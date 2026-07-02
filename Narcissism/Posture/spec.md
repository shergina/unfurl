# Posture Subsystem

Scope: the early increments of the posture-tracking effort. VISION.md
next to this file remains the long-term goal document; this spec covers only
what is built: the measurement probe (per-second metrics logging), the
debounced nudge channels (corner note, sound, status-item tint), the
Track Posture menu toggle with its snooze, and the calibration window
that measures the user's own good-posture slouch baseline. The nudge
delay and channels are configured on the Settings window's
Notifications page (see UI/Settings/spec.md).

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
  Turning the toggle off suspends the output rather than removing it
  (removing an output from the running session stalls every preview for
  ~300 ms - the gray toggle blink; see Tools/spec.md): its connection is
  disabled, so no frames are delivered or converted and no Vision work
  runs, the window and episode state reset, and the published status and
  joints clear so the corner note hides immediately. The suspended output
  stays wired but releases its claim on the session; the camera service
  counts claims, so the toggle never stops a session another surface
  (preview, photo capture, Dock tile) is still using, and the session -
  taking the wired output down with it - stops when the probe was its
  last consumer. Turning the toggle back on resumes the output in place
  (no rewiring, no blink); if the session went down while suspended, a
  fresh output attaches during the new session's own warm-up. Lifecycle
  operations are chained, each awaiting its predecessor, so a quick
  on-off flip cannot interleave.
- Snooze: the menu's Snooze submenu (visible only while tracking is on)
  writes a deadline to the PostureSnoozeUntil preference - 5/10/15/30
  minutes or 1/2/5 hours from now; Resume Now, shown only while snoozed,
  is the whole-snooze off switch and clears the deadline immediately.
  The Settings window's Notifications page offers the same durations as
  a popup writing the same preference (see UI/Settings/spec.md), so the
  menu and the page always agree.
  While the deadline is in the future the probe is stopped exactly as the
  toggle stops it (output suspended, note hidden, camera claim released),
  and the composition root schedules a one-shot timer that
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
- Zoom-out experiment (temporary), round one, settled: the body-pose model
  is trained on full-body imagery and mostly fails on laptop framing,
  where a head and shoulders fill the frame. Each frame was measured raw
  ("plain") and composited at the top of a black canvas 2.5x the frame
  height ("padded"). Three days of normal use through 2026-07-30 (1994
  windows) met the exit condition decisively: of 1215 windows with any
  measurement, padded was the sole provider in 1171 and plain in 15, so
  the plain path was deleted per the losing-path-is-deleted rule. Known
  remaining failure: padded detection dies when the user leans in close
  (observed live: works at ~95 percent frame-height occupancy, gone at
  100), which round two targets.
- Zoom-out experiment, round two (temporary): the fixed 2.5x canvas stays
  as the control; the candidate is a head-adaptive canvas that keeps the
  implied figure plausibly proportioned at any sitting distance and screen
  tilt. VNDetectFaceRectanglesRequest runs on each analyzed raw frame (the
  face detector stays reliable up close and at odd angles where the pose
  model fails, which breaks the circularity of sizing padding by how big
  the user looks). The largest face box is exponentially smoothed (weight
  0.3) and remembered ~5 s across missed frames, then inflated to a full
  head (x1.3, growth upward; the box covers eyebrows to chin). The canvas
  is sized in head-heights - 7.5 tall, 5.5 wide, per the 7-8-heads figure
  rule - never smaller than the frame (a distant sitter gets little or no
  padding), head growth capped at 0.45 of the frame height to bound the
  allocation, dimensions quantized up to 128 px so the buffer is not
  reallocated as the smoothed box breathes. The frame is placed with the
  estimated head top anchored 5 percent below the canvas top and the head
  centered horizontally. The anchor never opens a black gap above the
  frame's top edge: when the estimated head top lies at or above the frame
  edge (the user so close the forehead is clipped), the frame sits flush
  with the canvas top instead, so the composite reads as a photo cropped
  at the forehead (ordinary) rather than a head ending mid-image under
  black (impossible). Content falling outside the canvas (the ceiling
  band when the screen tilts up) is cropped by the placement itself, and
  the canvas is re-blacked every fill so the moving placement leaves no
  ghosts. Pixels stay 1:1; joint positions and metrics are remapped
  through the frame's placement rect (both axes now), and the shoulder
  width fraction divides by the frame's width, not the canvas's, so both
  pipelines report frame-relative, comparable values. Each log line
  reports both ("padded [...] adaptive [...]"; "no face" marks windows
  where the face detector never fed the candidate). Live status prefers
  adaptive, padded as fallback. Cost: 8 pose + 4 face inferences/s,
  accepted for the experiment's duration. Exit condition: same rule -
  the losing canvas is deleted, not kept. Open question: at extreme
  lean-in the slouch ratio drifts with lens perspective even when
  detection holds; very-close windows may deserve low trust for the
  ratio.
- The measurement is the distance between the left and right shoulder
  joints. Vision returns frame-normalized points, so the components are
  scaled to pixels first (aspect-correct); the log reports the distance in
  pixels and as a fraction of the frame width, the scale-invariant form the
  future metrics in VISION.md build on.
- Alongside the shoulders, each measurement reports the average height of
  the two eye joints from the same observation, as a fraction of the frame
  height (0 = frame bottom, 1 = frame top) and in pixels from the frame's
  bottom edge. Values are remapped from canvas to frame coordinates
  through the frame's placement rect, so both pipelines report comparable
  numbers. Slouching
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
  slouch.
- The ear-anchored slouch ratio (added 2026-08-06): the same drop measured
  from the ears - (average ear height - average shoulder height) /
  shoulder distance; one confident ear suffices, both sit at essentially
  the same height. The head pitches about an axis through the ears, so a
  downward glance at the keyboard moves the eyes but not this ratio; the
  eye form read every glance as a slouch, which was the complaint that
  prompted the change. Wherever the active camera's entry has an ear
  baseline, this is the judged metric; the eye form is the fallback for
  ear-less frames and entries (headphones, a hood, hair over both ears) -
  exactly the old behavior. The eyes also keep the jobs pitch cannot
  pollute: the eye:shoulder geometry probe (interocular separation is a
  horizontal segment, preserved under pitch) and the calibration
  usability gates. Decided cost: a chin-to-chest droop with a tall torso
  no longer reads as slouch - it is the same motion as a keyboard glance,
  only sustained, and treating it as posture was the false-positive
  engine.
- Whenever the eye heights are available, the line also reports a rough
  estimate of the share of the frame height the person occupies: from the
  frame's bottom edge (the body runs off it) to an estimated head top,
  taken as half the eye-to-shoulder drop above the eyes. Added 2026-07-30
  to inform the zoom-out framing questions (how much of the frame the
  visible person actually fills); rough by design, not a posture metric.
