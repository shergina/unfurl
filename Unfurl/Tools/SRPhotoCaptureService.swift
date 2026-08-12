//
//  SRPhotoCaptureService.swift
//  Unfurl
//
//  Created by Maria Shergina on 25/10/26.
//  Copyright © 2026 Maria Shergina. All rights reserved.
//

import Cocoa
@preconcurrency import AVFoundation
@preconcurrency import UserNotifications

@MainActor
class SRPhotoCaptureService: NSObject {

	static let sharedInstance = SRPhotoCaptureService()

	let cameraService = SRCameraService.sharedInstance

	// Created on first capture and attached to the running session. Attaching
	// lazily (rather than at session creation) keeps the video preview intact.
	fileprivate var photoOutput: AVCapturePhotoOutput?

	// Keeps capture delegates alive until AVFoundation finishes with them.
	fileprivate var inflightCaptures = Set<PhotoCaptureDelegate>()

	func capture(_ completion: ((NSError?) -> ())? = nil) {
		NSSound(named: "Grab.aif")?.play()

		// Task inherits the main-actor context, so state and the completion
		// closure stay on the main actor; only the awaited steps hop off.
		Task {
			do {
				let data = try await self.capturePhotoData()
				let fileURL = try await Self.savePhotoData(data)
				self.showNotificationForImage(fileURL: fileURL)
				completion?(nil)
			} catch {
				completion?(error as NSError)
			}
		}
	}

	fileprivate func capturePhotoData() async throws -> Data {
		let photoOutput: AVCapturePhotoOutput
		if let existing = self.photoOutput {
			photoOutput = existing
		} else {
			photoOutput = AVCapturePhotoOutput()
			self.photoOutput = photoOutput
			do {
				try await self.cameraService.attachOutput(photoOutput).value
			} catch {
				self.photoOutput = nil
				throw error
			}
		}

		let delegate = PhotoCaptureDelegate()
		self.inflightCaptures.insert(delegate)
		defer { self.inflightCaptures.remove(delegate) }

		return try await withCheckedThrowingContinuation { continuation in
			delegate.onFinish = { data, error in
				if let data {
					continuation.resume(returning: data)
				} else {
					continuation.resume(throwing: error ?? NSError(domain: "unfurl.photo", code: -3, userInfo: nil))
				}
			}
			photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
		}
	}

	fileprivate nonisolated static func savePhotoData(_ data: Data) async throws -> URL {
		let directoryURL = try FileManager.default.url(
			for: .picturesDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)

		let dateFormatter = DateFormatter()
		dateFormatter.dateStyle = .medium
		dateFormatter.timeStyle = .medium
		dateFormatter.timeZone = TimeZone.current

		let dateString = dateFormatter.string(from: Date())
		let fileURL = directoryURL.appendingPathComponent("Unfurl Camera Photo (\(dateString)).jpg", isDirectory: false)
		try data.write(to: fileURL, options: [.atomic])
		return fileURL
	}

	func showNotificationForImage(fileURL: URL) {
		let content = UNMutableNotificationContent()
		content.title = NSLocalizedString("notification.photo-was-saved.title", comment: "")
		content.subtitle = NSLocalizedString("notification.photo-was-saved.subtitle", comment: "")
		content.body = NSLocalizedString("notification.photo-was-saved.message", comment: "")

		let center = UNUserNotificationCenter.current()
		// Without authorization the notification is silently dropped.
		center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
			guard granted else { return }
			let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
			center.add(request, withCompletionHandler: nil)
		}
	}
}


/// One-shot delegate for AVCapturePhotoOutput.capturePhoto. AVFoundation only
/// holds it weakly, so SRPhotoCaptureService keeps it in `inflightCaptures`
/// until the capture completes.
fileprivate final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

	// Set once on the main actor before the capture starts; read once from
	// AVFoundation's delegate queue when the photo arrives.
	var onFinish: (@Sendable (Data?, Error?) -> Void)?

	func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		self.onFinish?(photo.fileDataRepresentation(), error)
	}
}
