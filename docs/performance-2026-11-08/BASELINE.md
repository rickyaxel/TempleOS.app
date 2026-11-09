# Performance baseline and methods (2026-11-08)

Baseline commit: `ad9f15a` (`main` when the pass started). The work was done on the local branch
`perf/overnight-2026-11-08`; the owner's uncommitted work in the main checkout was not touched.

## Environment

| | |
|---|---|
| Host | Apple M3 Pro, 12 cores, 18 GB, macOS 27.0.1 |
| Toolchains | Xcode 27.1, Swift 6.4; Gradle 8.13, Android Gradle Plugin 8.12.3, Kotlin 2.2.10; tests on JetBrains Runtime 21.0.11 |
| Android device | OPPO CPH2669, Android 14 (API 34), Qualcomm SM6115 (Snapdragon 662-class, 8 cores), 3.6 GB RAM; USB power, battery 100%, thermal status 0; `bench` build type (R8 release build, profileable, installed beside the user's app under the `.bench` application id) |
| iOS | iOS Simulator only: iPhone 17, iOS 27.0, Release configuration, unsigned simulator build; a simulator created for this pass |
| Not used | The paired physical iPhone (owner's instruction: simulator only); the Android emulator that was running belonged to another project |

The Mac was shared with other projects' builds, an Android emulator and simulators; the load average varied from
about 1 to 40 during measurements. To keep comparisons fair:
- host scenarios report the **thread CPU time** of the measuring thread (less sensitive to other processes than wall
  time), and wall time beside it;
- baseline and candidate builds were run **alternately** (three rounds), never one after the other in blocks;
- the same build configuration on both sides: Swift `-c release -Xswiftc -enable-testing`; Kotlin on the test JVM
  with `-XX:-DontCompileHugeMethods` on both sides (see B-3 in [BOTTLENECKS.md](BOTTLENECKS.md));
- results are per-scenario medians (p50) of 20 samples per round unless stated; p95 only with 20 or more samples.

## Harnesses and commands

| What | Command |
|---|---|
| Desktop and runtime scenarios (new) | `./gradlew :core:test --tests '*ShellPerfTest*' -Dtempleos.shellperf=20 [-Dtempleos.shellperfonly=boot,render] [-Dtempleos.shellperfout=<file>]`; Swift: `TEMPLEOS_SHELLPERF=20 [TEMPLEOS_SHELLPERFONLY=...] swift test -c release -Xswiftc -enable-testing --filter ShellPerfTests` |
| Real-clock program benchmark (existing) | `-Dtempleos.perf=game.bombergolf,...` (`PerfTest`), `TEMPLEOS_PERF=...` (`PerfTests`) |
| Profiles | Kotlin: `-Dtempleos.jfr=<file>.jfr` with any test; Swift: macOS `sample <pid>` on the test process; Android: `simpleperf record --app com.digitalcircuitstudios.templeosapp.bench -g` (deobfuscate with the build's `mapping.txt`) |
| Android gameplay A/B | `python3 tools/performance-analysis/perf_ab_android.py -s <serial> --apk base=<apk> --apk new=<apk> --program BomberGolf --taps "Space,Left arrow,Space,Right arrow" --seconds 25 --runs 3 --out <file>` |
| Android boot and composition A/B | bench mode (docs in `BenchMode.kt`): `am start -n com.digitalcircuitstudios.templeosapp.bench/io.github.templeosmobile.android.MainActivity --es bench "programs=C:/Demo/Games/BomberGolf.HC;engines=terry;secs=6;runs=4;warmup=1;mode=light;tag=x"`; read `boot_ms` and `frame_wall_ms` from the `TOSBENCH` lines |
| iOS Simulator gameplay | `xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build-for-testing`, then `test-without-building -only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testPerfProgram` with `TEST_RUNNER_TEMPLEOS_PERF_SECONDS=30 TEST_RUNNER_TEMPLEOS_SHOTS=<dir>`; the app process's CPU time read with `ps -o time=` once a second |

`ShellPerfTest(s)` scenarios: `boot.kernel` (one kernel boot), `shell.start` (shell to its first frame),
`idle.tick.*` (a display-frame tick with nothing to do), `render.*` (forced full redraw of the desktop, a
terminal, an editor on the largest bundled source, a landscape desktop with four windows, a running program's
window), `terminal.key` and `editor.key` (one keystroke including the redraw), `editor.cursor`, `editor.scroll`,
`editor.open.large`, `window.open-close`, `window.focus.landscape4`, `window.drag.landscape4`, `fs.*` (walks of the
whole bundled drive: 56 directories, 645 files), `l10n.*` (every string looked up; a language change with its
redraw), `game.ui.*` (UI thread per second of play: shell ticks at 60 Hz plus the platform's per-frame pixel
conversion; with the counts of surface and program-frame uploads).

## Baseline measurements

Host scenario baselines and the final values are in [OVERNIGHT_FINAL_SUMMARY.md](OVERNIGHT_FINAL_SUMMARY.md)
("Final benchmark table"); machine-readable results are in [results/](results/).

Other baselines measured before any change:

| Measurement | Value |
|---|---|
| Kotlin host `PerfTest` as committed (exec not compiled by HotSpot) | BattleLines 7.0 fps (17.4 M instr/s), Squirt 6.6 fps, Varoom 4.6 fps, boot 770-930 ms |
| Same with the test JVM flag | BattleLines 30 fps (72 M instr/s), Squirt 29.5 fps, Varoom 27.7 fps, boot 132-489 ms (first boot includes JIT warm-up) |
| OPPO, BomberGolf portrait (3 runs x 25 s) | game 30 fps; frame composition 28.3 ms; kernel thread busy 87%; whole-app CPU 127% of one core; UI 60 fps; UI frame time p50 12-13 ms, p95 15-16 ms, p99 17-19 ms; janky frames 15-36 of about 790; PSS 70-76 MB |
| OPPO, boot plus program load (bench mode, 12 runs) | BattleLines 566 ms, BomberGolf 578 ms, Varoom 559 ms (medians) |
| OPPO, frame composition for 6 s of virtual time (bench mode, 8 runs) | BomberGolf 4,713 ms, RawHide 6,655 ms, CastleFrankenstein 9,363 ms (medians) |
| iOS Simulator, BomberGolf portrait (3 runs x 30 s) | app process CPU 24.5-26.7% of one host core; game 30 fps; UI 60 fps; no stalls |

## Test status at the start

- The full suites were not run on the baseline itself; they were run on the candidate trees (results in the final
  summary). On the baseline, every Kotlin test that runs HolyC ran the interpreter loop uncompiled (B-3).
- Swift in **release** (`swift test -c release`): the `TempleCoreTests` process stops with signal 10 (stack overflow)
  in `FuzzTests.testDeepNestingProbes`, and in `DynExprUnitTests` when that runs first, on the baseline and on every
  candidate alike; both pass alone and in debug. It leaves `shared/test-vectors/fuzz-repro/swift-nesting-INFLIGHT.*`
  behind. Not changed by this pass.
- Earlier reports of wall-clock-sensitive Swift tests failing under load (`InputArchitectureTests`,
  `KeyboardFidelityTests`, `ShellUiTests.testLifeDrawnCellsEvolve`) did not recur in this pass's runs.
