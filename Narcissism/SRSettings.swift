//
//  SRSettings.swift
//  Narcissism
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// A value that can round-trip through UserDefaults.
protocol PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> Self?
	func write(to defaults: UserDefaults, key: String)
}


/// One strongly-typed user preference: UserDefaults-backed, observable.
/// `value` reads/writes synchronously; `publisher` replays the current
/// value and then every change. This replaces the old `Any`-typed subject
/// dictionary plus stringly-named NotificationCenter posts - a design
/// whose force-casts and type-erasure produced real bugs (`getDynamic`
/// once seeded every preference with `false`, silently breaking every
/// menu item).
@MainActor
final class Preference<Value: PreferenceValue> {

	let key: String
	let defaultValue: Value

	fileprivate let defaults: UserDefaults
	fileprivate let subject: CurrentValueSubject<Value, Never>

	init(_ key: String, default defaultValue: Value, defaults: UserDefaults) {
		self.key = key
		self.defaultValue = defaultValue
		self.defaults = defaults
		self.subject = CurrentValueSubject(Value.read(from: defaults, key: key) ?? defaultValue)
	}

	var value: Value {
		get {
			return self.subject.value
		}
		set {
			newValue.write(to: self.defaults, key: self.key)
			self.subject.send(newValue)
		}
	}

	var publisher: AnyPublisher<Value, Never> {
		return self.subject.eraseToAnyPublisher()
	}
}

extension Preference where Value == Bool {
	func toggle() {
		self.value.toggle()
	}
}


@MainActor
final class SRSettings {

	static let sharedInstance = SRSettings()

	// Keys are unchanged from the original PreferenceKey raw values, so
	// existing user defaults carry over.
	let statusItemWithCameraWidth: Preference<CGFloat>
	let flipCameraHorizontally: Preference<Bool>
	let showCameraOnStatusBar: Preference<Bool>
	let showCameraOnDockTile: Preference<Bool>
	let showCameraPanelOnHover: Preference<Bool>
	let cameraPanelSize: Preference<CGSize>
	let cameraPanelPosition: Preference<CGPoint>
	let cameraPanelPinned: Preference<Bool>
	let cameraPanelGhostMode: Preference<Bool>
	let launchAtLogin: Preference<Bool>
	// The selected camera's AVCaptureDevice.uniqueID; "" means system default.
	let selectedCameraDeviceID: Preference<String>

	static let statusItemWidthRange: ClosedRange<CGFloat> = 32.0...256.0

	/// `defaults` is injectable so tests can use a scratch suite instead of
	/// the real domain.
	init(defaults: UserDefaults = .standard) {
		self.statusItemWithCameraWidth = Preference("StatusItemWithCameraWidth", default: CGFloat(64.0), defaults: defaults)
		self.flipCameraHorizontally = Preference("FlipCameraHorizontally", default: false, defaults: defaults)
		self.showCameraOnStatusBar = Preference("ShowCameraOnStatusBar", default: true, defaults: defaults)
		self.showCameraOnDockTile = Preference("ShowCameraOnDockTile", default: false, defaults: defaults)
		self.showCameraPanelOnHover = Preference("ShowCameraPanelOnHover", default: true, defaults: defaults)
		self.cameraPanelSize = Preference("CameraPanelSize", default: CGSize(width: 300.0, height: 200.0), defaults: defaults)
		self.cameraPanelPosition = Preference("CameraPanelPosition", default: CGPoint.zero, defaults: defaults)
		self.cameraPanelPinned = Preference("CameraPanelPinned", default: true, defaults: defaults)
		self.cameraPanelGhostMode = Preference("CameraPanelGhostMode", default: false, defaults: defaults)
		self.launchAtLogin = Preference("LaunchAtLogin", default: false, defaults: defaults)
		self.selectedCameraDeviceID = Preference("SelectedCameraDeviceID", default: "", defaults: defaults)
	}
}


//: PreferenceValue conformances

extension Bool: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> Bool? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.bool(forKey: key)
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(self, forKey: key)
	}
}

extension String: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> String? {
		return defaults.string(forKey: key)
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(self, forKey: key)
	}
}

extension CGFloat: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> CGFloat? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return CGFloat(defaults.double(forKey: key))
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(Double(self), forKey: key)
	}
}

extension CGSize: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> CGSize? {
		guard let string = defaults.string(forKey: key) else { return nil }
		return NSSizeFromString(string)
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(NSStringFromSize(self), forKey: key)
	}
}

extension CGPoint: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> CGPoint? {
		guard let string = defaults.string(forKey: key) else { return nil }
		return NSPointFromString(string)
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(NSStringFromPoint(self), forKey: key)
	}
}
