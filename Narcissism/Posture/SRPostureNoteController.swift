//
//  SRPostureNoteController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The corner posture note: a ghost panel pinned to the top-right corner of
/// the main screen, visible only while there is something to say - the
/// debounced corrections to make, or "can't see you clearly". Good posture
/// shows nothing: the note disappearing is the reward. Prototype of the
/// ghost-toast notification design (see spec.md): click-through,
/// semi-transparent, excluded from screen capture so shared screens and
/// recordings never show it, on every Space including fullscreen, and
/// deliberately indifferent to Focus modes. Visually it borrows the system
/// notification banner's anatomy: leading symbol, title, secondary lines,
/// adaptive material.
@MainActor
final class SRPostureNoteController {

	fileprivate let postureService: SRPostureAnalysisService
	fileprivate let cameraService: CameraProviding

	fileprivate let panel: NSPanel
	fileprivate let background: NSVisualEffectView
	fileprivate let iconView: NSImageView
	fileprivate let label: NSTextField
	fileprivate var cancellables = Set<AnyCancellable>()

	/// Whether the note should currently be on screen; the fade-out
	/// completion checks it so a show racing a hide never orders out.
	fileprivate var wantsVisible = false

	/// The last text spoken to VoiceOver, nil while the note is hidden.
	fileprivate var announcedText: String?

	// Ghost mode (PostureNoteGhost): while on, the visible note fades to
	// almost nothing under the pointer and back when it leaves. The note
	// is click-through, so ordinary tracking areas never fire; hover is
	// watched with mouse-moved monitors, the panel ghost mode's approach,
	// installed only while the note is showing.
	fileprivate var ghostEnabled = false
	fileprivate var ghostHovered = false
	fileprivate var ghostMouseMonitors: [Any] = []

	/// Distance from the screen's top-right corner (below the menu bar).
	fileprivate static let cornerMargin: CGFloat = 12.0
	/// The note's resting translucency: present but ghostly.
	fileprivate static let ghostAlpha: CGFloat = 0.85
	/// Ghost mode's hovered translucency: barely there.
	fileprivate static let ghostHoverAlpha: CGFloat = 0.05
	fileprivate static let fadeDuration: TimeInterval = 0.25
	fileprivate static let hoverFadeDuration: TimeInterval = 0.2
	/// Generous floor so the note reads as a banner, not a chip.
	fileprivate static let minimumSize = CGSize(width: 280.0, height: 58.0)

	init(services: AppServices) {
		self.postureService = services.posture
		self.cameraService = services.camera

		let panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: 280, height: 58),
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
		panel.alphaValue = 0.0

		// Adaptive material, like the system's own banners; corners and
		// shadow are the system's own.
		let background = NSVisualEffectView()
		background.material = .popover
		background.state = .active
		background.blendingMode = .behindWindow
		background.maskImage = Self.makeMaskImage(cornerRadius: 16.0)

