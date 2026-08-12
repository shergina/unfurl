# Posture Tracking - Product Vision and Roadmap

Status: building. The first increment exists: a once-per-second
shoulder-distance measurement probe, specified in spec.md next to this file.
This document remains the long-term goal document for the posture-tracking
feature, meant to be referenced and edited as the design firms up. As pieces
get built, their stable contracts graduate into spec.md (per the spec-driven
workflow in CLAUDE.md); everything else here stays vision, not behavioral
spec.

Formatting follows the repo spec rules: ASCII only, no tables, compact.

## North star

Unfurl keeps all of its current camera functions unchanged. On top of
that, it becomes a lightweight, private, on-device posture coach: it learns
what the user's own good posture looks like, watches for sustained drift from
it, and nudges the user with specific, actionable feedback. A separate,
simpler feature reminds the user to periodically get up and move.

The camera never leaves the device. All analysis is local (Apple Vision).
This privacy property is a core feature, not an afterthought.

## Privacy (core, non-negotiable, and a selling point)

Privacy is a top priority for this product, not a nice-to-have. Everything
stays local on the user's device: camera frames, pose/landmark data, the
calibrated baseline, and the questionnaire answers are all processed and
stored on-device only. Nothing is transmitted over the network, ever - no
cloud analysis, no telemetry of camera data, no account required.

This is deliberately a competitive advantage. Many posture and wellness apps
are vague about where camera data goes; "runs 100 percent on your Mac, never
leaves your device" is a claim we can make truthfully and market on. Any
future change must preserve it: if a proposed feature would require sending
camera-derived data off the device, it does not ship in that form.

## Scope

In scope, long term:
- A settings toggle to turn posture tracking on and off while the app runs.
- A first-run guided calibration ("preset") flow that records the user's
  personal good-posture baseline.
- Continuous, throttled analysis of the live camera while tracking is on.
- Sustained-bad-posture detection with a tolerance band and a time debounce.
- Actionable nudges that name the specific problem (chin up, shoulders level).
- A separate, independently toggled "time to move" periodic reminder.

Explicit non-goals:
- No medical or clinical claims. This is a coach, not a diagnostic tool.
- No cloud, no network transmission of frames, no account.
- No multi-person tracking. One user, centered, is assumed.
- No attempt to measure true anatomical lengths (cm). Everything is ratios.

## The core constraint that shapes everything: 2D vision

A single webcam produces 2D image-plane coordinates with no true depth.
Vision's body-pose joints are normalized image positions plus confidence.
This splits metrics into two tiers, and the product should lean on tier 1:

Tier 1 - strong signals (live in the image plane, frontal view):
- Shoulder unevenness: vertical difference between left and right shoulder
  joints, normalized by shoulder width. This is the single most reliable
  metric. It directly serves the "one shoulder higher than the other" goal.
- Head lateral tilt: angle of the eye-line (or ear-line) off horizontal.

Tier 2 - proxy signals (real depth is required; frontal cam infers it poorly):
- Slouching / forward-head. True slouch is forward (toward-camera) motion
  plus spine flexion. It splits into two components:
  - The visible vertical head-drop component: the head drops toward the
    shoulders, shrinking the eye-to-shoulder vertical gap. This is an
    in-image-plane change the camera sees directly, so it is close to
    tier-1 reliable. It is exactly the slouch ratio defined below.
  - The pure toward-camera component (head juts forward with little vertical
    drop): this needs depth and a front camera sees it weakly. "Leaned in to
    read" looks similar. Treat this component as best-effort, not exact.
  Because most real slouching includes the head-drop component, the slouch
  ratio is a solid primary signal; do not oversell the pure-depth part.

Design consequence: report tier-1 problems with confidence; treat tier-2 as
supporting evidence. Do not oversell forward-slouch precision in the UI.

## The second constraint: distance and camera geometry

- We cannot measure lengths in cm; we measure ratios. Every metric must be
  scale-invariant where possible, expressed against a stable unit such as
  shoulder width or inter-eye (inter-pupillary) distance.
- A baseline is only valid for roughly the same user-to-camera distance and
  the same camera position. If the user rolls their chair back or moves the
  laptop, ratios drift. So the system must estimate current distance (via
  shoulder width or inter-eye distance vs the calibrated value) and, when it
  has moved too far, prompt a recalibrate instead of reporting bad data.
- Baseline is coupled to camera placement. Moving the camera invalidates it.

## Feature 1: posture tracking

### Calibration (the "preset" flow), first run

Triggered the first time the user enables posture tracking (re-runnable
later from settings). Guided, on-screen:
1. A short questionnaire: height and age (and room for more later). Stored
   with the profile. How these values are actually used is an open question
   (see below) - we do not guess a formula here; at minimum they are recorded.
2. Ask the user to sit straight with clear instructions: shoulders back and
   even, chin up and level, sit tall, face the camera squarely.
3. Capture a short, stable window of frames (not a single frame) and record
   the baseline metrics below as ratios.
4. Show what was captured and offer Confirm or Redo.

Baseline metrics to record (all as ratios / angles, scale-invariant where
possible):
- Slouch ratio (primary slouch signal): the vertical distance from the
  eye-midpoint down to the shoulder-midpoint, divided by shoulder width.
  Vertical distance only (not straight-line), so head tilt does not pollute
  it. Smaller ratio means more slouch: as the head drops toward the
  shoulders the numerator shrinks. Note the mild confound that slouching also
  rolls the shoulders forward and can shrink shoulder width (the denominator)
  somewhat; the numerator shrinks more, so the ratio still drops. This metric
  captures the visible in-plane head-drop component of slouch well; pure
  toward-camera motion with no vertical drop stays weak (see the 2D
  constraint). Learned in practice (2026-08-06): head pitch pollutes the
  eye form - looking down at the keyboard drops the eyes and reads as
  slouch. The ears sit on the head's pitch axis, so the same ratio
  measured from the ears is immune to glances; the shipped metric is
  ear-anchored with the eye form as fallback (see spec.md).
