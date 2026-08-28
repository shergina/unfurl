
//
//  SRStatusItemView.swift
//  Unfurl
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
	fileprivate var cancellables = Set<AnyCancellable>()

	// The one camera content view, created on first show and reused across
	// every later swap. Recreating it would detach/reattach its preview layer
	// on the running session - the ~300 ms all-preview stall (the toggle
	// blink; see Tools/spec.md). Swapping away suspends the preview instead;
	// swapping back resumes it. Side effect: a drag-resized width now
	// survives Show Camera toggles within the session (still never persisted).
	fileprivate var cameraContentView: SRStatusItemCameraView?

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
			.combineLatest(
				self.preferences.showCameraOnStatusBar.publisher,
				SRCameraService.sharedInstance.onState
			)
			// Short on purpose. This is the app's one always-visible surface, and
			// it was the last thing to attach at launch: half a second of
			// settling here put the preview outside the session's start window,
			// so it landed on a running stream and restarted it. Still long
			// enough to swallow a burst of publisher updates, which is all the
			// debounce was ever for.
			.debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
			.sink { [unowned self] (cameraAvailable, showCameraOnStatusBar, state) in
				// A device that exists but cannot deliver frames is not a
				// camera to show: denied access left the live view up as a
				// blank strip in the menu bar (2026-08-14). Unauthorized and
				// failed swap to the unavailable icon like a missing device.
				let deliverable: Bool
				switch state {
				case .unauthorized, .failed:
					deliverable = false
				case .idle, .unavailable, .running:
					deliverable = true
				}
				self.cameraAvailable = cameraAvailable && deliverable
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
		// The camera view is created once at its (session-only) default width
		// and never resized post-creation from here - re-setting the width
		// after the preview layer attaches is what blanked it. Over-widening
		// is prevented at drag time instead.
		//
		// The X icon wears every mode (2026-08-14): a camera app whose camera
		// cannot run is broken with the preview hidden too, and this item is
		// the one always-visible surface that can say so.
		let Class: SRStatusItemContentView.Type
		if !self.cameraAvailable {
			Class = SRStatusItemIconUnavailableView.self
		} else {
			Class = self.showCamera ? SRStatusItemCameraView.self : SRStatusItemIconView.self
		}

		// VoiceOver mirrors the X: the button's label says the app is
		// here, the value says whether the camera can run.
		self.statusItem?.button?.setAccessibilityValue(
			self.cameraAvailable ? nil : NSLocalizedString("accessibility.status-item.value.camera-unavailable", comment: "")
		)

		if let current = self.contentView, type(of: current) == Class { return }

		// The camera view is a kept singleton (see cameraContentView): reuse
		// resumes its suspended preview in place; only the very first show
		// creates it (that creation attaches, so no resume on top of it).
		let newContentView: SRStatusItemContentView
		if Class == SRStatusItemCameraView.self {
			if let camera = self.cameraContentView {
				camera.resumeCamera()
				newContentView = camera
			} else {
				let camera = SRStatusItemCameraView(frame: self.bounds, width: self.birthCameraWidth())
				camera.autoresizingMask = [.width, .height]
				self.cameraContentView = camera
				newContentView = camera
			}
		} else {
			newContentView = self.createContentViewWithClass(Class)
		}

		// Swapping away from the live camera: quiet its preview instead of
		// letting the view (and its layer wiring) die with the swap.
		if self.contentView === self.cameraContentView {
			self.cameraContentView?.suspendCamera()
		}

		self.setContentView(newContentView, animated: animated)
	}


	/// The width the camera view is born at: the user's remembered width from
	/// the last drag, clamped to what fits this screen. Clamping happens here,
	/// before the view exists, because the birth width is the only chance to
	/// choose it - resizing after the preview layer attaches blanks the feed.
	/// A width dragged wide on a large display therefore comes back trimmed on
	/// a small one instead of stretching the item under the notch.
	func birthCameraWidth() -> CGFloat {
		let range = SRSettings.allowedStatusItemCameraWidthRange
		let saved = self.preferences.statusItemCameraWidth.value
		return min(self.maximumCameraWidth(), max(range.lowerBound, saved))
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

}
