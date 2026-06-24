//
//  SRCameraService.swift
//  Narcissism
//
//  Created by Maria Shergina on 8/17/26.
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

@preconcurrency import AVFoundation
import Combine


/// What the camera pipeline is doing, for surfaces that need to explain
/// themselves (the panel placeholder) rather than showing a blank frame.
enum SRCameraState: Equatable {
	case idle          // nothing is using the camera yet
	case unauthorized  // camera access denied or restricted in System Settings
	case unavailable   // authorized, but no usable capture device
	case running       // session started, delivering frames
	case failed(String)

	var isRunning: Bool {
		if case .running = self { return true }
		return false
	}
}


/// A selectable camera, identified by its stable `AVCaptureDevice.uniqueID`.
/// `isExternal` marks monitor cameras and USB webcams (device type
/// `.external`), the ones Automatic may prefer over the built-in.
struct CameraDevice: Equatable, Sendable {
	let id: String
	let name: String
	let isExternal: Bool
}


/// The camera surface that consumers depend on: device availability, the
/// explainable state, the selectable device list, and attaching/detaching
/// preview layers and outputs. Injected through `AppServices` so a test can
/// substitute a fake without a real camera. The concrete `SRCameraService` is
/// the only production conformer.
protocol CameraProviding: AnyObject, Sendable {
	var onCaptureDeviceAvailable: CurrentValueSubject<Bool, Never> { get }
	var onState: CurrentValueSubject<SRCameraState, Never> { get }

	/// The cameras currently attached to the machine.
	var onDevices: CurrentValueSubject<[CameraDevice], Never> { get }
	/// The `uniqueID` of the device actually in use, or "" for none.
	var onSelectedDeviceID: CurrentValueSubject<String, Never> { get }
	/// Switch the active device by `uniqueID`; "" means the system default.
	func selectDevice(id: String)
	/// While Automatic, prefer an external (display) camera over the built-in
	/// when one is present. Re-resolves the active device.
	func setPreferExternalCamera(_ prefer: Bool)
	/// While non-nil, Automatic may auto-prefer only these external cameras;
	/// nil means no restriction. The policy behind the set lives upstream
	/// (posture's calibration gate, wired by the composition root); the
	/// service just applies it. An explicit pick is never restricted.
	func setAutoSwitchableExternalIDs(_ ids: Set<String>?)
	/// Session-only override of the resolved device, for a flow that must
	/// look through a camera the policy would not pick (calibrating a
	/// not-yet-active camera). Never persisted; nil clears it.
	func setTemporaryDeviceOverride(id: String?)

	@discardableResult func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Error>
	@discardableResult func detachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Never>
	@discardableResult func attachOutput(_ output: AVCaptureOutput) -> Task<Void, Error>
	@discardableResult func detachOutput(_ output: AVCaptureOutput) -> Task<Void, Never>

	/// Stops the session's work for an attached output - no frames delivered,
	/// no conversion - and releases its claim on the session, without removing
	/// it from the graph: removing an output from the running session stalls
	/// frame delivery to every consumer for ~300 ms (the measured toggle
	/// blink; see Tools/spec.md), while a disabled connection is free. The
	/// suspended output is torn down with the session when the last claim
	/// leaves. Idempotent.
	@discardableResult func suspendOutput(_ output: AVCaptureOutput) -> Task<Void, Never>
	/// Reclaims a suspended output: true when it was still wired (claim
	/// re-taken, connections re-enabled, frames flowing again); false when
	/// the session went down in the meantime and took the wiring with it, so
	/// the caller must attach a fresh output instead.
	@discardableResult func resumeOutput(_ output: AVCaptureOutput) -> Task<Bool, Never>

	/// The preview-layer twin of suspendOutput, for a preview that toggles
	/// while the session runs (the menu-bar camera): disables the layer's
	/// connection and releases its claim, leaving the layer wired - detaching
	/// a layer from the running session is the same graph rebuild as removing
	/// an output, with the same stall. Idempotent.
	@discardableResult func suspendPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Never>
	/// Reclaims a suspended preview layer. Unlike outputs, a layer needs no
	/// recreation, so this subsumes the fresh-attach fallback: still wired -
	/// re-take the claim and re-enable; session gone in the meantime - attach
	/// to the (re)created session, which is warming up behind its placeholder
	/// anyway. Throws only when the session cannot be created at all
	/// (surfaced through onState like every attach).
	@discardableResult func resumePreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Error>
}


