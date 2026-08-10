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

	/// The tail of the attach/suspend/resume chain; each lifecycle operation
	/// awaits its predecessor so a quick hide-show flip cannot interleave.
	/// Only a host that suspends/resumes (the status item) grows the chain;
	/// throwaway views (panel, calibration) just attach once and detach in
	/// deinit as before.
	fileprivate var lifecycleTask: Task<Void, Never>?

	// Must match the session preset (.hd1920x1080, see SRCameraService).
	var captureResolution: CGSize {
		return CGSize(width: 1920, height: 1080)
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

		let attach = self.cameraService.attachPreviewLayer(self.previewLayer)
		self.lifecycleTask = Task { try? await attach.value }

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

	/// Takes the live preview out of the frame path without tearing the view
	/// down: the layer's session connection is disabled (the session does no
	/// work for it) and its claim on the session released, but the wiring
	/// stays - detaching a layer from the running session stalls every
	/// preview for ~300 ms, the toggle blink (see Tools/spec.md). For hosts
	/// that hide and re-show the same view (the status item).
	func suspendPreview() {
		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value
			await self.cameraService.suspendPreviewLayer(self.previewLayer).value
		}
	}

	/// Puts a suspended preview back in the frame path: resumed in place when
	/// still wired, re-attached during the new session's warm-up otherwise.
	func resumePreview() {
		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value
			try? await self.cameraService.resumePreviewLayer(self.previewLayer).value
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
