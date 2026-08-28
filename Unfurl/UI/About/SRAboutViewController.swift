//
//  SRAboutViewController.swift
//  Unfurl
//
//  Created by Maria Shergina on 10/14/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit


class SRAboutViewController: NSViewController {
	private var didInstallConstraints = false

    var logoView: NSImageView!

    var titleView: NSTextField!
    var noteView: NSTextField!
    var signatureView: NSTextField!
    var roleView: NSTextField!
    var supportButton: NSButton!
    var versionView: NSTextField!
    var copyrightView: NSTextField!

    /// The note wraps, so it - not the longest single line - sets the panel's
    /// width. Every other label here is centered and sizes to its own text.
    fileprivate let kTextWidth = CGFloat(400)

    override func loadView() {
        self.view = NSView(frame: CGRect(origin: CGPoint.zero, size: CGSize(width: kAboutWindowWidth, height: 560.0)))

        self.logoView = NSImageView()
        // The real app icon, not a copy of it (see SRWelcomeViewController).
        self.logoView.image = NSApp.applicationIconImage
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

        // Left-aligned: a centered paragraph is ragged on both edges and hard
        // to read. It sits in a centered block, so the panel still reads centered.
        self.noteView = label(NSLocalizedString("about.application.note", comment: ""))
        self.noteView.alignment = .left
        // labelWithString builds a single-line label: maximumNumberOfLines
        // permits more lines but lineBreakMode is what actually wraps. Without
        // it the text honours its width constraint and runs off the panel.
        self.noteView.lineBreakMode = .byWordWrapping
        self.noteView.usesSingleLineMode = false
        self.noteView.cell?.wraps = true
        self.noteView.maximumNumberOfLines = 0
        self.noteView.preferredMaxLayoutWidth = self.kTextWidth
        self.noteView.textColor = .labelColor
        self.view.addSubview(self.noteView)

        self.signatureView = label(
            NSLocalizedString("about.application.signature", comment: ""),
            font: NSFont.systemFont(ofSize: 13, weight: .medium)
        )
        self.signatureView.alignment = .left
        self.view.addSubview(self.signatureView)

        self.roleView = label(NSLocalizedString("about.application.role", comment: ""))
        self.roleView.alignment = .left
        self.roleView.textColor = .secondaryLabelColor
        self.view.addSubview(self.roleView)

        self.supportButton = NSButton(
            title: NSLocalizedString("about.application.support", comment: ""),
            target: self,
            action: #selector(handleSupportButton)
        )
        self.supportButton.bezelStyle = .rounded
        self.supportButton.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.supportButton)

        let dictionary = Bundle.main.infoDictionary!
        let versions = dictionary["CFBundleShortVersionString"] as! String
        let build = dictionary["CFBundleVersion"] as! String
        let versionTextFormat: String = NSLocalizedString("about.application.version", comment: "")
        self.versionView = label(String(format: versionTextFormat, arguments: [versions, build]))
        self.versionView.textColor = .secondaryLabelColor
        self.view.addSubview(self.versionView)

        self.copyrightView = label(NSLocalizedString("about.application.copyright", comment: ""))
        self.copyrightView.textColor = .secondaryLabelColor
        self.view.addSubview(self.copyrightView)

        self.view.needsUpdateConstraints = true
        self.view.updateConstraintsForSubtreeIfNeeded()
    }

    /// Where support lives. A URL rather than a mailto on purpose: this ships
    /// inside the binary, so it can only be changed by releasing a new version
    /// - a link can be repointed at a real support page later, an address
    /// cannot. LAUNCH.md carries this as the App Store Support URL too.
    fileprivate static let supportURL = URL(string: "https://github.com/shergina/unfurl")

    @objc fileprivate func handleSupportButton() {
        guard let url = Self.supportURL else { return }
        NSWorkspace.shared.open(url)
    }

    override func updateViewConstraints() {
        if !self.didInstallConstraints {
            let kVerticalMargin = CGFloat(30)
            let kTextVerticalMargin = CGFloat(8)
            // The app icon image carries its own transparent margin for the
            // system's shadow - about 11pt of it at this 128pt size - so a
            // gap measured from the image view's edge renders that much
            // larger than the number says. Subtract it, and keep the icon
            // close to the name: the two are one identity block, and the
            // real separation belongs between them and the note.
            let kIconToTitle = CGFloat(8)
            let kTitleToNote = CGFloat(26)
            // Support belongs with the signature above it - that block is who
            // made this and how to reach them - so it sits closer to the name
            // than to the footer. Equal gaps on both sides read as floating.
            let kSignatureToSupport = CGFloat(18)
            let kSupportToFooter = CGFloat(36)

            NSLayoutConstraint.activate([
                self.logoView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.logoView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: kVerticalMargin),
                self.logoView.widthAnchor.constraint(equalToConstant: 128.0),
                self.logoView.heightAnchor.constraint(equalToConstant: 128.0),

                self.titleView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.titleView.topAnchor.constraint(equalTo: self.logoView.bottomAnchor, constant: kIconToTitle),

                self.noteView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.noteView.widthAnchor.constraint(equalToConstant: self.kTextWidth),
                self.noteView.topAnchor.constraint(equalTo: self.titleView.bottomAnchor, constant: kTitleToNote),

                self.signatureView.leadingAnchor.constraint(equalTo: self.noteView.leadingAnchor),
                self.signatureView.topAnchor.constraint(equalTo: self.noteView.bottomAnchor, constant: kTextVerticalMargin + 4.0),

                self.roleView.leadingAnchor.constraint(equalTo: self.noteView.leadingAnchor),
                self.roleView.topAnchor.constraint(equalTo: self.signatureView.bottomAnchor, constant: 2.0),

                // A control, not a line of the signature: its bezel gives it
                // enough identity to sit centered under the left-aligned block
                // without reading as stray text the way the address did.
                self.supportButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.supportButton.topAnchor.constraint(equalTo: self.roleView.bottomAnchor, constant: kSignatureToSupport),

                self.versionView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.versionView.topAnchor.constraint(equalTo: self.supportButton.bottomAnchor, constant: kSupportToFooter),

                self.copyrightView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                self.copyrightView.topAnchor.constraint(equalTo: self.versionView.bottomAnchor, constant: kTextVerticalMargin),
                self.copyrightView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -kVerticalMargin),
            ])
            self.didInstallConstraints = true
        }

        super.updateViewConstraints()
    }
}
