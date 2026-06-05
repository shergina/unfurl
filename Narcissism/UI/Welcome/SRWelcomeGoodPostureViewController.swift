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

		let titleView = SRWelcomeRows.label(
			NSLocalizedString("welcome.good-posture.title", comment: ""),
			font: NSFont.systemFont(ofSize: 20, weight: .bold)
		)
		titleView.alignment = .center

		let rows = NSStackView(views: [
			SRWelcomeRows.row(
				symbol: "chair",
				titleKey: "welcome.good-posture.hips.title",
				bodyKey: "welcome.good-posture.hips.body"
			),
			SRWelcomeRows.row(
				symbol: "arrow.up.to.line",
				titleKey: "welcome.good-posture.tall.title",
				bodyKey: "welcome.good-posture.tall.body"
			),
			SRWelcomeRows.row(
				symbol: "figure.arms.open",
				titleKey: "welcome.good-posture.shoulders.title",
				bodyKey: "welcome.good-posture.shoulders.body"
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
		let readyButton = button(
			NSLocalizedString("welcome.ready.ready", comment: ""),
			action: #selector(self.readyPressed(_:))
		)
		readyButton.keyEquivalent = "\r"

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			rows.widthAnchor.constraint(equalToConstant: SRWelcomeRows.textWidth),

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
