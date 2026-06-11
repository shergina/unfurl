//
//  SRPostureAnalysisService.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
@preconcurrency import AVFoundation
import Combine
import Vision
import os


/// The first buildable increment of the posture-tracking vision (VISION.md):
/// a measurement probe that taps the shared capture session, runs Apple
/// Vision body-pose detection off-main, and logs the shoulder distance,
/// average eye height, slouch ratio, and shoulder tilt angle once per
/// second, plus warning lines whenever the slouch ratio breaches the
/// user's calibrated good-posture baseline or the shoulder tilt exceeds
/// the level band. Runs only while the Track Posture preference is on; the
/// composition root calls start/stop as the preference changes. See
/// spec.md.
///
/// Currently running the synthetic zoom-out experiment: the body-pose model
/// is trained on full-body imagery and mostly fails on laptop framing where
/// a head and shoulders fill the frame. Each analyzed frame is therefore
/// measured twice - on the raw frame and on the frame composited at the top
/// of a taller black canvas, which makes the visible upper body a small
/// figure near the top of a mostly empty image, closer to the training
/// distribution. The log reports both so the lift is measurable on
/// identical frames. See spec.md for the decision this feeds.
@MainActor
final class SRPostureAnalysisService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

	static let sharedInstance = SRPostureAnalysisService()

	let cameraService = SRCameraService.sharedInstance

	/// Per-frame feed for the calibration window and the dots overlay,
	/// published on the main actor at the analysis rate. Nil fields = no
	/// usable body that frame; nil sample = probe detached.
	let onFrameSample = CurrentValueSubject<SRPostureFrameSample?, Never>(nil)

	/// The per-window posture status for the corner note (and any future
	/// nudge surface): good, the single correction to make, or not visible.
	/// Published on the main actor once per logging window; nil until the
	/// first window completes.
	let onPostureStatus = CurrentValueSubject<SRPostureStatus?, Never>(nil)

	/// The raw per-window verdicts for the history store, published on the
	/// main actor once per logging window while evaluation is live (muted
	/// windows publish nothing). Deliberately un-debounced: the store
	/// applies its own sustained-run rule (see SRPostureHistoryService),
	/// independent of the nudge machinery above.
	let onWindowSample = PassthroughSubject<SRPostureWindowSample, Never>()

	fileprivate var output: AVCaptureVideoDataOutput?

	/// The in-flight attach from start(), kept so stop() can wait for it to
	/// settle before detaching (a quick on-off flip must not interleave).
	fileprivate var attachTask: Task<Void, Error>?

	/// The serial queue the sample-buffer delegate and Vision work run on;
	/// every nonisolated(unsafe) property below is touched only here.
	fileprivate let analysisQueue = DispatchQueue(label: "narcissism.posture-analysis")

	fileprivate var cancellables = Set<AnyCancellable>()

	override init() {
		super.init()

		// Mirror the baseline preference onto the analysis queue, where it
		// is consumed. Worst case a frame races the initial push, sees nil,
		// and one window goes unevaluated.
		SRSettings.sharedInstance.postureBaselineSlouchRatio.publisher
			.sink { [unowned self] value in
				let baseline: CGFloat? = value > 0 ? value : nil
				self.analysisQueue.async { self.baselineSlouchRatio = baseline }
			}
			.store(in: &self.cancellables)

		// Same mirroring for the nudge delay: windows are ~1 s, so the
		// preference's seconds map straight to a window count.
		SRSettings.sharedInstance.postureNudgeDelay.publisher
			.sink { [unowned self] seconds in
				let windows = max(1, Int(seconds.rounded()))
				self.analysisQueue.async { self.issueReportWindows = windows }
			}
			.store(in: &self.cancellables)
	}

	/// Attaches a video data output to the shared session and begins the
	/// once-per-second shoulder-distance log. The attached output holds the
	/// session up for as long as tracking stays on, independent of any
	/// preview. Idempotent.
	func start() {
		guard self.output == nil else { return }

		let output = AVCaptureVideoDataOutput()
		// BGRA and deliberately no width/height request: asking the shared
		// session for scaled buffers renegotiates the device to a low
		// resolution format and degrades every preview (see the Dock output).
		output.videoSettings = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		]
		output.setSampleBufferDelegate(self, queue: self.analysisQueue)
		self.output = output

		self.attachTask = Task {
			do {
				try await self.cameraService.attachOutput(output).value
			} catch {
				// attachOutput already surfaced the failure through onState;
				// note it here too so the absent measurements are explained
				// in the same log the reader is watching.
				Self.logger.error("Posture probe could not attach to the camera: \(error.localizedDescription, privacy: .public)")
				// Only clear if a stop/start pair has not already replaced
				// the output this task was attaching.
				if self.output === output {
					self.output = nil
				}
				throw error
			}
		}
	}

	/// Detaches the probe and clears its published state, hiding the corner
	/// note. The camera service ref-counts its consumers, so this never stops
	/// a session another surface (preview, photo capture, Dock tile) is still
	/// using; the session goes down only when the probe was its last
	/// consumer. Idempotent.
	func stop() {
		guard let output = self.output else { return }
		self.output = nil

		let attachTask = self.attachTask
		self.attachTask = nil

		// Hide the note and dots right away rather than after the detach's
		// session-queue round trip.
		self.onFrameSample.send(nil)
		self.onPostureStatus.send(nil)

		Task {
			do {
				try await attachTask?.value
			} catch {
				// The attach never went through; there is nothing to detach.
				return
			}
			await self.cameraService.detachOutput(output).value

			// No new frames arrive after the detach; once the analysis queue
			// drains, the window and episode state can be reset so a later
			// start() begins from a clean slate.
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				self.analysisQueue.async {
					self.lastAnalysisTime = .invalid
					self.resetWindow()
					self.issueTrackers = [:]
					self.notVisibleWindows = 0
					self.lastLoggedStatus = nil
					continuation.resume()
				}
			}

			// Squash anything a last in-flight frame published between the
			// sends above and the detach completing.
			self.onFrameSample.send(nil)
			self.onPostureStatus.send(nil)

			Self.logger.log("Posture probe detached (tracking off)")
		}
	}

	// Analysis runs at 4 fps but logs at 1 Hz: single frames flicker (motion
	// blur, exposure settling, a marginal pose), so each one-second window
	// reports its best observation instead of whatever one frame happened to
	// say. Frames beyond 4/s are dropped before any Vision work happens.
    // This sets the number of frames per second (four):
	fileprivate nonisolated static let minimumAnalysisInterval = CMTime(value: 1, timescale: 4)
    // This sets the number of log lines per second (one):
	fileprivate nonisolated static let logInterval = CMTime(value: 1, timescale: 1)

	/// Height multiplier for the zoom-out canvas. At 2.5 the camera frame
	/// occupies the top 40 percent of the analyzed image.
	fileprivate nonisolated static let paddingFactor = 2.5

	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.narcissism", category: "Posture")

	/// Joints at or below this Vision confidence (0...1) are treated as not
	/// seen; a "not visible" line is logged instead of a noise measurement.
	/// Lowered from 0.3 on 2026-07-23 to see whether the marginal frames it
	/// admits are usable or noise; revisit with the accuracy question.
	fileprivate nonisolated static let minimumJointConfidence: Float = 0.2

	/// Windows whose slouch ratio drops more than this fraction below the
	/// baseline log a slouching warning (tightened from the ~10 percent
	/// starting band in VISION.md). Ratios above baseline are sitting tall,
	/// never an alert.
	fileprivate nonisolated static let slouchTolerance: CGFloat = 0.05

	/// Tilt magnitudes beyond this many degrees off level are called out as
	/// misaligned shoulders, naming the higher shoulder for correction.
	fileprivate nonisolated static let maximumLevelShoulderTiltDegrees: CGFloat = 3.0

	// An active episode ends only after this many consecutive clean
	// windows (or instantly on a strong recovery past half the tolerance
	// band). Brief dips at the threshold neither report nor reset.
	nonisolated static let issueClearWindows = 2
	// After this many consecutive can't-see-you windows every episode
	// resets: whoever returns to the desk starts from a clean slate.
	fileprivate nonisolated static let notVisibleResetWindows = 5

	/// The calibrated good-posture slouch ratio (see init); nil until
	/// calibrated, which suppresses the whole per-window evaluation.
	/// Touched only on the (serial) analysis queue.
	fileprivate nonisolated(unsafe) var baselineSlouchRatio: CGFloat?

	/// Mirror of calibrationWindowOpen. Touched only on the analysis queue.
	fileprivate nonisolated(unsafe) var suppressedForCalibration = false

	fileprivate var calibrationWindowOpen = false

	/// Mutes the evaluation while the calibration window is open - the note
	/// must not nag mid-calibration. Set by the window controller.
	func setCalibrationWindowOpen(_ open: Bool) {
		guard open != self.calibrationWindowOpen else { return }
		self.calibrationWindowOpen = open
		if open {
			// Hide an already-visible note right away, not at the next window.
			self.onPostureStatus.send(nil)
		}
		self.analysisQueue.async { self.suppressedForCalibration = open }
	}

	// The current logging window. Touched only on the (serial) analysis queue.
	fileprivate nonisolated(unsafe) var lastAnalysisTime = CMTime.invalid
	fileprivate nonisolated(unsafe) var windowStartTime = CMTime.invalid
	fileprivate nonisolated(unsafe) var windowFrameCount = 0
	fileprivate nonisolated(unsafe) var plainWindow = WindowAccumulator()
	fileprivate nonisolated(unsafe) var paddedWindow = WindowAccumulator()

	// Issue debounce state. Touched only on the (serial) analysis queue.
	// An issue is voiced only after being active this many windows (~1/s);
	// mirrored from the nudge-delay preference (see init).
	fileprivate nonisolated(unsafe) var issueReportWindows = 10
	fileprivate nonisolated(unsafe) var issueTrackers: [SRPostureIssue: SRIssueTracker] = [:]
	fileprivate nonisolated(unsafe) var notVisibleWindows = 0
	fileprivate nonisolated(unsafe) var lastLoggedStatus: SRPostureStatus?

	nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if self.lastAnalysisTime.isValid {
			let elapsed = timestamp - self.lastAnalysisTime
			if elapsed < .zero {
				// The timeline restarted (camera switch); drop the partial
				// window and every issue episode with it.
				self.resetWindow()
				self.issueTrackers = [:]
				self.notVisibleWindows = 0
			} else if elapsed < Self.minimumAnalysisInterval {
				return
			}
		}
		self.lastAnalysisTime = timestamp

		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

		if !self.windowStartTime.isValid {
			self.windowStartTime = timestamp
		}
		self.windowFrameCount += 1

		let plainResult = Self.analyzeShoulders(in: pixelBuffer, frameFraction: 1)
		self.plainWindow.merge(plainResult)
		var paddedResult: ShoulderAnalysis?
		if let canvas = self.paddedCanvasFilled(from: pixelBuffer) {
			let result = Self.analyzeShoulders(in: canvas, frameFraction: 1 / Self.paddingFactor)
			self.paddedWindow.merge(result)
			paddedResult = result
		}

		// Per-frame feed, padded pipeline preferred (the one that works).
		// Sent for every analyzed frame, usable or not: calibration counts
		// frame events.
		var best: ShoulderMeasurement?
		if case .measured(let measurement)? = paddedResult {
			best = measurement
		} else if case .measured(let measurement) = plainResult {
			best = measurement
		}
		let sample = SRPostureFrameSample(
			shoulderWidthFraction: best?.fractionOfWidth,
			slouchRatio: best?.slouchRatio,
			joints: best?.joints
		)
		Task { @MainActor [sample] in self.onFrameSample.send(sample) }

		if timestamp - self.windowStartTime >= Self.logInterval {
			self.logWindow()
			self.resetWindow()
			// Windows are contiguous: the next one starts at the frame that
			// closed this one, not at the next accepted frame, so the log
			// cadence stays at ~1 Hz instead of stretching by a frame gap.
			self.windowStartTime = timestamp
		}
	}

	/// Runs on the analysis queue: one line per finished window with both
	/// pipelines side by side, so the padded variant's lift over the plain
	/// one is readable off identical frames.
	fileprivate nonisolated func logWindow() {
		Self.logger.log("Shoulder distance: plain [\(self.plainWindow.summary, privacy: .public)] padded [\(self.paddedWindow.summary, privacy: .public)] (\(self.windowFrameCount, privacy: .public) frames)")

		// Muted while uncalibrated (nothing to judge against) or while the
		// calibration window is open (no nagging mid-calibration). Trackers
		// reset for a clean start.
		guard let baseline = self.baselineSlouchRatio, !self.suppressedForCalibration else {
			self.issueTrackers = [:]
			self.notVisibleWindows = 0
			self.lastLoggedStatus = nil
			Task { @MainActor in self.onPostureStatus.send(nil) }
			return
		}

		// Slouch alert, evaluated on whichever pipeline measured (padded is
		// the one that works at laptop framing; plain is the fallback). One
		// evaluation per window, no debounce yet: immediate per-second
		// feedback is the point of the current experiment.
		if
			let ratio = self.paddedWindow.bestMeasurement?.slouchRatio ?? self.plainWindow.bestMeasurement?.slouchRatio,
			ratio < baseline * (1 - Self.slouchTolerance)
		{
			let percentBelow = Int(((baseline - ratio) / baseline * 100).rounded())
			Self.logger.warning("Slouching: ratio \(String(format: "%.3f", ratio), privacy: .public) is \(percentBelow, privacy: .public) percent below your \(String(format: "%.3f", baseline), privacy: .public) baseline")
		}

		// Shoulder alignment alert, same cadence and pipeline preference.
		// Positive tilt means the subject's anatomical left shoulder is the
		// higher one, so it is the one to lower.
		if
			let tilt = self.paddedWindow.bestMeasurement?.shoulderTiltDegrees ?? self.plainWindow.bestMeasurement?.shoulderTiltDegrees,
			abs(tilt) > Self.maximumLevelShoulderTiltDegrees
		{
			let higherShoulder = tilt > 0 ? "left" : "right"
			Self.logger.warning("Shoulders misaligned: tilt \(String(format: "%+.1f", tilt), privacy: .public) deg - lower your \(higherShoulder, privacy: .public) shoulder")
		}

		// Debounced issue tracking for the corner note (see spec.md). Each
		// issue is observed independently per window and fed through its
		// own tracker: active ~issueReportWindows before it is voiced;
		// cleared only by ~issueClearWindows consecutive clean windows or
		// an instant strong recovery past half the tolerance band. Strong
		// recovery is one-sided per issue, so overcorrecting a left-high
		// tilt into a right-high one clears the left issue immediately.
		let status: SRPostureStatus
		if let measurement = self.paddedWindow.bestMeasurement ?? self.plainWindow.bestMeasurement {
			self.notVisibleWindows = 0

			let slouchObservation: SRIssueObservation
			if let ratio = measurement.slouchRatio {
				let breachFloor = baseline * (1 - Self.slouchTolerance)
				let strongFloor = baseline * (1 - Self.slouchTolerance / 2)
				slouchObservation = ratio < breachFloor ? .breaching : (ratio >= strongFloor ? .stronglyRecovered : .clean)
			} else {
				// Eyes not measurable this window: freeze the tracker
				// rather than guessing either way.
				slouchObservation = .unknown
			}

			let tilt = measurement.shoulderTiltDegrees
			let limit = Self.maximumLevelShoulderTiltDegrees
			let leftObservation: SRIssueObservation = tilt > limit ? .breaching : (tilt <= limit / 2 ? .stronglyRecovered : .clean)
			let rightObservation: SRIssueObservation = -tilt > limit ? .breaching : (-tilt <= limit / 2 ? .stronglyRecovered : .clean)

			self.updateTracker(for: .slouching, with: slouchObservation)
			self.updateTracker(for: .leftShoulderHigh, with: leftObservation)
			self.updateTracker(for: .rightShoulderHigh, with: rightObservation)

			let sample = SRPostureWindowSample(
				timestamp: Date.now,
				visible: true,
				slouchMeasurable: measurement.slouchRatio != nil,
				slouching: slouchObservation == .breaching,
				leftShoulderHigh: leftObservation == .breaching,
				rightShoulderHigh: rightObservation == .breaching
			)
			Task { @MainActor [sample] in self.onWindowSample.send(sample) }

			// Stable declaration order, so the note's lines never reshuffle.
			let reported = SRPostureIssue.allCases.filter { self.issueTrackers[$0]?.isReported(after: self.issueReportWindows) ?? false }
			status = .evaluated(issues: reported)
		} else {
			self.notVisibleWindows += 1
			if self.notVisibleWindows >= Self.notVisibleResetWindows {
				self.issueTrackers = [:]
			}
			let sample = SRPostureWindowSample.notVisible(at: Date.now)
			Task { @MainActor [sample] in self.onWindowSample.send(sample) }
			status = .notVisible
		}

		if status != self.lastLoggedStatus {
			self.lastLoggedStatus = status
			Self.logger.log("Posture status: \(status.logDescription, privacy: .public)")
		}
		Task { @MainActor [status] in self.onPostureStatus.send(status) }
	}

	fileprivate nonisolated func updateTracker(for issue: SRPostureIssue, with observation: SRIssueObservation) {
		var tracker = self.issueTrackers[issue] ?? SRIssueTracker()
		tracker.update(with: observation)
		self.issueTrackers[issue] = tracker
	}

	fileprivate nonisolated func resetWindow() {
		self.windowStartTime = .invalid
		self.windowFrameCount = 0
		self.plainWindow = WindowAccumulator()
		self.paddedWindow = WindowAccumulator()
	}

	//: ## The zoom-out canvas

	/// Lazily (re)created black canvas, paddingFactor times the frame height;
	/// only the frame region is overwritten each time, the padding stays
	/// black from allocation. Touched only on the analysis queue.
	fileprivate nonisolated(unsafe) var paddedCanvas: CVPixelBuffer?
	fileprivate nonisolated(unsafe) var didLogCanvasFailure = false

	/// Copies the frame into the top of the reusable canvas and returns it.
	/// Pixels are 1:1 with the source, so distances measured on the canvas
	/// are directly comparable with the plain pipeline.
	fileprivate nonisolated func paddedCanvasFilled(from source: CVPixelBuffer) -> CVPixelBuffer? {
		let width = CVPixelBufferGetWidth(source)
		let height = CVPixelBufferGetHeight(source)
		let paddedHeight = Int(Double(height) * Self.paddingFactor)

		if self.paddedCanvas == nil
			|| CVPixelBufferGetWidth(self.paddedCanvas!) != width
			|| CVPixelBufferGetHeight(self.paddedCanvas!) != paddedHeight {
			var canvas: CVPixelBuffer?
			CVPixelBufferCreate(kCFAllocatorDefault, width, paddedHeight, kCVPixelFormatType_32BGRA, nil, &canvas)
			if let canvas {
				CVPixelBufferLockBaseAddress(canvas, [])
				if let base = CVPixelBufferGetBaseAddress(canvas) {
					// Opaque black: the pattern keeps BGRA alpha at 255 so
					// the padding reads as black, not as transparency.
					var black: [UInt8] = [0, 0, 0, 255]
					memset_pattern4(base, &black, CVPixelBufferGetDataSize(canvas))
				}
				CVPixelBufferUnlockBaseAddress(canvas, [])
			}
			self.paddedCanvas = canvas
		}

		guard let canvas = self.paddedCanvas else {
			if !self.didLogCanvasFailure {
				self.didLogCanvasFailure = true
				Self.logger.error("Could not allocate the zoom-out canvas; the padded pipeline is off")
			}
			return nil
		}

		CVPixelBufferLockBaseAddress(source, .readOnly)
		CVPixelBufferLockBaseAddress(canvas, [])
		defer {
			CVPixelBufferUnlockBaseAddress(canvas, [])
			CVPixelBufferUnlockBaseAddress(source, .readOnly)
		}
		guard
			let sourceBase = CVPixelBufferGetBaseAddress(source),
			let canvasBase = CVPixelBufferGetBaseAddress(canvas)
		else { return nil }

		let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
		let canvasBytesPerRow = CVPixelBufferGetBytesPerRow(canvas)
		let rowBytes = min(sourceBytesPerRow, canvasBytesPerRow, width * 4)
		for row in 0..<height {
			memcpy(canvasBase + row * canvasBytesPerRow, sourceBase + row * sourceBytesPerRow, rowBytes)
		}
		return canvas
	}

	//: ## Detection

	/// Runs on the analysis queue. Detects the body pose and measures the
	/// shoulder distance, aspect-correct, in pixels and as a fraction of the
	/// frame width (the scale-invariant form the VISION.md metrics build on),
	/// plus the average eye height when the eye joints clear the confidence
	/// floor. Works on the raw frame and the zoom-out canvas alike; the
	/// reported width x height reveals which one produced a measurement.
	/// `frameFraction` is the portion of the analyzed image's height, at the
	/// top, that the real camera frame occupies (1 for the raw frame); eye
	/// heights are remapped through it into frame coordinates so both
	/// pipelines report comparable values.
	fileprivate nonisolated static func analyzeShoulders(in pixelBuffer: CVPixelBuffer, frameFraction: CGFloat) -> ShoulderAnalysis {
		let request = VNDetectHumanBodyPoseRequest()
		let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
		do {
			try handler.perform([request])
		} catch {
			Self.logger.error("Body-pose request failed: \(error.localizedDescription, privacy: .public)")
			return .failed
		}

		guard let observation = request.results?.first else {
			return .noBody
		}

		guard
			let left = try? observation.recognizedPoint(.leftShoulder),
			let right = try? observation.recognizedPoint(.rightShoulder)
		else {
			return .noBody
		}

		guard left.confidence > Self.minimumJointConfidence, right.confidence > Self.minimumJointConfidence else {
			return .lowConfidence(left: left.confidence, right: right.confidence)
		}

		// Vision points are normalized to the analyzed image, so x and y
		// scale differently; convert to pixels before taking the distance.
		let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
		let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
		let distanceInPixels = hypot((left.x - right.x) * width, (left.y - right.y) * height)

		// Shoulder tilt: the angle the shoulder line makes with horizontal.
		// The pixel separations are the legs of a right triangle whose
		// hypotenuse is the shoulder line; atan2 of vertical over horizontal
		// is the tilt. Signed: positive means the subject's anatomical left
		// shoulder is the higher one (independent of preview mirroring);
		// 0 is level. This is the shoulder tilt metric from VISION.md.
		let tiltDegrees = atan2(
			(left.y - right.y) * height,
			abs((left.x - right.x) * width)
		) * 180 / .pi

		// Frame-normalized joint positions for the TEMPORARY dots overlay:
		// x is unchanged (the canvas only adds height), y rescales around
		// the top edge, the same remap the eye height uses below.
		func remapToFrame(_ point: VNRecognizedPoint) -> CGPoint {
			return CGPoint(x: point.x, y: (point.y - (1 - frameFraction)) / frameFraction)
		}

		// Average eye height, reported relative to the camera frame (0 =
		// frame bottom, 1 = frame top). The frame is the top `frameFraction`
		// of the analyzed image, so image y rescales around the top edge;
		// on the raw frame the remap is the identity.
		var eyeHeightFraction: CGFloat?
		var eyeHeightPixels: CGFloat?
		var slouchRatio: CGFloat?
		var personHeightFraction: CGFloat?
		var leftEyePoint: CGPoint?
		var rightEyePoint: CGPoint?
		if
			let leftEye = try? observation.recognizedPoint(.leftEye),
			let rightEye = try? observation.recognizedPoint(.rightEye),
			leftEye.confidence > Self.minimumJointConfidence,
			rightEye.confidence > Self.minimumJointConfidence
		{
			leftEyePoint = remapToFrame(leftEye)
			rightEyePoint = remapToFrame(rightEye)
			let fraction = ((leftEye.y + rightEye.y) / 2 - (1 - frameFraction)) / frameFraction
			eyeHeightFraction = fraction
			eyeHeightPixels = fraction * height * frameFraction

			// The slouch ratio from VISION.md: the vertical drop from eye
			// level to shoulder level, over shoulder width. Heights are
			// vertical only, so head tilt does not pollute it, and the
			// division makes it scale-invariant: chair and laptop moves
			// cancel out. Smaller means more slouch.
			let shoulderHeightPixels = ((left.y + right.y) / 2 - (1 - frameFraction)) * height
			slouchRatio = (eyeHeightPixels! - shoulderHeightPixels) / distanceInPixels

			// Rough frame occupancy: the body runs off the frame's bottom
			// edge, so the occupied share is frame bottom to head top. The
			// head top is not a joint; estimate it as half the eye-to-
			// shoulder drop above the eyes.
			let shoulderFraction = ((left.y + right.y) / 2 - (1 - frameFraction)) / frameFraction
			personHeightFraction = min(1, fraction + (fraction - shoulderFraction) / 2)
		}

		return .measured(ShoulderMeasurement(
			fractionOfWidth: distanceInPixels / width,
			distanceInPixels: distanceInPixels,
			width: Int(width),
			height: Int(height),
			leftConfidence: left.confidence,
			rightConfidence: right.confidence,
			eyeHeightFraction: eyeHeightFraction,
			eyeHeightPixels: eyeHeightPixels,
			slouchRatio: slouchRatio,
			personHeightFraction: personHeightFraction,
			shoulderTiltDegrees: tiltDegrees,
			joints: SRPostureJoints(
				leftShoulder: remapToFrame(left),
				rightShoulder: remapToFrame(right),
				leftEye: leftEyePoint,
				rightEye: rightEyePoint
			)
		))
	}

}