- Slouch alert (experimental, log-only): each window's best available
  slouch ratio (adaptive pipeline preferred, padded as fallback) is compared
  against the user's calibrated baseline for the camera in use: the
  PostureBaselines map's entry for the active AVCaptureDevice.uniqueID,
  mirrored onto the analysis queue (the map combined with the camera
  service's onSelectedDeviceID, so a camera switch swaps the baseline),
  written by the calibration window (see Calibration below). Piecewise
  strictness (2026-08-06, the pitch-tuning outcome so far): the entry's
  gaze angle theta (middle-of-screen to straight-ahead, from the gaze
  probe; negative = screen below the gaze line) picks a regime at the
  -10 degree boundary, and each regime carries per-metric percent
  ladders (SRSettings.lowCamera*/highCamera*Percents - mediums 3 ears /
  5 eyes below the boundary, the measured flat region, and 7 / 8 above
  it, still being tuned).
  Which of the five stops applies is the Settings page's slouch
  strictness slider, live since 2026-08-08 (it stored a value nothing
  read before that). It writes PostureSlouchStrictnessIndex, a fresh key
  defaulting to the middle stop - which is what shipped hardcoded - so
  no one inherits a position from the inert control, and
  PostureSlouchDepthTolerance is left declared but dead. The index rides
  the same sink as the baseline and the camera, so moving the slider
  lands on the next window rather than the next calibration, and it is
  clamped on read: the preference is a stored number and must not index
  off the end of a ladder.
  Below the boundary the index picks a hand-tuned stop straight from the
  table. Above it the fitted line is the middle stop and a multiplier
  ladder moves it: highCameraAtScreenLadder [1.8, 1.5, 1.0, 0.85, 0.7]
  for both at-screen lines, and highCameraLookingDownLadder
  [1.25, 1.1, 1.0, 0.9, 0.8] for the down-gaze one. The at-screen ladder
  spreads wider at the relaxed end and less far at the strict end than
  the low tables imply about themselves ([1.6, 1.2, 1.0, 0.8, 0.6]
  ears), so a slider position is not quite the same relative strictness
  across the boundary - relaxed is looser above it, strict is milder.
  The down ladder is tighter on purpose: sharing
  the at-screen one multiplies an already-large tolerance, and on a
  shallow camera the relaxed stop reached 38 percent, which never fires.
  It is sized so a notch moves the down tolerance by roughly the points
  it moves the at-screen one (solving that across the sampled thetas
  gives 1.20-1.33 relaxed, 0.74-0.84 strict). Both ladders keep 1.0 in
  the middle - that is the value the decisions were made at. The down
  stop stays looser than the at-screen stop at every stop and theta,
  which the ordering depends on - but after the at-screen ladder widened
  to 1.8 the margin at the relaxed stop on a near-boundary camera is
  only about 0.35 points, so the down correction is close to a no-op in
  that one corner. Widening at-screen further, or tightening the down
  ladder, inverts it. Recorded cost: at the shallow end the
  down stops land about a point apart, which is the decide-by-feel noise
  floor, so adjacent notches may be indistinguishable there even though
  the full sweep is not (PITCH_TUNING.md).
  Above the boundary, and only when the entry carries a measured theta,
  the medium stop now comes from a line in theta instead of the table
  (added 2026-08-07, provisional): percent = slope * theta + intercept,
  with theta clamped to the span the line was fitted over
  (SRSettings.highCameraFitThetaRange) so an unusual angle cannot
  extrapolate its way to a nonsense tolerance. Three lines - ear at
  screen, ear looking down, eye at screen. Below the boundary, and for
  a pre-probe entry with no theta, nothing changed: the tables are
  still the whole threshold and no down-gaze stop exists, so the
  correction cannot fire there. The two ear lines are least squares
  over four monitor points spanning -9.9 to -0.6 (R2 0.89 and 0.99, all
  residuals under 1 point, which is the decide-by-feel noise floor); a
  fifth point at -8.9 was deleted as an outlier, flagged by
  leave-one-out on both metrics. The eye line is not refitted and still
  rests on two points including that deleted row, making it the weakest
  of the three; it only judges when the ears are unavailable
  (PITCH_TUNING.md). The mechanism is the durable part, the numbers are
  working data from one camera.
  Which ear line applies is decided per window by head pitch, straight
  off the face detector, against a fixed drop below the calibrated
  middle-of-screen pose - the same pose the baseline itself is captured
  at: PostureBaseline.uprightFacePitch (that pose's absolute pitch in
  degrees, stored since 2026-08-07 precisely because the detector's
  zero is per camera and a live reading means nothing without it) plus
  SRSettings.lookingDownPitchBelowScreenDegrees. Down is
  the positive pitch direction, so the drop adds. The anchor is per
  camera; the drop is not. Latched with hysteresis
  (lookingDownPitchHysteresisDegrees), engaging at the threshold and
  releasing a few degrees under it, so a gaze resting on the boundary
  does not flip the stop every window. An entry predating the pitch
  reference, or a window with no face, holds the at-screen stop -
  the stricter of the two.
  Anchored at screen centre rather than straight-ahead since
  2026-08-07. Screen centre is the more repeatable pose by about 2.2x
  across a day of calibrations - it is a target the user can aim at,
  where "straight ahead" is interpreted afresh each time - and the
  ahead anchor dragged the trigger around with theta while the screen
  stayed put, landing anywhere from 0.05 to 16.9 degrees past the
  screen's bottom edge across four setups. Off screen centre the depth
  is fixed and the only variation left is real screen height. Theta is
  no longer part of the trigger at all; it still selects the regime and
  evaluates the lines.
  This replaced an eye-minus-ear divergence test the same day. Both
  read head pitch, but the divergence read it indirectly, through a
  geometric difference of a few points against comparable noise, and it
  missed real down-gazes; it also needed both metrics at once, so it
  went blind in exactly the eye-fallback case that needs the correction
  most. Pitch survives losing the ears. What did not change: the eye
  metric still has no down-gaze line and never gets the correction, no
  eye down percents having been decided.
  The drop is 20 degrees, which on every camera sampled so far lands
  3.7 to 8.8 degrees past the screen's own bottom edge - clear of
  ordinary low-screen reading, without waiting for the deepest possible
  glance. Replayed against 103 windows of live pitch it fires in 18-46%
  of them, between the 37-69% of the 15 degrees tried before it and the
  0-11% of the 30 before that (PITCH_TUNING.md keeps all three; the
  constant is the single thing to change).
  The "Head pose:" line carries the live pitch, the threshold, the
  resolved gaze, and the effective ear limit every window.
  The breach drop is that percent of the metric's
  baseline, floored. A camera without a theta runs the looser high
  regime until recalibrated. The strictness slider is disconnected
  from slouch while this is in place (the intended end state: the
  slider picks the index into the active camera's regime); measured
  and derived spans stay stored, dormant. A per-window
  "Below baseline:" line reports both metrics' current drop as a
  percent of baseline (positive = below), so tuning bands read
  straight off the log. A "Head pose:" line rides alongside it (added
  2026-08-07): face-detector pitch and yaw in degrees plus the eye/ear
  width ratio, all telemetry only - nothing reads them yet. They exist
  to pick the trigger and threshold for a future
  loosen-when-turned-away correction from measured numbers rather than
  a guess (PITCH_TUNING.md). Since
  2026-08-06 the judged metric is ear-preferred: a window with an ear
  reading, on a camera whose entry has an ear baseline, is judged
  entirely in ear units (ear baseline, ear span, ear median); any other
  window is judged in eye units as before, against the eye regime
  percent. (The eye fallback was disabled briefly on 2026-08-06 so one
  decided strictness meant one thing during early collection; restored
  the same day when the regimes gave each metric its own percent.) Each metric keeps its own
  baseline, span, and rolling median - units never mix, they differ by
  the head-pitch term - and the warning line names the judge
  ("Slouching (ears):" / "(eyes):") so the two regimes are tellable
  apart in telemetry. The breach
  test is slouch depth (added 2026-08-02): the drop below baseline as a
  fraction of the camera's slouch span - measured by demonstration on
  the anchor calibration, derived from the geometry probe everywhere
  else (see the anchor bullet). A window deeper than the
  depth tolerance logs a warning-level "Slouching:" line naming the ratio
  and the depth percent; ratios above baseline mean sitting tall and
  never alert. Rationale: the ratio's sensitivity to a given physical
  slouch (the gain) depends on the camera's height - an elevated monitor
  camera converts the forward-lean component of a slouch into apparent
  vertical drop, reading 2-3x stronger than a laptop camera - so a
  percent-of-baseline threshold tuned on one camera is wildly miscalibrated
  on another; the span measures each camera's gain directly and makes one
  strictness setting mean the same thing everywhere. The tolerance is the
  PostureSlouchDepthTolerance preference (default 0.30), set by the
  strictness slider on the Settings window's Posture page over five
  stops - 0.6, 0.5, 0.4, 0.3, 0.2 of the span, relaxed to strict - and
  mirrored onto the analysis queue like the baseline. The resulting
  breach drop is floored at 0.01 absolute (0.02 until 2026-08-06,
  lowered so the piecewise ladders' strict ear stops are real; the
  history: 0.03 on 2026-08-02, 0.025
  then 0.02 on 2026-08-03): with the rolling-median accusation (see
  issue tracking) frame jitter no longer reaches the breach test, so
  the floor guards only what averaging cannot remove - natural
  settling, genuinely sitting a little lower than at calibration
  (observed: a sustained 0.021 below baseline while sitting well, which
  bounds the floor from below). The floor is absolute and
  camera-independent; it only clips ladder stops that a small span would
  push under it. For a shallow habitual slouch the clip is still
  substantial - a 0.047 span leaves stops at 0.028/0.024 live and
  floors the rest at 0.02 - so the floor remains the strict end of the
  de facto ladder there. A camera
  without a usable span (calibrated before the two-pose flow, or the flow was
  abandoned mid-slouch) is judged against a nominal span of 0.2 x its
  baseline (SRSettings.nominalSlouchSpanFraction); the 0.2 is chosen so
  the depth ladder reproduces the previous percent-of-baseline ladder
  (12, 10, 8, 6, 4 percent) stop for stop - the fallback IS the old
  behavior, and the old PostureSlouchTolerance preference migrates once
  by dividing by 0.2 (exact on every stop), then is never written again.
  Its log line keeps the old percent-below-baseline phrasing so the two
  regimes are tellable apart. (History: a
  hardcoded 5 percent through 2026-07-31, then a 15...5 percent ladder
  at default 10; live testing that day found the whole ladder too loose,
  real slouching going unflagged, so it was tightened to 12...4 at
  default 6; 2026-08-02 replaced percent-of-baseline with depth after
  monitor testing showed the same slight slouch reading 25 percent below
  baseline on an elevated camera.) While the active camera has no
  baseline stored (no map entry) the
  slouch alert, the issue tracking, and the corner note are all
  suppressed - nil status, trackers cleared - because there is nothing
  to judge against and nothing may pop over the calibration window. This
  is also the state while an uncalibrated camera the user picked
  explicitly is active: the switch goes quiet until calibrated (the
  calibration gate below keeps Automatic from ever landing here on its
  own).
  Decision (2026-07-24): the hardcoded 0.692 baseline of 2026-07-22 is
  retired; the preference is the only source. Deliberately no debounce
  or hysteresis on the log line: per-window feedback is what the
  experiment needs. The nudge debounce lives in the issue tracking
  below, not here.
- Shoulder alignment alert (experimental, log-only): same cadence and
  pipeline preference as the slouch alert. A window whose tilt magnitude
  exceeds the shoulder tolerance logs a warning-level "Shoulders
  misaligned:" line with the signed tilt and which shoulder to lower
  (positive tilt = the subject's anatomical left shoulder is higher, so
  lower the left). Unlike the slouch alert this needs no per-user
  baseline - level is level. The tolerance is the
  PostureShoulderTolerance preference, stored as a slope (the height
  difference between the shoulder joints over their separation) with
  five slider stops - 12, 10, 8, 6, 4 percent, relaxed to strict,
  default
  10 - and converted to degrees (atan) when mirrored onto the analysis
  queue, since the evaluation compares degrees. The default 10 percent
  is ~5.7 degrees. (History: a hardcoded 3-degree band, tuned from 5 and
  2 on 2026-07-22, then a 5...1 percent ladder at default ~2.9 degrees;
  live testing on 2026-07-31 found even the relaxed end too strict, a
  barely-visible tilt nagging, so the ladder was raised to 9...2 percent,
  ~5.1 to ~1.1 degrees, at default ~4.0; on 2026-08-03 the whole 9...2
  ladder still read too strict on every camera, so it was raised again
  to 12...4 percent, ~6.8 to ~2.3 degrees, at default ~5.7, and the
  stored value was cleared once so the new default takes effect.)
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
  tracker freezes - a head with neither ears nor eyes freezes only
  slouching). The slouch
  observation is asymmetric since 2026-08-03 - slow to accuse, instant
  to forgive: the breaching verdict comes from a rolling median of the
  last 8 windows' ratios (one median buffer per metric, ear and eye, the
  judged metric's buffer decides; at least 4 measured, else the raw value
  decides alone as before; unmeasured and not-visible windows push nil
  so stale readings age out of the buffers, and the buffers reset
  wherever the trackers do), while strong recovery is judged on the raw
  window value - sitting up decisively is a large, unambiguous move and
  the note must vanish right away, not after the median catches up.
  Rationale: onset detection happens near the threshold where frame
  jitter can fake it (a slouch must now occupy about half the recent
  window - single frames and coffee reaches structurally cannot
  accuse), which is what allowed the breach-drop floor to drop to the
  settling amplitude; recovery is a move several times the noise, raw
  is trustworthy there, and a false clear is cheap (the still-breached
  median re-arms the episode). Known cost: a marginal correction -
  rising to just above the breach floor but short of strong recovery -
  now clears via the median's lag plus the clean windows (~6 s instead
  of ~2), which leans further into "hovering at the threshold is still
  the issue". The per-window warning log line stays raw and carries the
  median alongside, so both views are visible in the telemetry. An
  issue is
  voiced after being active for the nudge-delay preference
  (PostureNudgeDelaySeconds, default 10 s; windows are ~1 s so seconds
  map straight to a window count, mirrored onto the analysis queue the
  same way the baseline is; the Settings window offers 5 s to 5 m). An
  active episode ages through clean dips (hovering at the threshold is
  still the issue) and ends only via the dual-path clear: ~2 consecutive
  clean windows, or instantly on one strongly recovered window - so a
  decisive correction is rewarded immediately while a marginal one must
  hold. A detection dropout shorter than 3 consecutive windows coasts:
  the last evaluated status stays published (nil during the camera's
  warm-up, so startup never flashes the note), trackers freeze, and the
  history samples stay honestly not-visible; only the 3rd consecutive
  empty window publishes "can't see you" (added 2026-07-30). Five
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
  click-through (ignoresMouseEvents), semi-transparent adaptive material,
  excluded from screen capture (sharingType none) so shared screens and
  recordings never show it while the user still sees it, present on all
  Spaces including fullscreen, and deliberately indifferent to Focus
  modes. The note is one of three independently
  toggled nudge channels (PostureNoteEnabled, default on): while its
  preference is off the status is treated as nothing-to-say and the
  note never shows. All three channels off means tracking runs
  silently.