/// Queue-confined by design: all mutable state (`session`, `captureDevice`,
/// `attachedObjects`) is only touched on `sessionQueue`; the subjects publish
/// on the main queue. `@unchecked Sendable` documents that discipline rather
/// than adding locks.
final class SRCameraService: NSObject, CameraProviding, @unchecked Sendable {
	static let sharedInstance = SRCameraService()

	fileprivate var cancellables = Set<AnyCancellable>()
	fileprivate var captureDeviceCancellable: AnyCancellable?

    fileprivate var session: AVCaptureSession!
	fileprivate var captureDeviceInput: AVCaptureDeviceInput?

	// The device the user asked for ("" = system default). Mirrors the
	// selectedCameraDeviceID preference, wired by the composition root.
	// Touched only on `sessionQueue`.
	fileprivate var desiredDeviceID: String = ""

	// Whether Automatic prefers an external (display) camera. Mirrors the
	// preferExternalCamera preference; touched only on `sessionQueue`. Default
	// matches the preference default so pre-wiring resolution behaves the same.
	fileprivate var preferExternalCamera: Bool = true

	// While non-nil, the only externals Automatic may auto-prefer (posture's
	// calibration gate, pushed by the composition root). Kept as mirrored
	// state rather than queried at resolve time so a hot-plugged camera is
	// judged against the already-current rule, with no race against the
	// upstream recomputation. Touched only on `sessionQueue`.
	fileprivate var autoSwitchableExternalIDs: Set<String>? = nil

	// Session-only device override (the calibration flow). Beats every other
	// resolution rule while set; never persisted, so a crash mid-calibration
	// self-heals on relaunch. Touched only on `sessionQueue`.
	fileprivate var temporaryDeviceOverrideID: String? = nil


    fileprivate let sessionQueue: DispatchQueue = DispatchQueue(label: "narcissism.camera")

	fileprivate let attachedObjects: NSHashTable<AnyObject> = NSHashTable.weakObjects()

	let onCaptureDeviceAvailable = CurrentValueSubject<Bool, Never>(false)
	let onDevices = CurrentValueSubject<[CameraDevice], Never>([])
	let onSelectedDeviceID = CurrentValueSubject<String, Never>("")

	/// The observable, human-explainable state of the pipeline. Errors that
	/// used to be swallowed (setup throws, runtime notifications, denied
	/// authorization) land here instead.
	let onState = CurrentValueSubject<SRCameraState, Never>(.idle)

