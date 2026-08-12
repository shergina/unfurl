//
//  SRWelcomePostureViewController.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit
import Combine


/// The posture preset page of the welcome flow. Embeds the same
/// calibration content the standalone window uses (Posture/spec.md); this
/// page adds the header, the "I'll do this later" escape, and the flow
/// semantics: success turns Track Posture on, everything else leaves the
/// app exactly as it was.
@MainActor
final class SRWelcomePostureViewController: NSViewController {

	/// Fires when the flow should close: after Looks Good (tracking is
	/// enabled by the teardown then) or I'll do this later.
	var onClose: (() -> Void)?
	var onBack: (() -> Void)?

	fileprivate let calibrationViewController = SRPostureCalibrationViewController()
	fileprivate var laterButton: NSButton!
	fileprivate var backButton: NSButton!
	fileprivate var beginButton: NSButton!
	fileprivate var doneButton: NSButton!
	fileprivate var redoButton: NSButton!
	fileprivate var startedProbe = false
	fileprivate var didTearDown = false
	fileprivate var cancellables = Set<AnyCancellable>()

	override func loadView() {
		let view = NSView()

		let titleView = NSTextField(wrappingLabelWithString: NSLocalizedString("welcome.posture.title", comment: ""))
		titleView.translatesAutoresizingMaskIntoConstraints = false
		titleView.font = NSFont.systemFont(ofSize: 20, weight: .bold)
		titleView.alignment = .center
		titleView.isSelectable = false
		view.addSubview(titleView)

		let bodyView = NSTextField(wrappingLabelWithString: NSLocalizedString("welcome.posture.body", comment: ""))
		bodyView.translatesAutoresizingMaskIntoConstraints = false
		bodyView.font = NSFont.systemFont(ofSize: 13)
		bodyView.textColor = NSColor.secondaryLabelColor
		bodyView.alignment = .center
		bodyView.isSelectable = false
		bodyView.preferredMaxLayoutWidth = 400
		view.addSubview(bodyView)

		self.addChild(self.calibrationViewController)
		// This page renders the action buttons itself, in the shared
		// bottom band; the embed's inline ones stay hidden.
		self.calibrationViewController.showsActionButtons = false
		let calibrationView = self.calibrationViewController.view
		calibrationView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(calibrationView)

		func button(_ title: String, action: Selector) -> NSButton {
			let button = NSButton(title: title, target: self, action: action)
			button.controlSize = .large
			button.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(button)
			return button
		}

		// The bottom band, assistant style: Back alone on the left is
		// navigation; the page's decision - Begin next to its Not Now
		// escape, or Looks Good next to Try Again - is on the right.
		self.backButton = button(
			NSLocalizedString("welcome.back", comment: ""),
			action: #selector(self.backPressed(_:))
		)
		self.laterButton = button(
			NSLocalizedString("welcome.posture.later", comment: ""),
			action: #selector(self.laterPressed(_:))
		)
		self.beginButton = button(
			NSLocalizedString("posture.calibration.begin", comment: ""),
			action: #selector(self.beginPressed(_:))
		)
		self.beginButton.keyEquivalent = "\r"
		self.redoButton = button(
			NSLocalizedString("posture.calibration.redo", comment: ""),
			action: #selector(self.redoPressed(_:))
		)
		self.redoButton.isHidden = true
		self.doneButton = button(
			NSLocalizedString("posture.calibration.accept", comment: ""),
			action: #selector(self.donePressed(_:))
		)
		self.doneButton.keyEquivalent = "\r"
		self.doneButton.isHidden = true

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			titleView.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
			titleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),