- Note appearance (redesigned 2026-07-30): the system notification
  banner's anatomy instead of the earlier bare dark chip. Adaptive
  popover material following light and dark mode, 16 pt rounded corners
  cut with the effect view's maskImage (the only clip that reaches the
  behind-window material; a layer mask leaves opaque corners), a
  leading 24 pt hierarchical SF Symbol in a fixed slot:
  figure.seated.side tinted orange for corrections,
  eye.trianglebadge.exclamationmark in secondary gray for can't-see-you.
  Each issue is its own 13 pt semibold line in the primary label color:
  the corrections are peers, so no title-and-detail hierarchy (a
  banner-style bold-first-line variant was tried and dropped the same
  day). The panel
  hugs its content above a generous floor (280 x 58) so it reads as a
  banner, not a chip, and short messages do not jitter its size. Shows
  and hides with a ~0.25 s fade, instant under Reduce Motion; a fade
  racing the opposite fade resolves to the latest state. The escalation
  cooldown from the agreed design is still not built.
- Note ghost mode (PostureNoteGhost, default on; a checkbox on the
  Settings window's Notifications page, enabled only while the note
  channel is): while on, the visible note fades to almost nothing when
  the pointer is inside its frame and back when it leaves - the same
  behavior the floating panel's ghost mode has. The note is
  click-through, so tracking areas never fire; hover is watched with
  global and local mouse-moved monitors, installed only while the note
  is on screen and ghost is on (keep background cost low), and torn
  down when it hides. The hover fade is instant under Reduce Motion.
