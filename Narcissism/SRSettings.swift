//
//  SRSettings.swift
//  Narcissism
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
/// demonstrated-slouch ratio (nil on a single-point entry - calibrated
/// before the two-pose flow, or the flow was abandoned after the upright
/// capture), and when it was measured. Stored per-camera (see
/// SRSettings.postureBaselines) because each camera's angle changes both
/// what an upright posture measures and how fast the ratio moves per unit
/// of real slouch - the span calibrates that second part, the gain.
struct PostureBaseline: Equatable, Sendable {
	var slouchRatio: CGFloat
	var slouchedRatio: CGFloat?
	var date: Date

	/// The eye:shoulder width ratio measured during the upright capture -
	/// the camera's geometry probe, from which a slouch span is derived
	/// for cameras that never ran the slouch pose (see
	/// postureEffectiveSlouchSpan). Nil on entries from before the probe
	/// existed.
	var eyeShoulderRatio: CGFloat?

	/// The ear-anchored pair, captured alongside the eye pair since
	/// 2026-08-06: ears sit on the head's pitch axis, so this variant of
	/// the ratio does not read a downward glance as a slouch and is the
	/// preferred evaluation metric. Nil on entries calibrated before it,
	/// or when the ears never cleared the confidence floor during capture
	/// (headphones, a hood); evaluation then stays on the eye pair.
	var earSlouchRatio: CGFloat?
	var earSlouchedRatio: CGFloat?

	/// The gaze probe (added 2026-08-06): how far the eye ratio, the ear
	/// ratio, and the face pitch (degrees) moved between looking at the
	/// camera's screen and looking directly ahead during calibration -
	/// the per-camera angle measurements for the pitch-based strictness
	/// work (see PITCH_TUNING.md). Nil on entries from before the probe
	/// or when its capture was skipped; nothing consumes them at runtime
	/// yet.
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

	/// How far the ratio travels from upright to this user's own slouch on
	/// this camera; nil while only the upright pose was measured.
	var span: CGFloat? {
		return self.slouchedRatio.map { self.slouchRatio - $0 }
	}

	/// The same travel in ear units; nil while unmeasured.
	var earSpan: CGFloat? {
		guard let upright = self.earSlouchRatio, let slouched = self.earSlouchedRatio else { return nil }
		return upright - slouched
	}
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
	// The anchor: the spans (eye and ear units) and eye:shoulder ratio of
	// the one two-pose calibration (every later camera runs single-pose
	// and derives its span from the anchor). Measured together, and
	// deliberately not tied to a camera - the anchor is a unit definition
	// and outlives the device it was measured on. 0 = not measured yet;
	// either span missing makes the next calibration two-pose, which is
	// also what migrates pre-ear-metric installs (their eye-only anchor is
	// refreshed wholesale by that run).
	let postureAnchorSpan: Preference<CGFloat>
	let postureAnchorEarSpan: Preference<CGFloat>
	let postureAnchorEyeShoulderRatio: Preference<CGFloat>
	// Legacy single-baseline preferences, kept only to migrate a pre-per-camera
	// install into postureBaselines once (see migrateLegacyBaselineIfNeeded);
	// cleared after, never written again.
	let postureBaselineSlouchRatio: Preference<CGFloat>
	let postureBaselineDate: Preference<Date>
	// How long (seconds) an issue must persist before it is voiced; drives
	// the report debounce in the analysis service.
	let postureNudgeDelay: Preference<CGFloat>
	// Strictness: how far a metric may drift before it counts as an issue,
	// for both the nudges and the recorded statistics. Slouch: the depth
	// tolerance - the fraction of the calibrated slouch span (upright to
	// demonstrated slouch) the ratio may sink (0.6 relaxed ... 0.2 strict);
	// a camera without a measured span falls back to a nominal span of
	// nominalSlouchSpanFraction of its baseline, which reproduces the old
	// percent-of-baseline ladder exactly. Shoulders: the height difference
	// between the shoulders as a fraction of their separation, i.e. the
	// tilt's slope (0.12 relaxed ... 0.04 strict).
	let postureSlouchDepthTolerance: Preference<CGFloat>
	let postureShoulderTolerance: Preference<CGFloat>
	// Legacy slouch tolerance (fraction below baseline), read once to seed
	// the depth tolerance; never written again.
	let postureSlouchTolerance: Preference<CGFloat>
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

	// A camera without a measured slouch span is judged against this nominal
	// span (a fraction of its baseline). 0.2 is chosen so the depth ladder
	// (0.6...0.2) reproduces the pre-span percent-of-baseline ladder
	// (12...4 percent) stop for stop - the fallback IS the old behavior.
	// nonisolated: also read on the posture analysis queue.
	nonisolated static let nominalSlouchSpanFraction: CGFloat = 0.2

