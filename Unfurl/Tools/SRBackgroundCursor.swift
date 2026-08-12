//
//  SRBackgroundCursor.swift
//  Unfurl
//
//  Created by Maria Shergina.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa


#if USE_UNDOCUMENTED_API
/// Allow this background app to change the mouse cursor. macOS normally lets
/// only the active app set the cursor, and this is an LSUIElement agent that is
/// never active, so `NSCursor` calls are otherwise ignored - over the menu bar
/// (the status item) and over our own non-key panel alike. This is the only
/// mechanism that works; it calls a private CoreGraphics SPI, gated on the
/// `USE_UNDOCUMENTED_API` build flag (defined for all configurations, including
/// App Store, which the app has passed review with before). Flip the flag off
/// to compile out every undocumented-API use in one move. Symbols are resolved
/// with `dlsym` to keep the target free of a bridging header.
///
/// Process-wide and idempotent: setting the connection property more than once
/// is harmless, so every surface that wants a background cursor may call this.
@MainActor
func enableCursorChangesForBackgroundApp() {
	typealias ConnectionID = Int32
	typealias DefaultConnectionFn = @convention(c) () -> ConnectionID
	typealias SetConnectionPropertyFn = @convention(c) (ConnectionID, ConnectionID, CFString, CFTypeRef) -> Int32

	let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
	guard
		let defaultConnectionSym = dlsym(rtldDefault, "_CGSDefaultConnection"),
		let setPropertySym = dlsym(rtldDefault, "CGSSetConnectionProperty")
	else {
		return
	}

	let defaultConnection = unsafeBitCast(defaultConnectionSym, to: DefaultConnectionFn.self)
	let setConnectionProperty = unsafeBitCast(setPropertySym, to: SetConnectionPropertyFn.self)

	let connection = defaultConnection()
	_ = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}
#endif
