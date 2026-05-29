//
//  SRPostureNoteController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The corner posture note: a small ghost panel pinned to the top-right
/// corner of the main screen, visible only while there is something to say
/// - the debounced corrections to make, or "can't see you clearly". Good
/// posture shows nothing: the note disappearing is the reward. Prototype
/// of the ghost-toast notification design (see spec.md): click-through,
/// semi-transparent, excluded from screen capture so shared screens and
/// recordings never show it, on every Space including fullscreen, and
/// deliberately indifferent to Focus modes.
@MainActor
final class SRPostureNoteController {

	fileprivate let postureService: SRPostureAnalysisService

	fileprivate let panel: NSPanel
	fileprivate let label: NSTextField
	fileprivate var cancellables = Set<AnyCancellable>()

	/// Distance from the screen's top-right corner (below the menu bar).
	fileprivate static let cornerMargin: CGFloat = 12.0
	fileprivate static let horizontalPadding: CGFloat = 14.0
	fileprivate static let verticalPadding: CGFloat = 8.0

	init(services: AppServices) {
		self.postureService = services.posture

		let panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: true
		)
		panel.level = .statusBar
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		// The ghost properties from the notifications design: never steals
		// clicks or focus, never appears in screen captures or shares, and
		// follows the user to every Space, fullscreen included.
		panel.ignoresMouseEvents = true
		panel.sharingType = .none
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
		panel.alphaValue = 0.8

		// The dark HUD material keeps the note legible over light and dark
		// content alike; corners and shadow are the system's own.
		let background = NSVisualEffectView()
		background.material = .hudWindow
		background.state = .active
		background.blendingMode = .behindWindow
		background.wantsLayer = true
		background.layer?.cornerRadius = 10.0
		background.layer?.masksToBounds = true

		let label = NSTextField(labelWithString: "")
		label.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
		label.alignment = .center
		// One line per reported issue; the chip grows with the list.
		label.usesSingleLineMode = false
		label.maximumNumberOfLines = 0
		background.addSubview(label)

		panel.contentView = background

		self.panel = panel
		self.label = label

		// The note is one of the selectable nudge channels: while its
		// preference is off the status is treated as nothing-to-say.
		self.postureService.onPostureStatus
			.combineLatest(services.settings.postureNoteEnabled.publisher)
			.map { status, enabled in enabled ? status : nil }
			.removeDuplicates()
			.sink { [weak self] status in self?.apply(status) }
			.store(in: &self.cancellables)

		// Displays come and go and resolutions change; keep the note pinned
		// to the current main screen's corner.
		NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
			.sink { [weak self] _ in self?.reposition() }
			.store(in: &self.cancellables)
	}

	fileprivate func apply(_ status: SRPostureStatus?) {
		guard let status else {
			// No completed analysis window yet (camera still warming up).
			self.panel.orderOut(nil)
			return
		}

		let text: String
		let color: NSColor
		switch status {
		case .notVisible:
			text = NSLocalizedString("posture.note.not-visible", comment: "")
			color = .secondaryLabelColor
		case .evaluated(let issues) where issues.isEmpty:
			// Good posture needs no note: the message disappearing is the
			// reward. It returns when an issue is voiced again.
			self.panel.orderOut(nil)
			return
		case .evaluated(let issues):
			text = issues.map { Self.message(for: $0) }.joined(separator: "\n")
			color = .systemOrange
		}

		self.label.stringValue = text
		self.label.textColor = color
		self.label.sizeToFit()
		self.reposition()
		self.panel.orderFrontRegardless()
	}

	fileprivate static func message(for issue: SRPostureIssue) -> String {
		switch issue {
		case .slouching:
			return NSLocalizedString("posture.note.slouching", comment: "")
		case .leftShoulderHigh:
			return NSLocalizedString("posture.note.lower-left-shoulder", comment: "")
		case .rightShoulderHigh:
			return NSLocalizedString("posture.note.lower-right-shoulder", comment: "")
		}
	}

	/// Sizes the panel to the label and pins it to the top-right corner of
	/// the main screen, just below the menu bar.
	fileprivate func reposition() {
		guard let screen = NSScreen.main else { return }

		let labelSize = self.label.frame.size
		let panelSize = CGSize(
			width: labelSize.width + Self.horizontalPadding * 2.0,
			height: labelSize.height + Self.verticalPadding * 2.0
		)
		let origin = CGPoint(
			x: screen.visibleFrame.maxX - panelSize.width - Self.cornerMargin,
			y: screen.visibleFrame.maxY - panelSize.height - Self.cornerMargin
		)
		self.panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
		self.label.frame = NSRect(
			x: Self.horizontalPadding,
			y: Self.verticalPadding,
			width: labelSize.width,
			height: labelSize.height
		)
	}

}
