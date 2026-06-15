//
//  SRSettingsNotificationsViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The Notifications page: how long bad posture must persist before a
/// nudge, which channels it arrives through (corner note, sound,
/// status-item tint), the note's ghost mode, and the snooze. The sound
/// picker previews on selection.
final class SRSettingsNotificationsViewController: NSViewController {

	fileprivate let settings = SRSettings.sharedInstance
	fileprivate var delayPopup: NSPopUpButton!
	fileprivate var soundPopup: NSPopUpButton!
	fileprivate var snoozePopup: NSPopUpButton!
	fileprivate var previewSound: NSSound?
	fileprivate var cancellables = Set<AnyCancellable>()

	fileprivate static let delayOptions: [(titleKey: String, seconds: Int)] = [
		("settings.notifications.delay.5-seconds", 5),
		("settings.notifications.delay.10-seconds", 10),
		("settings.notifications.delay.30-seconds", 30),
		("settings.notifications.delay.1-minute", 60),
		("settings.notifications.delay.5-minutes", 300),
	]

	// The same durations the menu's Snooze submenu offers.
	fileprivate static let snoozeDurations: [(titleKey: String, seconds: Int)] = [
		("menu.posture-snooze.5-minutes", 5 * 60),
		("menu.posture-snooze.10-minutes", 10 * 60),
		("menu.posture-snooze.15-minutes", 15 * 60),
		("menu.posture-snooze.30-minutes", 30 * 60),
		("menu.posture-snooze.1-hour", 60 * 60),
		("menu.posture-snooze.2-hours", 2 * 60 * 60),
		("menu.posture-snooze.5-hours", 5 * 60 * 60),
	]

	// The tag of the inert "Until <time>" state line while snoozed.
	fileprivate static let snoozeStateTag = -1

