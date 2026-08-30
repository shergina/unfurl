# Subsystem Spec: Floating Camera Panel

## Metadata

- **Title**: The floating, resizable camera panel and its control chip.
- **Surface**: floating panel.
- **Actor isolation**: main-actor.
- **Related code**: `.spec/app.spec.md`; `Unfurl/Tools/spec.md` (`SRCameraService` state and preview attach); `Unfurl/SRSettings.swift` (panel preferences).

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
  - `SRPanelContentView`: stack the camera view, placeholder, and chip; reveal the chip on hover over a live feed; hide the camera view when not running so the placeholder is interactive; hint that the panel is resizable by setting the matching resize cursor near each edge and corner (inert as shipped: see the design decision, the cursor needs a private call the app no longer makes).
  - `SRPanelToolbarView`: the chip buttons (close, pin, photo, ghost, mirror, menu) as SF Symbols, with active toggles accent-tinted.
  - `SRCameraPlaceholerView`: the logo is a template image tinted to `labelColor` at 10 percent opacity (2026-08-24). The view's material is `underWindowBackground`, which is light in light mode and dark in dark, so the previous literal-black artwork disappeared against the dark appearance; tinting makes it adapt. Show the app logo plus a per-state message, and an "Open System Settings" action when access is denied. Logo, message, and button center as one block (2026-08-14, was logo-at-center with the text hanging below - bottom-heavy); with the message hidden the block collapses to the bare logo, which keeps the watermark-behind-video role at dead center.
- **Owned invariants** (must always hold):
  - `showPanel == (hover || pinned) && (cameraAvailable || cameraState != .idle)`. A denied camera keeps the panel showable so its reason is visible; it does not silently hide.
  - The chip is revealed only while hovering AND `cameraState.isRunning`.
  - The camera view is hidden whenever `cameraState` is not running, so it cannot cover the placeholder or swallow the placeholder's button clicks.
  - Panel frame writes go to `cameraPanelSize` / `cameraPanelRelativePosition` / `cameraPanelScreenName` on move and resize (the position as a fraction of the screen's usable area plus the screen's name; see the placement decision). Programmatic repositioning on summon is excluded via `isPositioningProgrammatically`: with the window kept, a `setFrame` on a panel that already has a screen is indistinguishable from a user drag, and would rewrite the remembered screen on every summon.
  - The panel becomes its own window's delegate only *after* its content view controller is assigned. Assigning a content view controller makes AppKit size the window to the content's fitting size - 90x60, the panel's `minSize` - and that fires `windowDidResize`. Observed 2026-08-27: with the delegate already installed, that transient was written to `cameraPanelSize`, and every later summon restored a 90x60 panel near the bottom-left corner. The transient has always existed and was previously masked by the `setFrame` immediately after, whose own save overwrote the garbage; suppressing programmatic saves removed the overwrite and exposed it. Do not rely on a corrective second write - keep the delegate out of the construction window.
  - `hidePanel` clears `onMouseHoverPanel` by hand. A hidden window's tracking area cannot report the mouse leaving, and the show condition is `statusItemHover || panelHover`, so a latched panel-hover would hold `onShouldShowPanel` true and the panel could never hide again. Teardown used to reset this incidentally; keeping the panel makes it an explicit obligation.

## Key workflows

### Workflow 1: show and hide

