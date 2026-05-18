//
//  SRNarcissismApplicationDelegate.swift
//  Narcissism
//
//  Created by Maria Shergina on 19/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


@MainActor
class SRNarcissismApplicationDelegate: NSObject, NSApplicationDelegate {

	// The composition root: build the services once, then the surfaces, wiring
	// their few cross-surface dependencies explicitly here (the panel needs the
	// status item's hover and anchor). Nothing reaches back through the delegate.
	fileprivate let services = AppServices.production()
	fileprivate var cancellables = Set<AnyCancellable>()

	fileprivate var statusItemController: SRStatusItemController!
	fileprivate var panelController: SRPanelController!
	fileprivate var dockTileController: SRDockTileController!
	fileprivate var hotKeyController: SRHotKeyController!

	func applicationDidFinishLaunching(_ notification: Notification) {
		// The selected-camera preference is the source of truth; translate it
		// into a live device switch (replays the persisted value on launch).
		self.services.settings.selectedCameraDeviceID.publisher
			.sink { [services] id in services.camera.selectDevice(id: id) }
			.store(in: &self.cancellables)

		// Global shortcuts, bound to the same preferences and commands the menu
		// drives, so a shortcut and its menu item stay in lockstep.
		self.hotKeyController = SRHotKeyController(actions: SRHotKeyActions(
			togglePanel: { [services] in services.settings.cameraPanelPinned.toggle() },
			takePhoto: { [services] in services.photo.capture() },
			toggleMirror: { [services] in services.settings.flipCameraHorizontally.toggle() },
			cycleCamera: { [weak self] in self?.cycleCamera() }
		))

		let statusItem = SRStatusItemController(services: self.services)
		self.statusItemController = statusItem
		self.panelController = SRPanelController(services: self.services, statusItemController: statusItem)
		self.dockTileController = SRDockTileController(services: self.services)

		// The posture probe (Posture/spec.md) logs the shoulder distance once
		// per second; while attached it keeps the shared camera session
		// running for the whole app lifetime.
		self.services.posture.start()
	}

	/// Advance the selected camera one step through Automatic then each
	/// connected device, wrapping around. Writes the preference, which the
	/// subscription above turns into a live switch.
	fileprivate func cycleCamera() {
		let devices = self.services.camera.onDevices.value
		guard !devices.isEmpty else { return }

		let options = [""] + devices.map { $0.id }  // "" is Automatic
		let current = self.services.settings.selectedCameraDeviceID.value
		let index = options.firstIndex(of: current) ?? 0
		self.services.settings.selectedCameraDeviceID.value = options[(index + 1) % options.count]
	}

	func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
		return self.services.menu.menuForDock()
	}

}
