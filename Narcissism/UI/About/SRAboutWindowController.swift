//
//  SRAboutWindowController.swift
//  Narcissism
//
//  Created by Maria Shergina on 10/14/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit

class SRAboutWindowController: NSWindowController {

    override func loadWindow() {
        self.window = NSWindow(
            contentRect: CGRect(x: 0.0, y: 0.0, width: 300.0, height: 400.0),
            styleMask: [.titled, .closable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: true
        )

        let window = self.window!

        window.title = NSLocalizedString("about.title", comment: "")

        self.contentViewController = SRAboutViewController()

        // First open only (the instance is kept, so a reopen keeps the
        // user's placement): on the screen where the menu was clicked.
        if let screen = NSScreen.interaction {
            window.center(on: screen)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

		let window = self.window!
		window.makeKeyAndOrderFront(sender)
		NSApp.activate(ignoringOtherApps: true)
    }

}
