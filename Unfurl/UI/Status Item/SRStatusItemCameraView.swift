//
//  SRStatusItemCameraView.swift
//  Unfurl
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

	// Hover and menu-open both drive the overlay, so its visibility is derived
	// in one place rather than two observers fighting over alphaValue.
	fileprivate var hovered = false

	// How far the feed dims while the menu is open. The system draws its own
	// highlight behind us, so a low value stops the video covering that fill
	// and the two composite into haze - it reads as blur, not as a press.
	fileprivate static let lightedOpacity: Float = 0.85

	/// `width` is the birth width and must arrive already clamped to the
	/// current screen - the host resolves it (SRStatusItemView.birthWidth).
	/// It is set once here and never re-set from the content path: resizing
	/// after the preview layer attaches blanks the feed.
	init(frame: NSRect, width: CGFloat) {
		self.startViewWidth = 0
		self.startMouseX = 0
		self.width = width

		super.init(frame: frame)

		self.cameraView = SRScrollCameraView(frame: self.bounds)
		self.cameraView.autoresizingMask = [.width, .height]
		self.addSubview(self.cameraView)

		let iconImage = self.iconImageSuitableForCurrentAppearance()
		self.iconImageView = NSImageView(frame: CGRect(origin: CGPoint(x: 2, y: 0), size: iconImage.size))
		self.iconImageView.wantsLayer = true
		self.iconImageView.image = iconImage
		// The overlay icon is only shown while hovering with the menu closed;
		// start hidden so it doesn't obscure the live camera feed by default.
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
				self.hovered = $0
				self.updateOverlayVisibility(animated: true)
				#if USE_UNDOCUMENTED_API
				// Hint that the camera item is drag-to-resize.
				if $0 { self.cursor.push() } else { NSCursor.pop() }
				#endif
			}
			.store(in: &self.cancellables)
	}

	/// Only for the generic content-view path; the host always uses the
	/// width-carrying initializer above.
	override convenience init(frame: NSRect) {
		self.init(frame: frame, width: SRSettings.defaultStatusItemCameraWidth)
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
			self.cameraView.layer!.opacity = self.lighted ? SRStatusItemCameraView.lightedOpacity : 1.0
			self.updateOverlayVisibility(animated: true)
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

	/// The mark is a hover affordance, so it steps aside while the menu is open:
	/// the menu already names the app, and `lighted` dims only the video, which
	/// would otherwise leave the mark the brightest thing in the item.
	fileprivate func updateOverlayVisibility(animated: Bool) {
		self.iconImageView.setVisible(self.hovered && !self.lighted, animated: animated)
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
				// Remember where the user left it. Saved only at the end of a
				// drag, not on every frame of it, so a drag is one write.
				// Re-clamped to the screen on the next launch, not here.
				SRSettings.sharedInstance.statusItemCameraWidth.value = self.width

			@unknown default:
				break
		}
	}
}
