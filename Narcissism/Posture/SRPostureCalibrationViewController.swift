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

	/// Fires shortly after a save; the window controller closes on it.
	var onFinished: (() -> Void)?

	fileprivate var didInstallConstraints = false
	fileprivate var placeholderView: SRCameraPlaceholerView!
	fileprivate var cameraView: SRPostureCalibrationCameraView!
	fileprivate var countdownLabel: NSTextField!
	fileprivate var guidanceLabel: NSTextField!
	fileprivate var progressIndicator: NSProgressIndicator!
	fileprivate var beginButton: NSButton!
	fileprivate var closeTimer: Timer?
	fileprivate var cancellables = Set<AnyCancellable>()

	deinit {
		// Deallocation happens on main; deinit just isn't statically
		// isolated (same as SRCameraView).
		MainActor.assumeIsolated {
			self.closeTimer?.invalidate()
		}
	}

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
		self.beginButton.keyEquivalent = "\r"
		self.view.addSubview(self.beginButton)

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
			])
			self.didInstallConstraints = true
		}

		super.updateViewConstraints()
	}

	@objc fileprivate func handleBegin() {
		self.session.begin()
	}

	fileprivate func apply(_ phase: SRPostureCalibrationSession.Phase) {
		switch phase {
		case .positioning(let guidance, let failure):
			self.countdownLabel.isHidden = true
			self.progressIndicator.isHidden = true
			self.beginButton.isHidden = false
			self.beginButton.isEnabled = (guidance == .good)
			self.guidanceLabel.stringValue = Self.text(for: guidance, failure: failure)

		case .countingDown(let remaining):
			self.countdownLabel.isHidden = false
			self.countdownLabel.stringValue = "\(remaining)"
			self.progressIndicator.isHidden = true
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
			self.guidanceLabel.stringValue = NSLocalizedString("posture.calibration.done", comment: "")
			self.saveIfNeeded(baseline)
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

	fileprivate func saveIfNeeded(_ baseline: CGFloat) {
		guard !self.completed else { return }
		self.completed = true

		// All calibration ever persists: the ratio and its date.
		SRSettings.sharedInstance.postureBaselineSlouchRatio.value = baseline
		SRSettings.sharedInstance.postureBaselineDate.value = Date.now

		// Let "done" be readable for a beat, then close.
		let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
			Task { @MainActor [weak self] in self?.onFinished?() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.closeTimer = timer
	}

}
