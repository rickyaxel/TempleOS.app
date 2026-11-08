# Localization verification results (2026-11-08)

Every result below was produced on 2026-11-08 on the audit's working tree; nothing is extrapolated.
Screenshots stay on the machine that produced them (`docs/localization-audit/evidence/`, ignored by
git). Device and simulator identifiers are deliberately not recorded.

Kinds of evidence, kept apart:
- **static**: validators and source audits;
- **unit**: Kotlin `:core:test` and Swift `swift test` on the host (headless shell, real kernels);
- **runtime**: the real apps on an Android emulator and an iOS simulator, driven through their
  accessibility trees, with screenshots;
- **linguistic**: none. No native speaker reviewed the translations (see `$review` in each catalog).

## Toolchain

JDK 22, Gradle wrapper of the project, Android SDK emulator (Android 16 image, 1080×2400 at 420 dpi,
automatic display scale = 360 logical px wide); Xcode 27.1, Swift 6.4, iOS 27.0 simulator (iPhone 18
Pro).

## Static checks (all 89 locales, 73 catalogs)

| Check | Command | Result |
|---|---|---|
| Catalog keys, placeholders, line breaks, Unicode, branding | `python3 tools/l10n/validate.py` | 386 keys, 72/72 catalogs complete, 0 errors, 0 warnings |
| Validator self-test | `python3 tools/l10n/test_validate.py` | 4 tests OK |
| Platform language declarations | `python3 tools/l10n/gen_platform.py --check` | 89 locales, up to date |
| Hard-coded UI text | `python3 tools/l10n/hardcoded_audit.py` | 0 findings (the same script reports 14 on the original code: the five control labels on both platforms and the two keyless `FsError`s on both platforms) |
| Census, strict | `python3 tools/l10n/census.py --out <dir> --strict-coverage --baseline d1d85bc` | 89 locales / 73 catalogs / 386 keys; 193 metadata rows triaged; 0 English-copy findings; 7 keys added, only `fil` keeps two values equal to English (intentional loanwords) |
| Label widths | AppKit measurement of every control label in all 72 catalogs (bold system font at 10 pt, as the iOS text runs; CP437 labels at 8 px per character) | every label fits one 64-px cell except `id`/`ms` `KLIK KIRI`/`KLIK KANAN`, `ky` `ЖЫЛДЫРУУ`, `zu` `SOBUNXELE` (67–80 px), which take two cells. In landscape every label fits: a one-column gutter (controls need at least 96 px) leaves at least 80 px of label room, and in a two-column gutter a wide label takes both cells |
| Original assets | `git status` of `shared/bundled-fs`, program manifests, generated PureSwift/purekotlin sources | unchanged |

## Unit tests