// File scope, not nested: types nested in a @MainActor class inherit its
// isolation, and these are consumed on the analysis queue.

/// One usable shoulder measurement, kept while picking a window's best.
fileprivate struct ShoulderMeasurement {
	let fractionOfWidth: CGFloat
	let distanceInPixels: CGFloat
	let width: Int
	let height: Int
	let leftConfidence: Float
	let rightConfidence: Float

	/// Average of the two eye joints, relative to the camera frame: 0 is the
	/// frame's bottom edge, 1 its top. Nil when either eye is at or below
	/// the confidence floor. Slouching reads as this value dropping.
	let eyeHeightFraction: CGFloat?
	let eyeHeightPixels: CGFloat?

	/// (average eye height - average shoulder height) / shoulder distance,
	/// the scale-invariant slouch ratio from VISION.md. Nil whenever the eye
	/// heights are. Smaller means more slouch.
	let slouchRatio: CGFloat?

	/// Rough share of the frame's height the person occupies, from the
	/// frame's bottom edge (the body runs off it) to the estimated head
	/// top (half the eye-to-shoulder drop above the eyes). Nil whenever
	/// the eye heights are.
	let personHeightFraction: CGFloat?

	/// The angle of the shoulder line off horizontal, in degrees. Positive
	/// means the subject's anatomical left shoulder is higher; 0 is level.
	let shoulderTiltDegrees: CGFloat

	/// The joint positions behind this measurement, for the dots overlay.
	let joints: SRPostureJoints

	/// The weaker of the two joints; the per-window winner maximizes this.
	var weakestConfidence: Float { min(self.leftConfidence, self.rightConfidence) }
}


