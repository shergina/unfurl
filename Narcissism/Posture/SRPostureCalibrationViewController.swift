//
//  SRPostureCalibrationViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The calibration window's content: mirrored preview, the camera
/// placeholder behind it for failure states, guidance line, countdown
/// overlay, progress bar, Begin button. Owns the session and persists
/// its result.
@MainActor
final class SRPostureCalibrationViewController: NSViewController {

	let session = SRPostureCalibrationSession()

	/// True once a baseline was saved; the window controller uses it to
	/// tell completion from cancellation.
	private(set) var completed = false

	/// Fires when the user accepts the result; the window controller
	/// closes on it.
	var onFinished: (() -> Void)?

	/// The standalone window shows the action buttons (Begin, Looks Good,
	/// Try Again) inline; the welcome flow's embed turns this off and
	/// renders its own from the public session API (UI/Welcome/spec.md).
	/// Set before the view loads.
	var showsActionButtons = true

	/// The upright capture's eye:shoulder ratio, held between the upright
	/// save and a two-pose completion (the anchor stores the pair together).
	fileprivate var capturedRho: CGFloat?

	fileprivate var didInstallConstraints = false
	fileprivate var placeholderView: SRCameraPlaceholerView!
	fileprivate var cameraView: SRPostureCalibrationCameraView!
	fileprivate var countdownLabel: NSTextField!
	fileprivate var guidanceLabel: NSTextField!
	fileprivate var progressIndicator: NSProgressIndicator!
	fileprivate var beginButton: NSButton!
	fileprivate var doneButton: NSButton!
	fileprivate var redoButton: NSButton!
	fileprivate var cancellables = Set<AnyCancellable>()

