# Unfurl Product Architecture Review

Date: 2026-07-27

## Executive summary

Unfurl is a native, sandboxed macOS menu-bar camera and posture-coaching app. Its differentiators are immediate access to a live self-view across three surfaces, private on-device posture analysis, and lightweight nudges that do not interrupt work.

The architecture already has the right core shape: one shared `AVCaptureSession`, lazy consumers, off-main camera and Vision work, typed observable settings, system-native UI primitives, and explicit failure states. The most valuable next step is not a rewrite. It is to make the existing pipeline measurable, remove temporary duplicated work, finish dependency ownership, and turn onboarding and camera lifecycle into an intentional state machine.

The recommended order is:

1. Add performance and lifecycle instrumentation, automated tests, and release gates.
2. Remove the experimental second Vision inference after using existing probe data to choose a winner.
3. Make camera attachment transactional and race-free.
4. Finish dependency injection so all surfaces use the same explicit service graph.
5. Gate onboarding and camera permission around user intent.
6. Remove capabilities that contradict the local-only promise.
7. Only then tune capture formats, frame rates, and rendering using measured data.

This sequence preserves every feature while improving launch experience, responsiveness, battery use, testability, and confidence in future changes.

## Product model

### User value

The product combines two jobs:

- A glanceable personal camera: menu bar, floating panel, Dock tile, mirroring, camera selection, ghost mode, photo capture, and global shortcuts.
- A private posture coach: guided calibration, continuous on-device pose analysis, issue-specific debouncing, snooze, and configurable visual/audio/status-item nudges.

The shared constraint is that all camera uses coexist. A preview, Dock tile, photo output, calibration, and posture analysis must never create competing capture sessions or silently degrade one another.

### Current runtime topology

```text
SRUnfurlApplicationDelegate
        |
        +-- AppServices (partly injected)
        |      +-- SRSettings
        |      +-- SRCameraService ---- one AVCaptureSession
        |      +-- SRPhotoCaptureService         |
        |      +-- SRPostureAnalysisService      +-- preview layers
        |      +-- SRLaunch...Controller         +-- Dock output
        |      +-- SRMenuController              +-- photo output
        |                                         +-- posture output
        |
        +-- Status item / Panel / Dock / Hot keys / Posture nudges
```

The important weakness is the phrase "partly injected": controllers receive `AppServices`, but many leaf views and the menu/calibration paths still access global `sharedInstance` values directly. The graph therefore looks explicit while retaining hidden global edges.

## What is working well

- One shared capture session is the correct product-level invariant. It avoids camera contention and allows all surfaces to coexist.
- Session creation is lazy and ref-counted through attached consumers, so the camera can reach zero work when unused.
- Vision and sample-buffer conversion are off the main thread, while UI delivery returns to the main actor.
- Dock rendering is paced to about 10 fps, static chrome is cached, and full camera frames are downscaled away from the main actor.
- Posture processing is paced to 4 samples per second and aggregates a best observation into one-second windows, which is better UX than reacting to noisy individual frames.
- Typed `Preference<Value>` objects make settings observable and prevent the previous class of stringly typed bugs.
- Camera failures are modeled as observable state rather than blank previews.
- The app favors native AppKit behavior and system services such as `NSPanel`, `NSStatusItem`, SF Symbols, and `SMAppService`.
- The posture product model correctly separates detection from notification channels and explicitly avoids medical claims.

These should be preserved through any refactor.

## Highest-priority improvements

### P0: Create a performance and correctness baseline

There are currently no test targets and no durable performance instrumentation. Without those, optimization is guesswork and a shared-session regression can break several features at once.

Add a small `UnfurlCoreTests` target first. Extract pure, `Sendable` value logic from UI/services and cover:

- preference round trips and default values;
- posture metric calculation, thresholds, hysteresis, debounce, and recovery;
- calibration acceptance and aggregation;
- snooze deadline transitions across relaunch and wake;
- camera consumer lifecycle using a fake `CameraProviding` implementation;
- menu state derivation from a single app-state snapshot.

