//
//  SRWelcomeWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The welcome window: the first-run flow (see spec.md next to this file).
/// Owned as a single kept instance by SRMenuController, shown by the
/// composition root at launch. Pages are swapped as the content view
/// controller; Continue advances, the last page closes.
class SRWelcomeWindowController: NSWindowController {

	/// One fixed size for every page, set by the tallest (the posture
	/// preset): the window must never change size mid-flow, and the nav
	/// buttons sit in the same bottom band on every page.
	static let pageSize = CGSize(width: 480, height: 680)

	/// Set by the owner before showWindow; page two's Locate Me routes
	/// through here to the status item (wired in the composition root).
	var onLocate: (() -> Void)?

	override func loadWindow() {
		// The real page size, not .zero: center() runs before a deferred
		// window is materialized, and centering a zero-size frame parks the
		// window in the bottom-right quadrant once it grows to content size.
		let window = NSWindow(
			contentRect: CGRect(origin: .zero, size: Self.pageSize),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: true
		)
		// The page carries its own big title; the system title bar stays but
		// shows no text, so the title is not said twice.
		window.titleVisibility = .hidden
		window.title = NSLocalizedString("welcome.title", comment: "")
		window.isReleasedWhenClosed = false

		// Float while open, the calibration-window precedent: onboarding is
		// a short focused task, and without this the system camera
		// permission alert drops the window behind other apps on dismiss.
		window.level = .floating
		window.collectionBehavior = [.moveToActiveSpace]

		self.window = window

		self.showAboutPage()
	}

	override func showWindow(_ sender: Any?) {
		let freshPresentation = !(self.isWindowLoaded && self.window?.isVisible == true)

		// The instance is kept across closes; a re-show restarts the flow.
		if self.isWindowLoaded, let window = self.window, !window.isVisible {
			self.showAboutPage()
		}

		super.showWindow(sender)

		// Center only now: a deferred window gets its real frame when first
		// ordered on screen, and centering during loadWindow operated on
		// placeholder geometry, parking the window bottom-right.
		if freshPresentation {
			self.window!.center()
		}

		// The Settings-window recipe: with the Dock tile off the activation
		// policy is .prohibited, activation is refused, and without the
		// regardless-ordering the window opens behind the active app.
		self.window!.makeKeyAndOrderFront(sender)
		self.window!.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

	fileprivate func showAboutPage() {
		let page = SRWelcomeViewController()
		page.onContinue = { [weak self] in self?.showTutorialPage() }
		self.contentViewController = page
	}

	fileprivate func showTutorialPage() {
		let page = SRWelcomeTutorialViewController()
		page.onLocate = { [weak self] in self?.onLocate?() }
		page.onContinue = { [weak self] in self?.showReadyPage() }
		page.onBack = { [weak self] in self?.showAboutPage() }
		self.contentViewController = page
	}

	fileprivate func showReadyPage() {
		let page = SRWelcomeReadyViewController()
		page.onContinue = { [weak self] in self?.showGoodPosturePage() }
		page.onClose = { [weak self] in self?.close() }
		page.onBack = { [weak self] in self?.showTutorialPage() }
		self.contentViewController = page
	}

	fileprivate func showGoodPosturePage() {
		let page = SRWelcomeGoodPostureViewController()
		page.onReady = { [weak self] in self?.showPosturePage() }
		page.onClose = { [weak self] in self?.close() }
		page.onBack = { [weak self] in self?.showReadyPage() }
		self.contentViewController = page
	}

	fileprivate func showPosturePage() {
		let page = SRWelcomePostureViewController()
		page.onClose = { [weak self] in self?.close() }
		page.onBack = { [weak self] in self?.showGoodPosturePage() }
		self.contentViewController = page
	}

	/// True while the posture preset page is up; the calibration funnel in
	/// SRMenuController re-fronts this window instead of opening the
	/// standalone calibration window then.
	var isShowingPostureCalibration: Bool {
		return self.isWindowLoaded
			&& self.window?.isVisible == true
			&& self.contentViewController is SRWelcomePostureViewController
	}

}
