# Subsystem Spec: Status Menu

## Metadata

- **Title**: The shared status/Dock menu and its reactive item bindings.
- **Surface**: status menu (shown from the status item, the panel chip's menu button, and as the Dock menu).
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Narcissism/SRSettings.swift` (every toggle binds a preference); `Narcissism/Tools/spec.md` (`onCaptureDeviceAvailable` gates enabled state).

## Summary

- **What this subsystem is**: one menu, built once and reused, whose items bind their checked/enabled/visible state to preference and camera-availability publishers and whose actions toggle preferences or invoke commands.
- **One-sentence contract**: each menu item's visible state always reflects its bound publishers, and its action performs exactly the bound command.

## Scope

- **In scope**: `SRMenuController` (the shared `SRMenuController.sharedInstance`), `NSMenuItemWithClosure` (closure-action item that binds publishers to state), and the menu variants for status bar, toolbar, and Dock.
- **Constraints / assumptions**:
  - The menu is created once; the status-bar and toolbar variants return the same menu, the Dock variant returns a filtered copy.
  - `autoenablesItems` is off; enabled state is driven only by bound publishers.

## Responsibilities and ownership

- **Responsibilities**:
  - Build the menu: Track Posture (first, so the posture opt-in leads the list; see `Narcissism/Posture/spec.md`), the posture Snooze submenu, Calibrate Posture, Take Photo, the camera-display toggles, mirror, ghost mode, the Camera source submenu, launch-at-login, Settings, About, Quit.
  - Bind each item's checked/enabled/visible to publishers via `createMenuItem`.
  - Display the global-shortcut glyph on items that have one (Take Photo, Show Camera Panel, Mirror), reading the key equivalents from `SRHotKeyController` so they match what fires.
  - Rebuild the Camera submenu (device list plus an "Automatic" option) whenever the connected devices or the stored selection change.
  - Provide `menuForStatusBar`, `menuForToolbar`, `menuForDock`.
- **Owned invariants** (must always hold):
  - A toggle item is checked exactly when its bound preference publisher is true; camera-dependent items are enabled exactly when `onCaptureDeviceAvailable` is true.
  - In the Camera submenu, exactly one item carries the checkmark: it follows the stored `selectedCameraDeviceID` preference (the option the user picked - "Automatic" when "", else the matching device), not the live active device.
  - Ghost mode is also reachable from the menu because a ghosted (click-through) panel cannot be operated from its own chip; the menu is the escape hatch.
  - A key equivalent shown here is display-only: the status/Dock menu is not the main menu, so it is matched only while the menu is open. The shortcut fires globally through `SRHotKeyController`; the glyph and the hot key are kept in sync by reading the same constants.
  - Quit is visible only in the status-bar/toolbar variants.
  - The posture Snooze item is visible exactly when Track Posture's checked state is (preference on and a camera available). Its submenu items write the snooze deadline preference; while a deadline is pending the item title names it ("Snoozed Until ...") and a Resume Now item appears. The menu never runs snooze logic itself; the composition root owns the resume timer (see `Narcissism/Posture/spec.md`).
  - Calibrate Posture shares the Snooze visibility rule. Its action clears the snooze deadline (a deliberate resume) and presents the calibration window. The menu controller owns that window (the About precedent) and never creates a second one; the composition root's no-baseline auto-open funnels through the same method. While the welcome flow's posture page is up, that page is the one calibration surface and the funnel re-fronts the welcome window instead (`Narcissism/UI/Welcome/spec.md`).
  - The menu controller also owns the single Settings window (`Narcissism/UI/Settings/spec.md`), kept across closes so the selected tab survives reopening; the Settings item presents or re-fronts it. The window's Calibrate button routes back through the same calibration funnel.
  - The menu controller also owns the single welcome window (`Narcissism/UI/Welcome/spec.md`), presented by the composition root at launch through `showWelcome()`; no menu item triggers it yet. It carries the composition root's `onLocateStatusItem` closure into the window, so the welcome surface reaches the status item only through this explicit wiring.

## Key workflows

### Workflow 1: build and bind

1. `createMenu` (run once) adds each item through `createMenuItem`, passing optional `checked` / `enabled` / `visible` publishers and an action closure.
2. Each publisher is subscribed with the item retained as a subscriber; the item updates its state on every emission.

### Workflow 2: open

1. A surface calls `menuForStatusBar` / `menuForToolbar` / `menuForDock`.
2. Quit visibility is set for the variant; the Dock variant returns a filtered copy, the others return the shared menu.

### Workflow 3: choose a camera

1. The Camera parent item holds a submenu subscribed to `SRCameraService.onDevices` combined with the `selectedCameraDeviceID` preference; each emission rebuilds the submenu ("Automatic", a separator, then one item per connected device) with the checkmark on the item matching the preference.
2. Selecting an item writes `selectedCameraDeviceID` (device `uniqueID`, or "" for Automatic). The menu does not talk to the camera directly; the composition root translates that preference into `camera.selectDevice(id:)`.

## Requirements (what must be true)

### Functional requirements

- Toggling any item flips its preference, and the checkmark tracks the change live (a change made elsewhere updates the item too).
- Camera-dependent items disable when no device is available.
- The three menu variants share item definitions; only Quit visibility and Dock filtering differ.

### Non-functional requirements

- **Concurrency**: main-actor; all bound publishers deliver on main.
- **Native fidelity**: item titles are localized; toggles use standard checkmarks.

## Design (how it works)

### Interfaces and contracts

- **Public API surface**: `SRMenuController.sharedInstance`; `menuForStatusBar`, `menuForToolbar`, `menuForDock`.
- **Inputs**: typed preference publishers; `onCaptureDeviceAvailable`; the current modifier flags at open time.
- **Outputs**: preference toggles, the Settings window, the About window, application termination.

## Key design decisions (recorded)

- **Decision**: bind items to typed preference publishers.
  - Context: an earlier `Any`-typed settings store seeded every preference with `false` through a bridging bug, so every checkmark and every enabled state read wrong and every menu feature silently broke. The failure was invisible because nothing was type-checked.
  - Chosen: items bind to `Preference<Bool>.publisher`; a type mismatch is now a compile error, and the menu is the most visible consumer that proves the fix.
