//
//  SRPostureCalibrationSession.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine
import os


/// The calibration state machine, no AppKit: eats the probe's per-frame
/// samples, publishes the phase the window renders. Flow: position ->
/// Begin -> 3-2-1 -> 5 s of upright sampling (pauses when you vanish,
/// 10 s hard cap) -> quality gates -> the upright median is reported
/// (onUprightCaptured, saved right away) -> slouchReady: the slouch
/// instruction, waiting for Begin -> 3-2-1, the same 5 s capture and
/// gates plus the span gates -> done carries both medians. A failed
/// slouch capture returns to slouchReady with a failure line, so an
/// absent user never loops. See spec.md.
@MainActor
final class SRPostureCalibrationSession {

	enum Guidance: Equatable {
		case notVisible       // no confident shoulders this frame
		case faceNotVisible   // shoulders but no eyes, so no slouch ratio
		case tooFar           // shoulders too small a fraction of the frame
		case good
	}

	enum Failure: Equatable {
		case timedOut          // the wall-clock cap elapsed mid-capture
		case unstableReadings  // too few samples, too much spread, or nonsense
		case notSlouched       // the slouch capture read at or above upright
	}

	enum Pose: Equatable {
		case upright
		case slouched
	}

	enum Phase: Equatable {
		case positioning(guidance: Guidance, failure: Failure?)
		/// The gate before the slouch pose: entered after the upright
		/// capture (and again, with the failure, after a failed slouch
		/// capture); Begin arms the countdown.
		case slouchReady(failure: Failure?)
		case countingDown(pose: Pose, remaining: Int)
		case capturing(pose: Pose, sampledSeconds: Double, paused: Bool)
		/// slouched is nil for a single-pose run (hybrid mode: an anchor
		/// already exists, so the span is derived, not demonstrated).
		case done(baseline: CGFloat, slouched: CGFloat?)
	}

	/// Whether this run includes the slouch pose. True exactly when no
	/// anchor exists yet (the very first calibration measures the span
	/// once, ever); the owner sets it before the session starts. Every
	/// later camera runs single-pose and derives its span from the anchor
	/// via the eye:shoulder ratio (see SRSettings.postureEffectiveSlouchSpan).
	var includesSlouchPose = true

	/// Fires the moment the upright capture passes its gates, with the
	/// upright median and the median eye:shoulder ratio (nil if the eyes
	/// never measured, which the gates make unlikely); the owner saves
	/// both right away (a flow abandoned mid-slouch still keeps a valid
	/// single-point baseline).
	var onUprightCaptured: ((CGFloat, CGFloat?) -> Void)?

	/// Calibration outcomes are tuning telemetry (the span floor and the
	/// depth ladder are tuned from these lines), same category as the
	/// probe's per-window log.
	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.narcissism", category: "Posture")

	let onPhase = CurrentValueSubject<Phase, Never>(.positioning(guidance: .notVisible, failure: nil))

	/// Sampling time per frame. Coupled to the probe's 4 fps
	/// minimumAnalysisInterval; change both together.
	fileprivate static let secondsPerFrame = 0.25
	/// The capture target; also the progress indicator's scale.
	static let requiredSampledSeconds = 5.0
	// ~1 s of lost detection pauses the capture; ~1 s of continuous
	// detection resumes it (unsampled - the user is still settling in).
	fileprivate static let pauseAfterConsecutiveUnusable = 4
	fileprivate static let resumeAfterConsecutiveUsable = 4
	/// Hard cap from capture start; also the exit if frames stop entirely.
	fileprivate static let captureWallClockCap: TimeInterval = 10
	fileprivate static let countdownSeconds = 3
	// Completion gates: enough samples, low spread (more than this wasn't
	// one held pose), sane median.
	fileprivate static let minimumSampleCount = 12
	fileprivate static let maximumSampleStandardDeviation: CGFloat = 0.04
	fileprivate static let sanityRange: ClosedRange<CGFloat> = 0.2...1.5
	/// The slouched median must sit at least this far below the upright
	/// one. The gate's only job is "did you move at all", not "was it a
	/// big slouch": both sides are medians of 12+ samples, far tighter
	/// than the per-frame stddev gate, so this comfortably clears noise
	/// while accepting a low-gain camera's honest slouch. (History: 0.08
	/// on day one - "twice the stddev gate" - rejected real slouches on
	/// the laptop camera, whose whole span is ~0.05-0.10 precisely
	/// because its gain is low; a fixed floor sized for the monitor's
	/// gain repeated the per-camera mistake the span exists to fix.)
	fileprivate static let minimumSlouchSpan: CGFloat = 0.04
	/// Narrower shoulders than this fraction of the frame = too far away.
	fileprivate static let minimumShoulderWidthFraction: CGFloat = 0.15