- Sound channel (SRPostureSoundController, PostureSoundEnabled default
  off): plays the chosen system beep (PostureSoundName, one of the
  soundNames list, default Ping) when a newly voiced issue appears in
  the status - one beep per new issue, never per window; the upstream
  debounce keeps voicing rare. A not-visible spell keeps the voiced set,
  so briefly leaving the frame and returning with the same issue does
  not beep again; the probe stopping clears it. The Settings window's
  sound picker previews the beep on selection.
- Status-item tint channel (PostureStatusItemTint, default off): while
  any issue is voiced the menu-bar item lights up - the template icon
  tints orange, or the live camera gets an orange border. Best-effort
  ambient state per VISION.md, never load-bearing (the item can be
  hidden by the notch or a crowded bar). See the Status Item spec.
- Calibration window: opens whenever the probe would start (tracking on,
  not snoozed) and nothing is calibrated anywhere (the baselines map is
  empty) - covering the fresh toggle-on and the launch replay of an
  install that predates calibration - and on
  demand from the menu's "Calibrate Posture..." item (visible exactly
  when Snooze is; choosing it clears any snooze, a deliberate resume).
  The auto-open checks the whole map, not the active camera, because
  toggling tracking on also flips the calibration gate, which may still
  be switching the camera underneath; whenever any baseline exists, the
  camera the gate settles on is a calibrated one. The window can also be
  opened targeted at a camera that is not active (the new-camera nudge
  below): the target is applied as the camera service's temporary device
  override for the window's lifetime - the user calibrates looking
  through the camera being calibrated - and cleared on close, never
  persisted, so a declined calibration (or a crash mid-way) settles back
  onto the policy-resolved camera by itself. An already-open window
  keeps its own target.
  Both entry points funnel through SRMenuController, which owns the one
  window, so a second can never appear. The welcome flow's posture page
  (UI/Welcome/spec.md) embeds the same SRPostureCalibrationViewController
  instead of opening this window; while that page is up the funnel
  re-fronts the welcome window, keeping calibration a single surface.
  That page runs with Track Posture still off (it starts and stops the
  probe directly) and turns tracking on exactly when a capture completed.
  It also hides the view controller's inline action buttons
  (showsActionButtons) and renders its own, driving the session through
  its public begin/redo and phase publisher. The window floats above normal
  windows (level .floating: a brief, focused task must not get lost
  behind other work) and moves to the active Space when re-fronted
  rather than switching Spaces. It opens centered on the display of the
  camera it calibrates (the user must face that camera, so the guidance
  belongs on its screen): built-in camera on the built-in display,
  external camera on an external display. No API ties a camera to a
  display, so external->external is a heuristic; with several external
  displays the interaction screen (the pointer's, see the placement rule
  in UI/Settings/spec.md) wins when it is one, otherwise the first
  external, and with no match at all it falls back to the interaction
  screen. This camera-follows placement is deliberately the exception to
  that rule: the window is part of the measurement (the user must face
  the camera being calibrated, or the baseline encodes an off-axis
  pose), the Display Calibrator Assistant precedent.
  Two pages, both laid out at one shared size
  (SRPostureCalibrationViewController.contentSize, 480x520), so the
  window never resizes mid-flow - it is floating and centered, so a
  resize would move it under a user who is trying to hold still.
