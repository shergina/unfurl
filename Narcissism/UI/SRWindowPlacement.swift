//
//  SRWindowPlacement.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


extension NSScreen {

	/// The screen the user is acting on: the one holding the pointer. For
	/// a menu-bar agent NSScreen.main is a trap - with no key window it
	/// falls back to the primary display, not to where the user is - and
	/// every window here is summoned by a click, so the pointer is the
	/// honest signal.
	@MainActor static var interaction: NSScreen? {
		let mouse = NSEvent.mouseLocation
		return self.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? self.main
	}

}


extension NSWindow {

	/// center()'s placement - centered horizontally, a third of the free
	/// space above - but on a chosen screen instead of whichever screen
	/// center() resolves on its own.
	func center(on screen: NSScreen) {
		let area = screen.visibleFrame
		self.setFrameOrigin(NSPoint(
			x: area.midX - self.frame.width / 2,
			y: area.minY + (area.height - self.frame.height) * 2 / 3
		))
	}

}
