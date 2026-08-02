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

	/// Shared by every page of the calibration window, so the window never
	/// changes size mid-flow.
	static let contentSize = CGSize(width: 480.0, height: 520.0)

	/// Where the action buttons sit above the bottom edge. Derived from the
	/// layout below, and reused by the reminders page to line its Ready
	/// button up with Begin.
	static let actionButtonBottomInset = CGFloat(26)

	/// The content above the action buttons. The welcome embed hides the
	/// inline buttons and sizes itself to exactly this, so the two layouts
	/// cannot drift apart (UI/Welcome/spec.md).
	static let embeddedContentHeight = CGFloat(454)

	/// The guidance block's reserved band. Everything below is positioned
	/// from the band rather than from the text, so the progress bar and the
	/// buttons never hop as lines come and go.
	///
	/// Sized for the two-line block every normal step shows (39pt), not for
	/// the three-line worst case (59pt): reserving the worst case left ~27pt
	/// of dead air under the text on every screen the user actually sees.
	/// The block is centered, so the three-line states overflow the band by
	/// ~7pt at each end - which is free, because the only states that reach
	/// three lines (a capture failure, and lookAheadReady) are exactly the
	/// ones with the progress bar hidden underneath them.
	fileprivate static let guidanceBandHeight = CGFloat(46)

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

	fileprivate var didInstallConstraints = false
	fileprivate var placeholderView: SRCameraPlaceholerView!
	fileprivate var cameraView: SRPostureCalibrationCameraView!
	fileprivate var countdownLabel: NSTextField!
	fileprivate var guidanceStack: NSStackView!
	fileprivate var statusLabel: NSTextField!
	fileprivate var instructionLabel: NSTextField!
	fileprivate var holdLabel: NSTextField!
	fileprivate var progressIndicator: NSProgressIndicator!
	fileprivate var beginButton: NSButton!
	fileprivate var doneButton: NSButton!
	fileprivate var redoButton: NSButton!
	fileprivate var cancellables = Set<AnyCancellable>()

	override func loadView() {
		self.view = NSView(frame: CGRect(origin: .zero, size: Self.contentSize))

		// The window sizes itself from this, not from the fitting size - a
		// long guidance line must wrap, never widen the window (and with it
		// the preview, whose height rides the width).
		self.preferredContentSize = Self.contentSize

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
		// Deliberately smaller than it wants to be: the digit is a timer,
		// the instruction below it is the thing to read, and at 96pt the
		// digit won that contest.
		self.countdownLabel.font = NSFont.systemFont(ofSize: 64.0, weight: .bold)
		self.countdownLabel.textColor = .white
		self.countdownLabel.alignment = .center
		self.countdownLabel.isHidden = true
		self.view.addSubview(self.countdownLabel)

		// Three fixed slots: an optional status line (a failure, or the
		// upright confirmation), the pose instruction, and the line that
		// does not change between poses. One shape on every screen, so the
		// only thing the eye has to find is which instruction is showing.
		self.statusLabel = Self.slotLabel(font: NSFont.systemFont(ofSize: 13.0), color: .secondaryLabelColor)
		self.instructionLabel = Self.slotLabel(font: NSFont.systemFont(ofSize: 15.0, weight: .semibold), color: .labelColor)
		self.holdLabel = Self.slotLabel(font: NSFont.systemFont(ofSize: 13.0), color: .secondaryLabelColor)

		self.guidanceStack = NSStackView(views: [self.statusLabel, self.instructionLabel, self.holdLabel])
		self.guidanceStack.orientation = .vertical
		self.guidanceStack.alignment = .centerX
		self.guidanceStack.spacing = 4.0
		self.guidanceStack.translatesAutoresizingMaskIntoConstraints = false
		self.view.addSubview(self.guidanceStack)

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

		// The upright medians are saved the moment the capture passes the
		// gates, before the gaze probe runs: a flow abandoned mid-probe
		// keeps a usable baseline.
		self.session.onUprightCaptured = { [weak self] baseline, earBaseline in
			self?.save(baseline, earBaseline: earBaseline)
		}

		// The gaze probe lands after the upright save: fold its deltas
		// into the just-written entry.
		self.session.onGazeCaptured = { result in
			let deviceID = SRCameraService.sharedInstance.onSelectedDeviceID.value
			guard var entry = SRSettings.sharedInstance.postureBaseline(for: deviceID) else { return }
			entry.eyeGazeDelta = result.aheadEyeDelta
			entry.earGazeDelta = result.aheadEarDelta
			entry.gazePitchDelta = result.aheadPitchDelta
			entry.uprightFacePitch = result.uprightPitch
			SRSettings.sharedInstance.setPostureBaseline(entry, for: deviceID)
		}

		self.session.onPhase
			.sink { [weak self] phase in self?.apply(phase) }
			.store(in: &self.cancellables)

		// No frames -> show the placeholder, not a black rectangle. The
		// guidance goes quiet too: everything it can say presumes frames,
		// and "can't see you" under a placeholder that names the real
		// problem (access denied) diagnoses the wrong one. The band keeps
		// its reserved height, so nothing below shifts.
		SRCameraService.sharedInstance.onState
			.receive(on: DispatchQueue.main)
			.sink { [weak self] state in
				self?.cameraView.isHidden = !state.isRunning
				self?.guidanceStack.isHidden = !state.isRunning
			}
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

				// Centered in the reserved band, which starts 16 below the
				// preview.
				self.guidanceStack.centerYAnchor.constraint(
					equalTo: self.placeholderView.bottomAnchor,
					constant: 16.0 + Self.guidanceBandHeight / 2.0
				),
				self.guidanceStack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: kMargin),
				self.guidanceStack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -kMargin),

				// Hung off the band, not off the text: the bar and the
				// buttons hold still while the lines above them change.
				self.progressIndicator.topAnchor.constraint(
					equalTo: self.placeholderView.bottomAnchor,
					constant: 16.0 + Self.guidanceBandHeight + 12.0
				),
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
			// Bad framing takes the instruction slot for itself: nothing else
			// matters until the camera can see the user, and Begin is
			// disabled anyway.
			self.setGuidance(
				status: Self.failureText(failure),
				instruction: Self.guidanceText(guidance),
				hold: guidance == .good ? Self.holdText : nil
			)

		case .lookAheadReady:
			// The gaze probe's gate; Begin arms it, ungated on guidance -
			// framing was established by the upright capture.
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = !self.showsActionButtons
			self.beginButton.isEnabled = true
			self.setGuidance(
				// What just happened, above the next instruction.
				status: NSLocalizedString("posture.calibration.upright-captured", comment: ""),
				instruction: Self.instruction(for: .lookingAhead),
				hold: Self.holdText
			)

		case .countingDown(let pose, let remaining):
			self.countdownLabel.isHidden = false
			self.countdownLabel.stringValue = "\(remaining)"
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = true
			// The instruction carries straight through the countdown - those
			// three seconds are the time to settle into the pose, and someone
			// who pressed Begin without reading still gets it before the
			// first sample.
			self.setGuidance(instruction: Self.instruction(for: pose), hold: Self.holdText)

		case .capturing(let pose, let sampledSeconds, let paused):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = sampledSeconds
			self.beginButton.isHidden = true
			// Still the same instruction: the pose is being recorded right
			// now, so this is the worst moment to stop saying what it is.
			self.setGuidance(
				instruction: Self.instruction(for: pose),
				hold: NSLocalizedString(
					paused ? "posture.calibration.paused" : "posture.calibration.measuring",
					comment: ""
				)
			)

		case .done:
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = self.progressIndicator.maxValue
			self.beginButton.isHidden = true
			self.setGuidance(instruction: NSLocalizedString("posture.calibration.finished", comment: ""))
			// Nothing to persist here: the baseline landed at the upright
			// capture and the probe's angles were folded in by
			// onGazeCaptured.

			// The bar animates its fill at its own (undocumented) pace;
			// give it a generous beat to land before the buttons show up.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
				guard let self, self.showsActionButtons, case .done = self.session.onPhase.value else { return }
				self.doneButton.isHidden = false
				self.redoButton.isHidden = false
			}
		}
	}

	fileprivate static func slotLabel(font: NSFont, color: NSColor) -> NSTextField {
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = font
		label.textColor = color
		label.alignment = .center
		label.maximumNumberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		// Window width minus the margins; keeps the multi-line intrinsic
		// height honest.
		label.preferredMaxLayoutWidth = 440.0
		return label
	}

	/// Fills the three slots at once. An omitted slot is hidden, which the
	/// stack collapses, so the block stays centered in its band whatever is
	/// showing.
	fileprivate func setGuidance(status: String? = nil, instruction: String, hold: String? = nil) {
		self.statusLabel.stringValue = status ?? ""
		self.statusLabel.isHidden = (status == nil)
		self.instructionLabel.stringValue = instruction
		self.holdLabel.stringValue = hold ?? ""
		self.holdLabel.isHidden = (hold == nil)
	}

	/// The instruction slot's line for a pose - the same words at the gate,
	/// through the countdown, and during the capture. It never swaps out
	/// from under someone who read it before pressing Begin.
	fileprivate static func instruction(for pose: SRPostureCalibrationSession.Pose) -> String {
		switch pose {
		case .upright:
			return NSLocalizedString("posture.calibration.instruction.middle", comment: "")
		case .lookingAhead:
			return NSLocalizedString("posture.calibration.instruction.ahead", comment: "")
		}
	}

	/// The hold slot, the line that does not change between poses: both
	/// measure the baseline, so both ask for the same best posture.
	fileprivate static var holdText: String {
		return NSLocalizedString("posture.calibration.hold", comment: "")
	}

	fileprivate static func failureText(_ failure: SRPostureCalibrationSession.Failure?) -> String? {
		switch failure {
		case .timedOut:
			return NSLocalizedString("posture.calibration.failed.timeout", comment: "")
		case .unstableReadings:
			return NSLocalizedString("posture.calibration.failed.unstable", comment: "")
		case nil:
			return nil
		}
	}

	/// What the framing gate has to say. Only reached while it is unhappy -
	/// a good reading shows the pose instruction instead.
	fileprivate static func guidanceText(_ guidance: SRPostureCalibrationSession.Guidance) -> String {
		switch guidance {
		case .notVisible:
			return NSLocalizedString("posture.calibration.guidance.not-visible", comment: "")
		case .faceNotVisible:
			return NSLocalizedString("posture.calibration.guidance.face-not-visible", comment: "")
		case .tooFar:
			return NSLocalizedString("posture.calibration.guidance.too-far", comment: "")
		case .good:
			return Self.instruction(for: .upright)
		}
	}

	/// Saved the moment the upright capture passes its gates - a Try Again
	/// result overwrites. Stored against the camera in use, so each camera
	/// keeps its own. Writing the whole entry also clears the previous
	/// calibration's gaze angles: a new baseline must never pair with old
	/// ones (recalibrating after moving the screen would mix geometries),
	/// and the probe folds this run's in a moment later. All calibration
	/// ever persists: numbers and a date.
	fileprivate func save(_ baseline: CGFloat, earBaseline: CGFloat?) {
		self.completed = true
		let deviceID = SRCameraService.sharedInstance.onSelectedDeviceID.value
		SRSettings.sharedInstance.setPostureBaseline(
			PostureBaseline(slouchRatio: baseline, date: .now, earSlouchRatio: earBaseline),
			for: deviceID
		)
	}

}