- Calibration reminders page (added 2026-08-07): the window opens on the
  good-posture reminders (hips back, sit tall, shoulders level) with a
  Ready button, and only then swaps in the capture page. The list is
  SRGoodPostureReminders, defined once and shared with the welcome
  flow's good-posture page, which is why those strings are namespaced
  posture.good rather than welcome. A one-line secondary subtitle under
  the title says what the list is for ("Hold this while the camera
  measures you. It becomes the baseline you are coached toward"), added
  2026-08-07 against screenshots: both hosts show this page in a window
  sized for the camera page, and without it a 234pt list floated
  between two ~120pt voids and read as content that failed to fill the
  window. Redistributing that whitespace does not fix it - the page
  needs something that earns the space, and the stakes are the one
  thing worth saying here. Row spacing is 22 for the same reason. This
  is not in tension with the less-text goal, which is about the capture
  screens, where text competes with a button press; this page's whole
  job is to be read before anything is measured.
  Shown before every calibration, not
  only the first: the baseline is whatever the user happens to hold
  during the capture, and a bad one fails silently - the app goes on
  confidently coaching toward a slouch and the user has no way to tell.
  One extra click is the whole cost. Ready is deliberately not Begin
  (nothing is measured on this page, so hammering Return past it costs
  nothing), and its button sits at the same height as Begin so the
  pages do not shuffle. The capture page's view is loaded when the
  window opens, not when Ready is pressed, so the camera warms up and
  the framing guidance is already settled when the page appears. The
  welcome flow does not get this page - its own good-posture page
  already sits immediately before the camera page.
  Capture page content: a live always-mirrored
  preview, the panel's placeholder behind it so
  camera failures and permission denials explain themselves in-window,
  the guidance block (below), and a Begin button enabled only while
  framing is good:
  confident shoulders, measurable eyes, shoulder width at least 0.15 of
  the frame width (below that reads as sitting too far away). While the
  window is open the per-window evaluation is muted exactly as when
  uncalibrated, so the corner note never nags mid-calibration; trackers
  restart clean after it closes.
- Guidance block (three slots, added 2026-08-07; replaced a single
  centered paragraph): an optional status line (a capture failure, or
  the upright confirmation), the pose instruction in 15pt semibold, and
  a hold line in 13pt secondary. Every screen has the same shape, so
  the only thing the eye has to find is which instruction is showing;
  the previous run-on sentences differed in shape per step and buried
  the part that changed mid-clause, which is what let people press
  Begin without registering where to look. The instruction is one short
  line per pose - middle of your screen, straight ahead, slouch the way
  you normally do - and is held unchanged from
  the gate through the countdown and the capture, so it never swaps out
  from under someone who read it, and the pose is still named on screen
  while it is being recorded. (Before this, both the upright countdown
  and its capture said only "Measuring your posture - hold still",
  dropping the gaze and posture instruction for the entire five seconds
  that were actually being measured.) The hold line carries the part
  that does not change - best posture, hands on your keyboard - on
  every pose except the slouch, which contradicts it and asks for the
  hands alone; during a capture it becomes "Hold still - measuring" or
  the paused note. Sizing (settled 2026-08-07 against screenshots): the
  band is 46pt, the two-line height every normal step shows, not the
  59pt three-line worst case - reserving the worst case left about 27pt
  of dead air under the text on every screen a user actually sees, on
  top of the 20pt the hidden progress bar reserves anyway, and the
  lower panel read as unfinished. The block is centered, so the
  three-line states overflow the band by about 7pt at each end, which
  costs nothing: the only states that reach three lines (a capture
  failure, and slouchReady) are exactly the ones with the progress bar
  hidden below them, so the growth lands in empty space and nothing
  moves. Hands on keys pin the sitting distance to real
  working posture (added 2026-08-06), observed to make the captured
  distance far more repeatable than a free-floating "sit straight"; the
  middle-of-screen gaze is the working gaze, the reference both gaze
  probes difference against. No slot says "press Begin": Begin is the
  only enabled control on screen, and repeating the cue on four screens
  was pure text tax. Everything below the band is positioned from the
  band, not from the text, so the progress bar and the buttons hold
  still as lines come and go - they used to hop whenever the wrap count
  changed.
  (Wording history, all 2026-08-06:
  "look at yourself" pinned the gaze to wherever the calibration window
  sat, reading tall on a large monitor; "middle of your screen" fixed
  that; "bottom of your screen" - the lower-envelope idea, baseline at
  the lowest legitimate gaze so down-gazes never eat tolerance - worked
  at normal heights but collapsed sensitivity on very low screens,
  where the envelope is wide; superseded by middle-gaze baseline plus
  the piecewise regimes, with the bottom gaze kept for a while as a
  measured probe instead of the anchor - and dropped entirely
  2026-08-07, see the capture bullet.)
  No step counter, considered and rejected 2026-08-07 when the flow was
  still variable-length (the bottom-gaze leg ran only above the
  boundary, so the total was unknown at the start and could shrink
  mid-flow). The flow is fixed-length now that the leg is gone, so a
  counter is buildable - it just is not worth it at two or three steps;
  the changing instruction and the
  progress bar filling carry the forward motion instead.
- Calibration capture (hybrid since 2026-08-03: the slouch pose runs
  only while no anchor exists - exactly once, ever; every later
  calibration is single-pose and derives its span, see the anchor bullet
  below): Begin starts a 3-2-1 countdown (which ignores detection
  loss), then collects the per-frame slouch ratio until 5 seconds of
  sampling at the 4/s analysis rate (~20 samples). The countdown digit
  is 64pt, down from 96pt (2026-08-07): those three seconds are the
  built-in margin for someone who pressed Begin without reading, so the
  instruction under the digit has to outweigh it, and at 96pt the digit
  won. One unusable frame
  contributes nothing but does not pause; ~1 s of consecutive loss pauses
  the clock with "can't see you" (the lead-in frames are refunded), and
  resuming costs ~1 s of continuous detection, deliberately unsampled -
  whoever comes back is still settling in. A 10 s wall-clock cap from
  capture start aborts the pose (also the guaranteed exit if frames stop
  arriving entirely). Completion gates per capture: at least 12 usable
  samples, sample standard deviation at most 0.04, median inside
  0.2...1.5. The upright capture runs first and also collects the
  per-frame eye:shoulder width ratio (rho, the geometry probe: eye
  separation over shoulder separation, aspect-correct pixels; both
  segments are horizontal in the world, so the ratio encodes anatomy
  times perspective - which segment sits closer to the camera). Both
  captures additionally collect the ear-anchored ratio per frame,
  independent of the eye-based usability gate; an ear median counts
  only when it clears the same 12-sample bar, so an entry never carries
  a flimsy ear pair - short of the bar the entry is eye-only and
  evaluation stays on the eye metric (added 2026-08-06). The
  moment the upright capture passes its gates, its median, the rho
  median, and the upright ear median are saved as the entry
  (overwriting, and clearing
  any stored slouched value: a new baseline must never pair with an old
  slouch - recalibrating after moving the screen would mix geometries).
  Every run then walks one gaze probe, resting for Begin at
  lookAheadReady: the same 3-2-1 and 5 s capture looking directly
  ahead, which yields theta. Hands on the keyboard throughout. The
  deltas against the middle-gaze upright capture - eye ratio, ear ratio
  (both metrics, so the eye fallback gets its own numbers), and face
  pitch in degrees from the face detector's observation,
  camera-relative, sign settled empirically - are logged ("Calibration
  gaze captured") and folded into the entry (eyeGaze, earGaze,
  pitchDelta), alongside the absolute middle-of-screen pitch
  (uprightFacePitch) the looking-down test needs. The ahead pitch delta
  is theta, the regime selector and the input to the fitted lines. The
  probe is auxiliary, so any failure (gates, timeout) logs a skip and
  the flow moves on with nil deltas - it never rests, retries, or
  blocks.
  A second leg once ran here: bottom-of-screen, measuring the gaze
  envelope, gated on theta clearing the -10 boundary. Removed
  2026-08-07. It briefly fed the looking-down trigger, which was
  anchored at the measured screen-bottom pitch; once that anchor moved
  to a fixed drop below screen centre nothing read
  eyeBottom/earBottom/bottomPitch at all, and the leg was costing a
  gate, a Begin press and a 5 s capture on every high-camera
  calibration to write three fields no one opened. Its fields are gone
  from PostureBaseline too, so any values already on disk are dropped
  on the next write. Recoverable by recalibration if the eye work ever
  needs a measured envelope.
  After the probe a single-pose run goes straight to the finished
  screen. A two-pose run rests at slouchReady, status "Upright posture
  captured" over the slouch instruction - the pause tells the user what
  is coming and lets them start when ready.
  (An auto-started countdown was tried first and dropped 2026-08-04: it
  landed before the user realized a second pose was being asked for.)
  Begin starts a 3-2-1 (the countdown is
  the time to settle into the pose) and the same 5 s
  capture and gates, plus the span gate: the slouched median must sit at
  least 0.04 below the upright one. The gate judges the eye metric
  (always present on a usable capture); the ear span only has to come
  out positive - a nonsense ear span drops the slouched ear median, and
  that camera's ear span is derived or nominal like any other. The
  gate's only job is "did you move
  at all", not "was it a big slouch": both sides are medians of 12+
  samples, far tighter than the per-frame stddev gate, so 0.04 clears
  noise comfortably while accepting a low-gain camera's honest slouch.
  (History: 0.08 on day one rejected real slouches on the laptop camera,
  whose whole span is ~0.05-0.10 precisely because its gain is low - a
  fixed absolute floor sized for monitor-camera gains repeated the
  per-camera mistake the span exists to fix; lowered the same day. The
  instruction went through three wordings in a day: "the way you
  actually sit when tired - don't exaggerate" yielded a span of 0.041,
  so small the whole depth ladder fell inside measurement noise; "sink
  into your deepest slouch" was tried to anchor a larger span, then
  dropped because "deep" and "exaggerated" are subjective - people's
  imagined extremes vary far more than their habits. "The way you
  normally do" anchors to actual habit, the least ambiguous reference;
  the evaluation's absolute noise floor, not the instruction, is what
  defends against a small span now, at the recorded cost that on
  low-gain cameras the stricter ladder stops may flatten onto that
  floor.)
  Captured medians, the resulting span, and rejections are logged as
  tuning telemetry. A failed
  upright capture returns to positioning with an explanation; a failed
  slouch capture rests at slouchReady - instruction plus failure line,
  Begin re-arms it, deliberately not auto-retrying so an absent user
  never loops, and the good upright capture is never discarded. Closing
  mid-slouch keeps the single-point baseline (the pre-span behavior).
  The full result - upright ratio, slouched ratio when the pose ran, rho,
  the moment - is
  written into the PostureBaselines map under the active camera's
  AVCaptureDevice.uniqueID, leaving every other camera's entry untouched;
  the first-ever two-pose completion also writes the anchor (below),
  anchor before entry so observers of the map always see a current
  anchor. Nothing else is ever persisted - no frames, no files. The
  finished
  screen ("Calibration finished.") then offers Looks Good, which closes
  the window, and Try Again, which returns to positioning for another
  full pass whose result overwrites. Closing the window in the
  finished state is the same as Looks Good - the result is already saved.
- The anchor and the derived span (the hybrid, added 2026-08-03): the
  span - how far the ratio travels from upright to this user's own
  slouch - is measured by demonstration together with that capture's
  rho. The values persist as PostureAnchorSpan, PostureAnchorEarSpan
  (the same travel in ear units, added 2026-08-06), and
  PostureAnchorEyeShoulderRatio: a unit
  definition, deliberately not tied to a camera (it outlives the device
  it was measured on; an anchor measured on any camera works, which is
  what makes docked-first onboarding safe - the span self-normalizes, so
  the default strictness lands right whatever the first camera's angle).
  A calibration runs two-pose while either anchor unit is missing - once
  at the first-ever calibration, and once more by the first run after
  the ear metric landed, which refreshes the whole anchor (all three
  values from one capture) and is what migrates pre-ear installs. The
  ear unit is written only when the run measured a real positive ear
  span; a setup whose ears never measure keeps running two-pose, at the
  recorded cost of the extra pose for permanent-headphones users (the
  run is not wasted - each yields that camera a measured eye span).
  Every other entry's spans are derived from its own rho:
      span = anchor span x (rho / anchor rho) ^ exponent
  with one exponent per unit - eyes +1.9, ears -0.85 - and the scale
  clamped to 0.25...4, applied per unit from that unit's anchor span.
  The exponents were fitted 2026-08-06 from the first cross-camera
  measured pair (the same user's slouch demos on the laptop and monitor
  cameras; n=2, both values provisional, to be re-fit as calibration
  telemetry accumulates). Finding: the measured ear spans were nearly
  camera-independent (0.070 vs 0.059 across two very different camera
  angles) and tilt slightly opposite to rho - most of the old 2-3x
  cross-camera "gain" was head pitch, and it left with the eye metric.
  The eye-unit spans still track rho in the guessed direction, just far
  more gently (+1.9, not 6). Rationale for the mapping itself is
  unchanged: rho cancels the user's anatomy between cameras and encodes
  the camera's perspective geometry (not derivable exactly - height and
  distance are entangled in rho; the 27 percent rho swing observed on
  one camera between sitting distances is the caution). (History: a
  single shared exponent 6.0, the 2026-08-03 physics-informed guess
  bracketing 4.5-10; live use 2026-08-06 pinned a laptop's derived ear
  span on the lower clamp rail - maximum strictness via the noise
  floor - which prompted the fit.) The clamp bounds
  what a noisy rho can do, and the evaluation's absolute noise floor
  still backstops the strict end. Evaluation precedence per entry and
  per unit: measured span, else derived span, else the nominal fallback
  (SRSettings.postureEffectiveSlouchSpan and its ear counterpart
  postureEffectiveEarSlouchSpan are the one shared rule; the
  takeover gate, the nudge, and the Settings baseline label all treat
  "usable span" as measured-or-derived, judged on the eye unit - a
  camera is "calibrated" the same way it always was, ears or not). Migration: existing installs
  have no anchor, so the next calibration runs two-pose and becomes it;
  entries from before the probe (no rho) stay on the nominal fallback
  until recalibrated once. (History: the plan on 2026-08-02 was to
  instrument rho alongside two-pose everywhere and fit the exponent
  before switching; decided 2026-08-03 to ship the hybrid directly -
  per-camera slouch demonstrations cost the user too much and their
  performance varies between sessions - accepting a guessed exponent
  corrected from live logs instead.)
- Calibration cancel: closing the window while nothing is calibrated
  anywhere (empty baselines map) reverts Track Posture to off (no
  baseline, no tracking); with any baseline on file closing just closes
  and tracking continues on a calibrated camera - declining the
  new-camera nudge's calibration must not kill a working setup. The
  camera override, if any, is cleared before the check runs. Unchecking
  Track Posture while the window is open closes it.
- Per-camera baselines: the baseline is stored per camera because each
  camera's angle changes both what an upright posture measures (the
  offset) and how fast the ratio moves per unit of real slouch (the gain;
  see the slouch-depth rationale above). PostureBaselines keys
  PostureBaseline (upright ratio, optional slouched ratio, date) by the
  active AVCaptureDevice.uniqueID,
  which is stable enough for the built-in and a fixed display camera to be
  re-recognized across dock/undock. An install that predates this stored a
  single global baseline; it is migrated once, on the first launch after
  the update when a real device resolves, into the built-in camera's slot
  (where Automatic always measured it before), then the legacy keys are
  cleared. Migration targets the built-in specifically so a user docked at
  the moment of upgrade does not get the built-in's baseline stamped onto
  the monitor camera.