	fileprivate static let snoozeTimeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		formatter.dateStyle = .none
		return formatter
	}()

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let grid = NSGridView(numberOfColumns: 2, rows: 0)
		grid.translatesAutoresizingMaskIntoConstraints = false
		grid.rowSpacing = 10.0
		grid.columnSpacing = 12.0
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).xPlacement = .leading

		func addRow(_ labelKey: String, _ control: NSView) {
			let label = NSTextField(labelWithString: NSLocalizedString(labelKey, comment: ""))
			let row = grid.addRow(with: [label, control])
			row.yPlacement = .center
		}

		// How long the issue must persist before any channel speaks up.
		let delayPopup = NSPopUpButton()
		for option in Self.delayOptions {
			delayPopup.addItem(withTitle: NSLocalizedString(option.titleKey, comment: ""))
			delayPopup.lastItem!.tag = option.seconds
		}
		delayPopup.target = self
		delayPopup.action = #selector(SRSettingsNotificationsViewController.handleDelayChange(_:))
		self.settings.postureNudgeDelay.publisher
			.sink { [weak delayPopup] seconds in
				// Select the closest offered step, so an off-list stored
				// value still shows something sensible.
				guard let delayPopup else { return }
				let closest = Self.delayOptions.min { abs(CGFloat($0.seconds) - seconds) < abs(CGFloat($1.seconds) - seconds) }!
				delayPopup.selectItem(withTag: closest.seconds)
			}
			.store(in: &self.cancellables)
		self.delayPopup = delayPopup
		addRow("settings.notifications.delay.label", delayPopup)

		// The channels, each an independent toggle (all off means silent
		// tracking), stacked in the control column with a channel's own
		// sub-option nested one indent under it, so the dependency reads at a
		// glance: the note's ghost mode under the note, the sound picker under
		// the sound. The status-item tint has no sub-option. This replaces the
		// old flat list where those options were sibling rows repeating the
		// channel name; the checkbox above now names them. The "Notify with"
		// label baseline-aligns to the first checkbox.
		func indented(_ view: NSView) -> NSView {
			let spacer = NSView()
			spacer.translatesAutoresizingMaskIntoConstraints = false
			spacer.widthAnchor.constraint(equalToConstant: 18.0).isActive = true
			let row = NSStackView(views: [spacer, view])
			row.orientation = .horizontal
			row.spacing = 0.0
			return row
		}

		let noteCheckbox = SRPreferenceCheckbox(titleKey: "settings.notifications.channel.note", preference: self.settings.postureNoteEnabled)

		// The note's ghost mode; only meaningful while the note channel is
		// on, so it disables with it (the sound picker pattern).
		let ghostCheckbox = SRPreferenceCheckbox(titleKey: "settings.notifications.note-ghost", preference: self.settings.postureNoteGhost)
		self.settings.postureNoteEnabled.publisher
			.sink { [weak ghostCheckbox] enabled in ghostCheckbox?.isEnabled = enabled }
			.store(in: &self.cancellables)

		let soundCheckbox = SRPreferenceCheckbox(titleKey: "settings.notifications.channel.sound", preference: self.settings.postureSoundEnabled)

		// The sound picker sits bare under the Sound checkbox: the checkbox
		// above already says Sound, so no repeated label. Disabled with the
		// sound channel; selecting persists the name and previews it once.
		let soundPopup = NSPopUpButton()
		for name in SRPostureSoundController.soundNames {
			// System sound names are proper nouns; not localized.
			soundPopup.addItem(withTitle: name)
		}
		soundPopup.target = self
		soundPopup.action = #selector(SRSettingsNotificationsViewController.handleSoundChange(_:))
		self.settings.postureSoundName.publisher
			.sink { [weak soundPopup] name in soundPopup?.selectItem(withTitle: name) }
			.store(in: &self.cancellables)
		self.settings.postureSoundEnabled.publisher
			.sink { [weak soundPopup] enabled in soundPopup?.isEnabled = enabled }
			.store(in: &self.cancellables)
		self.soundPopup = soundPopup

		let statusItemCheckbox = SRPreferenceCheckbox(titleKey: "settings.notifications.channel.status-item", preference: self.settings.postureStatusItemTint)

		let channelsStack = NSStackView(views: [
			noteCheckbox,
			indented(ghostCheckbox),
			soundCheckbox,
			indented(soundPopup),
			statusItemCheckbox,
		])
		channelsStack.orientation = .vertical
		channelsStack.alignment = .leading
		channelsStack.spacing = 8.0
		let channelsLabel = NSTextField(labelWithString: NSLocalizedString("settings.notifications.channels.label", comment: ""))
		let channelsRow = grid.addRow(with: [channelsLabel, channelsStack])
		channelsRow.rowAlignment = .firstBaseline

		// A rule sets Snooze apart from the delivery settings above: it is a
		// temporary pause, not configuration of how a nudge arrives. Same
		// group-sized gap and full-width fill as the Posture tab's rule, so
		// the two tabs group the same way.
		let snoozeSeparator = NSBox()
		snoozeSeparator.boxType = .separator
		snoozeSeparator.translatesAutoresizingMaskIntoConstraints = false
		let snoozeSeparatorContainer = NSView()
		snoozeSeparatorContainer.addSubview(snoozeSeparator)
		NSLayoutConstraint.activate([
			snoozeSeparator.leadingAnchor.constraint(equalTo: snoozeSeparatorContainer.leadingAnchor),
			snoozeSeparator.trailingAnchor.constraint(equalTo: snoozeSeparatorContainer.trailingAnchor),
			snoozeSeparator.centerYAnchor.constraint(equalTo: snoozeSeparatorContainer.centerYAnchor),
			snoozeSeparatorContainer.heightAnchor.constraint(equalToConstant: 20.0),
		])
		let snoozeSeparatorRow = grid.addRow(with: [snoozeSeparatorContainer])
		snoozeSeparatorRow.mergeCells(in: NSRange(location: 0, length: 2))
		snoozeSeparatorRow.cell(at: 0).xPlacement = .fill

		// Snooze: the menu's durations as a popup, rebuilt on every deadline
		// change so it mirrors the menu's states - "Off" when idle, and while
		// snoozed an "Until <time>" state line plus an explicit Resume Now
		// item. Only meaningful while tracking is on: with tracking off the
		// composition root clears any snooze immediately, so the popup
		// disables rather than offering a write that would bounce.
		let snoozePopup = NSPopUpButton()
		snoozePopup.target = self
		snoozePopup.action = #selector(SRSettingsNotificationsViewController.handleSnoozeChange(_:))
		// Assign before subscribing: the publisher replays synchronously and
		// the rebuild reaches the popup through the property.
		self.snoozePopup = snoozePopup
		self.settings.postureSnoozeUntil.publisher
			.sink { [weak self] deadline in self?.rebuildSnoozePopup(deadline: deadline) }
			.store(in: &self.cancellables)
		self.settings.postureTracking.publisher
			.sink { [weak snoozePopup] tracking in snoozePopup?.isEnabled = tracking }
			.store(in: &self.cancellables)
		addRow("settings.notifications.snooze.label", snoozePopup)

		let view = NSView()
		view.addSubview(grid)
		// Top-anchored, never bottom-pinned: a page taller than its content
		// keeps the rows together at the top instead of stretching them apart.
		NSLayoutConstraint.activate([
			grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20.0),
			grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28.0),
			grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20.0),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		self.preferredContentSize = CGSize(width: 540.0, height: self.view.fittingSize.height)
	}

	@objc fileprivate func handleDelayChange(_ sender: Any?) {
		guard let seconds = self.delayPopup.selectedItem?.tag else { return }
		self.settings.postureNudgeDelay.value = CGFloat(seconds)
	}

	/// Rebuilds the popup for the current deadline. Idle: "Off" (selected)
	/// over the durations. Snoozed: an "Until <time>" state line (selected),
	/// the durations, and an explicit Resume Now - the same shape the menu's
	/// Snooze submenu has, so turning a snooze off is always one visible
	/// choice away.
	fileprivate func rebuildSnoozePopup(deadline: Date) {
		let popup = self.snoozePopup!
		popup.removeAllItems()

		let snoozed = deadline > Date.now
		if snoozed {
			popup.addItem(withTitle: String(
				format: NSLocalizedString("settings.notifications.snooze.until", comment: ""),
				Self.snoozeTimeFormatter.string(from: deadline)
			))
			popup.lastItem!.tag = Self.snoozeStateTag
		} else {
			popup.addItem(withTitle: NSLocalizedString("settings.notifications.snooze.off", comment: ""))
			popup.lastItem!.tag = 0
		}
		popup.menu?.addItem(NSMenuItem.separator())

		for duration in Self.snoozeDurations {
			popup.addItem(withTitle: NSLocalizedString(duration.titleKey, comment: ""))
			popup.lastItem!.tag = duration.seconds
		}

		if snoozed {
			popup.menu?.addItem(NSMenuItem.separator())
			popup.addItem(withTitle: NSLocalizedString("menu.posture-snooze.resume", comment: ""))
			popup.lastItem!.tag = 0
		}

		popup.selectItem(at: 0)
	}

	/// Tag 0 clears the deadline (Off / Resume Now); a duration replaces it
	/// counting from now, exactly like the menu; the state line is inert.
	@objc fileprivate func handleSnoozeChange(_ sender: Any?) {
		guard let seconds = self.snoozePopup.selectedItem?.tag, seconds != Self.snoozeStateTag else {
			return
		}
		self.settings.postureSnoozeUntil.value = seconds == 0
			? .distantPast
			: Date.now.addingTimeInterval(TimeInterval(seconds))
	}

	/// Persists the pick and plays it once, so the beeps can be auditioned
	/// right in the popup.
	@objc fileprivate func handleSoundChange(_ sender: Any?) {
		guard let name = self.soundPopup.selectedItem?.title else { return }
		self.settings.postureSoundName.value = name
		self.previewSound?.stop()
		self.previewSound = NSSound(named: name)
		self.previewSound?.play()
	}

}
