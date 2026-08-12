//
//  SRHotKeyController.swift
//  Unfurl
//
//  Created by Maria Shergina.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Carbon.HIToolbox


/// The commands the global shortcuts drive. The composition root supplies these
/// as closures bound to the injected services, so this controller never reaches
/// for a singleton and stays testable.
@MainActor
struct SRHotKeyActions {
	let togglePanel: () -> Void
	let takePhoto: () -> Void
	let toggleMirror: () -> Void
	let cycleCamera: () -> Void
}


/// Process-wide keyboard shortcuts via the Carbon Hot Key API
/// (`RegisterEventHotKey`). That is the sandbox-safe way for a background agent
/// to get global shortcuts: unlike an `NSEvent` global monitor it needs no
/// Accessibility permission, and it fires no matter which app is frontmost.
///
/// The default bindings live here (a future Preferences window can override
/// them) and are exposed as key-equivalent constants so the status menu can
/// display matching glyphs without duplicating the mapping.
@MainActor
final class SRHotKeyController {

	// Single source of truth for the default shortcuts, shared with the menu so
	// its glyphs always match what actually fires. All use the same distinctive
	// low-conflict modifier set.
	static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
	static let togglePanelKeyEquivalent = "c"
	static let takePhotoKeyEquivalent = "p"
	static let toggleMirrorKeyEquivalent = "m"
	static let cycleCameraKeyEquivalent = "n"

	fileprivate var actionsByID: [UInt32: () -> Void] = [:]
	fileprivate var hotKeyRefs: [EventHotKeyRef] = []
	fileprivate var eventHandler: EventHandlerRef?
	fileprivate var nextID: UInt32 = 1

	init(actions: SRHotKeyActions) {
		self.installEventHandler()

		let mods = Self.modifiers
		self.register(Self.togglePanelKeyEquivalent, mods, action: actions.togglePanel)
		self.register(Self.takePhotoKeyEquivalent, mods, action: actions.takePhoto)
		self.register(Self.toggleMirrorKeyEquivalent, mods, action: actions.toggleMirror)
		self.register(Self.cycleCameraKeyEquivalent, mods, action: actions.cycleCamera)
	}

	fileprivate func installEventHandler() {
		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard),
			eventKind: UInt32(kEventHotKeyPressed)
		)
		let context = Unmanaged.passUnretained(self).toOpaque()
		InstallEventHandler(
			GetApplicationEventTarget(),
			hotKeyEventHandler,
			1,
			&eventType,
			context,
			&self.eventHandler
		)
	}

	fileprivate func register(_ keyEquivalent: String, _ modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
		guard let keyCode = Self.keyCode(for: keyEquivalent) else { return }

		let id = self.nextID
		self.nextID += 1

		let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
		var ref: EventHotKeyRef?
		let status = RegisterEventHotKey(
			keyCode,
			Self.carbonModifiers(modifiers),
			hotKeyID,
			GetApplicationEventTarget(),
			0,
			&ref
		)

		// A taken combo just fails to register; the app keeps working without
		// that one shortcut rather than crashing.
		if status == noErr, let ref {
			self.actionsByID[id] = action
			self.hotKeyRefs.append(ref)
		}
	}

	fileprivate func perform(id: UInt32) {
		self.actionsByID[id]?()
	}

	// A four-char signature that tags our hot keys ('Nrcs').
	fileprivate static let signature: OSType = {
		let bytes = Array("Nrcs".utf8)
		return (OSType(bytes[0]) << 24) | (OSType(bytes[1]) << 16) | (OSType(bytes[2]) << 8) | OSType(bytes[3])
	}()

	fileprivate static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
		var carbon: UInt32 = 0
		if flags.contains(.command) { carbon |= UInt32(cmdKey) }
		if flags.contains(.option) { carbon |= UInt32(optionKey) }
		if flags.contains(.control) { carbon |= UInt32(controlKey) }
		if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
		return carbon
	}

	/// Virtual key codes for the letters we bind. Only the handful the defaults
	/// use are mapped; an unknown letter simply registers no shortcut.
	fileprivate static func keyCode(for keyEquivalent: String) -> UInt32? {
		switch keyEquivalent {
		case "c": return UInt32(kVK_ANSI_C)
		case "p": return UInt32(kVK_ANSI_P)
		case "m": return UInt32(kVK_ANSI_M)
		case "n": return UInt32(kVK_ANSI_N)
		default: return nil
		}
	}
}


/// Carbon requires a bare C callback. It runs on the main run loop, so we assert
/// main-actor isolation and dispatch to the controller carried in `userData`.
private func hotKeyEventHandler(
	_ callRef: EventHandlerCallRef?,
	_ event: EventRef?,
	_ userData: UnsafeMutableRawPointer?
) -> OSStatus {
	guard let event, let userData else { return OSStatus(eventNotHandledErr) }

	var hotKeyID = EventHotKeyID()
	let status = GetEventParameter(
		event,
		EventParamName(kEventParamDirectObject),
		EventParamType(typeEventHotKeyID),
		nil,
		MemoryLayout<EventHotKeyID>.size,
		nil,
		&hotKeyID
	)
	guard status == noErr else { return status }

	// Carry the controller across the isolation boundary as a Sendable bit
	// pattern (a raw pointer is not Sendable); reconstruct it on the main actor.
	let id = hotKeyID.id
	let context = UInt(bitPattern: userData)
	MainActor.assumeIsolated {
		guard let pointer = UnsafeMutableRawPointer(bitPattern: context) else { return }
		Unmanaged<SRHotKeyController>.fromOpaque(pointer).takeUnretainedValue().perform(id: id)
	}
	return noErr
}
