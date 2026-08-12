//
//  SRSettingsGeneralViewController.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The General page: the everyday switches, bound straight to their
/// preferences. Camera availability is deliberately not consulted here -
/// this page configures intent, and the surfaces themselves explain an
/// unavailable camera.
final class SRSettingsGeneralViewController: NSViewController {

	fileprivate let settings = SRSettings.sharedInstance
	fileprivate var cancellables = Set<AnyCancellable>()

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let grid = NSGridView(numberOfColumns: 2, rows: 0)
		grid.translatesAutoresizingMaskIntoConstraints = false
		grid.rowSpacing = 10.0
		grid.columnSpacing = 12.0
		grid.column(at: 0).xPlacement = .trailing
		grid.column(at: 1).xPlacement = .leading

		func addRow(_ labelKey: String, _ control: NSView) {
			let label = NSTextField(labelWithString: NSLocalizedString(labelKey, comment: ""))
			let row = grid.addRow(with: [label, control])
			row.yPlacement = .center
		}

		addRow("settings.general.track-posture", SRPreferenceSwitch(preference: self.settings.postureTracking))
		addRow("settings.general.show-camera-panel", SRPreferenceSwitch(preference: self.settings.cameraPanelPinned))
		addRow("settings.general.show-camera-on-status-bar", SRPreferenceSwitch(preference: self.settings.showCameraOnStatusBar))
		addRow("settings.general.prefer-external-camera", SRPreferenceSwitch(preference: self.settings.preferExternalCamera))
		addRow("settings.general.launch-at-login", SRPreferenceSwitch(preference: self.settings.launchAtLogin))

		let view = NSView()
		view.addSubview(grid)
		// Top-anchored, never bottom-pinned: a page taller than its content
		// keeps the rows together at the top instead of stretching them apart.
		NSLayoutConstraint.activate([
			grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20.0),
			grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28.0),
			grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20.0),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		self.preferredContentSize = CGSize(width: 540.0, height: self.view.fittingSize.height)
	}

}
