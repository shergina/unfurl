//
//  SRSettingsControls.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// A switch bound both ways to a Bool preference: the preference's
/// publisher drives the state, toggling writes the value back.
final class SRPreferenceSwitch: NSSwitch {

	fileprivate var preference: Preference<Bool>!
	fileprivate var cancellable: AnyCancellable?

	convenience init(preference: Preference<Bool>) {
		self.init()
		self.preference = preference
		self.target = self
		self.action = #selector(SRPreferenceSwitch.handleToggle(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in self?.state = value ? .on : .off }
	}

	@objc fileprivate func handleToggle(_ sender: Any?) {
		self.preference.value = (self.state == .on)
	}

}


/// A tick-marked slider over a fixed ladder of values for a CGFloat
/// preference, bound both ways: the publisher selects the nearest stop
/// (so an off-ladder stored value still shows something sensible),
/// dragging writes the stop's value back.
final class SRPreferenceStepSlider: NSSlider {

	fileprivate var preference: Preference<CGFloat>!
	fileprivate var stops: [CGFloat] = []
	fileprivate var cancellable: AnyCancellable?

	convenience init(stops: [CGFloat], preference: Preference<CGFloat>) {
		self.init(value: 0, minValue: 0, maxValue: Double(stops.count - 1), target: nil, action: nil)
		self.stops = stops
		self.preference = preference
		self.numberOfTickMarks = stops.count
		self.allowsTickMarkValuesOnly = true
		self.target = self
		self.action = #selector(SRPreferenceStepSlider.handleChange(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in
				guard let self else { return }
				let nearest = self.stops.indices.min { abs(self.stops[$0] - value) < abs(self.stops[$1] - value) }!
				self.doubleValue = Double(nearest)
			}
	}

	@objc fileprivate func handleChange(_ sender: Any?) {
		self.preference.value = self.stops[Int(self.doubleValue.rounded())]
	}

}


/// The contents of a tip popover: a lightbulb, a title, and a wrapping body.
fileprivate final class SRSettingsTipViewController: NSViewController {

	/// A comfortable measure for three or four lines, kept deliberately
	/// narrower than the page it springs from: at 240 the bubble came out
	/// about half the width of the settings window, which reads as oversized
	/// for a few lines of help even though a popover is entitled to overflow
	/// its parent window.
	fileprivate static let contentWidth: CGFloat = 200.0

	fileprivate static let padding: CGFloat = 14.0

	fileprivate let titleKey: String
	fileprivate let bodyKey: String

	init(titleKey: String, bodyKey: String) {
		self.titleKey = titleKey
		self.bodyKey = bodyKey
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let icon = NSImageView()
		icon.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)
		icon.symbolConfiguration = NSImage.SymbolConfiguration(
			pointSize: NSFont.smallSystemFontSize,
			weight: .semibold
		)
		icon.contentTintColor = NSColor.secondaryLabelColor

		let title = NSTextField(labelWithString: NSLocalizedString(self.titleKey, comment: ""))
		title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

		let heading = NSStackView(views: [icon, title])
		heading.orientation = .horizontal
		heading.spacing = 5.0
		heading.alignment = .firstBaseline

		let body = NSTextField(wrappingLabelWithString: NSLocalizedString(self.bodyKey, comment: ""))
		body.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		body.textColor = NSColor.secondaryLabelColor
		body.isSelectable = false
		body.preferredMaxLayoutWidth = SRSettingsTipViewController.contentWidth

		let stack = NSStackView(views: [heading, body])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 5.0
		stack.translatesAutoresizingMaskIntoConstraints = false

		let view = NSView()
		view.addSubview(stack)

		let padding = SRSettingsTipViewController.padding
		NSLayoutConstraint.activate([
			body.widthAnchor.constraint(equalToConstant: SRSettingsTipViewController.contentWidth),
			stack.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
			stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
		])
		self.view = view
	}

}


/// An info button that reveals a tip in a popover, for advice that belongs
/// to one control but is not itself a setting. On demand rather than on the
/// page: nothing to dismiss, nothing to restore, and the page keeps the
/// rhythm of its rows.
///
/// The popover is `.transient` - it closes on the next click anywhere - so
/// it behaves like every other informational popover on the system, and the
/// tip cannot be left open cluttering the page.
final class SRSettingsTipButton: NSButton {

	fileprivate let popover = NSPopover()

	convenience init(titleKey: String, bodyKey: String, accessibilityKey: String) {
		self.init(frame: .zero)

		self.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
		self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.0, weight: .regular)
		self.contentTintColor = NSColor.secondaryLabelColor
		self.imagePosition = .imageOnly
		self.isBordered = false
		self.bezelStyle = .inline
		self.title = ""
		self.target = self
		self.action = #selector(SRSettingsTipButton.showTip(_:))

		// The symbol alone says nothing out loud; name what it is about.
		self.setAccessibilityLabel(NSLocalizedString(accessibilityKey, comment: ""))
		self.toolTip = NSLocalizedString(accessibilityKey, comment: "")

		self.popover.behavior = .transient
		self.popover.contentViewController = SRSettingsTipViewController(titleKey: titleKey, bodyKey: bodyKey)
	}

	@objc fileprivate func showTip(_ sender: Any?) {
		guard !self.popover.isShown else {
			self.popover.performClose(sender)
			return
		}
		// Opens into the page's empty right-hand gutter, which is the room
		// the inline card used to occupy permanently.
		self.popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxX)
	}

}


/// The checkbox flavor of the same two-way preference binding.
final class SRPreferenceCheckbox: NSButton {

	fileprivate var preference: Preference<Bool>!
	fileprivate var cancellable: AnyCancellable?

	convenience init(titleKey: String, preference: Preference<Bool>) {
		self.init(checkboxWithTitle: NSLocalizedString(titleKey, comment: ""), target: nil, action: nil)
		self.preference = preference
		self.target = self
		self.action = #selector(SRPreferenceCheckbox.handleToggle(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in self?.state = value ? .on : .off }
	}

	@objc fileprivate func handleToggle(_ sender: Any?) {
		self.preference.value = (self.state == .on)
	}

}
