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
  - Enumerate connected cameras (built-in, external, Continuity, Desk View) and switch the active device on request, swapping the running session's input live.
  - Create/start the session lazily on first attach; stop/destroy it when the attached-object set empties.
  - Attach and detach preview layers (panel, status item) and outputs (Dock video-data output, photo output).
  - Publish `onCaptureDeviceAvailable`, `onState`, `onDevices`, and `onSelectedDeviceID`.
  - `SRPhotoCaptureService`: lazily attach an `AVCapturePhotoOutput`, capture one photo, write a JPEG to Pictures, post a user notification.
  - `SRLaunchApplicationAtLoginController`: register/unregister the main app as a login item when the preference changes.
- **Owned invariants** (must always hold):
  - At most one `AVCaptureSession` for the camera exists at a time.
  - `session`, `captureDevice`, `captureDeviceInput`, and `desiredDeviceID` are read and written only on the session queue.
  - Switching the device replaces the session's single input in one begin/commit and re-pins 1080p; outputs already attached (Dock, photo) are untouched. `onSelectedDeviceID` reports the `uniqueID` actually in use.
  - `onState` is published only on the main queue (its subscribers touch main-actor UI). A hard state (`unauthorized`, `failed`) is never overwritten by a later transient state (`unavailable`, `idle`, `running`).
  - Captured photos are written only under the user's Pictures directory; frames are never transmitted.

## Key workflows

### Workflow 1: first attach starts the session

1. A surface calls `attachPreviewLayer` / `attachOutput`; the object joins the weak attached-object set on the session queue.
2. `createCaptureSessionIfNeeded` builds the session: add the device input, then pin `.hd1920x1080` if supported, commit, start. No outputs are added at creation.
3. On success, `onState` becomes `.running`. A preview layer is then pointed at the live session; an output is added to it.

### Workflow 2: last detach stops the session

1. A surface detaches; the object leaves the attached-object set.
2. When the set is empty, the session is stopped and released; `onState` returns to `.idle`.

### Workflow 3: select a camera

1. The composition root mirrors the `selectedCameraDeviceID` preference into `selectDevice(id:)` (replayed on launch, so the persisted choice is applied before any surface attaches).
2. On the session queue, `applyDesiredDevice` resolves the id to a device (exact `uniqueID` match, else the system default). If it differs from the current device and the session is running, it removes the old input, adds the new one, re-pins `.hd1920x1080`, and commits.
3. `onSelectedDeviceID` publishes the resulting active `uniqueID` on the main queue, driving the menu checkmark. Hot-plug (connect/disconnect) refreshes `onDevices` and re-runs `applyDesiredDevice`, so a preferred device reappearing is picked up and one vanishing falls back to the default.

### Workflow 4: authorization and errors become state

1. On init, authorization is requested. Denied or restricted -> `onState = .unauthorized`. Authorized but no device -> `.unavailable`.
2. Session setup failure (no device, cannot add input) is caught centrally in `attachObject` -> `.failed(message)`; the error is also rethrown for the caller's `Task`.
3. An `AVCaptureSession.runtimeErrorNotification` -> `.failed(message)`.

### Workflow 5: take a photo

1. `SRPhotoCaptureService.capture` plays the shutter sound, lazily creates and attaches an `AVCapturePhotoOutput` to the shared session, and captures with a retained one-shot delegate.
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

- **Public API surface**: `SRCameraService.sharedInstance`; `onCaptureDeviceAvailable`, `onState`, `onDevices`, `onSelectedDeviceID`, `selectDevice(id:)`; `attachPreviewLayer`/`detachPreviewLayer`, `attachOutput`/`detachOutput`. `SRPhotoCaptureService.sharedInstance.capture`. `SRLaunchApplicationAtLoginController.sharedInstance.enabled`.
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
- **Decision**: the selected camera is a preference the composition root mirrors into the service, not a call the menu makes directly.
  - Context: device choice must persist across launches and be applied before any surface attaches, and the menu must not reach into the camera service.
  - Chosen: `selectedCameraDeviceID` (a `uniqueID`, "" = default) is the source of truth; the menu only writes it, and the app delegate subscribes it to `selectDevice(id:)`. The service resolves the id on its own queue and swaps the live input, so switching does not tear down the session or disturb attached outputs.
- **Decision**: surface errors as state instead of returning them to callers.
  - Context: the four `attach*` call sites discarded their `Task`, so setup and runtime errors vanished and a failed camera looked like an eternal placeholder.
  - Chosen: `attachObject` is the one chokepoint; it records `.failed` centrally, and `onState` is the single error surface.

## Open questions / known limitations

- `SRCameraService.sharedInstance` must be created on the main thread (its publishers assume main-queue delivery on init).
- Photo capture uses the shared session's active format; it does not switch to a higher-resolution photo format.
