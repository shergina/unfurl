# Subsystem Spec: Capture Services

## Metadata

- **Title**: Shared camera session, still capture, and launch-at-login.
- **Surface**: service (no UI of its own).
- **Actor isolation**: mixed. `SRPhotoCaptureService` and `SRLaunchApplicationAtLoginController` are main-actor. `SRCameraService` is queue-confined (`@unchecked Sendable`): its mutable state is touched only on its private session queue, and its publishers are delivered on the main queue.
- **Related code**: `.spec/app.spec.md` (shared-session invariant, concurrency topology); every camera surface consumes `SRCameraService`.

## Summary

- **What this subsystem is**: the single owner of the camera. `SRCameraService` runs one `AVCaptureSession`, tracks device availability and a human-explainable state, and lets surfaces attach preview layers and outputs. It is consumed through the `CameraProviding` protocol (the injectable seam; `SRCameraService` is the only production conformer). `SRPhotoCaptureService` takes a still from that session. `SRLaunchApplicationAtLoginController` mirrors the launch-at-login preference into `SMAppService`.
- **One-sentence contract**: there is exactly one capture session; it starts when the first consumer attaches and stops when the last detaches, and its authorization and error state are always observable.

## Scope

- **In scope**: `SRCameraService`, `SRCameraState`, `SRCameraError`, `CameraDevice`, `SRPhotoCaptureService`, `SRLaunchApplicationAtLoginController`, `UncheckedSendable`.
- **Constraints / assumptions**:
  - All camera-device and session mutation happens on `SRCameraService`'s serial session queue; no lock is used and none may be added.
  - Consumers are main-actor; every publisher this subsystem exposes delivers on the main queue.
  - The session is pinned to 1080p when the device supports it; consumers never set the session preset.

## Responsibilities and ownership

- **Responsibilities**:
  - Request camera authorization on first use; resolve the selected (or default) video device.
  - Enumerate the selectable cameras - the built-in and external ones (monitor cameras, USB webcams); Continuity and Desk View devices are excluded entirely (see the phone-ban decision) - and switch the active device on request, swapping the running session's input live.
  - Create/start the session lazily on first attach; stop/destroy it when the attached-object set empties.
  - Attach and detach preview layers (panel, status item) and outputs (Dock video-data output, photo output); suspend and resume the consumers that toggle while the session runs (the posture probe and Dock outputs, the menu-bar preview layer).
  - Publish `onCaptureDeviceAvailable`, `onState`, `onDevices`, and `onSelectedDeviceID`.
  - `SRPhotoCaptureService`: lazily attach an `AVCapturePhotoOutput`, capture one photo, write a JPEG to Pictures, post a user notification.
  - `SRLaunchApplicationAtLoginController`: register/unregister the main app as a login item when the preference changes.
- **Owned invariants** (must always hold):
  - At most one `AVCaptureSession` for the camera exists at a time.
  - `session`, `captureDevice`, `captureDeviceInput`, and `desiredDeviceID` are read and written only on the session queue.
  - Switching the device replaces the session's single input in one begin/commit and re-pins 1080p; outputs already attached (Dock, photo) are untouched. `onSelectedDeviceID` reports the `uniqueID` actually in use.
  - `onState` is published only on the main queue (its subscribers touch main-actor UI). A hard state (`unauthorized`, `failed`) is never overwritten by a later transient state (`unavailable`, `idle`, `running`), with one deliberate exception (2026-08-14): a successful input swap onto a running session publishes `.running` over `.failed` or `.unavailable` - the swap is the recovery. Without it, unplugging the active camera left the surfaces stuck on the runtime error ("Recording Stopped") while the built-in was already delivering. Never over `.unauthorized`: an unauthorized session runs without delivering a frame.
  - The attached-object set counts claims on the session, not wiring: a suspended output stays wired to the session graph but holds no claim, so the session still stops when the last claim leaves and the suspended output is torn down with it.
  - Captured photos are written only under the user's Pictures directory; frames are never transmitted.

## Key workflows

### Workflow 1: first attach starts the session

1. A surface calls `attachPreviewLayer` / `attachOutput`; the object joins the weak attached-object set on the session queue.
2. `createCaptureSessionIfNeeded` builds the session: add the device input, then pin `.hd1920x1080` if supported, commit. No outputs are added at creation. The stream is deliberately NOT started here.
3. The start is held for `sessionStartCoalescingWindow` (250 ms), then runs on the session queue; `onState` becomes `.running` at that point. Consumers attaching inside the window are added while the stream is still cold, which is free. Late arrivals still reconfigure a running session and pay a stop/start, as before.
4. The window exists because launch consumers arrive staggered - posture analysis, the Dock tile, and the status item preview each register on their own schedule. Measured 2026-08-27 with the stream started on first attach: three stop/start cycles at roughly 1.3 s apiece, with the menu-bar preview (last to decide, and the only surface the user can see) not settling until 2.7 s after the camera light came on. Starting on the first attach also meant that consumer wired itself up after the stream was already live, so even the first attach mutated a running session.
5. The window is a compromise, not a guarantee: it must cover the surfaces that register during launch without being felt when the panel alone summons a cold session. It pairs with the status item's own 100 ms content debounce - lengthen that and the preview falls outside the window again.

