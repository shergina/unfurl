# Agent and Contributor Guide

This file is the entry point for anyone changing this repository: AI agents (Claude, Cursor, Copilot, and others) and humans. `CLAUDE.md` and `.cursorrules` are symlinks to this file.

Narcissism is a native macOS app that coaches the user's posture and tracks its dynamics over time, built around a menu-bar camera (AppKit, Swift 6, sandboxed).

## The one rule that is easy to forget

**This repo is spec-driven. When you change behavior, contracts, or invariants, update the relevant `spec.md` in the same change.**

- The spec is the source of truth for intended behavior. Code conforms to the spec, never the reverse.
- Read `.spec/constitution.md` before non-trivial work; it defines the stable principles.
- Specs live next to the code: `.spec/app.spec.md` for the whole app, and `<subsystem>/spec.md` for each substantial subsystem under `Narcissism/` (Tools, UI/Panel, UI/Dock, UI/Status Item, UI/Menu).
- If your change touches a subsystem that has a `spec.md`, decide explicitly: does this change behavior, a contract, an invariant, or a recorded design decision? If yes, edit the spec in the same commit. If it is a pure no-behavior refactor, it is fine to leave the spec unchanged.
- A local pre-commit hook reminds you when code changed under a spec-owning subsystem without touching that spec (see "Local setup"). It is a reminder, not a gate; the judgment is yours.

## Where things are

- `main.swift` runs the app; `SRNarcissismApplicationDelegate` is the composition root (creates the three surfaces at launch).
- Services (process-wide singletons the surfaces observe): `SRCameraService` (the one shared capture session and its state), `SRPhotoCaptureService`, `SRSettings` (typed preferences), `SRLaunchApplicationAtLoginController`.
- Surfaces under `Narcissism/UI/`: `Status Item/`, `Panel/`, `Dock/`, `Menu/`, `About/`.
- Read the relevant `spec.md` first; it captures the design and the platform decisions already made.

## How this codebase expects changes to be made

These distill `.spec/constitution.md`; the constitution wins if they ever conflict.

- **Follow the macOS Human Interface Guidelines.** The app aims for best-in-class platform quality. When a design question has a platform convention - menu ordering and grouping, window roles, control choice, label style - the convention wins over invention. If a proposed design fights how a Mac app is expected to behave, redesign it rather than shipping the fight.
- **Prefer the system primitive.** Before hand-drawing chrome or reimplementing a system behavior, use the real one (`NSPanel` chrome, `SMAppService`, SF Symbols, `NSStatusItem.length`, system shadows and corners). Hand-rolled equivalents are what we keep deleting.
- **Stay main-actor by default.** UI and controllers are `@MainActor`. Only the camera session queue and the AVFoundation callbacks run off-main, and they hand back finished `Sendable` values. The build must stay warning-clean under strict concurrency; do not silence isolation warnings, fix them.
- **Never blank-frame a failure.** Camera permission and errors surface through `SRCameraService.onState`; user-facing surfaces explain the state. Do not swallow errors into `print` or a discarded `Task`.
- **One capture session.** All preview layers and outputs attach to `SRCameraService`'s shared session. Do not create a second `AVCaptureSession` on the camera, and do not request a buffer size on the Dock output.
- **Keep background cost low.** Cache static drawing; redraw only changing pixels; pace background surfaces; keep per-frame and IO work off the main thread.
- **Camera data stays on device.** No network transmission of frames or photos. The sandbox entitlements enforce this, not just convention: the app requests only app-sandbox, camera, and pictures read-write. Microphone and network-client are deliberately not requested. Do not add either without a real, user-facing reason and a matching Info.plist usage string.
- **Delete rather than defer.** Dead code and half-finished features are liabilities.

## Commit messages

- Write them like a human dashing off a note: short, on point, a bit sloppy is fine. One plain subject line; add a body only when the subject cannot carry it.
- No AI attribution of any kind: no Co-Authored-By trailers, no "Generated with" lines, no tool names. This applies to every commit; history has already been scrubbed once and should stay clean.

## Building and verifying

- Build: `xcodebuild -workspace Narcissism.xcworkspace -scheme Narcissism -configuration Debug -destination 'platform=macOS' build`
- The app is an `LSUIElement` agent: no Dock icon or main window by default; its UI is the menu-bar item, the floating panel, and (when enabled) the Dock tile.
- Development builds sign with a real Apple Development cert, so macOS keeps the camera grant across rebuilds. The team id lives in `Build Configurations/Configurations/Debug.xcconfig`; change it if you sign in with a different Apple ID. Ad-hoc signing (`CODE_SIGN_IDENTITY = -`) also builds, but re-prompts for camera access every time.
- Verify camera-facing changes by actually running the app and observing the surface, including the permission-denied path.

## Spec formatting rules (when editing specs)

- ASCII characters only. No smart quotes, em-dashes, or pseudographics.
- No Markdown tables.
- Compact. Do not repeat what an earlier section already implies. Record open questions instead of guessing.

## Local setup

Install the spec reminder hook once, per clone:

    ./scripts/install-hooks.sh

This points `core.hooksPath` at `scripts/hooks/`, so the versioned pre-commit reminder runs for you.
