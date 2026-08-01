# Subsystem Spec: Welcome Window

## Metadata

- **Title**: The welcome window (first-run onboarding, five pages).
- **Surface**: a fixed-size titled window (title text hidden), shown by the composition root on first launch.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/UI/Settings/VISION.md` (the three-page onboarding plan this implements); `Narcissism/UI/Menu/spec.md` (owner); `Narcissism/UI/Status Item/spec.md` (the menu Locate Me opens); `Narcissism/Posture/spec.md` (the calibration content page three embeds).

## Summary

- **What this subsystem is**: the onboarding flow, five pages. About: the app icon, a "Welcome to Narcissism" title, the slogan, the app description, the privacy block. Tutorial: where the app lives (a Locate Me button that points at the status item) and three feature rows describing what it does. Get ready: the setup checklist (screen angle and framing, clothing, hair, lighting, clear camera) shown before the camera ever starts. Good posture: the sit-like-this tips (hips back, sit tall, shoulders level), where Ready lives; the list itself is `SRGoodPostureReminders` in Posture/, shared with the calibration window's first page, which is why its strings are namespaced `posture.good`. Posture preset: a header plus the embedded calibration content, ending in Looks Good (enables Track Posture and closes) or Not Now (closes with nothing changed). Its body names the camera: "The posture you hold becomes this camera's baseline" (2026-08-12, was "the baseline"). A baseline belongs to a camera, and this is the first calibration anyone ever does, so saying "the baseline" here taught the opposite - that calibration is a thing done once, for yourself - which is the misconception that makes the later new-camera nudge read as a nag (`Narcissism/Posture/spec.md`). It plants the idea rather than explaining it; the tutorial's calibration row states the rule outright (2026-08-13, see Tutorial page), and the concrete walkthrough still waits for the calibration window on a second camera. The title stays the bare instruction, "Hold your best posture": it used to trail off in "to calibrate" (calibrate what?), and naming the camera there fixed the dangle but ran the line to the window's full width at the flow's shared 20pt title size. Dropping the trailing clause fixes both without a page-specific type size.
- **One-sentence contract**: the flow's durable effects are the ones calibration itself produces (a saved baseline and, on success, Track Posture switching on) plus the first-run flag every close sets; every other preference is left untouched.

## Scope

- **In scope**: `SRWelcomeWindowController` (window + page swapping), `SRWelcomeViewController` (about), `SRWelcomeTutorialViewController` (tutorial), `SRWelcomeReadyViewController` (get ready), `SRWelcomeGoodPostureViewController` (good posture), `SRWelcomePostureViewController` (posture preset), `SRWelcomeRows` (the shared row style of the list pages).
- **Constraints / assumptions**:
  - Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy. At launch the policy is usually `.prohibited`, so without the regardless-ordering the window opens behind the active app.
  - The window floats while open (`level = .floating`, moves to the active Space on re-front) - the calibration-window precedent: onboarding is a short focused task, and without the level the system camera-permission alert drops the window behind other apps when dismissed.
  - Every fresh presentation centers on the interaction screen, the pointer's screen (the app-wide placement rule, see UI/Settings/spec.md): at first launch and on a menu re-show alike, the window appears where the user is, not on the primary display.
  - `SRMenuController` owns the single kept instance (the Settings precedent); the composition root presents it through `showWelcome()`.
  - Locate Me never touches the status item directly: the page calls the window's `onLocate`, the menu controller forwards to `onLocateStatusItem`, and the composition root wires that to `SRStatusItemController.locate()` (the same explicit cross-surface wiring the panel uses).

## Flow

- Pages are swapped as the window's content view controller. Every page lays out at one shared fixed size (`SRWelcomeWindowController.pageSize`, set by the tallest page), so the window never changes size mid-flow; the shorter pages center their content in the room above the button band.
- The button band is assistant style on every page: Back alone in the bottom-left corner (navigation), the page's decision in the bottom-right (about and tutorial: Continue; get ready: Continue with Not Now beside it; good posture: Ready with Not Now beside it; posture: Begin with Not Now beside it, or Looks Good with Try Again beside it). Navigation and decisions never share a group.
- The order is about -> tutorial -> get ready -> good posture -> posture preset; the posture page ends the flow (Looks Good or Not Now close the window), and Not Now on the get-ready and good-posture pages closes it the same way. Closing the window at any page is allowed; only the posture page's finished state has a side effect (below).
- Every page after the first has a Back button to the previous page. The posture page's Back and Not Now show only while positioning and before a capture completed; leaving that page via Back runs the same teardown as any other exit.
- The kept instance re-shows starting from the about page: a fresh presentation is always the whole flow.

## Posture page (recorded decisions)

- The calibration surface is `SRPostureCalibrationViewController` embedded as a child view controller - the same content the standalone window's capture page shows (mirrored preview, placeholder, guidance block, countdown, progress). The standalone window's reminders page is deliberately not embedded: this flow's own good-posture page already sits immediately before this one, so showing the list twice in a row would be the redundancy, not the reinforcement. The embed's inline action buttons are disabled (`showsActionButtons`); the page renders Begin, Not Now, Try Again, and Looks Good itself in the bottom band, driven by the session's public phase publisher (Begin enabled exactly on good framing while positioning, and ungated at lookAheadReady - the gate before the gaze probe, entered after the upright capture, where Begin arms the probe's countdown; the finished pair after the same progress-settle beat). The capture logic, gates, and baseline persistence are untouched (Posture/spec.md).
- The embed's height is `SRPostureCalibrationViewController.embeddedContentHeight`, not a local constant: with the inline buttons hidden the embed ends at the progress bar, and that position is set by the calibration layout. Nothing clips here (AppKit views do not clip subviews by default), so if the two drift apart the guidance draws over this page's button band rather than being cut off. Taking the number from the calibration side means a change there cannot silently break this page.
- The probe normally runs only while Track Posture is on, but this page needs frame samples before the user has opted in: on appear it starts `SRPostureAnalysisService` directly (and mutes evaluation via `setCalibrationWindowOpen`, like the standalone window); on disappear it stops the probe again unless tracking is on by then. Track Posture itself is not touched to get samples - setting it early would trigger the composition root's no-baseline auto-open over this page.
- Success enables coaching: the single teardown path runs on every way off the page (Looks Good, later, the window close button) and turns Track Posture on exactly when a baseline was captured (`completed`), mirroring the standalone window's "closing in the finished state is the same as Looks Good". The baseline is saved before tracking flips, so the composition root's replay never reopens calibration.
- Not Now (the deferral escape) is visible only while positioning and only before a baseline was captured; from the finished state the choices are Looks Good / Try Again. It closes the window with nothing changed - tracking stays off, and the existing menu flow (toggle on -> standalone calibration window) remains the later path.
- While this page is up it is the one calibration surface: `SRMenuController.showPostureCalibration` re-fronts the welcome window instead of opening the standalone window (the one-surface invariant, extended).

## Get-ready page (recorded decisions)

- The checklist exists because the baseline is setup-sensitive (Posture/spec.md records baseline staleness as per-camera-placement): screen angle changes the measured geometry, bulky clothing, hair over the eyes or shoulders, and poor or backlit lighting degrade the body-pose detection, and a covered camera defeats everything.
- The title is "Help the camera see you", not calibration prep (renamed 2026-08-04): the same conditions govern everyday tracking, so the page reads as general camera-visibility guidance. Its placement before calibration is unchanged - that is still the moment settling the setup matters most.
- The screen-angle row is titled by its checkable condition, "Head and shoulders in view" (renamed 2026-08-04 from "A comfortable angle", which read as comfort advice, not a check): detection needs the eyes and shoulders in frame, so the row asks for chest-up framing after the tilt is settled. Settling the setup before measuring improves the baseline.
- The camera permission prompt still lands at app launch on a fresh install, not on this flow's pages: the mirror surfaces (panel pinned, menu-bar camera) default on and attach the shared session immediately. That is accepted - the about page's privacy block is on screen at that moment, which is the priming. This page's deferral governs the posture probe only.
- The camera and probe are deliberately untouched until Ready: the checklist gets read without a live self-view competing for attention, the camera permission prompt lands right after the user read "nothing covering the camera", and a Not Now here never triggers the camera at all.
- The rows reuse the tutorial's row style (SRWelcomeRows).

## Good-posture page (recorded decisions)

- The baseline is whatever posture the user holds during the capture, which makes these tips the flow's most load-bearing advice; the page sits immediately before the camera page so they are fresh when Begin is pressed.
- Three tips only: hips back, sit tall, shoulders down and level (the latter two map onto the measured slouch ratio and shoulder tilt). A fourth screen-at-eye-level tip was considered and dropped (2026-07-27): it overlapped the checklist's screen-angle row.
- Ready lives here, not on the checklist, because this page immediately precedes the capture. It is deliberately not "Begin": Begin is the capture trigger on the next page, and one flow must not have two different Begins.

## Tutorial page (recorded decisions)

- Feature order is Camera, Posture, Calibration memory, Notifications (2026-08-13, calibration row added): camera first because it is what the app is (and explains the icon just located), posture as the hero second, calibration memory third because it extends the hero (what setup costs, and that it is kept), notifications last since they are how posture speaks.
- The calibration row ("One setup per camera" / laptop and monitor each keep their own, set up once and remembered) states the per-camera rule outright: baselines are stored per specific camera, and saying so up front is what keeps the later new-camera nudge from reading as a nag. Symbol `video.badge.checkmark` - a camera, vouched for.
- The rows use the What's New pattern: an accent-tinted SF Symbol column, a bold title, a secondary one-liner, left-aligned. `figure.stand` and `bell` deliberately match the Settings tab icons (`bell.badge` until 2026-08-13, retired together with the Settings tab's badge - a permanent badge reads as pending state).
- Row icons center on the title line, not the whole text block (2026-07-28): body length varies from one to three lines across rows, and block-centering dragged icons away from their headings by different amounts on the same page.
- Locate Me is a plain push button; Continue stays the page's single default (accent) button.
- Locate Me opens the status menu immediately (see the Status Item spec): macOS highlights a status item while its menu is open, and that highlight is the locator. A pre-open tint pulse was tried and dropped (2026-07-26) as pure delay. Deliberately no hidden-icon detection or fallback text either: the Status Item spec records that no reliable hidden signal exists, and the open menu is itself the locator of last resort.

## First-run gate (recorded 2026-07-28)

- The composition root shows the window at launch only while HasCompletedOnboarding (per VISION.md) is false. Any close sets it true - a page's Not Now, the posture page finishing, or the window's close button - because the spec treats closing at any page as a legitimate exit, and reopening a dismissed flow on every launch would punish that. The window controller reports the close through `onDidClose`; the menu controller (the owner) writes the preference. Closing lands nowhere (the home-window landing tried on 2026-07-28 was reversed with the home window itself the same day): the app returns to being a quiet menu-bar agent.
- Deliberately close-marked, not show-marked: quitting the app with the window still open (never dismissed) leaves the flag false, so the flow returns next launch.
- No re-run entry point exists yet (open question below); until one does, a rerun means resetting the preference (`defaults delete` the key).

## Copy decisions (recorded)

- The slogan ("Work without the expense of your spine" - tightened 2026-08-04 from "Work doesn't have to come at the expense of your spine") is bold at prose size (13), and carries no trailing period: emphasis by weight, subordination by size, so it cannot compete with the title (bold at 15 read as a second title; 15 regular read too quiet - settled 2026-08-04). It mirrors the privacy lead's bold-at-13, the page's one other emphasis.
- The description is a plain two-sentence description - what the app does for you, then how (camera, what it detects, that it tells you what to improve - matching the tutorial's "specific corrections" claim) - using "uneven shoulders", the term the rest of the app uses. The maker story that used to open it ("Made by someone who spent too many years hunched over a keyboard") was cut 2026-08-04: the page describes the app, it does not tell a story. Credits stay in the About window.
- The privacy block is its own paragraph, set apart with a lock symbol and a bold "Private by design." lead, so even a skimmer absorbs it before the camera permission prompt ever appears. The description mentions the camera on purpose: it primes that prompt.
- The description is secondary-label color; the slogan and the privacy block are label color. The visual hierarchy is slogan first, privacy second, prose third.

## Requirements

- **Native fidelity**: system title bar with hidden title, system fonts, SF Symbols, the default-button (Return) Continue; one fixed window size shared by all pages.
- **Concurrency**: main-actor throughout; no camera, no publishers.

## Open questions

- Where the re-run entry point lives (menu item vs About vs Settings); VISION.md wants the tutorial re-runnable.
- An Open at Login checkbox on the last page.
- Whether the page swap should animate (it is currently a cut).
