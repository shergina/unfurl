//
//  SRWelcomeGoodPostureViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// The good-posture page of the welcome flow: what to hold while the
/// capture measures, shown immediately before the camera page - the
/// baseline is whatever the user sits like during capture, so this is
/// the flow's most load-bearing advice. Ready lives here for that
/// reason (and is deliberately not "Begin", the capture trigger).
class SRWelcomeGoodPostureViewController: NSViewController {

	var onReady: (() -> Void)?
	var onClose: (() -> Void)?
	var onBack: (() -> Void)?

	override func loadView() {
		let view = NSView()

		// The same reminders the calibration window shows before its capture
		// page; defined once in SRGoodPostureReminders.
		let stack = SRGoodPostureReminders.contentView()
		view.addSubview(stack)

		func button(_ title: String, action: Selector) -> NSButton {
			let button = NSButton(title: title, target: self, action: action)
			button.controlSize = .large
			button.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(button)
			return button
		}

		let backButton = button(
			NSLocalizedString("welcome.back", comment: ""),
			action: #selector(self.backPressed(_:))
		)
		let laterButton = button(
			NSLocalizedString("welcome.posture.later", comment: ""),
			action: #selector(self.laterPressed(_:))
		)
		let readyButton = button(
			NSLocalizedString("posture.good.ready", comment: ""),
			action: #selector(self.readyPressed(_:))
		)
		readyButton.keyEquivalent = "\r"

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			readyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
			readyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			readyButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
			laterButton.trailingAnchor.constraint(equalTo: readyButton.leadingAnchor, constant: -8),
			laterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
		])

		self.view = view
	}

	@objc fileprivate func readyPressed(_ sender: Any?) {
		self.onReady?()
	}

	@objc fileprivate func laterPressed(_ sender: Any?) {
		self.onClose?()
	}

	@objc fileprivate func backPressed(_ sender: Any?) {
		self.onBack?()
	}

}
