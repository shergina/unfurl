//
//  SRPostureHistoryService.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import Cocoa
import Combine
import os


/// The posture history store: turns the probe's per-window samples into
/// per-day, per-hour aggregate counts and persists them as JSON in
/// Application Support. This is the data the Statistics window will draw;
/// recording starts well before that window can draw it, so the charts
/// have history on day one (UI/Settings/VISION.md). Aggregates only:
/// no frames, landmarks, or raw samples are ever kept.
///
/// Slouching and misaligned-shoulder seconds count only within sustained
/// runs: a breach must hold `qualifySeconds` before it counts at all
/// (then its whole run counts, from its first breaching second), brief
/// gaps inside a run are tolerated but never counted themselves, and a
/// run that dies before qualifying contributes nothing. Transient
/// movement - reaching for a cup, stretching, turning to talk - never
/// reaches the threshold, because the harm in bad posture is in holding
/// it, not passing through it. These are measurement constants,
/// deliberately independent of the notification nudge delay: changing
/// notification preferences must never rewrite history.
@MainActor
final class SRPostureHistoryService {

	static let sharedInstance = SRPostureHistoryService()

	/// A breach run counts only once it has held this many seconds.
	/// Lowered from 15 on 2026-07-30: a slouch that held to the default
	/// nudge delay should also be on the record. Still a fixed constant,
	/// deliberately never the nudge-delay preference.
	nonisolated static let qualifySeconds = 10
	/// Non-breaching seconds tolerated inside a run before it ends.
	nonisolated static let gapToleranceSeconds = 2
	/// A pause between samples longer than this resets every run: the
	/// probe stopped (toggle, snooze, sleep, camera loss) and whatever
	/// comes next is a fresh sitting.
	fileprivate nonisolated static let sampleContinuitySeconds: TimeInterval = 5
	/// Days older than this are pruned when the file loads.
	fileprivate nonisolated static let retentionDays = 366
	/// Unsaved counts flush to disk at most this often (plus at quit).
	fileprivate nonisolated static let flushInterval: TimeInterval = 60

	fileprivate nonisolated static let logger = Logger(subsystem: "com.shergin.narcissism", category: "PostureHistory")

	/// Fires whenever the counts change: once per recorded sample, and
	/// once when the loaded file merges in. Consumers throttle to their
	/// own cadence (the Statistics window redraws at most every 30 s);
	/// nothing in the app renders per-emission.
	let onChange = PassthroughSubject<Void, Never>()

	fileprivate var history = SRPostureHistory()
	fileprivate var runs: [SRPostureIssue: SustainedRun] = [:]
	fileprivate var lastSampleDate: Date?
	fileprivate var dirty = false
	fileprivate var lastFlushDate: Date?
	fileprivate var cancellables = Set<AnyCancellable>()

	init(posture: SRPostureAnalysisService = .sharedInstance) {
		posture.onWindowSample
			.sink { [unowned self] sample in self.record(sample) }
			.store(in: &self.cancellables)

		// Load previous sessions off the main thread; anything recorded
		// before the load lands is merged in (buckets are sums, so the
		// merge is an add, order-independent).
		let url = Self.fileURL
		Task { [weak self] in
			guard let loaded = await Task.detached(operation: { SRPostureHistory.load(from: url) }).value else { return }
			self?.merge(loaded)
		}
	}

	/// The recorded days, for the Statistics window. Keys are local-day
	/// strings ("2026-07-28"); see SRPostureHistoryDay.
	var days: [String: SRPostureHistoryDay] {
		return self.history.days
	}

	/// The key `days` uses for a date (local calendar day).
	static func dayKey(for date: Date) -> String {
		return self.dayKeyFormatter.string(from: date)
	}

	/// The inverse of dayKey: the day a key names, at its local midnight.
	static func day(forKey key: String) -> Date? {
		return self.dayKeyFormatter.date(from: key)
	}

	/// Synchronous write, for application termination only; every other
	/// flush happens off the main thread.
	func flushNow() {
		guard self.dirty else { return }
		self.dirty = false
		self.history.save(to: Self.fileURL)
	}

	//: ## Recording

	fileprivate func record(_ sample: SRPostureWindowSample) {
		// A probe restart is a fresh sitting: no run survives it.
		if let last = self.lastSampleDate, sample.timestamp.timeIntervalSince(last) > Self.sampleContinuitySeconds {
			self.runs = [:]
		}
		self.lastSampleDate = sample.timestamp

		if sample.visible {
			self.count(\.measuredSeconds, at: sample.timestamp)
			if sample.slouchMeasurable {
				self.count(\.slouchMeasurableSeconds, at: sample.timestamp)
			}
		}

		self.advanceRun(.slouching, breaching: sample.visible && sample.slouching, at: sample.timestamp)
		self.advanceRun(.leftShoulderHigh, breaching: sample.visible && sample.leftShoulderHigh, at: sample.timestamp)
		self.advanceRun(.rightShoulderHigh, breaching: sample.visible && sample.rightShoulderHigh, at: sample.timestamp)

		self.onChange.send()
		self.flushIfDue(at: sample.timestamp)
	}

