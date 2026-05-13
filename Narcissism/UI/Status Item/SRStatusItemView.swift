
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

	override init(frame: NSRect) {
		self.lighted = false

		super.init(frame: frame)

		let clickGestureRecognizer = NSClickGestureRecognizer(target: self, action: #selector(SRStatusItemView.handleClickGesture(_:)))
		clickGestureRecognizer.delegate = self
		self.addGestureRecognizer(clickGestureRecognizer)

		self.setContentView(self.createContentViewWithClass(SRStatusItemIconUnavailableView.self), animated: false)

		SRCameraService.sharedInstance.onCaptureDeviceAvailable
			.combineLatest(self.preferences.showCameraOnStatusBar.publisher)
			.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
			.sink { [unowned self] (cameraAvailable, showCameraOnStatusBar) in
				let Class: NSView.Type = showCameraOnStatusBar ? (cameraAvailable ? SRStatusItemCameraView.self as NSView.Type : SRStatusItemIconUnavailableView.self as NSView.Type) : SRStatusItemIconView.self
				self.setContentView(self.createContentViewWithClass(Class), animated: true)
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

	override func viewWillMove(toWindow newWindow: NSWindow?) {
		self.window?.invalidateCursorRects(for: self)
	}

	override func resetCursorRects() {
		super.resetCursorRects()
	}

}
