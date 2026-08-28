//
//  SRPostureAnalysisService.swift
//  Unfurl
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
/// The body-pose model is trained on full-body imagery and mostly fails on
/// laptop framing where a head and shoulders fill the frame, so each
/// analyzed frame is composited onto a black canvas sized and positioned
/// from the detected face: the implied figure keeps full-body proportions
/// at any sitting distance and screen tilt. See spec.md for the zoom-out
/// experiments that settled on this design.
@MainActor
final class SRPostureAnalysisService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

	static let sharedInstance = SRPostureAnalysisService()

	let cameraService = SRCameraService.sharedInstance

	/// Per-frame feed for the calibration window, published on the main
	/// actor at the analysis rate. Nil fields = no usable body that frame;
	/// nil sample = probe detached.
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

	/// The probe's video data output. Created on the first start, then kept
	/// for as long as the session lives: stop() suspends it (connection
	/// disabled, session claim released) instead of removing it, because
	/// removing an output from the running session stalls frame delivery to
	/// every preview for ~300 ms - the gray toggle blink (see Tools/spec.md).
	/// Cleared only when the session went down while suspended and took the
	/// wiring with it, or when an attach failed.
	fileprivate var output: AVCaptureVideoDataOutput?

	/// The tail of the attach/suspend/resume chain; every lifecycle operation
	/// awaits its predecessor, so a quick on-off flip cannot interleave.
	fileprivate var lifecycleTask: Task<Void, Never>?

	/// The serial queue the sample-buffer delegate and Vision work run on;
	/// every nonisolated(unsafe) property below is touched only here.
	fileprivate let analysisQueue = DispatchQueue(label: "unfurl.posture-analysis")

	fileprivate var cancellables = Set<AnyCancellable>()

	override init() {
		super.init()

		// Mirror the active camera's baseline and breach percents onto the
		// analysis queue, where they are consumed. Keyed by the device
		// actually in use, so switching cameras swaps them (an
		// uncalibrated camera reads nil, which suppresses the slouch alert
		// exactly as before calibration). Worst case a frame races the
		// initial push, sees nil, and one window goes unevaluated.
		// The strictness index rides the same sink so moving the slider
		// takes effect on the next window rather than the next calibration.
		SRSettings.sharedInstance.postureBaselines.publisher
			.combineLatest(
				self.cameraService.onSelectedDeviceID,
				SRSettings.sharedInstance.postureSlouchStrictnessIndex.publisher
			)
			.sink { [unowned self] baselines, deviceID, strictnessIndex in
				let entry = baselines[deviceID]
				let baseline: CGFloat? = (entry?.slouchRatio ?? 0) > 0 ? entry?.slouchRatio : nil
				let earBaseline: CGFloat? = (entry?.earSlouchRatio ?? 0) > 0 ? entry?.earSlouchRatio : nil
				// Piecewise strictness (PITCH_TUNING.md): the regime is
				// which side of the user's level gaze the camera sits, the
				// fixed index picks the stop. Theta cannot classify the
				// camera - both probe legs are camera-relative, so the
				// camera cancels out of their difference and theta only
				// measures the screen centre's depth below level. The ahead
				// pitch (upright + theta) keeps the camera term: positive =
				// camera above the gaze line. Entries predating
				// uprightFacePitch fall back to the old theta proxy;
				// missing theta = the looser high-camera regime until
				// recalibrated.
				let theta = entry?.gazePitchDelta
				let aheadPitch = entry?.uprightFacePitch.flatMap { upright in theta.map { upright + $0 } }
				let lowCamera = aheadPitch.map { $0 <= SRSettings.lowCameraAheadPitchBoundary }
					?? theta.map { $0 <= SRSettings.lowCameraThetaBoundary }
					?? false
				// The slider's stop. Clamped rather than trusted: the
				// preference is a stored number, and a stale or hand-edited
				// one must not index off the end of a ladder.
				let index = min(
					max(Int(strictnessIndex.rounded()), 0),
					SRSettings.highCameraAtScreenLadder.count - 1
				)

				// Above the boundary, with a theta to evaluate them at, the
				// fitted lines replace the table's medium stop and a second
				// ear percent comes along for windows where the gaze is
				// below the screen. Everything else - the low regime, and a
				// pre-probe entry whose theta was never measured - keeps the
				// tables exactly as before, with no down-gaze percent, so
				// the correction cannot fire there.
				let earPercent: CGFloat
				let eyePercent: CGFloat
				let earLookingDownPercent: CGFloat?
				let source: String
				// Where the gaze counts as down: a fixed drop below the
				// middle-of-screen pose the baseline was captured at. Down
				// is the positive pitch direction, so the drop adds. Needs
				// only the absolute reference, so an entry predating it
				// keeps the at-screen stop for every window.
				let lookingDownPitch = entry?.uprightFacePitch
					.map { $0 + SRSettings.lookingDownPitchBelowScreenDegrees }

				// Named in the log so replayed sessions can tell which rule
				// classified the camera.
				let regimeLabel = aheadPitch.map { String(format: "ahead %+.1f deg", $0) }
					?? (theta != nil ? "legacy theta" : "no theta")
				if !lowCamera, let theta {
					// The fitted line is the middle stop; the ladder moves it.
					// Looking down gets its own, tighter ladder - see the
					// comment on highCameraLookingDownLadder.
					let range = SRSettings.highCameraFitThetaRange
					let atScreen = SRSettings.highCameraAtScreenLadder[index]
					let lookingDown = SRSettings.highCameraLookingDownLadder[index]
					earPercent = SRSettings.highCameraEarAtScreen.percent(theta: theta, clampedTo: range) * atScreen
					eyePercent = SRSettings.highCameraEyeAtScreen.percent(theta: theta, clampedTo: range) * atScreen
					earLookingDownPercent = SRSettings.highCameraEarLookingDown.percent(theta: theta, clampedTo: range) * lookingDown
					source = "high camera, fitted (\(regimeLabel))"
				} else {
					earPercent = (lowCamera ? SRSettings.lowCameraEarPercents : SRSettings.highCameraEarPercents)[index]
					eyePercent = (lowCamera ? SRSettings.lowCameraEyePercents : SRSettings.highCameraEyePercents)[index]
					earLookingDownPercent = nil
					source = lowCamera ? "low camera, table (\(regimeLabel))" : "high camera, table (\(regimeLabel))"
				}

				if entry != nil {
					let downText = earLookingDownPercent.map { String(format: "%.1f", $0) } ?? "n/a"
					let pitchText = lookingDownPitch.map { String(format: "%.1f", $0) } ?? "n/a (recalibrate)"
					Self.logger.log("Strictness: ears \(String(format: "%.1f", earPercent), privacy: .public)% (looking down \(downText, privacy: .public)% past pitch \(pitchText, privacy: .public) deg), eyes \(String(format: "%.1f", eyePercent), privacy: .public)% (\(source, privacy: .public), theta \(theta.map { String(format: "%.1f", $0) } ?? "n/a", privacy: .public), stop \(index, privacy: .public) of \(SRSettings.highCameraAtScreenLadder.count - 1, privacy: .public))")
				}
				self.analysisQueue.async {
					self.baselineSlouchRatio = baseline
					self.baselineEarSlouchRatio = earBaseline
					self.earBreachPercent = earPercent
					self.earBreachPercentLookingDown = earLookingDownPercent
					self.eyeBreachPercent = eyePercent
					self.lookingDownPitchThreshold = lookingDownPitch
					self.isLookingDown = false
				}
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

		// And for the strictness preferences. The slouch strictness is the
		// depth tolerance: the fraction of the calibrated slouch span the
		// ratio may sink. The shoulder tolerance is stored as a slope
		// (height difference over shoulder separation); the evaluation
		// compares degrees, so convert once here.
		SRSettings.sharedInstance.postureShoulderTolerance.publisher
			.sink { [unowned self] slope in
				let degrees = atan(slope) * 180 / .pi
				self.analysisQueue.async { self.maximumLevelShoulderTiltDegrees = degrees }
			}
			.store(in: &self.cancellables)
	}

	/// Puts the probe in the frame path and begins the once-per-second
	/// shoulder-distance log. The first start creates the video data output
	/// and attaches it to the shared session; later starts resume the kept
	/// output in place (see `output`). While running, the output holds the
	/// session up for as long as tracking stays on, independent of any
	/// preview. Idempotent: a repeated start resumes an already-flowing
	/// output, which is harmless and retries a previously failed attach.
	func start() {
		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value

			// Resume the suspended output where possible; a session torn
			// down while suspended took the wiring with it, so start fresh
			// (that attach lands during the new session's own warm-up).
			if let output = self.output {
				if await self.cameraService.resumeOutput(output).value {
					return
				}
				self.output = nil
			}

			let output = AVCaptureVideoDataOutput()
			// BGRA and deliberately no width/height request: asking the shared
			// session for scaled buffers renegotiates the device to a low
			// resolution format and degrades every preview (see the Dock output).
			output.videoSettings = [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			]
			output.setSampleBufferDelegate(self, queue: self.analysisQueue)
			self.output = output

			do {
				try await self.cameraService.attachOutput(output).value
			} catch {
				// attachOutput already surfaced the failure through onState;
				// note it here too so the absent measurements are explained
				// in the same log the reader is watching. Clearing the output
				// lets a later start retry the attach.
				Self.logger.error("Posture probe could not attach to the camera: \(error.localizedDescription, privacy: .public)")
				if self.output === output {
					self.output = nil
				}
			}
		}
	}

	/// Takes the probe out of the frame path and clears its published state,
	/// hiding the corner note. The output is suspended, not removed: its
	/// connection is disabled (the session does no work for it, so the idle
	/// cost is zero) and its claim on the session is released, but it stays
	/// wired - removing it would stall every preview for ~300 ms, the gray
	/// toggle blink this replaced (see Tools/spec.md). Releasing the claim
	/// keeps the camera lifecycle honest: the toggle never stops a session
	/// another surface (preview, photo capture, Dock tile) is still using,
	/// and the session - taking the wired output down with it - stops when
	/// the probe was its last consumer. Idempotent.
	func stop() {
		// Hide the note and dots right away rather than after the suspend's
		// session-queue round trip.
		self.onFrameSample.send(nil)
		self.onPostureStatus.send(nil)

		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value

			// Read under the chain, not at stop() time: the predecessor may
			// be the very attach that creates the output (or the failed one
			// that cleared it, in which case there is nothing to suspend).
			guard let output = self.output else { return }
			await self.cameraService.suspendOutput(output).value

			// No new frames arrive once the connection is off; when the
			// analysis queue drains, the window and episode state reset so a
			// later start() begins from a clean slate.
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				self.analysisQueue.async {
					self.lastAnalysisTime = .invalid
					self.resetWindow()
					self.issueTrackers = [:]
					self.recentSlouchRatios = []
					self.recentEarSlouchRatios = []
					self.notVisibleWindows = 0
					self.lastLoggedStatus = nil
					self.lastEvaluatedStatus = nil
					self.smoothedFaceBox = nil
					self.lastFacePitch = nil
					self.lastFaceTime = .invalid
					continuation.resume()
				}
			}

			// Squash anything a last in-flight frame published between the
			// sends above and the connection going quiet.
			self.onFrameSample.send(nil)
			self.onPostureStatus.send(nil)

			Self.logger.log("Posture probe suspended (tracking off)")
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

	// The adaptive canvas is sized off the detected head: a standing
	// figure is 7-8 head-lengths tall and 2-2.5 wide at the shoulders, so a
	// canvas measured in head-heights keeps the implied figure plausibly
	// proportioned however close the user leans in. Vision's face box covers
	// roughly eyebrows to chin, so it is inflated to a full head first; all
	// the growth is upward (the chin is already the head's bottom).
	fileprivate nonisolated static let headInflation: CGFloat = 1.3
	fileprivate nonisolated static let adaptiveHeightInHeads: CGFloat = 7.5
	fileprivate nonisolated static let adaptiveWidthInHeads: CGFloat = 5.5

	/// The estimated head top sits this fraction below the adaptive canvas's
	/// top edge; frame content that lands above it (the ceiling band when
	/// the screen tilts up) is cropped by the placement itself.
	fileprivate nonisolated static let headTopAnchor: CGFloat = 0.05

	/// Head heights beyond this fraction of the frame stop growing the
	/// canvas; bounds the allocation when the face fills the frame.
	fileprivate nonisolated static let maximumHeadFraction: CGFloat = 0.45

	/// Exponential smoothing weight of each new face box, so the canvas
	/// geometry follows the head without jittering frame to frame.
	fileprivate nonisolated static let faceSmoothing: CGFloat = 0.3

	/// A missed face (a turned head) keeps the last box this long before
	/// the adaptive pipeline starts reporting no face.
	fileprivate nonisolated static let faceMemory = CMTime(value: 5, timescale: 1)

	/// Adaptive canvas dimensions round up to this multiple, so the buffer
	/// is not reallocated every time the smoothed head box breathes.
	fileprivate nonisolated static let canvasQuantum = 128

	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.unfurl", category: "Posture")

	/// Joints at or below this Vision confidence (0...1) are treated as not
	/// seen; a "not visible" line is logged instead of a noise measurement.
	/// Lowered from 0.3 on 2026-07-23 to see whether the marginal frames it
	/// admits are usable or noise; revisit with the accuracy question.
	fileprivate nonisolated static let minimumJointConfidence: Float = 0.2

	// An active episode ends only after this many consecutive clean
	// windows (or instantly on a strong recovery past half the tolerance
	// band). Brief dips at the threshold neither report nor reset.
	nonisolated static let issueClearWindows = 2
	// A brief detection dropout (a turned head, a stretch, one blurred
	// window) coasts on the last evaluated status; after this many
	// consecutive empty windows that verdict is dropped as stale.
	fileprivate nonisolated static let notVisibleGraceWindows = 3
	// And only after this many is the absence worth saying out loud. Windows
	// are 1 s (see logInterval), so this is five minutes. That figure is
	// spelled out in the note's copy ("posture.note.not-visible"), so the two
	// have to move together.
	//
	// Two thresholds rather than one because they do different jobs: a stale
	// "Sit up straight" has to come down within seconds of the user leaving,
	// while the absence note should stay quiet until being gone actually means
	// something. One constant cannot do both.
	fileprivate nonisolated static let notVisibleNoteWindows = 300
	// After this many consecutive can't-see-you windows every episode
	// resets: whoever returns to the desk starts from a clean slate.
	fileprivate nonisolated static let notVisibleResetWindows = 5

	/// The calibrated good-posture slouch ratio (see init); nil until
	/// calibrated, which suppresses the whole per-window evaluation.
	/// Touched only on the (serial) analysis queue.
	fileprivate nonisolated(unsafe) var baselineSlouchRatio: CGFloat?

	/// The ear-metric counterpart (see PostureBaseline.earSlouchRatio):
	/// nil until this camera is calibrated with visible ears, which keeps
	/// the evaluation on the eye metric. Touched only on the analysis queue.
	fileprivate nonisolated(unsafe) var baselineEarSlouchRatio: CGFloat?

	/// The regime-resolved breach percents (see the piecewise tables in
	/// SRSettings), one per metric. Touched only on the analysis queue.
	fileprivate nonisolated(unsafe) var earBreachPercent: CGFloat?

	/// The ear stop to use instead while the gaze reads as below the
	/// screen. Nil outside the fitted high-camera regime, which is what
	/// keeps the correction from firing on a low camera or a pre-probe
	/// entry (PITCH_TUNING.md).
	fileprivate nonisolated(unsafe) var earBreachPercentLookingDown: CGFloat?

	/// Face pitch, in degrees, past which the gaze counts as down - the
	/// calibrated middle-of-screen pose plus a fixed drop. Nil when the
	/// entry predates the pitch reference, which leaves the at-screen
	/// stop in force for every window.
	fileprivate nonisolated(unsafe) var lookingDownPitchThreshold: CGFloat?

	/// Latched across windows so the stop releases lower than it engages.
	fileprivate nonisolated(unsafe) var isLookingDown = false
	fileprivate nonisolated(unsafe) var eyeBreachPercent: CGFloat?

	/// Mirror of the shoulder strictness preference (see init): how far
	/// off level the shoulder line may tilt (in degrees, converted from
	/// the stored slope). Ratios above baseline are sitting tall, never
	/// an alert. Touched only on the analysis queue; the literal matches
	/// the preference default and is overwritten by the replay in init.
	fileprivate nonisolated(unsafe) var maximumLevelShoulderTiltDegrees: CGFloat = 2.9

	/// No breach drop may be smaller than this, regardless of how small a
	/// span calibration measured. With the rolling-median accusation (see
	/// recentSlouchRatios) frame jitter no longer reaches the breach test,
	/// so the floor guards only what averaging cannot remove: natural
	/// settling - genuinely sitting a little lower than at calibration
	/// (observed 2026-08-02: a sustained 0.021 below baseline while
	/// sitting well). The floor is absolute and camera-independent, and
	/// for a shallow habitual slouch it is the effective strictness (much
	/// of the ladder sits under it), so this constant is also the tuning
	/// knob for that profile. (History: 0.03 on day one; 0.025 on
	/// 2026-08-03 when detection felt loose; 0.02 same day with the
	/// median - jitter handled, the observed settling amplitude is now
	/// the binding constraint and this sits at its edge.)
	// Lowered 0.02 -> 0.01 on 2026-08-06 for the piecewise percent
	// tables: the strict ear stops (2-3 percent of a ~0.5-0.7 baseline)
	// sit under the old floor, which would have silently flattened them.
	// The rolling-median accusation still guards jitter; revisit against
	// settling telemetry in ear units.
	fileprivate nonisolated static let minimumBreachDrop: CGFloat = 0.01

	/// The rolling window for the median-based accusation: the last N
	/// windows' slouch ratios (nil where unmeasured), ~N seconds of
	/// wall-clock. The median needs at least half the window measured to
	/// speak; below that the raw per-window value decides, as before.
	/// Sized so a slouch must occupy about half of it before the verdict
	/// flips - brief excursions and single jittery frames structurally
	/// cannot accuse. Touched only on the analysis queue.
	fileprivate nonisolated static let slouchMedianWindowCount = 8
	fileprivate nonisolated static let slouchMedianMinimumSamples = 4
	/// One rolling window per metric, so ear and eye readings never mix in
	/// a single median (their baselines differ by the head-pitch term).
	fileprivate nonisolated(unsafe) var recentSlouchRatios: [CGFloat?] = []
	fileprivate nonisolated(unsafe) var recentEarSlouchRatios: [CGFloat?] = []

	/// Push one window's reading (nil = not measurable this window) and
	/// return the median of the measured readings in the window, or nil
	/// while fewer than half are measured.
	fileprivate nonisolated func pushRecent(_ ratio: CGFloat?, into ratios: inout [CGFloat?]) -> CGFloat? {
		ratios.append(ratio)
		if ratios.count > Self.slouchMedianWindowCount {
			ratios.removeFirst(ratios.count - Self.slouchMedianWindowCount)
		}
		let measured = ratios.compactMap { $0 }.sorted()
		guard measured.count >= Self.slouchMedianMinimumSamples else { return nil }
		let count = measured.count
		return count % 2 == 0 ? (measured[count / 2 - 1] + measured[count / 2]) / 2 : measured[count / 2]
	}

	/// The absolute ratio drop that counts as a breach: the regime percent
	/// of the metric's baseline, never below the noise floor. Analysis
	/// queue only.
	fileprivate nonisolated func slouchBreachDrop(baseline: CGFloat, percent: CGFloat) -> CGFloat {
		return max(baseline * percent / 100, Self.minimumBreachDrop)
	}

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
	fileprivate nonisolated(unsafe) var adaptiveWindow = WindowAccumulator()

	// Issue debounce state. Touched only on the (serial) analysis queue.
	// An issue is voiced only after being active this many windows (~1/s);
	// mirrored from the nudge-delay preference (see init).
	fileprivate nonisolated(unsafe) var issueReportWindows = 10
	fileprivate nonisolated(unsafe) var issueTrackers: [SRPostureIssue: SRIssueTracker] = [:]
	fileprivate nonisolated(unsafe) var notVisibleWindows = 0
	fileprivate nonisolated(unsafe) var lastLoggedStatus: SRPostureStatus?
	/// The last status computed from a real measurement, coasted on while a
	/// dropout is within the grace. Touched only on the analysis queue.
	fileprivate nonisolated(unsafe) var lastEvaluatedStatus: SRPostureStatus?

	nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if self.lastAnalysisTime.isValid {
			let elapsed = timestamp - self.lastAnalysisTime
			if elapsed < .zero {
				// The timeline restarted (camera switch); drop the partial
				// window and every issue episode with it. The face box's
				// timestamp lives on the old timeline, so it goes too.
				self.resetWindow()
				self.issueTrackers = [:]
				self.recentSlouchRatios = []
				self.recentEarSlouchRatios = []
				self.notVisibleWindows = 0
				self.lastEvaluatedStatus = nil
				self.smoothedFaceBox = nil
				self.lastFacePitch = nil
				self.lastFaceTime = .invalid
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

		// The face box drives the adaptive canvas geometry; refresh it first.
		self.updateFaceBox(from: pixelBuffer, at: timestamp)

		var adaptiveResult = ShoulderAnalysis.noFace
		if
			let faceBox = self.smoothedFaceBox,
			let (canvas, frameRect) = self.adaptiveCanvasFilled(from: pixelBuffer, faceBox: faceBox)
		{
			adaptiveResult = Self.analyzeShoulders(in: canvas, frameRect: frameRect)
		}
		self.adaptiveWindow.merge(adaptiveResult)

		// Per-frame feed. Sent for every analyzed frame, usable or not:
		// calibration counts frame events.
		var best: ShoulderMeasurement?
		if case .measured(let measurement) = adaptiveResult {
			best = measurement
		}
		let sample = SRPostureFrameSample(
			shoulderWidthFraction: best?.fractionOfWidth,
			slouchRatio: best?.slouchRatio,
			earSlouchRatio: best?.earSlouchRatio,
			facePitch: self.lastFacePitch,
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

	/// Runs on the analysis queue: one line per finished window.
	fileprivate nonisolated func logWindow() {
		Self.logger.log("Shoulder distance: \(self.adaptiveWindow.summary, privacy: .public) (\(self.windowFrameCount, privacy: .public) frames)")

		// Muted while uncalibrated (nothing to judge against) or while the
		// calibration window is open (no nagging mid-calibration). Trackers
		// reset for a clean start.
		guard self.baselineSlouchRatio != nil, !self.suppressedForCalibration else {
			self.issueTrackers = [:]
			self.recentSlouchRatios = []
			self.recentEarSlouchRatios = []
			self.notVisibleWindows = 0
			self.lastLoggedStatus = nil
			self.lastEvaluatedStatus = nil
			Task { @MainActor in self.onPostureStatus.send(nil) }
			return
		}

		let best = self.adaptiveWindow.bestMeasurement

		// Distance from baseline per metric, every window, in the ladder's
		// own currency: percent of baseline, positive = below it (toward
		// slouch). The tuning notebook (PITCH_TUNING.md) reads its bands
		// straight off these lines.
		if let best, best.slouchRatio != nil || best.earSlouchRatio != nil {
			func dropText(_ ratio: CGFloat?, _ base: CGFloat?) -> String {
				guard let ratio, let base, base > 0 else { return "n/a" }
				return String(format: "%+.1f%%", (base - ratio) / base * 100)
			}
			Self.logger.log("Below baseline: ears \(dropText(best.earSlouchRatio, self.baselineEarSlouchRatio), privacy: .public), eyes \(dropText(best.slouchRatio, self.baselineSlouchRatio), privacy: .public)")
		}

		// Head-pose telemetry for the strictness-loosening experiment
		// (PITCH_TUNING.md). Nothing consumes these yet: they are here so a
		// tuning session can be replayed to pick the trigger and its
		// threshold from real numbers instead of a guess. Pitch and yaw come
		// off the face detector (camera-relative, so every camera has its
		// own zero); the eye/ear ratio comes off the same pose observation
		// the slouch metrics do.
		// Both rolling medians update every window, measured or not (nil
		// ages stale readings out during blindness); the chosen metric's
		// median drives the tracker's breach verdict below.
		let recentEarMedian = self.pushRecent(best?.earSlouchRatio, into: &self.recentEarSlouchRatios)
		let recentEyeMedian = self.pushRecent(best?.slouchRatio, into: &self.recentSlouchRatios)

		// Gaze test for the looking-down stop (PITCH_TUNING.md): head pitch
		// straight off the face detector, against the calibrated pitch of
		// the screen's bottom edge. This replaced an eye-minus-ear
		// divergence test on 2026-08-07 - both read head pitch, but the
		// divergence read it indirectly through a geometric difference of
		// a few points against comparable noise, and it missed real
		// down-gazes. Pitch also survives losing the ears, which the
		// divergence test could not: it needed both metrics, so it went
		// blind in exactly the eye-fallback case that needs it most.
		//
		// Latched with hysteresis: engage at the threshold, release a few
		// degrees under it, so a gaze resting on the boundary does not
		// flip the stop every window.
		let livePitchDegrees = self.lastFacePitch.map { $0 * 180 / .pi }
		if let threshold = self.lookingDownPitchThreshold, let pitch = livePitchDegrees {
			let release = threshold - SRSettings.lookingDownPitchHysteresisDegrees
			self.isLookingDown = self.isLookingDown ? (pitch > release) : (pitch > threshold)
		} else {
			// No reference, or no face this window: assume the gaze is on
			// the screen, which selects the stricter of the two stops.
			self.isLookingDown = false
		}
		let lookingDown = self.isLookingDown
		let earPercent = (lookingDown ? self.earBreachPercentLookingDown : nil) ?? self.earBreachPercent

		let degreesText = { (radians: CGFloat?) in
			radians.map { String(format: "%+.1f", $0 * 180 / .pi) } ?? "n/a"
		}
		let eyeEarText = best?.eyeEarWidthRatio.map { String(format: "%.3f", $0) } ?? "n/a"
		let thresholdText = self.lookingDownPitchThreshold.map { String(format: "%.1f", $0) } ?? "n/a"
		let earLimitText = earPercent.map { String(format: "%.1f", $0) } ?? "n/a"
		Self.logger.log("Head pose: pitch \(degreesText(self.lastFacePitch), privacy: .public) deg, yaw \(degreesText(self.lastFaceYaw), privacy: .public) deg, eye/ear \(eyeEarText, privacy: .public), gaze \(lookingDown ? "down" : "at-screen", privacy: .public) (past \(thresholdText, privacy: .public) deg), ear limit \(earLimitText, privacy: .public)%")

		// The metric for this window: ears whenever this camera has an ear
		// baseline and the window measured an ear - immune to the downward
		// keyboard glance - else the eye metric (headphones, a hood), each
		// judged against its own regime percent. Units never mix.
		let metric: (name: String, ratio: CGFloat, median: CGFloat?, baseline: CGFloat, percent: CGFloat)?
		if let earBaseline = self.baselineEarSlouchRatio, let ratio = best?.earSlouchRatio, let percent = earPercent {
			metric = ("ears", ratio, recentEarMedian, earBaseline, percent)
		} else if let eyeBaseline = self.baselineSlouchRatio, let ratio = best?.slouchRatio, let percent = self.eyeBreachPercent {
			metric = ("eyes", ratio, recentEyeMedian, eyeBaseline, percent)
		} else {
			metric = nil
		}

		// Slouch alert. One evaluation per window,
		// no debounce yet: immediate per-second feedback is the point of the
		// current experiment; the line stays raw on purpose (tuning
		// telemetry), names the metric that judged, and carries the rolling
		// median so the accusation the tracker actually acts on is visible
		// next to it. The line reports slouch depth (the fraction of the
		// calibrated span the ratio has sunk) when the span was measured,
		// the old percent-below-baseline form otherwise.
		if
			let metric,
			metric.ratio < metric.baseline - self.slouchBreachDrop(baseline: metric.baseline, percent: metric.percent)
		{
			let medianText = metric.median.map { String(format: "%.3f", $0) } ?? "n/a"
			let percentBelow = (metric.baseline - metric.ratio) / metric.baseline * 100
			Self.logger.warning("Slouching (\(metric.name, privacy: .public)): ratio \(String(format: "%.3f", metric.ratio), privacy: .public) (median \(medianText, privacy: .public)) is \(String(format: "%.1f", percentBelow), privacy: .public) percent below your \(String(format: "%.3f", metric.baseline), privacy: .public) baseline (limit \(String(format: "%.1f", metric.percent), privacy: .public) percent)")
		}

		// Shoulder alignment alert, same cadence.
		// Positive tilt means the subject's anatomical left shoulder is the
		// higher one, so it is the one to lower.
		if
			let tilt = self.adaptiveWindow.bestMeasurement?.shoulderTiltDegrees,
			abs(tilt) > self.maximumLevelShoulderTiltDegrees
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
		let status: SRPostureStatus?
		if let measurement = best {
			self.notVisibleWindows = 0

			// Slow to accuse, instant to forgive: the breach verdict comes
			// from the rolling median (a slouch must occupy about half the
			// recent window - jitter and brief excursions cannot accuse),
			// while a strong recovery is judged on the raw value (sitting
			// up decisively is a large, unambiguous move; the note must
			// vanish right away, not after the median catches up). While
			// the median has too few samples (startup, after a dropout),
			// the raw value decides alone, as before.
			let slouchObservation: SRIssueObservation
			if let metric {
				let breachDrop = self.slouchBreachDrop(baseline: metric.baseline, percent: metric.percent)
				let breachFloor = metric.baseline - breachDrop
				let strongFloor = metric.baseline - breachDrop / 2
				if metric.ratio >= strongFloor {
					slouchObservation = .stronglyRecovered
				} else if let median = metric.median {
					slouchObservation = median < breachFloor ? .breaching : .clean
				} else {
					slouchObservation = metric.ratio < breachFloor ? .breaching : .clean
				}
			} else {
				// Neither metric measurable this window: freeze the tracker
				// rather than guessing either way.
				slouchObservation = .unknown
			}

			let tilt = measurement.shoulderTiltDegrees
			let limit = self.maximumLevelShoulderTiltDegrees
			let leftObservation: SRIssueObservation = tilt > limit ? .breaching : (tilt <= limit / 2 ? .stronglyRecovered : .clean)
			let rightObservation: SRIssueObservation = -tilt > limit ? .breaching : (-tilt <= limit / 2 ? .stronglyRecovered : .clean)

			self.updateTracker(for: .slouching, with: slouchObservation)
			self.updateTracker(for: .leftShoulderHigh, with: leftObservation)
			self.updateTracker(for: .rightShoulderHigh, with: rightObservation)

			let sample = SRPostureWindowSample(
				timestamp: Date.now,
				visible: true,
				slouchMeasurable: metric != nil,
				slouching: slouchObservation == .breaching,
				leftShoulderHigh: leftObservation == .breaching,
				rightShoulderHigh: rightObservation == .breaching
			)
			Task { @MainActor [sample] in self.onWindowSample.send(sample) }

			// Stable declaration order, so the note's lines never reshuffle.
			let reported = SRPostureIssue.allCases.filter { self.issueTrackers[$0]?.isReported(after: self.issueReportWindows) ?? false }
			status = .evaluated(issues: reported)
			self.lastEvaluatedStatus = status
		} else {
			self.notVisibleWindows += 1
			if self.notVisibleWindows >= Self.notVisibleResetWindows {
				self.issueTrackers = [:]
			}
			let sample = SRPostureWindowSample.notVisible(at: Date.now)
			Task { @MainActor [sample] in self.onWindowSample.send(sample) }
			if self.notVisibleWindows < Self.notVisibleGraceWindows {
				// A dropout inside the grace coasts on the last evaluated
				// status instead of flashing "can't see you" (nil during
				// the camera's warm-up, keeping the note blank). Trackers
				// stay frozen and the history sample above stays honest.
				status = self.lastEvaluatedStatus
			} else {
				// Past the grace the last verdict is stale: the user may have
				// walked off mid-slouch, and "Sit up straight" must not sit in
				// the corner with nobody there to read it.
				self.lastEvaluatedStatus = nil

				// Between the two thresholds the note says nothing at all -
				// briefly out of frame is not news. nil hides the note, clears
				// the status item's tint, and lets the sound controller treat
				// the next issue as a fresh event.
				status = self.notVisibleWindows >= Self.notVisibleNoteWindows ? .notVisible : nil
			}
		}

		if let status, status != self.lastLoggedStatus {
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
		self.adaptiveWindow = WindowAccumulator()
	}

	//: ## The head-adaptive canvas

	/// The smoothed face box (frame-normalized, Vision bottom-left origin)
	/// and when a face was last actually seen. Touched only on the analysis
	/// queue.
	fileprivate nonisolated(unsafe) var smoothedFaceBox: CGRect?
	fileprivate nonisolated(unsafe) var lastFaceTime = CMTime.invalid
	/// The winning face's head pitch, kept in step with the box.
	fileprivate nonisolated(unsafe) var lastFacePitch: CGFloat?
	/// Head turn off the camera axis, same observation. Telemetry only for
	/// now: a candidate trigger for loosening strictness when the head is
	/// turned away (PITCH_TUNING.md).
	fileprivate nonisolated(unsafe) var lastFaceYaw: CGFloat?
	fileprivate nonisolated(unsafe) var adaptiveCanvas: CVPixelBuffer?
	fileprivate nonisolated(unsafe) var didLogAdaptiveCanvasFailure = false
	fileprivate nonisolated(unsafe) var didLogFaceFailure = false

	/// Face detection on the raw frame, feeding the adaptive canvas
	/// geometry. The face detector stays reliable at close range and odd
	/// screen angles where the pose model gives up, which breaks the
	/// circularity of "pad based on how big the user looks". The box is
	/// exponentially smoothed so the canvas does not jitter, and a missed
	/// frame (a turned head) keeps the last box for faceMemory before the
	/// pipeline goes honest about having no face.
	fileprivate nonisolated func updateFaceBox(from pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
		let request = VNDetectFaceRectanglesRequest()
		let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
		do {
			try handler.perform([request])
		} catch {
			if !self.didLogFaceFailure {
				self.didLogFaceFailure = true
				Self.logger.error("Face detection failed: \(error.localizedDescription, privacy: .public)")
			}
			return
		}

		// Largest face wins; a passerby in the background must not shrink
		// the canvas under the person at the desk.
		guard let observation = request.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height }) else {
			if self.lastFaceTime.isValid, timestamp - self.lastFaceTime > Self.faceMemory {
				self.smoothedFaceBox = nil
				self.lastFacePitch = nil
				self.lastFaceYaw = nil
			}
			return
		}
		let face = observation.boundingBox

		// Head pitch rides the same observation: radians, relative to the
		// camera's optical axis (every camera has its own zero). Feeds the
		// calibration gaze capture; sign convention is settled empirically
		// there.
		self.lastFacePitch = observation.pitch.map { CGFloat(truncating: $0) }
		self.lastFaceYaw = observation.yaw.map { CGFloat(truncating: $0) }

		if let previous = self.smoothedFaceBox {
			let alpha = Self.faceSmoothing
			self.smoothedFaceBox = CGRect(
				x: previous.minX + (face.minX - previous.minX) * alpha,
				y: previous.minY + (face.minY - previous.minY) * alpha,
				width: previous.width + (face.width - previous.width) * alpha,
				height: previous.height + (face.height - previous.height) * alpha
			)
		} else {
			self.smoothedFaceBox = face
		}
		self.lastFaceTime = timestamp
	}

	/// Copies the frame onto the head-adaptive canvas: black, sized in
	/// head-heights (never smaller than the frame, so a distant sitter gets
	/// little or no padding), with the estimated head top anchored just
	/// below the canvas top and the head centered horizontally. Frame
	/// content that falls outside the canvas is cropped by the placement
	/// itself. Pixels stay 1:1 with the source; the canvas is re-blacked
	/// every fill because the placement shifts with the head and stale
	/// pixels must not ghost around the frame. Returns the canvas plus the
	/// frame's placement rect in Vision-normalized canvas coordinates (it
	/// can extend past the unit square when the frame is partially cropped)
	/// for remapping results back into frame coordinates.
	fileprivate nonisolated func adaptiveCanvasFilled(from source: CVPixelBuffer, faceBox: CGRect) -> (canvas: CVPixelBuffer, frameRect: CGRect)? {
		let width = CVPixelBufferGetWidth(source)
		let height = CVPixelBufferGetHeight(source)

		let headHeight = min(Self.headInflation * faceBox.height, Self.maximumHeadFraction) * CGFloat(height)
		// Deliberately unclamped: with the forehead clipped by the frame the
		// estimated head top lies above the frame edge (a negative row), and
		// the placement below must know that.
		let headTopRow = CGFloat(height) * (1 - (faceBox.maxY + (Self.headInflation - 1) * faceBox.height))
		let headCenterColumn = faceBox.midX * CGFloat(width)

		func quantized(_ ideal: CGFloat, atLeast floor: Int) -> Int {
			let needed = max(Int(ideal.rounded(.up)), floor)
			return (needed + Self.canvasQuantum - 1) / Self.canvasQuantum * Self.canvasQuantum
		}
		let canvasWidth = quantized(Self.adaptiveWidthInHeads * headHeight, atLeast: width)
		let canvasHeight = quantized(Self.adaptiveHeightInHeads * headHeight, atLeast: height)

		if self.adaptiveCanvas == nil
			|| CVPixelBufferGetWidth(self.adaptiveCanvas!) != canvasWidth
			|| CVPixelBufferGetHeight(self.adaptiveCanvas!) != canvasHeight {
			var canvas: CVPixelBuffer?
			CVPixelBufferCreate(kCFAllocatorDefault, canvasWidth, canvasHeight, kCVPixelFormatType_32BGRA, nil, &canvas)
			self.adaptiveCanvas = canvas
		}
		guard let canvas = self.adaptiveCanvas else {
			if !self.didLogAdaptiveCanvasFailure {
				self.didLogAdaptiveCanvasFailure = true
				Self.logger.error("Could not allocate the adaptive canvas; the adaptive pipeline is off")
			}
			return nil
		}

		// Head top at the anchor; the frame's top row lands wherever that
		// puts it, negative meaning the rows above (the ceiling) are cropped.
		// Capped at flush: when the head top sits at or above the frame edge
		// (the user so close the forehead is clipped), the frame goes flush
		// with the canvas top. A head cropped by the image edge is ordinary
		// photography; a head ending mid-image under a black gap is not.
		let destinationTop = min(Int((Self.headTopAnchor * CGFloat(canvasHeight) - headTopRow).rounded()), 0)
		let destinationLeft = max(0, min(Int((CGFloat(canvasWidth) / 2 - headCenterColumn).rounded()), canvasWidth - width))

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

		// Opaque black, as on the fixed canvas.
		var black: [UInt8] = [0, 0, 0, 255]
		memset_pattern4(canvasBase, &black, CVPixelBufferGetDataSize(canvas))

		let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
		let canvasBytesPerRow = CVPixelBufferGetBytesPerRow(canvas)
		let rowBytes = min(sourceBytesPerRow, canvasBytesPerRow - destinationLeft * 4, width * 4)
		let firstRow = max(0, -destinationTop)
		let lastRow = min(height, canvasHeight - destinationTop)
		guard firstRow < lastRow, rowBytes > 0 else { return nil }
		for row in firstRow..<lastRow {
			memcpy(
				canvasBase + (destinationTop + row) * canvasBytesPerRow + destinationLeft * 4,
				sourceBase + row * sourceBytesPerRow,
				rowBytes
			)
		}

		let frameRect = CGRect(
			x: CGFloat(destinationLeft) / CGFloat(canvasWidth),
			y: CGFloat(canvasHeight - destinationTop - height) / CGFloat(canvasHeight),
			width: CGFloat(width) / CGFloat(canvasWidth),
			height: CGFloat(height) / CGFloat(canvasHeight)
		)
		return (canvas, frameRect)
	}

	//: ## Detection

	/// Runs on the analysis queue. Detects the body pose and measures the
	/// shoulder distance, aspect-correct, in pixels and as a fraction of the
	/// frame width (the scale-invariant form the VISION.md metrics build on),
	/// plus the average eye height when the eye joints clear the confidence
	/// floor. Works on either canvas; the reported width x height reveals
	/// which one produced a measurement. `frameRect` is the camera frame's
	/// placement within the analyzed image, Vision-normalized (it can extend
	/// past the unit square when the frame is partially cropped); results
	/// are remapped through it into frame coordinates so both pipelines
	/// report comparable, frame-relative values.
	fileprivate nonisolated static func analyzeShoulders(in pixelBuffer: CVPixelBuffer, frameRect: CGRect) -> ShoulderAnalysis {
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
		// both axes rescale through the frame's placement rect.
		func remapToFrame(_ point: VNRecognizedPoint) -> CGPoint {
			return CGPoint(
				x: (point.x - frameRect.minX) / frameRect.width,
				y: (point.y - frameRect.minY) / frameRect.height
			)
		}

		// The shoulder line's height in canvas pixels, shared by both slouch
		// variants below.
		let shoulderHeightPixels = ((left.y + right.y) / 2 - frameRect.minY) * height

		// Average eye height, reported relative to the camera frame (0 =
		// frame bottom, 1 = frame top), remapped through the placement rect.
		var eyeHeightFraction: CGFloat?
		var eyeHeightPixels: CGFloat?
		var slouchRatio: CGFloat?
		var personHeightFraction: CGFloat?
		var eyeEarWidthRatio: CGFloat?
		var leftEyePoint: CGPoint?
		var rightEyePoint: CGPoint?

		// Fetched before the eye block so the head-pose ratio below can pair
		// each eye with the ear on its own side; the ear-anchored slouch
		// ratio further down uses the same two points.
		let leftEar = (try? observation.recognizedPoint(.leftEar)).flatMap { $0.confidence > Self.minimumJointConfidence ? $0 : nil }
		let rightEar = (try? observation.recognizedPoint(.rightEar)).flatMap { $0.confidence > Self.minimumJointConfidence ? $0 : nil }

		if
			let leftEye = try? observation.recognizedPoint(.leftEye),
			let rightEye = try? observation.recognizedPoint(.rightEye),
			leftEye.confidence > Self.minimumJointConfidence,
			rightEye.confidence > Self.minimumJointConfidence
		{
			leftEyePoint = remapToFrame(leftEye)
			rightEyePoint = remapToFrame(rightEye)
			let fraction = ((leftEye.y + rightEye.y) / 2 - frameRect.minY) / frameRect.height
			eyeHeightFraction = fraction
			eyeHeightPixels = fraction * height * frameRect.height

			// Aspect-correct eye separation in pixels, the head-scale term
			// the ratio below is built from.
			let eyeDistanceInPixels = hypot((leftEye.x - rightEye.x) * width, (leftEye.y - rightEye.y) * height)

			// Candidate head-pose signal, telemetry only for now
			// (PITCH_TUNING.md). Both terms are head-scale, so camera
			// distance cancels and only pose moves it: turning the head
			// shortens the eye separation while the eye-to-ear distance
			// swings toward the head's depth, so the ratio falls from both
			// ends at once. Same-side pairs only, since the far ear
			// occludes on a turn - which is exactly when this matters - and
			// the longer pair wins when both sides are visible.
			let eyeEarDistances = [(leftEar, leftEye), (rightEar, rightEye)].compactMap { ear, eye -> CGFloat? in
				guard let ear else { return nil }
				return hypot((ear.x - eye.x) * width, (ear.y - eye.y) * height)
			}
			if let eyeEarDistance = eyeEarDistances.max(), eyeEarDistance > 0 {
				eyeEarWidthRatio = eyeDistanceInPixels / eyeEarDistance
			}

			// The slouch ratio from VISION.md: the vertical drop from eye
			// level to shoulder level, over shoulder width. Heights are
			// vertical only, so head tilt does not pollute it, and the
			// division makes it scale-invariant: chair and laptop moves
			// cancel out. Smaller means more slouch.
			slouchRatio = (eyeHeightPixels! - shoulderHeightPixels) / distanceInPixels

			// Rough frame occupancy: the body runs off the frame's bottom
			// edge, so the occupied share is frame bottom to head top. The
			// head top is not a joint; estimate it as half the eye-to-
			// shoulder drop above the eyes.
			let shoulderFraction = ((left.y + right.y) / 2 - frameRect.minY) / frameRect.height
			personHeightFraction = min(1, fraction + (fraction - shoulderFraction) / 2)
		}

		// The ear-anchored slouch ratio: the same vertical drop measured
		// from the ears. Ears sit on the head's pitch axis, so a downward
		// glance at the keyboard moves the eyes but not this ratio; it is
		// the preferred evaluation metric (see spec.md). One confident ear
		// is enough - both sit at essentially the same height.
		var earSlouchRatio: CGFloat?
		let ears = [leftEar, rightEar].compactMap { $0 }
		if !ears.isEmpty {
			let earY = ears.map(\.y).reduce(0, +) / CGFloat(ears.count)
			earSlouchRatio = ((earY - frameRect.minY) * height - shoulderHeightPixels) / distanceInPixels
		}

		return .measured(ShoulderMeasurement(
			// Fraction of the camera frame's width, not the canvas's, so the
			// value stays meaningful when the canvas adds side padding.
			fractionOfWidth: distanceInPixels / (width * frameRect.width),
			distanceInPixels: distanceInPixels,
			width: Int(width),
			height: Int(height),
			leftConfidence: left.confidence,
			rightConfidence: right.confidence,
			eyeHeightFraction: eyeHeightFraction,
			eyeHeightPixels: eyeHeightPixels,
			slouchRatio: slouchRatio,
			earSlouchRatio: earSlouchRatio,
			personHeightFraction: personHeightFraction,
			eyeEarWidthRatio: eyeEarWidthRatio,
			shoulderTiltDegrees: tiltDegrees,
			joints: SRPostureJoints(
				leftShoulder: remapToFrame(left),
				rightShoulder: remapToFrame(right),
				leftEye: leftEyePoint,
				rightEye: rightEyePoint,
				leftEar: leftEar.map(remapToFrame),
				rightEar: rightEar.map(remapToFrame)
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

	/// The same drop measured from the ears (one confident ear suffices),
	/// immune to head pitch; the preferred evaluation metric. Nil when
	/// neither ear cleared the confidence floor.
	let earSlouchRatio: CGFloat?

	/// Rough share of the frame's height the person occupies, from the
	/// frame's bottom edge (the body runs off it) to the estimated head
	/// top (half the eye-to-shoulder drop above the eyes). Nil whenever
	/// the eye heights are.
	let personHeightFraction: CGFloat?

	/// Eye separation over the eye-to-ear distance on the same side, both
	/// head-scale, so camera distance cancels. Telemetry only for now: a
	/// candidate head-pose signal for loosening the strictness when the
	/// head is turned or tilted away (PITCH_TUNING.md). Nil unless both
	/// eyes and at least one same-side ear cleared the confidence floor.
	let eyeEarWidthRatio: CGFloat?

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
	/// Adaptive pipeline only: no face box to build the canvas from.
	case noFace
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
/// (origin bottom-left). Eyes and ears are each nil below the confidence
/// floor.
struct SRPostureJoints: Sendable {
	let leftShoulder: CGPoint
	let rightShoulder: CGPoint
	let leftEye: CGPoint?
	let rightEye: CGPoint?
	let leftEar: CGPoint?
	let rightEar: CGPoint?
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


/// One analyzed frame's readings: shoulder
/// width as a fraction of the frame, the slouch ratio (nil without eyes),
/// its ear-anchored variant (nil without an ear), and the joints. All nil
/// when nothing measured.
struct SRPostureFrameSample: Sendable {
	let shoulderWidthFraction: CGFloat?
	let slouchRatio: CGFloat?
	let earSlouchRatio: CGFloat?
	/// Head pitch from the face detector, radians, camera-relative; nil
	/// while no face is tracked. Consumed by the calibration gaze capture.
	let facePitch: CGFloat?
	let joints: SRPostureJoints?
}


/// One pipeline's state within a logging window: the best usable measurement,
/// else the best sub-threshold confidence pair as the most informative
/// failure.
fileprivate struct WindowAccumulator {
	var bestMeasurement: ShoulderMeasurement?
	var bestLowConfidence: (left: Float, right: Float)?
	var sawNoFace = false

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
		case .noFace:
			self.sawNoFace = true
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
		return self.sawNoFace ? "no face" : "no body"
	}
}
