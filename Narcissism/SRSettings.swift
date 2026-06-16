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


/// One camera's good-posture calibration: the slouch ratio and when it was
/// measured. Stored per-camera (see SRSettings.postureBaselines) because each
/// camera's angle changes what an upright posture measures.
struct PostureBaseline: Equatable, Sendable {
	var slouchRatio: CGFloat
	var date: Date
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
	// While Automatic (selectedCameraDeviceID == ""), prefer an external
	// (display) camera over the built-in when one is present - plugging into
	// a monitor makes its camera take over. Off pins Automatic to the built-in.
	let preferExternalCamera: Preference<Bool>
	// While on, the posture probe runs (holding the camera) and the corner
	// note can appear; off detaches the probe entirely. Opt-in by default.
	let postureTracking: Preference<Bool>
	// The posture snooze deadline: tracking pauses (probe detached) until
	// this moment, then resumes on its own. distantPast means not snoozed.
	// Persisted, so a relaunch mid-snooze honors the remaining time.
	let postureSnoozeUntil: Preference<Date>
	// The calibration output, one baseline per camera keyed by the active
	// AVCaptureDevice.uniqueID: the good-posture slouch ratio and when it
	// was measured. A camera absent from the map is uncalibrated. Only these
	// values persist, never imagery.
	let postureBaselines: Preference<[String: PostureBaseline]>
	// Legacy single-baseline preferences, kept only to migrate a pre-per-camera
	// install into postureBaselines once (see migrateLegacyBaselineIfNeeded);
	// cleared after, never written again.
	let postureBaselineSlouchRatio: Preference<CGFloat>
	let postureBaselineDate: Preference<Date>
	// How long (seconds) an issue must persist before it is voiced; drives
	// the report debounce in the analysis service.
	let postureNudgeDelay: Preference<CGFloat>
	// Strictness: how far a metric may drift before it counts as an issue,
	// for both the nudges and the recorded statistics. Slouch: fraction
	// below the baseline ratio (0.12 relaxed ... 0.04 strict). Shoulders:
	// the height difference between the shoulders as a fraction of their
	// separation, i.e. the tilt's slope (0.09 relaxed ... 0.02 strict).
	let postureSlouchTolerance: Preference<CGFloat>
	let postureShoulderTolerance: Preference<CGFloat>
	// The nudge channels: the corner note, a beep, and the status-item
	// tint. Independent; all off means tracking runs silently.
	let postureNoteEnabled: Preference<Bool>
	// Ghost mode for the corner note: fade it to almost nothing while the
	// pointer is over it.
	let postureNoteGhost: Preference<Bool>
	let postureSoundEnabled: Preference<Bool>
	// An NSSound system sound name (see SRPostureSoundController.soundNames).
	let postureSoundName: Preference<String>
	let postureStatusItemTint: Preference<Bool>
	// The first-run gate: false until the welcome window is dismissed once
	// (any path counts); the composition root shows it only while false.
	let hasCompletedOnboarding: Preference<Bool>

    static let allowedStatusItemCameraWidthRange: ClosedRange<CGFloat> = 30.0...256.0
    // The camera's menu-bar width is session-only (never persisted): it always
    // starts here and is only adjusted by dragging within the current session.
    static let defaultStatusItemCameraWidth: CGFloat = 30.0

	/// `defaults` is injectable so tests can use a scratch suite instead of
	/// the real domain.
	init(defaults: UserDefaults = .standard) {
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
		self.preferExternalCamera = Preference("PreferExternalCamera", default: true, defaults: defaults)
		self.postureTracking = Preference("PostureTracking", default: false, defaults: defaults)
		self.postureSnoozeUntil = Preference("PostureSnoozeUntil", default: .distantPast, defaults: defaults)
		self.postureBaselines = Preference("PostureBaselines", default: [:], defaults: defaults)
		self.postureBaselineSlouchRatio = Preference("PostureBaselineSlouchRatio", default: 0, defaults: defaults)
		self.postureBaselineDate = Preference("PostureBaselineDate", default: .distantPast, defaults: defaults)
		self.postureNudgeDelay = Preference("PostureNudgeDelaySeconds", default: 10, defaults: defaults)
		self.postureSlouchTolerance = Preference("PostureSlouchTolerance", default: 0.06, defaults: defaults)
		self.postureShoulderTolerance = Preference("PostureShoulderTolerance", default: 0.07, defaults: defaults)
		self.postureNoteEnabled = Preference("PostureNoteEnabled", default: true, defaults: defaults)
		self.postureNoteGhost = Preference("PostureNoteGhost", default: true, defaults: defaults)
		self.postureSoundEnabled = Preference("PostureSoundEnabled", default: false, defaults: defaults)
		self.postureSoundName = Preference("PostureSoundName", default: "Ping", defaults: defaults)
		self.postureStatusItemTint = Preference("PostureStatusItemTint", default: false, defaults: defaults)
		self.hasCompletedOnboarding = Preference("HasCompletedOnboarding", default: false, defaults: defaults)
	}

	/// The stored baseline for one camera, or nil if it was never calibrated.
	func postureBaseline(for deviceID: String) -> PostureBaseline? {
		return self.postureBaselines.value[deviceID]
	}

	/// Store (or, with nil, clear) one camera's baseline, leaving the others
	/// untouched. Writing the whole map republishes it for the observers.
	func setPostureBaseline(_ baseline: PostureBaseline?, for deviceID: String) {
		var all = self.postureBaselines.value
		all[deviceID] = baseline
		self.postureBaselines.value = all
	}

	/// One-time migration: an install that predates per-camera baselines stored
	/// one global baseline that Automatic always measured on the built-in
	/// camera. Fold it into that camera's slot (unless already set), then clear
	/// the legacy keys so this never runs again and never leaks onto a second
	/// camera. Call once a real device has resolved.
	func migrateLegacyBaselineIfNeeded(deviceID: String) {
		let ratio = self.postureBaselineSlouchRatio.value
		guard ratio > 0 else { return }
		if self.postureBaselines.value[deviceID] == nil {
			self.setPostureBaseline(PostureBaseline(slouchRatio: ratio, date: self.postureBaselineDate.value), for: deviceID)
		}
		self.postureBaselineSlouchRatio.value = 0
		self.postureBaselineDate.value = .distantPast
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

extension Date: PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> Date? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return Date(timeIntervalSince1970: defaults.double(forKey: key))
	}

	func write(to defaults: UserDefaults, key: String) {
		defaults.set(self.timeIntervalSince1970, forKey: key)
	}
}

/// The per-camera baselines persist as a plist-native nested dictionary:
/// uniqueID -> ["ratio": Double, "date": epoch seconds]. A malformed entry is
/// dropped rather than failing the whole read.
extension Dictionary: PreferenceValue where Key == String, Value == PostureBaseline {
	static func read(from defaults: UserDefaults, key: String) -> [String: PostureBaseline]? {
		guard let raw = defaults.dictionary(forKey: key) as? [String: [String: Double]] else { return nil }
		var result: [String: PostureBaseline] = [:]
		for (id, fields) in raw {
			guard let ratio = fields["ratio"], let date = fields["date"] else { continue }
			result[id] = PostureBaseline(slouchRatio: CGFloat(ratio), date: Date(timeIntervalSince1970: date))
		}
		return result
	}

	func write(to defaults: UserDefaults, key: String) {
		var raw: [String: [String: Double]] = [:]
		for (id, baseline) in self {
			raw[id] = ["ratio": Double(baseline.slouchRatio), "date": baseline.date.timeIntervalSince1970]
		}
		defaults.set(raw, forKey: key)
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