fileprivate enum ShoulderAnalysis {
	case measured(ShoulderMeasurement)
	case lowConfidence(left: Float, right: Float)
	case noBody
	case failed
}


/// One independently tracked posture problem. Issues are a set, not a
/// choice: slouching and a tilted shoulder line can hold at once, and each
/// runs its own debounce. Left and right are the subject's anatomical
/// sides. Declaration order is the note's stable presentation order.
enum SRPostureIssue: CaseIterable, Hashable, Sendable {
	case slouching
	case leftShoulderHigh
	case rightShoulderHigh
}


/// One window's posture verdict for the nudge surfaces: the debounced set
/// of currently reported issues (empty = posture is good), or an honest
/// "cannot see you" that suppresses evaluation entirely.
enum SRPostureStatus: Equatable, Sendable {
	case notVisible
	case evaluated(issues: [SRPostureIssue])

	var logDescription: String {
		switch self {
		case .notVisible:
			return "not visible"
		case .evaluated(let issues):
			return issues.isEmpty ? "good" : issues.map { "\($0)" }.joined(separator: "+")
		}
	}
}


/// What one logging window said about one issue.
fileprivate enum SRIssueObservation {
	case breaching           // past the issue's threshold
	case clean               // inside the threshold, but not by much
	case stronglyRecovered   // past half the tolerance band, issue-side
	case unknown             // not measurable this window; freeze
}


