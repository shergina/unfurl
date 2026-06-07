//
//  SRStatisticsDayView.swift
//  Narcissism
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import SwiftUI
import Charts


/// One hour's chart datum: percentages computed from the bucket counts,
/// each over its own denominator (see Posture/spec.md). Nil percent =
/// nothing measurable that hour, drawn as an empty slot, never as zero.
struct SRStatisticsHourStat: Identifiable {
	let hour: Int
	/// The start of this hour, the mark's temporal x position (bars are
	/// binned by .hour, which is what gives them their width).
	let date: Date
	let slouchPercent: Double?
	let shouldersPercent: Double?
	let measuredSeconds: Int
	/// Still in progress, or under the solid floor: drawn dimmed.
	let provisional: Bool
	var id: Int { hour }
}


/// The today page's data: one stat per hour across the measured span
/// (padded one hour each side, clamped to the day).
struct SRStatisticsTodayModel {
	let hours: [SRStatisticsHourStat]
	let hourRange: ClosedRange<Int>
	let totalMeasuredSeconds: Int

	/// Hours with less measured time than this render dimmed: a
	/// percentage over a few minutes is a guess, not a measurement.
	static let solidFloorSeconds = 600

	static func today(in days: [String: SRPostureHistoryDay], dayKey: String, now: Date) -> SRStatisticsTodayModel {
		var buckets: [Int: SRPostureHistoryBucket] = [:]
		for (key, bucket) in days[dayKey]?.hours ?? [:] {
			if let hour = Int(key) { buckets[hour] = bucket }
		}

		let calendar = Calendar.current
		let currentHour = calendar.component(.hour, from: now)
		let measuredHours = buckets.filter { $0.value.measuredSeconds > 0 }.keys
		let total = buckets.values.reduce(0) { $0 + $1.measuredSeconds }
		guard let first = measuredHours.min(), let last = measuredHours.max(), total > 0 else {
			return SRStatisticsTodayModel(hours: [], hourRange: 0...23, totalMeasuredSeconds: 0)
		}

		let range = max(0, min(first, currentHour) - 1)...min(23, max(last, currentHour) + 1)
		let hours = range.map { hour -> SRStatisticsHourStat in
			let bucket = buckets[hour] ?? SRPostureHistoryBucket()
			return SRStatisticsHourStat(
				hour: hour,
				date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now,
				slouchPercent: bucket.slouchMeasurableSeconds > 0
					? Double(bucket.slouchingSeconds) / Double(bucket.slouchMeasurableSeconds) * 100
					: nil,
				shouldersPercent: bucket.measuredSeconds > 0
					? Double(bucket.leftShoulderHighSeconds + bucket.rightShoulderHighSeconds) / Double(bucket.measuredSeconds) * 100
					: nil,
				measuredSeconds: bucket.measuredSeconds,
				provisional: hour == currentHour || (bucket.measuredSeconds > 0 && bucket.measuredSeconds < Self.solidFloorSeconds)
			)
		}
		return SRStatisticsTodayModel(hours: hours, hourRange: range, totalMeasuredSeconds: total)
	}
}


/// The today chart: sustained slouching and uneven shoulders per hour,
/// as percentages of that hour's measured time. Hours without data stay
/// blank on a continuous axis; the in-progress hour and thin hours are
/// dimmed (see spec.md). Redrawn by the hosting controller, never
/// self-updating.
struct SRStatisticsTodayView: View {

	let model: SRStatisticsTodayModel

