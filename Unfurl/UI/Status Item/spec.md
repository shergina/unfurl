# Subsystem Spec: Status Item

## Metadata

- **Title**: The menu-bar camera item and its click-to-menu behavior.
- **Surface**: status item (menu bar).
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Unfurl/Tools/spec.md` (`SRCameraService`); `Unfurl/UI/Menu/` (the menu opened on click); `Unfurl/SRSettings.swift` (`showCameraOnStatusBar`; `statusItemCameraWidth`, `defaultStatusItemCameraWidth`, `allowedStatusItemCameraWidthRange`, `minimumStatusItemCameraHeight`).

## Summary

- **What this subsystem is**: the always-present menu-bar item. It hosts a custom view that shows either the live camera (scrollable by mouse position), an icon, or an "unavailable" icon, and opens the status menu on click.
- **One-sentence contract**: the item reflects the show-camera-in-menu-bar preference and camera availability, is resizable by drag, and reliably opens the menu when clicked.

## Scope

- **In scope**: `SRStatusItemController` (the `NSStatusItem`, hosting, click-to-menu), `SRStatusItemView` (content switching, width), `SRStatusItemCameraView` + `SRScrollCameraView` (live camera with mouse-driven vertical scroll and drag-to-resize), `SRStatusItemIconView` variants, `SRStatusBarButton`.
- **Constraints / assumptions**:
  - The custom view is hosted inside `statusItem.button` under Auto Layout; width is driven by `NSStatusItem.length`, never by manipulating frames.
  - Clicking must open the menu whether the current content is the icon or the live camera view.
  - The camera preview must render at native resolution.
  - The camera item ships with no resize cursor: the only mechanism that works from a background agent is a private CoreGraphics call, and `USE_UNDOCUMENTED_API` is undefined as of 2026-08-29 (see the design decision below). Drag-to-resize itself is unaffected.

## Responsibilities and ownership

- **Responsibilities**:
  - Host the custom view in the status button with a pinned height and length-driven width.
  - Switch content among camera / icon / unavailable based on the preference, device availability, and the camera state, debounced by 100 ms. That figure is load-bearing rather than arbitrary (2026-08-27, lowered from 500 ms): this is the app's one always-visible surface and it was the last consumer to attach at launch, which put it outside `SRCameraService`'s 250 ms session-start window, so it landed on an already-running stream and restarted it. Anything approaching that window puts the visible preview back on the slow path. The debounce only ever existed to swallow a burst of publisher updates, which 100 ms still does.
  - Open the status menu on click; light the item while the menu is open. The icon content uses the system primitive (`button.isHighlighted`); the camera content cannot, having no template image, so it dims the feed to `lightedOpacity` instead. That value is high on purpose (0.85, raised from 0.5 on 2026-08-27): macOS draws the item's highlight fill behind the view, and the video is what covers it, so dimming hard lets the fill bleed through and the two composite into haze - users read it as the camera going out of focus at the moment they click. Removing the dim outright was considered and rejected: at full opacity the video hides the system highlight completely, which would leave the item with no press state at all, and the overlay mark already steps aside while the menu is open.
  - Posture tint channel: while a posture issue is voiced and the `PostureStatusItemTint` preference is on, the item lights up - the icon swaps to a pre-tinted orange copy, the live camera gets an orange border. The pre-tinted copy is deliberate: `NSStatusBarButton` renders template images through the menu bar's own styling, and a `contentTintColor` blanks the image instead of tinting it. The alert state is forwarded to whichever content view is current and re-applied on every content swap. Best-effort ambient state (see `Unfurl/Posture/spec.md`), never load-bearing: the item can be hidden by the notch or a crowded bar.
  - `SRScrollCameraView`: scroll the tall camera layer vertically as the mouse moves; drag on the item resizes it within limits and persists the width.
  - Welcome-flow locate (`locate()`, triggered by the welcome tutorial's Locate Me through the composition root's wiring): open the status menu exactly as a click would, immediately. macOS highlights the item while its menu is open, and that highlight is the locator. A pre-open tint pulse was tried and dropped (2026-07-26): it only delayed the menu. Deliberately no hidden-state detection - no reliable signal exists (see the known limitations) - so the open menu is itself the locator of last resort.
- **Owned invariants** (must always hold):
  - Width flows through `statusItem.length`; the hosted view has an explicit height constraint (menu-bar thickness) so the button never collapses when a zero-intrinsic-height camera view is installed.
  - Content class is: unavailable-icon whenever the camera cannot run (device missing or suspended, access denied, session failed), in both modes; otherwise camera when show-in-menu-bar is on, plain icon when off. VoiceOver mirrors the choice (2026-08-14): the button's accessibility value reads "Camera unavailable" exactly when the X shows, and clears otherwise - the label alone said only that the app is here. Two decisions on 2026-08-14, both from the App Review denial walk: authorization folded into the choice (a denied camera still exists as hardware, so availability alone kept the live view up, which rendered as a blank strip - the exact blank-frame the constitution forbids, in the app's most visible surface), and the X wears the icon mode too (a camera app whose camera cannot run is broken with the preview hidden as well, and this item is the one always-visible surface that can say so).
  - The live camera's hover overlay (the app mark) is visible exactly when the mouse is over the item and the menu is closed. Both inputs are derived in one place (`updateOverlayVisibility`), not written by two independent observers, so hover and menu state cannot race over its alpha.
  - The camera width is remembered across launches: a drag saves it to `SRSettings.statusItemCameraWidth` at the end of the gesture (one write per drag, not per frame), and the item is born at that width next launch. A first run, before any drag, gets `SRSettings.defaultStatusItemCameraWidth`.
  - The saved width is re-clamped at birth, never trusted raw: `birthCameraWidth()` = saved width clamped to `allowedStatusItemCameraWidthRange.lowerBound ... maximumCameraWidth()`. Clamping happens in the host before the view is constructed, so a width dragged wide on a large display comes back trimmed on a small one instead of stretching the item under the notch.
  - The camera view's width is set once at creation and never re-set from the content path afterward; re-setting the width after the preview layer attaches blanks the feed. This is why the clamp is a birth-width choice rather than a post-creation resize. Over-widening is otherwise bounded during a drag.
  - Drag resize is bounded below by `allowedStatusItemCameraWidthRange.lowerBound` and above by `maximumCameraWidth()` (a screen-scaled cap, see Workflow 4). The resulting width is not persisted.
  - The camera layer is never shorter than `SRSettings.minimumStatusItemCameraHeight` (the default width's 16:9 height), nor shorter than the item itself. Height leads and width follows from the 16:9 ratio, so at narrow widths the layer overhangs the item horizontally and is cropped equally on both edges rather than shrinking below it.

## Key workflows

### Workflow 1: content switching

1. Combine `onCaptureDeviceAvailable` with `showCameraOnStatusBar`, debounced.
2. Choose the content class and cross-fade to it; update `statusItem.length` to the new content's intrinsic width.
3. The camera content view is a kept singleton (2026-08-05): created on the first show, reused on every later swap. Swapping away suspends its preview (layer connection disabled, session claim released, wiring kept); swapping back resumes it in place. Recreating the view would detach and reattach its preview layer on the running session, which stalls frame delivery to every preview for ~300 ms - the toggle blink (see Tools/spec.md). Lifecycle operations are chained inside SRCameraView, so a quick off-on flip cannot interleave.

### Workflow 2: click opens the menu

1. A click gesture - left or right button, two recognizers sharing one handler - (or the button action) calls the controller.
2. The controller asks the menu subsystem for the status menu, sets it on the status item, performs the click to pop it, then clears it; the item is lit while open.

### Workflow 3: drag to resize the camera (session-only)

1. A pan gesture on the camera view maps horizontal drag to a new width, bounded below by `allowedStatusItemCameraWidthRange.lowerBound` and above by `maximumCameraWidth()`, so the item follows the mouse within those bounds.
2. The new width applies to the live item immediately, and is saved to `statusItemCameraWidth` when the gesture ends (or is cancelled). Dragging is the only place width changes after creation, and the only place the preference is written.
3. The next launch is born at the saved width, re-clamped to that screen (see the invariants and Workflow 4).

### Workflow 4: bound drag width to the display size (screen-scaled)

1. `maximumCameraWidth()` = `(screen width - notch width) / maxCameraWidthScreenDivisor`, clamped to `allowedStatusItemCameraWidthRange`. Notch width is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (0 on displays without a notch), so one formula covers notched and non-notched displays and scales with the screen: wider display -> wider allowed camera. (On the built-in notched laptop probed: `(1470 - 179) / 20 = 64`.)
2. It is consulted in exactly two places: the drag handler (Workflow 3), and `birthCameraWidth()` when the camera view is constructed. It is never applied by resizing a live view - re-setting the width after the preview layer attaches blanks the feed - so at launch it can only choose the birth width.
3. This is a heuristic cap, not a guarantee: it does not know about the green camera-in-use indicator or other apps' items (unmeasurable), so a wide drag on a crowded bar can still be hidden by macOS. A conservative divisor keeps the cap small enough that this is rare. A reactive detect-and-recover approach was ruled out - no reliable "am I hidden" signal was found, and resizing post-creation blanks the feed.

## Requirements (what must be true)

### Functional requirements

- The item is present for the process lifetime and removed on termination.
- Clicking opens the menu in every content mode, with either mouse button; the item lights while the menu is open.
- The camera view scrolls with mouse position and can be resized by dragging.
- Every fade honors Reduce Motion (2026-08-29): with the system setting on, the hover overlay appears and disappears at once and the content cross-fade collapses to an instant swap, rather than animating.

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
- **Data flow**: driven by `SRCameraService.onCaptureDeviceAvailable` and `showCameraOnStatusBar`; the camera width comes from `statusItemCameraWidth` (written by a drag, re-clamped at birth).
- **Control flow**: created by the app delegate; removes its status item on `willTerminate`.

### Interfaces and contracts

- **Public API surface**: `SRStatusItemController` and its `onMouseHover` (consumed by the panel to decide hover-show); `locate()` (consumed by the welcome flow via the composition root).
- **Inputs**: camera availability, the two status-item preferences, the posture status and tint preference, mouse position (`SRMouseWatcher`).
- **Outputs**: `onMouseHover`; opens the shared menu.

## Key design decisions (recorded)

- **Decision**: drive width with `statusItem.length` and pin an explicit height.
  - Context: leftover `statusItem.view`-era frame manipulation fought Auto Layout in the button; with no height constraint the button collapsed to zero height when the camera view (zero intrinsic height) was installed, which broke both the feed and click handling.
  - Chosen: length-driven width, explicit menu-bar-thickness height, no manual frame changes.
- **Decision**: fix `currentEvent` handling when opening the menu.
  - Context: menu construction force-unwrapped `NSApplication.shared.currentEvent`, which is nil for non-mouse (accessibility/synthetic) activation, trapping the app.
  - Chosen: read modifier flags safely.
- **Decision**: ship no resize cursor over the camera item (2026-08-29). Supersedes the private-SPI design recorded below, which the flag still gates should it ever be revisited.
  - Context: the camera item is drag-to-resize, so the resize cursor is the right affordance. But macOS only lets the active app set the cursor, and this is an `LSUIElement` agent that is never active; `NSCursor` push/pop, `set()`, and `.cursorUpdate` tracking areas are all ignored over the menu bar. The only mechanism that works is setting the private `SetsCursorInBackground` connection property (`_CGSDefaultConnection` + `CGSSetConnectionProperty`), resolved via `dlsym` to avoid a bridging header.
  - Was: opt into the private call, shipped in all configurations, gated on the `USE_UNDOCUMENTED_API` Swift flag.
  - Chosen 2026-08-29, before App Store submission: leave the flag undefined in `Unfurl-Shared.xcconfig`, so no configuration compiles it. Guideline 2.5.1 permits only public API, and the entire benefit was a hover cursor - the drag still works, and the Settings Pro tip (`settings.general.status-bar-tip.body`) now documents drag-to-resize in words instead. The flag remains the single switch for every deliberate undocumented-API use, here and in the panel's diagonal cursors (`Unfurl/UI/Panel/spec.md`); defining it again restores both.

## Icon assets (recorded 2026-08-24)

- The glyph is the app's aperture mark, drawn as vector (SVG with `preserves-vector-representation`), replacing the earlier camera PNGs. It is template artwork: `SRStatusItemIconView` forces `isTemplate = true`, so only alpha survives and any detail has to be a real knockout, not a lighter fill. The mark's shrimp reading is deliberately dropped here - at this size it cannot register, and the item's job is to say camera state among other monochrome system glyphs (the app icon carries the identity instead).
- The two asset roles need different canvases, and the difference is load-bearing. `MonochromaticLogoSmall` is its own natural size (16.67x15, drawn from a 20x18 viewBox) because the 28x22 button centers whatever it is given. That height is set against the bar's actual population, not against the camera glyph it replaced: system menu bar symbols run 13-15pt tall (wifi 13, magnifyingglass 15, play.circle 15), and the outgoing 16.5pt camera glyph was already oversized. A solid form among outline-weight neighbours also reads heavier at equal height, so matching the smaller end is the match. The overlays are pinned: `SRStatusItemCameraView` builds the image view as `NSImageView(frame: origin (2,0), size: iconImage.size)`, so their canvas has to be the full 28x22 with the glyph inset (19.5 tall), or the overlay lands in the corner instead of over the preview. A future artwork swap that ships one canvas for all of them will silently misplace the overlays.
- The overlays are not template images: they composite over live video and are picked by appearance, so they ship as literal black and white copies of the same shape.

## Key design decisions (recorded, continued)

- **Decision**: the hover overlay hides while the status menu is open. (2026-08-27.)
  - Context: the overlay was driven by the camera view's raw hover publisher alone. Menu tracking runs its own modal event loop and swallows mouse-moved events, so the tracking area never sees `mouseExited` and hover latches on for the whole menu session. The mark therefore sat over the user's face while they clicked through Settings, Snooze, About. Worse, `lighted` dims only the video layer (the overlay is a sibling view at full alpha), so clicking made the mark *more* prominent than it had been on hover.
  - Chosen: derive the overlay from `hovered && !lighted`. `lighted` is already fed from `onMenuShown`, so no new plumbing. This matches what the controller already does for the panel's hover signal (`hover && !menuShown`), which the overlay had simply never been wired into. Nothing is lost while the menu is open: the open menu names the app, and macOS highlights the item.

- **Decision**: the camera width is remembered across launches, clamped to the screen at birth. (2026-08-17. Supersedes the session-only design below, which this replaces; the history is kept because the failure modes it was avoiding are still real and the current design has to keep dodging them.)
  - Context: the width had been session-only precisely because persisting it once went wrong. A saved over-stretch tucks the item under the notch and hides it, and the item came back blank on every relaunch with no way for the user to drag an item they cannot see. The first fix attempt - create at the saved width, then resize to fit - blanked the feed, because re-setting the width after the preview layer attaches is what breaks rendering. So the width was made a constant and reset each launch.
  - Chosen: persist it, but write and read it at the two safe moments. A drag saves the final width once, at gesture end. Launch resolves `birthCameraWidth()` = saved clamped to `lowerBound ... maximumCameraWidth()` *before* constructing the view, and passes it to the initializer. That keeps the create-once/never-resize render path intact, and the birth clamp is what makes persistence safe: the saved value can never exceed what a drag on the current screen could have produced, so the hidden-under-the-notch relaunch cannot recur even when the width was dragged on a different display.
  - Residual risk accepted: `maximumCameraWidth()` is a heuristic that cannot see other apps' items, so a deliberately wide width on a crowded bar can still be hidden by macOS - and now that state persists across launches instead of being reset. The clamp bounds it; the divisor keeps it rare.
  - Earlier attempts, still rejected: a polling feedback loop that stepped the width (laggy, depended on an unconfirmed hidden-state signal); a launch-time geometric clamp applied by resizing post-creation (blanked the feed); and a notch-position/chrome-based drag cap (the real obstacle is the green camera-in-use indicator and other items between us and the notch, which are unmeasurable, so a simple screen-fraction cap is used instead).

- **Decision**: the camera layer's height leads and its width follows; narrow items crop the sides.
  - Context: `layout()` fitted 16:9 to the item's width, so below about 39pt (bar thickness 22 x 16/9) the layer came out shorter than the item. The `(cameraHeight - viewHeight)` term in the pan then flipped sign and the whole strip slid up and down instead of panning, leaving a gap. The drag floor is 30, so 30-39 was a broken zone.
  - Chosen: vertical overscan. Height is `max(width / ratio, item height, minimumStatusItemCameraHeight)` and width is derived from it, centered, so the layer always covers the item and hangs over both edges instead of shrinking. The alternative - clamping the layer to the item height - fills too, but kills the head-shoulders pan at every width below 40; overscan keeps a constant 5pt of pan all the way down to the 30pt floor.
  - `minimumStatusItemCameraHeight` (27pt) is a standalone constant, deliberately not derived from the default width. It was briefly derived, which coupled two unrelated numbers: dropping the default to 35 would have pulled the floor to 19.7pt, under the 22pt bar thickness, silently flattening the pan to zero at the default width itself.

- **Decision (tried, reverted)**: do NOT force right-end placement via private `NSStatusBar` ordering.
  - Context: shrinking still hides *our* icon first under pressure, because macOS hides the leftmost status items first. There is no public API to order a status item (only `autosaveName` persists a user's manual Cmd-drag), so a Swift port of the 2015 `NSStatusBar+MISSINGOrder` category was attempted (private `_statusItemWithLength:systemInsertOrder:`, gated on `USE_UNDOCUMENTED_API`).
  - Outcome: it did not work on current macOS - the private create call returns an item that is never inserted into the visible bar, so the icon did not appear at all. Reverted to public `statusItem(withLength:)`; the item shows at its default (middle/left) position, and the design now accepts that position. If revisited, it needs real runtime introspection of the current NSStatusBar private surface, not a blind port.

## Open questions / known limitations

- The hover latch on menu close is unresolved and untested. Because menu tracking swallows the exit event, `hovered` can still read true when the menu closes with the pointer away from the item (dismissed by picking an item or clicking elsewhere), which would fade the overlay back in until the next mouse move re-syncs the tracking area. AppKit may deliver a synthetic exit at the end of menu tracking, in which case there is nothing to fix; that has not been observed either way. Note the panel is not an oracle for this - it consumes the same gated hover signal but debounces 500 ms, which hides any staleness shorter than that, while the overlay's fade is immediate. If it does need fixing, re-derive hover from `NSEvent.mouseLocation` against the view's screen frame on menu close.
- The mouse-driven scroll uses screen-relative mouse position via a shared global watcher; multi-display behavior is unspecified.
- Launch-time fitting goes only as far as the screen-scaled clamp on the remembered width; there is still no fitting to the room actually left on the bar. If the birth width does not fit a crowded bar, macOS hides the item until the user narrows it - and with the width now remembered, that state carries to the next launch instead of resetting. Any real adaptive fitting must also choose the birth width up front (resizing the live view blanks the feed). Only the built-in notched display's geometry has been probed.
- The drag cap (`maximumCameraWidth()`) is a screen-fraction heuristic (`maxCameraWidthScreenDivisor`), not an exact fit: it cannot see the green camera-in-use indicator or other apps' items, so on a crowded bar a wide stretch can still be hidden by macOS. The divisor is tuned so the cap stays small enough to make that rare. Recomputed live from the item's current screen, but there is no explicit external-display / `didChangeScreenParametersNotification` handling.
- A reliable "am I hidden right now?" signal was never found (`statusItem.isVisible`, `window.isVisible`, `occlusionState`, off-screen frame all proved unreliable), which is why the design avoids reacting to hidden state. The temporary probes that established this (`diagnosticLoggingEnabled`, `NARC-FIT` / `NARC-GEO` / `NARC-CAM` lines) were removed on 2026-08-17; the scroll one logged on every mouse move, which is real cost in an all-day background app. Anything similar should be reinstated only for a specific question and deleted with its answer.
- Right-end ordering is unsolved: there is no public API, and the 2015 private-selector port was tried and reverted (see the design decision above). If retried, introspect the live `NSStatusBar` private surface on the target macOS rather than porting old selectors blind. Since the app cannot place itself, the mitigation is user-facing and documentary: an info button beside the Show Camera in Menu Bar switch (Settings > General, `SRSettingsTipButton`, `settings.general.status-bar-tip.*`) opens a Pro tip popover telling the user to Command-drag the item to the right, toward the clock, and why. The direction is the whole point of the copy, so it says both the direction and the landmark: dragging the other way is what causes the problem. Three inline placements were tried first and all failed on layout rather than wording - explanatory text in the control column widens the label column and splits the switch list into two arbitrary groups; the one-line version that avoided both had no room left for the reason; and an aside in the right-hand gutter looked fine but spent page weight permanently on advice most users need once. On demand also means there is nothing to dismiss, which matters because the app cannot detect that the user has already moved the item, so a dismiss control could only ever be manual and one-way. `autosaveName` is deliberately still unset - AppKit's generated name has been observed to persist a manual drag across launches - so setting one later would reset every user's dragged position.
- Drag-to-resize has no cursor affordance, so it is discoverable only through the Settings Pro tip. That is the accepted cost of dropping the private call (see the design decision above); if `USE_UNDOCUMENTED_API` is ever defined again the cursor returns, and with it the risk that a future macOS changes the undocumented property and silently reverts it to the arrow.
