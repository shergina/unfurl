//
//  compose-screenshots.swift
//  Unfurl
//
//  Turns raw window captures into the two things the launch needs: App Store
//  canvases at exact pixel sizes, and downscaled README pairs. AppKit rather
//  than Pillow or ImageMagick so it runs on a stock Mac with nothing installed.
//
//  Compile it, do not `swift` it: the interpreter's JIT crashes inside AppKit's
//  drawing stack. There is no shebang here for the same reason.
//
//    swiftc -O scripts/compose-screenshots.swift -o /tmp/compose
//    /tmp/compose <rawDir> <outDir> [options]
//
//    <rawDir>  holds light/ and dark/ subfolders of window captures (PNG with
//              alpha - capture with Cmd-Shift-4 then Space, or screencapture -w)
//    <outDir>  is created; anything already there with the same name is replaced
//
//  Options:
//    --canvas WxH        App Store canvas, repeatable (default 2880x1800)
//    --max-scale N       never enlarge past this (default 1.0, keeps captures crisp)
//    --margin N          smallest gap between window and canvas edge, in canvas
//                        pixels (default 160)
//    --readme-width N    width of the README copies (default 1200)
//    --bg-light HEX      light canvas fill (default F2F2F7)
//    --bg-dark HEX       dark canvas fill (default 1C1C1E)
//
//  Output:
//    <outDir>/appstore/<WxH>/<theme>/<name>.png   opaque, exact size, no alpha
//    <outDir>/readme/<theme>/<name>.png           alpha kept, so GitHub's themes
//                                                 show through the rounded corners
//  and the <picture> markup for each README pair, printed at the end.
//

import AppKit
import Foundation

// AppKit's drawing stack wants an initialized application even in a command
// line tool; without this the first graphics context crashes.
_ = NSApplication.shared

// MARK: - Arguments

struct Options {
	var rawDir = ""
	var outDir = ""
	var canvases: [CGSize] = []
	var maxScale: CGFloat = 1.0
	var margin: CGFloat = 160
	var readmeWidth: CGFloat = 1200
	var backgrounds: [String: NSColor] = [:]
}

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("error: \(message)\n".utf8))
	exit(1)
}

func color(fromHex hex: String) -> NSColor {
	var value: UInt64 = 0
	Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
	return NSColor(
		srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
		green: CGFloat((value >> 8) & 0xFF) / 255.0,
		blue: CGFloat(value & 0xFF) / 255.0,
		alpha: 1.0
	)
}

func parseArguments() -> Options {
	var options = Options()
	var positional: [String] = []
	var lightHex = "F2F2F7"
	var darkHex = "1C1C1E"

	var index = 1
	let arguments = CommandLine.arguments
	while index < arguments.count {
		let argument = arguments[index]
		func next() -> String {
			index += 1
			guard index < arguments.count else { fail("\(argument) needs a value") }
			return arguments[index]
		}
		switch argument {
		case "--canvas":
			let parts = next().lowercased().split(separator: "x")
			guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
				fail("--canvas wants WxH, for example 2880x1800")
			}
			options.canvases.append(CGSize(width: w, height: h))
		case "--max-scale": options.maxScale = CGFloat(Double(next()) ?? 1.0)
		case "--margin": options.margin = CGFloat(Double(next()) ?? 160)
		case "--readme-width": options.readmeWidth = CGFloat(Double(next()) ?? 1200)
		case "--bg-light": lightHex = next()
		case "--bg-dark": darkHex = next()
		case let flag where flag.hasPrefix("--"): fail("unknown option \(flag)")
		default: positional.append(argument)
		}
		index += 1
	}

	guard positional.count == 2 else {
		fail("usage: swift scripts/compose-screenshots.swift <rawDir> <outDir> [options]")
	}
	options.rawDir = positional[0]
	options.outDir = positional[1]
	if options.canvases.isEmpty {
		options.canvases = [CGSize(width: 2880, height: 1800)]
	}
	options.backgrounds = ["light": color(fromHex: lightHex), "dark": color(fromHex: darkHex)]
	return options
}

// MARK: - Drawing

/// Strips the alpha channel by copying RGB into a 3-sample rep. Needed because
/// App Store Connect rejects an alpha channel, but CoreGraphics cannot back a
/// drawing context with a 24-bit no-alpha bitmap - so the canvas is drawn in
/// 32-bit and flattened afterwards. The background is opaque, so premultiplied
/// and straight RGB are the same bytes here and the copy is lossless.
func opaqueCopy(of source: NSBitmapImageRep) -> NSBitmapImageRep {
	let width = source.pixelsWide, height = source.pixelsHigh
	guard let output = NSBitmapImageRep(
		bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
		bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
		colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24
	), let from = source.bitmapData, let to = output.bitmapData else {
		fail("could not flatten a \(width)x\(height) canvas")
	}
	for y in 0..<height {
		var read = from + y * source.bytesPerRow
		var write = to + y * output.bytesPerRow
		for _ in 0..<width {
			write[0] = read[0]; write[1] = read[1]; write[2] = read[2]
			read += 4; write += 3
		}
	}
	return output
}