			bodyView.topAnchor.constraint(equalTo: titleView.bottomAnchor, constant: 8),
			bodyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			bodyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
			bodyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),

			// The embedded content is edge to edge like its standalone
			// window; its internals are top-anchored, and with the inline
			// buttons off it ends at the progress bar. The height comes from
			// the calibration layout itself - nothing here clips, so the two
			// must not drift apart or the guidance draws over the buttons.
			calibrationView.topAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: 20),
			calibrationView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			calibrationView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			calibrationView.heightAnchor.constraint(
				equalToConstant: SRPostureCalibrationViewController.embeddedContentHeight
			),

			self.backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			self.backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			self.beginButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			self.beginButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
			self.laterButton.trailingAnchor.constraint(equalTo: self.beginButton.leadingAnchor, constant: -8),
			self.laterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			self.doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			self.doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
			self.redoButton.trailingAnchor.constraint(equalTo: self.doneButton.leadingAnchor, constant: -8),
			self.redoButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
		])

		self.calibrationViewController.session.onPhase
			.sink { [weak self] phase in self?.apply(phase) }
			.store(in: &self.cancellables)

		self.view = view
	}

	override func viewDidAppear() {
		super.viewDidAppear()

		// No posture notes while calibrating, exactly like the standalone
		// window.
		SRPostureAnalysisService.sharedInstance.setCalibrationWindowOpen(true)

		// The probe normally runs only while Track Posture is on, but this
		// page needs frame samples before the user has opted in: start it
		// directly, and give it back on the way out (see tearDown).
		if !SRSettings.sharedInstance.postureTracking.value {
			SRPostureAnalysisService.sharedInstance.start()
			self.startedProbe = true
		}
	}

	override func viewDidDisappear() {
		super.viewDidDisappear()
		self.tearDown()
	}

	/// The band mirrors the standalone window's button logic, driven by the
	/// same session phases: Begin while positioning (enabled on good
	/// framing), nothing during the capture, Looks Good / Try Again when
	/// finished. Back and Not Now show only before a capture completed.
	fileprivate func apply(_ phase: SRPostureCalibrationSession.Phase) {
		var showsBegin = false
		var beginEnabled = false
		var showsEscape = false
		if case .positioning(let guidance, _) = phase {
			showsBegin = true
			beginEnabled = (guidance == .good)
			showsEscape = !self.calibrationViewController.completed
		}
		// The gate before the gaze probe: Begin arms it, ungated - framing
		// was established by the upright pass.
		if case .lookAheadReady = phase {
			showsBegin = true
			beginEnabled = true
		}
		self.beginButton.isHidden = !showsBegin
		self.beginButton.isEnabled = beginEnabled
		self.backButton.isHidden = !showsEscape
		self.laterButton.isHidden = !showsEscape

		if case .done = phase {
			// The same settle beat the standalone window gives its progress
			// bar before the finished pair appears.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
				guard let self, case .done = self.calibrationViewController.session.onPhase.value else { return }
				self.doneButton.isHidden = false
				self.redoButton.isHidden = false
			}
		} else {
			self.doneButton.isHidden = true
			self.redoButton.isHidden = true
		}
	}

	@objc fileprivate func beginPressed(_ sender: Any?) {
		self.calibrationViewController.session.begin()
	}

	@objc fileprivate func redoPressed(_ sender: Any?) {
		self.calibrationViewController.session.redo()
	}

	@objc fileprivate func donePressed(_ sender: Any?) {
		// The teardown turns tracking on (completed is set by the save).
		self.onClose?()
	}

	@objc fileprivate func laterPressed(_ sender: Any?) {
		self.onClose?()
	}

	@objc fileprivate func backPressed(_ sender: Any?) {
		self.onBack?()
	}

	/// One exit path for every way off this page (Looks Good, later, the
	/// close button): success enables tracking - the baseline is already
	/// saved, so the composition root will not reopen calibration - and
	/// anything else returns the probe to the state the preference asks for.
	fileprivate func tearDown() {
		guard !self.didTearDown else { return }
		self.didTearDown = true

		self.calibrationViewController.session.invalidate()
		SRPostureAnalysisService.sharedInstance.setCalibrationWindowOpen(false)

		if self.calibrationViewController.completed {
			SRSettings.sharedInstance.postureTracking.value = true
		} else if self.startedProbe && !SRSettings.sharedInstance.postureTracking.value {
			SRPostureAnalysisService.sharedInstance.stop()
		}
	}

}
