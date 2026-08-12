//
//  SRStatusItemContentView.swift
//  Unfurl
//
//  Created by Maria Shergina on 19/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

class SRStatusItemContentView: NSView {
	var lighted: Bool

	// The posture tint channel: subclasses show it their own way (icon
	// tint, camera border). Best-effort ambient state, never load-bearing.
	var postureAlert: Bool

	override init(frame: NSRect) {
		self.lighted = false
		self.postureAlert = false

		super.init(frame: frame)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}
