//
//  SRNarcissismApplicationDelegate.swift
//  Narcissism
//
//  Created by Maria Shergina on 19/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine
import AVFoundation


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
	fileprivate var postureCalibrationNudgeController: SRPostureCalibrationNudgeController!
	fileprivate var postureSnoozeTimer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// The selected-camera preference is the source of truth; translate it
		// into a live device switch (replays the persisted value on launch).
		self.services.settings.selectedCameraDeviceID.publisher
			.sink { [services] id in services.camera.selectDevice(id: id) }
			.store(in: &self.cancellables)

		// Automatic's default-camera policy: prefer the monitor's camera when
		// docked. The camera service re-resolves the active device on change.
		self.services.settings.preferExternalCamera.publisher
			.sink { [services] prefer in services.camera.setPreferExternalCamera(prefer) }
			.store(in: &self.cancellables)

		// The calibration gate on that takeover: while posture tracking is
		// on, Automatic may only auto-prefer externals with a usable slouch
		// span - measured (the anchor's own two-pose) or derived from the
		// anchor via the camera's geometry probe. No baseline would
		// silently mute tracking; a baseline without any span runs on the
		// nominal rule, which is known to be badly miscalibrated exactly on
		// elevated monitor cameras - the cameras takeover is about - so
		// neither may take over on its own (in clamshell the monitor is the
		// only camera and gets used regardless). Tracking off lifts the
		// restriction (pure mirror use, nothing to break). The rule's
		// inputs are pushed ahead of time, so a camera hot-plugged later is
		// judged against the already-current set. Anchor changes always
		// ride a baselines write (the anchor is stored first), so the map
		// publisher alone keeps this sink current.
		self.services.settings.postureTracking.publisher
			.combineLatest(self.services.settings.postureBaselines.publisher)
			.sink { [services] tracking, baselines in
				let calibrated = Set(baselines.filter {
					services.settings.postureEffectiveSlouchSpan(for: $0.value) != nil
				}.keys)
				services.camera.setAutoSwitchableExternalIDs(tracking ? calibrated : nil)
			}
			.store(in: &self.cancellables)

		// One-time: fold a pre-per-camera install's single baseline into the
		// built-in camera's slot (where Automatic always measured it). Waits
		// for a real device to resolve so authorization has settled and the
		// built-in default exists; runs once, then the legacy keys are cleared.
		self.services.camera.onSelectedDeviceID
			.filter { !$0.isEmpty }
			.first()
			.sink { [services] _ in
				// The built-in explicitly, not AVCaptureDevice.default (macOS
				// points that at a nearby iPhone), so the old baseline lands on
				// the camera Automatic actually measured it on.
				let builtInID = AVCaptureDevice.DiscoverySession(
					deviceTypes: [.builtInWideAngleCamera],
					mediaType: .video,
					position: .unspecified
				).devices.first?.uniqueID ?? ""
				services.settings.migrateLegacyBaselineIfNeeded(deviceID: builtInID)
			}
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

		// The welcome tutorial's Locate Me points at the status item; the
		// cross-surface wiring lives here, like the panel's.
		self.services.menu.onLocateStatusItem = { [weak statusItem] in statusItem?.locate() }

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

		// The calibration nudge: when the gate above blocks a takeover (an
		// uncalibrated monitor camera appeared while tracking is on), a
		// system notification offers to calibrate it.
		self.postureCalibrationNudgeController = SRPostureCalibrationNudgeController(services: self.services)

		// Welcome window: first launch only. Dismissing it (any path) flips
		// the flag, so the flow shows until the user has closed it once
		// (see UI/Welcome/spec.md).
		if !self.services.settings.hasCompletedOnboarding.value {
			self.services.menu.showWelcome()
		}
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

			// Never calibrated anywhere -> open calibration instead of
			// tracking blind. Covers the fresh toggle-on, launch replay, and
			// snooze expiry; re-emissions land on idempotent calls. The check
			// is the whole map, not the active camera: toggling tracking on
			// also flips the calibration gate, which may still be switching
			// the camera underneath us, and any camera the gate settles on is
			// calibrated whenever one baseline exists. An uncalibrated camera
			// the user picked explicitly tracks quiet instead (Posture spec).
			if self.services.settings.postureBaselines.value.isEmpty {
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

	func applicationWillTerminate(_ notification: Notification) {
		// The one synchronous history write: unsaved posture counts must
		// not die with the process.
		self.services.postureHistory.flushNow()
	}

}
