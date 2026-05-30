//
//  SRSettingsPostureViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The Posture page: the calibration home - when the baseline was
/// measured and the button to redo it. The nudge settings live on the
/// Notifications page.
final class SRSettingsPostureViewController: NSViewController {

	fileprivate let settings = SRSettings.sharedInstance
	fileprivate let onCalibrate: () -> Void
	fileprivate var cancellables = Set<AnyCancellable>()

	fileprivate static let baselineDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		return formatter
	}()

	init(onCalibrate: @escaping () -> Void) {
		self.onCalibrate = onCalibrate
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

		// The stored baseline, named by when it was measured; the ratio
		// itself is a meaningless number to a user, the date is not.
		let baselineLabel = NSTextField(labelWithString: "")
		self.settings.postureBaselineSlouchRatio.publisher
			.combineLatest(self.settings.postureBaselineDate.publisher)
			.sink { [weak baselineLabel] ratio, date in
				baselineLabel?.stringValue = ratio > 0
					? String(
						format: NSLocalizedString("settings.posture.baseline.calibrated", comment: ""),
						Self.baselineDateFormatter.string(from: date)
					)
					: NSLocalizedString("settings.posture.baseline.none", comment: "")
			}
			.store(in: &self.cancellables)
		let labelTitle = NSTextField(labelWithString: NSLocalizedString("settings.posture.baseline.label", comment: ""))
		let baselineRow = grid.addRow(with: [labelTitle, baselineLabel])
		baselineRow.yPlacement = .center

		// Calibration only makes sense while tracking is on, matching the
		// menu item's visibility rule. Full-width centered action row.
		let calibrateButton = NSButton(
			title: NSLocalizedString("settings.posture.calibrate", comment: ""),
			target: self,
			action: #selector(SRSettingsPostureViewController.handleCalibrate(_:))
		)
		self.settings.postureTracking.publisher
			.sink { [weak calibrateButton] tracking in calibrateButton?.isEnabled = tracking }
			.store(in: &self.cancellables)
		let calibrateRow = grid.addRow(with: [calibrateButton])
		calibrateRow.mergeCells(in: NSRange(location: 0, length: 2))
		calibrateRow.cell(at: 0).xPlacement = .center

		let view = NSView()
		view.addSubview(grid)
		// Top-anchored, never bottom-pinned: a page taller than its content
		// keeps the rows together at the top instead of stretching them apart.
		NSLayoutConstraint.activate([
			grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20.0),
			grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20.0),
			grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20.0),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		self.preferredContentSize = CGSize(width: 540.0, height: max(240.0, self.view.fittingSize.height))
	}

	@objc fileprivate func handleCalibrate(_ sender: Any?) {
		self.onCalibrate()
	}

}
