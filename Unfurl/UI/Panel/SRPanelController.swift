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

	// Hover timing, deliberately asymmetric: summoning the panel needs a real
	// dwell, dismissing should feel prompt. The hide delay also bridges the gap
	// while the mouse travels from the item down to the panel - neither is
	// hovered in between.
	fileprivate static let hoverShowDelay = DispatchQueue.SchedulerTimeType.Stride.milliseconds(800)
	fileprivate static let hoverHideDelay = DispatchQueue.SchedulerTimeType.Stride.milliseconds(500)

	/// How long a pre-warmed preview is left live before it is quieted, so it
	/// has actually received frames rather than only being wired up.
	fileprivate static let prewarmSettleDelay = DispatchQueue.SchedulerTimeType.Stride.milliseconds(300)

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

		// The hover signal before any dwell is applied - the moment the mouse
		// arrives, not the moment we decide to show.
		let rawHover = onMouseHoverStatusItemCombinedWithRelativePreference
			.combineLatest(mouseHoverPanel)
			.map { $0 || $1 }
			.removeDuplicates()
			.eraseToAnyPublisher()

		let onMouseHover =
			rawHover
			// switchToLatest cancels the pending edge when the signal flips, so
			// a quick in-and-out never gets as far as showing the panel.
			.map { show in
				Just(show).delay(
					for: show ? SRPanelController.hoverShowDelay : SRPanelController.hoverHideDelay,
					scheduler: DispatchQueue.main
				)
			}
			.switchToLatest()
			.eraseToAnyPublisher()

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

		// Wake the preview when the mouse arrives, not when the panel appears.
		// A suspended layer redisplays its last frame and only then catches up,
		// so showing and resuming together opens the panel on a stale image
		// that visibly jumps forward - the user sees themselves a second or two
		// ago. Re-enabling costs no stream restart, so doing it at the start of
		// the dwell is free, and by the time the panel is ordered front the
		// frames are live.
		//
		// Only for a panel that already exists: building one here would attach
		// on a hover that may never become a summon, and that attach can
		// restart the stream under the status item. Nothing is lost - the show
		// path builds it, and the launch pre-warm means it usually exists.
		rawHover
			.sink { [weak self] hovering in
				guard let self, self.window != nil, !self.isShown() else { return }

				// Only while the camera is already running. Resuming takes a
				// claim, and a claim on an idle session starts the camera - so
				// warming on a hover that never becomes a summon would flash
				// the privacy light for a panel the user never opened. With the
				// session idle there is nothing to warm anyway: the stale frame
				// this avoids only exists because the layer was live before.
				guard self.services.camera.onState.value.isRunning else { return }

				if hovering {
					self.viewController.resumeCamera()
				} else {
					self.viewController.suspendCamera()
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

	/// Built once and kept for the process lifetime. Tearing the panel down on
	/// every hide deallocated the camera view, and its deinit detaches the
	/// preview layer from the running session - a graph mutation that stalls
	/// frame delivery to every consumer for ~300 ms (the toggle blink; see
	/// Tools/spec.md). That is the blink on the menu-bar item and the Dock tile
	/// on each hover in and out. Hiding suspends the preview instead, the same
	/// trade the status item already makes for its own camera view.
	fileprivate func createPanelIfNeeded() {
		guard self.window == nil else { return }

		let panel = SRPanel()
		// We order it out rather than close it, and we keep the reference, so
		// AppKit must not release it out from under us.
		panel.isReleasedWhenClosed = false
		self.window = panel

		// Content first, delegate second, and the order is load-bearing.
		// Assigning a content view controller makes AppKit size the window to
		// the content's fitting size - 90x60, the panel's minSize - which fires
		// windowDidResize. As delegate we would record that as the user's
		// remembered panel size, and every later summon would restore a 90x60
		// panel. This used to be masked: the setFrame right after fired its own
		// save that overwrote the garbage, until suppressing programmatic saves
		// removed the overwrite and left the transient behind.
		self.createViewController()

		self.window!.delegate = self
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

	// 
	/// On screen, not merely constructed - the panel outlives its visibility now.
	func isShown() -> Bool {
		return self.window?.isVisible ?? false
	}

	/// Build the panel and attach its preview early, then quiet it, so the
	/// first summon resumes a suspended preview instead of attaching to a
	/// running session and restarting the stream for every other surface.
	///
	/// Fires on whichever of two moments comes first, then never again.
	func createPanelOnFirstCameraUse() {
		// A visible camera surface is switched on. That is the moment to
		// attach, not a moment later: the preference change lands us in the
		// same cold start-coalescing window as the status item's own attach,
		// so nothing restarts.
		//
		// This has to stay an event rather than a one-time check. Read once at
		// launch it was wrong: the user can enable the menu-bar camera at any
		// point afterwards, and the running-session branch below would then
		// fire and attach to a live stream - blinking the very surface this
		// branch exists to protect. The preference replays its current value,
		// so an already-enabled surface still fires immediately at launch.
		let visibleSurfaceEnabled = self.preferences.showCameraOnStatusBar.publisher
			.combineLatest(self.preferences.showCameraOnDockTile.publisher)
			.filter { $0 || $1 }
			.map { _ in () }
			.eraseToAnyPublisher()

		// Nothing visible, but something else (posture tracking) is running the
		// camera anyway. Attaching now does restart the stream, but with no
		// preview on screen there is nothing for the restart to blink, and it
		// buys the same free first summon. Deliberately not a preference check:
		// posture's gate is tracking-on AND past any snooze, it lives in the
		// composition root, and restating it here would drift. A running
		// session is that gate's observable consequence.
		//
		// If the camera never runs and no surface is ever enabled, neither
		// fires: nothing attaches, the privacy light stays off, and the first
		// hover pays a cold start.
		let sessionRunning = self.services.camera.onState
			.filter { $0.isRunning }
			.map { _ in () }
			.eraseToAnyPublisher()

		visibleSurfaceEnabled
			.merge(with: sessionRunning)
			.first()
			.sink { [weak self] _ in self?.buildPanelAndReleaseWhenSettled() }
			.store(in: &self.cancellables)
	}

	/// Builds the panel - which attaches its preview - and hands the session
	/// claim back once the session has settled, leaving the preview wired but
	/// quiet. Never attaches speculatively: the caller has already established
	/// that something else is holding, or is about to hold, the camera.
	fileprivate func buildPanelAndReleaseWhenSettled() {
		self.createPanelIfNeeded()

		// Any non-idle state will do. A denied or failed camera has nothing to
		// keep warm either, and letting go then is what lets the session be
		// torn down.
		//
		// The delay is the point, not politeness. Disabling the connection the
		// instant the stream starts leaves a layer that has never been handed a
		// frame, and it has nothing to draw when resumed - the panel opens grey
		// and waits for the next frame. Measured 2026-08-27: attaching cold and
		// releasing on the same millisecond as `.running` opened grey, while
		// attaching to an already-running session and releasing 59 ms later
		// opened instantly, because the layer had caught a frame and kept it.
		// So hold the preview live long enough to receive some. The claim is
		// held that much longer, which costs no camera runtime - something else
		// is holding the session, or we would not have attached at all.
		self.services.camera.onState
			.filter { $0 != .idle }
			.first()
			.delay(for: Self.prewarmSettleDelay, scheduler: DispatchQueue.main)
			.sink { [weak self] _ in
				// The user may have summoned it in the meantime; suspending a
				// panel that is on screen would blank the feed they asked for.
				guard let self, !self.isShown() else { return }
				self.viewController.suspendCamera()
			}
			.store(in: &self.cancellables)
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

		self.createPanelIfNeeded()

		self.setFrameWithoutStoring(panelFrame)
		self.panel.orderFront(self)
		// After orderFront: the resume re-runs layout, which needs the real
		// bounds and the real window backing scale to restore the preview.
		self.viewController.resumeCamera()

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

		guard self.window != nil else { return }

		self.panel.orderOut(self)
		self.viewController.suspendCamera()

		// Destroying the view controller used to reset this. A hidden window's
		// tracking area cannot report the mouse leaving, so without clearing it
		// here the latch stays true, `onShouldShowPanel` stays true, and the
		// panel never hides again.
		self.onMouseHoverPanel.send(false)
	}

	/// Repositioning is ours, not the user's, so it must not be written back as
	/// a remembered position. The window is kept now, so a programmatic
	/// setFrame on a panel that already has a screen would otherwise look
	/// exactly like a drag.
	fileprivate func setFrameWithoutStoring(_ frame: CGRect) {
		self.isPositioningProgrammatically = true
		defer { self.isPositioningProgrammatically = false }
		self.panel.setFrame(frame, display: true, animate: false)
	}

	//: Ghost mode
	//
	// A ghosted panel is click-through and semi-transparent; when the cursor
	// passes over it, it fades to near-invisible so whatever is underneath
	// stays visible and clickable. Because the window ignores mouse events,
	// its tracking areas never fire — hover is detected with global/local
	// mouse-moved monitors instead.

	fileprivate var isPositioningProgrammatically = false

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
		// Our own repositioning on summon is not a user placement.
		guard !self.isPositioningProgrammatically else { return }

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