Add `OSSignposter` intervals/events around:

- app launch to status item ready;
- first consumer attach to first camera frame;
- session start, stop, and device switch;
- each Vision request and each one-second aggregation window;
- Dock conversion and main-actor display handoff;
- photo request to file saved;
- onboarding page transitions and calibration duration.

Apple's signpost APIs are designed to expose these intervals in Instruments, including per-subsystem/category tracks ([Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data)).

Establish five repeatable Instruments scenarios:

1. Idle, all camera features off.
2. Panel and status preview only.
3. Posture tracking only, no visible preview.
4. All previews plus posture tracking.
5. Camera switch, photo capture, snooze, sleep/wake, and hot-unplug.

Track CPU, GPU, memory, idle wakeups, hangs, and time-to-first-frame. Suggested acceptance targets are below; capture a baseline before enforcing them.

### P0: End the doubled Vision experiment

`SRPostureAnalysisService` currently runs both raw and 2.5x padded body-pose pipelines for each selected frame. At 4 analyzed frames per second, that is 8 Vision inferences per second. The spec explicitly calls this temporary.

Use the existing unified-log data to decide which pipeline produces the better usable-observation rate under normal laptop framing, then delete the loser. This is the clearest immediate CPU, heat, and battery win because it removes roughly half of posture inference work without reducing the 4 fps decision cadence or any user feature.

If neither pipeline is reliable enough, keep the better one as a fallback while developing a new approach behind an internal experiment switch. Do not ship two permanent passes.

Also make the output's overload policy explicit by setting `alwaysDiscardsLateVideoFrames = true`. Apple documents that retaining late frames can significantly increase memory use; the default is currently true, but encoding the requirement protects the pipeline from future changes ([AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)).

### P0: Make camera consumer attachment transactional

The camera service's contract is central but its async API permits lifecycle races:

- `attachObject` records a consumer before session creation succeeds, but failure does not remove it.
- detach checks `attachedObjects.count` outside the session queue even though queue confinement is the documented invariant.
- output attach calls `addOutput` without `canAddOutput` or a modeled error.
- output detach assumes both the output and session exist; some callers force-unwrap an optional output while an async attach/detach may still be in flight.
- callers usually discard attachment tasks, so ordering depends on internal timing.
- device switching silently ignores input-creation/addition failure and can leave state inconsistent with the selected device.

Replace object-based weak ref-counting with explicit consumer registrations owned by the camera service:

```swift
let lease = try await camera.attach(.posture(output))
// lease cancellation or explicit close detaches exactly once
```

Internally, use one serialized camera executor/state machine for registration, session creation, configuration, and destruction. A Swift actor is attractive, but AVFoundation's blocking `startRunning` and callback behavior still belong on a dedicated serial executor; the goal is one ownership boundary, not moving blocking work to the cooperative global executor.

Required transactional behavior:

- A failed attachment rolls back its registration.
- Duplicate attach/detach is idempotent.
- The last successful lease closing stops the session.
- `canAddInput`/`canAddOutput` failures become typed state errors.
- device switch either commits a valid input or restores the previous one.
- state reflects requested, starting, running, interrupted, recovering, failed, and idle phases sufficiently for friendly UI copy.

This is the most important correctness refactor because every feature depends on it.

### P1: Finish the explicit service graph

`AppServices` is a good composition root, but global singletons remain in leaf views, toolbar actions, menu construction, calibration, welcome flow, settings pages, and camera views. This blocks isolated tests and makes it easy to accidentally construct logic outside the intended graph.

Move from a service bag plus globals to small purpose-specific dependencies:

- `CameraPreviewModel`: camera state, preview attachment, mirror setting.
- `PostureCoordinator`: tracking/snooze/calibration state machine.
- `CommandRouter`: toggle panel, take photo, calibrate, locate, open settings.
- `SettingsStore`: typed preferences and migrations.
- `AppState`: derived, read-only state consumed by menu and surfaces.

