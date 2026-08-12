//
//  SRWelcomeRows.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// The shared row style of the welcome flow's list pages (tutorial, get
/// ready, good posture): an accent-tinted symbol column next to a bold
/// title over a secondary one-liner, icon centered on the title line.
@MainActor
enum SRWelcomeRows {

	static let textWidth = CGFloat(400)
	fileprivate static let iconWidth = CGFloat(30)
	fileprivate static let iconSpacing = CGFloat(12)

	static func row(symbol: String, titleKey: String, bodyKey: String) -> NSView {
		let title = NSLocalizedString(titleKey, comment: "")

		let iconView = NSImageView()
		iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
		iconView.contentTintColor = .controlAccentColor
		iconView.translatesAutoresizingMaskIntoConstraints = false

		let bodyWidth = Self.textWidth - Self.iconWidth - Self.iconSpacing
		let titleView = Self.label(
			title,
			font: NSFont.systemFont(ofSize: 13, weight: .bold),
			maxWidth: bodyWidth
		)
		let bodyView = Self.label(
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
			iconView.widthAnchor.constraint(equalToConstant: Self.iconWidth),
			// Symbol glyphs fill their boxes unevenly, so edge-alignment
			// reads as scattered; center-anchoring hides that. Anchor to the
			// title, not the text block: body length varies per row, and
			// block-centering drags the icon away from its heading.
			iconView.centerYAnchor.constraint(equalTo: titleView.centerYAnchor),

			text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.iconWidth + Self.iconSpacing),
			text.trailingAnchor.constraint(equalTo: row.trailingAnchor),
			text.topAnchor.constraint(equalTo: row.topAnchor),
			text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
		])

		return row
	}

	static func label(
		_ text: String,
		font: NSFont,
		color: NSColor = .labelColor,
		maxWidth: CGFloat = SRWelcomeRows.textWidth
	) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = font
		label.textColor = color
		label.isSelectable = false
		label.preferredMaxLayoutWidth = maxWidth
		return label
	}

}
