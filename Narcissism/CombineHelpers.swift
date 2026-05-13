//
//  CombineHelpers.swift
//  Narcissism
//
//  Custom Combine publishers used during the migration off SignalKit.
//

import Cocoa
import Combine


// MARK: - NSView mouseHover publisher

extension NSView {
	/// Emits `true` when the mouse enters the view, `false` when it leaves.
	func mouseHoverPublisher() -> AnyPublisher<Bool, Never> {
		let watcher = _MouseHoverWatcher(view: self)
		return watcher.subject
			.handleEvents(receiveCancel: { Task { @MainActor in watcher.detach() } })
			// Emit an initial `false` (the mouse starts outside the view). Without
			// this, downstream `combineLatest` chains never produce a value until
			// the first hover — e.g. the pinned camera panel would never appear.
			.prepend(false)
			.eraseToAnyPublisher()
	}
}

private final class _MouseHoverWatcher: NSResponder {
	let subject = PassthroughSubject<Bool, Never>()
	private weak var view: NSView?
	private var trackingArea: NSTrackingArea?

	init(view: NSView) {
		self.view = view
		super.init()

		// .activeAlways, not .activeInActiveApp: this is an accessory app that
		// is almost never "active", and the camera panel is deliberately a
		// non-activating panel - with the stricter option, hover would only
		// ever fire while the app happened to be frontmost.
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self,
			userInfo: nil
		)
		view.addTrackingArea(area)
		self.trackingArea = area
	}

	required init?(coder: NSCoder) { fatalError() }

	func detach() {
		if let view = view, let area = trackingArea {
			view.removeTrackingArea(area)
		}
		trackingArea = nil
		view = nil
	}

	override func mouseEntered(with event: NSEvent) { subject.send(true) }
	override func mouseExited(with event: NSEvent) { subject.send(false) }
}


// MARK: - NSControl action publisher

extension NSControl {
	/// Emits the control whenever its action fires.
	func actionPublisher() -> AnyPublisher<NSControl, Never> {
		let handler = _ActionHandler(control: self)
		return handler.subject
			.handleEvents(receiveCancel: { Task { @MainActor in handler.detach() } })
			.eraseToAnyPublisher()
	}
}

@MainActor
private final class _ActionHandler: NSObject {
	let subject = PassthroughSubject<NSControl, Never>()
	private weak var control: NSControl?

	init(control: NSControl) {
		self.control = control
		super.init()
		control.target = self
		control.action = #selector(_ActionHandler.fire(_:))
	}

	@objc func fire(_ sender: NSControl) {
		subject.send(sender)
	}

	func detach() {
		control?.target = nil
		control?.action = nil
	}
}


// MARK: - Publisher → Subject convenience

extension Publisher where Failure == Never {
	/// Forward every emitted value into a subject. Convenience for the old SignalKit `bindTo`.
	func bind(to subject: PassthroughSubject<Output, Never>) -> AnyCancellable {
		return sink { subject.send($0) }
	}

	func bind(to subject: CurrentValueSubject<Output, Never>) -> AnyCancellable {
		return sink { subject.send($0) }
	}
}
