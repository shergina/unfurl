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
/// instance. Closing it with no baseline stored means cancel: Track
/// Posture goes back off. With an older baseline on file, closing just
/// closes.
@MainActor
final class SRPostureCalibrationWindowController: NSWindowController, NSWindowDelegate {

	/// The owner's hook to drop its reference once the window closes.
	var onClose: (() -> Void)?

	fileprivate var calibrationViewController: SRPostureCalibrationViewController!
	fileprivate var isClosing = false
	fileprivate var cancellables = Set<AnyCancellable>()

	override func loadWindow() {
		self.window = NSWindow(
			contentRect: CGRect(x: 0.0, y: 0.0, width: 480.0, height: 500.0),
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
		self.contentViewController = viewController

		viewController.onFinished = { [weak self] in self?.close() }

		if let screen = window.screen ?? NSScreen.main {
			let x = screen.frame.width / 2 - window.frame.width / 2
			let y = screen.frame.height / 2 - window.frame.height / 2
			window.setFrame(CGRect(x: x, y: y, width: window.frame.width, height: window.frame.height), display: true)
		}

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

		// Closing while uncalibrated is a cancel: revert the toggle (the
		// composition root then stops the probe). isClosing keeps the
		// toggle subscription above from re-entering close on this write.
		let settings = SRSettings.sharedInstance
		if !self.calibrationViewController.completed
			&& settings.postureBaselineSlouchRatio.value <= 0
			&& settings.postureTracking.value {
			settings.postureTracking.value = false
		}

		self.onClose?()
	}

}
