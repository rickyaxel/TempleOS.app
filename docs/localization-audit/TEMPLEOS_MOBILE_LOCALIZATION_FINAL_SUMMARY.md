# Mobile localization pass: summary (2026-11-08)

## Problems found

Application-owned English in non-English sessions of both apps (the Swift and Kotlin shells are
ports of each other, so every defect existed on both):

1. Game controls: the touch-mode toggle (`L-CLICK` / `R-CLICK` / `MOVE`) and the wheel buttons
   (`WHL+` / `WHL-`) were literals. The toggle's spoken text was chosen by comparing the visible
   English label, so the label could not be translated without breaking VoiceOver and TalkBack.
2. End line after **Stop program**: the overlay quoted the engine's reaction to the app's own command
   (`Ended: Break`, `Ended: Stopped.`); after a host failure, `Ended: internal error`.
3. About this program: `Author: TempleOS.app contributors` for the project's own examples.
4. Save as after a document program ends: `Invalid path` and `Path is too long` (errors without a
   catalog key).
5. Terminal banner: the word `Terminal` written beside the translated banner text.

Root causes: literals in a component added after the catalog conventions (game controls), presentation
coupled to identifiers (spoken text keyed on the English label), engine text reused as UI text, data
fields shown raw, and an audit script that only matched single-line calls from a fixed list.

## Changes

- Both shells: translated control labels with the spoken text attached to each button; a translated
  label wider than its grid cell takes the cells it needs (English layouts unchanged), with the labels and
  their widths resolved when the language changes, not on every frame; the app's own
  end line after Stop and after a host failure, with the engine's message preserved; localized author;
  keyed export errors; translated Terminal banner word.
- Catalogs: 7 new keys in English and all 72 translations (machine-written, flagged in `$review`).
- Tests: five new unit tests per platform (input parity of the game controls in all 89 locales, labels
  resolved once per language, the end line after Stop, authors, the banner) and an iOS UI test across
  14 locales.
- Tools: `hardcoded_audit.py` now catches these classes of leak (14 findings on the original code,
  0 now).
- Docs: this folder, a pointer from [localization.md](../localization.md), the regenerated
  [localization-coverage.md](../localization-coverage.md).

No original TempleOS file, HolyC source, program manifest, generated translation (PureSwift,
purekotlin), compiler or kernel behavior changed. Key codes, wheel deltas, typematic repeat, touch
modes, exit categories and `Kernel.exitMessage` are unchanged.

## Results

- Static: catalogs complete (386 keys × 73 catalogs, 0 errors), audit 0 findings, census strict
  pass, both release-configured packages carry byte-identical catalogs and the 89 locale
  declarations (`gen_platform.py --check` fails on the committed `Info.plist` for a reason that
  predates this work; see the verification results).
- Unit: targeted classes Kotlin 76/76 and Swift 82/82; full Kotlin suite 413 tests with one failure
  and full Swift suite with four failures, all explained in the verification results (one is caused
  by the in-progress `regional-policy.json`, the others are wall-clock tests that failed while the
  machine was oversubscribed and pass when run alone); the committed tree passes the localization,
  controls, brand, moderation and behavior classes on both platforms.
- Runtime: Android emulator 15/15 locales and iOS simulator 14/14 locales for the controls, toggle,
  landscape and end-line journey, with screenshots reviewed.
- Scope review: control labels resolved once per language (a new test fails on the first version on
  both platforms); layout, spoken names and toggle states identical to the first version in 5,340
  configurations per platform; targeted classes Kotlin 37/37 and Swift 38/38. The runtime runs were not
  repeated after this change.
- Not done: native-speaker review, tablets, screen readers running, the 320-px manual display scale.

Details: [TEMPLEOS_LOCALIZATION_VERIFICATION_RESULTS.md](TEMPLEOS_LOCALIZATION_VERIFICATION_RESULTS.md).

## Remaining items

See "Open items" in [TEMPLEOS_MOBILE_LOCALIZATION_AUDIT.md](TEMPLEOS_MOBILE_LOCALIZATION_AUDIT.md):
the product-required English brand intro, the unspoken iOS container label, the documented English
console fallback for non-CP437 languages, and long program-menu labels cut in one grid cell.

## Commits

On branch `main`, local only:

- `289dfc8` Translate the game controls, the end line and the remaining app messages (Swift and
  Kotlin shells, 73 catalogs, coverage table, unit tests)
- `7267968` Catch untranslated controls and keyless errors in the localization audit
  (`hardcoded_audit.py`, `census.py`, iOS UI test)
- `70ef420` Document the 2026-11-08 mobile localization audit (this folder, the pointer in `localization.md`)
- a scope-review commit: the control labels and their widths are resolved once per language instead of
  on every frame, and two fixes outside the translation work were backed out (an Android fallback for a
  message-less export error, a new `census.py` default); see "Scope review" in the audit

The uncommitted work on hierarchical language resolution that was in the working tree before this
pass was left as it was and is not in these commits.

Nothing was pushed, no pull request was opened, and no release or deployment was triggered.
