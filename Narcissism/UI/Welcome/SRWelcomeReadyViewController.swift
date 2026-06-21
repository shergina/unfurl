//
//  SRWelcomeReadyViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// The get-ready page of the welcome flow: the setup checklist, shown
/// before the camera ever starts (the posture page only begins its
/// capture-side work two pages later). Static content; the owner wires
/// the closures.
class SRWelcomeReadyViewController: NSViewController {

	var onContinue: (() -> Void)?
	var onClose: (() -> Void)?
	var onBack: (() -> Void)?

	override func loadView() {
		let view = NSView()

		let titleView = SRWelcomeRows.label(
			NSLocalizedString("welcome.ready.title", comment: ""),
			font: NSFont.systemFont(ofSize: 20, weight: .bold)
		)
		titleView.alignment = .center

		let rows = NSStackView(views: [
			SRWelcomeRows.row(
				symbol: "person.fill.viewfinder",
				titleKey: "welcome.ready.framing.title",
				bodyKey: "welcome.ready.framing.body"
			),
			SRWelcomeRows.row(
				symbol: "tshirt",
				titleKey: "welcome.ready.clothes.title",
				bodyKey: "welcome.ready.clothes.body"
			),
			SRWelcomeRows.row(
				symbol: "comb",
				titleKey: "welcome.ready.hair.title",
				bodyKey: "welcome.ready.hair.body"
			),
			SRWelcomeRows.row(
				symbol: "lightbulb",
				titleKey: "welcome.ready.lighting.title",
				bodyKey: "welcome.ready.lighting.body"
			),
			SRWelcomeRows.row(
				symbol: "eye",
				titleKey: "welcome.ready.camera.title",
				bodyKey: "welcome.ready.camera.body"
			),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 18
		rows.translatesAutoresizingMaskIntoConstraints = false

		let stack = NSStackView(views: [titleView, rows])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 24
		stack.translatesAutoresizingMaskIntoConstraints = false
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
		let continueButton = button(
			NSLocalizedString("welcome.continue", comment: ""),
			action: #selector(self.continuePressed(_:))
		)
		continueButton.keyEquivalent = "\r"

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			rows.widthAnchor.constraint(equalToConstant: SRWelcomeRows.textWidth),

			backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			backButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
			continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
			laterButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -8),
			laterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
		])

		self.view = view
	}

	@objc fileprivate func continuePressed(_ sender: Any?) {
		self.onContinue?()
	}

	@objc fileprivate func laterPressed(_ sender: Any?) {
		self.onClose?()
	}

	@objc fileprivate func backPressed(_ sender: Any?) {
		self.onBack?()
	}

}
