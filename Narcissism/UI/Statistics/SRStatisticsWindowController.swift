//
//  SRStatisticsWindowController.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


/// The Statistics window: a standalone window reserved for the posture
/// statistics to come (see UI/Settings/VISION.md), a placeholder line
/// until the history store exists. Owned as a single kept instance by
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


/// The content, deliberately empty for now: the window exists before the
/// posture history store that will feed it does.
fileprivate final class SRStatisticsViewController: NSViewController {

	init() {
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let label = NSTextField(labelWithString: NSLocalizedString("statistics.placeholder", comment: ""))
		label.textColor = .secondaryLabelColor
		label.translatesAutoresizingMaskIntoConstraints = false

		let view = NSView()
		view.addSubview(label)
		// The view carries the window size (the welcome-page pattern):
		// setting contentViewController resizes the window to the view's
		// fitting size, and without these the window collapses to the label.
		NSLayoutConstraint.activate([
			view.widthAnchor.constraint(equalToConstant: SRStatisticsWindowController.windowSize.width),
			view.heightAnchor.constraint(equalToConstant: SRStatisticsWindowController.windowSize.height),
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
		])
		self.view = view
	}

}
