# Posture Subsystem

Scope: the first buildable increment of the posture-tracking effort. VISION.md
next to this file remains the long-term goal document; this spec covers only
what is built. What exists today is a measurement probe: it measures the
image-plane distance between the user's shoulders once per second and logs it.
No UI, no settings, no calibration, no nudges yet.

## Behavior

- SRPostureAnalysisService attaches one AVCaptureVideoDataOutput to the
  shared SRCameraService session. The composition root starts it at launch.
- While the output is attached, the shared capture session is held running
  for the whole app lifetime, independent of any visible preview (the
  relationship decided in VISION.md). macOS shows its camera-in-use
  indicator the whole time. A user-facing toggle is deliberately not built
  yet; it is the expected next increment, and until then the probe is
  effectively always on.
- Frames are paced on the sample-buffer queue to four analyses per second;
  frames in between are dropped before any Vision work happens. Analysis is
  faster than logging on purpose: single frames flicker (motion blur,
  exposure settling, a marginal pose), so each one-second window logs its
  best observation - the one whose weaker shoulder joint has the highest
  confidence - rather than whatever one frame happened to say. The 4 fps
  rate sits inside the 2-5 fps envelope VISION.md sets for live tracking.
- Each analyzed frame runs VNDetectHumanBodyPoseRequest (Apple Vision,
  on-device) on the probe's serial analysis queue, never on the main thread.
- Zoom-out experiment (temporary): the body-pose model is trained on
  full-body imagery and mostly fails on laptop framing, where a head and
  shoulders fill the frame. To measure whether that is fixable by
  preprocessing alone, each analyzed frame is measured twice: once raw, and
  once composited at the top of a reusable black canvas 2.5x the frame
  height, so the upper body becomes a small figure near the top of a mostly
  empty image, closer to the training distribution. Canvas pixels are 1:1
  with the frame, so distances from both pipelines are directly comparable.
  Each log line reports both ("plain [...] padded [...]"); the reported
  width x height shows which pipeline a measurement came from. The doubled
  Vision cost (8 inferences/s) is accepted for the experiment's duration.
  Exit condition: after enough normal-use data, either the padded pipeline
  clearly rescues detection (adopt it, delete the plain path) or it does
  not (delete it and pursue the segmentation approach in VISION.md); the
  losing path is deleted, not kept.
- The measurement is the distance between the left and right shoulder
  joints. Vision returns frame-normalized points, so the components are
  scaled to pixels first (aspect-correct); the log reports the distance in
  pixels and as a fraction of the frame width, the scale-invariant form the
  future metrics in VISION.md build on.
- Alongside the shoulders, each measurement reports the average height of
  the two eye joints from the same observation, as a fraction of the frame
  height (0 = frame bottom, 1 = frame top) and in pixels from the frame's
  bottom edge. On the padded pipeline the value is remapped from canvas to
  frame coordinates, so both pipelines report comparable numbers. Slouching
  reads as the value dropping. If either eye joint is at or below the
  confidence floor the line says "eyes n/a" instead. This is an exploratory
  input for the slouch ratio in VISION.md; note the raw eye height is not
  scale-invariant (moving the chair or laptop changes it too), which is why
  the eventual slouch metric divides the eye-to-shoulder drop by shoulder
  width instead of using this value directly.
- Every measurement also reports the shoulder tilt angle: the angle of the
  line between the two shoulder joints off horizontal, computed aspect
  correct in frame pixels (atan2 of the vertical over the horizontal
  separation). Signed degrees: positive means the subject's anatomical
  left shoulder is higher, 0 is level. Being an angle it is inherently
  scale-invariant. This is the tier-1 shoulder tilt metric from VISION.md.
- Whenever the eye heights are available, the line also reports the slouch
  ratio exactly as VISION.md defines it: (average eye height - average
  shoulder height) / shoulder distance, all in frame pixels. Vertical
  components only, so head tilt does not pollute it; the division makes it
  scale-invariant, so chair and laptop moves cancel out. Smaller means more
  slouch. This is the live metric the future baseline comparison will run
  on.
- Slouch alert (experimental, log-only): each window's best available
  slouch ratio (padded pipeline preferred, plain as fallback) is compared
  against a hardcoded baseline of 0.692, the user's own ratio measured
  sitting with deliberately perfect posture on 2026-07-22 (replacing the
  0.616 relaxed-straight value from the day before). A window more than 5
  percent below baseline logs a warning-level "Slouching:" line naming the
  ratio
  and the deviation; ratios above baseline mean sitting tall and never
  alert. The baseline is per-user, per-camera-placement state that belongs
  to the future calibration flow; hardcoding it is a stopgap for the
  experiment. Deliberately no debounce or hysteresis yet: per-window
  feedback is what the experiment needs. The eventual nudge feature adds
  the ~10 s debounce per VISION.md.
