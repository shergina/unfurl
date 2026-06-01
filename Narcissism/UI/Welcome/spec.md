# Subsystem Spec: Welcome Window

## Metadata

- **Title**: The welcome window (first-run onboarding, page one).
- **Surface**: a fixed-size titled window (title text hidden), shown by the composition root at launch.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/UI/Settings/VISION.md` (the three-page onboarding plan this implements the first increment of); `Narcissism/UI/Menu/spec.md` (owner).

## Summary

- **What this subsystem is**: page one of the planned onboarding flow: the app icon, a "Welcome to Narcissism" title, the slogan, the maker's description, the privacy block, and a Continue button.
- **One-sentence contract**: static content only; the window reads and writes no preferences and has no side effects; Continue closes the window (it will advance to page two once that exists).

## Scope

- **In scope**: `SRWelcomeWindowController`, `SRWelcomeViewController`.
- **Constraints / assumptions**:
  - Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy. At launch the policy is usually `.prohibited`, so without the regardless-ordering the window opens behind the active app.
  - `SRMenuController` owns the single kept instance (the Settings precedent); the composition root presents it through `showWelcome()`.

## Temporary behavior (recorded 2026-07-26)

- The window is shown on every launch while its content is iterated on. The first-run gate (a HasCompletedOnboarding preference per VISION.md), pages two and three, and the re-run entry point are not built yet.

## Copy decisions (recorded)

- The slogan ("Work doesn't have to come at the expense of your spine") is bold and carries no trailing period: it is set as a display headline, not prose.
- The maker stays unnamed ("Made by someone who spent too many years hunched over a keyboard"); the name lives in the About window, where credits belong.
- The privacy block is its own paragraph, set apart with a lock symbol and a bold "Private by design." lead, so even a skimmer absorbs it before the camera permission prompt ever appears. The description mentions the camera on purpose: it primes that prompt.
- The description is secondary-label color; the slogan and the privacy block are label color. The visual hierarchy is slogan first, privacy second, prose third.

## Requirements

- **Native fidelity**: system title bar with hidden title, system fonts, an SF Symbol lock, the default-button (Return) Continue; the window is sized by Auto Layout from its content.
- **Concurrency**: main-actor throughout; no camera, no publishers.

## Open questions

- Pages two (find the icon, feature tour) and three (posture setup with "later" escape) per VISION.md, and whether finishing lands on the Settings window.
- Where the re-run entry point lives once the first-run gate exists (menu item vs About vs Settings).
- An Open at Login checkbox on the last page.