/// One issue's debounce state, advanced once per logging window (~1/s).
/// An episode starts on a breach, ages through breaching and clean-dip
/// windows alike (hovering at the threshold is still having the issue),
/// is voiced once old enough (the caller passes the preference-driven
/// window count), and ends only via the dual-path clear: enough
/// consecutive clean windows, or one strongly recovered window.
fileprivate struct SRIssueTracker {
	var activeWindows = 0
	var cleanWindows = 0

	var isActive: Bool { self.activeWindows > 0 }

	func isReported(after reportWindows: Int) -> Bool {
		return self.activeWindows >= reportWindows
	}

	mutating func update(with observation: SRIssueObservation) {
		switch observation {
		case .breaching:
			self.activeWindows += 1
			self.cleanWindows = 0
		case .clean:
			guard self.isActive else { return }
			self.activeWindows += 1
			self.cleanWindows += 1
			if self.cleanWindows >= SRPostureAnalysisService.issueClearWindows {
				self = SRIssueTracker()
			}
		case .stronglyRecovered:
			self = SRIssueTracker()
		case .unknown:
			break
		}
	}
}


/// One frame's joint positions, frame-normalized Vision coordinates
/// (origin bottom-left). Eyes are nil below the confidence floor.
struct SRPostureJoints: Sendable {
	let leftShoulder: CGPoint
	let rightShoulder: CGPoint
	let leftEye: CGPoint?
	let rightEye: CGPoint?
}