	fileprivate let onCaptureSessionRuntimeError = NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification)

	override init() {
        super.init()

		// Ask for camera access up front. Without this the capture session
		// runs but never receives frames (authorization stays notDetermined),
		// so the camera views only ever show the placeholder.
		self.requestCameraAccessIfNeeded { [weak self] authorized in
			guard let self else { return }
			if !authorized {
				self.setState(.unauthorized)
			}

			// Resolve the device once access is decided; availability then
			// reflects real hardware presence and the menu items enable. The
			// composition root then pushes the persisted selection.
			self.sessionQueue.async {
				self.applyDesiredDevice()
				if authorized && self.captureDevice == nil {
					self.updateStateIfIdle(.unavailable)
				}
			}
		}

		self.onCaptureSessionRuntimeError
			.sink { [weak self] notification in
				let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
				NSLog("SRCameraService runtime error: %@", error?.localizedDescription ?? "unknown")
				self?.setState(.failed(error?.localizedDescription ?? NSLocalizedString("camera.error.runtime", comment: "")))
			}
			.store(in: &self.cancellables)

		// Keep the device list current across hot-plug (monitor cameras, USB
		// webcams; a Continuity connect fires this too, but the enumeration
		// filter drops the phone). A (dis)connect may also make the desired
		// device (re)appear or vanish, so re-resolve the active device on
		// each change.
		Publishers.Merge(
			NotificationCenter.default.publisher(for: .AVCaptureDeviceWasConnected),
			NotificationCenter.default.publisher(for: .AVCaptureDeviceWasDisconnected)
		)
		.sink { [weak self] _ in
			guard let self else { return }
			self.refreshDevices()
			self.sessionQueue.async { self.applyDesiredDevice() }
		}
		.store(in: &self.cancellables)

		self.refreshDevices()
    }

	//: ## Device enumeration and selection

	/// Only fixed, user-facing cameras: the built-in and external ones
	/// (monitor cameras, USB webcams). Continuity and Desk View are not
	/// cameras of this app - a phone cannot serve a mirror-plus-posture
	/// app - and the exclusion filters on the isContinuityCamera property,
	/// not device type alone, because a nearby iPhone can enumerate as an
	/// `.external` device and slip past a type check.
	fileprivate func discoveredDevices() -> [AVCaptureDevice] {
		return AVCaptureDevice.DiscoverySession(
			deviceTypes: [.builtInWideAngleCamera, .external],
			mediaType: .video,
			position: .unspecified
		).devices.filter { !$0.isContinuityCamera }
	}

	fileprivate func refreshDevices() {
		// Log the raw enumeration, pre-filter, so how a device presents
		// itself - notably an iPhone claiming `.external` - is observable
		// on real hardware. Fires only on init and hot-plug, so it is cheap.
		let raw = AVCaptureDevice.DiscoverySession(
			deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
			mediaType: .video,
			position: .unspecified
		).devices
		for device in raw {
			NSLog(
				"SRCameraService discovered: %@ type=%@ continuity=%d",
				device.localizedName, device.deviceType.rawValue, device.isContinuityCamera ? 1 : 0
			)
		}

		let devices = self.discoveredDevices().map {
			CameraDevice(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
		}
		DispatchQueue.main.async { self.onDevices.send(devices) }
	}

	/// Resolves the desired id to a device, always within the filtered
	/// enumeration. The temporary override (a live calibration looking
	/// through its target camera) beats everything; then an explicit pick;
	/// then (Automatic, or a pick that has been unplugged) an external
	/// camera when the preference asks for it and the auto-switch set
	/// allows it; else the built-in, else whatever eligible camera remains.
	/// Deliberately never `AVCaptureDevice.default`: macOS points that at a
	/// nearby Continuity Camera, the exact takeover this app bans. A Mac
	/// with no eligible camera resolves nil and reads as unavailable rather
	/// than adopting a phone.
	fileprivate func resolveDevice(id: String) -> AVCaptureDevice? {
		let devices = self.discoveredDevices()
		if let overrideID = self.temporaryDeviceOverrideID,
			let device = devices.first(where: { $0.uniqueID == overrideID }) {
			return device
		}
		if !id.isEmpty, let device = devices.first(where: { $0.uniqueID == id }) {
			return device
		}
		if self.preferExternalCamera,
			let external = devices.first(where: { device in
				device.deviceType == .external
					&& (self.autoSwitchableExternalIDs?.contains(device.uniqueID) ?? true)
			}) {
			return external
		}
		return devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first
	}

	func selectDevice(id: String) {
		self.sessionQueue.async {
			self.desiredDeviceID = id
			self.applyDesiredDevice()
		}
	}

	func setPreferExternalCamera(_ prefer: Bool) {
		self.sessionQueue.async {
			self.preferExternalCamera = prefer
			self.applyDesiredDevice()
		}
	}

	func setAutoSwitchableExternalIDs(_ ids: Set<String>?) {
		self.sessionQueue.async {
			self.autoSwitchableExternalIDs = ids
			self.applyDesiredDevice()
		}
	}

	func setTemporaryDeviceOverride(id: String?) {
		self.sessionQueue.async {
			self.temporaryDeviceOverrideID = id
			self.applyDesiredDevice()
		}
	}

	/// On the session queue: point the capture at whatever `desiredDeviceID`
	/// now resolves to, swapping the running session's input if needed.
	fileprivate func applyDesiredDevice() {
		let device = self.resolveDevice(id: self.desiredDeviceID)
		if device === self.captureDevice {
			return
		}

		self.captureDevice = device

		if let session = self.session, let device = device {
			session.beginConfiguration()
			if let oldInput = self.captureDeviceInput {
				session.removeInput(oldInput)
				self.captureDeviceInput = nil
			}
			if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
				session.addInput(input)
				self.captureDeviceInput = input
				if session.canSetSessionPreset(.hd1920x1080) {
					session.sessionPreset = .hd1920x1080
				}
			}
			session.commitConfiguration()
		}

		let activeID = device?.uniqueID ?? ""
		DispatchQueue.main.async { self.onSelectedDeviceID.send(activeID) }
	}

	/// `onState` is UI-facing, so it always publishes on the main queue -
	/// its subscribers touch main-actor state. Senders may be on the session
	/// queue, the auth callback, or a notification thread.
	fileprivate func setState(_ newState: SRCameraState) {
		if Thread.isMainThread {
			self.onState.send(newState)
		} else {
			DispatchQueue.main.async { self.onState.send(newState) }
		}
	}

	/// Only overwrites transient/idle states, so a hard `.unauthorized` or
	/// `.failed` is not clobbered by a later `.unavailable`/`.idle`.
	fileprivate func updateStateIfIdle(_ newState: SRCameraState) {
		DispatchQueue.main.async {
			switch self.onState.value {
			case .idle, .unavailable, .running:
				self.onState.send(newState)
			case .unauthorized, .failed:
				break
			}
		}
	}

	fileprivate func requestCameraAccessIfNeeded(_ completion: @escaping @Sendable (_ authorized: Bool) -> Void) {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			completion(true)
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .video) { granted in
				completion(granted)
			}
		default:
			// Denied or restricted.
			completion(false)
		}
	}

    deinit {
    }

    var captureDevice: AVCaptureDevice? {
        willSet {
			self.captureDeviceCancellable?.cancel()
			self.captureDeviceCancellable = nil
        }

        didSet {
            if let captureDevice = self.captureDevice {
				self.captureDeviceCancellable = captureDevice.publisher(for: \.isSuspended, options: [.initial, .new])
					.map { !$0 }
					.removeDuplicates()
					.receive(on: DispatchQueue.main)  // subscribers drive AppKit
					.sink { [weak self] in self?.onCaptureDeviceAvailable.send($0) }
            }
        }
    }

    //: ## Session related stuff

	fileprivate func createCaptureSession() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			self.sessionQueue.async {
				if self.session != nil {
					continuation.resume()
					return
				}

				let session = AVCaptureSession()
				session.beginConfiguration()
				session.sessionPreset = .high

				do {
					guard let device = self.captureDevice else {
						continuation.resume(throwing: SRCameraError.noDevice)
						return
					}
					let captureDeviceInput = try AVCaptureDeviceInput(device: device)
					guard session.canAddInput(captureDeviceInput) else {
						continuation.resume(throwing: SRCameraError.cannotAddInput)
						return
					}
					session.addInput(captureDeviceInput)
					self.captureDeviceInput = captureDeviceInput
				} catch {
					continuation.resume(throwing: error)
					return
				}

				// Pin 1080p rather than staying on .high: the generic preset
				// sometimes negotiates the camera's square 1552x1552 format,
				// which a landscape surface then center-crops and upscales -
				// visibly soft. 1920x1080 is this hardware's best landscape
				// format. (Checked after addInput so the device is considered.)
				if session.canSetSessionPreset(.hd1920x1080) {
					session.sessionPreset = .hd1920x1080
				}

				// Note: no outputs are added here. The photo output is attached
				// lazily by SRPhotoCaptureService (adding an AVCapturePhotoOutput
				// during initial session configuration blanks the video preview
				// on current macOS), and the dock tile attaches its own video
				// data output via attachOutput.

				session.commitConfiguration()
				session.startRunning()

				self.session = session

				self.updateStateIfIdle(.running)

				continuation.resume()
			}
		}
	}

	fileprivate func createCaptureSessionIfNeeded() async throws {
		if self.session == nil {
			try await self.createCaptureSession()
		}
	}

	fileprivate func destroyCaptureSession() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			self.sessionQueue.async {
				if self.session != nil {
					if self.session.isRunning {
						self.session.stopRunning()
					}
					self.session = nil
					self.captureDeviceInput = nil

					self.updateStateIfIdle(.idle)
				}

				continuation.resume()
			}
		}
	}

    //: # Public methods

	fileprivate func attachObject(_ object: UncheckedSendable<AnyObject>) async throws {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			self.sessionQueue.async {
				self.attachedObjects.add(object.value)
				continuation.resume()
			}
		}
		do {
			try await self.createCaptureSessionIfNeeded()
		} catch {
			// Every attach flows through here, so this is the one place setup
			// failures need to be surfaced - the callers discard the Task.
			let message = (error as? SRCameraError)?.localizedDescription ?? error.localizedDescription
			self.updateStateIfIdle(.failed(message))
			NSLog("SRCameraService setup error: %@", message)
			throw error
		}
	}

	fileprivate func detachObject(_ object: UncheckedSendable<AnyObject>) async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			self.sessionQueue.async {
				self.attachedObjects.remove(object.value)
				continuation.resume()
			}
		}
		if self.attachedObjects.count == 0 {
			await self.destroyCaptureSession()
		}
	}

	// Attaching PreviewLayer's
    @discardableResult
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Error> {
		let layer = UncheckedSendable(value: layer)
		return Task { [weak self] in
			guard let self else { return }
			try await self.attachObject(UncheckedSendable(value: layer.value))
			self.sessionQueue.sync {
				layer.value.session = self.session
			}
		}
    }

    @discardableResult
    func detachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Never> {
		let layer = UncheckedSendable(value: layer)
		return Task { [weak self] in
			guard let self else { return }
			await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
				self.sessionQueue.async {
					layer.value.session = nil
					c.resume()
				}
			}
			await self.detachObject(UncheckedSendable(value: layer.value))
		}
	}

	// Attaching AVCaptureOutput's
	@discardableResult
	func attachOutput(_ output: AVCaptureOutput) -> Task<Void, Error> {
		let output = UncheckedSendable(value: output)
		return Task { [weak self] in
			guard let self else { return }
			try await self.attachObject(UncheckedSendable(value: output.value))
			self.sessionQueue.sync {
				self.session.beginConfiguration()
				self.session.addOutput(output.value)
				self.session.commitConfiguration()
			}
		}
	}

	@discardableResult
	func detachOutput(_ output: AVCaptureOutput) -> Task<Void, Never> {
		let output = UncheckedSendable(value: output)
		return Task { [weak self] in
			guard let self else { return }
			await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
				self.sessionQueue.async {
					self.session.beginConfiguration()
					self.session.removeOutput(output.value)
					self.session.commitConfiguration()
					c.resume()
				}
			}
			await self.detachObject(UncheckedSendable(value: output.value))
		}
	}

	// Suspending and resuming outputs (the contract lives on the protocol).
	// The isEnabled writes are guarded so a redundant suspend or resume never
	// touches the connection at all: only real toggles were measured
	// stall-free, and a no-op write costs nothing to skip.
	@discardableResult
	func suspendOutput(_ output: AVCaptureOutput) -> Task<Void, Never> {
		let output = UncheckedSendable(value: output)
		return Task { [weak self] in
			guard let self else { return }
			await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
				self.sessionQueue.async {
					for connection in output.value.connections where connection.isEnabled {
						connection.isEnabled = false
					}
					c.resume()
				}
			}
			await self.detachObject(UncheckedSendable(value: output.value))
		}
	}

	@discardableResult
	func resumeOutput(_ output: AVCaptureOutput) -> Task<Bool, Never> {
		let output = UncheckedSendable(value: output)
		return Task { [weak self] in
			guard let self else { return false }
			return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
				self.sessionQueue.async {
					guard let session = self.session, session.outputs.contains(output.value) else {
						c.resume(returning: false)
						return
					}
					self.attachedObjects.add(output.value)
					for connection in output.value.connections where !connection.isEnabled {
						connection.isEnabled = true
					}
					c.resume(returning: true)
				}
			}
		}
	}

	@discardableResult
	func suspendPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Never> {
		let layer = UncheckedSendable(value: layer)
		return Task { [weak self] in
			guard let self else { return }
			await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
				self.sessionQueue.async {
					if let connection = layer.value.connection, connection.isEnabled {
						connection.isEnabled = false
					}
					c.resume()
				}
			}
			await self.detachObject(UncheckedSendable(value: layer.value))
		}
	}

	@discardableResult
	func resumePreviewLayer(_ layer: AVCaptureVideoPreviewLayer) -> Task<Void, Error> {
		let layer = UncheckedSendable(value: layer)
		return Task { [weak self] in
			guard let self else { return }
			try await self.attachObject(UncheckedSendable(value: layer.value))
			self.sessionQueue.sync {
				// A suspended layer still points at the session it was wired
				// to; only rewire when that session is gone (the one path that
				// still rebuilds the graph, against a session warming up).
				if layer.value.session !== self.session {
					layer.value.session = self.session
				}
				if let connection = layer.value.connection, !connection.isEnabled {
					connection.isEnabled = true
				}
			}
		}
	}

}


/// Moves a value the compiler can't prove Sendable across the session-queue
/// boundary; safety comes from the queue discipline documented on
/// SRCameraService, not from this wrapper.
struct UncheckedSendable<T>: @unchecked Sendable {
	let value: T
}


enum SRCameraError: LocalizedError {
	case noDevice
	case cannotAddInput

	var errorDescription: String? {
		switch self {
		case .noDevice:
			return NSLocalizedString("camera.error.no-device", comment: "")
		case .cannotAddInput:
			return NSLocalizedString("camera.error.cannot-add-input", comment: "")
		}
	}
}
