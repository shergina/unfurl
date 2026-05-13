//
//  SRDockTileCameraView.swift
//  Narcissism
//
//  Created by Maria Shergina on 21/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import AVFoundation

class SRDockTileCameraView: NSView {

	var imageRef: CGImage?

	/// Geometry and styling of the tile. Icon ratios follow the Big Sur
	/// app-icon template; badge ratios were measured off the real macOS
	/// Dock (Messages' notification badge, see git history). Point values
	/// are expressed at a 128pt reference tile and scaled to the real size.
	fileprivate enum Metrics {
		static let referenceSide: CGFloat = 128.0

		// Icon shape
		static let iconInsetRatio: CGFloat = 0.1        // of tile side, per edge
		static let cornerRadiusRatio: CGFloat = 0.225   // of icon width

		// Icon drop shadow (at reference size)
		static let iconShadowOffsetY: CGFloat = -1.5
		static let iconShadowBlur: CGFloat = 4.5
		static let iconShadowAlpha: CGFloat = 0.3

		// Edge accents (hairlines, at reference size)
		static let edgeDarkAlpha: CGFloat = 0.3
		static let edgeLightAlpha: CGFloat = 0.22

		// Badge: the system notification badge is a disc with
		// diameter = 0.48 x icon width, overhanging by 0.24 of itself.
		// The camera glyph is an outline, not a solid disc, so its visible
		// width runs larger for equal perceived mass.
		static let badgeVisualWidthRatio: CGFloat = 0.55   // of icon width
		static let badgeOverhangRightRatio: CGFloat = 0.24 // of visible width
		static let badgeOverhangBelowRatio: CGFloat = 0.35 // of visible height
		static let badgeShadowOffsetY: CGFloat = -1.0
		static let badgeShadowBlur: CGFloat = 3.5
		static let badgeShadowAlpha: CGFloat = 0.55
		// Tight zero-offset contour that rims every edge of the white glyph,
		// keeping it legible when the video behind it is equally bright.
		static let badgeHaloBlur: CGFloat = 1.5
		static let badgeHaloAlpha: CGFloat = 0.7

		/// Alpha bounds of the camera glyph within MonochromaticLogo's square
		/// canvas (unit coordinates, measured from the asset): the glyph is
		/// wide, not square, so the badge is placed by its *visible* edges.
		static let logoContentRect = CGRect(x: 0.012, y: 0.158, width: 0.977, height: 0.684)
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
	}

	required init(coder: NSCoder) {
		fatalError("`init(coder:)` has not been implemented.")
	}

	// The tile redraws for every camera frame, but only the video pixels
	// change. Everything else - the icon shadow (a Gaussian blur), the edge
	// hairlines, and the badge with its own shadow - is pre-rendered once
	// per tile size into two cached images: a backdrop composited under the
	// video and an overlay composited above it. The per-frame path is then
	// three image blits and a clip.

	fileprivate struct TileChrome {
		let size: CGSize
		let iconRect: CGRect
		let iconPath: CGPath
		let backdrop: CGImage
		let overlay: CGImage
	}

	fileprivate var cachedChrome: TileChrome?

	override func draw(_ dirtyRect: NSRect) {
		guard let imageRef = self.imageRef else { return }
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		guard let chrome = self.chrome(for: self.bounds.size) else { return }

		let fullRect = CGRect(origin: .zero, size: chrome.size)
		context.draw(chrome.backdrop, in: fullRect)

		context.saveGState()
		context.addPath(chrome.iconPath)
		context.clip()
		// Mirror mode: the panel and status bar flip their preview layers;
		// the dock draws raw frames, so apply the same flip here. The icon
		// rect is horizontally centered, so mirroring about the tile's
		// vertical axis mirrors the video in place; the badge and edge
		// accents (drawn outside this clip) stay unflipped.
		if SRSettings.sharedInstance.flipCameraHorizontally.value {
			context.translateBy(x: fullRect.width, y: 0)
			context.scaleBy(x: -1, y: 1)
		}
		context.draw(imageRef, in: chrome.iconRect)
		context.restoreGState()

		context.draw(chrome.overlay, in: fullRect)
	}

	//: Chrome construction

	fileprivate func chrome(for size: CGSize) -> TileChrome? {
		if let chrome = self.cachedChrome, chrome.size == size {
			return chrome
		}

		guard size.width > 0, size.height > 0 else { return nil }

		let fullRect = CGRect(origin: .zero, size: size)
		let side = min(size.width, size.height)
		let scale = side / Metrics.referenceSide

		let iconRect = fullRect.insetBy(dx: side * Metrics.iconInsetRatio, dy: side * Metrics.iconInsetRatio)
		let radius = iconRect.width * Metrics.cornerRadiusRatio
		let iconPath = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

		guard
			let backdrop = self.renderChromeImage(size: size, { context in
				self.drawBackdrop(in: context, iconPath: iconPath, scale: scale)
			}),
			let overlay = self.renderChromeImage(size: size, { context in
				self.drawEdgeAccents(in: context, iconRect: iconRect, iconPath: iconPath, radius: radius, scale: scale)
				self.drawBadge(in: context, iconRect: iconRect, fullRect: fullRect, scale: scale)
			})
		else {
			return nil
		}

		let chrome = TileChrome(size: size, iconRect: iconRect, iconPath: iconPath, backdrop: backdrop, overlay: overlay)
		self.cachedChrome = chrome
		return chrome
	}

