//
//  SRPostureCalibrationNudgeController.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine
import UserNotifications
import os


/// The new-camera calibration nudge: when the calibration gate blocks the
/// external-camera takeover (an uncalibrated monitor camera appeared while
/// posture tracking is on), a system notification offers to calibrate it.
/// A real notification, not the corner-note style, on purpose: the corner
/// note is click-through by design and this nudge needs a button, and a
/// rare, actionable, fine-to-wait event is what Notification Center is for
/// (prefer the system primitive). Accepting funnels into the one shared
/// calibration window, targeted at the new camera; completing calibration
/// stores its baseline, which reopens the gate and lets the takeover happen.
@MainActor
final class SRPostureCalibrationNudgeController: NSObject, UNUserNotificationCenterDelegate {

	fileprivate nonisolated static let categoryIdentifier = "posture-calibration-nudge"
	fileprivate nonisolated static let calibrateActionIdentifier = "calibrate"
	fileprivate nonisolated static let identifierPrefix = "posture-calibration-nudge."
	fileprivate nonisolated static let deviceIDKey = "deviceID"

	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.unfurl", category: "Posture")

	/// What calibrating a blocked camera would buy, which is what the nudge
	/// has to say. Decided by whether tracking is producing anything right
	/// now - see notificationKeys.
	fileprivate enum NudgeState: String {
		/// Tracking works on another camera; this one is an upgrade.
		case offerSwitch
		/// Tracking is stalled on an uncalibrated camera, but has worked.
		case offerResume
		/// No camera has ever been calibrated, so nothing ever ran.
		case offerStart
	}

	/// One identifier per camera *and* state, not per camera. Reusing an
	/// identifier makes macOS treat the post as an update to the delivered
	/// notification rather than a new one, and an update does not alert:
	/// measured 2026-08-12, where an escalation posted with no error, landed
	/// in Notification Center, and never showed a banner. Each state gets its
	/// own identifier and the previous one is withdrawn by hand.
	fileprivate nonisolated static func identifier(deviceID: String, state: NudgeState) -> String {
		return Self.identifierPrefix + state.rawValue + "." + deviceID
	}

	fileprivate let services: AppServices
	fileprivate var cancellables = Set<AnyCancellable>()

	/// Baseline camera ids as of the last emission, nil until the launch
	/// replay lands. Lets a new key - a calibration just completed - be
	/// told apart from the stored set replaying at launch, which must not
	/// prompt (the never-at-launch rule).
	fileprivate var knownBaselineIDs: Set<String>?

	/// What has already been said about each blocked camera this session.
	///
	/// The inputs are levels, not events: reconcile runs on every emission
	/// of the four combined publishers - a preference toggle, a baseline
	/// write, any republish of the device list - and each run finds the same
	/// camera still blocked. This is the memory that turns "is blocked" into
	/// "just became blocked", so a nudge fires on the edge instead of on
	/// every re-evaluation.
	///
	/// Keyed by state, not just by camera (2026-08-12): keying by camera
	/// alone suppressed the escalation from offerSwitch to offerResume, so
	/// closing the lid on an uncalibrated monitor left tracking stopped with
	/// nothing said, and left the delivered notification claiming a switch
	/// was on offer. Re-posting under the same identifier replaces that
	/// notification rather than stacking a second.
	fileprivate var nudgedStates: [String: NudgeState] = [:]

	init(services: AppServices) {
		self.services = services
		super.init()

		let center = UNUserNotificationCenter.current()
		center.delegate = self
		let calibrate = UNNotificationAction(
			identifier: Self.calibrateActionIdentifier,
			title: NSLocalizedString("posture.nudge.action", comment: ""),
			options: []
		)
		center.setNotificationCategories([UNNotificationCategory(
			identifier: Self.categoryIdentifier,
			actions: [calibrate],
			intentIdentifiers: [],
			options: []
		)])

		// The nudge condition is the gate's blocking condition: takeover
		// allowed by the user (toggle on), wanted by tracking (on), and an
		// external camera present with no baseline. All inputs replay, so a
		// launch while docked and uncalibrated nudges too.
		self.services.settings.preferExternalCamera.publisher
			.combineLatest(
				self.services.settings.postureTracking.publisher,
				self.services.settings.postureBaselines.publisher,
				self.services.camera.onDevices
			)
			.sink { [weak self] prefer, tracking, baselines, devices in
				self?.reconcile(prefer: prefer, tracking: tracking, baselines: baselines, devices: devices)
			}
			.store(in: &self.cancellables)

		// A finished calibration is the engaged moment to ask for
		// notification authorization: the user just did the thing the nudge
		// offers to repeat for future cameras, and is looking at an app
		// window rather than plugging cables. The first-nudge ask in post()
		// stays as the backstop for a nudge that fires before any
		// calibration has ever completed.
		self.services.settings.postureBaselines.publisher
			.sink { [weak self] baselines in
				self?.primeAuthorization(baselines: baselines)
			}
			.store(in: &self.cancellables)
	}

