
//
//  SRStatusItemView.swift
//  Narcissism
//
//  Created by Maria Shergina on 22/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import ApplicationServices
import Combine


@MainActor
protocol SRStatusItemViewDelegate: AnyObject {
	func statusItemView(_ view: NSView, clickGestureRecognized event: NSGestureRecognizer)
}


class SRStatusItemView: NSView, NSGestureRecognizerDelegate {

	weak var delegate: SRStatusItemViewDelegate!
	weak var statusItem: NSStatusItem!

	fileprivate var contentView: SRStatusItemContentView!
	fileprivate let preferences = SRSettings.sharedInstance
	fileprivate let cursor = NSCursor.resizeLeftRight
	fileprivate var cancellables = Set<AnyCancellable>()

	// The camera width is session-only (starts at the default each launch, never
	// persisted). It is not clamped at launch; instead, over-widening is bounded
	// only while dragging (see `maximumCameraWidth`, used by the pan handler), so
	// the preview layer is never resized post-creation from here.
	fileprivate var cameraAvailable = false
	fileprivate var showCamera = false

	// The maximum draggable camera width scales with the usable display width:
	//   maxWidth = (screen width - notch width) / maxCameraWidthScreenDivisor
	// A larger divisor yields a smaller cap. Notch width is 0 on non-notched
	// displays, so the same formula covers both. Clamped to the absolute range.
	private static let maxCameraWidthScreenDivisor: CGFloat = 20.0

	private static let diagnosticLoggingEnabled = true

