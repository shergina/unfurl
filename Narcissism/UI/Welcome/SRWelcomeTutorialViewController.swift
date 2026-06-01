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

	fileprivate let kTextWidth = CGFloat(400)
	fileprivate let kRowIconWidth = CGFloat(30)
	fileprivate let kRowSpacing = CGFloat(12)

	override func loadView() {
		let view = NSView()

		let titleView = self.label(
			NSLocalizedString("welcome.tutorial.title", comment: ""),
			font: NSFont.systemFont(ofSize: 20, weight: .bold)
		)
		titleView.alignment = .center

		let subtitleView = self.label(
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
			self.featureRow(
				symbol: "web.camera",
				titleKey: "welcome.tutorial.camera.title",
				bodyKey: "welcome.tutorial.camera.body"
			),
			self.featureRow(
				symbol: "figure.stand",
				titleKey: "welcome.tutorial.posture.title",
				bodyKey: "welcome.tutorial.posture.body"
			),
			self.featureRow(
				symbol: "bell.badge",
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

		let stack = NSStackView(views: [titleView, subtitleView, locateButton, rows, continueButton])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 12
		stack.setCustomSpacing(16, after: subtitleView)
		stack.setCustomSpacing(28, after: locateButton)
		stack.setCustomSpacing(32, after: rows)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: 480),

			rows.widthAnchor.constraint(equalToConstant: self.kTextWidth),
			continueButton.widthAnchor.constraint(equalToConstant: 200),

			stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
			stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36),
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

	fileprivate func featureRow(symbol: String, titleKey: String, bodyKey: String) -> NSView {
		let title = NSLocalizedString(titleKey, comment: "")

		let iconView = NSImageView()
		iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
		iconView.contentTintColor = .controlAccentColor
		iconView.translatesAutoresizingMaskIntoConstraints = false

		let bodyWidth = self.kTextWidth - self.kRowIconWidth - self.kRowSpacing
		let titleView = self.label(
			title,
			font: NSFont.systemFont(ofSize: 13, weight: .bold),
			maxWidth: bodyWidth
		)
		let bodyView = self.label(
			NSLocalizedString(bodyKey, comment: ""),
			font: NSFont.systemFont(ofSize: 13),
			color: NSColor.secondaryLabelColor,
			maxWidth: bodyWidth
		)

		let text = NSStackView(views: [titleView, bodyView])
		text.orientation = .vertical
		text.alignment = .leading
		text.spacing = 2
		text.translatesAutoresizingMaskIntoConstraints = false

		let row = NSView()
		row.translatesAutoresizingMaskIntoConstraints = false
		row.addSubview(iconView)
		row.addSubview(text)

		NSLayoutConstraint.activate([
			iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
			iconView.widthAnchor.constraint(equalToConstant: self.kRowIconWidth),
			// Centered on the whole text block (the What's New look). Symbol
			// glyphs fill their boxes unevenly, so edge-alignment reads as
			// scattered; center-anchoring hides that.
			iconView.centerYAnchor.constraint(equalTo: text.centerYAnchor),

			text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: self.kRowIconWidth + self.kRowSpacing),
			text.trailingAnchor.constraint(equalTo: row.trailingAnchor),
			text.topAnchor.constraint(equalTo: row.topAnchor),
			text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
		])

		return row
	}

	fileprivate func label(
		_ text: String,
		font: NSFont,
		color: NSColor = .labelColor,
		maxWidth: CGFloat? = nil
	) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = font
		label.textColor = color
		label.isSelectable = false
		label.preferredMaxLayoutWidth = maxWidth ?? self.kTextWidth
		return label
	}

}
