# Subsystem Spec: Status Item

## Metadata

- **Title**: The menu-bar camera item and its click-to-menu behavior.
- **Surface**: status item (menu bar).
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Narcissism/Tools/spec.md` (`SRCameraService`); `Narcissism/UI/Menu/` (the menu opened on click); `Narcissism/SRSettings.swift` (`showCameraOnStatusBar`, `statusItemWithCameraWidth`).

## Summary

- **What this subsystem is**: the always-present menu-bar item. It hosts a custom view that shows either the live camera (scrollable by mouse position), an icon, or an "unavailable" icon, and opens the status menu on click.
- **One-sentence contract**: the item reflects the show-camera-in-menu-bar preference and camera availability, is resizable by drag, and reliably opens the menu when clicked.

## Scope

- **In scope**: `SRStatusItemController` (the `NSStatusItem`, hosting, click-to-menu), `SRStatusItemView` (content switching, width), `SRStatusItemCameraView` + `SRScrollCameraView` (live camera with mouse-driven vertical scroll and drag-to-resize), `SRStatusItemIconView` variants, `SRStatusBarButton`.
- **Constraints / assumptions**:
  - The custom view is hosted inside `statusItem.button` under Auto Layout; width is driven by `NSStatusItem.length`, never by manipulating frames.
  - Clicking must open the menu whether the current content is the icon or the live camera view.
  - The camera preview must render at native resolution.
  - Showing the resize cursor over the camera item requires a private CoreGraphics call (see the design decision below), gated on the `USE_UNDOCUMENTED_API` build flag.

## Responsibilities and ownership

- **Responsibilities**:
  - Host the custom view in the status button with a pinned height and length-driven width.
  - Switch content among camera / icon / unavailable based on the preference and device availability (debounced).
  - Open the status menu on click; light the item while the menu is open.
  - `SRScrollCameraView`: scroll the tall camera layer vertically as the mouse moves; drag on the item resizes it within limits and persists the width.
- **Owned invariants** (must always hold):
  - Width flows through `statusItem.length`; the hosted view has an explicit height constraint (menu-bar thickness) so the button never collapses when a zero-intrinsic-height camera view is installed.
  - Content class is: camera when show-in-menu-bar is on and the device is available; unavailable-icon when on but device is not available; plain icon when off.
  - Resize is clamped to `SRSettings.statusItemWidthRange` and written to `statusItemWithCameraWidth` on gesture end.

## Key workflows

### Workflow 1: content switching

1. Combine `onCaptureDeviceAvailable` with `showCameraOnStatusBar`, debounced.
2. Choose the content class and cross-fade to it; update `statusItem.length` to the new content's intrinsic width.

### Workflow 2: click opens the menu

1. A click gesture (or the button action) calls the controller.
2. The controller asks the menu subsystem for the status menu, sets it on the status item, performs the click to pop it, then clears it; the item is lit while open.

### Workflow 3: drag to resize the camera

1. A pan gesture on the camera view maps horizontal drag to a new width, clamped to the allowed range.
2. On gesture end, the width is written to the preference.

## Requirements (what must be true)

### Functional requirements

- The item is present for the process lifetime and removed on termination.
- Clicking opens the menu in every content mode; the item lights while the menu is open.
- The camera view scrolls with mouse position and can be resized by dragging.

### Non-functional requirements

- **Native fidelity**: width via `NSStatusItem.length`; the view lives in `statusItem.button` (not the deprecated `statusItem.view`).
- **Concurrency**: main-actor; mouse-position updates arrive via a shared mouse watcher and are applied on the main actor.
- **Resource cost**: the preview layer tracks the window backing scale for native-resolution video.

### Failure modes

- Camera unavailable while show-in-menu-bar is on.
  - Detection: `onCaptureDeviceAvailable == false`.
  - Expected behavior: the unavailable-icon content shows; clicking still opens the menu.

## Design (how it works)

### High-level architecture

- **Components**: `SRStatusItemController` owns the `NSStatusItem` and hosts `SRStatusItemView`, which swaps `SRStatusItemContentView` subclasses (`SRStatusItemCameraView` with `SRScrollCameraView`, `SRStatusItemIconView` / `...Unavailable`).
- **Data flow**: driven by `SRCameraService.onCaptureDeviceAvailable` and `showCameraOnStatusBar`; writes `statusItemWithCameraWidth`.
- **Control flow**: created by the app delegate; removes its status item on `willTerminate`.

### Interfaces and contracts

- **Public API surface**: `SRStatusItemController` and its `onMouseHover` (consumed by the panel to decide hover-show).
- **Inputs**: camera availability, the two status-item preferences, mouse position (`SRMouseWatcher`).
- **Outputs**: `statusItemWithCameraWidth`; `onMouseHover`; opens the shared menu.

## Key design decisions (recorded)

- **Decision**: drive width with `statusItem.length` and pin an explicit height.
  - Context: leftover `statusItem.view`-era frame manipulation fought Auto Layout in the button; with no height constraint the button collapsed to zero height when the camera view (zero intrinsic height) was installed, which broke both the feed and click handling.
  - Chosen: length-driven width, explicit menu-bar-thickness height, no manual frame changes.
- **Decision**: fix `currentEvent` handling when opening the menu.
  - Context: menu construction force-unwrapped `NSApplication.shared.currentEvent`, which is nil for non-mouse (accessibility/synthetic) activation, trapping the app.
  - Chosen: read modifier flags safely.
- **Decision**: show the horizontal resize cursor via a private CoreGraphics SPI, gated on `USE_UNDOCUMENTED_API`.
  - Context: the camera item is drag-to-resize, so the resize cursor is the right affordance. But macOS only lets the active app set the cursor, and this is an `LSUIElement` agent that is never active; `NSCursor` push/pop, `set()`, and `.cursorUpdate` tracking areas are all ignored over the menu bar. The only mechanism that works is setting the private `SetsCursorInBackground` connection property (`_CGSDefaultConnection` + `CGSSetConnectionProperty`), resolved via `dlsym` to avoid a bridging header.
  - Chosen: opt into the private call, shipped in all configurations including App Store. The app has passed App Store review with this API before. The call and its symbol names are gated on the `USE_UNDOCUMENTED_API` Swift flag (defined in `Narcissim-Shared.xcconfig` for every configuration), which is the single switch to compile out all deliberate undocumented-API use; removing the flag drops it everywhere in one move.

## Open questions / known limitations

- The mouse-driven scroll uses screen-relative mouse position via a shared global watcher; multi-display behavior is unspecified.
- The resize cursor depends on a private, undocumented CoreGraphics property; a future macOS may change or remove it, in which case the cursor silently reverts to the arrow (no functional impact, the drag still works). If a future review ever rejects it, flip `USE_UNDOCUMENTED_API` off.
