//
//  SRStatusItemController.swift
//  Narcissism
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import AppKit
import Combine


@MainActor
class SRStatusItemController: NSObject, NSMenuDelegate, SRStatusItemViewDelegate {

	fileprivate let services: AppServices
	let preferences: SRSettings

	var statusItem: NSStatusItem
	var statusItemView: SRStatusItemView

	fileprivate var cancellables = Set<AnyCancellable>()
	let onMouseHover: AnyPublisher<Bool, Never>
	let onMenuShown = CurrentValueSubject<Bool, Never>(false)

	init(services: AppServices) {
		self.services = services
		self.preferences = services.settings

		let systemStatusBar = NSStatusBar.system

		let statusItem = systemStatusBar.statusItem(withLength: NSStatusItem.variableLength)

		let width = self.preferences.statusItemWithCameraWidth.defaultValue
		let statusItemView = SRStatusItemView(frame: CGRect(x: 0, y: 0, width: width, height: systemStatusBar.thickness))
		statusItemView.statusItem = statusItem

		// Modern macOS: host the custom view inside statusItem.button instead of statusItem.view (deprecated).
		// The item's width is driven by `statusItem.length` (see SRStatusItemView.updateStatusItemLength);
		// do NOT pin a fixed width constraint here or it fights the dynamic length and collapses the item.
		if let button = statusItem.button {
			button.subviews.forEach { $0.removeFromSuperview() }
			statusItemView.translatesAutoresizingMaskIntoConstraints = false
			button.addSubview(statusItemView)
			NSLayoutConstraint.activate([
				statusItemView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
				statusItemView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
				statusItemView.topAnchor.constraint(equalTo: button.topAnchor),
				statusItemView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
				// Pin an explicit height (menu bar thickness). Without it the button
				// has no intrinsic height and collapses to 0 when a content view with
				// no intrinsic height (the camera view) is installed.
				statusItemView.heightAnchor.constraint(equalToConstant: systemStatusBar.thickness),
			])
		}

		statusItem.length = width

		self.statusItem = statusItem
		self.statusItemView = statusItemView

		let menuShown = self.onMenuShown
		self.onMouseHover = statusItemView.mouseHoverPublisher()
			.combineLatest(menuShown)
			.map { $0 && !$1 }
			.removeDuplicates()
			.eraseToAnyPublisher()

		super.init()

		self.statusItemView.delegate = self

		// Wire up the button click → present menu
		if let button = self.statusItem.button {
			button.target = self
			button.action = #selector(SRStatusItemController.handleButtonClick(_:))
			// The button hosts a custom camera view, so VoiceOver has no title
			// to read; give it one and describe what activating it does.
			button.setAccessibilityLabel(NSLocalizedString("accessibility.status-item.label", comment: ""))
			button.setAccessibilityHelp(NSLocalizedString("accessibility.status-item.help", comment: ""))
		}

		self.onMenuShown
			.sink { [unowned self] in self.statusItemView.lighted = $0 }
			.store(in: &self.cancellables)

		NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
			.sink { [unowned self] _ in
				NSStatusBar.system.removeStatusItem(self.statusItem)
			}
			.store(in: &self.cancellables)
	}

	@objc func handleButtonClick(_ sender: Any?) {
		let menu = self.services.menu.menuForStatusBar()
		menu.delegate = self
		self.statusItem.menu = menu
		self.statusItem.button?.performClick(nil)
		self.statusItem.menu = nil
	}

	// MARK: SRStatusItemViewDelegate

	func statusItemView(_ view: NSView, clickGestureRecognized: NSGestureRecognizer) {
		self.handleButtonClick(nil)
	}

	// MARK: NSMenuDelegate

	func menuWillOpen(_ menu: NSMenu) {
		self.onMenuShown.send(true)
	}

	func menuDidClose(_ menu: NSMenu) {
		self.onMenuShown.send(false)
	}
}