Pass only what each controller/view needs. Keep process-wide lifetimes in the composition root, but remove `sharedInstance` reads from leaves. This makes fake-camera UI tests possible and prevents surfaces from bypassing orchestration rules.

Do this incrementally by subsystem; a wholesale rewrite would create risk without user-visible benefit.

### P1: Model onboarding and posture orchestration as state machines

The welcome window currently opens every launch. That is intentionally temporary but is the largest obvious usability problem: returning users should reach the product immediately.

Add a versioned onboarding state such as `onboardingVersionCompleted`, not a single boolean. Show onboarding only when the stored version is below the required version. Provide a durable "Run Setup Again" entry in Settings or Help.

Unify all posture start/stop/calibration/snooze behavior under `PostureCoordinator`. Today the application delegate, standalone calibration window, welcome page, settings, and menu all participate in lifecycle decisions, including direct service starts during onboarding. A state machine should own transitions such as:

```text
off -> needsCalibration -> calibrating -> tracking
tracking -> snoozed -> tracking
any active state -> cameraUnavailable / permissionDenied
```

Surfaces should send intents and render state; they should not directly start or stop the analysis service. This removes re-entrant preference chains, competing calibration windows, and teardown edge cases.

### P1: Align permission timing and capabilities with the privacy promise

The camera service requests permission during singleton initialization, and default-visible camera surfaces attach at launch. This can cause the prompt before the user performs a clear camera action, even though onboarding attempts to explain the product first.

Introduce a permission coordinator and request camera access immediately after a user chooses a camera-dependent action or explicitly continues from the privacy/setup page. Preserve fast subsequent launches by attaching immediately once authorization is already granted.

The target currently declares microphone and outgoing-network sandbox entitlements, and `Info.plist` allows arbitrary network loads. No audited product behavior needs microphone or network access, while the product promises no network transmission. Remove:

- `com.apple.security.device.microphone`;
- `com.apple.security.network.client`;
- `NSAppTransportSecurity/NSAllowsArbitraryLoads`.

This is not primarily a speed optimization; it makes the privacy architecture enforce the product claim instead of relying on convention. Verify App Store packaging and any update mechanism before removing network access.

### P1: Tune capture cost from consumer requirements

The session is pinned to 1080p because it fixed nondeterministic soft previews. That is a valid product decision, but posture tracking alone does not need 1080p at camera frame rate, and the Dock only displays 256x256 at about 10 fps.

Do not lower the shared preset blindly: the existing spec records that output dimension requests degraded all previews. Instead:

- benchmark posture confidence and latency at downscaled input sizes off the sample-buffer queue;
- set per-output minimum frame duration where AVFoundation supports it without renegotiating shared quality;
- avoid BGRA conversion for posture if Vision can consume the camera's native bi-planar buffer directly;
- keep preview quality at 1080p when a visible large panel needs it;
- consider a quality policy driven by active leases only after measurements prove session reconfiguration does not cause blanking or latency.

The desired policy is "highest quality required by any active consumer," with hysteresis so opening/closing a surface does not repeatedly reconfigure the camera. This is a later optimization, not a prerequisite.

### P1: Stop drawing work when pixels are not visible

Apple recommends avoiding UI refresh when content is hidden or obscured because each update activates CPU, GPU, and display work ([Avoid Extraneous Content Updates](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/UsingEfficientGraphics.html)).

Apply visibility-aware leases:

- A hidden/occluded panel should detach its preview unless it is about to appear on hover.
- The Dock output should exist only while the Dock tile is enabled and actually present.
- Status-item camera work should stop when the user hides the camera or the status item is not visible, as far as public APIs can determine reliably.
- Posture tracking remains active when explicitly enabled; this is user-requested work and must not depend on preview visibility.

Retain a short warm grace period (for example 1-2 seconds) around hover-driven panel disappearance only if measurements show that it materially improves perceived latency without meaningful energy cost.

### P2: Reduce timer and event noise