Baseline before any change (same working tree, owner's in-progress resolver work included): the
targeted classes `L10n`, `LocalizationRegression`, `ControlsFidelity`, `GameInput`, `LanguageList`,
`AppBehavior`, `ShellUi`, `Brand`, `Census`, `Keyboard`, `TaskLifecycle`: Kotlin 72 tests, Swift 78
tests, 0 failures.

After the changes, same classes: **Kotlin 76 tests, Swift 82 tests, 0 failures.** New tests (both
platforms):

| Test | What it proves |
|---|---|
| `gameControlsAreTranslatedWithoutChangingTheirInput` | In all 89 locales, portrait and landscape: the touch-mode and wheel labels and spoken names come from the catalog; key caps unchanged; every button sends the same key codes, wheel notches and mode changes in the same order as English; buttons stay inside their area and do not overlap; labels fit (CP437 labels exactly, others by the headless estimate); the toggle keeps its place and size while it cycles |
| `gameControlsResolveTheirLabelsOncePerLanguage` (added in the scope review below) | In Japanese and Korean (labels the platform measures), the toggle's hidden labels are measured when the language changes and never during the following frames; the shown label is the current mode's. With the controls code of the first version the test fails on both platforms: every frame measured all three labels |
| `stoppingAProgramEndsWithALocalizedLine` | A HolyC program that catches nothing, stopped from the app in Spanish: the end line is `program.ended`; the engine's `Break` message is kept in `Kernel.exitMessage` and not shown; exit category stays `STOPPED`. With the fix disabled the test fails on both platforms (Swift showed `Finalizado: Break`) |
| `programAuthorsArePeopleOrTheProject` | Every catalog author is Terry A. Davis or the project; only the project's is translated |
| `terminalBannerNamesTheTerminalInTheUiLanguage` | Italian banner `TempleOS.app Terminale`; Japanese falls back to English console text, as documented for `tr8` |

### Full suites

Run once on the working tree (which also holds the owner's uncommitted resolver work) while the
machine was heavily oversubscribed (load average up to 70 on 12 cores: both suites, an iOS build and
an emulator at once).

| Suite | Result |
|---|---|
| Kotlin `./gradlew :core:test` | 413 tests, 7 skipped, **1 failure**: `ContentModerationTest.languagesShowTheSameModeratedDocument` |
| Swift `swift test`, `TempleCoreTests` | 408 tests, 1 skipped, **4 failing tests** (10 failed assertions): `ContentModerationTests.testLanguagesShowTheSameModeratedDocument`, `InputArchitectureTests.testHundredRealTerminalLaunchTypeExecuteCloseCycles`, `KeyboardFidelityTests.testOnScreenKeyIsHeldWhileTouched`, `ShellUiTests.testLifeDrawnCellsEvolve` |
| Swift `swift test`, `PureSwiftTests` | 43 tests, 0 failures |

Diagnosis:
- `ContentModeration`: the test expects 73 JSON files besides the manifest in `shared/runtime/l10n`;
  the owner's untracked `regional-policy.json` makes it 74. The committed tree (exported from the
  index before committing) passes it on both platforms (Kotlin 53 and Swift 56 tests of the
  localization, controls, brand, moderation and behavior classes, 0 failures).
- The three other Swift tests have wall-clock deadlines (a terminal answer within 5 s, ten key repeats
  within 0.7 s, Life generations within a time limit). Run alone afterwards they passed: 81 s, 1.8 s
  and 11 s, against 189 s, 6.4 s and 28 s under load. Their Kotlin counterparts passed in the full
  run. None depends on the changed code paths.

Pre-existing, unrelated to this work: `gen_platform.py --check` fails on the committed tree (`Info.plist`
lacks the comment the generator writes); the owner's uncommitted `Info.plist` edit adds it.

### Scope review

The game controls now resolve their translated labels, the toggle's spoken names and the label widths
once per language (see "Scope review" in the audit), and two fixes outside the translation work were
backed out (`ProgramApp.kt`'s export toast and `census.py` match their parent commit again). Checked on
the tree exported from the index before committing:

| Check | Result |
|---|---|
| Kotlin `LocalizationRegressionTest`, `ControlsFidelityTest`, `AppBehaviorTest`, `L10nTest` | 37 tests, 0 failures |
| Swift `LocalizationRegressionTests`, `ControlsFidelityTests`, `GameInputTests`, `L10nTests` | 38 tests, 0 failures |
| New test on the first version's controls code | fails on both platforms (all three toggle labels measured on each of the ten frames) |
| Layout before and after, both platforms (a throwaway test, not committed): every control's label, rectangle, spoken name and toggle state for 4 control sets × 89 locales × 5 layouts (portrait 360 px with and without d-pad, portrait 320 px, landscape gutters of 96 and 140 px) × 3 touch modes | byte-identical: 5,340 configurations per platform |
| `validate.py`, `hardcoded_audit.py`, census as above | 386 keys, 72/72 catalogs complete, 0 errors; 0 findings; census passes |
| Working tree with the owner's uncommitted work, Kotlin `LocalizationRegressionTest`, `ControlsFidelityTest`, `L10nTest` | 31 tests, 0 failures |

The emulator and simulator runs below used the first version of the controls code and were not
repeated; the change keeps their layout and input identical (table above).

## Runtime: Android emulator

Build: `./gradlew :app:assembleBench`, the `bench` variant (release configuration: R8 minification and
resource shrinking; its own application id, so no installed app or data is touched; debug-signed
because no upload key is configured on the build machine). Built from the audit's working tree.

Packaging: `census.py --apk <bench apk> --aapt2 <aapt2>`: 146 localization files (manifest, 73
catalogs, 72 vocabularies) byte-identical to the sources; the compiled `locales_config` matches the 89
declared locales and is referenced by the manifest.

Run: the emulator in read-only mode (nothing persisted), app language set with the bench-only
`inputLanguage` extra, driven through the TalkBack node tree (uiautomator). Per locale: Start menu →
the localized Games entry → BattleLines → its own `OKAY` PopUp → controls → toggle → landscape →
portrait → window menu → the localized **Stop program**.

| Locale | Toggle (TalkBack) | Wheel buttons | Toggle cycles | Landscape | End line = `program.ended` | Engine reason shown |
|---|---|---|---|---|---|---|
| en-US, es-ES, de-DE, fr-FR, ar, he-IL, hi-IN, ja-JP, zh-CN, ko-KR, th, id, ru-RU, ml-IN, zu | pass (15/15) | pass (15/15) | pass (15/15) | pass (15/15) | pass (15/15) | none (15/15) |

Screenshots reviewed (360 logical px wide, the narrowest automatic layout): French `MOLETTE+`,
`MOLETTE-`, `CLIC G` whole in one cell each; Indonesian, Zulu and Malayalam labels whole. Varoom
(a d-pad game, so narrower cells) in Indonesian: the toggle spans two cells and shows `KLIK KIRI`
whole; the d-pad and key buttons keep their cells.

## Runtime: iOS simulator

Run: XCUITest `testLocalizedGameControlsAndEndLine` (Debug configuration) on an iPhone 18 Pro
simulator, iOS 27.0, device language set with `-AppleLanguages`. Same journey and checks as on
Android, through the VoiceOver element tree, with a screenshot at each step.

| Locales | Result |
|---|---|
| en-US, es-ES, de-DE, ar, he-IL | passed (first run) |
| hi-IN, ja-JP, zh-CN, zh-TW, ko-KR, th, id, ru-RU, ml-IN | passed (second run) |

The first run stopped at hi-IN in the test's own setup: a fixed 12-second wait for BattleLines'
PopUp was too short on the heavily loaded machine (the failure snapshot showed the PopUp on screen).
The test now waits for the program's `OKAY` button itself and was rerun for the remaining locales; the
localization assertions did not change.

Screenshots reviewed at full resolution: Arabic and Hebrew labels centered and in right-to-left order
(`عجلة+`, `نقرة يمنى`, `גלגלת+`, `קליק שמאלי`); Devanagari, Malayalam and Thai shaped correctly
(conjuncts and tone marks); Japanese, Korean and both Chinese scripts drawn with the system fallback
fonts; landscape gutters keep every translated label whole; end lines read, for example,
`Programm beendet. Über das Menü neu starten.` and `程式已結束。請從選單重新啟動。`.

Release configuration: `xcodebuild build -configuration Release -destination 'generic/platform=iOS
Simulator' CODE_SIGNING_ALLOWED=NO`: build succeeded. `census.py --ios-app <Release .app>`: the same
146 localization files byte-identical to the sources, and `CFBundleLocalizations` lists the 89
declared locales.

## Scenario coverage

R = runtime on emulator and simulator in this pass, U = unit test in this pass, S = static check,
E = existing test re-run in the full suites (not new), — = not executed in this pass.

| # | Scenario | Evidence |
|---|---|---|
| 001 | English baseline | R (en-US both apps), U (full suites) |
| 002 | Spanish startup | R |
| 003 | Non-English program launcher | R (localized Start menu and Games entry); E (catalog headings, all locales) |
| 004 | Non-English game controls | R, U (all 89 locales) |
| 005 | Game input parity | U (all 89 locales, both platforms); not measured on a device |
| 006 | Program completion | R, U |
| 007 | Restart from the end line | — (code unchanged; menu label already localized) |
| 008 | Program exit (close) | E |
| 009 | Terminal toolbar and banner | U (banner), E (menus) |
| 010 | Terminal command preservation | E (`TerminalAnswerTest`, `InputArchitectureTest`) |
| 011 | Editor toolbar | E (all locales, narrow window) |
| 012 | Source preserved across language switch | E |
| 013–015 | Keyboard display, accessibility, input parity | S (key caps and `key.*` coverage), E; keyboard code unchanged |
| 016 | Settings | E (all locales) |
| 017 | Language persistence | — in this pass (existing iOS UI test `testLanguageFollowsDeviceAndInAppChoice` not re-run) |
| 018–020 | Orientation, portrait, landscape controls | R |
| 021 | RTL interface | R (ar, he-IL) |
| 022 | RTL gameplay | U (input identical to English in ar, fa, he-IL, ur) |
| 023 | Long translations | U (fit, all locales), R (French, Indonesian two-cell toggle) |
| 024 | Complex script | R (Devanagari, Malayalam, Thai, CJK, Hangul screenshots) |
| 025 | Small display | R (360-px Android layout); 320-px manual display scale not run |
| 026 | Large display (tablet) | — |
| 027 | Background/foreground | — (lifecycle code unchanged) |
| 028 | Dialog localization | E (all locales) |
| 029 | Error localization | S (`FsError` keys audit); export errors not triggered at runtime |
| 030 | Accessibility | R (TalkBack and VoiceOver element trees; screen readers not running) |
| 031 | Missing resource behavior | S (0 missing), E (every catalog resolves without hidden English fallback) |
| 032 | Program identity | S (manifests unchanged), R (titles unchanged) |
| 033 | C: drive | S (paths are arguments, never translated) |
| 034 | Control event sequencing | U (down/up order identical in all locales) |
| 035 | Simultaneous controls | E (`twoFingersReleaseTwoKeys`) |
| 036 | Rapid activation | — |
| 037 | Modal return | R (program PopUp, window menu) |
| 038 | Window reopening | — |
| 039 | Resource packaging | S (Android APK bytes and locale config; iOS app bundle, see below) |
| 040 | Cross-platform parity | S (one shared catalog), R (same journey on both apps) |
| 041 | First-frame localization | S (language resolved in the shell's constructor and session restore, before the first frame) |
| 042 | Program switching | — |
| 043 | Language switch during execution | U (the Stop test switches language while the program runs), E |
| 044 | Original program output | S, R (BattleLines' PopUp and menu text unchanged) |
| 045 | No network dependency | S (bundled catalogs; no network access in either app) |
| 046 | Full locale inventory | S (all 89) |
| 047 | Native control ownership | S (authenticity boundary) |
| 048 | State restoration | — |
| 049 | Unavailable feature state | E |
| 050 | Release configuration | R (Android release-configured bench build), S (iOS Release build) |

## Known failures and limits

- No linguistic review: every new string is machine-written and listed in its catalog's `$review`.
- Runtime coverage is 15 locales on Android and 14 on iOS; the other locales are covered by the static
  checks and the unit tests (all 89), not by screenshots.
- One phone form factor per platform (Android 360-px layout, iPhone 18 Pro); no tablet, foldable or
  iPad runs; the 320-px layout of the manual display scale was not run (the unit layout check uses
  360 px portrait and a 96-px landscape gutter).
- VoiceOver and TalkBack were not running; their element trees were read by XCUITest and uiautomator.
- Export errors (`fs.error.invalid_path`, `fs.error.path_too_long`) were checked statically, not
  triggered on a device.
- The iOS UI test ran in the Debug configuration; the Release configuration was built, not run.
- The runtime runs predate the scope review; its change was verified by host tests and the layout
  comparison only.
- The APK and app were built from the working tree, which includes the owner's uncommitted resolver
  work; the committed tree was verified by host tests only.
