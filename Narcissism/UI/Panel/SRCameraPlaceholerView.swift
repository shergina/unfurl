//
//  SRCameraPlaceholerView.swift
//  Narcissism
//
//  Created by Maria Shergina on 21/10/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine

class SRCameraPlaceholerView: NSVisualEffectView {

	fileprivate let logoView: NSImageView
	fileprivate let messageLabel: NSTextField
	fileprivate let actionButton: NSButton
	fileprivate var didInstallConstraints = false
	fileprivate var cancellables = Set<AnyCancellable>()

	override class var requiresConstraintBasedLayout: Bool {
		return true
	}

	override init(frame: NSRect) {
		self.logoView = NSImageView()
		self.logoView.wantsLayer = true
		self.logoView.image = NSImage(named: "MonochromaticLogo")
		self.logoView.layer?.opacity = 0.1
		self.logoView.translatesAutoresizingMaskIntoConstraints = false

		self.messageLabel = NSTextField(labelWithString: "")
		self.messageLabel.translatesAutoresizingMaskIntoConstraints = false
		self.messageLabel.alignment = .center
		self.messageLabel.textColor = .secondaryLabelColor
		self.messageLabel.font = .systemFont(ofSize: 12)
		self.messageLabel.maximumNumberOfLines = 0
		self.messageLabel.isHidden = true

		self.actionButton = NSButton(title: "", target: nil, action: nil)
		self.actionButton.translatesAutoresizingMaskIntoConstraints = false
		self.actionButton.bezelStyle = .rounded
		self.actionButton.controlSize = .small
		self.actionButton.isHidden = true

		super.init(frame: frame)

		self.material = .underWindowBackground
		self.blendingMode = .behindWindow

		self.addSubview(self.logoView)
		self.addSubview(self.messageLabel)
		self.addSubview(self.actionButton)

		self.actionButton.target = self
		self.actionButton.action = #selector(SRCameraPlaceholerView.handleActionButton)

		// The placeholder sits behind the live video; a message only shows
		// when the pipeline is not delivering frames and has something to say.
		SRCameraService.sharedInstance.onState
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in self?.apply(state: $0) }
			.store(in: &self.cancellables)
	}

	required init?(coder: NSCoder) {
	    fatalError("`init(coder:)` has not been implemented.")
	}

	fileprivate func apply(state: SRCameraState) {
		let message: String?
		let actionTitle: String?

		switch state {
		case .idle, .running:
			message = nil
			actionTitle = nil
		case .unauthorized:
			message = NSLocalizedString("camera.placeholder.unauthorized", comment: "")
			actionTitle = NSLocalizedString("camera.placeholder.open-settings", comment: "")
		case .unavailable:
			message = NSLocalizedString("camera.placeholder.unavailable", comment: "")
			actionTitle = nil
		case .failed(let description):
			message = description
			actionTitle = nil
		}

		self.messageLabel.stringValue = message ?? ""
		self.messageLabel.isHidden = (message == nil)

		if let actionTitle = actionTitle {
			self.actionButton.title = actionTitle
			self.actionButton.isHidden = false
		} else {
			self.actionButton.isHidden = true
		}
	}

	@objc fileprivate func handleActionButton() {
		// Deep-link straight to the Camera privacy pane. The pre-Ventura
		// com.apple.preference.security URL no longer opens the right pane
		// under System Settings.
		if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera") {
			NSWorkspace.shared.open(url)
		}
	}

	override func updateConstraints() {
		if !self.didInstallConstraints {
			let logoSize: CGFloat = 64.0

			NSLayoutConstraint.activate([
				self.logoView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
				self.logoView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
				self.logoView.widthAnchor.constraint(equalToConstant: logoSize),
				self.logoView.heightAnchor.constraint(equalToConstant: logoSize),

				self.messageLabel.topAnchor.constraint(equalTo: self.logoView.bottomAnchor, constant: 16.0),
				self.messageLabel.centerXAnchor.constraint(equalTo: self.centerXAnchor),
				self.messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor, constant: 24.0),
				self.messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -24.0),

				self.actionButton.topAnchor.constraint(equalTo: self.messageLabel.bottomAnchor, constant: 10.0),
				self.actionButton.centerXAnchor.constraint(equalTo: self.centerXAnchor),
			])
			self.didInstallConstraints = true
		}
		super.updateConstraints()
	}

}
