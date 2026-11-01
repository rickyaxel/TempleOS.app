# Testing

Paint investigation and bounded wrapper repairs (2026-10-22): see
paint-restoration/REPORT.md. `PaintRestorationTest(s)`
exercise indexed GR/archive compatibility, real pixels and preview frames, pointer
ownership/cancellation, file reopening and lifecycle boundaries. The shared replay
is explicitly for the mobile-authored wrapper; the original sprite editor remains
blocked in all four historical execution targets. Device workflows are
`testPaintRestorationWorkflow` and `tools/paint-restoration/android_workflow.py`,
followed by `android_tools_workflow.py` for all five wrapper tools and actual saved
GR bytes. Neither clears application data. The physical OPPO Android 14 workflow
and simulator evidence are in the report.

> **Typography pass (2026-10-18):** Kotlin `:core:test` **266 tests**, Swift `swift test` **262 tests** (1 skipped),
> 0 failures. New: `TypographyTest(s)`, the iOS UI test `testTypographyMatrix` (20 locales, edge-steepness check) and
> `tools/ui-audit/typography_matrix_android.py`. See `docs/typography/TEMPLEOS_TYPOGRAPHY.md`.

> **Audio fidelity pass 2 (2026-10-18):** Kotlin `:core:test` **261 tests**, 0 failures; Swift `swift test`
> **257 tests**, 0 failures, 1 skipped. New: `AudioFidelityTest(s)` (Play fixtures from the reference model
> `tools/audio/templeos_snd.py`, checked against the original TempleOS in the reference VM), `BlockedProgramsSoundTest(s)`,
> `TaskLifecycleTest(s)` (Whap BadMem). See `docs/audio/TEMPLEOS_AUDIO_FIDELITY.md`.

> **Menu sizing and performance pass (2026-10-17).**
> - Kotlin `:core:test`: **189 tests**, 0 failures.
> - New suites:
>   - `MenuMetricsTest(s)`, for the responsive menus;
>   - `RasterDiffTest(s)` cases for `mat4x4`, `lighting`, `circle` and `putChar`, plus symmetric `blot3`;
>   - the opt-in `PerfTest`/`PerfTests` (`-Dtempleos.perf=` / `TEMPLEOS_PERF=`) and `MenuShotsTest`
>     (`-Dtempleos.menushots=`).
> - New XCUITests: `testMenuSizing` and `testPerfProgram`. The coordinate-based XCUITests now find
>   menu items by label.
> - Device tools: `tools/performance-analysis/`.
> - See `docs/performance/` and
>   `docs/ui-normalization/TEMPLEOS_RESPONSIVE_MENU_UI.md`.

Status as of 2026-10-16. Every result below was produced in this repository;
nothing is extrapolated. Where something was not tested, it says so.

> **Fidelity audit (2026-10-17):** see
> `docs/fidelity-audit/TEMPLEOS_FIDELITY_TEST_RESULTS.md`.
> Totals now: Kotlin `:core:test` **175 tests**, 0 failures; Swift `swift test` **172 tests**,
> 0 failures, 1 skipped. New: the shared scenarios (`ScenarioTest(s)`, 354 source-derived
> scenarios; `-Dtempleos.scenarios=all|slow|<prefix>` / `TEMPLEOS_SCENARIOS`), the fidelity suites
> (`WindowGeometry`, `SoundTiming`, `InputFidelity`, `ScreenFidelity`, `ControlsFidelity`,
> `KeyboardFidelity`, `RuntimeFidelity`), the opt-in `VmPlanFramesTest` (`-Dtempleos.vmplan=all`),
> the iOS UI test `testFidelityAuditPrograms`, HolyC vectors 220-222, and the reference VM tools
> (`tools/reference-vm`). The sections below describe earlier states.

> **Verification pass (2026-10-16):** see `docs/verification-pass/` for the
> independent results.
>
> Totals now:
> - Kotlin `:core:test`: **94 tests**, 0 failures, 1 skipped.
> - Swift `swift test`: **77 tests**, 0 failures, 2 skipped.
> - ASan run (FuzzTests, LimitsTests, MemorySafetyTests): 49 tests, no reports.
> - iOS XCUITests: `testAcceptanceFlow`, `testFrameRates`, `testLargeTouchTargetsAndKeyRow`.
> - HolyC vectors: **42**.
>
> New suites on both runtimes:
> - `MemorySafetyTest(s)`, `LimitsTest(s)`, `FuzzTest(s)`;
> - `GameInputTest(s)`, `AppBehaviorTest(s)`, `FramePublishTest(s)`, `TerminalAnswerTest(s)`;
> - Life tests;
> - `BenchTest(s)` (opt-in, `-Dtempleos.bench=N` / `TEMPLEOS_BENCH=N`).
>
> Run them as listed in `docs/verification-pass/VERIFICATION_REPORT.md` §6.
> The counts and tables below describe the state before that pass.

