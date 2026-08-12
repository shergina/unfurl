//
//  SRPanelController.swift
//  Unfurl
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine

class SRPanelController: NSWindowController, NSWindowDelegate {

	fileprivate let services: AppServices
	weak var statusItemController: SRStatusItemController?

	let preferences: SRSettings

	var cancellables = Set<AnyCancellable>()

	let onMouseHoverStatusItem: AnyPublisher<Bool, Never>
	let onMouseHoverPanel = CurrentValueSubject<Bool, Never>(false)
	let onShouldShowPanel: AnyPublisher<Bool, Never>

	// Inits

	init(services: AppServices, statusItemController: SRStatusItemController) {
		self.services = services
		self.statusItemController = statusItemController
		self.onMouseHoverStatusItem = statusItemController.onMouseHover

		let preferences = services.settings
		self.preferences = preferences
		let mouseHoverPanel = self.onMouseHoverPanel

		let onMouseHoverStatusItemCombinedWithRelativePreference =
			self.onMouseHoverStatusItem
			.combineLatest(preferences.showCameraPanelOnHover.publisher)
			.map { (onHover, showOnHover) in onHover && showOnHover }

		let onMouseHover =
			onMouseHoverStatusItemCombinedWithRelativePreference
			.combineLatest(mouseHoverPanel)
			.map { $0 || $1 }
			.removeDuplicates()
			.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)

		// Show the panel when the camera is available OR when it has an error
		// to explain (denied/unavailable/failed) - otherwise a denied camera
		// would silently hide the panel and the user would never see why.
		let onHasContent =
			services.camera.onCaptureDeviceAvailable
			.combineLatest(services.camera.onState)
			.map { available, state in available || state != .idle }

		self.onShouldShowPanel =
			onMouseHover
			.combineLatest(preferences.cameraPanelPinned.publisher)
			.map { $0 || $1 }
			.combineLatest(onHasContent)
			.map { $0 && $1 }
			.removeDuplicates()
			.eraseToAnyPublisher()

		super.init(window: nil)

		self.onShouldShowPanel
			.sink { [unowned self] (show: Bool) in
				if show == self.isShown() { return }
				if show {
					self.showPanel()
				} else {
					self.hidePanel()
				}
			}
			.store(in: &self.cancellables)

		preferences.cameraPanelGhostMode.publisher
			.sink { [unowned self] _ in self.applyGhostMode() }
			.store(in: &self.cancellables)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// Panel (Window)
	fileprivate var panel: SRPanel {
		return self.window as! SRPanel
	}

	fileprivate func createPanel() {
		let panel = SRPanel()
		self.window = panel
		self.window!.delegate = self
	}
	
	fileprivate func destroyPanel() {
		self.window = nil
	}
	
	// View Controller
	fileprivate var viewController: SRPanelViewController {
		return self.panel.contentViewController as! SRPanelViewController
	}

	fileprivate func createViewController() {
		let viewController = SRPanelViewController();
		viewController.onMouseHover
			.sink { [weak self] in self?.onMouseHoverPanel.send($0) }
			.store(in: &self.cancellables)
		self.panel.contentViewController = viewController
	}

	fileprivate func destroyViewController() {
		self.panel.contentViewController = nil
		self.onMouseHoverPanel.send(false)
	}

	// 
	func isShown() -> Bool {
		return self.window != nil
	}

	// Show and Hide Panel
	func showPanel() {
		guard let anchor = self.statusItemController?.statusItemView else { return }
		self.showPanelAtView(anchor)
	}

	func showPanelAtView(_ view: NSView) {
		let size = self.preferences.cameraPanelSize.value
		// Read before creating: assigning the content view controller can
		// fire a transient frame save that would clobber the stored values.
		let panelFrame = self.restoredFrame(size: size) ?? self.anchoredFrame(under: view, size: size)

		self.createPanel()
		self.createViewController()

		self.panel.setFrame(panelFrame, display: true, animate: false)
		self.panel.orderFront(self)

		self.applyGhostMode()
	}

	/// The remembered position, re-anchored to the right display: the saved
	/// fraction of a screen's usable area, applied to the screen under the
	/// mouse for a hover summon (the panel appears where the user is
	/// looking) or to the screen the panel lived on for a pinned restore.
	/// nil while the panel has never been placed.
	fileprivate func restoredFrame(size: CGSize) -> CGRect? {
		var fraction: CGPoint
		var savedScreen: NSScreen?

		let savedScreenName = self.preferences.cameraPanelScreenName.value
		if !savedScreenName.isEmpty {
			fraction = self.preferences.cameraPanelRelativePosition.value
			savedScreen = NSScreen.screens.first { $0.localizedName == savedScreenName }
		} else {
			// Pre-fraction install: derive from the legacy absolute origin
			// (the screen containing it is the screen the panel lived on).
			// The first save rewrites everything in the new form. A legacy
			// origin on a screen no longer connected starts fresh.
			let legacy = self.preferences.cameraPanelPosition.value
			guard legacy != CGPoint.zero,
				let screen = NSScreen.screens.first(where: { NSMouseInRect(legacy, $0.frame, false) })
			else { return nil }
			fraction = Self.fraction(ofOrigin: legacy, size: size, on: screen)
			savedScreen = screen
		}

		let pinned = self.preferences.cameraPanelPinned.value
		let target = pinned
			? (savedScreen ?? self.screenUnderMouse() ?? NSScreen.main)
			: (self.screenUnderMouse() ?? savedScreen ?? NSScreen.main)
		guard let target else { return nil }

		return Self.frame(atFraction: fraction, size: size, on: target)
	}

