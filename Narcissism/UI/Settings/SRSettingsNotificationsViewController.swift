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
/// status-item tint), and the snooze. The sound picker previews on
/// selection.
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

		// The channels; all independent, all off means silent tracking.
		addRow(
			"settings.notifications.channels.label",
			SRPreferenceCheckbox(titleKey: "settings.notifications.channel.note", preference: self.settings.postureNoteEnabled)
		)
		grid.addRow(with: [
			NSGridCell.emptyContentView,
			SRPreferenceCheckbox(titleKey: "settings.notifications.channel.sound", preference: self.settings.postureSoundEnabled),
		])
		grid.addRow(with: [
			NSGridCell.emptyContentView,
			SRPreferenceCheckbox(titleKey: "settings.notifications.channel.status-item", preference: self.settings.postureStatusItemTint),
		])

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
		addRow("settings.notifications.sound.label", soundPopup)

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
			grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20.0),
			grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20.0),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		self.preferredContentSize = CGSize(width: 540.0, height: max(300.0, self.view.fittingSize.height))
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
