//
//  SRWelcomeTutorialViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// Page two of the welcome flow: where the app lives (Locate Me points at
/// the status item) and what it does (three feature rows). Static content;
/// the owner wires both closures.
class SRWelcomeTutorialViewController: NSViewController {

	var onLocate: (() -> Void)?
	var onContinue: (() -> Void)?
	var onBack: (() -> Void)?

	override func loadView() {
		let view = NSView()

		let titleView = SRWelcomeRows.label(
			NSLocalizedString("welcome.tutorial.title", comment: ""),
			font: NSFont.systemFont(ofSize: 20, weight: .bold)
		)
		titleView.alignment = .center

		let subtitleView = SRWelcomeRows.label(
			NSLocalizedString("welcome.tutorial.subtitle", comment: ""),
			font: NSFont.systemFont(ofSize: 13),
			color: NSColor.secondaryLabelColor
		)
		subtitleView.alignment = .center

		// A plain push button: Continue stays the page's single default.
		let locateButton = NSButton(
			title: NSLocalizedString("welcome.tutorial.locate", comment: ""),
			target: self,
			action: #selector(self.locatePressed(_:))
		)
		locateButton.controlSize = .large
		locateButton.translatesAutoresizingMaskIntoConstraints = false

		let rows = NSStackView(views: [
			SRWelcomeRows.row(
				symbol: "web.camera",
				titleKey: "welcome.tutorial.camera.title",
				bodyKey: "welcome.tutorial.camera.body"
			),
			SRWelcomeRows.row(
				symbol: "figure.stand",
				titleKey: "welcome.tutorial.posture.title",
				bodyKey: "welcome.tutorial.posture.body"
			),
			SRWelcomeRows.row(
				symbol: "video.badge.checkmark",
				titleKey: "welcome.tutorial.calibration.title",
				bodyKey: "welcome.tutorial.calibration.body"
			),
			SRWelcomeRows.row(
				symbol: "bell",
				titleKey: "welcome.tutorial.notifications.title",
				bodyKey: "welcome.tutorial.notifications.body"
			),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 18
		rows.translatesAutoresizingMaskIntoConstraints = false

		let continueButton = NSButton(
			title: NSLocalizedString("welcome.continue", comment: ""),
			target: self,
			action: #selector(self.continuePressed(_:))
		)
		continueButton.keyEquivalent = "\r"
		continueButton.controlSize = .large
		continueButton.translatesAutoresizingMaskIntoConstraints = false

		let backButton = NSButton(
			title: NSLocalizedString("welcome.back", comment: ""),
			target: self,
			action: #selector(self.backPressed(_:))
		)
		backButton.controlSize = .large
		backButton.translatesAutoresizingMaskIntoConstraints = false

		let stack = NSStackView(views: [titleView, subtitleView, locateButton, rows])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 12
		stack.setCustomSpacing(16, after: subtitleView)
		stack.setCustomSpacing(28, after: locateButton)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		view.addSubview(backButton)
		view.addSubview(continueButton)

		// The shared page size; content centers in the room above the
		// bottom button band (Back left, Continue right, assistant style).
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			rows.widthAnchor.constraint(equalToConstant: SRWelcomeRows.textWidth),

			backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
			continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
		])

		self.view = view
	}

	@objc fileprivate func locatePressed(_ sender: Any?) {
		self.onLocate?()
	}

	@objc fileprivate func continuePressed(_ sender: Any?) {
		self.onContinue?()
	}

	@objc fileprivate func backPressed(_ sender: Any?) {
		self.onBack?()
	}

}
