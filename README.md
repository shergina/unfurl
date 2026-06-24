# Narcissism

A native macOS posture coach that lives in your menu bar. It learns what
*your* good posture looks like through the webcam, watches for sustained
slouching or shoulder misalignment - entirely on device - and notifies you
when your posture worsens. Around that it offers a set of optional camera
features: a live preview in the menu bar, a floating panel, and the Dock
tile. It has no main window: it is a background agent whose UI is always
available and never in the way.

## Posture coach

- A first-run Welcome window walks you through setup and calibration.
- Calibration learns what your good posture looks like, separately for
  each camera you use. After that, the app watches for sustained slouching
  or shoulder tilt.
- When your posture worsens, a discreet system-banner-style note appears in
  the corner. Strictness is adjustable, and you can snooze or turn tracking
  off from the menu.
- A Statistics window charts your posture by the hour, lets you browse past
  days, and shows week-by-week trends.
- A Settings window covers general behavior, posture strictness, and
  notification preferences.

## Privacy

Everything runs on your Mac. Pose analysis is local (Apple Vision), and
frames, baselines, and history never leave the device. The sandbox enforces
this: the app's only entitlements are camera access and Pictures read-write -
no network, no microphone.

## Camera features

Every feature here is optional: each one has its own on/off toggle in the
menu's Camera submenu, so you can run the app as a pure posture coach with
no camera views at all.

- **Menu bar**: a resizable status item showing the live camera; click or
  right-click it for the menu.
- **Floating panel**: a non-activating, resizable panel with the camera edge
  to edge and a hover-revealed control chip. Supports pin, mirror, ghost mode
  (click-through translucency), and photo capture. Remembers its position per
  screen and follows you to the screen you are on.
- **Dock tile**: the live camera drawn as a native-looking Dock icon.
- **Photo**: saves a JPEG to your Pictures folder.

## Build and run

Requires a recent Xcode; the app runs on macOS 14 or later.

    xcodebuild -workspace Narcissism.xcworkspace -scheme Narcissism -configuration Debug -destination 'platform=macOS' build

Then run the built `Narcissism.app`. Grant camera access when prompted; if you
deny it, the panel explains how to re-enable it in System Settings.

Development builds are ad-hoc signed, so each rebuild re-prompts for camera
access. That is a signing artifact, not a bug.

## Architecture

The app is a single Swift target (Swift 6 language mode, strict concurrency,
sandboxed). One shared `AVCaptureSession` (`SRCameraService`) feeds every
camera view and the posture analysis; strongly typed, observable preferences
(`SRSettings`) drive them.

This repo is spec-driven: each substantial subsystem has a `spec.md` next to
its code capturing the design and the platform decisions behind it. Start
there, and read `AGENTS.md` before making changes.

## Build flags

- `USE_UNDOCUMENTED_API` (defined for all configurations in
  `Build Configurations/Configurations/Narcissism/Narcissim-Shared.xcconfig`):
  the single switch for deliberate undocumented-API use, currently the
  private CoreGraphics call that shows a resize cursor over the menu-bar item.
  Remove the flag to compile all such usage out.