	// Piecewise slouch strictness (PITCH_TUNING.md): the camera's gaze
	// angle theta (middle-of-screen to straight-ahead, degrees, negative
	// = screen below the gaze line) picks the regime; the index picks the
	// stop from that regime's per-metric ladder (percent below baseline,
	// relaxed to strict). Below the boundary the mediums (index 2) are
	// the measured flat region (3 ears / 5 eyes, decided at theta -19..
	// -10); above it they are the current working guess (7 / 8), still
	// being tuned. A camera without a theta (pre-probe entry) is treated
	// as high-camera: the looser regime, until recalibrated. The
	// strictness slider is disconnected from slouch while this is in
	// place - the index below is the whole control. The intended end
	// state: the slider picks this index into the active camera's
	// regime.
	nonisolated static let lowCameraThetaBoundary: CGFloat = -10
	nonisolated static let slouchStrictnessIndex = 2
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

	// The ear lines, least squares over four monitor points spanning
	// -9.9 to -0.6 (PITCH_TUNING.md). R2 0.89 and 0.99, max residual
	// under 1 point - inside the decide-by-feel noise floor, so the fit
	// is as good as the inputs allow.
	nonisolated static let highCameraEarAtScreen = SRStrictnessLine(slope: 0.675055, intercept: 10.6384)
	nonisolated static let highCameraEarLookingDown = SRStrictnessLine(slope: 2.115141, intercept: 26.9169)

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
	// 14 preserves the mean depth the ahead-anchored version had (14.4
	// below centre), so this changes the anchor, not the strictness.
	// Provisional (PITCH_TUNING.md).
	nonisolated static let lookingDownPitchBelowScreenDegrees: CGFloat = 14

	// Release lower than it engages, so a gaze resting on the boundary
	// does not flip the stop every window. Sized from the measured
	// flicker: the zero-divergence trigger it replaces changed verdict
	// about once every 25 s (PITCH_TUNING.md).
	nonisolated static let lookingDownPitchHysteresisDegrees: CGFloat = 3

	// The derived-span mapping: gain scale = (rho / anchor rho) ^ exponent,
	// clamped, one exponent per unit. Fitted 2026-08-06 from the first
	// cross-camera measured pair (the same user's laptop and monitor
	// slouch demos; n=2, so both values are provisional): eyes +1.9,
	// ears -0.85. The ear spans came out nearly camera-independent -
	// most of the old 2-3x "camera gain" was head pitch, and it left
	// with the eye metric. (History: a single shared 6.0, the 2026-08-03
	// physics guess bracketing 4.5-10; it pinned the laptop's derived
	// ear span on the lower clamp rail, and the strictness floor with
	// it.) The clamp bounds what a noisy rho can do to the thresholds.
	nonisolated static let slouchGainExponent: CGFloat = 1.9
	nonisolated static let earSlouchGainExponent: CGFloat = -0.85
	nonisolated static let slouchGainScaleRange: ClosedRange<CGFloat> = 0.25...4.0

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
		self.cameraPanelRelativePosition = Preference("CameraPanelRelativePosition", default: CGPoint.zero, defaults: defaults)
		self.cameraPanelScreenName = Preference("CameraPanelScreenName", default: "", defaults: defaults)
		self.cameraPanelPosition = Preference("CameraPanelPosition", default: CGPoint.zero, defaults: defaults)
		self.cameraPanelPinned = Preference("CameraPanelPinned", default: true, defaults: defaults)
		self.cameraPanelGhostMode = Preference("CameraPanelGhostMode", default: false, defaults: defaults)
		self.launchAtLogin = Preference("LaunchAtLogin", default: false, defaults: defaults)
		self.selectedCameraDeviceID = Preference("SelectedCameraDeviceID", default: "", defaults: defaults)
		self.preferExternalCamera = Preference("PreferExternalCamera", default: true, defaults: defaults)
		self.postureTracking = Preference("PostureTracking", default: false, defaults: defaults)
		self.postureSnoozeUntil = Preference("PostureSnoozeUntil", default: .distantPast, defaults: defaults)
		self.postureBaselines = Preference("PostureBaselines", default: [:], defaults: defaults)
		self.postureAnchorSpan = Preference("PostureAnchorSpan", default: 0, defaults: defaults)
		self.postureAnchorEarSpan = Preference("PostureAnchorEarSpan", default: 0, defaults: defaults)
		self.postureAnchorEyeShoulderRatio = Preference("PostureAnchorEyeShoulderRatio", default: 0, defaults: defaults)
		self.postureBaselineSlouchRatio = Preference("PostureBaselineSlouchRatio", default: 0, defaults: defaults)
		self.postureBaselineDate = Preference("PostureBaselineDate", default: .distantPast, defaults: defaults)
		self.postureNudgeDelay = Preference("PostureNudgeDelaySeconds", default: 10, defaults: defaults)
		self.postureSlouchDepthTolerance = Preference("PostureSlouchDepthTolerance", default: 0.30, defaults: defaults)
		self.postureSlouchTolerance = Preference("PostureSlouchTolerance", default: 0.06, defaults: defaults)
		self.postureShoulderTolerance = Preference("PostureShoulderTolerance", default: 0.10, defaults: defaults)