	/// Prompts only while authorization is undetermined; once the user has
	/// answered, the system makes this a no-op. Keyed on new camera ids, so
	/// recalibrating an existing camera stays quiet.
	fileprivate func primeAuthorization(baselines: [String: PostureBaseline]) {
		let ids = Set(baselines.keys)
		defer { self.knownBaselineIDs = ids }
		guard let known = self.knownBaselineIDs, !ids.subtracting(known).isEmpty else { return }
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
			if let error {
				Self.logger.error("Post-calibration authorization error: \(error.localizedDescription)")
			}
			if !granted {
				Self.logger.warning("Notification authorization not granted after calibration")
			}
		}
	}

	fileprivate func reconcile(prefer: Bool, tracking: Bool, baselines: [String: PostureBaseline], devices: [CameraDevice]) {
		// Blocked = the gate would not let this external take over, i.e. it
		// has no baseline (see the gate in the composition root).
		let blocked = (prefer && tracking)
			? devices.filter { $0.isExternal && baselines[$0.id] == nil }
			: []

		// Withdraw a delivered nudge once its reason is gone (calibrated,
		// unplugged, tracking off): a stale "calibrate to switch" lingering
		// in Notification Center would offer something already done.
		//
		// The memory outlives the withdrawal on purpose. Dropping it would
		// make an unplug forget the camera, so replugging would nudge the
		// same thing again - the replug nagging this rule exists to stop. A
		// replug under changed conditions still gets through, because the
		// state it compares against will have changed too.
		let blockedIDs = Set(blocked.map { $0.id })
		let stale = self.nudgedStates.filter { !blockedIDs.contains($0.key) }
		if !stale.isEmpty {
			self.withdraw(stale.map { Self.identifier(deviceID: $0.key, state: $0.value) })
		}

		// Post on a change of state, not merely on being blocked: the same
		// state again is the replug case and stays quiet, a different one is
		// something the user has not been told.
		for device in blocked {
			let state = self.nudgeState(baselines: baselines)
			let previous = self.nudgedStates[device.id]
			guard previous != state else { continue }
			// The superseded wording goes first, by its own identifier: two
			// nudges for one camera saying different things would be worse
			// than the stale single one this replaced.
			if let previous {
				self.withdraw([Self.identifier(deviceID: device.id, state: previous)])
			}
			self.nudgedStates[device.id] = state
			self.post(for: device, state: state)
		}
	}

	fileprivate func withdraw(_ identifiers: [String]) {
		let center = UNUserNotificationCenter.current()
		center.removeDeliveredNotifications(withIdentifiers: identifiers)
		center.removePendingNotificationRequests(withIdentifiers: identifiers)
	}

	/// What calibrating buys, which turns on whether tracking is producing
	/// anything right now - that is, whether the *active* camera has a
	/// baseline, not whether the blocked device happens to be the active
	/// one. Judging by the latter claimed a switch while tracking was
	/// stalled on an uncalibrated built-in.
	///
	/// Working: an upgrade, so offer the switch. Stalled after having
	/// worked: a resume. Never calibrated on any camera: a start - "resume"
	/// would claim something stopped, and nothing ever ran.
	///
	/// One value for every blocked camera: it describes the state of
	/// tracking, not of the camera being offered.
	fileprivate func nudgeState(baselines: [String: PostureBaseline]) -> NudgeState {
		if baselines[self.services.camera.onSelectedDeviceID.value] != nil {
			return .offerSwitch
		}
		return baselines.isEmpty ? .offerStart : .offerResume
	}

	fileprivate func notificationKeys(for state: NudgeState) -> (title: String, body: String) {
		switch state {
		case .offerSwitch:
			return ("posture.nudge.title", "posture.nudge.body")
		case .offerResume:
			return ("posture.nudge.title.resume", "posture.nudge.body.resume")
		case .offerStart:
			return ("posture.nudge.title.start", "posture.nudge.body.start")
		}
	}

	/// The authorization request here is the backstop for users who hit a
	/// nudge before ever completing a calibration; the primary ask happens
	/// in primeAuthorization, when a calibration finishes. Never at launch.
	/// Denial is logged, not silent.
	fileprivate func post(for device: CameraDevice, state: NudgeState) {
		let keys = self.notificationKeys(for: state)
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
			if let error {
				Self.logger.error("Calibration nudge authorization error: \(error.localizedDescription)")
			}
			guard granted else {
				Self.logger.warning("Calibration nudge for \(device.name) suppressed: notifications not authorized")
				return
			}
			let content = UNMutableNotificationContent()
			content.title = NSLocalizedString(keys.title, comment: "")
			content.body = String(format: NSLocalizedString(keys.body, comment: ""), device.name)
			content.categoryIdentifier = Self.categoryIdentifier
			content.userInfo = [Self.deviceIDKey: device.id]
			UNUserNotificationCenter.current().add(UNNotificationRequest(
				identifier: Self.identifier(deviceID: device.id, state: state),
				content: content,
				trigger: nil
			)) { error in
				if let error {
					Self.logger.error("Calibration nudge delivery error: \(error.localizedDescription)")
				}
			}
		}
	}

	//: UNUserNotificationCenterDelegate

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		// The app is a menu-bar agent, "active" in name only; show the
		// banner regardless.
		completionHandler([.banner])
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		let deviceID = response.notification.request.content.userInfo[Self.deviceIDKey] as? String
		let action = response.actionIdentifier
		completionHandler()

		guard let deviceID,
			action == Self.calibrateActionIdentifier || action == UNNotificationDefaultActionIdentifier
		else { return }
		Task { @MainActor [weak self] in
			guard let self else { return }
			// The same deliberate resume the menu's Calibrate item makes.
			self.services.settings.postureSnoozeUntil.value = .distantPast
			self.services.menu.showPostureCalibration(forDeviceID: deviceID)
		}
	}

}
