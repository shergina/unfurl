//
//  SRAboutWindowController.swift
//  Narcissism
//
//  Created by Maria Shergina on 10/14/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit

class SRAboutWindowController: NSWindowController {

//    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }

    override func loadWindow() {
        self.window = NSWindow(
            contentRect: CGRect(x: 0.0, y: 0.0, width: 300.0, height: 400.0),
            styleMask: [.titled, .closable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: true
        )

        let window = self.window!
        let screen = window.screen!

        window.title = NSLocalizedString("about.title", comment: "")

        self.contentViewController = SRAboutViewController()

        let x = screen.frame.width / 2 - window.frame.width / 2
        let y = screen.frame.height / 2 - window.frame.height / 2

        window.setFrame(CGRect(x: x, y: y, width: window.frame.width, height: window.frame.height), display: true)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

		let window = self.window!
		window.makeKeyAndOrderFront(sender)
		NSApp.activate(ignoringOtherApps: true)
    }

}
