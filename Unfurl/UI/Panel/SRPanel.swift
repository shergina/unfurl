//
//  SRPanel.swift
//  Unfurl
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

/// The floating camera panel. Deliberately a *panel*, not an app window:
/// non-activating (clicking it never steals focus from your work), floating
/// above normal windows, following you across Spaces, and absent from the
/// window cycler. The system draws the chrome — corners, shadow, resize
/// handles — while the titlebar is fully transparent so the video runs
/// edge to edge.
class SRPanel: NSPanel {

	override init(contentRect rect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
		super.init(
			contentRect: rect,
			styleMask: [.titled, .fullSizeContentView, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
			backing: bufferingType,
			defer: flag
		)

		// The title is hidden visually, but still names the window for
		// VoiceOver and the window menu.
		self.title = NSLocalizedString("accessibility.panel.title", comment: "")
		self.titleVisibility = .hidden
		self.titlebarAppearsTransparent = true
		self.standardWindowButton(.closeButton)?.isHidden = true
		self.standardWindowButton(.miniaturizeButton)?.isHidden = true
		self.standardWindowButton(.zoomButton)?.isHidden = true

		self.isFloatingPanel = true
		self.level = .floating
		self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		self.hidesOnDeactivate = false

		self.isMovableByWindowBackground = true
		self.becomesKeyOnlyIfNeeded = true

		self.minSize = CGSize(width: 90, height: 60)
		self.canHide = false
	}

	override var canBecomeKey: Bool {
		return true
	}

}