	/// Renders one chrome pass into a Retina-density bitmap.
	fileprivate func renderChromeImage(size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
		let pixelScale: CGFloat = self.window?.backingScaleFactor ?? 2.0
		guard let context = CGContext(
			data: nil,
			width: Int(size.width * pixelScale),
			height: Int(size.height * pixelScale),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return nil
		}

		context.scaleBy(x: pixelScale, y: pixelScale)
		draw(context)
		return context.makeImage()
	}

	/// The icon's drop shadow, composited under the video.
	fileprivate func drawBackdrop(in context: CGContext, iconPath: CGPath, scale: CGFloat) {
		context.saveGState()
		context.setShadow(
			offset: CGSize(width: 0, height: Metrics.iconShadowOffsetY * scale),
			blur: Metrics.iconShadowBlur * scale,
			color: NSColor.black.withAlphaComponent(Metrics.iconShadowAlpha).cgColor
		)
		context.addPath(iconPath)
		context.setFillColor(NSColor.black.cgColor)
		context.fillPath()
		context.restoreGState()
	}

	/// Edge accents, the treatment system icons like Terminal carry: a
	/// hairline dark edge defining the shape against bright content, and a
	/// light inner accent just inside it as the bevel highlight. Strokes are
	/// drawn while clipped, so only their inner half shows.
	fileprivate func drawEdgeAccents(in context: CGContext, iconRect: CGRect, iconPath: CGPath, radius: CGFloat, scale: CGFloat) {
		let hairline = max(1.0, scale)

		context.saveGState()
		context.addPath(iconPath)
		context.clip()

		context.addPath(iconPath)
		context.setStrokeColor(NSColor.black.withAlphaComponent(Metrics.edgeDarkAlpha).cgColor)
		context.setLineWidth(hairline * 2.0)
		context.strokePath()

		let innerRect = iconRect.insetBy(dx: hairline, dy: hairline)
		let innerPath = CGPath(roundedRect: innerRect, cornerWidth: radius - hairline, cornerHeight: radius - hairline, transform: nil)
		context.addPath(innerPath)
		context.setStrokeColor(NSColor.white.withAlphaComponent(Metrics.edgeLightAlpha).cgColor)
		context.setLineWidth(hairline)
		context.strokePath()

		context.restoreGState()
	}

	//: Badge

	/// The app's camera logo as a corner badge: white, with a soft shadow
	/// for separation, hanging partially outside the icon shape the way
	/// classic macOS badges do.
	fileprivate static let watermarkLogo: CGImage? = {
		let logo = NSImage(named: "MonochromaticLogo")!
		let tinted = NSImage(size: logo.size, flipped: false) { rect in
			logo.draw(in: rect)
			NSColor.white.set()
			rect.fill(using: .sourceAtop)
			return true
		}
		var rect = CGRect(origin: .zero, size: tinted.size)
		return tinted.cgImage(forProposedRect: &rect, context: nil, hints: nil)
	}()

	fileprivate func drawBadge(in context: CGContext, iconRect: CGRect, fullRect: CGRect, scale: CGFloat) {
		guard let logo = Self.watermarkLogo else { return }

		let content = Metrics.logoContentRect

		// Overhangs are capped by the room the tile canvas actually has.
		let visualWidth = iconRect.width * Metrics.badgeVisualWidthRatio
		let visualHeight = visualWidth * (content.height / content.width)

		let overhangRight = min(visualWidth * Metrics.badgeOverhangRightRatio, fullRect.maxX - iconRect.maxX - 1.0)
		let overhangBelow = min(visualHeight * Metrics.badgeOverhangBelowRatio, iconRect.minY - fullRect.minY - 1.0)

		// Map the desired visual rect back to the image's square box.
		let boxSize = visualWidth / content.width
		let badgeRect = CGRect(
			x: (iconRect.maxX + overhangRight) - content.maxX * boxSize,
			y: (iconRect.minY - overhangBelow) - content.minY * boxSize,
			width: boxSize,
			height: boxSize
		)

		// Halo pass: a tight contour around the glyph for contrast on bright
		// video...
		context.saveGState()
		context.setShadow(
			offset: .zero,
			blur: Metrics.badgeHaloBlur * scale,
			color: NSColor.black.withAlphaComponent(Metrics.badgeHaloAlpha).cgColor
		)
		context.draw(logo, in: badgeRect)
		context.restoreGState()

		// ...then the soft drop shadow for depth.
		context.saveGState()
		context.setShadow(
			offset: CGSize(width: 0, height: Metrics.badgeShadowOffsetY * scale),
			blur: Metrics.badgeShadowBlur * scale,
			color: NSColor.black.withAlphaComponent(Metrics.badgeShadowAlpha).cgColor
		)
		context.draw(logo, in: badgeRect)
		context.restoreGState()
	}

}
