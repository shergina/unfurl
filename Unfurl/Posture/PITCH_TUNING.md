# Pitch-based strictness tuning data

Working data for fitting the strictness multiplier m(theta). Not a spec:
this is a lab notebook, delete when the fit ships.

**What we're fitting:** for each camera angle, theta is the measured pitch
delta between "looking at yourself on the camera's screen" and "looking
directly ahead" (negative = screen centre sits below your level gaze; the
original "positive = camera sits above your gaze line" here was a mislabel -
the camera cancels out of the delta entirely, see the 2026-08-10 regime
note). For each
theta, sit naturally for a while, then deliberately slouch, read both
bands from the telemetry, and decide what medium strictness (percent
below baseline) separates them cleanly. The decided percents against
theta are the points the line/curve gets fitted to.

**Per-session procedure:**

1. Set up the camera angle. Describe it in Setup so it's reproducible.
2. Calibrate on that camera (baseline gets captured; theta gets measured
   once the two-gaze capture is built - until then estimate it or leave TBD).
3. Sit naturally and work for 5-10 minutes. Read your natural ear-ratio
   band from the `Shoulder distance` / `Slouching (ears)` telemetry lines.
4. Slouch the way you actually do for a minute. Read that band too.
5. Decide the medium strictness percent: a drop below baseline that your
   natural band never crosses but your slouch band clearly does.

## Data