The product uses timers for snooze deadlines and calibration countdowns/caps. These are appropriate, but add tolerance where exact timing is not user-visible and keep them invalidated when inactive. Apple recommends timer tolerance—about 10 percent for repeating timers—to let the system batch wakeups ([Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).

For posture snooze, also observe clock/time-zone changes and system wake explicitly, then recompute from the persisted absolute deadline. A single distant deadline timer is fine; correctness should not depend on it firing during sleep.

Remove temporary `asyncAfter` diagnostics and hot-path logging from camera/status UI. Keep structured fault logs and signposts, with debug detail compiled or filtered by log level.

### P2: Separate product state from presentation bindings

`SRMenuController` is about 500 lines and combines construction, localization, preference mutation, posture time formatting, window ownership, device submenu rebuilds, and variant copying. The posture service is about 760 lines and combines Vision execution, experimental preprocessing, metric extraction, aggregation, issue tracking, logging, and publication.

Split along stable responsibilities, not arbitrary file size:

- Vision frame processor -> immutable `PoseObservation`.
- Posture evaluator -> immutable `PostureVerdict`.
- Episode tracker -> debounce/hysteresis state.
- Calibration aggregator -> baseline result.
- Posture coordinator -> lifecycle.
- Menu model -> immutable rows/state.
- Menu presenter -> AppKit objects and actions.

Pure components should have no AppKit, Combine, `UserDefaults`, or capture-session dependency. This will make feature behavior faster to test and safer to tune.

## Recommended target architecture

```text
                           User intents
 Status / Panel / Dock / Menu / Settings / Welcome
                    |          ^
                    v          |
          AppState + CommandRouter (MainActor)
                    |
        +-----------+-------------------+
        |                               |
 PostureCoordinator                CameraCoordinator
 (state machine)                   (serialized leases)
        |                               |
        +---- PosturePipeline            +---- one AVCaptureSession
              |                          |       +-- previews
              +-- FrameProcessor         |       +-- photo
              +-- Evaluator              |       +-- Dock frames
              +-- EpisodeTracker         |       +-- posture frames
              +-- Calibration            |
                                          +---- CameraState

 SettingsStore <---- versioned preferences and migrations
 PerformanceRecorder <---- signposts, debug counters, no camera data
```

Concurrency boundaries:

- AppKit, preferences, commands, and published presentation state: `@MainActor`.
- Capture session and device mutation: one dedicated serial executor.
- Sample-buffer pacing and lightweight preprocessing: output queue(s).
- Vision requests: a bounded serial pipeline with newest-frame-wins backpressure.
- Photo encoding/file I/O: utility queue, returning only a result value.
- Values crossing boundaries: immutable `Sendable` structs; no generic `@unchecked Sendable` wrapper in public seams.

## Delivery roadmap

### Phase 1: Measure and stabilize (1-2 focused iterations)

- Add signposts and the five Instruments scenarios.
- Add the first pure-logic test target.
- Remove temporary UI diagnostics.
- Make late-frame dropping explicit.
- Fix camera attach rollback, queue-confined counts, `canAddOutput`, nil-safe detach, and device-switch error reporting.
- Decide and delete one posture analysis path.

Outcome: lower posture CPU cost, fewer lifecycle bugs, and a baseline that can prove later improvements.

### Phase 2: Improve first-run and ownership

- Ship versioned onboarding gating and a rerun entry point.
- Introduce `PostureCoordinator` and route all starts/stops through it.
- Introduce user-intent camera permission timing.
- Remove unused microphone/network/ATS capabilities after packaging verification.

Outcome: faster returning-user launch, clearer trust, and one source of truth for posture behavior.

### Phase 3: Complete dependency injection

- Replace singleton reads one subsystem at a time.
- Extract pure posture/calibration/menu models.
- Add fake-camera UI and integration tests.
- Add settings schema/version migrations for evolving baselines.

Outcome: features become safer and faster to change, with regressions caught before manual camera testing.

### Phase 4: Profile-driven media optimization

- Compare native pixel-buffer Vision input against conversion/downscale alternatives.
- Test active-consumer capture-quality policies.
- Add visibility-aware output leases and evaluate a short panel warm grace period.
- Tune posture sample cadence adaptively only if confidence and responsiveness remain acceptable.

Outcome: lower steady-state CPU/GPU/energy use without degraded preview or posture quality.

## Suggested performance and usability gates

These are initial engineering targets, not claims about current performance. Record present values first and adjust targets based on supported hardware.

- Idle with all features off: zero capture session, zero Vision work, no repeating high-frequency timer.
- Returning launch: status item interactive within 300 ms on a warm launch; no onboarding window unless required.
- Authorized first preview: first visible frame within 700 ms of user intent on representative hardware.
- UI responsiveness: no main-thread task above 16 ms during steady preview; no hang above 100 ms during camera switching or photo capture.
- Posture pipeline: at most one in-flight Vision request; stale frames dropped; p95 inference below the 250 ms sample interval.
- Dock: no more than 10 main-actor redraw requests per second, and none while disabled.
- Memory: bounded during a 30-minute all-features run and camera hot-plug loop.
- Energy: removing the second Vision pass should produce a clearly lower CPU/energy trace in posture-only mode.
- Reliability: 100 repeated attach/detach cycles and 20 device switches without blank preview, leaked consumer, crash, or stuck camera indicator.
- Accessibility/usability: every unavailable/denied/interrupted state has actionable copy; keyboard and VoiceOver paths cover onboarding, settings, menu, and calibration decisions.

## Product usability recommendations enabled by the architecture

- Show one concise status everywhere: Off, Calibrating, Tracking, Snoozed until time, Cannot See You, Camera Denied, or Camera Unavailable. Derive it once in `AppState`.
- When tracking is on without a visible preview, say so in the menu and expose a one-click pause/snooze. The macOS camera indicator is necessary but not sufficient product communication.
- Treat calibration quality failures as guidance, not generic errors: move back, improve light, uncover shoulders, or face the camera.
- Detect stale calibration by camera ID and meaningful reference-scale drift before emitting posture nudges.
- Save multiple baseline fields as a versioned value object rather than adding unrelated preferences one by one. This supports future schema migration and per-camera calibration.
- Keep fast commands available through the status menu and shortcuts; route them through `CommandRouter` so every entry point behaves identically.

## Risks and tradeoffs

- Dynamic capture quality can cause session interruption or blank previews. Do not implement it without device-matrix testing.
- Moving all session code directly into a conventional Swift actor can block the cooperative executor because AVFoundation start/stop calls are synchronous. Preserve a dedicated serial execution context.
- Deferring camera permission improves comprehension but may slightly delay the first preview. Prime the prompt with clear copy and start immediately after the user's action.
- Removing network entitlement should be verified against distribution/update plans, but retaining it weakens the strongest product promise.
- Visibility detection for status items is imperfect with notches and menu-bar managers. Never make posture correctness depend on inferred visibility.

## Repository/process findings

- `AGENTS.md` and subsystem specs reference `.spec/constitution.md` and `.spec/app.spec.md`, but both are absent from this checkout. Restore them or update every reference. Missing top-level principles make cross-subsystem decisions—especially privacy, concurrency, and the single-session invariant—easier to drift.
- The working tree already contained uncommitted product changes during this review. This report intentionally changes only this new Markdown file.
- A build was attempted with the documented command and a temporary Derived Data path. It could not start because `xcode-select` points to `/Library/Developer/CommandLineTools`, not a full Xcode developer directory. Re-run the build and tests after selecting the installed Xcode.
- This report changes no runtime behavior or contract, so no subsystem `spec.md` update is required. Every implemented behavioral recommendation should update its owning spec in the same change.

## Bottom line

Keep the product's current architecture center: one lazy shared session, native AppKit surfaces, typed preferences, and on-device analysis. Invest first in observability and transactional lifecycle correctness, then remove the doubled Vision experiment and consolidate orchestration. Those changes deliver the largest speed, battery, reliability, and usability gains with the least product risk. A broad framework rewrite or UI rewrite would be lower value than finishing the architecture already taking shape.
