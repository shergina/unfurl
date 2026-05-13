# Narcissism

A native macOS menu-bar camera app. It puts your live webcam in the menu bar,
a floating panel, and the Dock tile, and can save a photo. It has no main
window: it is a background agent whose UI is a set of always-available surfaces.

## Surfaces

- **Menu bar**: a resizable status item showing the live camera; click it for the menu.
- **Floating panel**: a non-activating, resizable panel with the camera edge to edge and a hover-revealed control chip. Supports pin, mirror, ghost mode (click-through translucency), and photo capture.
- **Dock tile**: the live camera drawn as a native-looking Dock icon.
- **Photo**: saves a JPEG to your Pictures folder.

## Build and run

Requires a recent Xcode and macOS 15.6+.

    xcodebuild -workspace Narcissism.xcworkspace -scheme Narcissism -configuration Debug -destination 'platform=macOS' build

Then run the built `Narcissism.app`. Grant camera access when prompted; if you
deny it, the panel explains how to re-enable it in System Settings.

Development builds are ad-hoc signed, so each rebuild re-prompts for camera
access. That is a signing artifact, not a bug.

## Architecture

The app is a single Swift target (Swift 6 language mode, strict concurrency,
sandboxed). One shared `AVCaptureSession` (`SRCameraService`) feeds every
surface; strongly-typed, observable preferences (`SRSettings`) drive them.

This repo is spec-driven: `.spec/constitution.md` defines the principles, and
`spec.md` files next to the code capture each subsystem's intent and the
platform decisions behind it. Start there, and read `AGENTS.md` before making
changes.

## Build flags

- `USE_UNDOCUMENTED_API` (defined for all configurations in
  `Build Configurations/Configurations/Narcissism/Narcissim-Shared.xcconfig`):
  the single switch for deliberate undocumented-API use, currently the
  private CoreGraphics call that shows a resize cursor over the menu-bar item.
  Remove the flag to compile all such usage out.
