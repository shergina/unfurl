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
	fileprivate var postureNoteController: SRPostureNoteController!
	fileprivate var postureSoundController: SRPostureSoundController!
	fileprivate var postureSnoozeTimer: Timer?

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

		// The posture probe (Posture/spec.md) runs while Track Posture is on
		// and any snooze deadline has passed; both preferences replay their
		// persisted values, so a relaunch resumes the stored choice and a
		// relaunch mid-snooze honors the remaining time.
		self.services.settings.postureTracking.publisher
			.combineLatest(self.services.settings.postureSnoozeUntil.publisher)
			.sink { [weak self] tracking, snoozeUntil in
				self?.applyPostureTracking(tracking, snoozeUntil: snoozeUntil)
			}
			.store(in: &self.cancellables)

		// The corner posture note observes the probe's status and shows the
		// current verdict as a ghost panel in the top-right corner; the sound
		// controller is the beep channel next to it.
		self.postureNoteController = SRPostureNoteController(services: self.services)
		self.postureSoundController = SRPostureSoundController(services: self.services)
	}

	/// Turns the two posture preferences into probe state: run while tracking
	/// is on and not snoozed. While snoozed the probe stops exactly as the
	/// toggle stops it, and a one-shot timer clears the deadline at its
	/// moment, so tracking resumes on its own and the menu's "Snoozed Until"
	/// state resets with the preference. Unchecking Track Posture discards
	/// any pending snooze: the master toggle always means a clean slate.
	/// Timers do not fire during system sleep; a deadline slept through
	/// fires on wake, which is when resuming makes sense anyway.
	fileprivate func applyPostureTracking(_ tracking: Bool, snoozeUntil: Date) {
		self.postureSnoozeTimer?.invalidate()
		self.postureSnoozeTimer = nil

		if !tracking {
			if snoozeUntil > Date.now {
				// Re-emits into this sink; the second pass sees the cleared
				// deadline and just stops again (idempotent).
				self.services.settings.postureSnoozeUntil.value = .distantPast
			}
			self.services.posture.stop()
			return
		}

		if snoozeUntil > Date.now {
			self.services.posture.stop()
			let timer = Timer(fire: snoozeUntil, interval: 0, repeats: false) { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.services.settings.postureSnoozeUntil.value = .distantPast
				}
			}
			RunLoop.main.add(timer, forMode: .common)
			self.postureSnoozeTimer = timer
		} else {
			self.services.posture.start()

			// No baseline yet -> open calibration instead of tracking
			// blind. Covers toggle-on, launch replay, and snooze expiry;
			// re-emissions land on idempotent calls.
			if self.services.settings.postureBaselineSlouchRatio.value <= 0 {
				self.services.menu.showPostureCalibration()
			}
		}
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
