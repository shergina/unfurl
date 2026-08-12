//
//  main.swift
//  Unfurl
//
//  Created by Maria Shergina on 17/10/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import AppKit

autoreleasepool { () -> () in
	let app = NSApplication.shared
	let delegate = SRUnfurlApplicationDelegate()
	app.delegate = delegate
	app.run()
}