- Shoulder alignment alert (experimental, log-only): same cadence and
  pipeline preference as the slouch alert. A window whose tilt magnitude
  exceeds 3 degrees off level logs a warning-level "Shoulders misaligned:"
  line with the signed tilt and which shoulder to lower (positive tilt =
  the subject's anatomical left shoulder is higher, so lower the left).
  Unlike the slouch alert this needs no per-user baseline - level is level
  - though the 3 degree band is a tuning choice (tried 5 and 2 before
  settling here on 2026-07-22).
- Output goes to the unified log: subsystem com.shergin.narcissism, category
  Posture. Watch it with:
      log stream --predicate 'subsystem == "com.shergin.narcissism"'
  or via the Xcode console when running from Xcode.
- Failures are logged, never silent (the log is this feature's user-facing
  surface, so "never blank-frame a failure" applies to it). A pipeline with
  no usable measurement in a window reports its most informative failure:
  the best sub-threshold confidences if some frame saw a body but the
  shoulders stayed at or below the 0.3 confidence floor, otherwise "no
  body". Every line includes the window's frame count. Vision request
  errors, a failed output attach, and a failed canvas allocation are logged
  as they happen.

- Issue tracking (feeds the corner note): posture problems are a set of
  independent issues, each with its own debounce - slouching, left
  shoulder high, right shoulder high (the two tilt directions are
  distinct issues, so an overcorrection flip clears one and starts the
  other from zero). Per logging window each issue observes its metric
  one-sidedly as breaching, clean, strongly recovered (past half the
  tolerance band on its own side), or unknown (not measurable; the
  tracker freezes - eyes hidden freezes only slouching). An issue is
  voiced after being active ~4 windows (~4 s); an active episode ages
  through clean dips (hovering at the threshold is still the issue) and
  ends only via the dual-path clear: ~2 consecutive clean windows, or
  instantly on one strongly recovered window - so a decisive correction
  is rewarded immediately while a marginal one must hold. Five
  consecutive not-visible windows, or a capture timeline restart, reset
  every episode. The per-window warning lines in the log stay raw and
  undebounced on purpose: they are tuning telemetry; the note is the
  coached surface. Status transitions are logged ("Posture status: ...").
- Corner posture note (experimental prototype of the ghost-toast
  notification design): a small borderless non-activating panel pinned to
  the top-right corner of the main screen, visible only while there is
  something to say: one line per reported issue in stable declaration
  order ("Sit up straight", "Lower your left/right shoulder"), or
  "Posture: can't see you clearly". Good posture shows nothing - the note
  disappearing is the reward (decided 2026-07-22, replacing the earlier
  always-visible "Posture: good" state). Ghost properties per the
  notifications design (decided 2026-07-22):
  click-through (ignoresMouseEvents), semi-transparent HUD material,
  excluded from screen capture (sharingType none) so shared screens and
  recordings never show it while the user still sees it, present on all
  Spaces including fullscreen, and deliberately indifferent to Focus
  modes. Fade animations and an escalation cooldown from the agreed
  design are not built yet.
- Dots overlay (temporary accuracy test): the service publishes the latest
  analyzed frame's joint positions (frame-normalized, padded pipeline
  preferred) on the main actor via onJoints, and the floating panel's
  camera view is temporarily SRPostureDebugCameraView, which draws them as
  dots over the live image: shoulders red, eyes yellow, hidden when
  detection drops. Dots are sublayers of the preview layer positioned via
  layerPointConverted, so aspect-fill cropping and mirroring apply to them
  exactly as to the video. Currently dormant: a master switch in the view
  (dotsVisible, default false) keeps the dots invisible while all the
  plumbing stays wired, per the user's request on 2026-07-22; flip it to
  true to show them again. Still explicitly a test aid: delete the view,
  the panel hookup, and onJoints together when the accuracy question is
  fully closed.

## Invariants

- No second AVCaptureSession; the probe consumes SRCameraService.attachOutput.
- No width/height request on the video data output: asking the shared
  session for scaled buffers renegotiates the device format and degrades
  every preview (same constraint the Dock output documents).
- All analysis is on-device (Apple Vision). No frame, landmark, or derived
  value leaves the machine.
- Analysis stays off the main thread. Only finished Sendable values may hop
  to the main actor; today nothing does, the log line is written on the
  analysis queue.

## Open questions

- The settings toggle (in scope per VISION.md) and whether the probe should
  instead piggyback on an already-running session until the toggle exists.
- Whether the per-second measurement log survives once real metrics land,
  and at what log level it should ship.
