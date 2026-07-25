//
//  SRSettingsPostureViewController.swift
//  Narcissism
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
	fileprivate let cameraList = NSGridView(numberOfColumns: 4, rows: 0)

	fileprivate static let baselineDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
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
		self.cameraList.rowSpacing = 8.0
		self.cameraList.columnSpacing = 8.0
		self.cameraList.column(at: 0).xPlacement = .center
		for column in 1..<4 {
			self.cameraList.column(at: column).xPlacement = .leading
		}
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
		let camerasLabel = NSTextField(labelWithString: NSLocalizedString("settings.posture.cameras.label", comment: ""))
		let camerasRow = grid.addRow(with: [camerasLabel, self.cameraList])
		// Top, not center: the label names a list that grows with the
		// cameras, so it should sit level with the first row of it.
		camerasRow.yPlacement = .top

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
		while self.cameraList.numberOfRows > 0 {
			self.cameraList.removeRow(at: 0)
		}

		for device in devices {
			// A checkmark for the camera in use, matching the Camera
			// submenu's vocabulary rather than inventing a second one. The
			// accessibility description carries it for VoiceOver, where a
			// bare glyph would say nothing.
			let inUse = NSImageView()
			if device.id == activeID {
				inUse.image = NSImage(
					systemSymbolName: "checkmark",
					accessibilityDescription: NSLocalizedString("settings.posture.camera.in-use", comment: "")
				)
				inUse.contentTintColor = .secondaryLabelColor
			}

			let name = NSTextField(labelWithString: device.name)

			// The date, not the ratio: the stored number is meaningless to a
			// user, when it was taken is not.
			let baseline = baselines[device.id]
			let status = NSTextField(labelWithString: baseline.map {
				String(
					format: NSLocalizedString("settings.posture.baseline.calibrated", comment: ""),
					Self.baselineDateFormatter.string(from: $0.date)
				)
			} ?? NSLocalizedString("settings.posture.baseline.none", comment: ""))
			status.textColor = .secondaryLabelColor

			// Calibrate vs Recalibrate: the verb says whether this camera has
			// ever been set up, which is the whole point of the list.
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

			let row = self.cameraList.addRow(with: [inUse, name, status, button])
			row.yPlacement = .center
		}
	}

	@objc fileprivate func handleCalibrate(_ sender: Any?) {
		self.onCalibrate((sender as? NSButton)?.identifier?.rawValue)
	}

}
