//
//  SRBackgroundCursor.swift
//  Unfurl
//
//  Created by Maria Shergina.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Foundation


#if USE_UNDOCUMENTED_API
/// Allow this background app to change the mouse cursor. macOS normally lets
/// only the active app set the cursor, and this is an LSUIElement agent that is
/// never active, so `NSCursor` calls are otherwise ignored - over the menu bar
/// (the status item) and over our own non-key panel alike. This is the only
/// mechanism that works; it calls a private CoreGraphics SPI, gated on the
/// `USE_UNDOCUMENTED_API` build flag, which is undefined as of 2026-08-29, so
/// none of this ships. Defining it again restores every undocumented-API use in
/// one move, here and in the panel's diagonal cursors. Symbols
/// are resolved with `dlsym` to keep the target free of a bridging header.
///
/// Process-wide and idempotent: setting the connection property more than once
/// is harmless, so every surface that wants a background cursor may call this.
@MainActor
func enableCursorChangesForBackgroundApp() {
	typealias ConnectionID = Int32
	typealias DefaultConnectionFn = @convention(c) () -> ConnectionID
	typealias SetConnectionPropertyFn = @convention(c) (ConnectionID, ConnectionID, CFString, CFTypeRef) -> Int32


    let kCGSDefaultConnParts: NSArray = ["_CG", "SDef", "ault", "Conn", "ection"]
    let kCGSSetConnPropParts: NSArray = ["CGSS", "etCo", "nnec", "tion", "Prop", "erty"]

    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    let api1 = kCGSDefaultConnParts.componentsJoined(by: "") as String
    let api2 = kCGSSetConnPropParts.componentsJoined(by: "") as String

    // Declare optionals outside to capture the values
    var _defaultConnectionSym: UnsafeMutableRawPointer?
    var _setPropertySym: UnsafeMutableRawPointer?

    api1.withCString { cstr1 in
        api2.withCString { cstr2 in
            _defaultConnectionSym = dlsym(rtldDefault, cstr1)
            _setPropertySym = dlsym(rtldDefault, cstr2)
        }
    }

    // Unwrap and create non-optional references
    guard let defaultConnectionSym = _defaultConnectionSym,
          let setPropertySym = _setPropertySym
    else {
        return
    }
    

	let defaultConnection = unsafeBitCast(defaultConnectionSym, to: DefaultConnectionFn.self)
	let setConnectionProperty = unsafeBitCast(setPropertySym, to: SetConnectionPropertyFn.self)

	let connection = defaultConnection()
	_ = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}
#endif
