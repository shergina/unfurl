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
  The Settings window's Notifications page offers the same durations as
  a popup writing the same preference (see UI/Settings/spec.md), so the
  menu and the page always agree.
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
  slouch. This is the live metric the future baseline comparison will run
  on.
- Whenever the eye heights are available, the line also reports a rough
  estimate of the share of the frame height the person occupies: from the
  frame's bottom edge (the body runs off it) to an estimated head top,
  taken as half the eye-to-shoulder drop above the eyes. Added 2026-07-30
  to inform the zoom-out framing questions (how much of the frame the
  visible person actually fills); rough by design, not a posture metric.
- Slouch alert (experimental, log-only): each window's best available
  slouch ratio (adaptive pipeline preferred, padded as fallback) is compared
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
  or hysteresis on the log line: per-window feedback is what the
  experiment needs. The nudge debounce lives in the issue tracking
  below, not here.
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
  not snoozed) and no baseline is stored - covering the fresh toggle-on
  and the launch replay of an install that predates calibration - and on
  demand from the menu's "Calibrate Posture..." item (visible exactly
  when Snooze is; choosing it clears any snooze, a deliberate resume).
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
  rather than switching Spaces. Content: a live always-mirrored
  preview with the joint dots (the user positions themselves by seeing
  exactly what the tracker sees), the panel's placeholder behind it so
  camera failures and permission denials explain themselves in-window, a
  guidance line (can't see you / face the camera / move closer / sit up
  straight), and a Begin button enabled only while framing is good:
  confident shoulders, measurable eyes, shoulder width at least 0.15 of
  the frame width (below that reads as sitting too far away). While the
  window is open the per-window evaluation is muted exactly as when
  uncalibrated, so the corner note never nags mid-calibration; trackers
  restart clean after it closes.
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
  (shoulder width fraction, slouch ratio, joints; adaptive pipeline
  preferred, padded as fallback, frame-normalized) on the main actor via
  onFrameSample. The
  calibration window renders the joints permanently as dots over its
  preview (shoulders red, eyes yellow, hidden when detection drops),
  positioned via layerPointConverted so aspect-fill cropping and
  mirroring apply to them exactly as to the video. The floating panel's
  camera view is still temporarily SRPostureDebugCameraView (accuracy
  aid), drawing the same dots behind a dotsVisible master switch - true
  again as of 2026-07-30, turned back on for the tilted-screen detection
  question. Delete that view and its panel hookup when the accuracy
  question is fully closed; onFrameSample itself is permanent.

## History recording (SRPostureHistoryService, added 2026-07-28)

- Alongside the debounced status, the service publishes one raw
  per-window sample (onWindowSample) while evaluation is live: visible or
  not, slouch measurable or not (the eyes), and the un-debounced breach
  verdict per issue. Muted windows (no baseline, calibration window open)
  publish nothing, so posing during calibration is never recorded.
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
- The constants are measurement constants, deliberately independent of
  the notification machinery (nudge delay, clear hysteresis): changing
  notification preferences must never rewrite history. Nudges may fire
  at one threshold while statistics require another; different jobs.
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
