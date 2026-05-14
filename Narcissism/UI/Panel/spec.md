# Subsystem Spec: Floating Camera Panel

## Metadata

- **Title**: The floating, resizable camera panel and its control chip.
- **Surface**: floating panel.
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Narcissism/Tools/spec.md` (`SRCameraService` state and preview attach); `Narcissism/SRSettings.swift` (panel preferences).

## Summary

- **What this subsystem is**: a non-activating utility panel that shows the live camera edge to edge with system window chrome, plus a hover-revealed control chip and an explanatory placeholder when there is no feed.
- **One-sentence contract**: the panel is visible exactly when the user wants it (pinned or hovering the status item) and the camera has something to show (a live feed or an error to explain), and it never steals focus.

## Scope

- **In scope**: `SRPanelController` (visibility, placement, ghost mode), `SRPanel` (the `NSPanel`), `SRPanelViewController`, `SRPanelContentView` (camera view, placeholder, chip z-order), `SRPanelToolbarView` (the chip), `SRCameraPlaceholerView`.
- **Constraints / assumptions**:
  - The panel is a non-activating `NSPanel`; clicking it must never activate the app.
  - Hover tracking must work while the app is inactive (tracking areas use `.activeAlways`).
  - Panel size and position persist across launches.

## Responsibilities and ownership

- **Responsibilities**:
  - `SRPanelController`: decide when to show/hide; place the panel; persist frame; own ghost mode (click-through translucency).
  - `SRPanelContentView`: stack the camera view, placeholder, and chip; reveal the chip on hover over a live feed; hide the camera view when not running so the placeholder is interactive; hint that the panel is resizable by setting the matching resize cursor near each edge and corner.
  - `SRPanelToolbarView`: the chip buttons (close, pin, photo, ghost, mirror, menu) as SF Symbols, with active toggles accent-tinted.
  - `SRCameraPlaceholerView`: show the app logo plus a per-state message, and an "Open System Settings" action when access is denied.
- **Owned invariants** (must always hold):
  - `showPanel == (hover || pinned) && (cameraAvailable || cameraState != .idle)`. A denied camera keeps the panel showable so its reason is visible; it does not silently hide.
  - The chip is revealed only while hovering AND `cameraState.isRunning`.
  - The camera view is hidden whenever `cameraState` is not running, so it cannot cover the placeholder or swallow the placeholder's button clicks.
  - Panel frame writes go to `cameraPanelSize` / `cameraPanelPosition` on move and resize.

## Key workflows

### Workflow 1: show and hide

1. `onShouldShowPanel` combines status-item hover, the pin preference, and "has content" (available or a non-idle state), debounced.
2. On rising edge, create the panel and content and order it front (without activating); on falling edge, tear it down.

### Workflow 2: hover reveals the chip

1. `SRPanelContentView` tracks hover with a tracking-area-backed publisher (`mouseHoverPublisher`) and combines it with `SRCameraService.onState`.
2. The chip fades in only when hovering over a running feed; otherwise it stays hidden.

### Workflow 3: camera denied

1. `SRCameraService.onState` becomes `.unauthorized`; the camera view hides and the placeholder shows the message plus the settings button.
2. Tapping the button deep-links to the Camera privacy pane via the modern `com.apple.settings.PrivacySecurity` URL.

### Workflow 4: ghost mode

1. Toggling ghost mode makes the panel click-through (`ignoresMouseEvents`) and semi-transparent.
2. Global/local mouse monitors (installed only while ghosted) fade it to near-invisible while the cursor is over it, back to semi-transparent when it leaves.

## Requirements (what must be true)

### Functional requirements

- Clicking the panel never changes the active app; the panel follows across Spaces and does not appear in the window cycler.
- Pin/ghost/mirror toggles reflect and drive their preferences; the chip's tint tracks them live.
- The placeholder message matches the camera state (denied, unavailable, failed); only denied offers the settings action.

### Non-functional requirements

- **Native fidelity**: chrome is the real `NSPanel` titled/full-size-content chrome (system corners, shadow, resize); the chip is an `NSVisualEffectView` HUD pill with SF Symbols. No hand-drawn window chrome.
- **Concurrency**: main-actor throughout; hover and state publishers deliver on main.
- **Resource cost**: the preview layer tracks the window backing scale so video renders at native resolution, not upscaled.

### Failure modes

- Camera permission denied while pinned.
  - Detection: `onState == .unauthorized`.
  - Expected behavior: panel stays visible showing the message and settings button; chip hidden.

## Design (how it works)

### High-level architecture

- **Components**: `SRPanel` (NSPanel) -> `SRPanelViewController` -> `SRPanelContentView` containing, in z-order, the camera view (bottom), the placeholder, and the chip (top).
- **View hierarchy / z-order**: the camera view sits above the placeholder; it is hidden when not running so the placeholder (and its button) receive events. The chip is topmost.
- **Data flow**: driven by `SRCameraService.onCaptureDeviceAvailable` / `onState` and the panel preferences; publishes nothing except preference writes for frame and toggles.
- **Control flow**: `SRPanelController` creates and destroys the window on demand.

### Interfaces and contracts

- **Public API surface**: `SRPanelController(services:statusItemController:)`, constructed by the app delegate with the status item controller injected explicitly (it reads that controller's `onMouseHover` and uses its view as the panel anchor). `handleCloseButton` (unpins and hides) is reached by the toolbar through `window.windowController`, not a global.
- **Inputs**: status-item hover, panel preferences, camera availability and state.
- **Outputs**: `cameraPanelSize` / `cameraPanelPosition` writes; toggling of pin/ghost/mirror preferences.

## Key design decisions (recorded)

- **Decision**: real `NSPanel` chrome instead of custom layers.
  - Context: a 655-line custom shadow/bevel/border/mask stack with a dated corner radius.
  - Chosen: `[.titled, .fullSizeContentView, .closable, .resizable, .nonactivatingPanel, .utilityWindow]` with a transparent titlebar and hidden traffic lights; the system draws chrome, video runs edge to edge.
- **Decision**: `.activeAlways` tracking areas.
  - Context: with `.activeInActiveApp`, hover only worked while the app was frontmost, so the chip usually never appeared (the app is an inactive agent and the panel is non-activating).
  - Chosen: `.activeAlways`.
- **Decision**: install both of `SRPanelContentView`'s tracking areas once, never bulk-remove.
  - Context: the content view carries two tracking areas over the same rect: the hover area (owned by `mouseHoverPublisher`'s watcher, drives the chip) and the resize-cursor area (owned by the view). Both use `.inVisibleRect`, so AppKit keeps them matched to the view size automatically and neither needs rebuilding on resize. An earlier `updateTrackingAreas()` override rebuilt the resize area with the boilerplate "remove every area, then re-add" recipe, which also tore down the hover area it did not own; the chip then never appeared after the first layout pass.
  - Chosen: add both areas once in `init` and do not override `updateTrackingAreas()`. A view must remove only tracking areas it owns.
- **Decision**: hint resizability with a cursor the app sets itself.
  - Context: `.resizable` performs the resize, but a non-key background panel gets no automatic resize cursor, so the affordance was invisible. macOS ignores a background agent's cursor changes unless `SetsCursorInBackground` is enabled (the same private CoreGraphics call the status item uses, factored into `SRBackgroundCursor`, gated on `USE_UNDOCUMENTED_API`).
  - Chosen: an `.activeAlways` tracking area sets the matching edge/corner resize cursor near the border (the content view fills the panel, so its outer points overlap the resize border); diagonal cursors come from the private `NSCursor` selectors with an arrow fallback. With the flag off, the resize still works, just without the cursor hint.
- **Decision**: hide the camera view when not running.
  - Context: an always-present transparent camera view sat above the placeholder and ate the "Open System Settings" click.
  - Chosen: gate `cameraView.isHidden` on `cameraState.isRunning`.

## Open questions / known limitations

- Placement math assumes the main screen; multi-display is unspecified.
- Ghost mode relies on global mouse monitors; if Input Monitoring is restricted the hover-fade may not fire (the panel stays at its idle translucency).
