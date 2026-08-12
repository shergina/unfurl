//
//  SRSettingsPostureViewController.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The Posture page, two groups split by a rule: the cameras up top -
/// one row each, showing which is in use and when it was calibrated -
/// then the two strictness sliders that set how far the metrics may drift
/// before they count as issues. The nudge settings live on the
/// Notifications page.
final class SRSettingsPostureViewController: NSViewController {

	fileprivate let settings = SRSettings.sharedInstance
	fileprivate let onCalibrate: (String?) -> Void
	fileprivate var cancellables = Set<AnyCancellable>()

	/// Rebuilt whenever the cameras, the baselines, the active camera or
	/// the tracking toggle change.
	fileprivate let cameraList = NSStackView()

	/// The width of the control column - the strictness rows. Fixed because
	/// the tab view sizes the window to the selected page, so Posture has
	/// to match General and Notifications rather than stretch to its
	/// content. The camera rows span the page under their header instead
	/// (2026-08-13) and share only the trailing axis, via their own width
	/// rule.
	fileprivate static let controlColumnWidth: CGFloat = 372.0

	fileprivate static let baselineDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		// Today/yesterday instead of the bare date, cased for the middle
		// of "Calibrated ..." - the way Finder speaks.
		formatter.doesRelativeDateFormatting = true
		formatter.formattingContext = .middleOfSentence
		return formatter
	}()

	init(onCalibrate: @escaping (String?) -> Void) {
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

		// One row per connected camera: which one is in use, its name, when
		// it was calibrated, and the button that (re)takes it. Calibration
		// is per-camera and nothing in the UI used to say so - a lone
		// "Baseline:" line taught the opposite, that one calibration covers
		// every camera, which is exactly why a new-camera nudge reads as a
		// nag. Seeing the laptop calibrated and the monitor not, side by
		// side, is the explanation.
		//
		// Connected cameras only: a stored baseline keeps an id and a date,
		// never a device name, so a camera that is not plugged in cannot be
		// labelled with anything a user would recognise.
		self.cameraList.translatesAutoresizingMaskIntoConstraints = false
		self.cameraList.orientation = .vertical
		self.cameraList.alignment = .leading
		self.cameraList.spacing = 12.0
		SRCameraService.sharedInstance.onDevices
			.combineLatest(
				self.settings.postureBaselines.publisher,
				SRCameraService.sharedInstance.onSelectedDeviceID,
				self.settings.postureTracking.publisher
			)
			.sink { [weak self] devices, baselines, activeID, tracking in
				self?.rebuildCameraList(
					devices: devices,
					baselines: baselines,
					activeID: activeID,
					tracking: tracking
				)
			}
			.store(in: &self.cancellables)
		// Both groups open with a semibold header (2026-08-13): one idiom
		// for the page. The old rule - a header only where the rows do not
		// explain themselves - read as imbalance next to the headerless
		// cameras group.
		func addSectionHeader(_ labelKey: String) {
			let header = NSTextField(labelWithString: NSLocalizedString(labelKey, comment: ""))
			header.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
			let row = grid.addRow(with: [header])
			row.mergeCells(in: NSRange(location: 0, length: 2))
			row.cell(at: 0).xPlacement = .leading
		}

		addSectionHeader("settings.posture.cameras.header")
		// The camera rows span both grid columns: under a full-width header,
		// content takes the header's axis plus a small indent (the System
		// Settings idiom). Leaving them in the control column left the label
		// column empty beside them, and a hole reads as a mistake. Trailing
		// placement plus the width rule keeps the buttons on the same
		// trailing axis as the sliders.
		let camerasRow = grid.addRow(with: [self.cameraList])
		camerasRow.mergeCells(in: NSRange(location: 0, length: 2))
		camerasRow.cell(at: 0).xPlacement = .trailing
		camerasRow.yPlacement = .top
		// 4pt tighter to the header: the first row is button-tall and the
		// name centers inside it, landing lower under its header than the
		// strictness rows land under theirs. This evens the two gaps.
		camerasRow.topPadding = -4.0
		self.cameraList.widthAnchor.constraint(equalTo: grid.widthAnchor, constant: -16.0).isActive = true

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

		// The header carries the "strictness" framing (the rows stay the
		// bare metric - Slouch, Shoulder tilt - so each label fits the
		// pane), and it names tracking rather than notifications because
		// these thresholds also define what the statistics count as bad
		// posture, not just when a nudge fires.
		addSectionHeader("settings.posture.strictness.header")

		// Strictness sliders, one ladder of five stops per issue, relaxed
		// on the left. Only the ends are labeled; the middle stops carry
		// no information a name would add. The stop values are the actual
		// tolerances (a slouch-ratio fraction below baseline; a shoulder
		// tilt slope), stored directly so the ladder can be retuned later
		// without migrating anyone.
		func addStrictnessRow(labelKey: String, slider: NSSlider) {
			slider.translatesAutoresizingMaskIntoConstraints = false
			// The slider takes whatever the two end labels leave, so every
			// strictness row ends on the same trailing axis as the camera
			// rows above. A fixed slider width stopped them short of it.
			slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
			stack.distribution = .fill
			stack.translatesAutoresizingMaskIntoConstraints = false
			stack.widthAnchor.constraint(equalToConstant: Self.controlColumnWidth).isActive = true
			let label = NSTextField(labelWithString: NSLocalizedString(labelKey, comment: ""))
			let row = grid.addRow(with: [label, stack])
			row.yPlacement = .center
		}
		// The slouch slider stores the ladder index rather than a tolerance:
		// what a stop means depends on the camera's angle, so the value has
		// to be resolved against the active baseline, not baked into the
		// control (see SRSettings.highCameraAtScreenLadder).
		addStrictnessRow(
			labelKey: "settings.posture.slouch-strictness.label",
			slider: SRPreferenceStepSlider(
				stops: [0, 1, 2, 3, 4],
				preference: self.settings.postureSlouchStrictnessIndex
			)
		)
		addStrictnessRow(
			labelKey: "settings.posture.shoulder-strictness.label",
			slider: SRPreferenceStepSlider(
				stops: [0.18, 0.15, 0.12, 0.09, 0.06],
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

	/// Rows are torn down and rebuilt wholesale: the list is four cells long
	/// on a normal desk, so diffing it would be more code than it saves.
	fileprivate func rebuildCameraList(
		devices: [CameraDevice],
		baselines: [String: PostureBaseline],
		activeID: String,
		tracking: Bool
	) {
		for view in self.cameraList.arrangedSubviews {
			self.cameraList.removeArrangedSubview(view)
			view.removeFromSuperview()
		}

		var buttons: [NSButton] = []
		for device in devices {
			let name = NSTextField(labelWithString: device.name)
			name.lineBreakMode = .byTruncatingTail
			// Low hugging: the name takes the slack, which pins the button to
			// the trailing edge on every row.
			name.setContentHuggingPriority(.defaultLow, for: .horizontal)
			name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

			// Calibrate vs Recalibrate: the verb says whether this camera has
			// ever been set up, which is the whole point of the list.
			let baseline = baselines[device.id]
			let button = NSButton(
				title: NSLocalizedString(
					baseline == nil ? "settings.posture.calibrate" : "settings.posture.recalibrate",
					comment: ""
				),
				target: self,
				action: #selector(SRSettingsPostureViewController.handleCalibrate(_:))
			)
			// The row's camera, carried on the button: the action needs to
			// know which one was asked for, and it may not be the active one.
			button.identifier = NSUserInterfaceItemIdentifier(device.id)
			button.isEnabled = tracking
			// High, not required: the equal-width rule below may stretch a
			// button past its intrinsic size.
			button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
			buttons.append(button)

			let header = NSStackView(views: [name, button])
			header.orientation = .horizontal
			header.spacing = 6.0
			// .fill, not the default .gravityAreas: gravity packs each view at
			// its intrinsic width, which leaves the button next to the name
			// and the row short of its trailing edge. Filling lets the
			// low-hugging name take the slack so the button pins right, the
			// way a device list reads.
			header.distribution = .fill

			// The date, not the ratio: the stored number is meaningless to a
			// user, when it was taken is not. Secondary and on its own line
			// under the name - two short lines fit the shared window width
			// where one long row did not.
			//
			// "In use" is folded in here rather than drawn as a leading
			// checkmark: a checkmark gutter indents every camera name past
			// the axis the strictness rows start on, and the page is built on
			// having one such axis. It also reads better under VoiceOver than
			// a bare glyph.
			var statusText = baseline.map {
				String(
					format: NSLocalizedString("settings.posture.baseline.calibrated", comment: ""),
					Self.baselineDateFormatter.string(from: $0.date)
				)
			} ?? NSLocalizedString("settings.posture.baseline.none", comment: "")
			if device.id == activeID {
				statusText = String(
					format: NSLocalizedString("settings.posture.camera.in-use", comment: ""),
					statusText
				)
			}
			let status = NSTextField(labelWithString: statusText)
			status.textColor = .secondaryLabelColor
			status.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
			status.lineBreakMode = .byTruncatingTail

			let block = NSStackView(views: [header, status])
			block.orientation = .vertical
			block.alignment = .leading
			block.spacing = 2.0
			block.translatesAutoresizingMaskIntoConstraints = false

			self.cameraList.addArrangedSubview(block)
			block.widthAnchor.constraint(equalTo: self.cameraList.widthAnchor).isActive = true
			header.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
		}

		// One width for all the buttons: stacked, Calibrate and Recalibrate
		// read as a column, and a ragged column reads as noise.
		for button in buttons.dropFirst() {
			button.widthAnchor.constraint(equalTo: buttons[0].widthAnchor).isActive = true
		}
	}

	@objc fileprivate func handleCalibrate(_ sender: Any?) {
		self.onCalibrate((sender as? NSButton)?.identifier?.rawValue)
	}

}
