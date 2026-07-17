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

	var isBuiltin: Bool {
		guard let number = self.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
		else { return false }
		return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
	}

	/// The screen a camera looks out of. For anything the camera has an
	/// opinion about this beats the pointer: a face reading proves the user
	/// is facing that camera, where the pointer only says where the mouse
	/// was last moved. No API ties a camera to a display, so external
	/// camera -> external display is the best available guess; with several
	/// externals the interaction screen wins when it is one.
	@MainActor static func forCamera(isExternal: Bool) -> NSScreen? {
		let wantsBuiltin = !isExternal
		if let interaction = self.interaction, interaction.isBuiltin == wantsBuiltin { return interaction }
		return self.screens.first { $0.isBuiltin == wantsBuiltin } ?? self.interaction
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
