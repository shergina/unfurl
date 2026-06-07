//
//  SRStatisticsWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine
import SwiftUI


/// The Statistics window: today's hourly posture chart over the history
/// store's live counts (see spec.md). Owned as a single kept instance by
/// SRMenuController, shown from the menu's Statistics item.
class SRStatisticsWindowController: NSWindowController {

	/// Room for the future charts; the placeholder holds the final frame
	/// so real content is not a resize surprise later (spec.md).
	static let windowSize = CGSize(width: 640.0, height: 480.0)

	override func loadWindow() {
		let window = NSWindow(
			contentRect: CGRect(origin: .zero, size: Self.windowSize),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: true
		)
		window.title = NSLocalizedString("statistics.window.title", comment: "")
		window.isReleasedWhenClosed = false
		self.window = window

		self.contentViewController = SRStatisticsViewController()
		window.center()
	}

	override func showWindow(_ sender: Any?) {
		super.showWindow(sender)

		// The Settings-window recipe: with the Dock tile off the activation
		// policy is .prohibited, activation is refused, and without the
		// regardless-ordering the window opens behind the active app.
		self.window!.makeKeyAndOrderFront(sender)
		self.window!.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

}


/// Hosts the SwiftUI today chart and drives its redraw cadence: fresh on
/// every appearance, then at most one redraw per 30 seconds off the
/// history service's change publisher while the window is visible. The
/// chart itself never self-updates - calm by construction (spec.md).
fileprivate final class SRStatisticsViewController: NSViewController {

	fileprivate let history = SRPostureHistoryService.sharedInstance
	fileprivate var hostingView: NSHostingView<SRStatisticsTodayView>!
	fileprivate var cancellables = Set<AnyCancellable>()

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let hosting = NSHostingView(rootView: SRStatisticsTodayView(model: self.currentModel()))
		self.hostingView = hosting
		// The view carries the window size (the welcome-page pattern):
		// setting contentViewController resizes the window to the view's
		// fitting size, and without these the window collapses.
		NSLayoutConstraint.activate([
			hosting.widthAnchor.constraint(equalToConstant: SRStatisticsWindowController.windowSize.width),
			hosting.heightAnchor.constraint(equalToConstant: SRStatisticsWindowController.windowSize.height),
		])
		self.view = hosting
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		self.history.onChange
			.throttle(for: .seconds(30), scheduler: DispatchQueue.main, latest: true)
			.sink { [unowned self] in self.render() }
			.store(in: &self.cancellables)
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		// Fresh on every open; this is also what rolls the chart over to
		// the new day when the window is reopened after midnight.
		self.render()
	}

	fileprivate func render() {
		// A closed window skips the redraw; viewWillAppear catches up.
		guard self.hostingView.window?.isVisible == true || self.hostingView.window == nil else { return }
		self.hostingView.rootView = SRStatisticsTodayView(model: self.currentModel())
	}

	fileprivate func currentModel() -> SRStatisticsTodayModel {
		let now = Date.now
		return SRStatisticsTodayModel.today(
			in: self.history.days,
			dayKey: SRPostureHistoryService.dayKey(for: now),
			now: now
		)
	}

}
