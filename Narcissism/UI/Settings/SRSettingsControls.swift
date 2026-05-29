//
//  SRSettingsControls.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// A switch bound both ways to a Bool preference: the preference's
/// publisher drives the state, toggling writes the value back.
final class SRPreferenceSwitch: NSSwitch {

	fileprivate var preference: Preference<Bool>!
	fileprivate var cancellable: AnyCancellable?

	convenience init(preference: Preference<Bool>) {
		self.init()
		self.preference = preference
		self.target = self
		self.action = #selector(SRPreferenceSwitch.handleToggle(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in self?.state = value ? .on : .off }
	}

	@objc fileprivate func handleToggle(_ sender: Any?) {
		self.preference.value = (self.state == .on)
	}

}


/// The checkbox flavor of the same two-way preference binding.
final class SRPreferenceCheckbox: NSButton {

	fileprivate var preference: Preference<Bool>!
	fileprivate var cancellable: AnyCancellable?

	convenience init(titleKey: String, preference: Preference<Bool>) {
		self.init(checkboxWithTitle: NSLocalizedString(titleKey, comment: ""), target: nil, action: nil)
		self.preference = preference
		self.target = self
		self.action = #selector(SRPreferenceCheckbox.handleToggle(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in self?.state = value ? .on : .off }
	}

	@objc fileprivate func handleToggle(_ sender: Any?) {
		self.preference.value = (self.state == .on)
	}

}
