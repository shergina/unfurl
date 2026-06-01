# Home Screen and Onboarding - Product Vision and Roadmap

Status: building. The first increment exists: the Settings window (that
is the decided name) with toolbar tabs - a General page, a Notifications
page with the nudge delay and the three nudge channels, and a
placeholder Statistics tab - specified in spec.md next to this file.
The onboarding flow has started as well: the welcome page (feature 1's
page 1) exists, specified in UI/Welcome/spec.md; its pages 2 and 3 and
the first-run gate are still to come. This document remains the
long-term plan for the rest. Edit it as the design firms up. As pieces
get built, their stable contracts graduate into spec.md files next to
the code; everything here stays vision, not behavioral spec.

Formatting follows the repo spec rules: ASCII only, no tables, compact.

## North star

Narcissism stays a lightweight menu-bar agent, but gains a face. A new
user opens the app and immediately understands what it is, where it
lives, and what it can do. An existing user has one window where every
capability is visible, explained, and configurable. The menu stays the
quick path; the home window is the deep path.

## Non-negotiables

- Privacy: everything on-device, including any posture history stored for
  statistics. Nothing leaves the Mac, ever.
- One capture session: any camera preview in these windows attaches to
  the shared SRCameraService session and reuses SRCameraView plus
  SRCameraPlaceholerView. A denied or unavailable camera shows an
  explanation, never a blank frame.
- System primitives: the home window is a normal NSWindow with an
  NSTabViewController in toolbar style (the System Settings look). No
  hand-rolled tab bar.
- The app stays an LSUIElement agent. Windows appear the way the About
  window does (makeKeyAndOrderFront plus NSApp.activate), without
  touching the activation policy that SRDockTileController owns.

## Feature 1: first-run onboarding

A small paged window shown the first time the app launches. Three pages
with a Next button between them:

1. Welcome. A few words about what Narcissism is, plus the privacy
   statement: runs 100 percent on your Mac, the camera never leaves the
   device.
2. Tutorial. A button that points out Narcissism in the menu bar (flash
   the status item or briefly open its menu), and a short description of
   each function: camera panel, hover to peek, menu bar camera, dock
   tile, photos, ghost mode, hotkeys.
3. Posture. What posture tracking does, one privacy reminder, and an
   offer to preset measurements now. Accepting routes into the existing
   calibration flow (and later the height/age questionnaire from the
   posture vision). Skippable.

Finishing lands the user on the home window. First run is detected with
a new persisted preference (HasCompletedOnboarding). The tutorial must
be re-runnable later from the home window or the menu, so the content is
not lost after first launch.

## Feature 2: the home window (now the Settings window)

One window, pages switched in the top panel (toolbar tabs). Built so
far (see spec.md):

- General. Track Posture, Show Camera Panel, Show Camera in Menu Bar,
  Open at Login.
- Posture. The baseline status and the Calibrate Posture button; the
  natural home for baseline staleness hints later.
- Notifications. The nudge delay (how long bad posture persists before
  a nudge), the three channels: corner note, sound (with a pick-and
  preview beep list), menu bar icon lighting up - and the snooze, the
  same durations the menu offers.
- Statistics. A placeholder tab reserving the spot.

Still planned:

- Photos. Live camera preview, Take Photo, mirror toggle, camera source
  picker (Automatic plus the device list), where photos are saved.
- Visibility and Appearance. The three camera surfaces (menu bar,
  floating panel, dock tile) as toggles with one-line explanations,
  hover to peek, ghost mode. What else appearance covers is an open
  question.
- Statistics, for real. Today: time in good posture out of tracked
  time. Breakdown: slouching vs raised-shoulder events and how often
  nudges fired. Trends: charts over recent weeks showing whether
  posture is improving. Needs the history store below.
- General additions. The hotkey cheat sheet (Ctrl+Opt+Cmd C/P/M/N),
  maybe rebindable hotkeys later (SRHotKeyController already
  anticipates this), maybe About and version info folded in. System
  notifications stay the reserve nudge channel from the posture
  vision.

## The big new piece: posture history store

Statistics need data, and today nothing persists; posture metrics go
only to the unified log. Plan: a small on-device store fed by the
posture service's once-per-second status, aggregated into per-day
buckets (seconds good and bad per issue, nudge counts). Raw per-second
samples are never kept long-term, only aggregates. Consequence for
ordering: start recording history early, well before the statistics page
ships, so the page has data on day one.

## How this fits the existing architecture

- New window controllers follow the About and calibration precedent: a
  single lazily created instance owned by one place, dropped on close.
- Wiring happens in the composition root, like every other surface.
- New SRSettings preferences drive behavior through Combine, same as
  today.
- The menu gains an item to open the home window.

## Roadmap

Each phase ships with its spec.md updates.

1. Done: the Settings window shell with General, Notifications, and the
   Statistics placeholder; the nudge delay and channels behind it.
2. Photos page and the Visibility and Appearance page. No new storage.
3. Onboarding flow and first-run detection.
4. Posture history store (start recording early).
5. Posture Statistics page over the accumulated history.

## Open questions (decide before or during build, do not guess)

- What appearance covers beyond the posture note style.
- Whether note style settings live on Notifications or on Visibility
  and Appearance.
- History retention window and the exact aggregates to keep.
- Whether About and a future check-for-updates fold into the Settings
  window (an unused "Check for update..." string already exists in the
  app).
- Whether onboarding reuses the Settings window or is its own window.
- Whether the menu slims down now that the Settings window exists.
- What else Photos grows to include (format, destination picker).
