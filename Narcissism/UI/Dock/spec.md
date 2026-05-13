# Subsystem Spec: Dock Tile

## Metadata

- **Title**: Live camera rendered as a native-looking Dock icon.
- **Surface**: Dock tile.
- **Actor isolation**: mixed. `SRDockTileController` is main-actor; its `AVCaptureVideoDataOutputSampleBufferDelegate` callback and the pixel-buffer-to-image conversion are `nonisolated` (sample-buffer queue) and hand a finished `CGImage` to the main actor. `SRDockTileCameraView` drawing is main-actor.
- **Related code**: `.spec/app.spec.md`; `Narcissism/Tools/spec.md` (`attachOutput` on the shared session); `Narcissism/SRSettings.swift` (`showCameraOnDockTile`, `flipCameraHorizontally`).

## Summary

- **What this subsystem is**: when enabled, the app becomes a regular Dock app and draws the live camera into its Dock tile styled as a modern app icon (squircle, shadow, edge accents, corner badge).
- **One-sentence contract**: while `showCameraOnDockTile` is on and the camera is available, the Dock tile shows the paced live feed drawn like a native icon, without degrading the other surfaces.

## Scope

- **In scope**: `SRDockTileController` (activation policy, output lifecycle, frame pacing, pixel conversion), `SRDockTileCameraView` (icon drawing, badge, mirror).
- **Constraints / assumptions**:
  - Enabling the tile switches `NSApp` activation policy to `.regular` (Dock icon appears); disabling returns it to accessory.
  - The tile draws raw frames (not a preview layer), so mirror mode must be applied here explicitly.
  - Geometry scales with the actual tile size (`NSDockTile.size`), not a fixed canvas.

## Responsibilities and ownership

- **Responsibilities**:
  - Attach/detach a video-data output on the shared session as the preference and camera availability change.
  - Pace delivered frames to about 10 fps and convert each to a square, downscaled `CGImage`.
  - Draw the icon: squircle-clipped video, drop shadow, dark/light edge hairlines, and the camera-logo corner badge, with mirror applied when set.
- **Owned invariants** (must always hold):
  - The Dock output requests only a pixel format, never a width/height; asking for sized buffers would renegotiate the shared session's device format and blur every surface.
  - All drawing geometry is proportional to the current tile size via a single scale factor.
  - The badge and edge accents are never mirrored; only the video is.

## Key workflows

### Workflow 1: enable

1. `showCameraOnDockTile` and `onCaptureDeviceAvailable`, combined and debounced, flip an `enable` flag.
2. Enabling sets activation policy `.regular`, creates the video-data output (BGRA only), and attaches it to the shared session.

### Workflow 2: per frame

1. On the sample-buffer queue, drop frames arriving faster than about 10 fps by presentation timestamp.
2. Convert the pixel buffer to a full image, center-crop square (aspect fill), downscale to the tile image size, and hand it to the main actor.
3. The main actor sets it on the tile view and calls `dockTile.display()`.

### Workflow 3: draw

1. Build the static chrome once per tile size (backdrop shadow image + overlay of edge accents and badge) and cache it.
2. Per frame: draw the cached backdrop, clip to the squircle, draw the (optionally mirrored) video, draw the cached overlay.

## Requirements (what must be true)

### Functional requirements

- Enabling the tile makes the app appear in the Dock; disabling removes it.
- Mirror mode flips the Dock video in the same orientation as the panel and status item.
- The tile updates visibly while enabled and stops cleanly when disabled.

### Non-functional requirements

- **Native fidelity**: content occupies about 80 percent of the tile with a 22.5 percent corner radius and a subtle drop shadow (Big Sur icon template); the badge matches the system notification-badge geometry measured from the real Dock (diameter about 0.48 of icon width, overhang about 0.24 of the badge). Numbers and their provenance live in `SRDockTileCameraView.Metrics`.
- **Concurrency**: pixel work is off-main; only the finished `CGImage` crosses to the main actor.
- **Resource cost**: about 10 fps, static chrome cached (only video pixels redraw per frame). Measured effect: chrome caching plus pacing cut process CPU from about 21 percent to about 10 percent with the tile streaming.

## Design (how it works)

### Drawing model

- **Geometry**: derived from `self.bounds` and a `scale = side / 128` reference factor; icon inset, corner radius, shadow, hairlines, and badge all scale from it. Badge placement uses the logo's measured alpha content rect (the glyph is wide, not square) so the badge sits by its visible edges.
- **Caching**: a `TileChrome` (backdrop image, overlay image, icon path) is rebuilt only when the tile size changes.
- **Appearance**: the badge is white with a tight contour halo plus a soft drop shadow so it stays legible over bright video.

### Interfaces and contracts

- **Public API surface**: `SRDockTileController` (constructed by the app delegate).
- **Inputs**: `showCameraOnDockTile`, `flipCameraHorizontally`, camera availability; the shared session.
- **Outputs**: activation-policy changes; `NSDockTile` display; a video-data output attached to the shared session.

## Key design decisions (recorded)

- **Decision**: request no buffer size on the Dock output.
  - Context: requesting small (236x236) buffers renegotiated the shared session's device format and blurred the panel and status bar whenever the Dock tile was on.
  - Chosen: request BGRA only; crop and downscale in software on the sample-buffer queue.
- **Decision**: match the system notification badge by measurement.
  - Context: a guessed badge read as the wrong size next to real Dock badges.
  - Chosen: measured ratios from Messages' badge on the real Dock, recorded in `Metrics` with their origin.
- **Decision**: correct the sample-buffer delegate signature.
  - Context: a stale Swift-2 signature never matched the protocol, so AVFoundation never called it and the tile showed the app icon instead of video.
  - Chosen: the modern `captureOutput(_:didOutput:from:)`.

## Open questions / known limitations

- The software crop/downscale copies full-resolution frames; vImage could reduce that cost if it matters.
