# TempleOS.app mobile localization audit (2026-11-08)

Purpose: find every place where application-owned English still appears when the Swift (iOS) or
Kotlin (Android) app runs in another supported language, fix it without changing what any control
does, and leave checks that catch the next one. TempleOS content itself is out of scope by design
(see [TEMPLEOS_LOCALIZATION_AUTHENTICITY_BOUNDARY.md](TEMPLEOS_LOCALIZATION_AUTHENTICITY_BOUNDARY.md)).

Repository state at the start: branch `main` at `d1d85bc`, with uncommitted work in progress on
hierarchical language resolution (resolver, regional policy, per-app language sync). That work was
left untouched and is not part of this audit's commits.

## Architecture (both platforms)

There is no platform resource system for UI text: both apps draw their whole interface into one
indexed framebuffer through a shared shell (`temple_os_kotlin/core/.../ui`,
`temple_os_swift/TempleCore/Sources/TempleCore/UI`; line-for-line ports). Text comes from
`L10n.tr(key)` over the shared JSON catalogs in `shared/runtime/l10n`; `tr8` writes console text in
CP437 (English when the TempleOS font cannot show the translation). Text the TempleOS font cannot
draw becomes a platform text run (shaping, bidi and font fallback by Core Text / Android text).
Screen-reader nodes are recorded while drawing and published as VoiceOver elements
(`AccessibilityAdapter.swift`) and TalkBack virtual nodes (`AccessibilityAdapter.kt`), with the UI
locale's language set on each. Android `res/values/strings.xml` holds only the untranslatable app
name; iOS `Info.plist` declares `CFBundleLocalizations` generated from the manifest.

Language selection: in-app choice (Language window, Settings), then the device/per-app language
list, then en-US. Changes apply live without restarting programs (`Shell.applyLanguage`, cached
labels refresh through `L10n.Presentation` when `L10n.version` changes).

## Supported languages

89 locales served by 73 catalogs, identical on both platforms (one manifest, generated platform
declarations; `gen_platform.py --check` passes). Right-to-left: `ar`, `fa` (4 locales), `he-IL`,
`ur`. Scripts: Latin, Cyrillic, Greek, Armenian, Georgian, Arabic, Hebrew, Devanagari, Bengali,
Gujarati, Gurmukhi, Odia, Tamil, Telugu, Kannada, Malayalam, Sinhala, Thai, Lao, Khmer, Myanmar,
Ethiopic, Hangul, Han (Simplified/Traditional), Japanese kana. Locales sharing a catalog are listed in
[localization.md](../localization.md); nothing was added or removed.

## Method

1. Read the localization system, docs and tools; ran the existing validators (all passed: catalogs
   complete, `hardcoded_audit.py` found 0) and the targeted test suites (Kotlin 72 / Swift 78 tests,
   0 failures) as a baseline.
2. Swept every string literal containing letters in the UI and platform code of both apps (1,962
   literals), filtered identifiers and data keys, and traced each remaining candidate to where
   it reaches the screen or a screen reader.
3. Traced generated text: kernel exit messages, `FsError` messages, catalog metadata fields shown in
   dialogs, console banners, accessibility labels assigned in the platform layers.
4. Compared the catalog keys each platform references (identical except a Kotlin-only null-message
   fallback) and the two implementations of every affected surface.

## Findings

| ID | Severity | Surface | Visible English | Root cause | Status |
|---|---|---|---|---|---|
| L-01 | High | Game controls (every graphics program with on-screen controls) | `L-CLICK`, `R-CLICK`, `MOVE` | Literal labels in `GameControls.draw`; the spoken text was chosen by comparing the visible English label, so the label could not be translated without breaking VoiceOver/TalkBack | Fixed (both) |
| L-02 | High | Game controls (programs that read the wheel, e.g. BattleLines) | `WHL+`, `WHL-` | Literal labels | Fixed (both) |
| L-03 | Medium | Program end line after **Stop program** | `Ended: Break`, `Ended: Stopped.` (e.g. Spanish showed `Finalizado: Break`) | The end line always quoted the kernel's exit message, including the engine's reaction to the app's own Stop command | Fixed (both) |
| L-04 | Low | Program end line after a host failure | `Ended: internal error` | Host runtime's sentinel passed to the kernel as the exit message | Fixed (both) |
| L-05 | Medium | About this program (9 examples written for the project) | `Author: TempleOS.app contributors` | The catalog's `author` field shown raw (the license field was already mapped) | Fixed (both) |
| L-06 | Low | Save as after a document program ends | `Invalid path`, `Path is too long` | `FsError` created without a catalog key, so `localized()` showed its message | Fixed (both) |
| L-07 | Low | Terminal banner | `TempleOS.app Terminal` | The word "Terminal" written as a literal beside the `tr8` banner text | Fixed (both) |
| L-08 | Low | Save as error toast (Android) | empty toast | A non-`FsError` exception without a message produced an empty toast | Fixed (Kotlin; Swift already showed the error text) |