## 1. Automated test suites

### Kotlin (`temple_os_kotlin/core`, JVM, `./gradlew :core:test`)

24 tests always run; 7 more are opt-in diagnostics that return immediately
unless enabled with a `-Dtempleos.*` property. Last full run: **31 tests,
0 failures**.

| Suite | Tests | What it checks |
|---|---|---|
| `HolyCVectorTest` | 1 (16 vectors) | every `shared/test-vectors/holyc/*.HC` program's console output or expected error |
| `RasterDiffTest` | 10 | native graphics routines vs the original HolyC on random inputs (pixels, depth buffer, collisions, extents, return values, RNG use), `Line`, `SpriteSize` on all 325 bundled sprites |
| `LayeredFsTest` | 6 | path normalization and traversal, copy-on-write, whiteouts, restore, quota, atomic writes, HolyC file I/O and `#include` from the virtual drive |
| `GraphicsDemoTest` | 2 | prelude + graphics library boot; `Demo/Graphics/Lines.HC` runs without error and draws at least 3 colours |
| `ShellUiTest` | 3 | headless desktop: every app opens, terminal runs HolyC, graphics program publishes frames, session save/restore, landscape tiling, Paint `.GR` round trip, menus after dialogs with per-touch ids |
| `DragTest` | 2 | drags reach programs (Maze draws walls); quick taps register (TicTacToe), verified by mutation |
| `SweepTest` *(opt-in)* | 1 | runs Demo/Games, Demo/Graphics, Apps or the whole catalog for 3 s of virtual time; writes frames for parity |
| `CensusTest`, `DebugTest`, `DebugLex`, `ProbeTest`, `ProbeSpriteTest`, `FlapProbeTest` *(opt-in)* | 6 | diagnostics used during development |

### Swift (`temple_os_swift/TempleCore`, `swift test` on macOS)

14 tests always run; `SweepTests` is opt-in (`TEMPLEOS_SWEEP=...`). Last
run: **14 tests, 0 failures**.

| Suite | Tests | What it checks |
|---|---|---|
| `HolyCVectorTests` | 1 (16 vectors) | same vectors as Kotlin |
| `LayeredFsTests` | 6 | same cases as Kotlin |
| `ShellUiTests` | 7 | same headless shell checks as Kotlin plus drag, quick tap, iOS-style touch ids, menu after an editor run |
| `SweepTests` *(opt-in)* | 1 | Swift sweep; writes frames for parity |

### iOS UI tests (`TempleOSMobileUITests`, XCUITest on the simulator)

| Test | Result (iPhone 17 simulator, iOS 26.1) |
|---|---|
| `testAcceptanceFlow` | **passed** (Debug): first launch, start menu, Terminal `Dir;` and an expression, rotation to landscape and back, editor typing, Save as `C:/Home/MyTest.HC`, RUN output, Games → BattleLines, popup OKAY, drag on the battlefield, Pause and Resume from the window menu, relaunch with session restore |
| `testFrameRates` | **passed** (Release): BattleLines and Varoom show 30 FPS |

Screenshots are attached to the test result and can be written to a folder
with `TEST_RUNNER_TEMPLEOS_SHOTS=<dir>`.

### Cross-platform parity

`tools/parity/compare_frames.py Catalog` after both catalog sweeps (64 MiB):
same status for all 96 programs; 88 of 91 final frames byte-identical; 3
differ by 34–2597 pixels (X-Caliber, RocketScience, Squirt) because the
platforms' math libraries round transcendental functions differently. (Since 2026-10-20 both
platforms use fdlibm for `Sin`/`Cos`/`Exp`/`Pow`/..., and the four-engine comparison below finds
no such differences: native-translation/findings.md F-2.)

### Native engines (Pure Kotlin / Pure Swift)

Differential tests between the interpreter and the ahead-of-time translations, and between the
platforms (frames, palette, sound, console, budget ticks and every global, every 20 ms of virtual
time); results in native-translation/REPORT.md.

