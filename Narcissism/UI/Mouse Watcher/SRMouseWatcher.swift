//
//  SRMouseWatcher.swift
//  Narcissism
//
//  Created by Maria Shergina on 28/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


@MainActor
protocol SRMouseWatcherListener: AnyObject {
	func mouseMoved(withRelativePoint point: CGPoint)
}


/// Tracks the mouse across the screen and reports its position in unit
/// coordinates (0...1 of the screen). Replaces the 2015 Objective-C
/// version built on a CGEventTap - NSEvent monitors do the same job
/// without event-tap machinery, which is also what triggers Input
/// Monitoring permission prompts on modern macOS.
@MainActor
final class SRMouseWatcher {

	static let sharedInstance = SRMouseWatcher()

	fileprivate let listeners = NSHashTable<AnyObject>.weakObjects()
	fileprivate var monitors: [Any] = []

	fileprivate init() {
		if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
			self?.handleMouseMove()
		}) {
			self.monitors.append(global)
		}

		if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
			self?.handleMouseMove()
			return event
		}) {
			self.monitors.append(local)
		}
	}

	func add(_ listener: SRMouseWatcherListener) {
		self.listeners.add(listener)
	}

	func remove(_ listener: SRMouseWatcherListener) {
		self.listeners.remove(listener)
	}

	var relativePoint: CGPoint {
		// Computed against the current screen frame (the old version cached
		// it at init and went stale on display changes).
		guard let screenFrame = NSScreen.main?.frame,
			screenFrame.width > 0, screenFrame.height > 0
		else {
			return .zero
		}

		let mouseLocation = NSEvent.mouseLocation
		return CGPoint(
			x: mouseLocation.x / screenFrame.width,
			y: mouseLocation.y / screenFrame.height
		)
	}

	fileprivate func handleMouseMove() {
		let point = self.relativePoint
		for listener in self.listeners.allObjects {
			(listener as? SRMouseWatcherListener)?.mouseMoved(withRelativePoint: point)
		}
	}
}
