# Subsystem Spec: Status Item

## Metadata

- **Title**: The menu-bar camera item and its click-to-menu behavior.
- **Surface**: status item (menu bar).
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Narcissism/Tools/spec.md` (`SRCameraService`); `Narcissism/UI/Menu/` (the menu opened on click); `Narcissism/SRSettings.swift` (`showCameraOnStatusBar`; `defaultStatusItemCameraWidth`, `allowedStatusItemCameraWidthRange`).

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
  - Posture tint channel: while a posture issue is voiced and the `PostureStatusItemTint` preference is on, the item lights up - the icon swaps to a pre-tinted orange copy, the live camera gets an orange border. The pre-tinted copy is deliberate: `NSStatusBarButton` renders template images through the menu bar's own styling, and a `contentTintColor` blanks the image instead of tinting it. The alert state is forwarded to whichever content view is current and re-applied on every content swap. Best-effort ambient state (see `Narcissism/Posture/spec.md`), never load-bearing: the item can be hidden by the notch or a crowded bar.
  - `SRScrollCameraView`: scroll the tall camera layer vertically as the mouse moves; drag on the item resizes it within limits and persists the width.
- **Owned invariants** (must always hold):
  - Width flows through `statusItem.length`; the hosted view has an explicit height constraint (menu-bar thickness) so the button never collapses when a zero-intrinsic-height camera view is installed.
  - Content class is: camera when show-in-menu-bar is on and the device is available; unavailable-icon when on but device is not available; plain icon when off.
  - The camera width is session-only: the camera view is created at the `SRSettings.defaultStatusItemCameraWidth` constant (not a persisted preference) on every launch and the width is never saved, so a previous run's resize has no effect on relaunch.
  - The camera view's width is set once at creation and never re-set from the content path afterward; re-setting the width after the preview layer attaches blanks the feed. Over-widening is bounded only during a drag.
  - Drag resize is bounded below by `allowedStatusItemCameraWidthRange.lowerBound` and above by `maximumCameraWidth()` (a screen-scaled cap, see Workflow 4). The resulting width is not persisted.

## Key workflows

### Workflow 1: content switching

1. Combine `onCaptureDeviceAvailable` with `showCameraOnStatusBar`, debounced.
2. Choose the content class and cross-fade to it; update `statusItem.length` to the new content's intrinsic width.

### Workflow 2: click opens the menu

1. A click gesture (or the button action) calls the controller.
2. The controller asks the menu subsystem for the status menu, sets it on the status item, performs the click to pop it, then clears it; the item is lit while open.

### Workflow 3: drag to resize the camera (session-only)

1. A pan gesture on the camera view maps horizontal drag to a new width, bounded below by `allowedStatusItemCameraWidthRange.lowerBound` and above by `maximumCameraWidth()`, so the item follows the mouse within those bounds.
2. The new width applies to the live item immediately. It is NOT persisted: quitting and relaunching resets to the default width. Dragging is the only place width changes after creation.

### Workflow 4: bound drag width to the display size (screen-scaled)

1. `maximumCameraWidth()` = `(screen width - notch width) / maxCameraWidthScreenDivisor`, clamped to `allowedStatusItemCameraWidthRange`. Notch width is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (0 on displays without a notch), so one formula covers notched and non-notched displays and scales with the screen: wider display -> wider allowed camera. (On the built-in notched laptop probed: `(1470 - 179) / 20 = 64`.)
2. It is consulted ONLY by the drag handler (Workflow 3). The launch/content path does not clamp - the camera view keeps its birth width - because re-setting the width after the preview layer attaches blanks the feed.
3. This is a heuristic cap, not a guarantee: it does not know about the green camera-in-use indicator or other apps' items (unmeasurable), so a wide drag on a crowded bar can still be hidden by macOS. A conservative divisor keeps the cap small enough that this is rare. A reactive detect-and-recover approach was ruled out - no reliable "am I hidden" signal was found, and resizing post-creation blanks the feed.

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
- **Data flow**: driven by `SRCameraService.onCaptureDeviceAvailable` and `showCameraOnStatusBar`; the camera width is a session-only constant and is not persisted.
- **Control flow**: created by the app delegate; removes its status item on `willTerminate`.

### Interfaces and contracts

- **Public API surface**: `SRStatusItemController` and its `onMouseHover` (consumed by the panel to decide hover-show).
- **Inputs**: camera availability, the two status-item preferences, the posture status and tint preference, mouse position (`SRMouseWatcher`).
- **Outputs**: `onMouseHover`; opens the shared menu.

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

## Key design decisions (recorded, continued)

- **Decision**: the camera width is session-only and clamped only during a drag, not at launch.
  - Context: width was a persisted preference re-applied at birth, so a previous run's over-stretch (which tucks the item under the notch and hides it) was remembered and the item stayed blank on relaunch. Separately, clamping the width at launch meant the camera view was created at the saved (possibly too-wide) width and then resized; re-setting the width after the preview layer attaches blanks the feed - the view renders only when created once at its birth width and left alone.
  - Chosen: create the camera view at the `SRSettings.defaultStatusItemCameraWidth` constant every launch and never persist or re-clamp it from the content path. Bound over-widening purely in the drag handler, which clamps to `maximumCameraWidth()` - a screen-scaled cap `(screen width - notch width) / maxCameraWidthScreenDivisor` (Workflow 4). This keeps the render path (create-once, never-resize) that actually works, and makes relaunch deterministic. Earlier attempts were removed: a polling feedback loop that stepped the width (laggy, depended on an unconfirmed hidden-state signal); a launch-time geometric clamp (blanked the feed by resizing post-creation); and a notch-position/chrome-based drag cap (the real obstacle is the green camera-in-use indicator and other items between us and the notch, which are unmeasurable, so a simple screen-fraction cap is used instead).

- **Decision (tried, reverted)**: do NOT force right-end placement via private `NSStatusBar` ordering.
  - Context: shrinking still hides *our* icon first under pressure, because macOS hides the leftmost status items first. There is no public API to order a status item (only `autosaveName` persists a user's manual Cmd-drag), so a Swift port of the 2015 `NSStatusBar+MISSINGOrder` category was attempted (private `_statusItemWithLength:systemInsertOrder:`, gated on `USE_UNDOCUMENTED_API`).
  - Outcome: it did not work on current macOS - the private create call returns an item that is never inserted into the visible bar, so the icon did not appear at all. Reverted to public `statusItem(withLength:)`; the item shows at its default (middle/left) position, and the design now accepts that position. If revisited, it needs real runtime introspection of the current NSStatusBar private surface, not a blind port.

## Open questions / known limitations

- The mouse-driven scroll uses screen-relative mouse position via a shared global watcher; multi-display behavior is unspecified.
- There is no launch-time width fitting: the item always starts at the default width. If that default does not fit a crowded bar, macOS still hides it until the user (or a future adaptive pass) narrows it. Not-yet-built: any automatic fitting to available room (deferred because doing it by resizing the live view blanked the feed - it must instead choose the birth width up front). Only the built-in notched display's geometry has been probed.
- The drag cap (`maximumCameraWidth()`) is a screen-fraction heuristic (`maxCameraWidthScreenDivisor`), not an exact fit: it cannot see the green camera-in-use indicator or other apps' items, so on a crowded bar a wide stretch can still be hidden by macOS. The divisor is tuned so the cap stays small enough to make that rare. Recomputed live from the item's current screen, but there is no explicit external-display / `didChangeScreenParametersNotification` handling.
- A reliable "am I hidden right now?" signal was never found (`statusItem.isVisible`, `window.isVisible`, `occlusionState`, off-screen frame all proved unreliable), which is why the design avoids reacting to hidden state. Temporary diagnostic logging (`diagnosticLoggingEnabled`, `NARC-FIT` / `NARC-GEO` / `NARC-CAM` lines) remains and should be removed once no longer needed.
- Right-end ordering is unsolved: there is no public API, and the 2015 private-selector port was tried and reverted (see the design decision above). If retried, introspect the live `NSStatusBar` private surface on the target macOS rather than porting old selectors blind.
- The resize cursor depends on a private, undocumented CoreGraphics property; a future macOS may change or remove it, in which case the cursor silently reverts to the arrow (no functional impact, the drag still works). If a future review ever rejects it, flip `USE_UNDOCUMENTED_API` off.
