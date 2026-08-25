//
//  SRStatusItemIconView.swift
//  Unfurl
//
//  Created by Maria Shergina on 03/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

class SRStatusItemIconView: SRStatusItemContentView {
    class var imageName: String { return "MonochromaticLogoSmall" }

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

	override var postureAlert: Bool {
		didSet {
			guard self.postureAlert != oldValue else { return }
			// NSStatusBarButton renders template images through the menu
			// bar's own styling and a contentTintColor blanks them instead
			// of tinting; swap in a pre-tinted, non-template copy instead.
			self.button.image = self.postureAlert ? self.image.map(Self.tintedOrange) : self.image
		}
	}

	fileprivate static func tintedOrange(_ image: NSImage) -> NSImage {
		let tinted = NSImage(size: image.size, flipped: false) { rect in
			image.draw(in: rect)
			NSColor.systemOrange.set()
			rect.fill(using: .sourceAtop)
			return true
		}
		tinted.isTemplate = false
		return tinted
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


class SRStatusItemIconUnavailableView: SRStatusItemIconView {
    override class var imageName: String { return "MonochromaticLogoSmallUnavailable" }
}
