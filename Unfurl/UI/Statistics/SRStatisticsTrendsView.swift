//
//  SRStatisticsTrendsView.swift
//  Unfurl
//
//  Copyright (c) 2026 Maria Shergina. All rights reserved.
//

import SwiftUI
import Charts


/// One week's point on a trend line. `run` numbers stretches of
/// consecutive tracked weeks: the line breaks at untracked weeks
/// instead of drawing data that does not exist.
struct SRStatisticsTrendPoint: Identifiable {
	let weekStart: Date
	let percent: Double
	let run: Int
	/// The week still in progress, or under the solid floor: dimmed.
	let provisional: Bool
	var id: Date { weekStart }
}


/// The week-by-week trends: each issue as a percentage of that week's
/// time, summed across the week before dividing (the same per-issue
/// denominators as the day chart, so a week always agrees with its
/// days).
struct SRStatisticsTrendsModel {
	let slouching: [SRStatisticsTrendPoint]
	let shoulders: [SRStatisticsTrendPoint]
	/// Weeks with any measured time at all.
	let weekCount: Int

	/// Weeks with less measured time than this render dimmed.
	static let solidFloorSeconds = 3600

	@MainActor
	static func trends(in days: [String: SRPostureHistoryDay], now: Date) -> SRStatisticsTrendsModel {
		struct WeekTotals {
			var measured = 0
			var slouchMeasurable = 0
			var slouching = 0
			var shouldersHigh = 0
		}

		let calendar = Calendar.current
		var totals: [Date: WeekTotals] = [:]
		for (key, day) in days {
			guard
				let date = SRPostureHistoryService.day(forKey: key),
				let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start
			else { continue }
			var weekTotals = totals[week] ?? WeekTotals()
			for bucket in day.hours.values {
				weekTotals.measured += bucket.measuredSeconds
				weekTotals.slouchMeasurable += bucket.slouchMeasurableSeconds
				weekTotals.slouching += bucket.slouchingSeconds
				weekTotals.shouldersHigh += bucket.leftShoulderHighSeconds + bucket.rightShoulderHighSeconds
			}
			totals[week] = weekTotals
		}

		let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
		let weeks = totals.filter { $0.value.measured > 0 }.keys.sorted()

		var slouching: [SRStatisticsTrendPoint] = []
		var shoulders: [SRStatisticsTrendPoint] = []
		var run = 0
		var previousWeek: Date?
		for week in weeks {
			if let previous = previousWeek,
				calendar.date(byAdding: .weekOfYear, value: 1, to: previous) != week {
				run += 1
			}
			previousWeek = week

			let weekTotals = totals[week]!
			let provisional = week == currentWeek || weekTotals.measured < Self.solidFloorSeconds
			if weekTotals.slouchMeasurable > 0 {
				slouching.append(SRStatisticsTrendPoint(
					weekStart: week,
					percent: Double(weekTotals.slouching) / Double(weekTotals.slouchMeasurable) * 100,
					run: run,
					provisional: provisional
				))
			}
			shoulders.append(SRStatisticsTrendPoint(
				weekStart: week,
				percent: Double(weekTotals.shouldersHigh) / Double(weekTotals.measured) * 100,
				run: run,
				provisional: provisional
			))
		}

		return SRStatisticsTrendsModel(slouching: slouching, shoulders: shoulders, weekCount: weeks.count)
	}
}


/// The Trends page: the two issues week by week as a multiline chart,
/// same series colors as the day chart (color follows the entity across
/// views). One tracked week draws its dots with an explanation; only
/// zero data shows a message instead of a chart (see spec.md).
struct SRStatisticsTrendsView: View {

	let model: SRStatisticsTrendsModel

	var body: some View {
		if model.weekCount == 0 {
			Text(NSLocalizedString("statistics.trends.empty", comment: ""))
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			VStack(alignment: .leading, spacing: 4) {
				Text(NSLocalizedString("statistics.trends.title", comment: ""))
					.font(.title2.bold())
				Text(model.weekCount == 1
					? NSLocalizedString("statistics.trends.weeks.one", comment: "")
					: String(format: NSLocalizedString("statistics.trends.weeks.many", comment: ""), model.weekCount))
					.font(.subheadline)
					.foregroundStyle(.secondary)

				chart
					.padding(.top, 12)

				Text(model.weekCount == 1
					? NSLocalizedString("statistics.trends.one-week", comment: "")
					: NSLocalizedString("statistics.trends.note", comment: ""))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.padding(.top, 8)
			}
		}
	}

