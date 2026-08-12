//
//  AppServices.swift
//  Unfurl
//

import Cocoa


/// The process-wide services the surfaces depend on, constructed once by the
/// composition root (`SRUnfurlApplicationDelegate`). Surfaces receive this
/// instead of reaching for singletons, so ownership is explicit and the graph
/// can be rebuilt with fakes in tests.
///
/// Leaf views still read the `.sharedInstance` singletons directly; the
/// production factory below points this container at those same instances, so
/// controllers and views observe one shared set of services.
@MainActor
final class AppServices {

	let settings: SRSettings
	let camera: CameraProviding
	let photo: SRPhotoCaptureService
	let posture: SRPostureAnalysisService
	let postureHistory: SRPostureHistoryService
	let launch: SRLaunchApplicationAtLoginController
	let menu: SRMenuController

	init(
		settings: SRSettings,
		camera: CameraProviding,
		photo: SRPhotoCaptureService,
		posture: SRPostureAnalysisService,
		postureHistory: SRPostureHistoryService,
		launch: SRLaunchApplicationAtLoginController,
		menu: SRMenuController
	) {
		self.settings = settings
		self.camera = camera
		self.photo = photo
		self.posture = posture
		self.postureHistory = postureHistory
		self.launch = launch
		self.menu = menu
	}

	static func production() -> AppServices {
		return AppServices(
			settings: .sharedInstance,
			camera: SRCameraService.sharedInstance,
			photo: .sharedInstance,
			posture: .sharedInstance,
			postureHistory: .sharedInstance,
			launch: .sharedInstance,
			menu: .sharedInstance
		)
	}
}
