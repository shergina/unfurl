//
//  SRGoodPostureReminders.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import AppKit


/// The sit-like-this reminders (hips back, sit tall, shoulders level),
/// defined once and shown by both surfaces that lead into a capture: the
/// welcome flow's good-posture page and the calibration window's first
/// page. The baseline is whatever the user happens to hold during those
/// five seconds, and a bad one fails silently - the app goes on coaching
/// toward a slouch - so neither surface starts the camera without it.
@MainActor
enum SRGoodPostureReminders {

	/// The title and its one-line stakes over the three rows, in the welcome
	/// flow's row style. Lays out at SRWelcomeRows.textWidth, which is
	/// exactly the calibration window's width minus its margins, so it drops
	/// into either host.
	static func contentView() -> NSView {
		let titleView = SRWelcomeRows.label(
			NSLocalizedString("posture.good.title", comment: ""),
			font: NSFont.systemFont(ofSize: 20, weight: .bold)
		)
		titleView.alignment = .center

		// Why the list is worth reading. Both hosts show this page in a
		// window sized for the camera page, so without it the list is a
		// small block floating between two large voids.
		let bodyView = SRWelcomeRows.label(
			NSLocalizedString("posture.good.body", comment: ""),
			font: NSFont.systemFont(ofSize: 13),
			color: NSColor.secondaryLabelColor
		)
		bodyView.alignment = .center

		let header = NSStackView(views: [titleView, bodyView])
		header.orientation = .vertical
		header.alignment = .centerX
		header.spacing = 8
		header.translatesAutoresizingMaskIntoConstraints = false

		let rows = NSStackView(views: [
			SRWelcomeRows.row(
				symbol: "chair",
				titleKey: "posture.good.hips.title",
				bodyKey: "posture.good.hips.body"
			),
			SRWelcomeRows.row(
				symbol: "arrow.up.to.line",
				titleKey: "posture.good.tall.title",
				bodyKey: "posture.good.tall.body"
			),
			SRWelcomeRows.row(
				symbol: "figure.arms.open",
				titleKey: "posture.good.shoulders.title",
				bodyKey: "posture.good.shoulders.body"
			),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 22
		rows.translatesAutoresizingMaskIntoConstraints = false

		let stack = NSStackView(views: [header, rows])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 24
		stack.translatesAutoresizingMaskIntoConstraints = false

		NSLayoutConstraint.activate([
			rows.widthAnchor.constraint(equalToConstant: SRWelcomeRows.textWidth),
		])

		return stack
	}

}


/// The calibration window's first page: the reminders, then Ready swaps in
/// the capture page. Ready is deliberately not Begin - nothing is measured
/// here, so a user who hammers Return past this page loses nothing.
@MainActor
final class SRPostureRemindersViewController: NSViewController {

	var onReady: (() -> Void)?

	/// Set before the view loads. Adds the line explaining why a second
	/// camera needs its own calibration - true only when this camera has no
	/// baseline and another one does, which is the moment the rule stops
	/// being abstract. The welcome flow shares the reminders content but not
	/// this controller, so onboarding never shows it.
	var showsPerCameraNote = false

	override func loadView() {
		let size = SRPostureCalibrationViewController.contentSize
		let view = NSView(frame: CGRect(origin: .zero, size: size))
		self.preferredContentSize = size

		let content: NSView
		if self.showsPerCameraNote {
			let note = SRWelcomeRows.label(
				NSLocalizedString("posture.good.per-camera", comment: ""),
				font: NSFont.systemFont(ofSize: 13),
				color: NSColor.secondaryLabelColor
			)
			note.alignment = .center
			note.translatesAutoresizingMaskIntoConstraints = false
			note.widthAnchor.constraint(equalToConstant: SRWelcomeRows.textWidth).isActive = true

			let stack = NSStackView(views: [SRGoodPostureReminders.contentView(), note])
			stack.orientation = .vertical
			stack.alignment = .centerX
			stack.spacing = 24
			stack.translatesAutoresizingMaskIntoConstraints = false
			content = stack
		} else {
			content = SRGoodPostureReminders.contentView()
		}
		view.addSubview(content)

		let readyButton = NSButton(
			title: NSLocalizedString("posture.good.ready", comment: ""),
			target: self,
			action: #selector(SRPostureRemindersViewController.handleReady)
		)
		readyButton.translatesAutoresizingMaskIntoConstraints = false
		readyButton.bezelStyle = .rounded
		readyButton.controlSize = .large
		readyButton.keyEquivalent = "\r"
		view.addSubview(readyButton)

		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			// Nudged above center: the button sits low, so a dead-centered
			// list reads as drifting downward.
			content.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),

			// Same height as the capture page's Begin, so the button does
			// not jump when the pages swap.
			readyButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			readyButton.bottomAnchor.constraint(
				equalTo: view.bottomAnchor,
				constant: -SRPostureCalibrationViewController.actionButtonBottomInset
			),
		])

		self.view = view
	}

	@objc fileprivate func handleReady() {
		self.onReady?()
	}

}
