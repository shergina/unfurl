# Subsystem Spec: Statistics Window

## Metadata

- **Title**: The Statistics window, a standalone placeholder until the posture history store exists.
- **Surface**: a standard titled window, shown from the menu's "Statistics..." item.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/UI/Menu/spec.md` (owner and entry point); `Narcissism/UI/Settings/VISION.md` (the statistics plan and the history store that will feed this window); `Narcissism/Posture/spec.md` (the metrics the statistics will aggregate).

## Summary

- **What this subsystem is**: the window reserved for posture statistics: today a placeholder line, later the charts over the posture history store (VISION.md).
- **One-sentence contract**: the window displays; it owns no preferences, touches no camera, and has no side effects.

## Recorded decisions

- Statistics is its own window, not a Settings tab (decided 2026-07-28, the same day a home-window experiment was tried and reversed): settings are things you set and leave, statistics are things you check and revisit, and neither framing served the other. The brief home-window variant (app-named window, Statistics tab first, fixed page size, opened at launch) is fully reverted; no window opens at launch besides the first-run welcome flow.
- Sized 640 x 480 from the start: the future charts want more room than the settings pages, and the placeholder holding the final frame avoids a resize surprise later.
- Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy.
- `SRMenuController` owns the single kept instance (the Settings precedent).

## Requirements

- **Native fidelity**: a plain titled window, system fonts.
- **Concurrency**: main-actor throughout.

## Open questions

- The statistics content and layout. The history store now records (SRPostureHistoryService, Posture/spec.md): hourly second counts ready for the planned hour-of-day bar chart and calendar heatmap. Untracked hours and days must render as no-data (blank or gray slots on a continuous axis), never as zero - 0 percent is an achievement, absence is nothing - and percentages with a small measured denominator (under ~10 minutes) should be de-emphasized or annotated rather than shown at full strength.
- Whether the window becomes resizable once charts land.
