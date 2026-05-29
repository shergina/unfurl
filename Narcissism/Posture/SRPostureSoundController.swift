//
//  SRPostureSoundController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The sound nudge channel: plays the chosen system beep whenever a new
/// posture issue is voiced. One beep per newly reported issue set, not per
/// window - the debounce upstream already keeps voicing rare.
@MainActor
final class SRPostureSoundController {

	/// The system sounds offered by the settings picker.
	static let soundNames = ["Basso", "Glass", "Ping", "Purr", "Tink"]

	fileprivate let settings: SRSettings
	fileprivate var voicedIssues: Set<SRPostureIssue> = []
	fileprivate var sound: NSSound?
	fileprivate var cancellables = Set<AnyCancellable>()

	init(services: AppServices) {
		self.settings = services.settings

		services.posture.onPostureStatus
			.removeDuplicates()
			.sink { [weak self] status in self?.apply(status) }
			.store(in: &self.cancellables)
	}

	fileprivate func apply(_ status: SRPostureStatus?) {
		guard let status else {
			// Probe stopped; the next voiced issue is a fresh event.
			self.voicedIssues = []
			return
		}
		// notVisible keeps the voiced set: briefly leaving the frame and
		// returning with the same issue must not beep again.
		guard case .evaluated(let issues) = status else { return }

		let current = Set(issues)
		let hasNewIssue = !current.subtracting(self.voicedIssues).isEmpty
		self.voicedIssues = current

		guard hasNewIssue, self.settings.postureSoundEnabled.value else { return }
		self.play(self.settings.postureSoundName.value)
	}

	/// Kept in a property so the sound is not deallocated mid-playback.
	func play(_ name: String) {
		self.sound?.stop()
		self.sound = NSSound(named: name)
		self.sound?.play()
	}

}
