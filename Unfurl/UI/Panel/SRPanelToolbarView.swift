//
//  SRPanelToolbarView.swift
//  Unfurl
//
//  Created by Maria Shergina on 28/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


/// The panel's floating control chip: a translucent pill that fades in when
/// the cursor is over the panel (see SRPanelContentView), in the spirit of
/// QuickTime/FaceTime overlay controls. SF Symbol buttons, vibrancy-tinted.
class SRPanelToolbarView: NSVisualEffectView {

	fileprivate let preferences = SRSettings.sharedInstance
	fileprivate var cancellables = Set<AnyCancellable>()

	fileprivate var closeButtonView: NSButton!
	fileprivate var pinButtonView: NSButton!
	fileprivate var photoButtonView: NSButton!
	fileprivate var ghostButtonView: NSButton!
	fileprivate var mirrorButtonView: NSButton!
	fileprivate var menuButtonView: NSButton!

	fileprivate var stackView: NSStackView!

	override init(frame: NSRect) {
		super.init(frame: frame)

		self.material = .hudWindow
		self.blendingMode = .withinWindow
		self.state = .active
		self.wantsLayer = true
		self.layer!.cornerRadius = SRPanelToolbarView.chipHeight / 2.0
		self.layer!.cornerCurve = .continuous
		self.layer!.masksToBounds = true

		self.closeButtonView = SRPanelToolbarView.toolbarButton(symbolName: "xmark", accessibilityDescription: NSLocalizedString("panel.toolbar.close", comment: ""))
		self.pinButtonView = SRPanelToolbarView.toolbarButton(symbolName: "pin", accessibilityDescription: NSLocalizedString("panel.toolbar.pin", comment: ""))
		self.photoButtonView = SRPanelToolbarView.toolbarButton(symbolName: "camera", accessibilityDescription: NSLocalizedString("panel.toolbar.photo", comment: ""))
		self.ghostButtonView = SRPanelToolbarView.toolbarButton(symbolName: "cursorarrow.slash", accessibilityDescription: NSLocalizedString("panel.toolbar.ghost", comment: ""))
		self.mirrorButtonView = SRPanelToolbarView.toolbarButton(symbolName: "trapezoid.and.line.vertical", accessibilityDescription: NSLocalizedString("panel.toolbar.mirror", comment: ""))
		self.menuButtonView = SRPanelToolbarView.toolbarButton(symbolName: "ellipsis.circle", accessibilityDescription: NSLocalizedString("panel.toolbar.menu", comment: ""))

		self.stackView = NSStackView(views: [
			self.closeButtonView,
			self.pinButtonView,
			self.photoButtonView,
			self.ghostButtonView,
			self.mirrorButtonView,
			self.menuButtonView,
		])
		self.stackView.orientation = .horizontal
		self.stackView.spacing = 6.0
		self.stackView.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
		self.stackView.translatesAutoresizingMaskIntoConstraints = false
		self.addSubview(self.stackView)

		NSLayoutConstraint.activate([
			self.heightAnchor.constraint(equalToConstant: SRPanelToolbarView.chipHeight),
			self.stackView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
			self.stackView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
			self.stackView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
		])

		self.closeButtonView.actionPublisher()
			.sink { [unowned self] _ in
				// The toolbar lives in the panel window, whose windowController is
				// the SRPanelController - reach it directly, no global needed.
				(self.window?.windowController as? SRPanelController)?.handleCloseButton()
			}
			.store(in: &self.cancellables)

		self.pinButtonView.actionPublisher()
			.sink { [unowned self] _ in
				self.preferences.cameraPanelPinned.toggle()
			}
			.store(in: &self.cancellables)

		self.photoButtonView.actionPublisher()
			.sink { _ in
				SRPhotoCaptureService.sharedInstance.capture()
			}
			.store(in: &self.cancellables)

		self.ghostButtonView.actionPublisher()
			.sink { [unowned self] _ in
				self.preferences.cameraPanelGhostMode.toggle()
			}
			.store(in: &self.cancellables)

		self.mirrorButtonView.actionPublisher()
			.sink { [unowned self] _ in
				self.preferences.flipCameraHorizontally.toggle()
			}
			.store(in: &self.cancellables)

		self.menuButtonView.actionPublisher()
			.sink { [unowned self] _ in
				let menu: NSMenu = SRMenuController.sharedInstance.menuForToolbar()
				menu.popUp(positioning: nil, at: NSPoint(x: 0.0, y: self.menuButtonView.bounds.maxY + 6.0), in: self.menuButtonView)
			}
			.store(in: &self.cancellables)

		Publishers.Merge3(
			self.preferences.cameraPanelPinned.publisher,
			self.preferences.cameraPanelGhostMode.publisher,
			self.preferences.flipCameraHorizontally.publisher
		)
		.sink { [unowned self] _ in self.updateButtonStyle() }
		.store(in: &self.cancellables)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	static let chipHeight: CGFloat = 38.0

	class func toolbarButton(symbolName: String, accessibilityDescription: String) -> NSButton {
		let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)!
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14.0, weight: .medium))!

		let button = NSButton()
		button.setButtonType(.momentaryChange)
		button.bezelStyle = .regularSquare
		button.isBordered = false
		button.imagePosition = .imageOnly
		button.image = image
		button.contentTintColor = .labelColor
		button.toolTip = accessibilityDescription

		button.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 28.0),
			button.heightAnchor.constraint(equalToConstant: 28.0),
		])

		return button
	}

	func setCompactMode(_ compactMode: Bool, animated: Bool) {
		let alpha: CGFloat = compactMode ? 0.0 : 1.0
		// Reduce Motion: apply the end alpha at once.
		let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		if animated {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.2
				self.animator().alphaValue = alpha
			}
		} else {
			self.alphaValue = alpha
		}
	}

	fileprivate func updateButtonStyle() {
		func applyToggleTint(_ button: NSButton, on: Bool) {
			button.contentTintColor = on ? .controlAccentColor : .labelColor
		}

		applyToggleTint(self.pinButtonView, on: self.preferences.cameraPanelPinned.value)
		applyToggleTint(self.ghostButtonView, on: self.preferences.cameraPanelGhostMode.value)
		applyToggleTint(self.mirrorButtonView, on: self.preferences.flipCameraHorizontally.value)
	}
}
