//
//  SRDockTileController.swift
//  Unfurl
//
//  Created by Maria Shergina on 21/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
@preconcurrency import AVFoundation
import Combine

@MainActor
class SRDockTileController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

	fileprivate let cameraService: CameraProviding

	fileprivate var dockTile: NSDockTile
	fileprivate var dockTileView: SRDockTileCameraView

	// Created on first enable, then kept: disabling the tile suspends the
	// output (connection off, session claim released) instead of removing it,
	// because removing an output from the running session stalls every
	// preview for ~300 ms - the toggle blink (see Tools/spec.md). Cleared
	// only when the session died while suspended, or an attach failed.
	fileprivate var output: AVCaptureVideoDataOutput?

	/// The tail of the attach/suspend/resume chain; every lifecycle operation
	/// awaits its predecessor, so a quick on-off flip cannot interleave.
	fileprivate var lifecycleTask: Task<Void, Never>?

	fileprivate var enabled = false

	fileprivate let preferences: SRSettings
	fileprivate var cancellables = Set<AnyCancellable>()

	init(services: AppServices) {
		self.cameraService = services.camera
		self.preferences = services.settings
		self.dockTileView = SRDockTileCameraView()
		self.dockTile = NSApplication.shared.dockTile
		self.dockTile.contentView = self.dockTileView

		super.init()

		self.enable = false

		cameraService.onCaptureDeviceAvailable
			.combineLatest(self.preferences.showCameraOnDockTile.publisher)
			.map { $0 && $1 }
			.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
			.sink { [unowned self] in self.enable = $0 }
			.store(in: &self.cancellables)
	}

	fileprivate var showsDockTile: Bool {
		get {
			return NSApp.activationPolicy() == NSApplication.ActivationPolicy.regular
		}

		set(value) {
			NSApp.setActivationPolicy(value ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.prohibited)
		}
	}

	fileprivate var enable: Bool {
		get {
			return self.enabled
		}

		set(value) {
			if value == self.enabled {
				return
			}
			self.enabled = value

			self.showsDockTile = value

			if value {
				self.startOutput()
			}
			else {
				self.stopOutput()
			}
		}
	}

	/// Puts the tile's output in the frame path: resumes the kept output in
	/// place, or - first enable, or the session died while it was suspended -
	/// attaches a fresh one (that attach lands during the session's own
	/// warm-up). Mirrors the posture probe's lifecycle.
	fileprivate func startOutput() {
		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value

			if let output = self.output {
				if await self.cameraService.resumeOutput(output).value {
					return
				}
				self.output = nil
			}

			let output = AVCaptureVideoDataOutput()

			let queue = DispatchQueue(label: "sample-buffer-queue", attributes: [])
			output.setSampleBufferDelegate(self, queue: queue)

			// BGRA only - deliberately no width/height request. Asking this
			// output for small scaled buffers makes the *shared* capture session
			// renegotiate the device to a low-resolution format, visibly
			// degrading the panel and status bar previews. Full-resolution
			// frames are downscaled in imageRefFromSampleBuffer instead, which
			// is cheap at the tile's ~10 fps pacing.
			output.videoSettings = [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			]

			self.output = output

			do {
				try await self.cameraService.attachOutput(output).value
			} catch {
				// Surfaced through onState centrally; clearing lets the next
				// enable retry the attach.
				if self.output === output {
					self.output = nil
				}
			}
		}
	}

	fileprivate func stopOutput() {
		let previous = self.lifecycleTask
		self.lifecycleTask = Task {
			await previous?.value

			guard let output = self.output else { return }
			await self.cameraService.suspendOutput(output).value
		}
	}

	// Frame pacing: a Dock icon gains nothing from the camera's full frame
	// rate, and every delivered frame costs a CVPixelBuffer -> CGImage
	// conversion plus a Dock redraw. Frames beyond ~10/s are dropped on the
	// sample-buffer queue before any of that work happens.
	fileprivate nonisolated static let minimumFrameInterval = CMTime(value: 1, timescale: 10)

	// Touched only on the (serial) sample-buffer queue.
	fileprivate nonisolated(unsafe) var lastDisplayedFrameTime = CMTime.invalid

	nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

		// Called on the sample-buffer queue; pace, convert there, and hand
		// only the finished CGImage to the main actor.
		let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if self.lastDisplayedFrameTime.isValid {
			let elapsed = timestamp - self.lastDisplayedFrameTime
			// A negative elapsed time means the timeline restarted; accept.
			if elapsed >= .zero && elapsed < Self.minimumFrameInterval {
				return
			}
		}
		self.lastDisplayedFrameTime = timestamp

		guard let imageRef = Self.imageRefFromSampleBuffer(sampleBuffer) else { return }

		Task { @MainActor in
			self.dockTileView.imageRef = imageRef
			self.dockTile.display()
		}

	}

	// The dock tile is small and square; the full-resolution frame is
	// center-cropped square (aspect fill) and downscaled here, on the
	// sample-buffer queue.
	fileprivate nonisolated static let tileImageSize = 256

	nonisolated static func imageRefFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CGImage? {
		guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

		CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

		let width = CVPixelBufferGetWidth(imageBuffer)
		let height = CVPixelBufferGetHeight(imageBuffer)
		let colorSpace = CGColorSpaceCreateDeviceRGB()

		guard let fullContext = CGContext(
			data: CVPixelBufferGetBaseAddress(imageBuffer),
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: CVPixelBufferGetBytesPerRow(imageBuffer),
			space: colorSpace,
			bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
		), let fullImage = fullContext.makeImage() else {
			return nil
		}

		let side = min(width, height)
		let cropRect = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
		guard let croppedImage = fullImage.cropping(to: cropRect) else { return fullImage }

		let target = Self.tileImageSize
		guard let thumbnailContext = CGContext(
			data: nil,
			width: target,
			height: target,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return croppedImage
		}

		thumbnailContext.interpolationQuality = .medium
		thumbnailContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: target, height: target))
		return thumbnailContext.makeImage()
	}

}