```sh
cd temple_os_kotlin
./gradlew :translator:run --args=translate          # regenerate (incremental; --force for all)
./gradlew :purekotlin:test                          # audit, function-level diff, lifecycle, BomberGolf + TreeCheckers parity
./gradlew :purekotlin:test --tests '*ParityTest.sweepAll' -Dtempleos.parity=all   # every translated catalog program
./gradlew :purekotlin:test --tests '*BenchmarkTest*' -Dtempleos.bench=default    # host benchmark
cd ../temple_os_swift/TempleCore
swift build -c release --build-tests -Xswiftc -enable-testing
TEMPLEOS_PARITY=all swift test -c release -Xswiftc -enable-testing --skip-build --filter ParityTests.testSweepAll  # 4-way, after the Kotlin sweep
TEMPLEOS_BENCH=default swift test -c release -Xswiftc -enable-testing --skip-build --filter BenchmarkTests
python3 tools/performance-analysis/perf_engines_android.py -s <serial> --apk <release.apk> --program "Games...:BomberGolf:Space"
```

### Offline / capability audit

`tools/compatibility-validation/offline_audit.sh` checks the release APK, the
iOS app bundle and both source trees: no permissions, no INTERNET, only the
launcher intent, no data/URL intent filters, no providers/services/receivers,
backup disabled, no networking classes in dex, no URL types / document types
/ ATS keys / file sharing / app extensions on iOS, no Network/WebKit/
JavaScriptCore linkage or URLSession/socket/WebView symbols, no document
pickers or URL handlers in sources, no third-party dependencies. Last run:
**all checks passed**.

## 2. Manual and device testing

| Platform | Device | What was done |
|---|---|---|
| Android | emulator `Medium_Phone_API_36.0` (Android 16, arm64) | release and debug builds installed; desktop, start menu, Terminal, Games; BattleLines, Varoom, Maze, TicTacToe, FlapBat played or observed; FPS/CPU/memory measured; **first launch in airplane mode** (Terminal `Dir;` and HolyC expression worked); session restore after process kill |
| Android | OPPO CPH2669 (Android 14), physical | release APK installed (it is still installed); **no interactive test**: the phone was locked and was not unlocked |
| iOS | iPhone 17 simulator (iOS 26.1) | Debug and Release builds; XCUITests above; idle memory |
| iOS | physical iPhone | **not tested** (none attached) |

## 3. Not tested / known gaps

- Physical devices (both platforms).
- Sound output by ear: since 2026-10-18 the rendered and mixed audio is recorded and checked against
  TempleOS's own trace on both phones (`docs/audio/TEMPLEOS_SOUND.md` §7–9), but no one listened to
  every program.
- Hardware keyboards on real devices (mapping is unit-level only).
- Accessibility (VoiceOver/TalkBack): the desktop is a single custom view.
- Low-memory behaviour and process death on real devices.
- iPad layouts beyond the shared landscape/portrait logic.
- Fuzzing of the compiler and VM (see `security-model.md` §7).

## 4. Commands

