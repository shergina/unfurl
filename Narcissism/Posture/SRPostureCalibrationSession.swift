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
/// Begin -> 3-2-1 -> 5 s of middle-gaze upright sampling (pauses when
/// you vanish, 10 s hard cap) -> quality gates -> the upright median is
/// reported (onUprightCaptured, saved right away) -> the gaze probes,
/// each resting for Begin: directly ahead first (theta), then the
/// bottom of the screen only when theta says the camera is near or
/// above the gaze line (the high baseline leaves a wide down-gaze
/// envelope below it, worth measuring) - the same capture machinery;
/// the combined deltas ride onGazeCaptured once, after the last probe
/// (failures skip forward) ->
/// then slouchReady: the slouch instruction, waiting for Begin -> 3-2-1,
/// the same 5 s capture and gates plus the span gates -> done carries
/// both medians. A failed slouch capture returns to slouchReady with a
/// failure line, so an absent user never loops. See spec.md.
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
		/// The gaze probe: same capture machinery, eyes on the horizon
		/// instead of the screen's middle. Auxiliary - a failure skips
		/// forward, never blocks the flow.
		case lookingAhead
	}

	enum Phase: Equatable {
		case positioning(guidance: Guidance, failure: Failure?)
		/// The gate before the gaze probe, right after the upright
		/// capture; Begin arms it. Carries no failure: a failed gaze
		/// capture skips forward instead of resting.
		case lookAheadReady
		/// The gate before the slouch pose: entered after the gaze probe
		/// (and again, with the failure, after a failed slouch capture);
		/// Begin arms the countdown.
		case slouchReady(failure: Failure?)
		case countingDown(pose: Pose, remaining: Int)
		case capturing(pose: Pose, sampledSeconds: Double, paused: Bool)
		/// slouched is nil for a single-pose run (hybrid mode: an anchor
		/// already exists, so the span is derived, not demonstrated). The
		/// ear pair rides along when the ears cleared the sample bar; a
		/// nonsense ear span (at or above upright) drops the slouched half.
		case done(baseline: CGFloat, slouched: CGFloat?, earBaseline: CGFloat?, earSlouched: CGFloat?)
	}

	/// Whether this run includes the slouch pose. True exactly when no
	/// anchor exists yet (the very first calibration measures the span
	/// once, ever); the owner sets it before the session starts. Every
	/// later camera runs single-pose and derives its span from the anchor
	/// via the eye:shoulder ratio (see SRSettings.postureEffectiveSlouchSpan).
	var includesSlouchPose = true

	/// Fires the moment the upright capture passes its gates, with the
	/// upright median, the median eye:shoulder ratio (nil if the eyes
	/// never measured, which the gates make unlikely), and the upright
	/// ear median (nil when the ears fell short of the sample bar -
	/// headphones, a hood); the owner saves all three right away (a flow
	/// abandoned mid-slouch still keeps a valid single-point baseline).
	var onUprightCaptured: ((CGFloat, CGFloat?, CGFloat?) -> Void)?

	/// Fires once after the look-ahead probe (or its skip) with both
	/// probes' deltas from the middle-of-screen baseline - the per-camera
	/// inputs for the piecewise strictness (PITCH_TUNING.md). Each field
	/// nil when its capture fell short or was skipped.
	var onGazeCaptured: ((SRGazeProbeResult) -> Void)?

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
	// The ear-anchored ratio per frame, both poses; the ear median counts
	// only when it clears the same sample bar as the eye one, so an entry
	// never carries a flimsy ear baseline.
	fileprivate var earSamples: [CGFloat] = []
	fileprivate var uprightEarMedian: CGFloat?
	// Face pitch per frame (radians), collected during every capture; the
	// upright (middle-gaze) median is the reference both probes
	// difference against.
	fileprivate var pitchSamples: [CGFloat] = []
	fileprivate var uprightPitchMedian: CGFloat?
	// Accumulates both probes' deltas across the run; fired once after
	// the look-ahead stage.
	fileprivate var probeResult = SRGazeProbeResult()
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
		case .countingDown, .done, .slouchReady, .lookAheadReady:
			// The countdown ignores detection loss; capture pauses right
			// away if the user is still gone. The ready gates wait for
			// Begin - framing was already established by the upright
			// capture.
			break
		}
	}

	/// Honored while positioned well (starts the upright pass; the Begin
	/// button mirrors this) and at slouchReady (arms the slouch pass).
	func begin() {
		switch self.onPhase.value {
		case .positioning(guidance: .good, _):
			self.startCountdown(pose: .upright)
		case .lookAheadReady:
			self.startCountdown(pose: .lookingAhead)
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
		self.earSamples = []
		self.pitchSamples = []
		self.uprightMedian = nil
		self.uprightEarMedian = nil
		self.uprightPitchMedian = nil
		self.probeResult = SRGazeProbeResult()
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
		self.earSamples = []
		self.pitchSamples = []
		if self.capturePose == .upright {
			self.rhoSamples = []
			self.probeResult = SRGazeProbeResult()
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
		// Ears and pitch ride along independently of the eye gate; whether
		// their medians count is decided at finish, against the same
		// sample bar.
		if let earRatio = sample?.earSlouchRatio {
			self.earSamples.append(earRatio)
		}
		if let pitch = sample?.facePitch {
			self.pitchSamples.append(pitch)
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
	/// and slouchReady requires Begin, so an absent user never loops). The
	/// gaze probe is the exception: auxiliary data, so its failures skip
	/// forward instead of resting or retrying.
	fileprivate func abortCapture(with failure: Failure) {
		guard case .capturing = self.onPhase.value else { return }
		self.invalidate()
		self.samples = []
		switch self.capturePose {
		case .upright:
			// The guidance refreshes on the very next ingested frame.
			self.onPhase.send(.positioning(guidance: .notVisible, failure: failure))
		case .lookingAhead:
			Self.logger.log("Calibration gaze capture skipped (\(String(describing: failure), privacy: .public))")
			self.finishGazeProbes()
		case .slouched:
			self.onPhase.send(.slouchReady(failure: failure))
		}
	}

	/// The flow once the gaze probe is over, however it ended: report
	/// the collected deltas, then the slouch pose for a two-pose run, else
	/// done - the upright result was already saved by onUprightCaptured.
	fileprivate func finishGazeProbes() {
		self.onGazeCaptured?(self.probeResult)
		if self.includesSlouchPose {
			// Rest at slouchReady: the instruction explains the slouch
			// pose and Begin starts it when the user is ready. (An
			// auto-started countdown was tried first: it landed before
			// the user realized what was being asked.)
			self.onPhase.send(.slouchReady(failure: nil))
		} else {
			guard let upright = self.uprightMedian else { return }
			// Hybrid mode: the anchor exists, the spans are derived from
			// rho, and this run is complete.
			Self.logger.log("Calibration finished (single pose): baseline \(String(format: "%.3f", upright), privacy: .public)")
			self.onPhase.send(.done(baseline: upright, slouched: nil, earBaseline: self.uprightEarMedian, earSlouched: nil))
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

		// The ear median counts only when the ears were seen as reliably as
		// the eyes; short of the bar the entry simply has no ear pair and
		// evaluation stays on the eye metric.
		let earMedian = self.earSamples.count >= Self.minimumSampleCount ? Self.median(of: self.earSamples) : nil
		let earText = earMedian.map { String(format: "%.3f", $0) } ?? "n/a"

		switch self.capturePose {
		case .upright:
			self.uprightMedian = median
			self.uprightEarMedian = earMedian
			self.uprightPitchMedian = self.pitchSamples.count >= Self.minimumSampleCount ? Self.median(of: self.pitchSamples) : nil
			self.probeResult.uprightPitch = self.uprightPitchMedian.map { $0 * 180 / .pi }
			let rho = Self.median(of: self.rhoSamples)
			let rhoText = rho.map { String(format: "%.4f", $0) } ?? "n/a"
			Self.logger.log("Calibration upright captured: median \(String(format: "%.3f", median), privacy: .public), ear \(earText, privacy: .public), rho \(rhoText, privacy: .public) (\(count, privacy: .public) samples, \(self.earSamples.count, privacy: .public) ear)")
			self.onUprightCaptured?(median, rho, earMedian)

			// The look-ahead probe follows every upright capture.
			self.onPhase.send(.lookAheadReady)

		case .lookingAhead:
			// Ahead deltas vs the middle-gaze baseline, per metric, plus
			// the face-pitch swing in degrees: theta, the direct per-camera
			// angle measurement (PITCH_TUNING.md).
			let text = { (value: CGFloat?) in value.map { String(format: "%.3f", $0) } ?? "n/a" }
			self.probeResult.aheadEyeDelta = self.uprightMedian.map { median - $0 }
			self.probeResult.aheadEarDelta = self.uprightEarMedian.flatMap { upright in earMedian.map { $0 - upright } }
			let aheadPitch = self.pitchSamples.count >= Self.minimumSampleCount ? Self.median(of: self.pitchSamples) : nil
			self.probeResult.aheadPitchDelta = self.uprightPitchMedian.flatMap { upright in aheadPitch.map { ($0 - upright) * 180 / .pi } }
			Self.logger.log("Calibration gaze captured: eye delta \(text(self.probeResult.aheadEyeDelta), privacy: .public), ear delta \(text(self.probeResult.aheadEarDelta), privacy: .public), theta \(text(self.probeResult.aheadPitchDelta), privacy: .public) deg (\(count, privacy: .public) samples, \(self.earSamples.count, privacy: .public) ear, \(self.pitchSamples.count, privacy: .public) pitch)")

			self.finishGazeProbes()

		case .slouched:
			// The span gates: a "slouch" at or above upright, or closer to it
			// than measurement noise, is not a slouch. The gate judges the
			// eye metric (always present on a usable capture); the ear span
			// only has to come out positive, else its slouched half is
			// dropped and the ear span is derived or nominal like any other.
			guard let upright = self.uprightMedian, upright - median >= Self.minimumSlouchSpan else {
				let upright = self.uprightMedian ?? 0
				Self.logger.warning("Calibration slouch rejected: median \(String(format: "%.3f", median), privacy: .public) vs upright \(String(format: "%.3f", upright), privacy: .public), span \(String(format: "%.3f", upright - median), privacy: .public) under floor \(String(format: "%.3f", Self.minimumSlouchSpan), privacy: .public)")
				self.abortFinishedCapture(with: .notSlouched)
				return
			}
			var earSlouched = earMedian
			if let earUpright = self.uprightEarMedian, let slouched = earSlouched, earUpright - slouched <= 0 {
				earSlouched = nil
			}
			let earSpanText = self.uprightEarMedian.flatMap { u in earSlouched.map { String(format: "%.3f", u - $0) } } ?? "n/a"
			Self.logger.log("Calibration finished: upright \(String(format: "%.3f", upright), privacy: .public), slouched \(String(format: "%.3f", median), privacy: .public), span \(String(format: "%.3f", upright - median), privacy: .public), ear span \(earSpanText, privacy: .public)")
			self.onPhase.send(.done(baseline: upright, slouched: median, earBaseline: self.uprightEarMedian, earSlouched: earSlouched))
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
		case .lookingAhead:
			Self.logger.log("Calibration gaze capture skipped (\(String(describing: failure), privacy: .public))")
			self.finishGazeProbes()
		case .slouched:
			self.onPhase.send(.slouchReady(failure: failure))
		}
	}

}


/// The gaze probes' combined result: deltas from the middle-of-screen
/// baseline to the screen's bottom edge (the gaze envelope) and to
/// looking directly ahead (theta), per metric plus face pitch in
/// degrees. Each field nil when its capture fell short or was skipped.
struct SRGazeProbeResult {
	/// The middle-of-screen face pitch itself, in degrees, not a delta.
	/// Every other field here is relative to it, which is fine for fitting
	/// but useless at runtime: comparing a live pitch reading against
	/// calibration needs the absolute zero, and the face detector's zero
	/// is per camera. Stored so the looking-down test has something to
	/// difference against (PITCH_TUNING.md).
	var uprightPitch: CGFloat?
	var aheadEyeDelta: CGFloat?
	var aheadEarDelta: CGFloat?
	var aheadPitchDelta: CGFloat?
}
