//
//  SRScrollCameraView.swift
//  Unfurl
//
//  Created by Maria Shergina on 27/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa

class SRScrollCameraView: SRCameraView, SRMouseWatcherListener {

	fileprivate var layerSize: CGSize?
	fileprivate var cameraLayerSize: CGSize?

	override init(frame: NSRect) {
		super.init(frame: frame)
		SRMouseWatcher.sharedInstance.add(self)

		self.updateCachedSizes()
	}

	required init?(coder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}

	deinit {
		// NSViews deallocate on the main thread; deinit just isn't statically
		// isolated. (The listener table holds weak references anyway.)
		MainActor.assumeIsolated {
			SRMouseWatcher.sharedInstance.remove(self)
		}
	}

	override func layout() {
		super.layout()

		let viewSize = self.layer!.bounds.size

		// Height leads, width follows. Fitting 16:9 to the item's width alone
		// made the layer shorter than the item below ~39pt, which flipped the
		// sign of the pan term and slid the whole strip up and down. The layer
		// never gets shorter than the default height (nor than the item), so it
		// overhangs horizontally instead and masksToBounds crops the sides.
		let height = max(viewSize.width / self.captureRatio, viewSize.height, SRSettings.minimumStatusItemCameraHeight)
		let width = height * self.captureRatio

		CATransaction.begin()
		CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
		// Centered, so the crop takes equal bites off both edges.
		self.cameraLayer.frame = CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: height)
		CATransaction.commit()

		self.updateCachedSizes()

		self.mouseMoved(withRelativePoint: SRMouseWatcher.sharedInstance.relativePoint)
	}

	func updateCachedSizes() {
		self.layerSize = self.layer!.bounds.size
		self.cameraLayerSize = self.cameraLayer.bounds.size
	}

	func mouseMoved(withRelativePoint point: CGPoint) {
		let yOffset = -1 * (self.cameraLayerSize!.height - self.layerSize!.height) * (1 - point.y)

		var frame = self.cameraLayer.frame
		frame.origin.y = yOffset

		CATransaction.begin()
		CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
		self.cameraLayer.frame = frame
		CATransaction.commit()
	}
}
