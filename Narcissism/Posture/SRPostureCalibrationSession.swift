//
//  SRPostureCalibrationSession.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The calibration state machine, no AppKit: eats the probe's per-frame
/// samples, publishes the phase the window renders. Flow: position ->
/// Begin -> 3-2-1 -> 5 s of sampling (pauses when you vanish, 10 s hard
/// cap) -> quality gates -> the median becomes the baseline. See spec.md.
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
	}

	enum Phase: Equatable {
		case positioning(guidance: Guidance, failure: Failure?)
		case countingDown(remaining: Int)
		case capturing(sampledSeconds: Double, paused: Bool)
		case done(baseline: CGFloat)
	}

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
	/// Narrower shoulders than this fraction of the frame = too far away.
	fileprivate static let minimumShoulderWidthFraction: CGFloat = 0.15

	fileprivate var samples: [CGFloat] = []
	fileprivate var sampledSeconds = 0.0
	fileprivate var consecutiveUnusable = 0
	fileprivate var consecutiveUsable = 0
	fileprivate var paused = false
	fileprivate var countdownTimer: Timer?
	fileprivate var capTimer: Timer?

	/// Feed every published frame sample in.
	func ingest(_ sample: SRPostureFrameSample?) {
		switch self.onPhase.value {
		case .positioning(_, let failure):
			self.onPhase.send(.positioning(guidance: Self.guidance(for: sample), failure: failure))
		case .capturing:
			self.ingestWhileCapturing(sample)
		case .countingDown, .done:
			// The countdown ignores detection loss; capture pauses right
			// away if the user is still gone.
			break
		}
	}

	/// Only honored while positioned well; the Begin button mirrors this.
	func begin() {
		guard case .positioning(guidance: .good, _) = self.onPhase.value else { return }
		self.startCountdown()
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

	fileprivate func startCountdown() {
		self.onPhase.send(.countingDown(remaining: Self.countdownSeconds))
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in self?.tickCountdown() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.countdownTimer = timer
	}

	fileprivate func tickCountdown() {
		guard case .countingDown(let remaining) = self.onPhase.value else { return }
		if remaining > 1 {
			self.onPhase.send(.countingDown(remaining: remaining - 1))
		} else {
			self.countdownTimer?.invalidate()
			self.countdownTimer = nil
			self.startCapture()
		}
	}

	//: ## Capture

	fileprivate func startCapture() {
		self.samples = []
		self.sampledSeconds = 0
		self.consecutiveUnusable = 0
		self.consecutiveUsable = 0
		self.paused = false
		self.onPhase.send(.capturing(sampledSeconds: 0, paused: false))

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
				self.onPhase.send(.capturing(sampledSeconds: self.sampledSeconds, paused: false))
			}
			return
		}

		if self.consecutiveUnusable >= Self.pauseAfterConsecutiveUnusable {
			// Sustained loss: pause, and refund the lead-in frames that
			// ticked the clock while the user was already gone.
			self.paused = true
			self.sampledSeconds = max(0, self.sampledSeconds - Double(Self.pauseAfterConsecutiveUnusable - 1) * Self.secondsPerFrame)
			self.onPhase.send(.capturing(sampledSeconds: self.sampledSeconds, paused: true))
			return
		}

		self.sampledSeconds += Self.secondsPerFrame
		if let ratio {
			self.samples.append(ratio)
		}

		if self.sampledSeconds >= Self.requiredSampledSeconds {
			self.finishCapture()
		} else {
			self.onPhase.send(.capturing(sampledSeconds: self.sampledSeconds, paused: false))
		}
	}

	fileprivate func abortCapture(with failure: Failure) {
		guard case .capturing = self.onPhase.value else { return }
		self.invalidate()
		self.samples = []
		// The guidance refreshes on the very next ingested frame.
		self.onPhase.send(.positioning(guidance: .notVisible, failure: failure))
	}

	fileprivate func finishCapture() {
		self.capTimer?.invalidate()
		self.capTimer = nil

		let sorted = self.samples.sorted()
		let count = sorted.count
		guard count >= Self.minimumSampleCount else {
			self.abortFinishedCapture()
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
			self.abortFinishedCapture()
			return
		}

		self.onPhase.send(.done(baseline: median))
	}

	/// A capture that reached its 5 seconds but failed the quality gates.
	fileprivate func abortFinishedCapture() {
		self.samples = []
		self.onPhase.send(.positioning(guidance: .notVisible, failure: .unstableReadings))
	}

}
