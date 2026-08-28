# Subsystem Spec: Statistics Window

## Metadata

- **Title**: The Statistics window, a standalone placeholder until the posture history store exists.
- **Surface**: a standard titled window, shown from the menu's "Statistics..." item.
- **Actor isolation**: main-actor.
- **Related code**: `Unfurl/UI/Menu/spec.md` (owner and entry point); `Unfurl/UI/Settings/VISION.md` (the statistics plan and the history store that will feed this window); `Unfurl/Posture/spec.md` (the metrics the statistics will aggregate).

## Summary

- **What this subsystem is**: the posture statistics window, two pages behind a segmented picker. Day: a horizontal date strip (today rightmost, back to the first recorded day) over the selected day's hourly chart. Trends: the two issues week by week as a multiline chart. Both draw with Swift Charts over the history store's live counts.
- **One-sentence contract**: the window renders the history store read-only; it owns no preferences, touches no camera, and has no side effects.

## Recorded decisions

- First open centers on the interaction screen, the pointer's screen at the menu click (the app-wide placement rule, see UI/Settings/spec.md); the kept instance keeps the user's placement on reopen.
- The chart reads SRPostureHistoryService.days (the live in-memory counts), never the JSON file: the file is durability and lags up to a minute; the UI and the service share a process.
- Redraw cadence: fresh on every window appearance, then at most one redraw per 30 seconds, from the service's onChange publisher through a Combine throttle. Statistics is the reflective surface (the corner note is the live one); per-second movement would turn it into a monitoring dashboard and make thin hours twitch. A closed window skips redraws and catches up on reopen, which is also what rolls the chart to a new day.
- Percentages are computed at display time, each issue over its own denominator: slouching over slouch-measurable seconds, shoulders over measured seconds. Hours with nothing measurable draw no mark - absence on a continuous axis, never a zero bar. The axis spans first-measured to current hour, padded one hour each side, clamped to the day.
- Bars are binned temporally (Date x values, .hour unit): a quantitative hour axis gives grouped bars no band step to size against, and they collapse to invisible slivers (found 2026-07-29).
- A quiet baseline strip (tertiary label color) underlines every tracked hour: a clean hour draws a 0 percent bar, which is zero pixels tall, and without the strip it would be indistinguishable from an hour that was never tracked. Strip with no bar = clean; nothing = untracked. The footnote explains both the strip and the dimming.
- Provisional rendering: the in-progress hour and any hour under ten minutes measured draw dimmed (0.4 opacity), with a footnote explaining the dimming. A partial hour is a guess, not a measurement, and the sustained-run rule's retroactive credit can visibly jump a thin bar.
- Series colors are fixed dynamic colors, one step per appearance (light #F74F9E/#5856D6, dark #EE4D96/#5E5CE6), validated for colorblind separation (deutan dE >= 13) and 3:1 surface contrast in both modes. Deliberately not the user's accent: an accent change must never repaint a series into the other one.
- No data at all today shows an explanation ("no data yet, turn on Track Posture"), never an empty chart.
- The date strip (2026-07-29, the Health cycle-strip pattern): weekday initial over day number, today rightmost, spanning back to the earliest recorded day - the actual data span, not the retention window. Days without data are shaded light gray (tertiary ink, the native nothing-here treatment - a filled gray cell would read as selection) but stay selectable; picking one shows "There is no posture data for <date>" with the date locale-formatted. Today's empty state keeps the turn-on-tracking hint; a past day's does not (the past cannot be retroactively tracked).
- Selection: accent-tinted circle (selection semantics, so the user accent is correct here, unlike the series colors). A Today button snaps back, disabled while today is selected; left/right arrow keys step one day, clamped to the strip's span. Every window open resets to today.
- Past days are static: the current-hour provisional dimming applies only to today (the model builder gets currentHour only then); the 30-second refresh cadence is unchanged and simply finds nothing new on past days.
- The AppKit controller owns selection and refresh; state flows through an ObservableObject store into one long-lived SwiftUI root view, so a refresh never resets the strip's scroll position (replacing the root view wholesale would).
- Trends page (2026-07-29): one point per calendar week (local first-weekday), each issue summed across the week before dividing, with the same per-issue denominators as the day chart (slouching over slouch-measurable, shoulders over measured) so a week always agrees with its days. Lines break at untracked weeks - a line across a gap would fabricate data - implemented as consecutive-week runs in separate line series sharing one legend entry. Points for the in-progress week or weeks under an hour of measured time draw dimmed. Same series colors as the day chart: color follows the entity across views.
- Trends x axis (2026-08-17): labels land on real weeks, walked forward from the oldest at the tick step, and the newest week deliberately carries none. It sits hard against the plot's trailing edge with no room for a label, which made Charts truncate it - the axis read "Au..." instead of "Aug 16" once history reached about two months. Nothing is lost by dropping it: it is the in-progress week, drawn dimmed and named by the footnote, and the right edge of a trend chart already reads as now. Two alternatives were tried and rejected in the same session. Thinning the labels to at most six (rounding the step up) fixed the truncation but halved the axis density for no reason beyond one edge label. Widening the domain padding also fixed it, but spends plot width on both sides forever to serve that same label - and while the labels came from a calendar stride, the wider padding moved the first label onto the padding boundary, putting a labelled gridline on a week with no point: an empty cell to the left of where the lines began. Explicit tick values on real weeks is what removed that second failure. Domain padding is a fraction of the span (floored at half a week) rather than fixed days, because the room a label needs is measured in points: at a year's range half a week is only a few. Found while staging App Store screenshots, but the truncation was a real bug on the path every retained user walks. The window does not resize, so the axis has to fit the width it is given.
- Trends footnote names the denominator (2026-08-17): both footnote variants lead with "Each point is the share of that week's tracked time." The axis is labelled 0-40% but said nothing about the base, and Trends has no equivalent of the Day tab's "7h 1m tracked" subtitle to infer it from, so 40% could be read as 40% of the week or of work hours. Deliberately loose about which tracked time: the two series divide by different denominators, and the Day tab's tooltip already serves raw durations for anyone who wants that precision. Put in the footnote rather than a rotated y axis title - Apple's own charts carry units on tick labels and meaning in surrounding text, and rotated text would also cost width the fixed window cannot spare.
- Vertical grid lines on the Trends x axis are kept (2026-08-17), against the observation that Apple's system charts grid only the value axis. Considered and declined; revisit only with a reason beyond convention.
- Sparse trends (2026-07-29): one tracked week draws its dots plus a caption saying lines appear as weeks accumulate - real data is never hidden behind a come-back-later message. Only zero recorded data shows a message instead of the chart.
- The Day/Trends picker is view-local state in the root view: it survives refreshes, resets to Day when the window reopens, and the controller does not know about it (arrow keys still step the day selection even from Trends, harmlessly).
- Hover tooltips (2026-07-29): hovering any tracked hour highlights the column (the whole column is the hit target, never just the thin bars) and shows a material card - hour range, tracked time, then per-issue durations. Durations, not percentages: the bars already say the percentages. This is where the left/right shoulder split surfaces (the bar merges the directions), and a tracked hour with no issues says "No sustained issues". Blank hours show nothing - they are blank on purpose. The hover state is view-local and survives the 30-second refreshes.

- Statistics is its own window, not a Settings tab (decided 2026-07-28, the same day a home-window experiment was tried and reversed): settings are things you set and leave, statistics are things you check and revisit, and neither framing served the other. The brief home-window variant (app-named window, Statistics tab first, fixed page size, opened at launch) is fully reverted; no window opens at launch besides the first-run welcome flow.
- Sized 640 x 480 from the start: the future charts want more room than the settings pages, and the placeholder holding the final frame avoids a resize surprise later.
- Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy.
- `SRMenuController` owns the single kept instance (the Settings precedent).

## Requirements

- **Native fidelity**: a plain titled window, system fonts.
- **Concurrency**: main-actor throughout.

## Open questions

- Whether a month-grid heatmap joins the strip once months of data exist.
- Hover on the trends chart (crosshair plus per-week detail), matching the day chart's tooltips.
- Month orientation in the strip (labels at month boundaries, click-to-jump): scrolling far back currently relies on the selected date title.
- Whether the window becomes resizable now that it has real content.