1. `onShouldShowPanel` combines status-item hover, the pin preference, and "has content" (available or a non-idle state), debounced by an 800 ms hover dwell.
2. The dwell is deliberate and was raised from 500 ms (2026-08-27): at 500 ms the panel read as instant, and merely crossing the menu bar toward another app's status item was enough to summon it. Summoning a floating window showing the user's face is heavyweight enough that a false positive costs more than the added latency.
3. Show and hide are timed separately (`hoverShowDelay` 800 ms, `hoverHideDelay` 500 ms) by a value-keyed `delay` plus `switchToLatest`, not by a symmetric `debounce`. `switchToLatest` cancels the pending edge when the signal flips, so a quick in-and-out never reaches the show.
4. The hide delay is not politeness: hover is `statusItemHover || panelHover`, and neither is true while the mouse travels from the item down to the panel, so it is what keeps the panel alive across that gap. Shortening it below the travel time makes the panel unreachable; a symmetric 800 ms was tried first (2026-08-27) and made dismissal feel stuck.
5. On rising edge, create the panel and its content on first use only, position it, resume the preview, and order it front (without activating). On falling edge, order it out and suspend the preview. The panel and view controller are kept for the process lifetime; they are never torn down.
6. The keep is the point (2026-08-27): destroying the view controller deallocated `SRCameraView`, whose deinit calls `detachPreviewLayer`, which sets `layer.session = nil`. That graph mutation stalls frame delivery to every consumer for ~300 ms, so each hover in and out visibly blinked the menu-bar item and the Dock tile. `suspendPreviewLayer` only disables the layer's connection and is documented as free. This is the same kept-singleton trade the status item already makes for its own camera view.
7. The panel is built at launch (`createPanelOnFirstCameraUse`, called by the composition root): the panel and its preview are created while the capture session is still cold, then suspended, so the first summon is a resume rather than an attach on a running stream. Without it the first hover of each launch restarts the stream and blinks every other surface.
8. It never attaches speculatively. It builds on whichever of two events comes first, then never again: a visible camera surface (menu bar or Dock tile) being enabled, or `onState` reporting running. The two exist because they are the two moments when attaching is either free or unseen.
9. Visible surface enabled: attach on the preference change itself, which lands in the same cold start-coalescing window as the status item's own attach, so nothing restarts. This has to be an event, not a value read at launch (corrected 2026-08-27, same day it was introduced): read once, a user enabling the menu-bar camera later would fall through to the running-session branch, which would attach to a live stream and blink the very surface that branch protects. The preference replays, so an already-enabled surface still fires at launch.
10. Session running: nothing visible is on, but something else - posture tracking - is holding the camera. Attaching does restart the stream, but with no preview on screen there is nothing to blink and posture only misses frames of a slow judgment. Deliberately not a preference check: posture's gate is tracking-on AND past any snooze, it lives in the composition root, and restating it here would drift. A running session is that gate's observable consequence.
11. Neither firing is the honest limit: no surface enabled and nothing running means nothing attaches, the privacy light stays off, and the first hover pays a cold start. Attaching anyway would start the camera at launch and stop it moments later - the green light blinking on, off, on - for a panel the user may never open.
12. Attached is not the same as ready, and this is the non-obvious fact the timing here is built around. A preview layer that is wired but has never been handed a frame draws nothing; one that has run keeps its last frame and redisplays it the moment it is resumed. Observed 2026-08-27: releasing the pre-warmed claim on the same millisecond as `.running` gave a layer that opened grey, while releasing 59 ms later opened instantly. Treating attach as readiness is what made the first version of the pre-warm buy the claim without buying the picture.
13. Hence `prewarmSettleDelay` (300 ms): the pre-warmed preview is held live that long before being quieted, so it has actually received frames. It is not an arbitrary sleep and removing it returns the grey.
14. The same cache is why the preview is woken when the mouse arrives rather than when the panel is shown. Resuming at the moment of showing opened the panel on the frame from the last hide - a one-to-two-second-old image that visibly jumped forward as live frames arrived. The undelayed hover signal resumes it at the start of the dwell instead, so the frames are live by the time the window is ordered front, and re-enabling costs no stream restart so the early wake is free.
15. The hover wake has two guards. Only a panel that already exists: building one on a passing hover would attach and could restart the stream under the status item. And only while the session is already running: resuming takes a claim, and a claim on an idle session starts the camera, so warming on a hover that never becomes a summon would flash the privacy light for a panel the user never opened. Nothing is lost by the second guard - the stale frame it avoids only exists because the layer was live before.
16. Either way the claim is handed back once `onState` leaves `.idle` - any non-idle state, since a denied or failed camera has nothing to keep warm - and the release is skipped if the user has already summoned the panel, which would blank the feed they just asked for.
17. Suspending releases the session claim exactly as detaching did (`suspendPreviewLayer` calls `detachObject`), so the camera still stops when the last consumer goes away. Keeping the panel costs resident memory, not camera runtime. Suspend-on-hide is load-bearing for that: ordering the window out without suspending would leave the connection enabled and frames rendering into an invisible window.

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
- Every fade honors Reduce Motion (2026-08-29): with the system setting on, the ghost-alpha change and the toolbar's compact-mode fade apply their end alpha at once instead of animating. The animated paths already had a non-animated branch, so the setting simply forces it.

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
- **Outputs**: `cameraPanelSize` / `cameraPanelRelativePosition` / `cameraPanelScreenName` writes; toggling of pin/ghost/mirror preferences.

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
  - Chosen: an `.activeAlways` tracking area sets the matching edge/corner resize cursor near the border (the content view fills the panel, so its outer points overlap the resize border); the diagonal corners need private `NSCursor` selectors, so they are gated on `USE_UNDOCUMENTED_API` too and fall back to the arrow.
  - As shipped (2026-08-29): the flag is undefined, so the background-cursor call is never made and macOS ignores every cursor the panel sets - the edge cursors included, public though they are. The tracking areas and the cursor code remain, inert, behind one switch. Resizing works throughout; only the hint is missing.
- **Decision**: hide the camera view when not running.
  - Context: an always-present transparent camera view sat above the placeholder and ate the "Open System Settings" click.
  - Chosen: gate `cameraView.isHidden` on `cameraState.isRunning`.
- **Decision** (2026-08-02): the panel position is screen-relative, and a hover summon targets the screen being hovered.
  - Context: the position was one absolute global point, so hovering the status item on a monitor summoned the panel to wherever it last lived (usually the laptop screen), and a point saved on a since-disconnected display restored nowhere.
  - Chosen: the origin persists as a fraction of a screen's usable area (`visibleFrame`, 0...1 per axis of the room the panel has to move) plus the screen's `localizedName`. On show, the fraction is applied to a target screen: the screen under the mouse for a hover summon - the mouse is on the hovered menu bar by definition, and the glance should happen where the user is looking - or the named screen for a pinned restore (pinning means "it lives here"), each falling back to the other, then to the main screen. The fraction is clamped on apply, so a restored panel is always fully on screen and one dragged position means the same corner on every display. The legacy absolute `cameraPanelPosition` is read once to seed the fraction (its containing screen doubles as the home screen) and zeroed on the first save. First-ever placement still anchors under the status item, clamped by the screen's real edges (maxX/minX, not width - a secondary display's global origin is not zero). Known simplification: two identical displays share a `localizedName`; the pinned restore then picks the first match.
- Ghost mode relies on global mouse monitors; if Input Monitoring is restricted the hover-fade may not fire (the panel stays at its idle translucency).
