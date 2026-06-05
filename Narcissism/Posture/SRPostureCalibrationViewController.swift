//
//  SRPostureCalibrationViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The calibration window's content: mirrored preview with joint dots,
/// the camera placeholder behind it for failure states, guidance line,
/// countdown overlay, progress bar, Begin button. Owns the session and
/// persists its result.
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

		case .countingDown(let remaining):
			self.countdownLabel.isHidden = false
			self.countdownLabel.stringValue = "\(remaining)"
			self.progressIndicator.isHidden = true
			self.progressIndicator.doubleValue = 0
			self.beginButton.isHidden = true
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.capturing", comment: "")

		case .capturing(let sampledSeconds, let paused):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = sampledSeconds
			self.beginButton.isHidden = true
			self.guidanceLabel.stringValue = NSLocalizedString(
				paused ? "posture.calibration.paused" : "posture.calibration.capturing",
				comment: ""
			)

		case .done(let baseline):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = false
			self.progressIndicator.doubleValue = self.progressIndicator.maxValue
			self.beginButton.isHidden = true
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.finished", comment: "")
			self.save(baseline)

			// The bar animates its fill at its own (undocumented) pace;
			// give it a generous beat to land before the buttons show up.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
				guard let self, self.showsActionButtons, case .done = self.session.onPhase.value else { return }
				self.doneButton.isHidden = false
				self.redoButton.isHidden = false
			}
		}
	}

	/// Failure explanation first, live guidance on the next line.
	fileprivate static func text(for guidance: SRPostureCalibrationSession.Guidance, failure: SRPostureCalibrationSession.Failure?) -> String {
		var lines: [String] = []
		switch failure {
		case .timedOut:
			lines.append(NSLocalizedString("posture.calibration.failed.timeout", comment: ""))
		case .unstableReadings:
			lines.append(NSLocalizedString("posture.calibration.failed.unstable", comment: ""))
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

	/// Saved the moment a capture passes the gates; a Try Again result
	/// overwrites. All calibration ever persists: the ratio and its date.
	fileprivate func save(_ baseline: CGFloat) {
		self.completed = true
		SRSettings.sharedInstance.postureBaselineSlouchRatio.value = baseline
		SRSettings.sharedInstance.postureBaselineDate.value = Date.now
	}

}
