//
//  SRWelcomeViewController.swift
//  Unfurl
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
			font: NSFont.systemFont(ofSize: 13, weight: .bold)
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
			iconView, titleView, sloganView, descriptionView, privacyView,
		])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 16
		// The icon asset has built-in transparent padding, so a small value
		// here already reads as a comfortable gap.
		stack.setCustomSpacing(8, after: iconView)
		stack.setCustomSpacing(10, after: titleView)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		view.addSubview(continueButton)

		// The shared page size; content centers in the room above the
		// bottom button band.
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.width),
			view.heightAnchor.constraint(equalToConstant: SRWelcomeWindowController.pageSize.height),

			iconView.widthAnchor.constraint(equalToConstant: 96),
			iconView.heightAnchor.constraint(equalToConstant: 96),

			continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
			continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
			continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),

			stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
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
			// AppKit puts an attachment image on the line's bottom, not the
			// text baseline (unlike UIKit, which reads the symbol's metrics).
			// This 11 pt semibold lock.fill raster is 11x13 with 1 pt of
			// transparent padding below the glyph (alpha-measured), so y = -1
			// rests the glyph's flat bottom exactly on the baseline.
			attachment.bounds = CGRect(
				x: 0,
				y: -1.0,
				width: lock.size.width,
				height: lock.size.height
			)
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
