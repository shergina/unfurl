//
//  SRPostureCalibrationCameraView.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The calibration preview: the live camera, always mirrored.
class SRPostureCalibrationCameraView: SRCameraView {

	/// Always mirror: a calibration preview is a mirror, whatever the flip
	/// preference says.
	override func applyCameraFlip() {
		self.cameraLayer.transform = CATransform3DMakeRotation(.pi, 0.0, 1.0, 0.0)
	}

}
