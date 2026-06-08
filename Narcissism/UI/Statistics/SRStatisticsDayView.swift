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
	// The raw durations behind the percentages, for the hover tooltip -
	// which is also where the left/right split surfaces (the bar merges
	// the two directions; the tooltip separates them).
	let slouchingSeconds: Int
	let leftHighSeconds: Int
	let rightHighSeconds: Int
	/// Still in progress, or under the solid floor: drawn dimmed.
	let provisional: Bool
	var id: Int { hour }
}


/// One day's chart data: one stat per hour across the measured span
/// (padded one hour each side, clamped to the day).
struct SRStatisticsDayModel {
	let hours: [SRStatisticsHourStat]
	let hourRange: ClosedRange<Int>
	let totalMeasuredSeconds: Int

	/// Hours with less measured time than this render dimmed: a
	/// percentage over a few minutes is a guess, not a measurement.
	static let solidFloorSeconds = 600

	/// `currentHour` is non-nil only for today: it extends the axis span
	/// to now and dims the in-progress hour. Past days are static.
	static func day(in days: [String: SRPostureHistoryDay], key: String, selectedDay: Date, currentHour: Int?) -> SRStatisticsDayModel {
		var buckets: [Int: SRPostureHistoryBucket] = [:]
		for (hourKey, bucket) in days[key]?.hours ?? [:] {
			if let hour = Int(hourKey) { buckets[hour] = bucket }
		}

		let calendar = Calendar.current
		let measuredHours = buckets.filter { $0.value.measuredSeconds > 0 }.keys
		let total = buckets.values.reduce(0) { $0 + $1.measuredSeconds }
		guard let first = measuredHours.min(), let last = measuredHours.max(), total > 0 else {
			return SRStatisticsDayModel(hours: [], hourRange: 0...23, totalMeasuredSeconds: 0)
		}

		let lo = max(0, min(first, currentHour ?? first) - 1)
		let hi = min(23, max(last, currentHour ?? last) + 1)
		let hours = (lo...hi).map { hour -> SRStatisticsHourStat in
			let bucket = buckets[hour] ?? SRPostureHistoryBucket()
			return SRStatisticsHourStat(
				hour: hour,
				date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDay) ?? selectedDay,
				slouchPercent: bucket.slouchMeasurableSeconds > 0
					? Double(bucket.slouchingSeconds) / Double(bucket.slouchMeasurableSeconds) * 100
					: nil,
				shouldersPercent: bucket.measuredSeconds > 0
					? Double(bucket.leftShoulderHighSeconds + bucket.rightShoulderHighSeconds) / Double(bucket.measuredSeconds) * 100
					: nil,
				measuredSeconds: bucket.measuredSeconds,
				slouchingSeconds: bucket.slouchingSeconds,
				leftHighSeconds: bucket.leftShoulderHighSeconds,
				rightHighSeconds: bucket.rightShoulderHighSeconds,
				provisional: hour == currentHour || (bucket.measuredSeconds > 0 && bucket.measuredSeconds < Self.solidFloorSeconds)
			)
		}
		return SRStatisticsDayModel(hours: hours, hourRange: lo...hi, totalMeasuredSeconds: total)
	}
}


/// One cell of the date strip.
struct SRStatisticsDayCell: Identifiable {
	let date: Date
	let key: String
	let hasData: Bool
	var id: String { key }
}


/// Everything the window shows, replaced wholesale by the controller on
/// selection changes and (throttled) data changes.
struct SRStatisticsViewState {
	var strip: [SRStatisticsDayCell]
	var selectedKey: String
	var selectedDate: Date
	var todayDate: Date
	var isToday: Bool
	var day: SRStatisticsDayModel
}


/// The bridge between the AppKit controller and the SwiftUI content: the
/// controller mutates `state`, SwiftUI diffs. The root view stays the
/// same instance across updates, so the strip's scroll position and
/// other view-local state survive the 30-second refreshes.
@MainActor
final class SRStatisticsStore: ObservableObject {
	@Published var state: SRStatisticsViewState
	/// Set by the controller; the strip and the Today button route here.
	var onSelect: ((Date) -> Void)?

	init(state: SRStatisticsViewState) {
		self.state = state
	}
}