	fileprivate var samples: [CGFloat] = []
	// The eye:shoulder width ratio per usable frame, collected during the
	// upright capture only (the geometry probe belongs to the upright pose,
	// like the baseline it rides with).
	fileprivate var rhoSamples: [CGFloat] = []
	fileprivate var sampledSeconds = 0.0
	fileprivate var consecutiveUnusable = 0
	fileprivate var consecutiveUsable = 0
	fileprivate var paused = false
	fileprivate var capturePose: Pose = .upright
	fileprivate var uprightMedian: CGFloat?
	fileprivate var countdownTimer: Timer?
	fileprivate var capTimer: Timer?

	/// Feed every published frame sample in.
	func ingest(_ sample: SRPostureFrameSample?) {
		switch self.onPhase.value {
		case .positioning(_, let failure):
			self.onPhase.send(.positioning(guidance: Self.guidance(for: sample), failure: failure))
		case .capturing:
			self.ingestWhileCapturing(sample)
		case .countingDown, .done, .slouchReady:
			// The countdown ignores detection loss; capture pauses right
			// away if the user is still gone. slouchReady waits for Begin -
			// framing was already established by the upright capture.
			break
		}
	}

	/// Honored while positioned well (starts the upright pass; the Begin
	/// button mirrors this) and at slouchReady (arms the slouch pass).
	func begin() {
		switch self.onPhase.value {
		case .positioning(guidance: .good, _):
			self.startCountdown(pose: .upright)
		case .slouchReady:
			self.startCountdown(pose: .slouched)
		default:
			break
		}
	}

	/// Back to positioning for a full two-pose pass; only honored in done.
	func redo() {
		guard case .done = self.onPhase.value else { return }
		self.samples = []
		self.uprightMedian = nil
		self.onPhase.send(.positioning(guidance: .notVisible, failure: nil))
	}

	/// Stops the timers; called on window close.
	func invalidate() {
		self.countdownTimer?.invalidate()
		self.countdownTimer = nil
		self.capTimer?.invalidate()
		self.capTimer = nil
	}

	fileprivate static func guidance(for sample: SRPostureFrameSample?) -> Guidance {
		guard let sample, let width = sample.shoulderWidthFraction else { return .notVisible }
		if sample.slouchRatio == nil { return .faceNotVisible }
		if width < Self.minimumShoulderWidthFraction { return .tooFar }
		return .good
	}

	//: ## Countdown

	fileprivate func startCountdown(pose: Pose) {
		self.capturePose = pose
		self.onPhase.send(.countingDown(pose: pose, remaining: Self.countdownSeconds))
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in self?.tickCountdown() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.countdownTimer = timer
	}

	fileprivate func tickCountdown() {
		guard case .countingDown(let pose, let remaining) = self.onPhase.value else { return }
		if remaining > 1 {
			self.onPhase.send(.countingDown(pose: pose, remaining: remaining - 1))
		} else {
			self.countdownTimer?.invalidate()
			self.countdownTimer = nil
			self.startCapture()
		}
	}

	//: ## Capture

