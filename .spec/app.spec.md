# App Spec

What the whole app is, and the contracts that cross subsystem lines.
Each subsystem under Narcissism/ owns its own spec.md (Posture, Tools,
UI/Dock, UI/Menu, UI/Panel, UI/Settings, UI/Statistics, UI/Status Item,
UI/Welcome); this file records only what spans them.

## Identity

- Narcissism, a posture coach for macOS 14+ that watches through the
  camera and tracks posture dynamics over time. AppKit, Swift 6 strict
  concurrency, sandboxed, LSUIElement agent.
- Posture coaching is the product; the camera surfaces around it are
  optional mirrors: the status-bar camera, the floating panel, the Dock
  tile (opt-in), plus the menu, Settings, Statistics, About, and the
  one-time Welcome flow.

## Composition

- main.swift runs the app; SRNarcissismApplicationDelegate is the
  composition root. It builds AppServices and creates the surfaces at
  launch; surfaces observe services, never each other.
- Process-wide services: SRCameraService (the one shared capture
  session and its state), SRPhotoCaptureService, SRSettings (typed
  preferences), SRLaunchApplicationAtLoginController,
  SRPostureAnalysisService and its posture siblings.

## Cross-cutting invariants

- One capture session, owned by SRCameraService; every preview layer
  and output attaches through it (constitution, principle 6).
- Every surface renders every camera state; permission-denied is a
  first-class state with its own presentation, not an error path.
- Preferences go through SRSettings typed Preference values; no raw
  UserDefaults access elsewhere.
- Entitlements stay minimal: app-sandbox, camera, pictures read-write.
  Nothing else without a user-facing reason and a usage string.
- Localizable.strings carries every user-visible string; keys live and
  die with the code that reads them.

## Open questions

- None recorded yet. Add them here rather than guessing in code.
