# Subsystem Spec: Statistics Window

## Metadata

- **Title**: The Statistics window, a standalone placeholder until the posture history store exists.
- **Surface**: a standard titled window, shown from the menu's "Statistics..." item.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/UI/Menu/spec.md` (owner and entry point); `Narcissism/UI/Settings/VISION.md` (the statistics plan and the history store that will feed this window); `Narcissism/Posture/spec.md` (the metrics the statistics will aggregate).

## Summary

- **What this subsystem is**: the posture statistics window. First increment (2026-07-29): today's hourly chart - sustained slouching and uneven shoulders as percentages of each hour's measured time, drawn with Swift Charts over the history store's live counts. Later: the calendar heatmap and multi-day averages (VISION.md).
- **One-sentence contract**: the window renders the history store read-only; it owns no preferences, touches no camera, and has no side effects.

## Recorded decisions

- The chart reads SRPostureHistoryService.days (the live in-memory counts), never the JSON file: the file is durability and lags up to a minute; the UI and the service share a process.
- Redraw cadence: fresh on every window appearance, then at most one redraw per 30 seconds, from the service's onChange publisher through a Combine throttle. Statistics is the reflective surface (the corner note is the live one); per-second movement would turn it into a monitoring dashboard and make thin hours twitch. A closed window skips redraws and catches up on reopen, which is also what rolls the chart to a new day.
- Percentages are computed at display time, each issue over its own denominator: slouching over slouch-measurable seconds, shoulders over measured seconds. Hours with nothing measurable draw no mark - absence on a continuous axis, never a zero bar. The axis spans first-measured to current hour, padded one hour each side, clamped to the day.
- Bars are binned temporally (Date x values, .hour unit): a quantitative hour axis gives grouped bars no band step to size against, and they collapse to invisible slivers (found 2026-07-29).
- A quiet baseline strip (tertiary label color) underlines every tracked hour: a clean hour draws a 0 percent bar, which is zero pixels tall, and without the strip it would be indistinguishable from an hour that was never tracked. Strip with no bar = clean; nothing = untracked. The footnote explains both the strip and the dimming.
- Provisional rendering: the in-progress hour and any hour under ten minutes measured draw dimmed (0.4 opacity), with a footnote explaining the dimming. A partial hour is a guess, not a measurement, and the sustained-run rule's retroactive credit can visibly jump a thin bar.
- Series colors are fixed dynamic colors, one step per appearance (light #F74F9E/#5856D6, dark #EE4D96/#5E5CE6), validated for colorblind separation (deutan dE >= 13) and 3:1 surface contrast in both modes. Deliberately not the user's accent: an accent change must never repaint a series into the other one.
- No data at all today shows an explanation ("no data yet, turn on Track Posture"), never an empty chart.

- Statistics is its own window, not a Settings tab (decided 2026-07-28, the same day a home-window experiment was tried and reversed): settings are things you set and leave, statistics are things you check and revisit, and neither framing served the other. The brief home-window variant (app-named window, Statistics tab first, fixed page size, opened at launch) is fully reverted; no window opens at launch besides the first-run welcome flow.
- Sized 640 x 480 from the start: the future charts want more room than the settings pages, and the placeholder holding the final frame avoids a resize surprise later.
- Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy.
- `SRMenuController` owns the single kept instance (the Settings precedent).

## Requirements

- **Native fidelity**: a plain titled window, system fonts.
- **Concurrency**: main-actor throughout.

## Open questions

- The calendar heatmap and multi-day views (percentages as sum of numerators over sum of denominators across days, never averaged percentages).
- Hover tooltips (per-hour detail: minutes tracked, per-issue seconds); skipped in the first increment.
- Whether the window becomes resizable now that it has real content.