		// One-time: a pre-depth install stored the slouch tolerance as a
		// fraction of baseline; dividing by the nominal span fraction gives
		// the equivalent depth stop - exact on every ladder stop (0.06 ->
		// 0.30), so a customized strictness carries over unchanged.
		if defaults.object(forKey: "PostureSlouchDepthTolerance") == nil
			&& defaults.object(forKey: "PostureSlouchTolerance") != nil {
			self.postureSlouchDepthTolerance.value = self.postureSlouchTolerance.value / SRSettings.nominalSlouchSpanFraction
		}
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

	/// The slouch span an entry is judged against, by precedence: the
	/// measured one (the entry ran the slouch pose - the anchor itself, or
	/// a pre-hybrid two-pose entry), else one derived from the anchor by
	/// the camera's geometry probe - anchor span x (rho / anchor rho) ^
	/// slouchGainExponent, clamped - else nil (no anchor yet, or an entry
	/// from before the probe: evaluation falls back to the nominal span,
	/// and the takeover gate treats the camera as not fully calibrated).
	func postureEffectiveSlouchSpan(for baseline: PostureBaseline) -> CGFloat? {
		if let span = baseline.span, span > 0 {
			return span
		}
		return self.derivedSlouchSpan(
			anchorSpan: self.postureAnchorSpan.value,
			rho: baseline.eyeShoulderRatio,
			exponent: SRSettings.slouchGainExponent
		)
	}

	/// Ear-unit counterpart of postureEffectiveSlouchSpan, same precedence:
	/// the measured ear span, else one derived from the ear anchor by the
	/// same rho mapping (with the ear-unit exponent), else nil (evaluation
	/// falls back to the nominal fraction of the ear baseline).
	func postureEffectiveEarSlouchSpan(for baseline: PostureBaseline) -> CGFloat? {
		if let span = baseline.earSpan, span > 0 {
			return span
		}
		return self.derivedSlouchSpan(
			anchorSpan: self.postureAnchorEarSpan.value,
			rho: baseline.eyeShoulderRatio,
			exponent: SRSettings.earSlouchGainExponent
		)
	}

	fileprivate func derivedSlouchSpan(anchorSpan: CGFloat, rho: CGFloat?, exponent: CGFloat) -> CGFloat? {
		let anchorRatio = self.postureAnchorEyeShoulderRatio.value
		guard anchorSpan > 0, anchorRatio > 0, let rho, rho > 0 else {
			return nil
		}
		let scale = pow(rho / anchorRatio, exponent)
		return anchorSpan * min(max(scale, SRSettings.slouchGainScaleRange.lowerBound), SRSettings.slouchGainScaleRange.upperBound)
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
				PostureBaseline(slouchRatio: ratio, slouchedRatio: nil, date: self.postureBaselineDate.value, eyeShoulderRatio: nil),
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
/// uniqueID -> ["ratio": Double, "slouched": Double?, "date": epoch seconds];
/// "slouched" is absent on a single-point entry. A malformed entry is
/// dropped rather than failing the whole read.
extension Dictionary: PreferenceValue where Key == String, Value == PostureBaseline {
	static func read(from defaults: UserDefaults, key: String) -> [String: PostureBaseline]? {
		guard let raw = defaults.dictionary(forKey: key) as? [String: [String: Double]] else { return nil }
		var result: [String: PostureBaseline] = [:]
		for (id, fields) in raw {
			guard let ratio = fields["ratio"], let date = fields["date"] else { continue }
			result[id] = PostureBaseline(
				slouchRatio: CGFloat(ratio),
				slouchedRatio: fields["slouched"].map { CGFloat($0) },
				date: Date(timeIntervalSince1970: date),
				eyeShoulderRatio: fields["eyeShoulder"].map { CGFloat($0) },
				earSlouchRatio: fields["earRatio"].map { CGFloat($0) },
				earSlouchedRatio: fields["earSlouched"].map { CGFloat($0) },
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
			if let slouched = baseline.slouchedRatio {
				fields["slouched"] = Double(slouched)
			}
			if let eyeShoulder = baseline.eyeShoulderRatio {
				fields["eyeShoulder"] = Double(eyeShoulder)
			}
			if let earRatio = baseline.earSlouchRatio {
				fields["earRatio"] = Double(earRatio)
			}
			if let earSlouched = baseline.earSlouchedRatio {
				fields["earSlouched"] = Double(earSlouched)
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