/// One logging window's raw verdicts for the history store: whether the
/// user was visible, whether the slouch ratio was measurable (eyes seen),
/// and which issues breached their thresholds this window. Un-debounced
/// on purpose - the store applies its own sustained-run rule.
struct SRPostureWindowSample: Sendable {
	let timestamp: Date
	let visible: Bool
	let slouchMeasurable: Bool
	let slouching: Bool
	let leftShoulderHigh: Bool
	let rightShoulderHigh: Bool

	static func notVisible(at timestamp: Date) -> SRPostureWindowSample {
		return SRPostureWindowSample(
			timestamp: timestamp,
			visible: false,
			slouchMeasurable: false,
			slouching: false,
			leftShoulderHigh: false,
			rightShoulderHigh: false
		)
	}
}


/// One analyzed frame's readings, padded pipeline preferred: shoulder
/// width as a fraction of the frame, the slouch ratio (nil without eyes),
/// and the joints. All nil when nothing measured.
struct SRPostureFrameSample: Sendable {
	let shoulderWidthFraction: CGFloat?
	let slouchRatio: CGFloat?
	let joints: SRPostureJoints?
}


/// One pipeline's state within a logging window: the best usable measurement,
/// else the best sub-threshold confidence pair as the most informative
/// failure.
fileprivate struct WindowAccumulator {
	var bestMeasurement: ShoulderMeasurement?
	var bestLowConfidence: (left: Float, right: Float)?

	mutating func merge(_ analysis: ShoulderAnalysis) {
		switch analysis {
		case .measured(let measurement):
			if measurement.weakestConfidence > (self.bestMeasurement?.weakestConfidence ?? -1) {
				self.bestMeasurement = measurement
			}
		case .lowConfidence(let left, let right):
			if min(left, right) > (self.bestLowConfidence.map { min($0.left, $0.right) } ?? -1) {
				self.bestLowConfidence = (left, right)
			}
		case .noBody, .failed:
			break
		}
	}

	var summary: String {
		if let best = self.bestMeasurement {
			var line = String(
				format: "%.3f of width, %d px at %dx%d, L %.2f R %.2f",
				best.fractionOfWidth, Int(best.distanceInPixels), best.width, best.height, best.leftConfidence, best.rightConfidence
			)
			if let eyeFraction = best.eyeHeightFraction, let eyePixels = best.eyeHeightPixels {
				line += String(format: ", eyes %.3f of height (%d px)", eyeFraction, Int(eyePixels))
			} else {
				line += ", eyes n/a"
			}
			if let slouchRatio = best.slouchRatio {
				line += String(format: ", slouch ratio %.3f", slouchRatio)
			}
			if let personHeightFraction = best.personHeightFraction {
				line += String(format: ", occupies ~%.0f%% of height", personHeightFraction * 100)
			}
			line += String(format: ", tilt %+.1f deg", best.shoulderTiltDegrees)
			return line
		}
		if let low = self.bestLowConfidence {
			return String(format: "low confidence, best L %.2f R %.2f", low.left, low.right)
		}
		return "no body"
	}
}