/// Draws `image` centered on an opaque canvas. Opaque on purpose: flattening
/// is what turns the capture's transparent rounded corners into the canvas
/// color rather than black, and what keeps the alpha channel out of the file.
func canvasRep(for image: NSImage, size: CGSize, background: NSColor, margin: CGFloat, maxScale: CGFloat) -> NSBitmapImageRep {
	guard let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
		bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
		colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width) * 4, bitsPerPixel: 32
	) else { fail("could not allocate a \(Int(size.width))x\(Int(size.height)) canvas") }

	// Fit inside the margins, but never enlarge past maxScale: these are 2x
	// captures, and upscaling them is the one thing that would visibly soften
	// text that is otherwise pixel-perfect.
	let available = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
	let fit = min(available.width / image.size.width, available.height / image.size.height)
	let scale = min(fit, maxScale)
	let drawn = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
	let origin = CGPoint(x: ((size.width - drawn.width) / 2).rounded(), y: ((size.height - drawn.height) / 2).rounded())

	guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
		fail("could not open a drawing context for a \(Int(size.width))x\(Int(size.height)) canvas")
	}
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = context
	context.imageInterpolation = .high
	background.setFill()
	NSRect(origin: .zero, size: size).fill()
	image.draw(
		in: NSRect(origin: origin, size: drawn),
		from: NSRect(origin: .zero, size: image.size),
		operation: .sourceOver,
		fraction: 1.0
	)
	NSGraphicsContext.restoreGraphicsState()
	return opaqueCopy(of: rep)
}

/// Straight resize with the alpha channel intact, for GitHub: transparent
/// rounded corners let the reader's theme show through instead of sitting on
/// a white block.
func resizedRep(for image: NSImage, toWidth width: CGFloat) -> NSBitmapImageRep {
	let scale = width / image.size.width
	let size = CGSize(width: width.rounded(), height: (image.size.height * scale).rounded())
	guard let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
		bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
		colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width) * 4, bitsPerPixel: 32
	) else { fail("could not allocate a \(Int(size.width))px resize") }

	guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
		fail("could not open a drawing context for a \(Int(size.width))px resize")
	}
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = context
	context.imageInterpolation = .high
	image.draw(
		in: NSRect(origin: .zero, size: size),
		from: NSRect(origin: .zero, size: image.size),
		operation: .copy,
		fraction: 1.0
	)
	NSGraphicsContext.restoreGraphicsState()
	return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
	guard let data = rep.representation(using: .png, properties: [:]) else {
		fail("could not encode \(path)")
	}
	let url = URL(fileURLWithPath: path)
	try? FileManager.default.createDirectory(
		at: url.deletingLastPathComponent(), withIntermediateDirectories: true
	)
	do { try data.write(to: url) } catch { fail("could not write \(path): \(error)") }
}

func kilobytes(_ path: String) -> Int {
	let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
	return (size + 512) / 1024
}

// MARK: - Run

let options = parseArguments()
let fileManager = FileManager.default
var readmeNames: Set<String> = []
var produced = 0

for theme in ["light", "dark"] {
	let themeDir = "\(options.rawDir)/\(theme)"
	guard let entries = try? fileManager.contentsOfDirectory(atPath: themeDir) else {
		print("skipping \(theme): no \(themeDir)")
		continue
	}
	let background = options.backgrounds[theme]!

	for entry in entries.sorted() where entry.lowercased().hasSuffix(".png") {
		let name = (entry as NSString).deletingPathExtension
		let source = "\(themeDir)/\(entry)"
		guard let image = NSImage(contentsOfFile: source), image.size.width > 0 else {
			fail("could not read \(source)")
		}

		for canvas in options.canvases {
			let label = "\(Int(canvas.width))x\(Int(canvas.height))"
			let target = "\(options.outDir)/appstore/\(label)/\(theme)/\(name).png"
			write(
				canvasRep(
					for: image, size: canvas, background: background,
					margin: options.margin, maxScale: options.maxScale
				),
				to: target
			)
			print("  appstore \(label) \(theme)/\(name).png  \(kilobytes(target))KB")
			produced += 1
		}

		let readme = "\(options.outDir)/readme/\(theme)/\(name).png"
		write(resizedRep(for: image, toWidth: options.readmeWidth), to: readme)
		print("  readme   \(Int(options.readmeWidth))px  \(theme)/\(name).png  \(kilobytes(readme))KB")
		readmeNames.insert(name)
		produced += 1
	}
}

guard produced > 0 else { fail("nothing to do - put window captures in \(options.rawDir)/light and \(options.rawDir)/dark") }

print("\n--- paste into README.md, one block per image ---\n")
for name in readmeNames.sorted() {
	print("""
	<picture>
	  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/\(name).png">
	  <img src="docs/screenshots/light/\(name).png" width="700"
	       alt="TODO: describe what the screenshot shows, not that it is a screenshot.">
	</picture>
	""")
	print("")
}