	override func loadView() {
		self.view = NSView(frame: CGRect(origin: .zero, size: CGSize(width: 480.0, height: 500.0)))

		// The window sizes itself from this, not from the fitting size - a
		// long guidance line must wrap, never widen the window (and with it
		// the preview, whose height rides the width).
		self.preferredContentSize = CGSize(width: 480.0, height: 500.0)

		// Placeholder behind the preview, panel-style: when the camera is
		// not delivering, it says why (incl. the System Settings button).
		self.placeholderView = SRCameraPlaceholerView()
		self.placeholderView.translatesAutoresizingMaskIntoConstraints = false
		self.view.addSubview(self.placeholderView)

		self.cameraView = SRPostureCalibrationCameraView()
		self.cameraView.translatesAutoresizingMaskIntoConstraints = false
		self.view.addSubview(self.cameraView)

		self.countdownLabel = NSTextField(labelWithString: "")
		self.countdownLabel.translatesAutoresizingMaskIntoConstraints = false
		self.countdownLabel.font = NSFont.systemFont(ofSize: 96.0, weight: .bold)
		self.countdownLabel.textColor = .white
		self.countdownLabel.alignment = .center
		self.countdownLabel.isHidden = true
		self.view.addSubview(self.countdownLabel)

		self.guidanceLabel = NSTextField(labelWithString: "")
		self.guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
		self.guidanceLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
		self.guidanceLabel.alignment = .center
		self.guidanceLabel.maximumNumberOfLines = 0
		self.guidanceLabel.lineBreakMode = .byWordWrapping
		// Window width minus the margins; keeps the multi-line intrinsic
		// height honest.
		self.guidanceLabel.preferredMaxLayoutWidth = 440.0
		self.view.addSubview(self.guidanceLabel)

		self.progressIndicator = NSProgressIndicator()
		self.progressIndicator.translatesAutoresizingMaskIntoConstraints = false
		self.progressIndicator.isIndeterminate = false
		self.progressIndicator.minValue = 0
		self.progressIndicator.maxValue = SRPostureCalibrationSession.requiredSampledSeconds
		self.progressIndicator.isHidden = true
		self.view.addSubview(self.progressIndicator)

		self.beginButton = NSButton(
			title: NSLocalizedString("posture.calibration.begin", comment: ""),
			target: self,
			action: #selector(SRPostureCalibrationViewController.handleBegin)
		)
		self.beginButton.translatesAutoresizingMaskIntoConstraints = false
		self.beginButton.bezelStyle = .rounded
		self.beginButton.controlSize = .large
		self.beginButton.keyEquivalent = "\r"
		self.view.addSubview(self.beginButton)

		// The finished-state pair, hidden until a capture passes the gates.
		self.doneButton = NSButton(
			title: NSLocalizedString("posture.calibration.accept", comment: ""),
			target: self,
			action: #selector(SRPostureCalibrationViewController.handleDone)
		)
		self.doneButton.translatesAutoresizingMaskIntoConstraints = false
		self.doneButton.bezelStyle = .rounded
		self.doneButton.controlSize = .large
		self.doneButton.keyEquivalent = "\r"
		self.doneButton.isHidden = true
		self.view.addSubview(self.doneButton)

		self.redoButton = NSButton(
			title: NSLocalizedString("posture.calibration.redo", comment: ""),
			target: self,
			action: #selector(SRPostureCalibrationViewController.handleRedo)
		)
		self.redoButton.translatesAutoresizingMaskIntoConstraints = false
		self.redoButton.bezelStyle = .rounded
		self.redoButton.controlSize = .large
		self.redoButton.isHidden = true
		self.view.addSubview(self.redoButton)

		SRPostureAnalysisService.sharedInstance.onFrameSample
			.sink { [weak self] sample in self?.session.ingest(sample) }
			.store(in: &self.cancellables)

		// Hybrid mode: the slouch pose runs only while the anchor is
		// missing a unit - once at the very first calibration, and once
		// more by the first run after the ear metric landed (which is what
		// migrates older installs to an ear-unit anchor). Every later
		// calibration is single-pose; its spans are derived from the
		// anchor by the eye:shoulder ratio.
		let settings = SRSettings.sharedInstance
		self.session.includesSlouchPose =
			settings.postureAnchorSpan.value <= 0 || settings.postureAnchorEarSpan.value <= 0

		// The upright medians (with the geometry probe) are saved the
		// moment the capture passes the gates, before any slouch pose runs:
		// a flow abandoned mid-slouch keeps a valid single-point baseline.
		self.session.onUprightCaptured = { [weak self] baseline, rho, earBaseline in
			self?.capturedRho = rho
			self?.saveUpright(baseline, rho: rho, earBaseline: earBaseline)
		}

		// The gaze probes land after the upright save: fold their deltas
		// into the just-written entry.
		self.session.onGazeCaptured = { result in
			let deviceID = SRCameraService.sharedInstance.onSelectedDeviceID.value
			guard var entry = SRSettings.sharedInstance.postureBaseline(for: deviceID) else { return }
			entry.eyeGazeDelta = result.aheadEyeDelta
			entry.earGazeDelta = result.aheadEarDelta
			entry.gazePitchDelta = result.aheadPitchDelta
			entry.eyeBottomDelta = result.bottomEyeDelta
			entry.earBottomDelta = result.bottomEarDelta
			entry.bottomPitchDelta = result.bottomPitchDelta
			SRSettings.sharedInstance.setPostureBaseline(entry, for: deviceID)
		}

		self.session.onPhase
			.sink { [weak self] phase in self?.apply(phase) }
			.store(in: &self.cancellables)

		// No frames -> show the placeholder, not a black rectangle.
		SRCameraService.sharedInstance.onState
			.receive(on: DispatchQueue.main)
			.sink { [weak self] state in self?.cameraView.isHidden = !state.isRunning }
			.store(in: &self.cancellables)

		self.view.needsUpdateConstraints = true
		self.view.updateConstraintsForSubtreeIfNeeded()
	}

	override func updateViewConstraints() {
		if !self.didInstallConstraints {
			let kMargin = CGFloat(20)

			NSLayoutConstraint.activate([
				self.placeholderView.topAnchor.constraint(equalTo: self.view.topAnchor),
				self.placeholderView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
				self.placeholderView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
				self.placeholderView.heightAnchor.constraint(equalTo: self.placeholderView.widthAnchor, multiplier: 3.0 / 4.0),

				// The live preview exactly covers the placeholder.
				self.cameraView.topAnchor.constraint(equalTo: self.placeholderView.topAnchor),
				self.cameraView.leadingAnchor.constraint(equalTo: self.placeholderView.leadingAnchor),
				self.cameraView.trailingAnchor.constraint(equalTo: self.placeholderView.trailingAnchor),
				self.cameraView.bottomAnchor.constraint(equalTo: self.placeholderView.bottomAnchor),

				self.countdownLabel.centerXAnchor.constraint(equalTo: self.cameraView.centerXAnchor),
				self.countdownLabel.centerYAnchor.constraint(equalTo: self.cameraView.centerYAnchor),

				self.guidanceLabel.topAnchor.constraint(equalTo: self.placeholderView.bottomAnchor, constant: 16.0),
				self.guidanceLabel.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
				self.guidanceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: self.view.leadingAnchor, constant: kMargin),
				self.guidanceLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.view.trailingAnchor, constant: -kMargin),

				self.progressIndicator.topAnchor.constraint(equalTo: self.guidanceLabel.bottomAnchor, constant: 12.0),
				self.progressIndicator.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 60.0),
				self.progressIndicator.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -60.0),

