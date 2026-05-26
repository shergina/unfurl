//
//  SRCameraView.swift
//  Narcissism
//
//  Created by Maria Shergina on 27/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import AVFoundation
import Combine

class SRCameraView: NSView {
	fileprivate let cameraService = SRCameraService.sharedInstance
	fileprivate var previewLayer: AVCaptureVideoPreviewLayer
	fileprivate let preferences = SRSettings.sharedInstance
	fileprivate var cancellables = Set<AnyCancellable>()

	var captureResolution: CGSize {
		return CGSize(width: 320, height: 240)
	}

	var captureRatio: CGFloat {
		return self.captureResolution.width / self.captureResolution.height
	}

	var cameraLayer: CALayer {
		return self.previewLayer
	}

	override init(frame: NSRect) {
		self.previewLayer = AVCaptureVideoPreviewLayer()

		self.previewLayer.videoGravity = .resizeAspectFill

		self.previewLayer.autoresizingMask = [CAAutoresizingMask.layerWidthSizable, CAAutoresizingMask.layerHeightSizable];

		super.init(frame: frame)

		self.wantsLayer = true
		self.previewLayer.frame = self.layer!.bounds
		self.layer!.masksToBounds = true
		self.layer!.insertSublayer(self.previewLayer, at: 0)

		// Live video has no text; present it to VoiceOver as a labeled image.
		self.setAccessibilityElement(true)
		self.setAccessibilityRole(.image)
		self.setAccessibilityLabel(NSLocalizedString("accessibility.camera-preview.label", comment: ""))

		_ = self.cameraService.attachPreviewLayer(self.previewLayer)

		// TEMPORARY: check whether the session ever actually attaches (the layout
		// log runs before the async attach completes).
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
			guard let self else { NSLog("NARC-CAM[+3s]: view was deallocated"); return }
			NSLog("NARC-CAM[+3s]: class=\(type(of: self)) session=\(self.previewLayer.session != nil) superlayer=\(self.previewLayer.superlayer != nil) previewFrame=\(NSStringFromRect(self.previewLayer.frame))")
		}

		// Replays the current value, so this also applies the initial flip.
		self.preferences.flipCameraHorizontally.publisher
			.sink { [unowned self] _ in self.applyCameraFlip() }
			.store(in: &self.cancellables)
	}

	deinit {
		// NSViews deallocate on the main thread; deinit just isn't statically
		// isolated, so assert the isolation to touch main-actor state.
		MainActor.assumeIsolated {
			self.previewLayer.removeFromSuperlayer()
			_ = self.cameraService.detachPreviewLayer(self.previewLayer)
		}
	}

	required init?(coder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}

	override func layout() {
		super.layout()

		// Keep the preview layer sized to the view. The layer's autoresizing mask
		// alone doesn't track the view reliably (it was set when bounds were zero),
		// so without this the panel's feed stays zero-sized and the placeholder
		// shows through. SRScrollCameraView overrides this for its scroll effect.
		CATransaction.begin()
		CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
		self.previewLayer.frame = self.layer!.bounds
		CATransaction.commit()

		self.updatePreviewLayerContentsScale()

		// TEMPORARY render diagnostic.
		NSLog("NARC-CAM[\(type(of: self))]: bounds=\(NSStringFromRect(self.bounds)) layerBounds=\(NSStringFromRect(self.layer?.bounds ?? .zero)) previewFrame=\(NSStringFromRect(self.previewLayer.frame)) session=\(self.previewLayer.session != nil) scale=\(self.previewLayer.contentsScale)")
	}

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		self.updatePreviewLayerContentsScale()
	}

	// AppKit only manages contentsScale for a view's own backing layer;
	// manually-inserted sublayers stay at 1x, which on Retina renders the
	// video at half resolution and upscales it - visibly soft. Track the
	// window's backing scale by hand.
	fileprivate func updatePreviewLayerContentsScale() {
		let scale = self.window?.backingScaleFactor ?? 2.0
		if self.previewLayer.contentsScale != scale {
			self.previewLayer.contentsScale = scale
		}
	}

	// Internal (not fileprivate) so SRPostureCalibrationCameraView can
	// override it to mirror unconditionally.
	func applyCameraFlip() {
		self.previewLayer.transform =
			self.preferences.flipCameraHorizontally.value ?
				CATransform3DMakeRotation(.pi, 0.0, 1.0, 0.0) :
				CATransform3DIdentity
	}

}