One theta per row (it's a property of the camera setup); two decided
strictnesses per row, one per metric - the fit produces two curves,
m_ear(theta) and m_eye(theta), over the same theta axis. Cells with two
values are ear / eye.

| # | Date | Camera | Setup (angle, distance, tilt) | theta (deg) | Baseline (ear / eye) | Natural band (ear / eye) | Slouch band (ear / eye) | Decided medium % at screen (ear / eye) | Decided medium % looking down (ear / eye) | Notes |
|---|------|--------|-------------------------------|-------------|----------------------|--------------------------|-------------------------|----------------------------------------|-------------------------------------------|-------|
| 1 | 2026-08-07 | LG UltraFine (monitor) | (describe: desk position at 13:01) | -3.7 | 0.574 / 0.601 | | | 9 / 18 | 20 / TBD | Calibrated 13:01, rho 0.2553. Ear at-screen revised 8 -> 9 on 2026-08-07. Bottom-gaze: ear -0.044, eye -0.088, pitch +7.6. Caveat: the ahead-probe barely moved - gaze deltas ear +0.005, eye +0.009, an order of magnitude under the other rows' - so theta here rests on the face-pitch reading alone and the probe corroborates nothing. Bands again unsegmented: the whole session sat at +8 to +10 ears / +13 to +17 eyes with no natural-vs-slouch split, i.e. never near baseline |
| 2 | 2026-08-07 | LG UltraFine (monitor) | (describe: desk position at 15:55) | -8.1 | 0.504 / 0.507 | | | 6 / TBD | 10 / TBD | Calibrated 15:55, rho 0.2589. First entry carrying uprightFacePitch (19.1 deg), so the pitch trigger is live: looking-down past 31.0 deg. Gaze deltas: ear +0.039, eye +0.076. Bottom-gaze: ear -0.010, eye -0.048, pitch +8.9. Eye percents deliberately not decided yet. Near-replicate of the row deleted as an outlier (theta -8.9, decided 7 / 15, 0.8 deg away); that disagreement against this row's 6 / 10 is what first flagged it |
| 3 | 2026-08-07 | LG UltraFine (monitor) | (describe: desk position at 16:19) | -9.9 | 0.532 / 0.551 | | | 3 / TBD | 5.5 / TBD | Calibrated 16:19, rho 0.2482, uprightFacePitch 16.6 (trigger 26.7 deg). Gaze deltas: ear +0.045, eye +0.073. Bottom-gaze: ear -0.009, eye -0.064, pitch +10.1. Theta 0.11 deg off the -10 boundary. The decided 3.0 lands almost on the low-camera table's 2.5, which is evidence the regimes are continuous and there is no real cliff - and it was 4 points under the deleted outlier's 7 at a theta 1 deg away |
| 4 | 2026-08-07 | LG UltraFine (monitor) | (describe: desk position at 16:32) | -0.6 | 0.551 / 0.555 | | | 9.5 / TBD | 25 / TBD | Calibrated 16:32, rho 0.2520, uprightFacePitch 19.7 (trigger 39.1 deg). Gaze deltas: ear +0.018, eye +0.054. Bottom-gaze: ear -0.030, eye -0.073, pitch +2.5. Shallowest theta collected, 3 deg past row 1 and 7.5 from the -8 cluster, so it is the first point with real leverage on the slope. Theta sits above the fit clamp, so the live stops were the clamped -3.7 endpoints (9.0 / 20.0) rather than a fitted value |

## The -10 boundary (evidence as of 2026-08-07)

Row 3 decided 3.0% ears at theta -9.888, one tenth of a degree above the
boundary. The low-camera table just below it is 2.5%. Those agree, and
the shipped four-point line now reaches 3.89% at -10, which agrees too.
That is three independent routes to roughly the same number at the
boundary, so the regimes look continuous and the feared cliff was an
artefact of the old high-camera guess (7.0%) rather than a property of
the angle.

The looking-down line reaches 5.77% at -10, and there is no low-camera
counterpart to compare it against - the down-gaze correction does not
exist below the boundary at all. That is the remaining discontinuity: a
camera drifting across -10 keeps roughly its at-screen strictness but
loses the down-gaze allowance entirely.

Ten thetas measured on this one monitor in an afternoon: -9.9, -9.7,
-9.4, -8.9, -8.1, -7.4, -6.4, -5.4, -3.7, -1.3, -0.6, -0.4, -0.1, and
one at +3.6. The spread means regime assignment is not stable for this
setup, so any discontinuity at the boundary shows up as strictness
changing at random between calibrations. Continuity is not a nicety
here.

## Piecewise strictness (implemented 2026-08-06)

The working policy shipped from this data: theta at or below -10 deg
uses percents around 3 ears / 5 eyes (the measured flat region); above
-10 deg uses percents around 7 / 8 (working guess). Tables and the
boundary live in SRSettings (lowCamera*/highCamera*Percents,
lowCameraThetaBoundary, and the ladders the slider indexes). Calibration now runs
three gazes (middle = baseline, bottom of screen = envelope, ahead =
theta). Further rows refine the high-camera side and the boundary.

## Shipped fit (4 points, 2026-08-07)

High-camera regime only (theta above -10), ears only. Least squares over
rows 1-4 after the theta -8.9 outlier was deleted:

    ear      = 0.675055 * theta + 10.6384   R2 0.894, max residual 0.96
    ear_down = 2.115141 * theta + 26.9169   R2 0.994, max residual 0.91

    theta -9.9   decided  3.0 / 5.5    fit  3.96 / 5.98
    theta -8.1   decided  6.0 / 10.0   fit  5.17 / 9.78
    theta -3.7   decided  9.0 / 20.0   fit  8.14 / 19.09
    theta -0.6   decided  9.5 / 25.0   fit 10.23 / 25.65

Every residual is under 1 point, which is the decide-by-feel noise floor
measured on the deleted rows - so the fit is as good as the inputs
allow, and tightening it further would mean improving the decisions, not
the model.

Live in SRSettings as highCameraEarAtScreen only - ear_down was replaced
by a hand-set line on 2026-08-10, see below. Both are clamped to
highCameraFitThetaRange, now -9.9...-0.6 (was -8.9...-3.7).
That span covers nearly the whole high-camera regime, so clamping is
rare in practice - except above -0.6, where nothing has been measured
and the clamp is the only thing preventing extrapolation past the gaze
line.

Eyes were deliberately not refitted: highCameraEyeAtScreen still rests
on two points, one of them the deleted row, making it the weakest of the
three. It only judges when the ears are unavailable, and it is due a
collection pass of its own.

### Why the outlier went

The deleted row: theta -8.9, decided 7 at screen and 15 looking down,
the first decision made under the new flow. Leave-one-out on the five
points flagged it on both metrics - dropping it took the down line's R2
from 0.86 to 0.994 and the at-screen from 0.75 to 0.89, both by a wide
margin over any other row. Its own notes corroborated: the session's
telemetry oscillated instead of holding a natural block, and its bands
were never segmented.

Recorded so it is not silently lost. Its eye values (15 at screen, 18
was row 1's neighbour) are what the shipped eye line still rests on.
With four points remaining, a second deletion would leave three and
prove nothing; the way to test any other row is a repeat decision at its
setup, not another cut.

### If the boundary needs moving

The rows 2/3/4 lines extrapolate to the -10 boundary at 3.47% at screen
and 5.40% looking down. The low-camera table currently applies 2.5%.
Row 4's decided 3.0% at theta -9.888 sits between the two. Raising the
low-camera ear medium from 2.5 to somewhere near 3.5 would make the
regimes join up; that number has the advantage of being consistent with
both row 4 and the extrapolation, and the disadvantage of resting on
data from one monitor with no low-camera point collected under the
current flow at all.

What would actually help, in order: repeat decisions at one fixed setup
on different days, to size the decide-by-feel noise floor directly (the
deleted rows put it near 1 point; these say 4 or more for down-gaze);
segmented natural-vs-slouch sessions so the percents come from measured
band separation instead of feel; and only then points at thetas far from
-8, where a real slope could actually show above the noise.

### Shipped 2-point lines

Looking at the screen, from the decided percents (ear 7 at -8.9, 9 at
-3.7; eye 15 and 18):

    ear = 0.384615 * theta + 10.4231
    eye = 0.576923 * theta + 20.1346

Looking down, from the decided ear percents (15 at -8.9, 20 at -3.7).
No eye values decided yet:

    ear_down = 0.961538 * theta + 23.5577

Three things this pair of revisions exposed.

The ear at-screen slope doubled - 0.192308 to 0.384615 - on a single
one-point revision (row 2's 8 to 9). Two points determine a line
exactly, so every decided value moves the slope by its full share and
nothing averages out. The decide-by-feel noise floor was measured at
about 1 point in the deleted rows, which is the same size as the
revision that doubled the slope. No fitted number here is meaningful
until there are 4+ points.

The decided down-gaze values run consistently above what the bottom-gaze
probe predicts, by almost exactly the same amount at both setups:

    row 1: screen 7 + measured offset 4.6 = 11.6 predicted, 15 decided (+3.4)
    row 2: screen 9 + measured offset 7.7 = 16.7 predicted, 20 decided (+3.3)

If that ~3.4 constant holds at a third point it is a real finding: the
down-gaze worth tolerating is a fixed excursion past the bottom of the
screen (a keyboard or phone glance is the same physical movement
whatever the camera angle), not the screen-bottom gaze the probe
measures. That would mean the blend's far endpoint should be the probe
value plus a constant, not the probe value.

The decided multiplier is now nearly flat - 15/7 = 2.14 and 20/9 = 2.22 -
where the probe-derived one grew (1.66 to 1.96). So on the decided
numbers a constant ~2.2x reproduces both rows about as well as the
second line does, which weakens the earlier argument for two curves.
Two points cannot separate a flat multiplier from a growing one; a
third, further from these two, can.

Shipped 2026-08-07 (SRSettings.highCameraEarAtScreen /
highCameraEarLookingDown / highCameraEyeAtScreen, clamped to
highCameraFitThetaRange). All three reproduce their decided values
exactly. Low camera and any entry without a measured theta keep the
tables untouched. Gaze is decided per window by eye-minus-ear divergence
off the rolling medians, trigger at plain zero, no deadband yet.

Measured against the 13:02-13:06 session (theta -3.7, so 9% at screen /
20% looking down), replaying its telemetry through the shipped logic:

- 88% of windows judged looking-down, so the loose stop is the common
  case, not the exception.
- Ear drop median +10.0%, which lands between the two stops, so the gaze
  test - not the posture - decides the verdict in 53% of windows.
- 10 verdict flips in ~4 minutes, roughly one every 25 s. That is the
  zero-threshold flicker predicted when this was designed, now measured.
  13% of windows sit within 1 point of the threshold.
- Net effect on that session: the old flat 7% breached 205/251 windows;
  the new pair breaches 14/251.

Superseded 2026-08-07: the divergence test was replaced by head pitch
from the face detector, compared against the calibrated pitch of the
screen's bottom edge (uprightFacePitch + bottomPitchDelta + margin,
margin 0). Reported symptom was that real down-gazes did not register -
consistent with the signal being small: a full screen-bottom gaze only
moved divergence 2.3 to 6.9 points, against noise that put 13% of
windows within 1 point of the trigger. Pitch also keeps working when the
ears are lost, which the divergence test could not - it needed both
metrics, so it went blind in exactly the eye-fallback case that needs
the correction most.

Trigger shipped as 14 degrees below the calibrated middle-of-screen
pose (uprightFacePitch + 14) since 2026-08-07. It was previously
anchored to straight-ahead (uprightFacePitch + gazePitchDelta + drop) at
30, then 15, then 20; a probe-derived form (uprightFacePitch +
bottomPitchDelta, the screen's bottom edge) was built before any of
those.

Lowered to 8 on 2026-08-09: 14 never fired in real use. The 2026-08-09
monitor calibration carried uprightPitch 22.5 (the highest recorded,
rows above sat 16.6-19.7), putting the trigger at 36.5 absolute -
deeper than every measured bottom-gaze excursion (+2.5..+10.1 past
centre) and past the replay's 0%-at-41 / 23%-at-31 tail. A real glance
also drops the eyes more than the head, so live pitch under-reads the
gaze. 8 trades that for engaging while the gaze is still on the
screen's bottom edge on the deeper setups (rows 2 and 3, bottoms at
+8.9 and +10.1).

Why the anchor moved to screen centre. Derived from the logged triggers
across a day of calibrations, the straight-ahead pose ranged 6.7 to 21.3
deg absolute (spread 14.6) while the middle-of-screen pose ranged 15.6
to 22.1 (spread 6.5) - 2.2x more repeatable, which makes sense since
screen centre is a target the user can aim at and "straight ahead" is
interpreted afresh each time. Worse, anchoring to ahead dragged the
trigger with theta while the screen stayed put:

    theta -9.9  trigger 10.1 below centre, screen bottom 10.06  ->  0.05 deg past the bottom edge
    theta -8.1  trigger 11.9 below centre, screen bottom  8.92  ->  2.99
    theta -3.7  trigger 16.3 below centre, screen bottom  7.56  ->  8.75
    theta -0.6  trigger 19.4 below centre, screen bottom  2.50  -> 16.92

So "looking down" meant glancing at the bottom of the screen on one
setup and looking 17 deg below the screen on another. Off screen centre
the depth is fixed; the remaining 7.6 deg of variation past the bottom
edge is real screen height, not measurement drift.

14 was chosen to preserve the mean depth the ahead-anchored version had
(14.4 below centre), so this is a change of anchor, not of strictness.

Note the baseline was already the middle-of-screen gaze and has been
since the 2026-08-06 revision.

The bottom-of-screen leg was deleted 2026-08-07, right after this. It
had fed the probe-derived trigger for about an hour; once the anchor
moved to a fixed drop below screen centre, nothing read
eyeBottom/earBottom/bottomPitch at all, and the leg was costing a gate,
a Begin press and a 5 s capture on every high-camera calibration to
write three fields no one opened. Its PostureBaseline fields went with
it, so values already on disk are dropped on the next write. If the eye
tuning turns out to want a measured gaze envelope, the leg has to come
back and every camera needs recalibrating - that was the risk taken.

Hysteresis is 3 degrees, sized from the flicker measured above.

Live since the 15:55 calibration (row 3), the first entry to carry
uprightFacePitch: 19.1 deg, theta -8.086, so the trigger sits at 31.0
deg absolute. Replaying the 103 earlier pitch windows against it puts
23% of them on the down side (42% at a 15 drop, 0% at 30) - but those
windows predate the trigger, so this is still a replay, not a
measurement of the thing in use. What is missing is a session where the
crossings can be checked against what the gaze was actually doing.

Cautions before any of this ships:
- Both rows are the same monitor, 5.2 deg apart, and neither had a
  segmented natural-vs-slouch band, so every percent here is
  decide-by-feel.
- No eye down-gaze values decided. The probe-derived estimate reached
  ~33% at -3.7; a metric that tolerates a third of its baseline is not
  measuring anything, which is the case for ear-preferred judging
  rather than for an eye correction.
- The bottom probe does not run below -10, so low cameras have no
  measured far endpoint at all.

## Regime discriminator moved off theta (2026-08-10)

Theta never measured the camera. Both probe legs read face pitch
relative to the same camera, so with the camera C degrees above the
level gaze and the screen centre S degrees below it: at-screen pitch is
C + S, ahead pitch is C, and theta = ahead - at-screen = -S. C cancels;
theta is the screen centre's depth below level, nothing more. The
header's old "positive = camera sits above your gaze line" was wrong
from day one. Theta worked as a camera-height proxy only because screen
depth correlates with camera height (laptops deep, monitors shallow).

The break: the 2026-08-09 19:29 monitor calibration, with the ahead
probe aimed honestly level for the first time, measured theta -14.46 -
below the -10 boundary, so a camera sitting above the head classified
as a low camera and lost the down-gaze allowance. Geometry agrees the
measurement was honest: a 27 inch panel with its top edge at eye level
at ~65 cm puts the centre ~14.5 deg below level. The earlier shallow
thetas on the same desk (-0.6 to -9.9, one +3.6) were the aim wobble,
not this row.

The switch: the regime selector is now the ahead pitch itself,
uprightFacePitch + pitchDelta = C, positive = camera above the level
gaze, boundary 0 (SRSettings.lowCameraAheadPitchBoundary). On record
for this monitor: +11.0, +6.7, +19.1, +16.0, +9.8 - always positive,
never within 6 deg of the boundary, while theta on the same desk
straddled -10. Entries predating uprightFacePitch fall back to the old
theta rule at -10, which keeps the laptop entry (theta -17.0, no
uprightPitch) correctly low without recalibrating. The "Strictness:"
line names the rule that classified (ahead x.x deg / legacy theta / no
theta).

Caveats: C rides the ahead leg, so it inherits the aim wobble (~12 deg
spread on record) - tolerable while every real setup sits well clear of
0, unmeasured for near-level cameras. The fitted lines still take theta
as their x, and rows 1-4's thetas were collected under the old wobbly
aiming, so the x-axis is shakier than the R2 suggests; an honest-aim
recollection would re-found them. Nothing is measured near the 0
boundary.

## Down line hand-set (2026-08-10)

ear_down is now y = 0.8 * theta + 27, hand-set, replacing the fitted
2.115141 * theta + 26.9169. Rationale: the rows' thetas were measured
under the wobbly forward aim (see the regime note above), so the
deep-theta points plotted too shallow, and the two gaze poses differ
person to person - a 4-point fit's slope was carrying more precision
than its inputs had. The replacement is close to flat, so it loosens
the deep end hard and the shallow end a little:

    theta -9.9   decided  5.5   fitted  5.98   hand 19.08
    theta -8.1   decided 10.0   fitted  9.78   hand 20.52
    theta -3.7   decided 20.0   fitted 19.09   hand 24.04
    theta -0.6   decided 25.0   fitted 25.65   hand 26.52

No row reproduces now, the errors running +1.5 to +13.6 points. Across
the whole clamp the line moves 7.4 points where the fit moved 19.7, so
the down allowance has stopped tracking theta in any real sense: treat
it as a tolerance setting rather than a fit. If the down correction
should follow the camera angle again, this is the line to refit once
honest-aim thetas exist. The at-screen line and the clamp range are
untouched; at the deep clamp the down stop moves 5.98 -> 19.08.

## Fit (fill once there are 4+ points)

- Candidate shapes, all fitted to the same points: line `a + b*theta`,
  cosine `a*(cos theta + k*sin theta)`, quadratic. Pick by eye; clamp
  outside the sampled theta range.
- Other strictness stops derive from the fitted medium curve
  (proportional steps preferred over +/- constant points, so the ladder
  compresses gracefully at low-gain angles - decide after seeing data).

## Open notes

- Head-pose instrumentation (2026-08-07, telemetry only - nothing reads
  it): a per-window "Head pose:" log line carries face-detector pitch and
  yaw in degrees plus the eye/ear width ratio (eye separation over the
  eye-to-ear distance on the same side, longer side wins). For the
  planned "loosen the strictness when the head is turned away"
  correction: sit and turn/tilt the head through the range, then read the
  real distribution off the log and pick the trigger and its threshold
  from that. Open questions to settle from the data: which of the three
  signals actually separates turned-away from normal working movement;
  whether the trigger fires at all before Vision drops an eye and the
  existing faceNotVisible path takes over; whether the response should
  be a looser threshold or no verdict at all; and what release threshold
  keeps a hard trigger from flickering at the boundary. Whatever ships
  must name itself in the "Strictness:" line, or it will contaminate the
  theta rows being collected now.

- The calibration reminders page shipped 2026-08-07 and is designed to
  make people hold a better baseline. If it works, baselines move, so
  rows collected from that date forward are not comparable with rows 1-5
  (which are already flagged below for re-collection under a different
  gaze wording). Mark new rows accordingly; the high-camera side is
  starting from zero usable points, not one.

- Provenance of the deleted 2026-08-06 rows (removed 2026-08-07 as
  non-comparable): the at-screen gaze target moved twice during that
  collection - "look at yourself" (the calibration window, upper third)
  -> "middle of your screen" -> "bottom of your screen" - so their
  baselines and thetas were referenced to different gaze targets and
  could not be fitted together. Kept here because the shipped
  low-camera table still rests on them: three laptop sessions at theta
  -19.0, -18.9 and -9.6 decided 3/5, 4/5 and 3/5 (ear/eye), which is
  where "around 3 ears / 5 eyes below -10" came from, and the one
  monitor session at theta -4.0 decided 12/20. That monitor point is
  the only prior high-camera evidence and it disagrees sharply with the
  shipped 7/8 guess. Re-measure rather than trusting any of it.

- Theta instrumentation is built (2026-08-06): calibration now runs a
  gaze probe after the upright capture (look at yourself -> look
  directly ahead). Theta comes from the "Calibration gaze captured" log
  line and persists per camera entry (eyeGaze, earGaze, pitchDelta in
  PostureBaselines). Both metrics' deltas are captured so the eye
  fallback can get its own fitted correction.
- Sign convention, read off the first capture (laptop, 2026-08-06):
  theta = ahead minus at-screen; NEGATIVE means the screen sits below
  the gaze horizon (laptop measured -19.0 deg). Expect the monitor to
  read small and near zero-to-positive. Confirm with its capture.
- The decided percents implicitly absorb the best-posture settle, since
  they're chosen against baselines captured with the current wording. If
  the calibration instruction ever changes, the fit needs re-collecting.
