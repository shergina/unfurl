//
//  SRPostureCalibrationNudgeController.swift
//  Narcissism
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

	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.narcissism", category: "Posture")

	fileprivate let services: AppServices
	fileprivate var cancellables = Set<AnyCancellable>()

	/// Nudged at most once per camera per app session; a dismissed nudge
	/// does not come back on every replug (the menu's Calibrate item and
	/// the Settings button remain the on-demand paths).
	fileprivate var nudgedDeviceIDs = Set<String>()

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
		let blockedIDs = Set(blocked.map { $0.id })
		let stale = self.nudgedDeviceIDs.subtracting(blockedIDs).map { Self.identifierPrefix + $0 }
		let center = UNUserNotificationCenter.current()
		if !stale.isEmpty {
			center.removeDeliveredNotifications(withIdentifiers: stale)
			center.removePendingNotificationRequests(withIdentifiers: stale)
		}

		for device in blocked where !self.nudgedDeviceIDs.contains(device.id) {
			self.nudgedDeviceIDs.insert(device.id)
			self.post(for: device, baselines: baselines)
		}
	}

	/// The wording names what calibrating this camera buys, which turns on
	/// whether tracking is producing anything right now - that is, whether
	/// the *active* camera has a baseline, not whether this device happens
	/// to be the active one. Judging by the latter claimed a switch while
	/// tracking was stalled on an uncalibrated built-in.
	///
	/// Working: an upgrade, so offer the switch. Stalled after having
	/// worked: a resume. Never calibrated on any camera: a start - "resume"
	/// would claim something stopped, and nothing ever ran.
	fileprivate func notificationKeys(
		for device: CameraDevice,
		baselines: [String: PostureBaseline]
	) -> (title: String, body: String) {
		if baselines[self.services.camera.onSelectedDeviceID.value] != nil {
			return ("posture.nudge.title", "posture.nudge.body")
		}
		return baselines.isEmpty
			? ("posture.nudge.title.start", "posture.nudge.body.start")
			: ("posture.nudge.title.resume", "posture.nudge.body.resume")
	}

	/// Authorization is requested lazily, on the first nudge that actually
	/// needs it, never at launch. Denial is logged, not silent.
	fileprivate func post(for device: CameraDevice, baselines: [String: PostureBaseline]) {
		let keys = self.notificationKeys(for: device, baselines: baselines)
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
				identifier: Self.identifierPrefix + device.id,
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