- Calibration gate (added 2026-08-01; tightened 2026-08-02; usable-span
  form since 2026-08-03): the external-camera takeover (Tools/spec.md)
  is gated on
  calibration. Automatic prefers an external camera only when the
  preference allows it AND (tracking is off OR that camera has a usable
  slouch span - measured, or derived from the anchor): tracking off is
  pure mirror use, nothing to break; tracking on must never auto-switch
  onto a camera that would go quiet (no baseline) or run knowingly
  miscalibrated (an entry with no span at all uses the nominal rule,
  which is
  fitted to laptop-height geometry and demonstrably too strict on exactly
  the elevated monitor cameras takeover is about - while the laptop
  itself stays trustworthy on it, because that is the tested
  status quo). In clamshell the built-in vanishes from discovery and the
  monitor is used regardless as the last resort: with a span-less
  baseline it tracks on the nominal-span rule (honest, degraded, and only
  when there is no alternative), with none it tracks quiet. The
  composition root pushes the rule's inputs into the camera
  service ahead of time - tracking on maps to the set of usable-span
  uniqueIDs, tracking off to no restriction - so a hot-plugged camera is
  judged against the already-current set with no race. An explicit user
  pick is never gated (intent wins; the escape hatch for whoever wants
  monitor tracking without recalibrating), and the snooze state
  deliberately does not lift the gate: snoozed tracking will resume, and
  it must resume on a calibrated camera. Under the hybrid, one
  single-pose recalibration (~20 s) is all a camera needs to clear the
  gate; the nudge explains it, and tracking meanwhile continues on a
  calibrated camera.