	var body: some View {
		if model.totalMeasuredSeconds == 0 {
			VStack(spacing: 6) {
				Text(NSLocalizedString("statistics.empty.title", comment: ""))
				Text(NSLocalizedString("statistics.empty.hint", comment: ""))
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			VStack(alignment: .leading, spacing: 4) {
				Text(NSLocalizedString("statistics.today.title", comment: ""))
					.font(.title2.bold())
				Text(String(
					format: NSLocalizedString("statistics.today.tracked", comment: ""),
					SRStatisticsFormatters.duration.string(from: TimeInterval(model.totalMeasuredSeconds)) ?? ""
				))
				.font(.subheadline)
				.foregroundStyle(.secondary)

				chart
					.padding(.top, 12)

				Text(NSLocalizedString("statistics.provisional-note", comment: ""))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.padding(.top, 8)
			}
			.padding(20)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
	}

	fileprivate var chart: some View {
		let slouching = NSLocalizedString("statistics.series.slouching", comment: "")
		let shoulders = NSLocalizedString("statistics.series.shoulders", comment: "")

		return Chart {
			ForEach(model.hours) { stat in
				// The tracked strip: a quiet baseline segment under every
				// hour with measured time, so a clean hour (0 percent, no
				// bar) never looks like an hour that was not tracked at
				// all. Inset from the hour edges to keep a gap per slot.
				if stat.measuredSeconds > 0 {
					RuleMark(
						xStart: .value("Hour", stat.date.addingTimeInterval(300)),
						xEnd: .value("Hour", stat.date.addingTimeInterval(3300)),
						y: .value("Percent", 0)
					)
					.foregroundStyle(Color(nsColor: .tertiaryLabelColor))
					.lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
				}

				if let percent = stat.slouchPercent {
					BarMark(
						x: .value("Hour", stat.date, unit: .hour),
						y: .value("Percent", percent),
						width: .ratio(0.75)
					)
					.position(by: .value("Series", slouching))
					.foregroundStyle(by: .value("Series", slouching))
					.opacity(stat.provisional ? 0.4 : 1)
					.cornerRadius(3)
					.accessibilityLabel("\(slouching), \(Self.hourLabel(stat.hour))")
					.accessibilityValue("\(Int(percent.rounded())) percent")
				}
				if let percent = stat.shouldersPercent {
					BarMark(
						x: .value("Hour", stat.date, unit: .hour),
						y: .value("Percent", percent),
						width: .ratio(0.75)
					)
					.position(by: .value("Series", shoulders))
					.foregroundStyle(by: .value("Series", shoulders))
					.opacity(stat.provisional ? 0.4 : 1)
					.cornerRadius(3)
					.accessibilityLabel("\(shoulders), \(Self.hourLabel(stat.hour))")
					.accessibilityValue("\(Int(percent.rounded())) percent")
				}
			}
		}
		// Fixed per-mode series colors, validated for colorblind
		// separation and surface contrast in light and dark. Deliberately
		// not the user's accent: an accent change must never collide the
		// two series.
		.chartForegroundStyleScale([
			slouching: Color(nsColor: .srStatisticsSlouching),
			shoulders: Color(nsColor: .srStatisticsShoulders),
		])
		.chartLegend(position: .top, alignment: .leading)
		.chartXScale(domain: xDomain)
		.chartYScale(domain: 0...yMax)
		.chartXAxis {
			AxisMarks(values: .stride(by: .hour, count: xTickStep)) { _ in
				AxisGridLine()
				AxisValueLabel(format: .dateTime.hour())
			}
		}
		.chartYAxis {
			AxisMarks { value in
				AxisGridLine()
				AxisValueLabel {
					if let percent = value.as(Double.self) {
						Text("\(Int(percent))%")
					}
				}
			}
		}
	}

	/// From the first shown hour's start to the last shown hour's end.
	fileprivate var xDomain: ClosedRange<Date> {
		let start = model.hours.first?.date ?? Date.now
		let end = (model.hours.last?.date ?? Date.now).addingTimeInterval(3600)
		return start...end
	}

	/// Top of the y axis: the next 10 above the tallest bar, floor 10,
	/// so near-zero days do not stretch noise to full height.
	fileprivate var yMax: Double {
		let top = model.hours
			.flatMap { [$0.slouchPercent, $0.shouldersPercent] }
			.compactMap { $0 }
			.max() ?? 0
		return max(10, (top / 10).rounded(.up) * 10)
	}

	/// Hour ticks thinned so labels never collide on a wide span.
	fileprivate var xTickStep: Int {
		let span = model.hourRange.count
		return span > 12 ? 3 : (span > 8 ? 2 : 1)
	}

	fileprivate static func hourLabel(_ hour: Int) -> String {
		let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date.now) ?? Date.now
		return SRStatisticsFormatters.hour.string(from: date)
	}

}


@MainActor
enum SRStatisticsFormatters {

	/// Locale-aware hour labels ("14" or "2 PM").
	static let hour: DateFormatter = {
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("j")
		return formatter
	}()

	static let duration: DateComponentsFormatter = {
		let formatter = DateComponentsFormatter()
		formatter.allowedUnits = [.hour, .minute]
		formatter.unitsStyle = .abbreviated
		return formatter
	}()

}


extension NSColor {

	// The series colors, one dynamic color per series with its own step
	// per appearance (dark is selected, not a flip of light); the pairs
	// pass the colorblind-separation and contrast checks on both
	// surfaces.
	static let srStatisticsSlouching = NSColor(name: nil) { appearance in
		return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			? NSColor(srgbRed: 0.933, green: 0.302, blue: 0.588, alpha: 1)  // #EE4D96
			: NSColor(srgbRed: 0.969, green: 0.310, blue: 0.620, alpha: 1)  // #F74F9E
	}

	static let srStatisticsShoulders = NSColor(name: nil) { appearance in
		return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			? NSColor(srgbRed: 0.369, green: 0.361, blue: 0.902, alpha: 1)  // #5E5CE6
			: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1)  // #5856D6
	}

}