	/// First-ever placement: centered under the status item, clamped into
	/// the item's screen. Used until the user moves or resizes the panel
	/// once; after that the stored fraction takes over.
	fileprivate func anchoredFrame(under view: NSView, size: CGSize) -> CGRect {
		let padding: CGFloat = 10
		let viewFrameRelativeToWindow = view.convert(view.bounds, to: nil)
		let viewFrameRelativeToScreen = view.window!.convertToScreen(viewFrameRelativeToWindow)
		let point = NSPoint(x: NSMidX(viewFrameRelativeToScreen), y: NSMinY(viewFrameRelativeToScreen))
		let screenFrame = view.window!.screen!.frame

		var position = CGPoint(
			x: ceil(point.x - size.width / 2.0),
			y: point.y - size.height - padding
		)
		// Clamp against the screen's edges (maxX/minX, not its width: a
		// secondary display's global origin is not zero).
		position.x = min(position.x, screenFrame.maxX - size.width - padding)
		position.x = max(position.x, screenFrame.minX + padding)

		return CGRect(origin: position, size: size)
	}

	fileprivate func screenUnderMouse() -> NSScreen? {
		let location = NSEvent.mouseLocation
		return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
	}

	/// Where an origin sits inside a screen's usable area: 0 is the
	/// left/bottom edge, 1 the right/top edge of the room the panel has to
	/// move on that screen. Screen-size independent, so one position means
	/// the same corner on every display.
	fileprivate static func fraction(ofOrigin origin: CGPoint, size: CGSize, on screen: NSScreen) -> CGPoint {
		let visible = screen.visibleFrame
		let roomX = visible.width - size.width
		let roomY = visible.height - size.height
		return CGPoint(
			x: roomX > 0 ? (origin.x - visible.minX) / roomX : 0,
			y: roomY > 0 ? (origin.y - visible.minY) / roomY : 0
		)
	}

	/// The inverse: a frame at the given fraction of a screen's usable
	/// area. The fraction is clamped to 0...1, so a restored panel is
	/// always fully on screen (a smaller display cannot strand it).
	fileprivate static func frame(atFraction fraction: CGPoint, size: CGSize, on screen: NSScreen) -> CGRect {
		let visible = screen.visibleFrame
		let roomX = max(visible.width - size.width, 0)
		let roomY = max(visible.height - size.height, 0)
		let clamped = CGPoint(x: min(max(fraction.x, 0), 1), y: min(max(fraction.y, 0), 1))
		return CGRect(
			x: visible.minX + clamped.x * roomX,
			y: visible.minY + clamped.y * roomY,
			width: size.width,
			height: size.height
		)
	}

	func hidePanel() {
		self.removeGhostMouseMonitors()
		self.ghostHovered = false
		self.close()
		self.destroyViewController()
		self.destroyPanel()
	}

	//: Ghost mode
	//
	// A ghosted panel is click-through and semi-transparent; when the cursor
	// passes over it, it fades to near-invisible so whatever is underneath
	// stays visible and clickable. Because the window ignores mouse events,
	// its tracking areas never fire — hover is detected with global/local
	// mouse-moved monitors instead.

	fileprivate var ghostMouseMonitors: [Any] = []
	fileprivate var ghostHovered = false

	fileprivate static let ghostIdleAlpha: CGFloat = 0.6
	fileprivate static let ghostHoverAlpha: CGFloat = 0.05

	fileprivate func applyGhostMode() {
		guard self.isShown() else { return }

		if self.preferences.cameraPanelGhostMode.value {
			self.panel.ignoresMouseEvents = true
			self.ghostHovered = NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)
			self.updateGhostAlpha(animated: true)
			self.installGhostMouseMonitors()
		} else {
			self.removeGhostMouseMonitors()
			self.ghostHovered = false
			self.panel.ignoresMouseEvents = false
			self.panel.animator().alphaValue = 1.0
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

	fileprivate func updateGhostHover() {
		guard self.isShown() else { return }

		let hovered = NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)
		if hovered != self.ghostHovered {
			self.ghostHovered = hovered
			self.updateGhostAlpha(animated: true)
		}
	}

	fileprivate func updateGhostAlpha(animated: Bool) {
		let alpha = self.ghostHovered ? Self.ghostHoverAlpha : Self.ghostIdleAlpha
		if animated {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.2
				self.panel.animator().alphaValue = alpha
			}
		} else {
			self.panel.alphaValue = alpha
		}
	}

	//: NSWindowDelegate

	func windowDidResize(_ notification: Notification) {
		self.storeWindowPosition()
	}

	func windowDidMove(_ notification: Notification) {
		self.storeWindowPosition()
	}

	func storeWindowPosition() {
		// No screen (window mid-transition or off-screen): keep the last
		// saved place rather than recording garbage.
		guard let window = self.window, let screen = window.screen else {
			return
		}

		self.preferences.cameraPanelSize.value = window.frame.size
		self.preferences.cameraPanelRelativePosition.value =
			Self.fraction(ofOrigin: window.frame.origin, size: window.frame.size, on: screen)
		self.preferences.cameraPanelScreenName.value = screen.localizedName
		// The legacy absolute origin has served its migration purpose.
		if self.preferences.cameraPanelPosition.value != CGPoint.zero {
			self.preferences.cameraPanelPosition.value = CGPoint.zero
		}
	}


	//:

	// Reached from the toolbar's close button via the responder chain (the
	// window controller is in the chain), so the toolbar needs no reference
	// to this controller.
	@objc func handleCloseButton() {
		self.preferences.cameraPanelPinned.value = false
		self.hidePanel()
	}
}
