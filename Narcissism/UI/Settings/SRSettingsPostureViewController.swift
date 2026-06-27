//
//  SRSettingsPostureViewController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The Posture page, two groups split by a rule: calibration up top -
/// when the baseline was measured and the button to redo it - then the
/// two strictness sliders that set how far the metrics may drift before
/// they count as issues. The nudge settings live on the Notifications page.
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
		// Shows the baseline of the camera in use (each camera keeps its own),
		// so it follows both a recalibration and a camera switch. An entry
		// without a usable span (neither measured nor derivable from the
		// anchor) reads as partially calibrated: it works on the
		// nominal-span rule but will not take over as an external until
		// recalibrated.
		let baselineLabel = NSTextField(labelWithString: "")
		self.settings.postureBaselines.publisher
			.combineLatest(SRCameraService.sharedInstance.onSelectedDeviceID)
			.sink { [weak self, weak baselineLabel] baselines, deviceID in
				guard let self else { return }
				let baseline = baselines[deviceID]
				baselineLabel?.stringValue = baseline.map {
					String(
						format: NSLocalizedString(
							self.settings.postureEffectiveSlouchSpan(for: $0) != nil
								? "settings.posture.baseline.calibrated"
								: "settings.posture.baseline.partial",
							comment: ""
						),
						Self.baselineDateFormatter.string(from: $0.date)
					)
				} ?? NSLocalizedString("settings.posture.baseline.none", comment: "")
			}
			.store(in: &self.cancellables)
		// Baseline rides the shared label column like every other row: the
		// label right-aligns to the one colon axis, the value sits in the
		// control column. One axis for the whole page reads more native than
		// a centered island.
		let labelTitle = NSTextField(labelWithString: NSLocalizedString("settings.posture.baseline.label", comment: ""))
		let baselineRow = grid.addRow(with: [labelTitle, baselineLabel])
		baselineRow.yPlacement = .center

		// Calibration sits with its baseline: the status line above names
		// when the baseline was taken, the button (re)takes it. The button
		// sits in the control column under the value - a labelless cell, the
		// way a "Change Password..." button rides a pref form - not merged
		// centered, so it keeps the page's one axis. Only makes sense while
		// tracking is on, matching the menu item's visibility rule.
		let calibrateButton = NSButton(
			title: NSLocalizedString("settings.posture.calibrate", comment: ""),
			target: self,
			action: #selector(SRSettingsPostureViewController.handleCalibrate(_:))
		)
		self.settings.postureTracking.publisher
			.sink { [weak calibrateButton] tracking in calibrateButton?.isEnabled = tracking }
			.store(in: &self.cancellables)
		let calibrateRow = grid.addRow(with: [NSGridCell.emptyContentView, calibrateButton])
		calibrateRow.yPlacement = .center

		// A hairline rule splits calibration (what "upright" means) from
		// strictness (how far you may drift from it) - the classic
		// preference-pane way to group without headers shouting on a page
		// this small. Wrapped in a taller container so the rule gets a
		// group-sized gap (~2x the 10pt row spacing) above and below,
		// while the rows themselves keep the 10pt rhythm the other tabs use.
		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		let separatorContainer = NSView()
		separatorContainer.addSubview(separator)
		NSLayoutConstraint.activate([
			separator.leadingAnchor.constraint(equalTo: separatorContainer.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: separatorContainer.trailingAnchor),
			separator.centerYAnchor.constraint(equalTo: separatorContainer.centerYAnchor),
			separatorContainer.heightAnchor.constraint(equalToConstant: 20.0),
		])
		let separatorRow = grid.addRow(with: [separatorContainer])
		separatorRow.mergeCells(in: NSRange(location: 0, length: 2))
		separatorRow.cell(at: 0).xPlacement = .fill

		// Section header: the sliders set how strict posture tracking is per
		// issue, so the group is named for that. It carries the "strictness"
		// framing (the rows stay the bare metric - Slouch, Shoulder tilt - so
		// each label fits the pane), and it names tracking rather than
		// notifications because these thresholds also define what the
		// statistics count as bad posture, not just when a nudge fires.
		let strictnessHeader = NSTextField(labelWithString: NSLocalizedString("settings.posture.strictness.header", comment: ""))
		strictnessHeader.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		let headerRow = grid.addRow(with: [strictnessHeader])
		headerRow.mergeCells(in: NSRange(location: 0, length: 2))
		headerRow.cell(at: 0).xPlacement = .leading

		// Strictness sliders, one ladder of five stops per issue, relaxed
		// on the left. Only the ends are labeled; the middle stops carry
		// no information a name would add. The stop values are the actual
		// tolerances (a slouch-ratio fraction below baseline; a shoulder
		// tilt slope), stored directly so the ladder can be retuned later
		// without migrating anyone.
		func addStrictnessRow(labelKey: String, slider: NSSlider) {
			slider.translatesAutoresizingMaskIntoConstraints = false
			slider.widthAnchor.constraint(equalToConstant: 160.0).isActive = true
			func endLabel(_ key: String) -> NSTextField {
				let label = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
				label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
				label.textColor = .secondaryLabelColor
				return label
			}
			let stack = NSStackView(views: [
				endLabel("settings.posture.strictness.relaxed"),
				slider,
				endLabel("settings.posture.strictness.strict"),
			])
			stack.orientation = .horizontal
			stack.spacing = 8.0
			let label = NSTextField(labelWithString: NSLocalizedString(labelKey, comment: ""))
			let row = grid.addRow(with: [label, stack])
			row.yPlacement = .center
		}
		// Inert for slouch while the piecewise strictness runs (see
		// SRSettings.slouchStrictnessIndex): the control still works and
		// stores, but the evaluation reads the per-regime percent tables.
		// Intended end state: this slider picks the strictness index.
		addStrictnessRow(
			labelKey: "settings.posture.slouch-strictness.label",
			slider: SRPreferenceStepSlider(
				stops: [0.60, 0.50, 0.40, 0.30, 0.20],
				preference: self.settings.postureSlouchDepthTolerance
			)
		)
		addStrictnessRow(
			labelKey: "settings.posture.shoulder-strictness.label",
			slider: SRPreferenceStepSlider(
				stops: [0.12, 0.10, 0.08, 0.06, 0.04],
				preference: self.settings.postureShoulderTolerance
			)
		)

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

	@objc fileprivate func handleCalibrate(_ sender: Any?) {
		self.onCalibrate()
	}

}
