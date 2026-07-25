//
//  SRMenuController.swift
//  Narcissism
//
//  Created by Maria Shergina on 21/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


class NSMenuItemWithClosure: NSMenuItem {

	var actionClosure: () -> ()
	var cancellables = Set<AnyCancellable>()

	init(title: String, keyEquivalent: String, action: @escaping () -> ()) {
		self.actionClosure = action
		super.init(title: title, action: #selector(NSMenuItemWithClosure.action(_:)), keyEquivalent: keyEquivalent)
		self.target = self
	}

	required init(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	@objc func action(_ sender: NSMenuItem) {
		self.actionClosure()
	}

	override func copy(with zone: NSZone?) -> Any {
		let menu = NSMenuItemWithClosure(title: self.title, keyEquivalent: self.keyEquivalent, action: self.actionClosure)
		menu.state = self.state
		menu.isEnabled = self.isEnabled
		menu.isHidden = self.isHidden
		return menu
	}
}


@MainActor
class SRMenuController: NSObject {

	static let sharedInstance = SRMenuController()

	fileprivate let preferences = SRSettings.sharedInstance
	fileprivate var aboutWindowController: SRAboutWindowController? = nil
	fileprivate var settingsWindowController: SRSettingsWindowController? = nil
	fileprivate var statisticsWindowController: SRStatisticsWindowController? = nil
	fileprivate var postureCalibrationWindowController: SRPostureCalibrationWindowController? = nil
	fileprivate var welcomeWindowController: SRWelcomeWindowController? = nil


	fileprivate let showQuitMenuItem = CurrentValueSubject<Bool, Never>(false)

	fileprivate var menu: NSMenu?
	fileprivate var cancellables = Set<AnyCancellable>()

	override init() {
		super.init()

		self.menu = self.createMenu()
	}

	typealias BoolPublisher = AnyPublisher<Bool, Never>

	func createMenuItem(
		_ title: String,
		keyEquivalent: String = "",
		keyEquivalentModifierMask: NSEvent.ModifierFlags = [],
		checked: BoolPublisher? = nil,
		enabled: BoolPublisher? = nil,
		visible: BoolPublisher? = nil,
		action: (() -> ())? = nil
	) -> NSMenuItem {
		let menuItem =
			NSMenuItemWithClosure(
				title: NSLocalizedString(title, comment: ""),
				keyEquivalent: keyEquivalent
			) {
				if let action = action {
					action()
				}
			}

		// The status/Dock menu is not the main menu, so a key equivalent here is
		// only matched while the menu is open - it just displays the glyph. The
		// shortcut actually fires globally through SRHotKeyController.
		menuItem.keyEquivalentModifierMask = keyEquivalentModifierMask

		if let checked = checked {
			checked
				.sink { [unowned menuItem] in
					menuItem.state = $0 ? .on : .off
				}
				.store(in: &menuItem.cancellables)
		}

		if let enabled = enabled {
			enabled
				.sink { [unowned menuItem] in menuItem.isEnabled = $0 }
				.store(in: &menuItem.cancellables)
		}

		if let visible = visible {
			visible
				.sink { [unowned menuItem] in
					menuItem.isHidden = !$0
					menuItem.isEnabled = $0
				}
				.store(in: &menuItem.cancellables)
		}

		return menuItem;
	}

	/// A toggle's checked state: its preference, and-ed with camera
	/// availability so a checked feature never claims to run cameraless.
	fileprivate func preferenceAndCameraAvailable(_ preference: Preference<Bool>) -> BoolPublisher {
		return preference.publisher
			.combineLatest(SRCameraService.sharedInstance.onCaptureDeviceAvailable)
			.map { $0 && $1 }
			.eraseToAnyPublisher()
	}

	func createMenu() -> NSMenu {
		let menu = NSMenu(title: "")
		menu.autoenablesItems = false

		let onCaptureDeviceAvailable = SRCameraService.sharedInstance.onCaptureDeviceAvailable.eraseToAnyPublisher()

		// Track Posture
		menu.addItem(self.createMenuItem(
			"menu.track-posture",
			checked: preferenceAndCameraAvailable(self.preferences.postureTracking),
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.postureTracking.toggle()
		})

		// Snooze (posture): the hover submenu with the pause durations.
		menu.addItem(self.makePostureSnoozeItem())

		// Calibrate Posture: same visibility rule as Snooze. Calibrating
		// while snoozed clears the snooze.
		// "for This Camera" says the scope without naming the device: the name
		// made this item set the menu's width, and made that width change on
		// every dock and undock. The calibration window names the device.
		menu.addItem(self.createMenuItem(
			"menu.calibrate-posture",
			visible: preferenceAndCameraAvailable(self.preferences.postureTracking)
		) {
			SRSettings.sharedInstance.postureSnoozeUntil.value = .distantPast
			self.showPostureCalibration()
		})

		menu.addItem(NSMenuItem.separator())

		// Take Photo: the one camera action, kept top-level; the camera
		// options live one hover away in the submenu below it.
		menu.addItem(self.createMenuItem(
			"menu.take-photo",
			keyEquivalent: SRHotKeyController.takePhotoKeyEquivalent,
			keyEquivalentModifierMask: SRHotKeyController.modifiers,
			enabled: onCaptureDeviceAvailable
		) {
			SRPhotoCaptureService.sharedInstance.capture()
		})

		// Camera: every camera control in one submenu (see spec.md).
		menu.addItem(self.makeCameraItem())

		menu.addItem(NSMenuItem.separator())

		// Statistics
		menu.addItem(self.createMenuItem(
			"menu.statistics"
		) {
			self.showStatistics()
		})

		// Settings
		menu.addItem(self.createMenuItem(
			"menu.settings"
		) {
			self.showSettings()
		})

		// About
		menu.addItem(self.createMenuItem(
			"menu.about"
		) {
			self.showAboutDialog()
		})

		menu.addItem(NSMenuItem.separator())

		menu.addItem(self.createMenuItem(
			"menu.quit",
			visible: self.showQuitMenuItem.eraseToAnyPublisher()
		) {
			NSApplication.shared.terminate(self)
		})

		return menu
	}

	/// The posture "Snooze" parent item with the duration submenu, visible
	/// only while posture tracking is on (and a camera exists, matching the
	/// toggle's checked state). Choosing a duration writes the snooze
	/// deadline preference; the composition root turns that into a paused
	/// probe and a resume timer. While snoozed the title names the deadline
	/// and a "Resume Now" item appears as the whole-snooze off switch; both
	/// follow the preference, which the resume timer clears, so the menu
	/// never shows a stale snooze.
	fileprivate func makePostureSnoozeItem() -> NSMenuItem {
		let parent = NSMenuItem(
			title: NSLocalizedString("menu.posture-snooze", comment: ""),
			action: nil,
			keyEquivalent: ""
		)
		let submenu = NSMenu(title: "")
		submenu.autoenablesItems = false
		parent.submenu = submenu

		let durations: [(title: String, interval: TimeInterval)] = [
			("menu.posture-snooze.5-minutes", 5 * 60),
			("menu.posture-snooze.10-minutes", 10 * 60),
			("menu.posture-snooze.15-minutes", 15 * 60),
			("menu.posture-snooze.30-minutes", 30 * 60),
			("menu.posture-snooze.1-hour", 60 * 60),
			("menu.posture-snooze.2-hours", 2 * 60 * 60),
			("menu.posture-snooze.5-hours", 5 * 60 * 60),
		]
		for duration in durations {
			submenu.addItem(NSMenuItemWithClosure(
				title: NSLocalizedString(duration.title, comment: ""),
				keyEquivalent: ""
			) {
				SRSettings.sharedInstance.postureSnoozeUntil.value = Date.now.addingTimeInterval(duration.interval)
			})
		}

		let separator = NSMenuItem.separator()
		submenu.addItem(separator)

		let resume = NSMenuItemWithClosure(
			title: NSLocalizedString("menu.posture-snooze.resume", comment: ""),
			keyEquivalent: ""
		) {
			SRSettings.sharedInstance.postureSnoozeUntil.value = .distantPast
		}
		submenu.addItem(resume)

		self.preferences.postureTracking.publisher
			.combineLatest(SRCameraService.sharedInstance.onCaptureDeviceAvailable)
			.map { $0 && $1 }
			.sink { [unowned parent] in parent.isHidden = !$0 }
			.store(in: &self.cancellables)

		self.preferences.postureSnoozeUntil.publisher
			.sink { [unowned parent, unowned resume, unowned separator] deadline in
				let snoozed = deadline > Date.now
				resume.isHidden = !snoozed
				separator.isHidden = !snoozed
				parent.title = snoozed
					? String(
						format: NSLocalizedString("menu.posture-snooze.snoozed-until", comment: ""),
						Self.snoozeTimeFormatter.string(from: deadline)
					)
					: NSLocalizedString("menu.posture-snooze", comment: "")
			}
			.store(in: &self.cancellables)

		return parent
	}

	fileprivate static let snoozeTimeFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeStyle = .short
		formatter.dateStyle = .none
		return formatter
	}()

	/// The "Camera" parent item: every camera control in one submenu - the
	/// surface toggles (panel, hover, menu bar, Dock), the modes (mirror,
	/// ghost), and the source list at the bottom, rebuilt as devices come
	/// and go. The parent stays enabled with no camera so the options
	/// remain discoverable; the items inside disable themselves.
	fileprivate func makeCameraItem() -> NSMenuItem {
		let parent = NSMenuItem(
			title: NSLocalizedString("menu.camera", comment: ""),
			action: nil,
			keyEquivalent: ""
		)
		let submenu = NSMenu(title: "")
		submenu.autoenablesItems = false
		parent.submenu = submenu

		let onCaptureDeviceAvailable = SRCameraService.sharedInstance.onCaptureDeviceAvailable.eraseToAnyPublisher()

		submenu.addItem(self.createMenuItem(
			"menu.show-camera-panel",
			keyEquivalent: SRHotKeyController.togglePanelKeyEquivalent,
			keyEquivalentModifierMask: SRHotKeyController.modifiers,
			checked: self.preferenceAndCameraAvailable(self.preferences.cameraPanelPinned),
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.cameraPanelPinned.toggle()
		})

		submenu.addItem(self.createMenuItem(
			"menu.show-camera-panel-on-hover",
			checked: self.preferenceAndCameraAvailable(self.preferences.showCameraPanelOnHover),
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.showCameraPanelOnHover.toggle()
		})

		submenu.addItem(self.createMenuItem(
			"menu.show-camera-on-status-bar",
			checked: self.preferenceAndCameraAvailable(self.preferences.showCameraOnStatusBar),
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.showCameraOnStatusBar.toggle()
		})

		submenu.addItem(self.createMenuItem(
			"menu.show-camera-on-dock-tile",
			checked: self.preferenceAndCameraAvailable(self.preferences.showCameraOnDockTile),
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.showCameraOnDockTile.toggle()
		})

		submenu.addItem(NSMenuItem.separator())

		submenu.addItem(self.createMenuItem(
			"menu.flip-camera-horizontally",
			keyEquivalent: SRHotKeyController.toggleMirrorKeyEquivalent,
			keyEquivalentModifierMask: SRHotKeyController.modifiers,
			checked: self.preferences.flipCameraHorizontally.publisher,
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.flipCameraHorizontally.toggle()
		})

		// Ghost Mode - also the escape hatch: a ghosted panel is click-through,
		// so its own toolbar button can't be reached to turn the mode off.
		submenu.addItem(self.createMenuItem(
			"menu.ghost-mode",
			checked: self.preferences.cameraPanelGhostMode.publisher,
			enabled: onCaptureDeviceAvailable
		) {
			self.preferences.cameraPanelGhostMode.toggle()
		})

		// The source list, one radio group after the boundary separator:
		// "Automatic" plus the connected devices, rebuilt on every device
		// or selection change. The checkmark follows the stored preference
		// (the option the user picked), not the live device.
		let sourcesBoundary = NSMenuItem.separator()
		submenu.addItem(sourcesBoundary)

		SRCameraService.sharedInstance.onDevices
			.combineLatest(self.preferences.selectedCameraDeviceID.publisher)
			.sink { [weak self, unowned submenu, unowned sourcesBoundary] devices, selectedID in
				self?.rebuildCameraSources(in: submenu, after: sourcesBoundary, devices: devices, selectedID: selectedID)
			}
			.store(in: &self.cancellables)

		return parent
	}

	fileprivate func rebuildCameraSources(in submenu: NSMenu, after boundary: NSMenuItem, devices: [CameraDevice], selectedID: String) {
		let boundaryIndex = submenu.index(of: boundary)
		guard boundaryIndex >= 0 else { return }
		while submenu.items.count > boundaryIndex + 1 {
			submenu.removeItem(at: boundaryIndex + 1)
		}

		let automatic = NSMenuItemWithClosure(
			title: NSLocalizedString("menu.camera.automatic", comment: ""),
			keyEquivalent: ""
		) {
			SRSettings.sharedInstance.selectedCameraDeviceID.value = ""
		}
		automatic.state = selectedID.isEmpty ? .on : .off
		submenu.addItem(automatic)

		for device in devices {
			let item = NSMenuItemWithClosure(title: device.name, keyEquivalent: "") {
				SRSettings.sharedInstance.selectedCameraDeviceID.value = device.id
			}
			item.state = (device.id == selectedID) ? .on : .off
			submenu.addItem(item)
		}
	}

	/// Presents the calibration window; re-fronts if already open. Every
	/// entry point (menu item, no-baseline auto-open, the new-camera nudge)
	/// funnels through here, so there is never a second window.
	/// `forDeviceID` targets a camera that is not active (the nudge's
	/// calibrate-the-new-monitor path): the window looks through it for its
	/// lifetime via the camera service's temporary override. An already-open
	/// window keeps its own target; the nudge stays delivered, so the user
	/// can come back to it.
	func showPostureCalibration(forDeviceID deviceID: String? = nil) {
		// While the welcome flow's posture page is up, that page is the one
		// calibration surface: re-front it instead of opening a second.
		if let welcome = self.welcomeWindowController, welcome.isShowingPostureCalibration {
			welcome.showWindow(self)
			return
		}

		if let existing = self.postureCalibrationWindowController {
			existing.showWindow(self)
			return
		}
		let controller = SRPostureCalibrationWindowController(windowNibName: "")
		controller.cameraOverrideDeviceID = deviceID
		controller.onClose = { [weak self] in self?.postureCalibrationWindowController = nil }
		self.postureCalibrationWindowController = controller
		controller.showWindow(self)
	}

	/// Presents the Settings window; a single kept instance, so the window
	/// (and its selected tab) survives closing and reopening.
	func showSettings() {
		if self.settingsWindowController == nil {
			let controller = SRSettingsWindowController(windowNibName: "")
			// The page's Calibrate button behaves exactly like the menu
			// item: clear any snooze, then the one shared calibration funnel.
			controller.onCalibrate = { [weak self] deviceID in
				SRSettings.sharedInstance.postureSnoozeUntil.value = .distantPast
				self?.showPostureCalibration(forDeviceID: deviceID)
			}
			self.settingsWindowController = controller
		}
		self.settingsWindowController!.showWindow(self)
	}

	/// Presents the Statistics window; a single kept instance, the
	/// Settings precedent.
	func showStatistics() {
		if self.statisticsWindowController == nil {
			self.statisticsWindowController = SRStatisticsWindowController(windowNibName: "")
		}
		self.statisticsWindowController!.showWindow(self)
	}

	/// Set by the composition root; the welcome tutorial's Locate Me routes
	/// through here to the status item controller, so the welcome surface
	/// never touches the status item directly.
	var onLocateStatusItem: (() -> Void)?

	/// Presents the welcome window; a single kept instance (the Settings
	/// precedent). Shown by the composition root on first launch; no menu
	/// item triggers it yet (see UI/Welcome/spec.md).
	func showWelcome() {
		if self.welcomeWindowController == nil {
			let controller = SRWelcomeWindowController(windowNibName: "")
			controller.onLocate = { [weak self] in self?.onLocateStatusItem?() }
			// Any dismissal counts as onboarding done; the flow never
			// reopens on its own after the first close.
			controller.onDidClose = { [preferences] in preferences.hasCompletedOnboarding.value = true }
			self.welcomeWindowController = controller
		}
		self.welcomeWindowController!.showWindow(self)
	}

	func showAboutDialog() {
		DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(0.1 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC), execute: {
			if self.aboutWindowController == nil {
				self.aboutWindowController = SRAboutWindowController(windowNibName: "")
				self.aboutWindowController!.showWindow(self)
			}
			else {
				self.aboutWindowController?.window!.orderBack(self)
				self.aboutWindowController?.window!.makeKeyAndOrderFront(self)
			}
		})
	}

	func menuForDock() -> NSMenu {
		self.showQuitMenuItem.send(false)

		var menu = self.menu!

		menu = menu.copy() as! NSMenu

		var previousItemWasSeparator = true
		for menuItem in menu.items.reversed() {
			if menuItem.isHidden {
				menu.removeItem(menuItem)
				continue
			}

			let currentItemIsSeparator = menuItem.isSeparatorItem

			if previousItemWasSeparator && currentItemIsSeparator {
				menu.removeItem(menuItem)
			}

			previousItemWasSeparator = currentItemIsSeparator
		}

		return menu
	}

	func menuForStatusBar() -> NSMenu {
		self.showQuitMenuItem.send(true)
		return self.menu!
	}

	func menuForToolbar() -> NSMenu {
		self.showQuitMenuItem.send(true)
		return self.menu!
	}
}