	fileprivate func advanceRun(_ issue: SRPostureIssue, breaching: Bool, at timestamp: Date) {
		var run = self.runs[issue] ?? SustainedRun()
		defer { self.runs[issue] = run }

		if breaching {
			run.gapSeconds = 0
			if run.qualified {
				self.count(Self.bucketField(for: issue), at: timestamp)
			} else {
				run.pending.append(timestamp)
				if run.pending.count >= Self.qualifySeconds {
					// The run just proved itself: credit it from its first
					// breaching second, then count live from here on.
					run.qualified = true
					for pended in run.pending {
						self.count(Self.bucketField(for: issue), at: pended)
					}
					run.pending = []
				}
			}
		} else if run.qualified || !run.pending.isEmpty {
			// Gap seconds are never counted toward the issue, only
			// tolerated; a run that dies unqualified contributes nothing.
			run.gapSeconds += 1
			if run.gapSeconds > Self.gapToleranceSeconds {
				run = SustainedRun()
			}
		}
	}

	fileprivate nonisolated static func bucketField(for issue: SRPostureIssue) -> WritableKeyPath<SRPostureHistoryBucket, Int> {
		switch issue {
		case .slouching: return \.slouchingSeconds
		case .leftShoulderHigh: return \.leftShoulderHighSeconds
		case .rightShoulderHigh: return \.rightShoulderHighSeconds
		}
	}

	/// Adds one second to a field of the bucket the timestamp falls in
	/// (local calendar day and hour). Windows are ~1 s, so one window is
	/// counted as one second.
	fileprivate func count(_ field: WritableKeyPath<SRPostureHistoryBucket, Int>, at timestamp: Date) {
		let day = Self.dayKeyFormatter.string(from: timestamp)
		let hour = String(Calendar.current.component(.hour, from: timestamp))
		self.history.days[day, default: SRPostureHistoryDay()].hours[hour, default: SRPostureHistoryBucket()][keyPath: field] += 1
		self.dirty = true
	}

	fileprivate static let dayKeyFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd"
		return formatter
	}()

	//: ## Persistence

	fileprivate nonisolated static var fileURL: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return support.appendingPathComponent("PostureHistory.json")
	}

	fileprivate func merge(_ loaded: SRPostureHistory) {
		var merged = loaded
		if let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date.now) {
			merged.prune(before: Self.dayKeyFormatter.string(from: cutoffDate))
		}
		for (day, dayRecord) in self.history.days {
			for (hour, bucket) in dayRecord.hours {
				merged.days[day, default: SRPostureHistoryDay()].hours[hour, default: SRPostureHistoryBucket()].add(bucket)
			}
		}
		self.history = merged
		self.onChange.send()
	}

	fileprivate func flushIfDue(at timestamp: Date) {
		guard self.dirty else { return }
		if let last = self.lastFlushDate, timestamp.timeIntervalSince(last) < Self.flushInterval { return }
		self.lastFlushDate = timestamp
		self.dirty = false

		let snapshot = self.history
		let url = Self.fileURL
		Task.detached { snapshot.save(to: url) }
	}

}


/// The history file's format: one record per local day, one bucket per
/// hour of that day, sparse (untracked days and hours are simply absent -
/// the charts render absence as no-data, never as zero).
struct SRPostureHistory: Codable, Sendable {
	var version = 1
	/// Keyed "yyyy-MM-dd" (local calendar), so keys sort chronologically.
	var days: [String: SRPostureHistoryDay] = [:]

	/// Drops days before the cutoff key. Day keys sort as dates.
	mutating func prune(before cutoff: String) {
		self.days = self.days.filter { $0.key >= cutoff }
	}

	nonisolated static func load(from url: URL) -> SRPostureHistory? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		do {
			let data = try Data(contentsOf: url)
			return try JSONDecoder().decode(SRPostureHistory.self, from: data)
		} catch {
			// A corrupt file is logged and left in place; recording starts
			// a fresh in-memory history and overwrites at the next flush.
			SRPostureHistoryService.logger.error("Could not load the posture history: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	nonisolated func save(to url: URL) {
		do {
			let data = try JSONEncoder().encode(self)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try data.write(to: url, options: .atomic)
		} catch {
			SRPostureHistoryService.logger.error("Could not save the posture history: \(error.localizedDescription, privacy: .public)")
		}
	}
}


struct SRPostureHistoryDay: Codable, Sendable {
	/// Keyed by local hour, "0"..."23", sparse.
	var hours: [String: SRPostureHistoryBucket] = [:]
}


/// One hour's counts, all in seconds. Counts are stored, never ratios:
/// percentages are computed at display time (sum of numerators over sum
/// of denominators), so short sessions weigh what they measured and
/// nothing more. slouching/left/right count only sustained runs (see
/// SRPostureHistoryService); the two denominators differ because the
/// slouch ratio needs the eyes while the tilt needs only the shoulders.
struct SRPostureHistoryBucket: Codable, Sendable {
	var measuredSeconds = 0
	var slouchMeasurableSeconds = 0
	var slouchingSeconds = 0
	var leftShoulderHighSeconds = 0
	var rightShoulderHighSeconds = 0

	mutating func add(_ other: SRPostureHistoryBucket) {
		self.measuredSeconds += other.measuredSeconds
		self.slouchMeasurableSeconds += other.slouchMeasurableSeconds
		self.slouchingSeconds += other.slouchingSeconds
		self.leftShoulderHighSeconds += other.leftShoulderHighSeconds
		self.rightShoulderHighSeconds += other.rightShoulderHighSeconds
	}
}


/// One issue's sustained-run state, advanced once per window sample.
fileprivate struct SustainedRun {
	/// Breaching seconds not yet credited (the run has not qualified).
	var pending: [Date] = []
	var qualified = false
	var gapSeconds = 0
}
