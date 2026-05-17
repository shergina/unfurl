//
//  SRScrollCameraView.swift
//  Narcissism
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

		let width = self.layer!.bounds.size.width
		let height = width / self.captureRatio

		CATransaction.begin()
		CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
		self.cameraLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
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

		// TEMPORARY scroll diagnostic.
		NSLog("NARC-CAM[scroll]: pointY=\(point.y) layerH=\(self.layerSize?.height ?? -1) camH=\(self.cameraLayerSize?.height ?? -1) yOffset=\(yOffset) camFrame=\(NSStringFromRect(self.cameraLayer.frame))")
	}
}