/// The statistics window's content: the date strip (today rightmost,
/// back to the first recorded day), then the selected day's hourly
/// chart, or an explanation when the day holds no data (see spec.md).
struct SRStatisticsRootView: View {

	@ObservedObject var store: SRStatisticsStore

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			dateStrip
				.padding(.bottom, 10)

			Text(store.state.isToday
				? NSLocalizedString("statistics.today.title", comment: "")
				: store.state.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
				.font(.title2.bold())

			if store.state.day.totalMeasuredSeconds == 0 {
				emptyDay
			} else {
				Text(String(
					format: NSLocalizedString("statistics.today.tracked", comment: ""),
					SRStatisticsFormatters.duration.string(from: TimeInterval(store.state.day.totalMeasuredSeconds)) ?? ""
				))
				.font(.subheadline)
				.foregroundStyle(.secondary)

				SRStatisticsDayChart(model: store.state.day)
					.padding(.top, 12)

				Text(NSLocalizedString("statistics.provisional-note", comment: ""))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.padding(.top, 8)
			}
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	fileprivate var dateStrip: some View {
		HStack(spacing: 12) {
			ScrollViewReader { proxy in
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 2) {
						ForEach(store.state.strip) { cell in
							SRStatisticsDayCellView(
								cell: cell,
								selected: cell.key == store.state.selectedKey,
								action: { store.onSelect?(cell.date) }
							)
							.id(cell.key)
						}
					}
					.padding(.vertical, 2)
				}
				.onAppear {
					proxy.scrollTo(store.state.selectedKey, anchor: .trailing)
				}
				.onChange(of: store.state.selectedKey) { _, key in
					proxy.scrollTo(key)
				}
			}

			Button(NSLocalizedString("statistics.today-button", comment: "")) {
				store.onSelect?(store.state.todayDate)
			}
			.disabled(store.state.isToday)
		}
	}

	fileprivate var emptyDay: some View {
		VStack(spacing: 6) {
			if store.state.isToday {
				Text(NSLocalizedString("statistics.empty.title", comment: ""))
				Text(NSLocalizedString("statistics.empty.hint", comment: ""))
					.foregroundStyle(.secondary)
			} else {
				Text(String(
					format: NSLocalizedString("statistics.empty.day", comment: ""),
					store.state.selectedDate.formatted(date: .long, time: .omitted)
				))
				.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

}


/// One strip cell: weekday initial over day number. Days without data
/// are shaded light gray (tertiary ink, the native nothing-here
/// treatment) but stay selectable; the selected day wears the accent.
fileprivate struct SRStatisticsDayCellView: View {

	let cell: SRStatisticsDayCell
	let selected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: self.action) {
			VStack(spacing: 3) {
				Text(SRStatisticsFormatters.weekdayInitial.string(from: cell.date))
					.font(.caption2)
					.foregroundStyle(.secondary)
				Text(SRStatisticsFormatters.dayNumber.string(from: cell.date))
					.font(.callout.monospacedDigit())
					.foregroundStyle(self.numberStyle)
					.frame(width: 28, height: 28)
					.background {
						if self.selected {
							Circle().fill(Color.accentColor)
						}
					}
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(cell.date.formatted(date: .long, time: .omitted))
		.accessibilityValue(cell.hasData ? "" : NSLocalizedString("statistics.empty.title", comment: ""))
	}

	fileprivate var numberStyle: AnyShapeStyle {
		if self.selected {
			return AnyShapeStyle(.white)
		}
		return cell.hasData ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
	}

}


/// The hourly chart for one day; pure rendering of the model (the
/// provisional dimming and axis span are decided by the model builder).
struct SRStatisticsDayChart: View {

	let model: SRStatisticsDayModel

	/// The hour under the pointer (only ever a tracked hour). View-local:
	/// it survives the 30-second model refreshes but never drives them.
	@State fileprivate var hoveredHour: Int?

	var body: some View {
		let slouching = NSLocalizedString("statistics.series.slouching", comment: "")
		let shoulders = NSLocalizedString("statistics.series.shoulders", comment: "")

		Chart {
			// The hovered column, highlighted behind the marks; fixed
			// style on purpose, so it never enters the legend.
			if let stat = self.hoveredStat {
				RectangleMark(
					xStart: .value("Hour", stat.date),
					xEnd: .value("Hour", stat.date.addingTimeInterval(3600))
				)
				.foregroundStyle(.quaternary.opacity(0.5))
			}

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
		.chartOverlay { proxy in
			GeometryReader { geometry in
				ZStack(alignment: .topLeading) {
					// The hover surface: the whole plot area, so the hit
					// target is the hour column, never just the thin bars.
					Rectangle()
						.fill(.clear)
						.contentShape(Rectangle())
						.onContinuousHover { phase in
							switch phase {
							case .active(let location):
								self.hoveredHour = self.hour(at: location, proxy: proxy, geometry: geometry)
							case .ended:
								self.hoveredHour = nil
							}
						}

					if let stat = self.hoveredStat {
						self.tooltip(for: stat, proxy: proxy, geometry: geometry)
					}
				}
			}
		}
	}

	fileprivate var hoveredStat: SRStatisticsHourStat? {
		guard let hovered = self.hoveredHour else { return nil }
		return model.hours.first { $0.hour == hovered && $0.measuredSeconds > 0 }
	}

	/// The tracked hour under the pointer, nil over margins or blank slots.
	fileprivate func hour(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
		guard let plotAnchor = proxy.plotFrame else { return nil }
		let plot = geometry[plotAnchor]
		guard plot.contains(location) else { return nil }
		guard let date: Date = proxy.value(atX: location.x - plot.origin.x) else { return nil }
		return Calendar.current.component(.hour, from: date)
	}

	/// The hover card: hour range, tracked time, then each issue's
	/// duration (the left/right shoulder split lives here). Durations,
	/// not percentages - the bars already say the percentages.
	fileprivate func tooltip(for stat: SRStatisticsHourStat, proxy: ChartProxy, geometry: GeometryProxy) -> some View {
		let card = VStack(alignment: .leading, spacing: 3) {
			Text(String(
				format: NSLocalizedString("statistics.tooltip.hours", comment: ""),
				Self.hourLabel(stat.hour), Self.hourLabel(stat.hour + 1)
			))
			.font(.caption.bold())
			Text(String(
				format: NSLocalizedString("statistics.today.tracked", comment: ""),
				SRStatisticsFormatters.shortDuration.string(from: TimeInterval(stat.measuredSeconds)) ?? ""
			))
			.font(.caption)
			.foregroundStyle(.secondary)

			if stat.slouchingSeconds + stat.leftHighSeconds + stat.rightHighSeconds == 0 {
				Text(NSLocalizedString("statistics.tooltip.clean", comment: ""))
					.font(.caption)
			} else {
				if stat.slouchingSeconds > 0 {
					self.tooltipRow("statistics.tooltip.slouching", seconds: stat.slouchingSeconds)
				}
				if stat.leftHighSeconds > 0 {
					self.tooltipRow("statistics.tooltip.left-high", seconds: stat.leftHighSeconds)
				}
				if stat.rightHighSeconds > 0 {
					self.tooltipRow("statistics.tooltip.right-high", seconds: stat.rightHighSeconds)
				}
			}
		}
		.padding(8)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
		.allowsHitTesting(false)  // never steal the hover from the plot

		// Centered over the hovered hour, clamped into the plot.
		let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
		let center = proxy.position(forX: stat.date.addingTimeInterval(1800)) ?? 0
		let x = min(max(plot.origin.x + center, plot.minX + 80), plot.maxX - 80)
		return card.position(x: x, y: plot.minY + 48)
	}

	fileprivate func tooltipRow(_ key: String, seconds: Int) -> some View {
		return Text(String(
			format: NSLocalizedString(key, comment: ""),
			SRStatisticsFormatters.shortDuration.string(from: TimeInterval(seconds)) ?? ""
		))
		.font(.caption)
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

	/// Tooltip durations, down to seconds ("1m 30s", "42s").
	static let shortDuration: DateComponentsFormatter = {
		let formatter = DateComponentsFormatter()
		formatter.allowedUnits = [.hour, .minute, .second]
		formatter.unitsStyle = .abbreviated
		formatter.maximumUnitCount = 2
		return formatter
	}()

	/// Narrow weekday ("M", "T"), for the strip cells.
	static let weekdayInitial: DateFormatter = {
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("EEEEE")
		return formatter
	}()

	static let dayNumber: DateFormatter = {
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("d")
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