- Shoulder tilt angle (line between shoulders vs horizontal).
- Shoulder-height asymmetry (normalized vertical shoulder difference).
- Head lateral tilt (eye-line or ear-line angle).
- Reference scale (shoulder width and inter-eye distance in normalized
  coords) - stored so we can later detect that the user has moved.

Calibration must reject a bad baseline: low joint confidence, user not
centered, poor lighting, or partial occlusion should block Confirm and
explain why rather than silently recording garbage.

### Live tracking

While tracking is on and the camera session is running:
- Throttle analysis to a few frames per second (2 to 5); no per-frame work
  on the main thread. Off-main analysis hands back finished values.
- For each analyzed frame, compute the current metrics and compare each to
  its calibrated baseline.
- Tolerance band: anything within ~10 percent of the baseline (per metric)
  is considered normal, not bad posture. The 10 percent is a starting point
  and should be tunable. Apply hysteresis so a metric hovering at the
  threshold does not flap between good and bad.
- Time debounce: only treat posture as bad after it has been continuously
  bad for at least ~10 seconds. Brief lapses (reaching for coffee) do not
  fire.

### Nudge

When posture has been bad past the debounce, notify the user with specific,
actionable feedback derived from which metric(s) breached, for example:
- shoulder asymmetry breached -> "level your shoulders"
- head tilt breached -> "straighten your head"
- neck/forward proxy breached -> "chin up, sit tall"

Delivery mechanism is user-selectable later (see open questions): a beep, a
system notification, and/or a status-item change. Detection and nudging are
separate concerns so the delivery choice can change without touching
detection.

### Relationship to the camera previews (decided)

Posture tracking is independent of the visible camera surfaces. The user can
turn off the menu-bar camera and the main panel and posture tracking keeps
running: while tracking is enabled it holds the shared capture session up on
its own (via the analysis output), regardless of whether any preview is
shown. Turning off the previews does not stop tracking; only the posture
toggle (or quitting) does.

Honesty caveat this creates: when all previews are hidden but tracking is on,
the camera is still active with nothing visible on screen. macOS shows its
own in-use indicator, and the app should also make the active state legible
(for example in the menu) rather than have the camera run silently.

### States to surface honestly (never blank-frame a failure)

- Camera off / not running: tracking cannot run; say so.
- Cannot see the user well (low confidence, off-center, dark): pause scoring
  and tell the user, do not emit false nudges.
- User appears to have moved from calibration distance: suggest recalibrate.
- Not yet calibrated: route to the calibration flow.

## Feature 2: move-around reminder

Independent of posture tracking, separately toggled in settings. On a
user-set interval (for example every 30 or 60 minutes), remind the user to
stand up and move for a bit. This needs no camera and no Vision; it is a
timer plus a notification. Consider pausing or resetting when the machine is
idle or asleep so it does not fire against an empty chair.

## How this fits the existing architecture (summary)

Detailed wiring lives with the code when we build. In brief, following the
current patterns:
- A new process-wide service (mirrors SRPhotoCaptureService) taps the shared
  SRCameraService session via attachOutput with an AVCaptureVideoDataOutput,
  runs Vision off-main, and publishes a posture state. No second capture
  session; consume the seams SRCameraService already exposes.
- New SRSettings preferences (posture tracking on/off, move reminder on/off
  and its interval) drive start/stop from the composition root, the same way
  selectedCameraDeviceID does today.
- The service is added to AppServices so surfaces observe it explicitly.
- A separate notifier observes posture state and delivers the nudge.

## Open questions (decide before or during build, do not guess)

- Nudge delivery (direction decided 2026-07-22, details in spec.md): a
  click-through, semi-transparent corner note excluded from screen capture
  is the primary channel; a status-item tint is planned as best-effort
  ambient state (never load-bearing - the item can be hidden by the notch
  or the user); the status menu will carry the status line plus snooze and
  recalibrate; system notifications are held in reserve as a possible
  later user-selectable option. The note deliberately ignores Focus modes.
  Still open: debounce and cooldown tuning, and whether fullscreen
  suppresses the note.
- Tolerance: is a single global 10 percent right, or should the band be
  per-metric (tier-1 tighter, tier-2 looser)? To be tuned later.
- Debounce (decided 2026-07-22, details in spec.md): per-issue, not
  global. An issue is voiced after ~4 s of sustained activity; an episode
  ends after ~2 s clean or instantly on recovery past half the tolerance
  band (one-sided per issue). Constants are code-level; tuning remains
  open.
- Recalibration UX: automatic prompt on detected movement, manual only, or
  both?
- Storage of the baseline: one profile, or multiple (desk vs couch)?
- How are the questionnaire answers (height, age) actually used? Options:
  tune default thresholds, adjust nudge copy, purely informational/stored,
  or feed future features. Undecided; recorded but not yet wired to anything.
- Move-reminder interval options and default.

## Known limitations to set expectations around

- Forward-slouch detection on a frontal 2D camera is a proxy, not a precise
  measurement. Shoulder evenness and head tilt are the trustworthy metrics.
- Baseline is tied to camera position and user distance; moving either can
  require recalibration.
- Requires adequate lighting and the user reasonably centered and unoccluded.
- Single-user assumption.
