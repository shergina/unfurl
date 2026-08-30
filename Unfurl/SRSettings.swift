//
//  SRSettings.swift
//  Unfurl
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// A strictness stop expressed as a line in theta: percent below baseline
/// = slope * theta + intercept. Evaluated with theta clamped to the span
/// the line was fitted over, so an unusual camera angle cannot extrapolate
/// its way to a nonsense tolerance (PITCH_TUNING.md).
struct SRStrictnessLine: Sendable {
	let slope: CGFloat
	let intercept: CGFloat

	func percent(theta: CGFloat, clampedTo range: ClosedRange<CGFloat>) -> CGFloat {
		let clamped = min(max(theta, range.lowerBound), range.upperBound)
		return self.slope * clamped + self.intercept
	}
}


/// A value that can round-trip through UserDefaults.
protocol PreferenceValue {
	static func read(from defaults: UserDefaults, key: String) -> Self?
	func write(to defaults: UserDefaults, key: String)
}


/// One camera's good-posture calibration: the upright slouch ratio, the
/// gaze probe's angles, and when it was measured. Stored per-camera (see
/// SRSettings.postureBaselines) because each camera's angle changes both
/// what an upright posture measures and how strict the thresholds have to
/// be to mean the same thing.
struct PostureBaseline: Equatable, Sendable {
	var slouchRatio: CGFloat
	var date: Date

	/// The ear-anchored baseline, captured alongside the eye one since
	/// 2026-08-06: ears sit on the head's pitch axis, so this variant of
	/// the ratio does not read a downward glance as a slouch and is the
	/// preferred evaluation metric. Nil on entries calibrated before it,
	/// or when the ears never cleared the confidence floor during capture
	/// (headphones, a hood); evaluation then stays on the eye pair.
	var earSlouchRatio: CGFloat?

	/// The gaze probe (added 2026-08-06): how far the eye ratio, the ear
	/// ratio, and the face pitch (degrees) moved between looking at the
	/// camera's screen and looking directly ahead during calibration.
	/// gazePitchDelta is theta, which places the camera's regime and
	/// evaluates the fitted strictness lines (PITCH_TUNING.md); the two
	/// ratio deltas are tuning telemetry. Nil on entries from before the
	/// probe or when its capture was skipped.
	var eyeGazeDelta: CGFloat?
	var earGazeDelta: CGFloat?
	var gazePitchDelta: CGFloat?

	/// The middle-of-screen face pitch in degrees, absolute rather than a
	/// delta (added 2026-08-07). The face detector's zero is per camera,
	/// so a live pitch reading means nothing on its own; this is the
	/// reference it gets differenced against for the looking-down test.
	/// Nil on entries calibrated before it, which turns that test off
	/// until the camera is recalibrated.
	var uprightFacePitch: CGFloat?
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

	fileprivate let defaults: UserDefaults
	fileprivate let subject: CurrentValueSubject<Value, Never>