	fileprivate var chart: some View {
		let slouching = NSLocalizedString("statistics.series.slouching", comment: "")
		let shoulders = NSLocalizedString("statistics.series.shoulders", comment: "")

		return Chart {
			ForEach(model.slouching) { point in
				LineMark(
					x: .value("Week", point.weekStart),
					y: .value("Percent", point.percent),
					series: .value("Run", "slouching-\(point.run)")
				)
				.foregroundStyle(by: .value("Series", slouching))
				PointMark(
					x: .value("Week", point.weekStart),
					y: .value("Percent", point.percent)
				)
				.foregroundStyle(by: .value("Series", slouching))
				.opacity(point.provisional ? 0.4 : 1)
				.accessibilityLabel("\(slouching), \(Self.weekLabel(point.weekStart))")
				.accessibilityValue("\(Int(point.percent.rounded())) percent")
			}
			ForEach(model.shoulders) { point in
				LineMark(
					x: .value("Week", point.weekStart),
					y: .value("Percent", point.percent),
					series: .value("Run", "shoulders-\(point.run)")
				)
				.foregroundStyle(by: .value("Series", shoulders))
				PointMark(
					x: .value("Week", point.weekStart),
					y: .value("Percent", point.percent)
				)
				.foregroundStyle(by: .value("Series", shoulders))
				.opacity(point.provisional ? 0.4 : 1)
				.accessibilityLabel("\(shoulders), \(Self.weekLabel(point.weekStart))")
				.accessibilityValue("\(Int(point.percent.rounded())) percent")
			}
		}
		.chartForegroundStyleScale([
			slouching: Color(nsColor: .srStatisticsSlouching),
			shoulders: Color(nsColor: .srStatisticsShoulders),
		])
		.chartLegend(position: .top, alignment: .leading)
		.chartXScale(domain: xDomain)
		.chartYScale(domain: 0...yMax)
		.chartXAxis {
			AxisMarks(values: xTickValues) { _ in
				AxisGridLine()
				AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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

	/// Air on each side, so edge points never sit on the plot border and an
	/// edge label keeps room to draw. A fraction of the span rather than a
	/// fixed half week: the room a label needs is measured in points, and
	/// over a year's range half a week is only a few of them, so the last
	/// label runs into the axis. Floored at half a week so short histories
	/// still get a little air.
	fileprivate var xDomain: ClosedRange<Date> {
		let weeks = model.shoulders.map { $0.weekStart }
		let first = weeks.first ?? Date.now
		let last = weeks.last ?? Date.now
		let pad = max(3.5 * 86400, last.timeIntervalSince(first) * 0.045)
		return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
	}

	/// The weeks that carry a label, walked back from the most recent one.
	/// Anchoring on the newest week means it always gets a label - it is
	/// the week the user cares about - and every label lands on a week that
	/// actually has a point. Striding by calendar instead counted from the
	/// domain start, which put the first label out on the padding boundary:
	/// an empty labelled gridline sitting to the left of where the lines
	/// began (2026-08-17).
	fileprivate var xTickValues: [Date] {
		let weeks = model.shoulders.map { $0.weekStart }
		guard !weeks.isEmpty else { return [] }
		// The newest week deliberately carries no label: it sits hard against
		// the plot's trailing edge with no room for one, which is what
		// truncated "Aug 16" to "Au...". Nothing is lost - it is the
		// in-progress week, drawn dimmed and named by the footnote, and the
		// right edge of a trend chart already reads as now. Widening the
		// padding until the label fit was the alternative, and it costs plot
		// width on both sides forever to serve one label. Under three weeks
		// there is room to spare, so nothing is dropped.
		let labelled = weeks.count >= 3 ? Array(weeks.dropLast()) : weeks
		return stride(from: 0, to: labelled.count, by: self.xTickStep).map { labelled[$0] }
	}

	fileprivate var yMax: Double {
		let top = (model.slouching + model.shoulders).map { $0.percent }.max() ?? 0
		return max(10, (top / 10).rounded(.up) * 10)
	}

	/// Weeks between axis labels. Roughly six or seven land on the axis,
	/// which is what the fixed 640pt window fits at this label width.
	fileprivate var xTickStep: Int {
		return max(1, model.weekCount / 6)
	}

	fileprivate static func weekLabel(_ week: Date) -> String {
		return week.formatted(date: .abbreviated, time: .omitted)
	}

}
