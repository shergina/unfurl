//
//  SRAboutViewController.swift
//  Narcissism
//
//  Created by Maria Shergina on 10/14/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit


class SRAboutViewController: NSViewController {
	private var didInstallConstraints = false

    var logoView: NSImageView!

    var titleView: NSTextField!
    var subtitleView: NSTextField!
    var versionView: NSTextField!
    var copyrightView: NSTextField!

    override func loadView() {
        self.view = NSView(frame: CGRect(origin: CGPoint.zero, size: CGSize(width: 300.0, height: 400.0)))

        self.logoView = NSImageView()
        self.logoView.image = NSImage(named: "AppIcon")
        self.logoView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.logoView)

        func label(_ text: String, font: NSFont? = nil) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.translatesAutoresizingMaskIntoConstraints = false
            if let font = font {
                label.font = font
            }
            return label
        }

        self.titleView = label(
            NSLocalizedString("about.application.title", comment: ""),
            font: NSFont.boldSystemFont(ofSize: 22)
        )
        self.view.addSubview(self.titleView)

        self.subtitleView = label(
            NSLocalizedString("about.application.subtitle", comment: ""),
            font: NSFont.systemFont(ofSize: 16)
        )
        self.view.addSubview(self.subtitleView)

        let dictionary = Bundle.main.infoDictionary!
        let versions = dictionary["CFBundleShortVersionString"] as! String
        let build = dictionary["CFBundleVersion"] as! String
        let versionTextFormat: String = NSLocalizedString("about.application.version", comment: "")
        self.versionView = label(String(format: versionTextFormat, arguments: [versions, build]))
        self.view.addSubview(self.versionView)

        self.copyrightView = label(NSLocalizedString("about.application.copyright", comment: ""))
        self.view.addSubview(self.copyrightView)

        self.view.needsUpdateConstraints = true
        self.view.updateConstraintsForSubtreeIfNeeded()
    }

    override func updateViewConstraints() {
        if !self.didInstallConstraints {
            let kVerticalMargin = CGFloat(30)
            let kTextVerticalMargin = CGFloat(8)

            NSLayoutConstraint.activate([
                self.logoView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.logoView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: kVerticalMargin),
                self.logoView.widthAnchor.constraint(equalToConstant: 128.0),
                self.logoView.heightAnchor.constraint(equalToConstant: 128.0),

                self.titleView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.titleView.topAnchor.constraint(equalTo: self.logoView.bottomAnchor, constant: kVerticalMargin),

                self.subtitleView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.subtitleView.topAnchor.constraint(equalTo: self.titleView.bottomAnchor, constant: kTextVerticalMargin),

                self.versionView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.versionView.topAnchor.constraint(equalTo: self.subtitleView.bottomAnchor, constant: kTextVerticalMargin),

                self.copyrightView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.copyrightView.topAnchor.constraint(equalTo: self.versionView.bottomAnchor, constant: kTextVerticalMargin),
                self.copyrightView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -kVerticalMargin),
            ])
            self.didInstallConstraints = true
        }

        super.updateViewConstraints()
    }
}
