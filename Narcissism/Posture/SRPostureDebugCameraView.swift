//
//  SRPostureDebugCameraView.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import AVFoundation
import Combine


/// TEMPORARY (accuracy test): the panel's camera view plus dots where the
/// posture probe last saw the shoulders (red) and eyes (yellow), so Vision's
/// accuracy can be judged against the live image. The dots are sublayers of
/// the preview layer and are positioned through the preview layer's own
/// coordinate converter, so the aspect-fill crop and the mirror flip apply
/// to them exactly as to the video.
///
/// Delete together with the test: this file, the one line in
/// SRPanelContentView that instantiates it, and the onJoints publishing in
/// SRPostureAnalysisService.
class SRPostureDebugCameraView: SRCameraView {

	/// Master switch for the overlay. All the plumbing (joint publishing,
	/// subscription, coordinate conversion) stays wired; while false the
	/// dots are simply never shown. Flip to true to see them again.
	fileprivate static let dotsVisible = false

	fileprivate var leftShoulderDot: CALayer!
	fileprivate var rightShoulderDot: CALayer!
	fileprivate var leftEyeDot: CALayer!
	fileprivate var rightEyeDot: CALayer!
	fileprivate var jointsCancellable: AnyCancellable?

	override init(frame: NSRect) {
		super.init(frame: frame)

		func makeDot(_ color: NSColor, diameter: CGFloat) -> CALayer {
			let dot = CALayer()
			dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
			dot.cornerRadius = diameter / 2
			dot.backgroundColor = color.cgColor
			dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
			dot.borderWidth = 1.5
			dot.isHidden = true
			dot.zPosition = 10
			self.cameraLayer.addSublayer(dot)
			return dot
		}
		self.leftShoulderDot = makeDot(.systemRed, diameter: 14)
		self.rightShoulderDot = makeDot(.systemRed, diameter: 14)
		self.leftEyeDot = makeDot(.systemYellow, diameter: 10)
		self.rightEyeDot = makeDot(.systemYellow, diameter: 10)

		// Published on the main actor at the analysis rate (4/s).
		self.jointsCancellable = SRPostureAnalysisService.sharedInstance.onJoints
			.sink { [weak self] joints in self?.updateDots(joints) }
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	fileprivate func updateDots(_ joints: SRPostureJoints?) {
		guard Self.dotsVisible else {
			for dot in [self.leftShoulderDot, self.rightShoulderDot, self.leftEyeDot, self.rightEyeDot] {
				dot?.isHidden = true
			}
			return
		}
		guard let previewLayer = self.cameraLayer as? AVCaptureVideoPreviewLayer else { return }

		CATransaction.begin()
		CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
		defer { CATransaction.commit() }

		func place(_ dot: CALayer, at point: CGPoint?) {
			guard let point else {
				dot.isHidden = true
				return
			}
			// Vision points have their origin at the bottom-left; capture
			// device coordinates at the top-left. The converter absorbs the
			// aspect-fill crop and connection-level mirroring - but answers
			// in iOS-style top-left-origin layer coordinates, while a
			// default macOS layer is bottom-left. Verified live: without the
			// correction the dots are vertically mirrored (shoulders at eye
			// level, eyes at shoulder level); x needs no correction. Mirror
			// only y about the layer center; aspect-fill centers the video
			// in the layer, so the flip composes exactly.
			let devicePoint = CGPoint(x: point.x, y: 1 - point.y)
			let converted = previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
			dot.position = CGPoint(
				x: converted.x,
				y: previewLayer.bounds.height - converted.y
			)
			dot.isHidden = false
		}
		place(self.leftShoulderDot, at: joints?.leftShoulder)
		place(self.rightShoulderDot, at: joints?.rightShoulder)
		place(self.leftEyeDot, at: joints?.leftEye)
		place(self.rightEyeDot, at: joints?.rightEye)
	}

}
