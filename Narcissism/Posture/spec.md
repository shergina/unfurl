# Posture Subsystem

Scope: the early increments of the posture-tracking effort. VISION.md
next to this file remains the long-term goal document; this spec covers only
what is built: the measurement probe (per-second metrics logging), the
debounced corner posture note, the Track Posture menu toggle with its
snooze, and the calibration window that measures the user's own
good-posture slouch baseline.

## Behavior

- SRPostureAnalysisService attaches one AVCaptureVideoDataOutput to the
  shared SRCameraService session. The composition root starts and stops it
  as the tracking and snooze preferences direct.
- The probe runs only while Track Posture is on: the first item in the
  shared status/Dock menu, bound to the PostureTracking preference
  (default off, so tracking is opt-in). The composition root observes the
  preference and calls the service's start/stop; the preference publisher
  replays the persisted value, so quitting with tracking on resumes it at
  the next launch.
- While on, the attached output holds the shared capture session running,
  independent of any visible preview (the relationship decided in
  VISION.md), and macOS shows its camera-in-use indicator the whole time.
  Turning the toggle off detaches the output (no Vision work at all),
  resets the window and episode state, and clears the published status and
  joints so the corner note hides immediately. The camera service
  ref-counts its consumers, so the toggle never stops a session another
  surface (preview, photo capture, Dock tile) is still using; the session
  goes down only when the probe was its last consumer. A quick on-off
  flip is safe: stop waits for an in-flight attach to settle before
  detaching.
- Snooze: the menu's Snooze submenu (visible only while tracking is on)
  writes a deadline to the PostureSnoozeUntil preference - 5/10/15/30
  minutes or 1/2/5 hours from now; Resume Now, shown only while snoozed,
  is the whole-snooze off switch and clears the deadline immediately.
  While the deadline is in the future the probe is stopped exactly as the
  toggle stops it (output detached, note hidden, camera released to its
  ref-count), and the composition root schedules a one-shot timer that
  clears the deadline, so tracking resumes by itself and the menu's
  "Snoozed Until ..." title resets with the preference. Choosing a new
  duration mid-snooze replaces the deadline from now. Unchecking Track
  Posture discards any pending snooze: the master toggle always means a
  clean slate. The deadline is persisted, so a relaunch mid-snooze honors
  the remaining time (or resumes at launch if it passed while the app was
  closed). Timers do not fire during system sleep; a deadline slept
  through fires on wake.
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
  against the user's calibrated baseline: the PostureBaselineSlouchRatio
  preference, mirrored onto the analysis queue, written by the
  calibration window (see Calibration below). A window more than 5
  percent below baseline logs a warning-level "Slouching:" line naming
  the ratio and the deviation; ratios above baseline mean sitting tall
  and never alert. While no baseline is stored (<= 0 sentinel) the
  slouch alert, the issue tracking, and the corner note are all
  suppressed - nil status, trackers cleared - because there is nothing
  to judge against and nothing may pop over the calibration window.
  Decision (2026-07-24): the hardcoded 0.692 baseline of 2026-07-22 is
  retired; the preference is the only source. Deliberately no debounce
  or hysteresis yet on the log line: per-window feedback is what the
  experiment needs. The eventual nudge feature adds the ~10 s debounce
  per VISION.md.
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
  shoulders stayed at or below the confidence floor, otherwise "no
  body". The floor is 0.2 (0.3 until 2026-07-23; lowered to see whether
  the marginal frames it admits are usable or noise). Every line includes the window's frame count. Vision request
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
- Calibration window: opens whenever the probe would start (tracking on,
  not snoozed) and no baseline is stored - covering the fresh toggle-on
  and the launch replay of an install that predates calibration - and on
  demand from the menu's "Calibrate Posture..." item (visible exactly
  when Snooze is; choosing it clears any snooze, a deliberate resume).
  Both entry points funnel through SRMenuController, which owns the one
  window, so a second can never appear. The window floats above normal
  windows (level .floating: a brief, focused task must not get lost
  behind other work) and moves to the active Space when re-fronted
  rather than switching Spaces. Content: a live always-mirrored
  preview with the joint dots (the user positions themselves by seeing
  exactly what the tracker sees), the panel's placeholder behind it so
  camera failures and permission denials explain themselves in-window, a
  guidance line (can't see you / face the camera / move closer / sit up
  straight), and a Begin button enabled only while framing is good:
  confident shoulders, measurable eyes, shoulder width at least 0.15 of
  the frame width (below that reads as sitting too far away).
- Calibration capture: Begin starts a 3-2-1 countdown (which ignores
  detection loss), then collects the per-frame slouch ratio until 5
  seconds of sampling at the 4/s analysis rate (~20 samples). One
  unusable frame contributes nothing but does not pause; ~1 s of
  consecutive loss pauses the clock with "can't see you" (the lead-in
  frames are refunded), and resuming costs ~1 s of continuous detection,
  deliberately unsampled - whoever comes back is still settling in. A
  10 s wall-clock cap from capture start aborts back to positioning
  (also the guaranteed exit if frames stop arriving entirely).
  Completion gates: at least 12 usable samples, sample standard
  deviation at most 0.04, median inside 0.2...1.5; a failed gate returns
  to positioning with an explanation. The stored baseline is the median
  of the samples (robust to Vision's outlier frames), written to
  PostureBaselineSlouchRatio with the moment in PostureBaselineDate;
  nothing else is ever persisted - no frames, no files. The baseline is
  saved the moment the capture passes the gates; the finished screen
  ("Calibration finished.") then offers Looks Good, which closes the
  window, and Try Again, which returns to positioning for another pass
  whose result overwrites. Closing the window in the finished state is
  the same as Looks Good - the result is already saved.
- Calibration cancel: closing the window while no baseline is stored
  reverts Track Posture to off (no baseline, no tracking); with a
  previous baseline on file (the recalibrate path) closing just closes
  and tracking continues on the old value. Unchecking Track Posture
  while the window is open closes it.
- Dots overlay: the service publishes each analyzed frame's readings
  (shoulder width fraction, slouch ratio, joints; padded pipeline
  preferred, frame-normalized) on the main actor via onFrameSample. The
  calibration window renders the joints permanently as dots over its
  preview (shoulders red, eyes yellow, hidden when detection drops),
  positioned via layerPointConverted so aspect-fill cropping and
  mirroring apply to them exactly as to the video. The floating panel's
  camera view is still temporarily SRPostureDebugCameraView (accuracy
  aid), drawing the same dots behind a dotsVisible master switch - false
  in code as of 2026-07-24 (the earlier "currently true" note here did
  not match the code). Delete that view and its panel hookup when the
  accuracy question is fully closed; onFrameSample itself is permanent.

## Invariants

- No second AVCaptureSession; the probe consumes SRCameraService.attachOutput.
- No width/height request on the video data output: asking the shared
  session for scaled buffers renegotiates the device format and degrades
  every preview (same constraint the Dock output documents).
- All analysis is on-device (Apple Vision). No frame, landmark, or derived
  value leaves the machine.
- Analysis stays off the main thread. Only finished Sendable values hop to
  the main actor: the per-frame sample and the per-window status. The log
  line is written on the analysis queue.

## Open questions

- Whether the per-second measurement log survives once real metrics land,
  and at what log level it should ship.
- Baseline staleness: the baseline is per-user and per-camera-placement,
  and moving the laptop or switching cameras silently invalidates it.
  Recalibrating by hand is the only remedy today; PostureBaselineDate is
  the hook for a future staleness heuristic (prompt on camera change?
  shoulder-width drift?).
