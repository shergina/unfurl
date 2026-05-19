//
//  SRPanelContentView.swift
//  Narcissism
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// Which resizable edge (or corner) of the panel the mouse is over, and the
/// cursor that hints it. The panel is already `.resizable`, so the system does
/// the actual resize when the frame border is dragged; this only supplies the
/// cursor hint, which a non-activating background agent must set itself.
private enum SRPanelResizeEdge {
	case none
	case left, right, top, bottom
	case topLeft, topRight, bottomLeft, bottomRight

	var cursor: NSCursor {
		switch self {
		case .none:
			return .arrow
		case .left, .right:
			return .resizeLeftRight
		case .top, .bottom:
			return .resizeUpDown
		case .topLeft, .bottomRight:
			return SRPanelResizeEdge.diagonalCursor("_windowResizeNorthWestSouthEastCursor")
		case .topRight, .bottomLeft:
			return SRPanelResizeEdge.diagonalCursor("_windowResizeNorthEastSouthWestCursor")
		}
	}

	/// The diagonal resize cursors are not public; ask `NSCursor` for the
	/// private one by name and fall back to the arrow if it ever goes away.
	private static func diagonalCursor(_ name: String) -> NSCursor {
		let selector = NSSelectorFromString(name)
		if NSCursor.responds(to: selector),
		   let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
			return cursor
		}
		return .arrow
	}
}


class SRPanelContentView: NSView {

	override class var requiresConstraintBasedLayout: Bool {
		return true
	}

	/// How close to an edge (in points) counts as "on the resize border".
	fileprivate let resizeEdgeThickness: CGFloat = 6.0

	fileprivate var cancellables = Set<AnyCancellable>()

	fileprivate var cameraView: SRCameraView
	fileprivate var toolbarView: SRPanelToolbarView
	fileprivate var cameraPlaceholderView: SRCameraPlaceholerView

	override init(frame rect: NSRect) {
		// TEMPORARY (posture accuracy test): the debug subclass overlays
		// dots at the joints the posture probe reports. Revert to
		// SRCameraView() when the test is done.
		self.cameraView = SRPostureDebugCameraView()
		self.toolbarView = SRPanelToolbarView()
		self.toolbarView.setCompactMode(true, animated: false)
		self.cameraPlaceholderView = SRCameraPlaceholerView()


		super.init(frame: rect)
		self.wantsLayer = true

		#if USE_UNDOCUMENTED_API
		// Without this a background agent's cursor changes are ignored, so the
		// resize hint below would never appear over our own non-key panel.
		enableCursorChangesForBackgroundApp()
		#endif

		self.addSubview(self.cameraPlaceholderView)
		self.addSubview(self.cameraView)
		self.addSubview(self.toolbarView)

		// The control chip only makes sense over a live feed: reveal it on
		// hover, but only while the camera is actually running. In the
		// placeholder states (denied / unavailable / failed) it stays hidden,
		// since its buttons - photo, mirror, pin, ghost - have nothing to act
		// on. The panel is then managed from the status-bar menu.
		self.mouseHoverPublisher()
			.debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
			.combineLatest(SRCameraService.sharedInstance.onState)
			.sink { [unowned self] (hovering, state) in
				self.toolbarView.setCompactMode(!(hovering && state.isRunning), animated: true)
			}
			.store(in: &self.cancellables)

		// Resize-cursor hinting area. `.inVisibleRect` makes AppKit keep this
		// matched to the view's size automatically, so - like the hover area
		// installed by `mouseHoverPublisher()` above - it is created once and
		// never needs rebuilding on resize. We deliberately do not override
		// `updateTrackingAreas()`: the usual "remove all, re-add" recipe there
		// would also tear down the hover area (we do not own it), which is what
		// kept the control chip from ever appearing.
		self.addTrackingArea(NSTrackingArea(
			rect: .zero,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self,
			userInfo: nil
		))

		// The camera view sits above the placeholder; hide it when there's no
		// feed so it stops covering the placeholder's message and swallowing
		// clicks meant for its "Open System Settings" button.
		SRCameraService.sharedInstance.onState
			.sink { [unowned self] state in
				self.cameraView.isHidden = !state.isRunning
			}
			.store(in: &self.cancellables)
	}

	required init?(coder: NSCoder) {
		fatalError("NSCoding not supported")
	}

	override func updateConstraints() {
		self.cameraView.translatesAutoresizingMaskIntoConstraints = false
		self.cameraPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
		self.toolbarView.translatesAutoresizingMaskIntoConstraints = false

		NSLayoutConstraint.activate([
			self.cameraView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
			self.cameraView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
			self.cameraView.topAnchor.constraint(equalTo: self.topAnchor),
			self.cameraView.bottomAnchor.constraint(equalTo: self.bottomAnchor),

			self.cameraPlaceholderView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
			self.cameraPlaceholderView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
			self.cameraPlaceholderView.topAnchor.constraint(equalTo: self.topAnchor),
			self.cameraPlaceholderView.bottomAnchor.constraint(equalTo: self.bottomAnchor),

			// Floating control chip, centered near the bottom edge.
			self.toolbarView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
			self.toolbarView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12.0),
		])

		super.updateConstraints()
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		return true
	}

	// Resize-cursor hinting.
	//
	// The content view fills the panel (fullSizeContentView), so its outermost
	// points overlap the window's resize border. The tracking area installed in
	// init reports movement across the whole view; near an edge we set the
	// matching resize cursor. `.set()` on every move is deliberate: any event
	// can reset the cursor, and continuously asserting it is the robust way to
	// keep the hint stable for a background, non-key window. The system still
	// performs the actual resize.

	fileprivate func resizeEdge(at point: CGPoint) -> SRPanelResizeEdge {
		let thickness = self.resizeEdgeThickness
		let nearLeft = point.x <= thickness
		let nearRight = point.x >= self.bounds.width - thickness
		let nearBottom = point.y <= thickness
		let nearTop = point.y >= self.bounds.height - thickness

		switch (nearLeft, nearRight, nearTop, nearBottom) {
		case (true, _, true, _): return .topLeft
		case (_, true, true, _): return .topRight
		case (true, _, _, true): return .bottomLeft
		case (_, true, _, true): return .bottomRight
		case (true, _, _, _): return .left
		case (_, true, _, _): return .right
		case (_, _, true, _): return .top
		case (_, _, _, true): return .bottom
		default: return .none
		}
	}

	override func mouseMoved(with event: NSEvent) {
		super.mouseMoved(with: event)
		let point = self.convert(event.locationInWindow, from: nil)
		self.resizeEdge(at: point).cursor.set()
	}

	override func mouseExited(with event: NSEvent) {
		super.mouseExited(with: event)
		NSCursor.arrow.set()
	}

}
