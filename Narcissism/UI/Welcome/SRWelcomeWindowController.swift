//
//  SRWelcomeWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The welcome window: the first-run flow (see spec.md next to this file).
/// Owned as a single kept instance by SRMenuController, shown by the
/// composition root at launch. Pages are swapped as the content view
/// controller; Continue advances, the last page closes.
class SRWelcomeWindowController: NSWindowController {

	/// Set by the owner before showWindow; page two's Locate Me routes
	/// through here to the status item (wired in the composition root).
	var onLocate: (() -> Void)?

	override func loadWindow() {
		let window = NSWindow(
			contentRect: .zero,
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: true
		)
		// The page carries its own big title; the system title bar stays but
		// shows no text, so the title is not said twice.
		window.titleVisibility = .hidden
		window.title = NSLocalizedString("welcome.title", comment: "")
		window.isReleasedWhenClosed = false
		self.window = window

		self.showPageOne()

		window.center()
	}

	override func showWindow(_ sender: Any?) {
		// The instance is kept across closes; a re-show restarts the flow.
		if self.isWindowLoaded, let window = self.window, !window.isVisible {
			self.showPageOne()
		}

		super.showWindow(sender)

		// The Settings-window recipe: with the Dock tile off the activation
		// policy is .prohibited, activation is refused, and without the
		// regardless-ordering the window opens behind the active app.
		self.window!.makeKeyAndOrderFront(sender)
		self.window!.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

	fileprivate func showPageOne() {
		let page = SRWelcomeViewController()
		page.onContinue = { [weak self] in self?.showPageTwo() }
		self.contentViewController = page
	}

	fileprivate func showPageTwo() {
		let page = SRWelcomeTutorialViewController()
		page.onLocate = { [weak self] in self?.onLocate?() }
		// Continue just closes until page three exists.
		page.onContinue = { [weak self] in self?.close() }
		self.contentViewController = page
	}

}
