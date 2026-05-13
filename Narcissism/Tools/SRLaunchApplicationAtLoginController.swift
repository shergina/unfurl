//
//  SRLaunchApplicationAtLoginController.swift
//  Narcissism
//
//  Created by Maria Shergina on 8/28/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import ServiceManagement
import Combine

@MainActor
class SRLaunchApplicationAtLoginController: NSObject {
    static let sharedInstance = SRLaunchApplicationAtLoginController()

	fileprivate var cancellables = Set<AnyCancellable>()

    var enabled: Bool {
        set(enabled) {
			do {
				if enabled {
					try SMAppService.mainApp.register()
				} else {
					try SMAppService.mainApp.unregister()
				}
			} catch {
				print("SRLaunchApplicationAtLoginController: failed to \(enabled ? "register" : "unregister"): \(error)")
			}
        }

        get {
            return SMAppService.mainApp.status == .enabled
        }
    }

	override init() {
		super.init()

		SRSettings.sharedInstance.launchAtLogin.publisher
			.sink { [unowned self] enabled in
				if enabled != self.enabled {
					self.enabled = enabled
				}
			}
			.store(in: &self.cancellables)
	}
}