- New-camera nudge (SRPostureCalibrationNudgeController, added
  2026-08-01): when the gate blocks a takeover - an external camera is
  present, the takeover preference is on, tracking is on, and that camera
  lacks a usable span (no entry, or an entry with neither a measured nor
  a derivable span) -
  a system notification offers to calibrate it. The wording names what
  calibrating buys: "New camera detected ... to switch to it" when the
  camera is not active, "to resume tracking" when it is active without a
  baseline (the clamshell last resort), "to keep slouch detection
  accurate" when it is active on a single-point baseline. A real
  UNUserNotificationCenter notification, not the corner-note style, on
  purpose: the corner note is click-through by design and this nudge
  needs a button, and a rare, actionable, fine-to-wait-in-Notification-
  Center event is what the system primitive is for. Notification
  authorization is requested lazily, on the first nudge that needs it,
  never at launch; denial is logged, not silent. Clicking the
  notification or its Calibrate action clears any snooze (the same
  deliberate resume the menu's Calibrate item makes) and opens the shared
  calibration window targeted at the new camera via the temporary device
  override; a completed calibration stores the baseline, which reopens
  the gate and lets the takeover happen on its own. At most one nudge per
  camera per app session (a dismissed nudge must not return on every
  replug); a delivered nudge is withdrawn once its reason is gone
  (calibrated, unplugged, or tracking turned off). If the takeover
  preference is off there is no nudge: the user said no automatic
  switching, and a nudge to enable a switch they disabled would argue
  with them.
- Dots overlay: the service publishes each analyzed frame's readings
  (shoulder width fraction, slouch ratio, joints; adaptive pipeline
  preferred, padded as fallback, frame-normalized) on the main actor via
  onFrameSample. The calibration window drew the joints as dots over its
  preview (shoulders red, eyes yellow) until 2026-08-04, removed as
  visual noise: the guidance line already tells the user whether
  detection sees them. The floating panel's
  camera view is still temporarily SRPostureDebugCameraView (accuracy
  aid), drawing the same dots behind a dotsVisible master switch - true
  again as of 2026-07-30, turned back on for the tilted-screen detection
  question. 2026-08-06: ear dots (orange) joined the overlay; the test
  they enabled promoted the ears into the judged metric the same day
  (see the ear-anchored ratio bullet). A neck dot was tried and deleted
  within the day: Vision's neck joint is the shoulder midpoint, no
  independent signal. Delete that view and its panel
  hookup when the accuracy question is fully closed; onFrameSample
  itself is permanent.

## History recording (SRPostureHistoryService, added 2026-07-28)

- Alongside the debounced status, the service publishes one raw
  per-window sample (onWindowSample) while evaluation is live: visible or
  not, slouch measurable or not (whichever metric judged the window,
  ears preferred), and the un-debounced breach
  verdict per issue. Muted windows (no baseline, calibration window open)
  publish nothing, so posing during calibration is never recorded.
  The breach verdicts use the same strictness preferences as the nudges
  (a recorded decision, 2026-07-31: one notion of "bad posture" for both
  surfaces beats explaining two). History is recorded, never recomputed:
  changing strictness changes only future verdicts, and days tracked
  under a different strictness keep theirs - the same way a fitness
  tracker keeps old workouts when a goal changes.
- SRPostureHistoryService (a composition-root service, AppServices) folds
  those samples into per-day, per-hour buckets of five counters, all in
  seconds: measured, slouch-measurable, slouching, left shoulder high,
  right shoulder high. Counts are stored, never ratios: percentages are
  computed at display time as sum-of-numerators over sum-of-denominators,
  so a 30-minute session weighs exactly what it measured. One window
  counts as one second (windows are ~1 s).
- Sustained-run rule: an issue's seconds count only within runs that held
  at least qualifySeconds (10; lowered from 15 on 2026-07-30 so a
  slouch that held to the default nudge delay is also on the record);
  a qualifying run is credited from its
  first breaching second (retroactively, into the buckets those seconds
  fell in). Up to gapToleranceSeconds (2) of non-breaching windows are
  tolerated inside a run without being counted themselves; a longer gap
  ends the run, and a run that dies unqualified contributes nothing.
  Rationale: the harm in bad posture is holding it, not passing through
  it - reaching for a cup or stretching must not count, while those same
  seconds still count as measured (denominator) time, which is exactly
  how a user reads a coffee sip: fine.
- The qualify and gap constants are measurement constants, deliberately
  independent of the notification machinery (nudge delay, clear
  hysteresis): changing how nudges are delivered must never change what
  gets recorded. The breach thresholds are the exception by design -
  the shared strictness preferences above define what counts as an
  issue for both surfaces at once.
- A pause between samples longer than 5 s resets every run (probe
  stopped: toggle, snooze, sleep, camera loss); whatever follows is a
  fresh sitting.
- Persistence: JSON (PostureHistory.json) in the sandbox container's
  Application Support, written atomically off the main thread at most
  once a minute plus one synchronous write at app termination. Days
  older than 366 are pruned at load. Aggregates only - no frames,
  landmarks, or raw samples are ever persisted (the privacy stance in
  both VISION.md files). Untracked days and hours are simply absent from
  the file; the future charts render absence as no-data, never as zero.
- Load and save failures are logged (category PostureHistory), never
  silent; a corrupt file starts a fresh history and is overwritten at
  the next flush.
- The service publishes onChange (once per recorded sample, once when
  the loaded file merges in); consumers throttle to their own cadence.
  The Statistics window is the consumer (UI/Statistics/spec.md).

## Invariants

- No second AVCaptureSession; the probe consumes SRCameraService's
  attachOutput and the suspendOutput/resumeOutput pair.
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
- Ear-metric tuning (2026-08-06): the breach floor keeps the eye-tuned
  0.02 (the settling amplitude was observed in eye units), to be
  revisited from the "(ears)"-tagged telemetry once it accumulates.
  The gain exponents are now per-unit and fitted, but from a single
  cross-camera pair - more measured pairs would firm them up. Also
  open: whether Vision's ear point drifts along the pinna as the head
  pitches (initial live observation says it holds, even with hair in
  front).
- Baseline staleness: baselines are now per-camera (switching cameras
  looks up the right one instead of reusing a wrong one), but each is still
  per-placement - tilting the same laptop screen or moving to a different
  desk silently invalidates that camera's baseline. Recalibrating by hand
  is the only remedy today; the stored date is the hook for a future
  staleness heuristic (shoulder-width drift?).
- The new-camera nudge covers the gate-blocked external only. Two quiet
  states remain unnudged: an uncalibrated camera the user picked
  explicitly (tracking silently muted until they calibrate via the menu),
  and an undock falling back onto an uncalibrated built-in (possible when
  onboarding ran docked, so only the monitor got calibrated). Whether
  those deserve the same notification treatment is open.
- Small spans vs per-window noise: largely addressed in two steps. The
  noise floor exists (0.03 -> 0.025 -> 0.02 across 2026-08-02/03), and
  the rolling-median accusation removed frame jitter from the breach
  test, which is what let the floor reach the settling amplitude - on a
  0.047 span the slider now has distinct stops at 0.028/0.024/0.02
  instead of one. Still open: whether the floor can sit lower (the
  0.021 settling event bounds it - going under would flag genuinely
  good sitting), whether the median window (8) and its minimum (4) are
  right, and whether the still-floored strict stops deserve the
  floor-slope idea (the floor itself varying 0.03...0.02 across the
  slider, giving every stop a distinct meaning at the cost of the
  strictest flirting with settling) - decide from lived-with behavior.
- The shoulder tilt observation still runs on raw single-window values;
  the rolling-median accusation applies only to slouching. Some of the
  tilt's perceived over-strictness may be jitter accusing - the exact
  failure the median removed from the slouch axis. If the loosened
  12...4 ladder still nags, port the median (signed tilts, same
  slow-accuse/instant-forgive shape) before loosening further.
- The derived-span exponent (6.0) is unvalidated: it has never been
  checked against a real measured-span pair, because the hybrid shipped
  before any camera had both. First check: after the anchor calibration,
  single-pose a second camera and compare how alerts feel (and what
  derived span the calibration log prints) against expectation; the
  exponent and the 0.25...4 clamp are one-line tunings. A future
  recalibration of the anchor camera also yields a fresh
  (span, rho) pair to sanity-check the formula against.
- Face pitch as a staleness detector (idea recorded 2026-08-02, not
  built). The face detector already running for the adaptive canvas can
  report roll/yaw/pitch; pitch approximates the camera's elevation
  relative to the user's head. Too coarse and too confounded to correct
  the slouch gain analytically (the gain is cos(pitch) + k*sin(pitch)
  where k, the personal forward-lean-to-drop ratio, dominates and is
  unobservable - which is why the two-pose calibration measures the gain
  instead), but plenty accurate for change detection: record the smoothed
  face pitch at calibration time in the per-camera entry, and when the
  runtime pitch in good windows drifts far from it (screen re-tilted,
  monitor raised, chair changed), that camera's baseline is stale - the
  missing trigger for the staleness heuristic above. Secondary use:
  sanity-check the demonstrated slouch span during calibration (near-zero
  pitch with an enormous span smells like a hammed slouch). Cheap first
  step when picked up: store the calibration-time pitch from day one and
  tune the drift threshold on logged data.
