//
//  SRPostureCalibrationWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The calibration window: titled, closable, centered, floating. A fresh
/// controller per presentation; SRMenuController owns the single live
/// instance. Closing it while nothing is calibrated anywhere means cancel:
/// Track Posture goes back off. With any baseline on file, closing just
/// closes and tracking continues on a calibrated camera.
@MainActor
final class SRPostureCalibrationWindowController: NSWindowController, NSWindowDelegate {

	/// The owner's hook to drop its reference once the window closes.
	var onClose: (() -> Void)?

	/// Set before showing to calibrate a camera that is not active (the
	/// new-camera nudge): applied as the camera service's temporary override
	/// for the window's lifetime, cleared on close, never persisted - so a
	/// declined calibration (or a crash) settles back onto the policy camera
	/// by itself.
	var cameraOverrideDeviceID: String?

	fileprivate var calibrationViewController: SRPostureCalibrationViewController!
	fileprivate var isClosing = false
	fileprivate var cancellables = Set<AnyCancellable>()

	override func loadWindow() {
		self.window = NSWindow(
			contentRect: CGRect(origin: .zero, size: SRPostureCalibrationViewController.contentSize),
			styleMask: [.titled, .closable, .unifiedTitleAndToolbar],
			backing: .buffered,
			defer: true
		)

		let window = self.window!
		window.title = NSLocalizedString("posture.calibration.title", comment: "")
		window.isReleasedWhenClosed = false
		window.delegate = self

		// In front of everything (a short focused task shouldn't get lost
		// behind other windows), and re-fronting pulls it to the current
		// Space instead of switching Spaces.
		window.level = .floating
		window.collectionBehavior = [.moveToActiveSpace]

		let viewController = SRPostureCalibrationViewController()
		self.calibrationViewController = viewController
		viewController.onFinished = { [weak self] in self?.close() }

		// Load the capture page now but show it second: its subscriptions go
		// live immediately, so the camera has the whole reminders page to
		// warm up and the framing guidance is already right when it appears.
		_ = viewController.view

		// The reminders come first, on every calibration - the baseline is
		// whatever the user holds during the capture, and a bad one fails
		// silently. Both pages are contentSize, so the window does not
		// resize mid-flow (it is floating and centered, so a resize would
		// move it under a user who is trying to hold still).
		let remindersViewController = SRPostureRemindersViewController()
		remindersViewController.onReady = { [weak self] in
			self?.contentViewController = self?.calibrationViewController
		}
		self.contentViewController = remindersViewController

		// Center on the display of the camera being calibrated: the user
		// calibrates looking through that camera, so the window belongs on
		// the screen the camera sits on. No API ties a camera to a display,
		// so external camera -> external display is the best available
		// guess; with several externals the interaction screen wins when it
		// is one.
		let cameraService = SRCameraService.sharedInstance
		let targetDeviceID = self.cameraOverrideDeviceID ?? cameraService.onSelectedDeviceID.value
		let targetDevice = cameraService.onDevices.value.first { $0.id == targetDeviceID }
		if let screen = NSScreen.forCamera(isExternal: targetDevice?.isExternal ?? false) {
			window.center(on: screen)
		}

		// Both nouns, phrased to answer the menu item: "for This Camera"
		// there, "for FaceTime HD Camera" here. A baseline belongs to one
		// camera, and a title naming only the concept taught that calibration
		// is a thing done once for yourself, which is what leaves people
		// reading the new-camera nudge as a nag. Naming only the camera swaps
		// that for a worse reading: calibrating the hardware. Set as one
		// title, not title plus subtitle - with no toolbar macOS joins those
		// with an en dash, and "for" reads better than a dash.
		window.title = targetDevice.map {
			String(format: NSLocalizedString("posture.calibration.title.camera", comment: ""), $0.name)
		} ?? NSLocalizedString("posture.calibration.title", comment: "")

		// Calibrating a not-yet-active camera: look through it while the
		// window lives.
		if let overrideID = self.cameraOverrideDeviceID {
			SRCameraService.sharedInstance.setTemporaryDeviceOverride(id: overrideID)
		}

		// No posture notes while calibrating.
		SRPostureAnalysisService.sharedInstance.setCalibrationWindowOpen(true)

		// Unchecking Track Posture closes the window; dropFirst skips the
		// replayed current value.
		SRSettings.sharedInstance.postureTracking.publisher
			.dropFirst()
			.sink { [weak self] tracking in
				if !tracking { self?.close() }
			}
			.store(in: &self.cancellables)
	}

	override func showWindow(_ sender: Any?) {
		super.showWindow(sender)

		let window = self.window!
		window.makeKeyAndOrderFront(sender)
		NSApp.activate(ignoringOtherApps: true)
	}

	func windowWillClose(_ notification: Notification) {
		guard !self.isClosing else { return }
		self.isClosing = true

		self.calibrationViewController.session.invalidate()
		SRPostureAnalysisService.sharedInstance.setCalibrationWindowOpen(false)

		// Drop the camera override first, so the app settles back onto the
		// policy-resolved camera - after a completed calibration the new
		// baseline lets the gate keep this very camera; after a declined one
		// it falls back to a calibrated one.
		if self.cameraOverrideDeviceID != nil {
			SRCameraService.sharedInstance.setTemporaryDeviceOverride(id: nil)
		}

		// Closing while nothing is calibrated anywhere is a cancel: revert
		// the toggle (the composition root then stops the probe). Declining
		// one camera's calibration while another holds a baseline keeps
		// tracking on - it continues on the calibrated camera. isClosing
		// keeps the toggle subscription above from re-entering close on
		// this write.
		let settings = SRSettings.sharedInstance
		if !self.calibrationViewController.completed
			&& settings.postureBaselines.value.isEmpty
			&& settings.postureTracking.value {
			settings.postureTracking.value = false
		}

		self.onClose?()
	}

}