	override init(frame: NSRect) {
		self.lighted = false

		super.init(frame: frame)

		let clickGestureRecognizer = NSClickGestureRecognizer(target: self, action: #selector(SRStatusItemView.handleClickGesture(_:)))
		clickGestureRecognizer.delegate = self
		self.addGestureRecognizer(clickGestureRecognizer)

		// Right click opens the same menu as a left click, whatever content
		// (icon or camera) is showing.
		let rightClickGestureRecognizer = NSClickGestureRecognizer(target: self, action: #selector(SRStatusItemView.handleClickGesture(_:)))
		rightClickGestureRecognizer.buttonMask = 0x2
		rightClickGestureRecognizer.delegate = self
		self.addGestureRecognizer(rightClickGestureRecognizer)

		self.setContentView(self.createContentViewWithClass(SRStatusItemIconUnavailableView.self), animated: false)

		SRCameraService.sharedInstance.onCaptureDeviceAvailable
			.combineLatest(self.preferences.showCameraOnStatusBar.publisher)
			.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
			.sink { [unowned self] (cameraAvailable, showCameraOnStatusBar) in
				self.cameraAvailable = cameraAvailable
				self.showCamera = showCameraOnStatusBar
				self.refreshContent(animated: true)
			}
			.store(in: &self.cancellables)

		self.needsLayout = true
	}

	required init?(coder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}

	var lighted: Bool {
		didSet {
			self.contentView.lighted = self.lighted
			self.needsDisplay = true
		}
	}

	/// The posture tint channel (best-effort ambient state); forwarded to
	/// the current content view and re-applied on every content swap.
	var postureAlert = false {
		didSet {
			self.contentView.postureAlert = self.postureAlert
		}
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		return true
	}

	//:

	@objc func handleClickGesture(_ gestureRecognizer: NSGestureRecognizer) {
		self.delegate?.statusItemView(self, clickGestureRecognized: gestureRecognizer)
	}

	fileprivate func setContentView(_ contentView: SRStatusItemContentView, animated: Bool) {
		let oldContentView = self.contentView
		let newContentView = contentView

		self.contentView = contentView
		newContentView.postureAlert = self.postureAlert

		// Fill self via autoresizing; the item's overall width is controlled by
		// `statusItem.length`, not by manipulating frames (which fights the
		// Auto Layout constraints pinning this view inside statusItem.button).
		newContentView.frame = self.bounds
		newContentView.autoresizingMask = [.width, .height]

		oldContentView?.alphaValue = 1.0
		newContentView.alphaValue = 0.0

		self.addSubview(newContentView)

		self.updateStatusItemLength(newContentView.intrinsicContentSize.width)

		NSAnimationContext.runAnimationGroup({ (context: NSAnimationContext) in
			context.duration = animated ? 0.25 : 0.0
			oldContentView?.animator().alphaValue = 0.0
			newContentView.animator().alphaValue = 1.0
		}, completionHandler: {
			// runAnimationGroup calls back on the main thread; the SDK just
			// doesn't annotate the completion handler as such.
			MainActor.assumeIsolated {
				oldContentView?.removeFromSuperview()
			}
		})
	}

	/// Drives the width of the status item. The custom view is hosted inside
	/// `statusItem.button` under Auto Layout, so width must flow through
	/// `NSStatusItem.length` rather than direct frame changes.
	func updateStatusItemLength(_ width: CGFloat) {
		guard width > 0 else { return }
		self.statusItem?.length = width
	}

    fileprivate func createContentViewWithClass(_ Class: NSView.Type) -> SRStatusItemContentView {
		let view = Class.init(frame: self.bounds) as! SRStatusItemContentView
		view.autoresizingMask = [.width, .height]
		return view
	}

	/// Selects the content class from `showCamera` and `cameraAvailable` and swaps
	/// to it only when it actually changes, so the live camera view is not
	/// needlessly torn down and rebuilt. Width is not touched here - the camera
	/// keeps its birth width (see the note in the body).
	fileprivate func refreshContent(animated: Bool) {
		self.logGeometry("refresh")
		self.logFitStateIfNeeded()

		// Content is chosen by availability only. The camera view is created once
		// at its (session-only) default width and never resized post-creation from
		// here - re-setting the width after the preview layer attaches is what
		// blanked it. Over-widening is prevented at drag time instead.
		let Class: SRStatusItemContentView.Type
		if self.showCamera {
			Class = self.cameraAvailable ? SRStatusItemCameraView.self : SRStatusItemIconUnavailableView.self
		} else {
			Class = SRStatusItemIconView.self
		}

		if let current = self.contentView, type(of: current) == Class { return }
		self.setContentView(self.createContentViewWithClass(Class), animated: animated)
	}


	/// The largest width the camera may be dragged to, scaled to the usable
	/// display: `(screen width - notch width) / maxCameraWidthScreenDivisor`,
	/// clamped to the absolute allowed range. Notch width is 0 on displays
	/// without a notch, so the same formula covers notched and non-notched alike.
	func maximumCameraWidth() -> CGFloat {
		let range = SRSettings.allowedStatusItemCameraWidthRange

		guard let screen = self.window?.screen else {
			return SRSettings.defaultStatusItemCameraWidth
		}

		let notchWidth: CGFloat
		if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
			// The gap between the two usable menu-bar areas is the notch.
			notchWidth = max(0, right.minX - left.maxX)
		} else {
			notchWidth = 0
		}

		let usableWidth = screen.frame.width - notchWidth
		let maxWidth = usableWidth / SRStatusItemView.maxCameraWidthScreenDivisor
		return min(range.upperBound, max(range.lowerBound, maxWidth))
	}

	/// Logs the geometry inputs behind `maximumCameraWidth` at decision points
	/// (content refresh, drag end). TEMPORARY, alongside the hidden-state probe.
	func logGeometry(_ context: String) {
		guard SRStatusItemView.diagnosticLoggingEnabled else { return }
		let notch = self.window?.screen?.auxiliaryTopRightArea?.minX
		let rightEdge = self.window?.frame.maxX
		NSLog("NARC-GEO[\(context)]: notchRightEdge=\(notch.map { String(Int($0)) } ?? "nil") ourRightEdge=\(rightEdge.map { String(Int($0)) } ?? "nil") maxWidth=\(Int(self.maximumCameraWidth())) default=\(Int(SRSettings.defaultStatusItemCameraWidth))")
	}

	/// TEMPORARY. Logs every candidate hidden-state signal so we can identify
	/// which one macOS actually toggles when the item disappears. View with:
	///   log stream --predicate 'eventMessage CONTAINS "NARC-FIT"'
	/// or run the app from a terminal and watch stderr. Delete once resolved.
	fileprivate func logFitStateIfNeeded() {
		guard SRStatusItemView.diagnosticLoggingEnabled else { return }
		let statusItem = self.statusItem
		let button = statusItem?.button
		let window = button?.window
		let frame = window?.frame ?? .zero
		let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
		let cameraWidth = (self.contentView as? SRStatusItemCameraView)?.width ?? -1
		NSLog("NARC-FIT: cameraState=\(String(describing: SRCameraService.sharedInstance.onState.value)) available=\(self.cameraAvailable) show=\(self.showCamera) statusItem.isVisible=\(statusItem?.isVisible ?? false) window=\(window != nil) window.isVisible=\(window?.isVisible ?? false) occlusionVisible=\(window?.occlusionState.contains(.visible) ?? false) frame=\(NSStringFromRect(frame)) onScreen=\(onScreen) content=\(self.contentView.map { String(describing: type(of: $0)) } ?? "nil") width=\(Int(cameraWidth))")
	}

	override func viewWillMove(toWindow newWindow: NSWindow?) {
		self.window?.invalidateCursorRects(for: self)
	}

	override func resetCursorRects() {
		super.resetCursorRects()
	}

}
