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

		// Left/right arrows step through the date strip.
		self.window!.makeFirstResponder(self.contentViewController?.view)
	}

}


/// Hosts the SwiftUI content and owns the selection and redraw cadence:
/// the selected day resets to today on every appearance, the state
/// refreshes at most once per 30 seconds off the history service's
/// change publisher while the window is visible, and left/right arrows
/// step through the strip. The state flows through SRStatisticsStore so
/// the root view instance survives refreshes (preserving the strip's
/// scroll position); the views never self-update (spec.md).
fileprivate final class SRStatisticsViewController: NSViewController {

	fileprivate let history = SRPostureHistoryService.sharedInstance
	fileprivate var store: SRStatisticsStore!
	fileprivate var selectedDay = Calendar.current.startOfDay(for: Date.now)
	fileprivate var cancellables = Set<AnyCancellable>()

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let store = SRStatisticsStore(state: self.currentState())
		store.onSelect = { [unowned self] date in self.select(date) }
		self.store = store

		let hosting = SRStatisticsHostingView(rootView: SRStatisticsRootView(store: store))
		hosting.onStepDay = { [unowned self] delta in self.step(delta) }
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
			.sink { [unowned self] in self.refresh() }
			.store(in: &self.cancellables)
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		// Every open starts on today; this is also what rolls the window
		// over to the new day when it is reopened after midnight.
		self.selectedDay = Calendar.current.startOfDay(for: Date.now)
		self.refresh()
	}

	fileprivate func select(_ date: Date) {
		self.selectedDay = Calendar.current.startOfDay(for: date)
		self.refresh()
	}

	/// Arrow keys: one day per press, clamped to the strip's span.
	fileprivate func step(_ delta: Int) {
		let calendar = Calendar.current
		guard
			let moved = calendar.date(byAdding: .day, value: delta, to: self.selectedDay),
			let first = self.store.state.strip.first?.date,
			let last = self.store.state.strip.last?.date
		else { return }
		self.select(min(max(moved, first), last))
	}

	fileprivate func refresh() {
		// A closed window skips the refresh; viewWillAppear catches up.
		guard self.view.window?.isVisible == true || self.view.window == nil else { return }
		self.store.state = self.currentState()
	}

	fileprivate func currentState() -> SRStatisticsViewState {
		let calendar = Calendar.current
		let now = Date.now
		let today = calendar.startOfDay(for: now)
		let selectedKey = SRPostureHistoryService.dayKey(for: self.selectedDay)
		let isToday = self.selectedDay == today

		// The strip: today rightmost, back to the first recorded day
		// (just today while nothing is recorded yet).
		var firstDay = today
		if let earliestKey = self.history.days.keys.min(),
			let parsed = SRPostureHistoryService.day(forKey: earliestKey) {
			firstDay = min(calendar.startOfDay(for: parsed), today)
		}
		var strip: [SRStatisticsDayCell] = []
		var date = firstDay
		while date <= today {
			let key = SRPostureHistoryService.dayKey(for: date)
			let measured = self.history.days[key]?.hours.values.reduce(0) { $0 + $1.measuredSeconds } ?? 0
			strip.append(SRStatisticsDayCell(date: date, key: key, hasData: measured > 0))
			date = calendar.date(byAdding: .day, value: 1, to: date) ?? today.addingTimeInterval(1)
		}

		return SRStatisticsViewState(
			strip: strip,
			selectedKey: selectedKey,
			selectedDate: self.selectedDay,
			todayDate: today,
			isToday: isToday,
			day: SRStatisticsDayModel.day(
				in: self.history.days,
				key: selectedKey,
				selectedDay: self.selectedDay,
				currentHour: isToday ? calendar.component(.hour, from: now) : nil
			),
			trends: SRStatisticsTrendsModel.trends(in: self.history.days, now: now)
		)
	}

}


/// Hosting view that turns left/right arrow presses into date-strip
/// steps; everything else passes through to SwiftUI.
fileprivate final class SRStatisticsHostingView: NSHostingView<SRStatisticsRootView> {

	var onStepDay: ((Int) -> Void)?

	override var acceptsFirstResponder: Bool { return true }

	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 123: self.onStepDay?(-1)  // left arrow
		case 124: self.onStepDay?(1)   // right arrow
		default: super.keyDown(with: event)
		}
	}

}
