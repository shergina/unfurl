//
//  SRCameraServiceSettings.swift
//  Unfurl
//
//  Created by Maria Shergina on 24/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// Opening System Settings is a UI act, so it lives here rather than in
/// `SRCameraService` - that file stays AVFoundation and Combine only, with no
/// idea a screen exists. Both the panel placeholder and the status menu call
/// this, so the URL has exactly one home.
extension SRCameraService {

	/// Send the user to the Camera privacy pane, the only place a denial can
	/// be undone. The pre-Ventura com.apple.preference.security URL no longer
	/// opens the right pane under System Settings.
	static func openCameraPrivacySettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera") else { return }
		NSWorkspace.shared.open(url)
	}

}
