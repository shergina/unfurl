//
//  SRSettingsWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The Settings window: a standard titled window with toolbar-style tab
/// pages (the System Settings look), shown from the menu. Owned as a
/// single lazily created instance by SRMenuController, like About.
class SRSettingsWindowController: NSWindowController {

	/// Set by the owner before showWindow; the Posture page's per-camera
	/// Calibrate buttons route through here so every calibration entry point
	/// funnels into the same window (see SRMenuController.showPostureCalibration).
	/// The device id names which camera's row was clicked; nil means the
	/// active one.
	var onCalibrate: ((String?) -> Void)?

	override func loadWindow() {
		let window = NSWindow(
			contentRect: CGRect(x: 0.0, y: 0.0, width: 540.0, height: 320.0),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: true
		)
		window.toolbarStyle = .preference
		window.isReleasedWhenClosed = false
		self.window = window

		let tabs = SRSettingsTabViewController()
		tabs.onCalibrate = { [weak self] deviceID in self?.onCalibrate?(deviceID) }
		self.contentViewController = tabs

		window.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label

		// First open only (the instance is kept, so a reopen keeps the
		// user's placement): on the screen where the menu was clicked, not
		// center()'s primary-display fallback.
		if let screen = NSScreen.interaction {
			window.center(on: screen)
		}
	}

	override func showWindow(_ sender: Any?) {
		super.showWindow(sender)

		// Bring the window forward without touching the activation policy.
		// While the Dock tile is off that policy is .prohibited, so the
		// activate call is ignored and makeKeyAndOrderFront only orders
		// within our own inactive app; orderFrontRegardless forces this one
		// jump above other apps' windows. It is a one-time ordering, not a
		// floating level: any window clicked afterwards covers us normally.
		self.window!.makeKeyAndOrderFront(sender)
		self.window!.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

}


/// The toolbar tabs. The window title follows the selected page, like
/// System Settings.
fileprivate final class SRSettingsTabViewController: NSTabViewController {

	var onCalibrate: ((String?) -> Void)?

	override func viewDidLoad() {
		self.tabStyle = .toolbar

		func item(_ controller: NSViewController, labelKey: String, symbolName: String) -> NSTabViewItem {
			let item = NSTabViewItem(viewController: controller)
			item.label = NSLocalizedString(labelKey, comment: "")
			item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.label)
			return item
		}

		self.addTabViewItem(item(
			SRSettingsGeneralViewController(),
			labelKey: "settings.tab.general",
			symbolName: "gearshape"
		))
		self.addTabViewItem(item(
			SRSettingsPostureViewController(onCalibrate: { [weak self] deviceID in self?.onCalibrate?(deviceID) }),
			labelKey: "settings.tab.posture",
			symbolName: "figure.stand"
		))
		self.addTabViewItem(item(
			SRSettingsNotificationsViewController(),
			labelKey: "settings.tab.notifications",
			symbolName: "bell"
		))

		super.viewDidLoad()
	}

	override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
		super.tabView(tabView, didSelect: tabViewItem)
		if let label = tabViewItem?.label {
			self.view.window?.title = label
		}
	}

}
