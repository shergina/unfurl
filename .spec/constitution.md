# Constitution

The stable principles behind Unfurl. AGENTS.md distills these for
day-to-day work; if the two ever conflict, this file wins. Subsystem
spec.md files record the decisions made under these principles.

## What the app is

Unfurl is a native macOS posture coach. It learns the user's good
posture through the camera, watches for sustained slouching entirely on
device, nudges when posture worsens, and tracks posture dynamics over
time (hour-by-hour history, week-by-week trends). Around that it
offers optional camera surfaces: a live self-view in the status bar, a
floating panel, and a Dock tile. AppKit, Swift 6, sandboxed, an
LSUIElement agent with no Dock icon or main window by default.

## Principles

1. Spec first. Intended behavior lives in spec.md files next to the code
   they describe. Code conforms to the spec, never the reverse. A change
   to behavior, a contract, an invariant, or a recorded design decision
   updates the spec in the same commit. Specs record open questions
   instead of guessing.

2. Platform quality. Follow the macOS Human Interface Guidelines. When a
   design question has a platform convention - menu ordering, window
   roles, control choice, label style - the convention wins over
   invention. A design that fights how a Mac app is expected to behave
   gets redesigned, not shipped.

3. System primitives. Before hand-drawing chrome or reimplementing a
   system behavior, use the real one: NSPanel chrome, SMAppService, SF
   Symbols, NSStatusItem.length, system shadows and corners. Hand-rolled
   equivalents are what this project keeps deleting.

4. Main actor by default. UI and controllers are @MainActor. Only the
   camera session queue and AVFoundation callbacks run off-main, and
   they hand back finished Sendable values. The build stays warning-clean
   under strict concurrency; isolation warnings are fixed, never
   silenced.

5. Never blank-frame a failure. Camera permission and errors surface
   through SRCameraService state, and every user-facing surface explains
   the state it is in. Errors are not swallowed into print or a
   discarded Task.

6. One capture session. Every preview layer and output attaches to the
   single shared session owned by SRCameraService. No second
   AVCaptureSession, ever, and no buffer-size requests from surfaces
   that do not need them.

7. Background cost stays low. The app is on screen all day, so it earns
   its keep by being cheap: cache static drawing, redraw only changing
   pixels, pace background surfaces, keep per-frame and IO work off the
   main thread.

8. Camera data stays on device. No network transmission of frames,
   photos, or measurements. The sandbox enforces this, not just
   convention: the app requests only app-sandbox, camera, and pictures
   read-write. Microphone and network entitlements are deliberately
   absent and are not added without a real, user-facing reason and a
   matching usage string.

9. Delete rather than defer. Dead code, half-finished features, and
   stale experiment scaffolding are liabilities. When an experiment
   compares two approaches, the losing path is deleted, not kept as a
   fallback.