	fileprivate func startCapture() {
		self.samples = []
		if self.capturePose == .upright {
			self.rhoSamples = []
		}
		self.sampledSeconds = 0
		self.consecutiveUnusable = 0
		self.consecutiveUsable = 0
		self.paused = false
		self.onPhase.send(.capturing(pose: self.capturePose, sampledSeconds: 0, paused: false))

		let timer = Timer(timeInterval: Self.captureWallClockCap, repeats: false) { [weak self] _ in
			Task { @MainActor [weak self] in self?.abortCapture(with: .timedOut) }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.capTimer = timer
	}

	fileprivate func ingestWhileCapturing(_ sample: SRPostureFrameSample?) {
		let ratio = sample?.slouchRatio
		if ratio != nil {
			self.consecutiveUsable += 1
			self.consecutiveUnusable = 0
		} else {
			self.consecutiveUnusable += 1
			self.consecutiveUsable = 0
		}

		if self.paused {
			if self.consecutiveUsable >= Self.resumeAfterConsecutiveUsable {
				self.paused = false
				self.onPhase.send(.capturing(pose: self.capturePose, sampledSeconds: self.sampledSeconds, paused: false))
			}
			return
		}

		if self.consecutiveUnusable >= Self.pauseAfterConsecutiveUnusable {
			// Sustained loss: pause, and refund the lead-in frames that
			// ticked the clock while the user was already gone.
			self.paused = true
			self.sampledSeconds = max(0, self.sampledSeconds - Double(Self.pauseAfterConsecutiveUnusable - 1) * Self.secondsPerFrame)
			self.onPhase.send(.capturing(pose: self.capturePose, sampledSeconds: self.sampledSeconds, paused: true))
			return
		}

		self.sampledSeconds += Self.secondsPerFrame
		if let ratio {
			self.samples.append(ratio)
			if self.capturePose == .upright, let rho = sample?.eyeShoulderWidthRatio {
				self.rhoSamples.append(rho)
			}
		}

		// Publish the final value too, so the bar gets its "full" target
		// before the done phase lands.
		self.onPhase.send(.capturing(pose: self.capturePose, sampledSeconds: self.sampledSeconds, paused: false))
		if self.sampledSeconds >= Self.requiredSampledSeconds {
			self.finishCapture()
		}
	}

	/// A failed capture rests at the failed pose: positioning for upright,
	/// slouchReady for slouched (a good upright capture is never discarded,
	/// and slouchReady requires Begin, so an absent user never loops).
	fileprivate func abortCapture(with failure: Failure) {
		guard case .capturing = self.onPhase.value else { return }
		self.invalidate()
		self.samples = []
		switch self.capturePose {
		case .upright:
			// The guidance refreshes on the very next ingested frame.
			self.onPhase.send(.positioning(guidance: .notVisible, failure: failure))
		case .slouched:
			self.onPhase.send(.slouchReady(failure: failure))
		}
	}

	fileprivate func finishCapture() {
		self.capTimer?.invalidate()
		self.capTimer = nil

		let sorted = self.samples.sorted()
		let count = sorted.count
		guard count >= Self.minimumSampleCount else {
			self.abortFinishedCapture(with: .unstableReadings)
			return
		}

		// Median, not mean: one flickery Vision frame drags a mean of ~20
		// samples noticeably.
		let median = count % 2 == 0
			? (sorted[count / 2 - 1] + sorted[count / 2]) / 2
			: sorted[count / 2]

		let mean = sorted.reduce(0, +) / CGFloat(count)
		let variance = sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(count)
		guard variance.squareRoot() <= Self.maximumSampleStandardDeviation, Self.sanityRange.contains(median) else {
			self.abortFinishedCapture(with: .unstableReadings)
			return
		}

		switch self.capturePose {
		case .upright:
			self.uprightMedian = median
			let rho = Self.median(of: self.rhoSamples)
			let rhoText = rho.map { String(format: "%.4f", $0) } ?? "n/a"
			Self.logger.log("Calibration upright captured: median \(String(format: "%.3f", median), privacy: .public), rho \(rhoText, privacy: .public) (\(count, privacy: .public) samples)")
			self.onUprightCaptured?(median, rho)

			if self.includesSlouchPose {
				// Rest at slouchReady: the instruction explains the slouch
				// pose and Begin starts it when the user is ready. (An
				// auto-started countdown was tried first: it landed before
				// the user realized what was being asked.)
				self.onPhase.send(.slouchReady(failure: nil))
			} else {
				// Hybrid mode: the anchor exists, the span is derived from
				// rho, and this run is complete after the one pose.
				Self.logger.log("Calibration finished (single pose): baseline \(String(format: "%.3f", median), privacy: .public), rho \(rhoText, privacy: .public)")
				self.onPhase.send(.done(baseline: median, slouched: nil))
			}

		case .slouched:
			// The span gates: a "slouch" at or above upright, or closer to it
			// than measurement noise, is not a slouch.
			guard let upright = self.uprightMedian, upright - median >= Self.minimumSlouchSpan else {
				let upright = self.uprightMedian ?? 0
				Self.logger.warning("Calibration slouch rejected: median \(String(format: "%.3f", median), privacy: .public) vs upright \(String(format: "%.3f", upright), privacy: .public), span \(String(format: "%.3f", upright - median), privacy: .public) under floor \(String(format: "%.3f", Self.minimumSlouchSpan), privacy: .public)")
				self.abortFinishedCapture(with: .notSlouched)
				return
			}
			Self.logger.log("Calibration finished: upright \(String(format: "%.3f", upright), privacy: .public), slouched \(String(format: "%.3f", median), privacy: .public), span \(String(format: "%.3f", upright - median), privacy: .public)")
			self.onPhase.send(.done(baseline: upright, slouched: median))
		}
	}

	fileprivate static func median(of values: [CGFloat]) -> CGFloat? {
		guard !values.isEmpty else { return nil }
		let sorted = values.sorted()
		let count = sorted.count
		return count % 2 == 0 ? (sorted[count / 2 - 1] + sorted[count / 2]) / 2 : sorted[count / 2]
	}

	/// A capture that reached its 5 seconds but failed the quality gates.
	fileprivate func abortFinishedCapture(with failure: Failure) {
		self.samples = []
		switch self.capturePose {
		case .upright:
			self.onPhase.send(.positioning(guidance: .notVisible, failure: failure))
		case .slouched:
			self.onPhase.send(.slouchReady(failure: failure))
		}
	}

}
