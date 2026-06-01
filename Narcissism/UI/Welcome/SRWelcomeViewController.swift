//
//  SRWelcomeViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// Page one of the welcome flow: app icon, title, slogan, description,
/// the privacy block, and Continue. Static content only; the owner decides
/// what Continue does.
class SRWelcomeViewController: NSViewController {

	var onContinue: (() -> Void)?

	fileprivate let kTextWidth = CGFloat(400)

	override func loadView() {
		let view = NSView()

		let iconView = NSImageView()
		iconView.image = NSImage(named: "AppIcon")
		iconView.translatesAutoresizingMaskIntoConstraints = false

		let titleView = self.label(
			NSLocalizedString("welcome.title", comment: ""),
			font: NSFont.systemFont(ofSize: 27, weight: .bold)
		)

		let sloganView = self.label(
			NSLocalizedString("welcome.slogan", comment: ""),
			font: NSFont.systemFont(ofSize: 15, weight: .bold)
		)

		let descriptionView = self.label(
			NSLocalizedString("welcome.description", comment: ""),
			font: NSFont.systemFont(ofSize: 13),
			color: NSColor.secondaryLabelColor
		)

		let privacyView = self.label("", font: NSFont.systemFont(ofSize: 13))
		privacyView.attributedStringValue = self.privacyText()

		let continueButton = NSButton(
			title: NSLocalizedString("welcome.continue", comment: ""),
			target: self,
			action: #selector(self.continuePressed(_:))
		)
		continueButton.keyEquivalent = "\r"
		continueButton.controlSize = .large
		continueButton.translatesAutoresizingMaskIntoConstraints = false

		let stack = NSStackView(views: [
			iconView, titleView, sloganView, descriptionView, privacyView, continueButton,
		])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 16
		// The icon asset has built-in transparent padding, so a small value
		// here already reads as a comfortable gap.
		stack.setCustomSpacing(8, after: iconView)
		stack.setCustomSpacing(10, after: titleView)
		stack.setCustomSpacing(28, after: privacyView)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)

		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: 480),

			iconView.widthAnchor.constraint(equalToConstant: 96),
			iconView.heightAnchor.constraint(equalToConstant: 96),

			continueButton.widthAnchor.constraint(equalToConstant: 200),

			stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
			stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
		])

		self.view = view
	}

	@objc fileprivate func continuePressed(_ sender: Any?) {
		self.onContinue?()
	}

	fileprivate func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = font
		label.textColor = color
		label.alignment = .center
		label.isSelectable = false
		label.preferredMaxLayoutWidth = self.kTextWidth
		return label
	}

	/// The privacy block: a lock symbol and a bold "Private by design." lead,
	/// then the plain statement, as one centered paragraph.
	fileprivate func privacyText() -> NSAttributedString {
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = .center

		let text = NSMutableAttributedString()

		if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) {
			let attachment = NSTextAttachment()
			attachment.image = lock
			text.append(NSAttributedString(attachment: attachment))
			text.append(NSAttributedString(string: " "))
		}

		text.append(NSAttributedString(
			string: NSLocalizedString("welcome.privacy.lead", comment: ""),
			attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]
		))
		text.append(NSAttributedString(string: " "))
		text.append(NSAttributedString(
			string: NSLocalizedString("welcome.privacy.body", comment: ""),
			attributes: [.font: NSFont.systemFont(ofSize: 13)]
		))

		text.addAttributes(
			[.paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor],
			range: NSRange(location: 0, length: text.length)
		)
		return text
	}

}
