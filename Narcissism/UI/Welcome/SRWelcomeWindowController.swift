//
//  SRWelcomeWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The welcome window: page one of the first-run flow (see spec.md next to
/// this file). Owned as a single kept instance by SRMenuController, shown
/// by the composition root at launch.
class SRWelcomeWindowController: NSWindowController {

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

		let content = SRWelcomeViewController()
		// Continue just closes until pages two and three exist.
		content.onContinue = { [weak self] in self?.close() }
		self.contentViewController = content

		window.center()
	}

	override func showWindow(_ sender: Any?) {
		super.showWindow(sender)

		// The Settings-window recipe: with the Dock tile off the activation
		// policy is .prohibited, activation is refused, and without the
		// regardless-ordering the window opens behind the active app.
		self.window!.makeKeyAndOrderFront(sender)
		self.window!.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

}
