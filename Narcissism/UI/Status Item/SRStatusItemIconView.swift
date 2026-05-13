//
//  SRStatusItemIconView.swift
//  Narcissism
//
//  Created by Maria Shergina on 03/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

class SRStatusItemIconView: SRStatusItemContentView {
    class var imageName: String { return "StatusItemIconPattern" }

    var image: NSImage? {
        guard let image = NSImage(named: type(of: self).imageName) else {
            print("SRStatusItemIconView: missing asset '\(type(of: self).imageName)'")
            return nil
        }
        image.isTemplate = true
        return image
    }

	var button: NSButton!

	override init(frame: NSRect) {
        super.init(frame: frame)

		self.button = SRStatusBarButton(frame: CGRect(x: 2.0, y: 0.0, width: 28.0, height: 22.0))
		self.button.wantsLayer = true
		self.button.image = self.image
		self.button.imagePosition = .imageOnly
		self.button.isBordered = false


		self.wantsLayer = true
		self.addSubview(self.button)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var lighted: Bool {
		didSet {
			self.button.isHighlighted = self.lighted;
		}
	}

	override var intrinsicContentSize: CGSize {
		get {
			return CGSize(
				width: self.button.bounds.size.width + 4,
				height: self.bounds.size.height
			)
		}
	}

}


class SRStatusItemIconNormalView: SRStatusItemIconView {
    override class var imageName: String { return "StatusItemIconPattern" }
}

class SRStatusItemIconUnavailableView: SRStatusItemIconView {
    override class var imageName: String { return "StatusItemIconPatternUnavailable" }
}
