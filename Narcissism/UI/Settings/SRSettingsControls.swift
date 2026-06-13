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


/// A tick-marked slider over a fixed ladder of values for a CGFloat
/// preference, bound both ways: the publisher selects the nearest stop
/// (so an off-ladder stored value still shows something sensible),
/// dragging writes the stop's value back.
final class SRPreferenceStepSlider: NSSlider {

	fileprivate var preference: Preference<CGFloat>!
	fileprivate var stops: [CGFloat] = []
	fileprivate var cancellable: AnyCancellable?

	convenience init(stops: [CGFloat], preference: Preference<CGFloat>) {
		self.init(value: 0, minValue: 0, maxValue: Double(stops.count - 1), target: nil, action: nil)
		self.stops = stops
		self.preference = preference
		self.numberOfTickMarks = stops.count
		self.allowsTickMarkValuesOnly = true
		self.target = self
		self.action = #selector(SRPreferenceStepSlider.handleChange(_:))
		self.cancellable = preference.publisher
			.sink { [weak self] value in
				guard let self else { return }
				let nearest = self.stops.indices.min { abs(self.stops[$0] - value) < abs(self.stops[$1] - value) }!
				self.doubleValue = Double(nearest)
			}
	}

	@objc fileprivate func handleChange(_ sender: Any?) {
		self.preference.value = self.stops[Int(self.doubleValue.rounded())]
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