				self.beginButton.topAnchor.constraint(equalTo: self.progressIndicator.bottomAnchor, constant: 12.0),
				self.beginButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),

				// Looks Good / Try Again sit side by side where Begin is.
				self.doneButton.topAnchor.constraint(equalTo: self.beginButton.topAnchor),
				self.doneButton.trailingAnchor.constraint(equalTo: self.view.centerXAnchor, constant: -4.0),
				self.redoButton.topAnchor.constraint(equalTo: self.beginButton.topAnchor),
				self.redoButton.leadingAnchor.constraint(equalTo: self.view.centerXAnchor, constant: 4.0),
			])
			self.didInstallConstraints = true
		}

		super.updateViewConstraints()
	}

	@objc fileprivate func handleBegin() {
		self.session.begin()
	}

	@objc fileprivate func handleDone() {
		self.onFinished?()
	}

	@objc fileprivate func handleRedo() {
		self.session.redo()
	}

	fileprivate func apply(_ phase: SRPostureCalibrationSession.Phase) {
		if case .done = phase {} else {
			self.doneButton.isHidden = true
			self.redoButton.isHidden = true
		}

		switch phase {
		case .positioning(let guidance, let failure):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			// Zero the bar while hidden, so a redo never shows it sliding
			// back down from full.
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = !self.showsActionButtons
			self.beginButton.isEnabled = (guidance == .good)
			self.guidanceLabel.stringValue = Self.text(for: guidance, failure: failure)

		case .bottomReady:
			// The gaze probes' gates; Begin arms each, ungated on guidance -
			// framing was established by the upright capture.
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = !self.showsActionButtons
			self.beginButton.isEnabled = true
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.bottom-ready", comment: "")

		case .lookAheadReady:
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = !self.showsActionButtons
			self.beginButton.isEnabled = true
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.look-ahead-ready", comment: "")

		case .slouchReady(let failure):
			// The gate before the slouch pose (and its resting state after
			// a failed capture); Begin arms it. Framing was established by
			// the upright capture, so the button is not gated on guidance.
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = !self.showsActionButtons
			self.beginButton.isEnabled = true
			self.guidanceLabel.stringValue = Self.slouchText(failure: failure)

		case .countingDown(let pose, let remaining):
			self.countdownLabel.isHidden = false
			self.countdownLabel.stringValue = "\(remaining)"
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = true
			// The slouch and gaze countdowns carry the instruction: those
			// three seconds are the time to settle into the pose.
			let countdownKey: String
			switch pose {
			case .upright: countdownKey = "posture.calibration.capturing"
			case .lookingAtBottom: countdownKey = "posture.calibration.bottom-instruction"
			case .lookingAhead: countdownKey = "posture.calibration.look-ahead-instruction"
			case .slouched: countdownKey = "posture.calibration.slouch-instruction"
			}
			self.guidanceLabel.stringValue = NSLocalizedString(countdownKey, comment: "")

		case .capturing(let pose, let sampledSeconds, let paused):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = sampledSeconds
			self.beginButton.isHidden = true
			let key: String
			if paused {
				key = "posture.calibration.paused"
			} else {
				switch pose {
				case .upright: key = "posture.calibration.capturing"
				case .lookingAtBottom: key = "posture.calibration.bottom-capturing"
				case .lookingAhead: key = "posture.calibration.look-ahead-capturing"
				case .slouched: key = "posture.calibration.slouch-capturing"
				}
			}
			self.guidanceLabel.stringValue = NSLocalizedString(key, comment: "")

		case .done(let baseline, let slouched, let earBaseline, let earSlouched):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = self.progressIndicator.maxValue
			self.beginButton.isHidden = true
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.finished", comment: "")
			// A single-pose run (slouched == nil) was fully saved by
			// saveUpright; a two-pose run saves the pairs and, while a
			// unit is missing, refreshes the anchor.
			if let slouched {
				self.save(baseline: baseline, slouched: slouched, earBaseline: earBaseline, earSlouched: earSlouched)
			}

			// The bar animates its fill at its own (undocumented) pace;
			// give it a generous beat to land before the buttons show up.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
				guard let self, self.showsActionButtons, case .done = self.session.onPhase.value else { return }
				self.doneButton.isHidden = false
				self.redoButton.isHidden = false
			}
		}
	}

	/// The slouch pose's guidance: what just happened on the first line -
	/// the upright capture landing, or the failure - then the instruction
	/// with its press-Begin cue, mirroring the positioning text.
	fileprivate static func slouchText(failure: SRPostureCalibrationSession.Failure?) -> String {
		var lines: [String] = []
		switch failure {
		case .timedOut:
			lines.append(NSLocalizedString("posture.calibration.failed.timeout", comment: ""))
		case .unstableReadings:
			lines.append(NSLocalizedString("posture.calibration.failed.unstable", comment: ""))
		case .notSlouched:
			lines.append(NSLocalizedString("posture.calibration.failed.not-slouched", comment: ""))
		case nil:
			lines.append(NSLocalizedString("posture.calibration.upright-captured", comment: ""))
		}
		lines.append(NSLocalizedString("posture.calibration.slouch-ready", comment: ""))
		return lines.joined(separator: "\n")
	}

	/// Failure explanation first, live guidance on the next line.
	fileprivate static func text(for guidance: SRPostureCalibrationSession.Guidance, failure: SRPostureCalibrationSession.Failure?) -> String {
		var lines: [String] = []
		switch failure {
		case .timedOut:
			lines.append(NSLocalizedString("posture.calibration.failed.timeout", comment: ""))
		case .unstableReadings:
			lines.append(NSLocalizedString("posture.calibration.failed.unstable", comment: ""))
		case .notSlouched:
			// Slouch-phase failures land at slouchReady, not here; carried
			// for exhaustiveness.
			lines.append(NSLocalizedString("posture.calibration.failed.not-slouched", comment: ""))
		case nil:
			break
		}
		switch guidance {
		case .notVisible:
			lines.append(NSLocalizedString("posture.calibration.guidance.not-visible", comment: ""))
		case .faceNotVisible:
			lines.append(NSLocalizedString("posture.calibration.guidance.face-not-visible", comment: ""))
		case .tooFar:
			lines.append(NSLocalizedString("posture.calibration.guidance.too-far", comment: ""))
		case .good:
			lines.append(NSLocalizedString("posture.calibration.guidance.good", comment: ""))
		}
		return lines.joined(separator: "\n")
	}

	/// Saved the moment the upright capture passes its gates, with the
	/// geometry probe, clearing any stored slouched value: a new baseline
	/// must never pair with an old slouch (recalibrating after moving the
	/// screen would mix geometries). For a single-pose run this IS the
	/// complete result; for a two-pose run, a flow abandoned after this
	/// point leaves a valid single-point entry.
	fileprivate func saveUpright(_ baseline: CGFloat, rho: CGFloat?, earBaseline: CGFloat?) {
		self.completed = true
		let deviceID = SRCameraService.sharedInstance.onSelectedDeviceID.value
		SRSettings.sharedInstance.setPostureBaseline(
			PostureBaseline(slouchRatio: baseline, slouchedRatio: nil, date: .now, eyeShoulderRatio: rho, earSlouchRatio: earBaseline),
			for: deviceID
		)
	}

	/// The full two-pose result; a Try Again result overwrites. Stored
	/// against the camera in use, so each camera keeps its own pairs. A
	/// completion while the anchor is missing a unit (the very first ever,
	/// or the first after the ear metric landed) refreshes the whole
	/// anchor - the spans and geometry probe measured together, written
	/// before the entry so observers of the baselines map always see a
	/// current anchor. The ear anchor unit is only written when this run
	/// measured a real ear span; until one does, calibrations keep running
	/// two-pose. All calibration ever persists: numbers and a date.
	fileprivate func save(baseline: CGFloat, slouched: CGFloat, earBaseline: CGFloat?, earSlouched: CGFloat?) {
		self.completed = true
		let settings = SRSettings.sharedInstance
		if settings.postureAnchorSpan.value <= 0 || settings.postureAnchorEarSpan.value <= 0,
			let rho = self.capturedRho, rho > 0 {
			settings.postureAnchorSpan.value = baseline - slouched
			if let earBaseline, let earSlouched, earBaseline - earSlouched > 0 {
				settings.postureAnchorEarSpan.value = earBaseline - earSlouched
			}
			settings.postureAnchorEyeShoulderRatio.value = rho
		}
		let deviceID = SRCameraService.sharedInstance.onSelectedDeviceID.value
		settings.setPostureBaseline(
			PostureBaseline(
				slouchRatio: baseline,
				slouchedRatio: slouched,
				date: .now,
				eyeShoulderRatio: self.capturedRho,
				earSlouchRatio: earBaseline,
				earSlouchedRatio: earSlouched
			),
			for: deviceID
		)
	}

}