Not defects (classified and left as they are, with reasons in the boundary document): key caps on the
keyboard, key row and game controls; game buttons named by the program's own menu; kernel and
compiler messages; console lines written by the kernel emulation (`Program stopped (Break).`); file
names and paths; engine names; the HolyC starter template; the picture decoder's detail text; the
product-required brand intro and its `MENU` chip.

Tooling defects found on the way:
- `hardcoded_audit.py` only matched single-line calls from a fixed list, so it missed all of the
  above. It now also checks the game controls' `Btn`, multi-line calls, platform accessibility
  assignments and keyless `FsError`s; on the original code it reports 14 findings, on the fixed code 0.
- `census.py` defaulted to a baseline commit that predates this repository's history and crashed
  without `--baseline`; it now defaults to `HEAD`.

## Changes

- **Game controls** (`ProgramHost.kt`, `ProgramHost.swift`): labels from `controls.button.*`; the
  spoken text is attached to each button; the touch-mode toggle takes its label and spoken name from
  one table indexed by the mode; a translated label wider than its grid cell takes the cells it needs
  on its row (only these labels; key and menu buttons keep one cell, and English layouts are
  unchanged on screens at least 360 logical px wide, which every automatic display scale gives). Scan codes, wheel deltas, typematic repeat and the toggle
  action are unchanged.
- **End line** (`ProgramApp`, `KernelRunner`): `stoppedByUser` and `internalError` decide the app's own
  line; `Kernel.exitMessage` and the exit category are untouched.
- **Author** (`ProgramInfo.localizedAuthor`), **export errors** (`DocumentRuntime.export` now passes
  `fs.error.invalid_path` / `fs.error.path_too_long`), **Terminal banner** (`tr8("app.terminal.title")`).
- **Catalogs**: 7 keys added to `en.json` and all 72 translations; the five control labels are listed
  in every catalog's `$review`, the two sentences in the catalogs that already carry many review flags.
- **Tests**: `LocalizationRegressionTest(s)` gained four tests per platform, and the iOS UI tests
  gained `testLocalizedGameControlsAndEndLine` (see the verification results). **Tools**:
  `hardcoded_audit.py`, `census.py` as above.

## Final assessment

Within the audited scope (all drawn UI, menus, dialogs, toasts, screen-reader labels and
app-generated messages of both apps) no confirmed application-owned English remains, apart from the
documented exceptions. The translations added here are machine-written, like the existing catalogs,
and await native review (`$review`). Runtime coverage and its limits are in
[TEMPLEOS_LOCALIZATION_VERIFICATION_RESULTS.md](TEMPLEOS_LOCALIZATION_VERIFICATION_RESULTS.md).

Open items for the owner:
- The startup brand copy (`Tap MENU to begin.` and the empty-desktop `MENU` chip) is the first
  English a non-English user sees. It is English by the documented Brand/distribution decision
  (`Brand.INTRO_LINES`); reconsider if that decision changes.
- The iOS container view keeps the accessibility label `TempleOS desktop`. VoiceOver reads its child
  elements instead (it is not an accessibility element); this was not checked with VoiceOver running.
- Console text keeps falling back to English for languages the TempleOS font cannot draw (`tr8`), a
  documented limitation of 8-bit console cells.
- Game buttons named by a program's own menu keep one grid cell and the program's text, so a long
  entry is cut at the cell's edge (BattleLines' `TimeLapse` shows as `TimeLaps` in a landscape
  gutter, in every language including English). This predates the audit and is not a translation
  issue; giving those buttons the two-cell rule would change English layouts, so it was left for
  the owner to decide.
