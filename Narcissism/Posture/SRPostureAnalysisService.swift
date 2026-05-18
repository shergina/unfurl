//
//  SRPostureAnalysisService.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
@preconcurrency import AVFoundation
import Vision
import os


/// The first buildable increment of the posture-tracking vision (VISION.md):
/// a measurement probe that taps the shared capture session, runs Apple
/// Vision body-pose detection off-main, and logs the shoulder distance,
/// average eye height, and slouch ratio once per second, plus a warning
/// line whenever the ratio breaches the hardcoded good-posture baseline.
/// No UI, settings, or nudges yet; see spec.md.
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

	fileprivate var output: AVCaptureVideoDataOutput?

	/// The serial queue the sample-buffer delegate and Vision work run on;
	/// every nonisolated(unsafe) property below is touched only here.
	fileprivate let analysisQueue = DispatchQueue(label: "narcissism.posture-analysis")

	/// Attaches a video data output to the shared session and begins the
	/// once-per-second shoulder-distance log. The attached output holds the
	/// session up for as long as the app runs, independent of any preview.
	/// Idempotent.
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

		Task {
			do {
				try await self.cameraService.attachOutput(output).value
			} catch {
				// attachOutput already surfaced the failure through onState;
				// note it here too so the absent measurements are explained
				// in the same log the reader is watching.
				Self.logger.error("Posture probe could not attach to the camera: \(error.localizedDescription, privacy: .public)")
				self.output = nil
			}
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
	fileprivate nonisolated static let minimumJointConfidence: Float = 0.3

	/// The user's own good-posture slouch ratio, measured sitting straight
	/// on 2026-07-21. Hardcoded until the calibration flow in VISION.md
	/// exists; only valid for the same user, camera, and rough distance.
    /// Masha's slouch ratio, CHANGE LATER tO ADJUST FOR USER:
	fileprivate nonisolated static let baselineSlouchRatio: CGFloat = 0.616

	/// Windows whose slouch ratio drops more than this fraction below the
	/// baseline log a slouching warning (the ~10 percent tolerance band
	/// VISION.md starts from). Ratios above baseline are sitting tall, never
	/// an alert.
	fileprivate nonisolated static let slouchTolerance: CGFloat = 0.10

	// The current logging window. Touched only on the (serial) analysis queue.
	fileprivate nonisolated(unsafe) var lastAnalysisTime = CMTime.invalid
	fileprivate nonisolated(unsafe) var windowStartTime = CMTime.invalid
	fileprivate nonisolated(unsafe) var windowFrameCount = 0
	fileprivate nonisolated(unsafe) var plainWindow = WindowAccumulator()
	fileprivate nonisolated(unsafe) var paddedWindow = WindowAccumulator()

	nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if self.lastAnalysisTime.isValid {
			let elapsed = timestamp - self.lastAnalysisTime
			if elapsed < .zero {
				// The timeline restarted; drop the partial window.
				self.resetWindow()
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

		self.plainWindow.merge(Self.analyzeShoulders(in: pixelBuffer, frameFraction: 1))
		if let canvas = self.paddedCanvasFilled(from: pixelBuffer) {
			self.paddedWindow.merge(Self.analyzeShoulders(in: canvas, frameFraction: 1 / Self.paddingFactor))
		}

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

		// Slouch alert, evaluated on whichever pipeline measured (padded is
		// the one that works at laptop framing; plain is the fallback). One
		// evaluation per window, no debounce yet: immediate per-second
		// feedback is the point of the current experiment.
		if
			let ratio = self.paddedWindow.bestMeasurement?.slouchRatio ?? self.plainWindow.bestMeasurement?.slouchRatio,
			ratio < Self.baselineSlouchRatio * (1 - Self.slouchTolerance)
		{
			let percentBelow = Int(((Self.baselineSlouchRatio - ratio) / Self.baselineSlouchRatio * 100).rounded())
			Self.logger.warning("Slouching: ratio \(String(format: "%.3f", ratio), privacy: .public) is \(percentBelow, privacy: .public) percent below your \(String(format: "%.3f", Self.baselineSlouchRatio), privacy: .public) baseline")
		}
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

		// Average eye height, reported relative to the camera frame (0 =
		// frame bottom, 1 = frame top). The frame is the top `frameFraction`
		// of the analyzed image, so image y rescales around the top edge;
		// on the raw frame the remap is the identity.
		var eyeHeightFraction: CGFloat?
		var eyeHeightPixels: CGFloat?
		var slouchRatio: CGFloat?
		if
			let leftEye = try? observation.recognizedPoint(.leftEye),
			let rightEye = try? observation.recognizedPoint(.rightEye),
			leftEye.confidence > Self.minimumJointConfidence,
			rightEye.confidence > Self.minimumJointConfidence
		{
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
			slouchRatio: slouchRatio
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

	/// The weaker of the two joints; the per-window winner maximizes this.
	var weakestConfidence: Float { min(self.leftConfidence, self.rightConfidence) }
}


fileprivate enum ShoulderAnalysis {
	case measured(ShoulderMeasurement)
	case lowConfidence(left: Float, right: Float)
	case noBody
	case failed
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
			return line
		}
		if let low = self.bestLowConfidence {
			return String(format: "low confidence, best L %.2f R %.2f", low.left, low.right)
		}
		return "no body"
	}
}
