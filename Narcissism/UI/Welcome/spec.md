# Subsystem Spec: Welcome Window

## Metadata

- **Title**: The welcome window (first-run onboarding, pages one and two).
- **Surface**: a fixed-size titled window (title text hidden), shown by the composition root at launch.
- **Actor isolation**: main-actor.
- **Related code**: `Narcissism/UI/Settings/VISION.md` (the three-page onboarding plan this implements the first increments of); `Narcissism/UI/Menu/spec.md` (owner); `Narcissism/UI/Status Item/spec.md` (the locate pulse Locate Me triggers).

## Summary

- **What this subsystem is**: the onboarding flow. Page one (about): the app icon, a "Welcome to Narcissism" title, the slogan, the maker's description, the privacy block. Page two (tutorial): where the app lives (a Locate Me button that points at the status item) and three feature rows describing what it does.
- **One-sentence contract**: the window reads and writes no preferences; its only side effect is Locate Me, which is delegated out through a closure; Continue advances pages, and the last page's Continue closes the window.

## Scope

- **In scope**: `SRWelcomeWindowController` (window + page swapping), `SRWelcomeViewController` (page one), `SRWelcomeTutorialViewController` (page two).
- **Constraints / assumptions**:
  - Shown via the Settings-window recipe (`makeKeyAndOrderFront` plus `orderFrontRegardless` plus `NSApp.activate`), never by changing the activation policy. At launch the policy is usually `.prohibited`, so without the regardless-ordering the window opens behind the active app.
  - `SRMenuController` owns the single kept instance (the Settings precedent); the composition root presents it through `showWelcome()`.
  - Locate Me never touches the status item directly: the page calls the window's `onLocate`, the menu controller forwards to `onLocateStatusItem`, and the composition root wires that to `SRStatusItemController.locate()` (the same explicit cross-surface wiring the panel uses).

## Flow

- Pages are swapped as the window's content view controller; the window resizes to each page's Auto Layout size.
- Page one Continue advances to page two. Page two Continue closes the window (until page three exists). Closing the window at any page is allowed and has no side effects.
- The kept instance re-shows starting from page one: a fresh presentation is always the whole flow.

## Page two (recorded decisions)

- Feature order is Camera, Posture, Notifications: camera first because it is what the app is (and explains the icon just located), posture as the hero second, notifications third since they are how posture speaks. It also lands posture-adjacent content right before the future posture setup page.
- The rows use the What's New pattern: an accent-tinted SF Symbol column, a bold title, a secondary one-liner, left-aligned. `figure.stand` and `bell.badge` deliberately match the Settings tab icons.
- Locate Me is a plain push button; Continue stays the page's single default (accent) button.
- Locate Me opens the status menu immediately (see the Status Item spec): macOS highlights a status item while its menu is open, and that highlight is the locator. A pre-open tint pulse was tried and dropped (2026-07-26) as pure delay. Deliberately no hidden-icon detection or fallback text either: the Status Item spec records that no reliable hidden signal exists, and the open menu is itself the locator of last resort.

## Temporary behavior (recorded 2026-07-26)

- The window is shown on every launch while its content is iterated on. The first-run gate (a HasCompletedOnboarding preference per VISION.md), page three, and the re-run entry point are not built yet.

## Copy decisions (recorded)

- The slogan ("Work doesn't have to come at the expense of your spine") is bold and carries no trailing period: it is set as a display headline, not prose.
- The maker stays unnamed ("Made by someone who spent too many years hunched over a keyboard"); the name lives in the About window, where credits belong.
- The privacy block is its own paragraph, set apart with a lock symbol and a bold "Private by design." lead, so even a skimmer absorbs it before the camera permission prompt ever appears. The description mentions the camera on purpose: it primes that prompt.
- The description is secondary-label color; the slogan and the privacy block are label color. The visual hierarchy is slogan first, privacy second, prose third.

## Requirements

- **Native fidelity**: system title bar with hidden title, system fonts, SF Symbols, the default-button (Return) Continue; the window is sized by Auto Layout from its content.
- **Concurrency**: main-actor throughout; no camera, no publishers.

## Open questions

- Page three (posture setup with a "later" escape) per VISION.md, and whether finishing lands on the Settings window.
- Where the re-run entry point lives once the first-run gate exists (menu item vs About vs Settings).
- An Open at Login checkbox on the last page.
- Whether the page swap should animate (it is currently a cut).
