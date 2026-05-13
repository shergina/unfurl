//
//  SRStatusItemContentView.swift
//  Narcissism
//
//  Created by Maria Shergina on 19/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

class SRStatusItemContentView: NSView {
	var lighted: Bool

	override init(frame: NSRect) {
		self.lighted = false

		super.init(frame: frame)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}
