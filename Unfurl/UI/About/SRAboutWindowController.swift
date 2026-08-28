//
//  SRAboutWindowController.swift
//  Unfurl
//
//  Created by Maria Shergina on 10/14/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// Shared by the window and its content view so the two cannot drift.
let kAboutWindowWidth = CGFloat(480)


class SRAboutWindowController: NSWindowController {

    override func loadWindow() {
        self.window = NSWindow(
            contentRect: CGRect(x: 0.0, y: 0.0, width: kAboutWindowWidth, height: 560.0),
            styleMask: [.titled, .closable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: true
        )

        let window = self.window!

        window.title = NSLocalizedString("about.title", comment: "")

        self.contentViewController = SRAboutViewController()

        // Width is a design decision; height follows the content, so a longer
        // note (or a translation of it) cannot overflow or leave a gap.
        // Only the height is taken from the layout: every label here is placed
        // with centerXAnchor, which puts no width requirement on the view at
        // all, so fittingSize.width is 0 and using it collapses the window.
        if let content = self.contentViewController?.view {
            window.setContentSize(NSSize(width: kAboutWindowWidth, height: content.fittingSize.height))
        }

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