```sh
# Kotlin
cd temple_os_kotlin && ./gradlew :core:test :app:assembleDebug :app:assembleRelease
./gradlew :core:test --tests '*SweepTest*' -Dtempleos.sweep=Catalog -Dtempleos.memmb=64

# Swift
cd temple_os_swift/TempleCore && swift test
swift build -c release --build-tests -Xswiftc -enable-testing
TEMPLEOS_MEMMB=64 TEMPLEOS_SWEEP=Catalog swift test -c release --skip-build -Xswiftc -enable-testing --filter SweepTests

# Parity and audit
python3 tools/parity/compare_frames.py Catalog
tools/compatibility-validation/offline_audit.sh <ios-derived-data-dir>

# iOS UI tests
cd temple_os_swift/App && xcodebuild -project TempleOSMobile.xcodeproj -scheme TempleOSMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Language lists

- `LanguageListTest` (Kotlin) and `LanguageListTests` (Swift): the Language window's order
  (docs/localization.md, "Language lists"): permutations, accents, case, scripts, RTL, variants,
  missing names, duplicates, ties, languages added later, language switches, the window's rows and
  selection.
- Device flows (orders written to `docs/localization-evidence/language-order/`):
  - Android 13+: `python3 tools/l10n/language_order.py android -s <serial> --apk <apk>`
  - iOS (simulator only; it reads the repository's files): `-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testLanguageListOrder`
    with `TEST_RUNNER_TEMPLEOS_ORDER_OUT=<dir>`
  - Parity: `python3 tools/l10n/language_order.py compare <dir>/android.json <dir>/ios.json`

## God Words localization and documentation attribution

- `GodWordsTest` (Kotlin) and `GodWordsTests` (Swift) check the tokenizer, the picks, language
  isolation, coverage, fallbacks, the attribution notice and the About page against
  `shared/test-vectors/god-words/vectors.json` (`tools/l10n/vocab.py vectors`).
- Device flows:
  - Android: `python3 tools/l10n/god_words_android.py -s emulator-5554 --apk <apk>`
  - iOS (simulator only; it reads the repository's files): `-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testGodWordsLocalization`
- Data checks:
  - `tools/l10n/vocab.py check`
  - `tools/provenance/doc_attribution_audit.py --out docs/fidelity-audit/evidence/doc-attribution.md`

Report: fidelity-audit/TEMPLEOS_10_WORDS_VALIDATION.md.

## System chrome (navigation bar, gesture handle, home indicator)

- `SystemChromeTest` (Kotlin) and `SystemChromeTests` (Swift): 12 cases each. Every shell case
  also checks the rendered surface: the bottom gutter and the row above it must equal the
  resolved `SystemChrome` color.
- Android device check (emulator or phone; screenshots, colors, icon polarity, a screen
  recording of quick navigation):
  - `python3 tools/system-chrome/android_nav_check.py -s emulator-5554 --out <dir> --mode threebutton --install <apk>`
  - then the same with `--mode gestural`;
  - on a personal phone, add `--no-clear`. Its mode cannot be switched from adb on ColorOS.
- iOS (simulator):
  `-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testSystemChromeFollowsTheScreen`
  (with `TEST_RUNNER_TEMPLEOS_SHOTS=<dir>` for the PNGs).

Report and device matrix: ui-normalization/SYSTEM_CHROME.md.

## iPhone Duo (foldable) and adaptive layout

- `DisplayLayoutTests` (Swift only): the layout policy and the shell on synthetic screens (phones,
  every Duo posture as the simulator measures it, asymmetric insets, an edge occlusion, a narrow
  split window, the smallest surface, degenerate input), 20 fold cycles keeping every window and
  app, menus opened before a transition, and the cost of a transition.
- `DuoPostureUITests` (iOS UI tests, iPhone Duo simulator only): real fold and rotation
  transitions pressed in DeviceHub by `tools/foldable/posture_server.sh` during the test. Covers the
  posture matrix, menus, dialogs, the terminal with a running HolyC loop and a latched CTRL, a game,
  Sound, background/foreground, rotation combinations, 20 repeated cycles, 13 languages and the
  TempleOS keyboard across 40 close/open cycles (`testD30_…`, `DUO_KB_CYCLES`). Skipped without the
  server.
- `KeyboardLifecycleTests` (Swift) and the iOS UI test `testKeyboardVisibilityFollowsOnlyAttributedActions`:
  the TempleOS keyboard's visibility changes only for attributed reasons, never for geometry
  (foldable/KEYBOARD_LIFECYCLE.md).
  - `tools/foldable/run_duo_campaign.sh <dir> [test ...]` (needs the Accessibility permission for the
    terminal; don't use the Mac while it runs).

Report: foldable/IPHONE_DUO_ADAPTATION.md.

## Content moderation

- `ContentModerationTest` (Kotlin) and `ContentModerationTests` (Swift), 8 cases each: every
  manifest edit is in the bundled files and marked ADAPTED; with `reference/templeos-iso`, each file
  is the original plus its edits and nothing else; redacted wording reaches neither the viewer's
  text nor accessibility labels; religious and technical text is kept; markers are safe DolDoc;
  every reading path and every UI language shows the same moderated text; every catalog has the
  notice strings. Original wording is identified by hash and never spelled out in the tests.
- iOS (simulator): `-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testModeratedDocumentsShowRedactionMarkers`
  (markers, notice, rotation, a German UI, About).
- Data checks:
  - `python3 tools/resource-packaging/moderation.py check reference/templeos-iso`
  - `tools/provenance/doc_attribution_audit.py` (as above)

Report: [content-moderation/CONTENT_MODERATION.md](content-moderation/CONTENT_MODERATION.md).