		let iconView = NSImageView()
		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24.0, weight: .medium)
		background.addSubview(iconView)

		// One line per issue, all the same weight: the corrections are
		// peers, not a title and a detail.
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
		label.textColor = .labelColor
		label.usesSingleLineMode = false
		label.maximumNumberOfLines = 0
		background.addSubview(label)

		NSLayoutConstraint.activate([
			background.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.width),
			background.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.height),
			// A fixed icon slot keeps the text aligned across symbol changes.
			iconView.widthAnchor.constraint(equalToConstant: 32.0),
			iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14.0),
			iconView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
			label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10.0),
			label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16.0),
			label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
			label.topAnchor.constraint(greaterThanOrEqualTo: background.topAnchor, constant: 12.0),
		])

		panel.contentView = background

		self.panel = panel
		self.background = background
		self.iconView = iconView
		self.label = label

		// The note is one of the selectable nudge channels: while its
		// preference is off the status is treated as nothing-to-say.
		self.postureService.onPostureStatus
			.combineLatest(services.settings.postureNoteEnabled.publisher)
			.map { status, enabled in enabled ? status : nil }
			.removeDuplicates()
			.sink { [weak self] status in self?.apply(status) }
			.store(in: &self.cancellables)

		services.settings.postureNoteGhost.publisher
			.sink { [weak self] enabled in self?.applyGhostEnabled(enabled) }
			.store(in: &self.cancellables)

		// Displays come and go and resolutions change; keep the note pinned
		// to the right corner.
		NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
			.sink { [weak self] _ in self?.reposition() }
			.store(in: &self.cancellables)

		// Switching cameras moves which screen the user is facing, so the
		// note follows. Only the builtin/external answer matters here.
		services.camera.onSelectedDeviceID
			.combineLatest(services.camera.onDevices)
			.map { id, devices in devices.first { $0.id == id }?.isExternal ?? false }
			.removeDuplicates()
			.sink { [weak self] _ in self?.reposition() }
			.store(in: &self.cancellables)
	}

	fileprivate func apply(_ status: SRPostureStatus?) {
		guard let status else {
			// No completed analysis window yet (camera still warming up).
			self.setVisible(false)
			return
		}

		switch status {
		case .notVisible:
			self.label.stringValue = NSLocalizedString("posture.note.not-visible", comment: "")
			self.setIcon("eye.trianglebadge.exclamationmark", color: .secondaryLabelColor)
		case .evaluated(let issues) where issues.isEmpty:
			// Good posture needs no note: the message disappearing is the
			// reward. It returns when an issue is voiced again.
			self.setVisible(false)
			return
		case .evaluated(let issues):
			self.label.stringValue = issues.map { Self.message(for: $0) }.joined(separator: "\n")
			self.setIcon("figure.seated.side", color: .systemOrange)
		}

		self.reposition()
		self.setVisible(true)
		self.announce(self.label.stringValue)
	}

	/// Speaks the note for VoiceOver users: the note itself is a
	/// click-through panel VoiceOver cannot reach, so each new message is
	/// posted as an announcement. Keyed on the text, so the per-tick
	/// re-evaluation does not re-announce an unchanged note; the key
	/// clears on hide, so a note that returns speaks again.
	fileprivate func announce(_ text: String) {
		guard text != self.announcedText else { return }
		self.announcedText = text
		NSAccessibility.post(
			element: NSApp as Any,
			notification: .announcementRequested,
			userInfo: [
				.announcement: text,
				.priority: NSAccessibilityPriorityLevel.medium.rawValue,
			]
		)
	}

	fileprivate func setIcon(_ symbolName: String, color: NSColor) {
		self.iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
		self.iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24.0, weight: .medium)
			.applying(.init(hierarchicalColor: color))
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

	/// Fades the note in or out; a text-only change while visible skips the
	/// animation. Honors Reduce Motion by switching instantly.
	fileprivate func setVisible(_ visible: Bool) {
		guard visible != self.wantsVisible else { return }
		self.wantsVisible = visible

		if visible {
			self.ghostHovered = self.ghostEnabled && self.isMouseOverNote()
			if self.ghostEnabled {
				self.installGhostMouseMonitors()
			}
		} else {
			self.removeGhostMouseMonitors()
			self.ghostHovered = false
			self.announcedText = nil
		}

		let target = visible ? self.restingAlpha() : 0.0
		if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
			self.panel.alphaValue = target
			if visible {
				self.panel.orderFrontRegardless()
			} else {
				self.panel.orderOut(nil)
			}
			return
		}

		if visible {
			self.panel.orderFrontRegardless()
		}
		NSAnimationContext.runAnimationGroup({ context in
			context.duration = Self.fadeDuration
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			self.panel.animator().alphaValue = target
		}, completionHandler: { [weak self] in
			// AppKit calls the completion on the main thread.
			MainActor.assumeIsolated {
				guard let self, !self.wantsVisible else { return }
				self.panel.orderOut(nil)
			}
		})
	}

	// MARK: Ghost mode

	fileprivate func applyGhostEnabled(_ enabled: Bool) {
		guard enabled != self.ghostEnabled else { return }
		self.ghostEnabled = enabled

		// While hidden there is nothing to fade and no monitors installed;
		// the next show picks the new setting up.
		guard self.wantsVisible else { return }
		if enabled {
			self.ghostHovered = self.isMouseOverNote()
			self.installGhostMouseMonitors()
		} else {
			self.removeGhostMouseMonitors()
			self.ghostHovered = false
		}
		self.fadeToRestingAlpha()
	}

	fileprivate func updateGhostHover() {
		guard self.wantsVisible else { return }

		let hovered = self.isMouseOverNote()
		if hovered != self.ghostHovered {
			self.ghostHovered = hovered
			self.fadeToRestingAlpha()
		}
	}

	fileprivate func isMouseOverNote() -> Bool {
		NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)
	}

	/// The visible note's alpha: barely there while hovered in ghost mode.
	fileprivate func restingAlpha() -> CGFloat {
		self.ghostHovered ? Self.ghostHoverAlpha : Self.ghostAlpha
	}

	fileprivate func fadeToRestingAlpha() {
		if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
			self.panel.alphaValue = self.restingAlpha()
			return
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = Self.hoverFadeDuration
			self.panel.animator().alphaValue = self.restingAlpha()
		}
	}

	fileprivate func installGhostMouseMonitors() {
		guard self.ghostMouseMonitors.isEmpty else { return }

		if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
			self?.updateGhostHover()
		}) {
			self.ghostMouseMonitors.append(global)
		}

		if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
			self?.updateGhostHover()
			return event
		}) {
			self.ghostMouseMonitors.append(local)
		}
	}

	fileprivate func removeGhostMouseMonitors() {
		for monitor in self.ghostMouseMonitors {
			NSEvent.removeMonitor(monitor)
		}
		self.ghostMouseMonitors.removeAll()
	}

	/// Sizes the panel to its content (clamped to the banner minimum) and
	/// pins it to the top-right corner, just below the menu bar, of the
	/// screen the tracking camera looks out of. NSScreen.main would put it
	/// on the primary display, which is neither where the user is nor
	/// where the camera is.
	fileprivate func reposition() {
		let deviceID = self.cameraService.onSelectedDeviceID.value
		let isExternal = self.cameraService.onDevices.value.first { $0.id == deviceID }?.isExternal ?? false
		guard let screen = NSScreen.forCamera(isExternal: isExternal) else { return }

		self.background.layoutSubtreeIfNeeded()
		let size = self.background.fittingSize
		let origin = CGPoint(
			x: screen.visibleFrame.maxX - size.width - Self.cornerMargin,
			y: screen.visibleFrame.maxY - size.height - Self.cornerMargin
		)
		self.panel.setFrame(NSRect(origin: origin, size: size), display: true)
	}

	/// A stretchable rounded-rect mask for the visual effect view. Only
	/// maskImage reaches the behind-window material in the window server;
	/// a layer mask clips just our drawing and leaves opaque corners.
	fileprivate static func makeMaskImage(cornerRadius: CGFloat) -> NSImage {
		let edge = cornerRadius * 2.0 + 1.0
		let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
			NSColor.black.setFill()
			NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
			return true
		}
		image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
		image.resizingMode = .stretch
		return image
	}

}
