//
//  SRPanelViewController.swift
//  Narcissism
//
//  Created by Maria Shergina on 14/06/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine


class SRPanelViewController: NSViewController {


	lazy var onMouseHover: AnyPublisher<Bool, Never> = { return self.view.mouseHoverPublisher() }()

	convenience init() {
		self.init(nibName: nil, bundle: nil)
	}

	override func loadView() {
		self.view = SRPanelContentView()
	}

	override func viewWillAppear() {
		super.viewWillAppear()
	}

}