	init(_ key: String, default defaultValue: Value, defaults: UserDefaults) {
		self.key = key
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
	// The menu-bar camera's width, as last left by a drag. Re-clamped to the
	// current screen when the item is born (see SRStatusItemView), so a width
	// dragged on a wide display cannot come back oversized on a small one.
	let statusItemCameraWidth: Preference<CGFloat>
	// Where the panel sits: its origin as a fraction of a screen's usable
	// area (0...1 per axis) plus the name of the screen it was last on.
	// The fraction makes one dragged position carry to every display
	// (top-right here is top-right there); the name lets a pinned panel
	// restore to its home screen. See SRPanelController's placement.
	let cameraPanelRelativePosition: Preference<CGPoint>
	let cameraPanelScreenName: Preference<String>
	// Legacy absolute origin, read only to seed the relative position on a
	// pre-fraction install and zeroed on the first save; never written
	// otherwise.
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
	// for both the nudges and the recorded statistics. Slouch: which stop
	// of the five-step ladder the slider sits on, 0 = most relaxed; the
	// stop's meaning is set by the camera's regime (see the piecewise
	// tables below). Shoulders: the height difference between the
	// shoulders as a fraction of their separation, i.e. the tilt's slope
	// (0.18 relaxed ... 0.06 strict).
	let postureSlouchStrictnessIndex: Preference<CGFloat>
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

	// Piecewise slouch strictness (PITCH_TUNING.md): the regime is which
	// side of the user's level gaze the camera sits, measured by the
	// ahead pitch (uprightFacePitch + gazePitchDelta, degrees; positive
	// = camera above the gaze line). At or below the boundary the
	// hand-tuned low tables apply; above it the fitted lines. The index
	// picks the stop from the regime's per-metric ladder (percent below
	// baseline, relaxed to strict).
	//
	// Theta itself cannot classify the camera: both probe legs are
	// camera-relative, so the camera cancels out of their difference and
	// theta only measures the screen centre's depth below level.
	// Discovered 2026-08-10 when an honestly aimed ahead probe put a
	// monitor camera at the top of the head below the old theta
	// boundary; the ahead pitch on the same desk sits +6.7..+19.1
	// across every calibration on record, nowhere near 0.
	nonisolated static let lowCameraAheadPitchBoundary: CGFloat = 0

	// The legacy proxy, kept for entries that predate uprightFacePitch
	// (screen depth correlates loosely with camera height: laptops deep,
	// monitors shallow). A camera with no theta at all runs the looser
	// high regime until recalibrated.
	nonisolated static let lowCameraThetaBoundary: CGFloat = -10

	// The strictness ladder, five stops, relaxed first - the slider picks
	// the index (PostureSlouchStrictnessIndex, default 2 = the middle).
	// Below the boundary the index selects a hand-tuned stop from the
	// tables; above it the fitted line gives the middle stop and these
	// multiply it.
	//
	// The at-screen ladder spreads wider at the relaxed end and less far
	// at the strict end than the low tables imply about themselves
	// ([1.6, 1.2, 1.0, 0.8, 0.6] for ears), so a slider position is not
	// quite the same relative strictness on either side of the boundary -
	// relaxed is looser above it, strict is milder.
	//
	// The looking-down ladder is deliberately tighter. Sharing the
	// at-screen one multiplies an already-large tolerance: on a shallow
	// camera the relaxed stop reached 38 percent, which is "never fires".
	// The relaxed end is sized so one notch moves the down tolerance by
	// roughly the points it moves the at-screen one - solving that across
	// the sampled thetas gives 1.20 to 1.33, hence 1.25. The same solve
	// puts the strict end at 0.74 to 0.84; the shipped 0.9 sits above it,
	// hand-loosened on 2026-08-10 alongside the down line. The middle
	// stop stays 1.0 on both: that is the fitted value the decisions were
	// made at (PITCH_TUNING.md).
	//
	// The two ladders must keep the down stop looser than the at-screen
	// stop everywhere, or looking away would be judged harder than
	// looking at the screen. Under the hand-set down line that ordering
	// is no longer close: the tightest corner (stop 1 at the shallow
	// clamp edge) holds with about 13.8 points to spare, against 0.35
	// under the fitted line.
	nonisolated static let highCameraAtScreenLadder: [CGFloat] = [1.8, 1.5, 1.0, 0.85, 0.7]
	nonisolated static let highCameraLookingDownLadder: [CGFloat] = [1.25, 1.1, 1.0, 0.95, 0.9]
	nonisolated static let defaultSlouchStrictnessIndex: CGFloat = 2
	nonisolated static let lowCameraEarPercents: [CGFloat] = [4, 3, 2.5, 2, 1.5]
	nonisolated static let lowCameraEyePercents: [CGFloat] = [8, 6.5, 5, 4, 3]
	nonisolated static let highCameraEarPercents: [CGFloat] = [11, 9, 7, 5.5, 4.5]
	nonisolated static let highCameraEyePercents: [CGFloat] = [12, 10, 8, 6.5, 5]

	// Above the boundary the medium stop comes from a line in theta rather
	// than the table above (PITCH_TUNING.md, 2026-08-07). Two ear lines:
	// one for a gaze at the screen, one for a gaze below it, picked per
	// window by whether the eye metric has dropped further than the ear
	// one. The eye metric keeps a single line - no down-gaze eye percents
	// have been decided, and the divergence test needs an ear reading it
	// does not have when the eye metric is judging alone.
	//
	// Theta is clamped to the sampled span before evaluating: outside it
	// these are extrapolation, and the notebook's policy is to clamp
	// rather than extrapolate. Nothing has been measured above -0.6, so
	// the lines are unconstrained on the far side of the gaze line and
	// the clamp is what keeps a camera up there honest. An entry with no
	// measured theta cannot evaluate a line at all and stays on the
	// tables.
	nonisolated static let highCameraFitThetaRange: ClosedRange<CGFloat> = -9.9...(-0.6)

	// The at-screen ear line, least squares over four monitor points
	// spanning -9.9 to -0.6 (PITCH_TUNING.md). R2 0.89, max residual
	// under 1 point - inside the decide-by-feel noise floor.
	nonisolated static let highCameraEarAtScreen = SRStrictnessLine(slope: 0.675055, intercept: 10.6384)

	// The down line is hand-set (2026-08-10), replacing the fitted
	// 2.115141x + 26.9169. The rows' thetas rode the wobbly forward aim
	// and the two gaze poses differ person to person, so the deep-theta
	// points plotted too shallow and the fitted slope over-tightened the
	// deep end. The replacement is close to flat - 19.1 percent at the
	// -9.9 clamp to 26.5 at -0.6, a 7.4 point span where the fit moved
	// 19.7 - so the down-gaze allowance barely tracks the camera angle
	// any more. No decided row reproduces; the errors run 1.5 points at
	// row 4 to 13.6 at row 3. Deliberate, and it makes this a tolerance
	// setting rather than a fit to the notebook (PITCH_TUNING.md).
	nonisolated static let highCameraEarLookingDown = SRStrictnessLine(slope: 0.8, intercept: 27)

	// Not refitted. This still rests on two points, one of which was the
	// row deleted as an ear outlier, so it is the weakest of the three
	// and is due a collection pass of its own. It only judges when the
	// ears are unavailable.
	nonisolated static let highCameraEyeAtScreen = SRStrictnessLine(slope: 0.576923, intercept: 20.1346)

	// Where "looking down" starts: this many degrees of face pitch below
	// the middle-of-screen calibration pose - the same pose the baseline
	// itself is captured at.
	//
	// Anchored there rather than to straight-ahead (changed 2026-08-07)
	// for two reasons. Screen centre is the more repeatable of the two
	// poses by a factor of about 2.2 across a day of calibrations, being
	// a target the user can actually aim at where "straight ahead" gets
	// interpreted afresh every time. And anchoring to ahead dragged the
	// trigger around with theta while the screen stayed put: across four
	// setups it landed anywhere from 0.05 to 16.9 degrees past the
	// screen's bottom edge, so "looking down" meant a different gesture
	// on each. Off screen centre it sits at a fixed depth and the only
	// variation left is real screen height.
	//
	// Lowered 14 -> 8 on 2026-08-09, then 8 -> 6: 14 sat past everything
	// the detector reports (screen-bottom stares measured only +2.5..+10.1
	// past centre, and a real glance drops the eyes more than the head),
	// so the trigger never fired. 6 is reachable, at the cost of engaging
	// while reading the screen's bottom edge on three of the four setups
	// sampled, where 8 caught two. Provisional (PITCH_TUNING.md).
	nonisolated static let lookingDownPitchBelowScreenDegrees: CGFloat = 6

	// Release lower than it engages, so a gaze resting on the boundary
	// does not flip the stop every window. Sized from the measured
	// flicker: the zero-divergence trigger it replaces changed verdict
	// about once every 25 s (PITCH_TUNING.md).
	nonisolated static let lookingDownPitchHysteresisDegrees: CGFloat = 3

    static let allowedStatusItemCameraWidthRange: ClosedRange<CGFloat> = 30.0...256.0
    // What a first run gets, before the user has ever dragged the item.
    // Afterwards the dragged width is remembered (statusItemCameraWidth).
    static let defaultStatusItemCameraWidth: CGFloat = 35.0
    // Floor for the camera layer's height, whatever the item's width. Two jobs:
    // stay above the menu bar thickness so the layer always covers the item,
    // and leave headroom (about 5pt over a 22pt bar) for the mouse pan to have
    // range. Deliberately NOT derived from the default width - a default below
    // ~39pt would drag this under the bar thickness and flatten the pan to
    // nothing. Narrow items keep this height and crop the sides instead
    // (see SRScrollCameraView.layout).
    static let minimumStatusItemCameraHeight: CGFloat = 27.0

	/// `defaults` is injectable so tests can use a scratch suite instead of
	/// the real domain.
	init(defaults: UserDefaults = .standard) {
		self.flipCameraHorizontally = Preference("FlipCameraHorizontally", default: false, defaults: defaults)
		self.showCameraOnStatusBar = Preference("ShowCameraOnStatusBar", default: true, defaults: defaults)
		self.showCameraOnDockTile = Preference("ShowCameraOnDockTile", default: false, defaults: defaults)
		self.showCameraPanelOnHover = Preference("ShowCameraPanelOnHover", default: true, defaults: defaults)
		self.cameraPanelSize = Preference("CameraPanelSize", default: CGSize(width: 600.0, height: 400.0), defaults: defaults)
		self.statusItemCameraWidth = Preference("StatusItemCameraWidth", default: SRSettings.defaultStatusItemCameraWidth, defaults: defaults)
		self.cameraPanelRelativePosition = Preference("CameraPanelRelativePosition", default: CGPoint.zero, defaults: defaults)
		self.cameraPanelScreenName = Preference("CameraPanelScreenName", default: "", defaults: defaults)
		self.cameraPanelPosition = Preference("CameraPanelPosition", default: CGPoint.zero, defaults: defaults)
		self.cameraPanelPinned = Preference("CameraPanelPinned", default: false, defaults: defaults)
		self.cameraPanelGhostMode = Preference("CameraPanelGhostMode", default: false, defaults: defaults)
		self.launchAtLogin = Preference("LaunchAtLogin", default: false, defaults: defaults)
		self.selectedCameraDeviceID = Preference("SelectedCameraDeviceID", default: "", defaults: defaults)
		self.preferExternalCamera = Preference("PreferExternalCamera", default: true, defaults: defaults)
		self.postureTracking = Preference("PostureTracking", default: false, defaults: defaults)
		self.postureSnoozeUntil = Preference("PostureSnoozeUntil", default: .distantPast, defaults: defaults)
		self.postureBaselines = Preference("PostureBaselines", default: [:], defaults: defaults)
		self.postureBaselineSlouchRatio = Preference("PostureBaselineSlouchRatio", default: 0, defaults: defaults)
		self.postureBaselineDate = Preference("PostureBaselineDate", default: .distantPast, defaults: defaults)
		self.postureNudgeDelay = Preference("PostureNudgeDelaySeconds", default: 20, defaults: defaults)
		self.postureSlouchStrictnessIndex = Preference("PostureSlouchStrictnessIndex", default: SRSettings.defaultSlouchStrictnessIndex, defaults: defaults)
		self.postureShoulderTolerance = Preference("PostureShoulderTolerance", default: 0.12, defaults: defaults)
		self.postureNoteEnabled = Preference("PostureNoteEnabled", default: true, defaults: defaults)
		self.postureNoteGhost = Preference("PostureNoteGhost", default: true, defaults: defaults)
		self.postureSoundEnabled = Preference("PostureSoundEnabled", default: false, defaults: defaults)
		self.postureSoundName = Preference("PostureSoundName", default: "Ping", defaults: defaults)
		self.postureStatusItemTint = Preference("PostureStatusItemTint", default: true, defaults: defaults)
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
			self.setPostureBaseline(
				PostureBaseline(slouchRatio: ratio, date: self.postureBaselineDate.value),
				for: deviceID
			)
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
/// uniqueID -> ["ratio": Double, "date": epoch seconds, plus whichever
/// optional fields were measured]. Unknown keys are ignored on read, so an
/// entry written by an older build (which carried the retired slouch-pose
/// and geometry-probe fields) still loads. A malformed entry is dropped
/// rather than failing the whole read.
extension Dictionary: PreferenceValue where Key == String, Value == PostureBaseline {
	static func read(from defaults: UserDefaults, key: String) -> [String: PostureBaseline]? {
		guard let raw = defaults.dictionary(forKey: key) as? [String: [String: Double]] else { return nil }
		var result: [String: PostureBaseline] = [:]
		for (id, fields) in raw {
			guard let ratio = fields["ratio"], let date = fields["date"] else { continue }
			result[id] = PostureBaseline(
				slouchRatio: CGFloat(ratio),
				date: Date(timeIntervalSince1970: date),
				earSlouchRatio: fields["earRatio"].map { CGFloat($0) },
				eyeGazeDelta: fields["eyeGaze"].map { CGFloat($0) },
				earGazeDelta: fields["earGaze"].map { CGFloat($0) },
				gazePitchDelta: fields["pitchDelta"].map { CGFloat($0) },
				uprightFacePitch: fields["uprightPitch"].map { CGFloat($0) }
			)
		}
		return result
	}

	func write(to defaults: UserDefaults, key: String) {
		var raw: [String: [String: Double]] = [:]
		for (id, baseline) in self {
			var fields = ["ratio": Double(baseline.slouchRatio), "date": baseline.date.timeIntervalSince1970]
			if let earRatio = baseline.earSlouchRatio {
				fields["earRatio"] = Double(earRatio)
			}
			if let eyeGaze = baseline.eyeGazeDelta {
				fields["eyeGaze"] = Double(eyeGaze)
			}
			if let earGaze = baseline.earGazeDelta {
				fields["earGaze"] = Double(earGaze)
			}
			if let pitchDelta = baseline.gazePitchDelta {
				fields["pitchDelta"] = Double(pitchDelta)
			}
			if let uprightPitch = baseline.uprightFacePitch {
				fields["uprightPitch"] = Double(uprightPitch)
			}
			raw[id] = fields
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
