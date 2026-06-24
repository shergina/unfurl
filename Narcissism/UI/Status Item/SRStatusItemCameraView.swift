//
//  SRStatusItemCameraView.swift
//  Narcissism
//
//  Created by Maria Shergina on 19/08/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


private extension NSView {
	func setVisible(_ visible: Bool, animated: Bool) {
		let target: CGFloat = visible ? 1.0 : 0.0
		if animated {
			NSAnimationContext.runAnimationGroup({ ctx in
				ctx.duration = 0.2
				self.animator().alphaValue = target
			}, completionHandler: nil)
		} else {
			self.alphaValue = target
		}
		self.isHidden = (target == 0.0 && !animated)
	}
}

class SRStatusItemCameraView: SRStatusItemContentView, NSGestureRecognizerDelegate {

	fileprivate var cameraView: SRScrollCameraView!
	fileprivate var iconImageView: NSImageView!

	fileprivate var startViewWidth: CGFloat
	fileprivate var startMouseX: CGFloat

	#if USE_UNDOCUMENTED_API
	fileprivate lazy var cursor = NSCursor.resizeLeftRight
	#endif
	fileprivate var cancellables = Set<AnyCancellable>()

	override init(frame: NSRect) {
		self.startViewWidth = 0
		self.startMouseX = 0
		// Session-only width: always start from the default, never the last run's
		// value, so a previous session's resize has no effect on relaunch.
		self.width = SRSettings.defaultStatusItemCameraWidth

		super.init(frame: frame)

		self.cameraView = SRScrollCameraView(frame: self.bounds)
		self.cameraView.autoresizingMask = [.width, .height]
		self.addSubview(self.cameraView)

		let iconImage = self.iconImageSuitableForCurrentAppearance()
		self.iconImageView = NSImageView(frame: CGRect(origin: CGPoint(x: 2, y: 0), size: iconImage.size))
		self.iconImageView.wantsLayer = true
		self.iconImageView.image = iconImage
		// The overlay icon is only shown while hovering; start hidden so it
		// doesn't obscure the live camera feed by default.
		self.iconImageView.alphaValue = 0.0
		self.addSubview(self.iconImageView)

		let panGestureRecognizer = NSPanGestureRecognizer(target: self, action: #selector(SRStatusItemCameraView.handlePanGesture(_:)))
		panGestureRecognizer.delegate = self
		self.addGestureRecognizer(panGestureRecognizer)

		#if USE_UNDOCUMENTED_API
		// Required for the resize cursor below to appear from this background
		// agent; without it macOS ignores our cursor changes over the menu bar.
		enableCursorChangesForBackgroundApp()
		#endif

		self.mouseHoverPublisher()
			.sink { [unowned self] in
				self.iconImageView.setVisible($0, animated: true)
				#if USE_UNDOCUMENTED_API
				// Hint that the camera item is drag-to-resize.
				if $0 { self.cursor.push() } else { NSCursor.pop() }
				#endif
			}
			.store(in: &self.cancellables)
	}

	required init?(coder: NSCoder) {
	    fatalError("init(coder:) has not been implemented")
	}

	/// Suspend/resume forwarding for the host's content swaps: the view is
	/// kept and reused across Show Camera toggles, so its preview layer never
	/// detaches from the running session (see SRStatusItemView.refreshContent).
	func suspendCamera() {
		self.cameraView.suspendPreview()
	}

	func resumeCamera() {
		self.cameraView.resumePreview()
	}

	var width: CGFloat {
		didSet {
			// Resize the whole status item through NSStatusItem.length (via the
			// hosting SRStatusItemView) instead of setting the superview frame
			// directly, which the Auto Layout constraints would immediately undo.
			(self.superview as? SRStatusItemView)?.updateStatusItemLength(self.width)
		}
	}

	override var lighted: Bool {
		didSet {
			self.cameraView.layer!.opacity = self.lighted ? 0.5 : 1.0
		}
	}

	override var postureAlert: Bool {
		didSet {
			// No template image to tint here, so the live camera gets an
			// orange frame instead.
			self.cameraView.layer!.borderColor = NSColor.systemOrange.cgColor
			self.cameraView.layer!.borderWidth = self.postureAlert ? 2.0 : 0.0
		}
	}

	override var intrinsicContentSize: CGSize {
		return CGSize(width: self.width, height: self.bounds.size.height)
	}

	func iconImageSuitableForCurrentAppearance() -> NSImage {
		let isAppearanceDark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		return NSImage(named: isAppearanceDark ? "StatusItemIconOverlayWhite" : "StatusItemIconOverlayBlack")!
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		self.iconImageView.image = self.iconImageSuitableForCurrentAppearance()
	}

	// Mouse events

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		return true
	}

	// Gesture recognizer

	@objc func handlePanGesture(_ gestureRecognizer: NSGestureRecognizer) {
		let state = gestureRecognizer.state
		let mouseLocationX = NSEvent.mouseLocation.x

		switch state {
			case .possible:
				break

			case .began:
				self.startViewWidth = self.bounds.size.width
				self.startMouseX = mouseLocationX

			case .changed:
				let proposed = self.startViewWidth + (self.startMouseX - mouseLocationX)
				let range = SRSettings.allowedStatusItemCameraWidthRange
				// Follow the mouse, bounded below by the absolute minimum and above
				// by the screen-scaled maximum (see SRStatusItemView.maximumCameraWidth).
				let maxWidth = (self.superview as? SRStatusItemView)?.maximumCameraWidth() ?? range.upperBound
				self.width = min(maxWidth, max(range.lowerBound, proposed))

			case .ended, .cancelled, .failed:
				// Session-only: the resized width is deliberately NOT persisted, so
				// relaunching always starts fresh at the default. Dragging still
				// resizes the item live during the current session.
				(self.superview as? SRStatusItemView)?.logGeometry("drag-end")

			@unknown default:
				break
		}
	}
}
