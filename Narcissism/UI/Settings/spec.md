# Subsystem Spec: Settings Window

## Metadata

- **Title**: The Settings window with toolbar-style tab pages.
- **Surface**: a standard titled window, shown from the menu's "Settings..." item.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/SRSettings.swift` (every control binds a preference); `Narcissism/UI/Menu/spec.md` (owner and entry point); `Narcissism/Posture/spec.md` (the nudge settings this window edits); `VISION.md` next to this file (the long-term home-screen/onboarding plan).

## Summary

- **What this subsystem is**: the app's one configuration window: a normal `NSWindow` whose content is an `NSTabViewController` in toolbar style (the System Settings look), with a General page, a Posture page, a Notifications page, and a placeholder Statistics page.
- **One-sentence contract**: every control reflects its bound preference live and writes it back on change; the window has no side effects beyond preferences and the calibration funnel.

## Scope

- **In scope**: `SRSettingsWindowController` (window + tabs), `SRSettingsGeneralViewController`, `SRSettingsNotificationsViewController`, `SRSettingsStatisticsViewController`, and the two-way binding controls in `SRSettingsControls.swift` (`SRPreferenceSwitch`, `SRPreferenceCheckbox`).
- **Constraints / assumptions**:
  - Shown via the About-window recipe (`makeKeyAndOrderFront` plus `NSApp.activate`) plus `orderFrontRegardless`, never by changing the activation policy - that stays owned by the Dock tile controller. The regardless-ordering matters: with the Dock tile off the policy is `.prohibited`, activation is refused, and without it the window opens behind the active app. It is a one-time jump to the front, not a floating level; other windows cover it normally afterwards.
  - No page attaches to the camera session yet; the window consumes nothing from `SRCameraService`.

## Responsibilities and ownership

- **Responsibilities**:
  - General page: Track Posture switch, Show Camera Panel switch (`cameraPanelPinned`), Show Camera in Menu Bar switch (`showCameraOnStatusBar`), Open at Login switch (`launchAtLogin`).
  - Posture page: the baseline status line ("Calibrated <date>" from `PostureBaselineDate`, or "Not calibrated" while the ratio sentinel is <= 0) and the Calibrate Posture button (enabled only while tracking is on, routed through the owner's calibration funnel; its row spans the grid centered, because a labelless button in the controls column reads as stranded).
  - Notifications page: the nudge delay popup (5 s / 10 s / 30 s / 1 m / 5 m writing `PostureNudgeDelaySeconds`; an off-list stored value selects the closest step), the three channel checkboxes (corner note, sound, status-item tint), the sound picker (enabled only while the sound channel is on; selecting persists the name and plays it once as a preview), and the snooze popup, rebuilt on every deadline change to mirror the menu's states: idle it shows "Off" over the durations; while snoozed it shows an inert "Until <time>" state line, the durations, and an explicit Resume Now item, so turning a snooze off is always one visible choice away. The popup is enabled only while Track Posture is on, because with tracking off the composition root clears any snooze write immediately (the master toggle means a clean slate).
  - Statistics page: a placeholder line only; it reserves the tab until the posture history store exists (see VISION.md).
  - The window title follows the selected tab, like System Settings.
- **Owned invariants**:
  - Controls bind to raw preferences; camera availability is deliberately not consulted here. This page configures intent; the surfaces themselves explain an unavailable camera. (The menu makes the opposite choice and gates on availability; both are recorded decisions.)
  - A preference change made anywhere else (menu, hotkey) updates the visible control live, and vice versa - the menu and this window can be open at once and never disagree.
  - `SRMenuController` owns the single instance (the About precedent) and keeps it across closes, so the window and its selected tab survive reopening.
  - The Calibrate button behaves exactly like the menu's Calibrate item: clear any snooze, then the one shared calibration funnel, so a second calibration window can never appear.

## Requirements

- **Native fidelity**: real `NSTabViewController` toolbar tabs, SF Symbol tab icons, `NSSwitch`/checkbox/popup system controls; window `toolbarStyle` is `.preference`.
- **Concurrency**: main-actor throughout; bindings ride the preference publishers.

## Open questions

- What an "appearance" section should cover beyond the posture note style, and whether note style lives on Notifications or a future Visibility and Appearance page.
- Statistics content and layout once the history store exists.
- Whether About (and a future check-for-updates) folds into this window.
