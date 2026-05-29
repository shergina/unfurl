//
//  SRSettingsStatisticsViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The Statistics page, deliberately empty for now: it reserves the tab
/// while the posture history store that will feed it does not exist yet
/// (see VISION.md).
final class SRSettingsStatisticsViewController: NSViewController {

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let label = NSTextField(labelWithString: NSLocalizedString("settings.statistics.placeholder", comment: ""))
		label.textColor = .secondaryLabelColor
		label.translatesAutoresizingMaskIntoConstraints = false

		let view = NSView()
		view.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		self.preferredContentSize = CGSize(width: 540.0, height: 260.0)
	}

}