### Workflow 2: last detach stops the session

1. A surface detaches; the object leaves the attached-object set.
2. When the set is empty, the session is stopped and released; `onState` returns to `.idle`.

### Workflow 3: select a camera

1. The composition root mirrors the `selectedCameraDeviceID` preference into `selectDevice(id:)` and the `preferExternalCamera` preference into `setPreferExternalCamera(_:)` (both replayed on launch, so the persisted choices are applied before any surface attaches).
2. On the session queue, `applyDesiredDevice` resolves the id to a device, always within the filtered enumeration: the temporary device override wins when set (a live calibration looking through its target camera; `setTemporaryDeviceOverride`, session-only, never persisted); then an exact `uniqueID` match; otherwise (Automatic, or a pick that has been unplugged) an `.external` camera is chosen when one exists, `preferExternalCamera` is on, and the auto-switch set allows it (`setAutoSwitchableExternalIDs`: while non-nil, only these externals may be auto-preferred - posture's calibration gate, pushed by the composition root; the policy lives upstream, the service just applies it); else the built-in, else whatever eligible camera remains. `AVCaptureDevice.default(for: .video)` is never consulted - macOS points it at a nearby Continuity Camera (see the phone-ban decision) - so a Mac with no eligible camera resolves nil and reads as unavailable rather than adopting a phone. If the resolved device differs from the current one and the session is running, it removes the old input, adds the new one, re-pins `.hd1920x1080`, and commits.
3. `onSelectedDeviceID` publishes the resulting active `uniqueID` on the main queue, driving the menu checkmark. Hot-plug (connect/disconnect) refreshes `onDevices` and re-runs `applyDesiredDevice`, so plugging into a monitor makes its camera take over by default (unless the preference is off or the user picked a specific camera), and unplugging falls back to the built-in.

### Workflow 4: authorization and errors become state

1. On init, authorization is requested. Denied or restricted -> `onState = .unauthorized`. Authorized but no device -> `.unavailable`.
2. Session setup failure (no device, cannot add input) is caught centrally in `attachObject` -> `.failed(message)`; the error is also rethrown for the caller's `Task`.
3. An `AVCaptureSession.runtimeErrorNotification` -> `.failed(message)`.

### Workflow 5: take a photo

1. `SRPhotoCaptureService.capture` plays the shutter sound (the named system sound "Pop"; nothing bundled), lazily creates and attaches an `AVCapturePhotoOutput` to the shared session, and captures with a retained one-shot delegate.
2. The finished JPEG is written to Pictures on a background queue; a "photo saved" user notification is posted after requesting notification authorization.

## Requirements (what must be true)

### Functional requirements

- `onCaptureDeviceAvailable` reflects hardware presence and suspension, independent of authorization (so menu items enable when a camera exists).
- `onState` distinguishes `idle`, `unauthorized`, `unavailable`, `running`, `failed`; `.running` is true only while the session delivers frames.
- Attaching a second consumer never restarts or reconfigures the running session beyond adding its output.

### Non-functional requirements

- **Native fidelity**: launch-at-login uses `SMAppService.mainApp` (not the removed `SMLoginItemSetEnabled` + helper app).
- **Concurrency**: no main-actor access from the session queue or AVFoundation callbacks; cross-queue values travel in `UncheckedSendable`. Builds clean under strict concurrency.
- **Resource cost**: the session exists only while a surface needs it.

### Failure modes

- Camera access denied.
  - Detection: authorization result is not `.authorized`.
  - Expected behavior: `onState = .unauthorized`; the panel explains and offers System Settings; the session never starts.
- Session runtime error mid-stream.
  - Detection: `runtimeErrorNotification`.
  - Expected behavior: `onState = .failed(message)`; the message reaches the panel placeholder.

## Design (how it works)

### Interfaces and contracts

- **Public API surface**: `SRCameraService.sharedInstance`; `onCaptureDeviceAvailable`, `onState`, `onDevices`, `onSelectedDeviceID`, `selectDevice(id:)`; `attachPreviewLayer`/`detachPreviewLayer`, `attachOutput`, `suspendOutput`/`resumeOutput`, `suspendPreviewLayer`/`resumePreviewLayer`. `SRPhotoCaptureService.sharedInstance.capture`. `SRLaunchApplicationAtLoginController.sharedInstance.enabled`.
- **Inputs/outputs**: preview layers and outputs in; `Sendable` state out on the main queue; a JPEG file and a notification out of the photo path.
- **Error model**: setup throws `SRCameraError`; callers of `attach*` may discard the returned `Task` because failures are surfaced centrally through `onState`.

### Concurrency

- One serial session queue guards all session/device state; `SRCameraService` is `@unchecked Sendable` to document this instead of locking. `setState` hops to the main queue when needed; `updateStateIfIdle` always dispatches to main and refuses to clobber a hard state.

## Key design decisions (recorded)

- **Decision**: pin the session to 1080p rather than leave it on `.high`.
  - Context: `.high` non-deterministically negotiated the camera's square 1552x1552 format, which landscape surfaces center-cropped and upscaled; sharpness was a per-launch lottery.
  - Chosen: set `.hd1920x1080` after adding the input, with `.high` as fallback.
- **Decision**: no outputs added at session creation; attach lazily.
  - Context: adding an `AVCapturePhotoOutput` during initial configuration blanks the live preview on current macOS.
  - Chosen: the photo output attaches on first capture; the Dock output attaches when the Dock tile turns on.
- **Decision** (2026-08-05): an output that toggles while the session runs is suspended and resumed, never removed.
  - Context: adding or removing an output on the running session makes AVFoundation rebuild the capture graph and stalls frame delivery to every consumer - both previews flash gray. Measured with a frame-gap monitor riding the session: 12 of 12 add/remove toggles stalled 278-302 ms; toggling the output's `connection.isEnabled` instead produced zero gaps over the same protocol, frames stop reaching the disabled output immediately (the session does no work for a disabled connection, so the idle cost is zero), and re-enabling delivers the first frame within ~100 ms.
  - Chosen: `suspendOutput` disables the output's connections and releases its claim on the session; `resumeOutput` re-takes the claim and re-enables the connections while the output is still wired, and reports false when the session went down in between (the caller then attaches a fresh output - the one remaining rewire, against a session that is warming up anyway, behind its placeholder). The `isEnabled` writes are skipped when already in the desired state; only real flips were measured stall-free. The posture probe and the Dock tile use this pair. The menu-bar preview uses the layer twin, `suspendPreviewLayer`/`resumePreviewLayer` (a preview layer owns a connection in the same graph, so detaching it stalls identically); since a layer needs no recreation, its resume subsumes the fresh-attach fallback. Verified with the same frame-gap monitor: three Dock cycles and three menu-bar cycles against live frames, zero gaps. The photo output's one-time lazy attach (first capture) remains the only mid-session rewire.
- **Decision**: the selected camera is a preference the composition root mirrors into the service, not a call the menu makes directly.
  - Context: device choice must persist across launches and be applied before any surface attaches, and the menu must not reach into the camera service.
  - Chosen: `selectedCameraDeviceID` (a `uniqueID`, "" = default) is the source of truth; the menu only writes it, and the app delegate subscribes it to `selectDevice(id:)`. The service resolves the id on its own queue and swaps the live input, so switching does not tear down the session or disturb attached outputs.
- **Decision**: Automatic prefers an external (display) camera over the built-in.
  - Context: a laptop docked to a monitor has two cameras at different angles; the monitor's is usually the one the user is facing, and it should take over on plug-in without a manual pick.
  - Chosen: a `preferExternalCamera` preference (default on) that only shapes the Automatic resolution inside `resolveDevice` - an explicit pick still wins, and turning it off pins Automatic to the built-in. The takeover is additionally gated by the auto-switch set while posture tracking is on (see `Unfurl/Posture/spec.md`, "Calibration gate"); the set's semantics are deliberately opaque to this service - it restricts which externals Automatic may adopt, nothing more - so the camera layer stays free of posture knowledge. The rule's inputs are mirrored onto the session queue ahead of time, so a hot-plugged camera is judged against the already-current rule instead of racing an upstream recomputation.
- **Decision** (2026-08-01): phone-backed cameras (Continuity Camera, Desk View) are not cameras of this app at all - not enumerated, not selectable, never resolved.
  - Context: a mirror-plus-posture app needs fixed, user-facing cameras; a phone appears and vanishes with proximity and moves when picked up, and the posture pipeline cannot use a Desk View feed at all. In practice the iPhone kept seizing the session through two back doors: `AVCaptureDevice.default(for:)` is biased toward a nearby Continuity Camera, and a Continuity device can enumerate as `.external`, slipping past device-type checks.
  - Chosen: discovery is limited to `.builtInWideAngleCamera` and `.external` and additionally filters out `isContinuityCamera` (the property catches the `.external` masquerade the type check misses); resolution never consults `AVCaptureDevice.default`. One camera concept for the whole app - the mirror and the posture probe always share the active device - was picked over per-feature camera selections, which would have needed a second simultaneous session and two cameras running at once. Restoring the phones someday is a one-line filter change. `refreshDevices` logs the raw pre-filter enumeration with each device's type and continuity flag, so how a phone presents itself stays observable on real hardware.
- **Decision**: surface errors as state instead of returning them to callers.
  - Context: the four `attach*` call sites discarded their `Task`, so setup and runtime errors vanished and a failed camera looked like an eternal placeholder.
  - Chosen: `attachObject` is the one chokepoint; it records `.failed` centrally, and `onState` is the single error surface.

## Open questions / known limitations

- `SRCameraService.sharedInstance` must be created on the main thread (its publishers assume main-queue delivery on init).
- Photo capture uses the shared session's active format; it does not switch to a higher-resolution photo format.
