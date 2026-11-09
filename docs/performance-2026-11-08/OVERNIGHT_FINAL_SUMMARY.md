# Performance pass, 2026-11-08: final summary

Both apps do the same work as before, faster, without changing what they draw, run or accept as input. Programs
and terminals start in less than half the time on a low-end Android phone. A running game no longer makes the
desktop re-upload every frame, and typing redraws are 27-44% cheaper.

- Baseline: `ad9f15a`. Final: `9e29aac` on the local branch `perf/overnight-2026-11-08` (not pushed).
- Environment and methods: [BASELINE.md](BASELINE.md). Ranked findings: [BOTTLENECKS.md](BOTTLENECKS.md).
- Per platform: [KOTLIN_OPTIMIZATION_REPORT.md](KOTLIN_OPTIMIZATION_REPORT.md), [SWIFT_OPTIMIZATION_REPORT.md](SWIFT_OPTIMIZATION_REPORT.md),
  [CROSS_PLATFORM_COMPARISON.md](CROSS_PLATFORM_COMPARISON.md). Raw data: [results/](results/README.md).

## Commits

| Commit | Change | Platforms |
|---|---|---|
| `82f49c2` | Test JVM compiles the interpreter loop (`-XX:-DontCompileHugeMethods`) | Kotlin tests only |
| `180a756` | `ShellPerfTest` / `ShellPerfTests`: opt-in desktop and runtime timing scenarios | both (tests) |
| `624e837` | Upload the desktop surface only when a redraw changes it (`Surface.commit`) | both |
| `3da0048` | Pen tables set up natively at kernel boot (`Kernel.setUpPens`, `PenTablesTest(s)`) | both |
| `70085e2` | Overlay folder's canonical path resolved once | both |
| `c39429c` | Glyphs inside the clip drawn without per-pixel clip tests | both |
| `06162b4` | `tools/performance-analysis/perf_ab_android.py`: alternating A/B on an Android device | tool |
| `b9d1e43` | GrBlot3 pixels written directly when `plot0` needs no extra bookkeeping | both |
| `9e29aac` | HolyC punctuators matched on bytes in the lexer | Swift |
| (this commit) | These reports and their raw results | docs |

## Most important results

| Platform | Scenario | Before | After | Change | Samples, source |
|---|---|---|---|---|---|
| Android device | Program start (boot plus load), BattleLines / BomberGolf / Varoom | 566 / 578 / 559 ms | 241 / 262 / 231 ms | -55 to -59% | 12 runs each, medians; ranges do not overlap (OPPO CPH2669, bench mode) |
| Android device | BomberGolf: whole-app CPU | 127% of a core | 120% | -7 points | 3 x 25 s (`624e837` alone) |
| Android device | BomberGolf: UI frame time p95 / p99 | 15-16 / 17-19 ms | 13-14 / 14-15 ms | -2 to -4 ms | 3 x 25 s, gfxinfo (`624e837` alone) |
| Android device | BomberGolf: janky UI frames | 15-36 per ~790 | 0-3 | | 3 x 25 s (`624e837` alone) |
| Android device | BomberGolf frame composition, 6 s of game time | 4,713 ms | 4,478 ms | -5% | 8 runs, ranges do not overlap (`b9d1e43` alone) |
| iOS Simulator | BomberGolf: app process CPU | 25.8% (24.5-26.7) | 23.4% (20.1-24.0) | -9% | 3 x 30 s |
| Kotlin host | Kernel boot | 121.7 ms | 28.8 ms | -76% | 3 x 20 |
| Swift host | Kernel boot | 75.3 ms | 42.5 ms, then 37.2-38.2 ms with `9e29aac` | -44%, then -50% | 3 x 20; 4 x 40 |
| Kotlin / Swift host | Terminal keystroke (with redraw) | 195 / 294 µs | 113 / 165 µs | -42% / -44% | 3 x 20 |
| Kotlin / Swift host | UI thread while Varoom plays | 11.4 / 10.2 ms/s | 8.2 / 7.3 ms/s | -28% / -29% | 3 x 20 one-second windows |
| Kotlin host (test suite) | `:core:test` | (about 27 min in the previous session, on a busier machine) | 4 min 40 s | | B-3 and faster boots |

## Final benchmark table (host)

Thread CPU time per operation (µs) or per second of play (ms/s), M3 Pro host, Kotlin on the test JVM and Swift
release. Each value is the median of three alternating rounds' p50 (20 samples each); p95 likewise. Baseline
`ad9f15a`, final `b9d1e43` (the Swift lexer commit `9e29aac` came after this table: Swift boot 37.2-38.2 ms).
Memory was not measured by the harness; the only added memory is one surface-sized copy (about 288 KB at 360x800
logical px) per shell.

| Platform | Scenario | Baseline p50 | Final p50 | Change | Baseline p95 | Final p95 | Result |
|---|---|---|---|---|---|---|---|
| Kotlin | boot.kernel (ms) | 121.7 | 28.8 | -76% | N/A | N/A | improved |
| Kotlin | shell.start | 218 | 288 | +32% | 1,192 | 1,076 | regression (+70 µs once per launch; attributed to allocating and filling the first committed copy) |
| Kotlin | render.desktop | 43.5 | 53.5 | +23% | 84.7 | 99.2 | regression (+10 µs: comparing an unchanged frame, which is then not uploaded) |
| Kotlin | render.terminal | 209.8 | 125.2 | -40% | 410.3 | 236.7 | improved |
| Kotlin | terminal.key | 195.4 | 113.2 | -42% | 224.1 | 122.0 | improved |
| Kotlin | render.editor | 184.2 | 125.7 | -32% | 194.7 | 128.1 | improved |
| Kotlin | editor.key | 191.1 | 133.1 | -30% | 194.5 | 149.3 | improved |
| Kotlin | editor.cursor / editor.scroll | 176.3 / 152.0 | 128.3 / 110.9 | -27% / -27% | 182.5 / 160.9 | 138.7 / 114.6 | improved |
| Kotlin | window.open-close | 642.3 | 546.8 | -15% | 3,247.5 | 732.5 | improved |
| Kotlin | render / focus / drag, landscape, 4 windows | 209.9 / 140.1 / 176.0 | 172.4 / 119.1 / 139.8 | -18% / -15% / -21% | 238.3 / 149.5 / 186.8 | 209.0 / 137.1 / 152.0 | improved |
| Kotlin | fs list / read / stat, whole drive (ms) | 8.65 / 64.8 / 47.7 | 7.01 / 57.1 / 41.7 | -19% / -12% / -13% | 9.18 / 71.5 / 48.3 | 8.28 / 67.2 / 43.9 | improved |
| Kotlin | l10n.switch+render | 229.6 | 199.8 | -13% | 284.8 | 439.4 | inconclusive (p95 noisy) |
| Kotlin | render.program (BomberGolf / Varoom) | 72.5 / 42.9 | 76.7 / 49.2 | +6% / +15% | 91.3 / 44.7 | 117.5 / 50.4 | regression (+4 to +6 µs: the comparison; the upload it avoids is not in this number) |
| Kotlin | game.ui BomberGolf / Varoom (ms/s) | 26.7 / 11.4 | 25.7 / 8.2 | -4% / -28% | 37.8 / 14.0 | 34.5 / 11.6 | improved; surface uploads 29.9 / 27.4 per s -> 0.05 / 0.1 |
| Swift | boot.kernel (ms) | 75.3 | 42.5 | -44% | N/A | N/A | improved (37.2-38.2 with `9e29aac`) |
| Swift | shell.start | 46.5 | 46.0 | -1% | 64.4 | 61.6 | unchanged |
| Swift | render.desktop | 21.8 | 24.7 | +14% | 22.2 | 25.1 | regression (+3 µs: comparison of an unchanged frame) |
| Swift | render.terminal / terminal.key | 294.5 / 294.4 | 164.6 / 165.0 | -44% / -44% | 299.9 / 295.9 | 170.3 / 166.5 | improved |
| Swift | render.editor / editor.key | 194.2 / 200.4 | 131.6 / 137.6 | -32% / -31% | 195.1 / 201.6 | 132.7 / 139.7 | improved |
| Swift | editor.cursor / editor.scroll / editor.open.large | 194.7 / 177.4 / 378.3 | 131.3 / 124.1 / 343.8 | -33% / -30% / -9% | 195.1 / 179.0 / 409.0 | 132.8 / 125.1 / 357.0 | improved |
| Swift | window.open-close | 714.7 | 646.4 | -10% | 732.0 | 668.1 | improved |
| Swift | render / focus / drag, landscape, 4 windows | 314.5 / 258.7 / 324.1 | 260.5 / 214.2 / 268.9 | -17% each | 316.2 / 259.8 / 331.4 | 261.9 / 216.5 / 270.0 | improved |
| Swift | fs list / read / stat, whole drive (ms) | 8.87 / 64.6 / 48.7 | 7.30 / 54.8 / 39.7 | -18% / -15% / -19% | 9.09 / 65.2 / 52.0 | 7.81 / 57.5 / 40.7 | improved |
| Swift | l10n.tr.all-keys / l10n.switch+render | 215.9 / 374.1 | 216.9 / 367.0 | 0% / -2% | 219.9 / 385.2 | 219.1 / 380.7 | unchanged |
| Swift | render.program (BomberGolf / Varoom) | 102.9 / 58.6 | 100.0 / 49.7 | -3% / -15% | 166.0 / 60.2 | 155.2 / 50.2 | improved |
| Swift | game.ui BomberGolf / Varoom (ms/s) | 36.5 / 10.2 | 26.6 / 7.3 | -27% / -29% | 40.4 / 13.3 | 30.1 / 9.3 | improved; surface uploads 29.7 / 30.0 per s -> 0.05 / 0.05 |

Idle ticks (`idle.tick.*`, under 0.5 µs) did not change measurably.

## Unsuccessful or not kept

- **Byte-matching punctuators in the Kotlin lexer:** within noise on the JVM (boot 20.2-26.8 -> 19.8-21.7 ms);
  reverted. The same change on Swift was kept (`9e29aac`, -9.5% boot on a quiet host).
- **A filesystem lookup cache** (B-10): not attempted; correct invalidation on every overlay change outweighs a gain of
  tens of microseconds per user action.
- **Kotlin composition copies** (B-9): not changed; they stayed under the device profile's report threshold.

## Tests

| Suite | Result |
|---|---|
| Kotlin `:core:test` (final tree) | 416 tests, 11 skipped, 0 failures (13 min together with `:purekotlin:test`) |
| Kotlin `:purekotlin:test` (engine parity) | 70 tests, 0 failures |
| Swift `swift test` debug, `TempleCoreTests` (tree `b9d1e43`) | 411 tests, 5 skipped, 0 failures |
| Swift `swift test` debug, `PureSwiftTests` (tree `b9d1e43`) | 43 tests, 0 failures |
| Swift after `9e29aac` (debug): HolyCVector, Fuzz, DynExprUnit, Limits, Scenario, GraphicsDemo, MemorySafety, PenTables, RuntimeFidelity | 87 tests, 2 skipped, 0 failures |
| Swift `swift test -c release`, full | Pre-existing: the test process stops with signal 10 (stack overflow) in `FuzzTests.testDeepNestingProbes` (and `DynExprUnitTests` when that runs first), identically on the baseline; both pass alone and in debug |
| iOS UI test `testPerfProgram` (Simulator, Release) | 6 runs passed (3 baseline, 3 final) |
| Android device | Bench-mode runs and the gameplay A/B completed; the last typing and gameplay runs on the final build did not run (see below) |

New tests: `PenTablesTest(s)` (arena and frame equivalence of the native pen setup). New opt-in harness:
`ShellPerfTest(s)`.

## Hardware

- **Tested:** OPPO CPH2669 (Android 14, physical) with the bench build beside the user's app; iOS Simulator
  (iPhone 17, iOS 27.0); the M3 Pro host.
- **Not tested:** physical iPhone (by instruction), Android emulators, tablets, foldables, landscape gameplay on a
  device, older iPhones, energy and thermal behaviour.
- **Interrupted:** after repeated installs of the debug-signed bench build, Google Play Protect showed a
  "send app for a security check" prompt on the phone and further installs waited on it. The device runs were
  stopped; the prompt was later answered "Don't send" by another session sharing the phone, not by this pass. The
  final build's typing measurement on the device was not taken.

## Remaining opportunities

1. Prelude compilation at every boot (B-7): a compiled-prelude snapshot shared by kernels, or further lexer and
   parser work (Swift profile: string creation, hashing and scope lookups).
2. Pure Kotlin functions above ART's huge-method threshold (B-8): verify whether ART leaves them uncompiled, and
   split them in the translator if so.
3. Partial surface uploads: convert and upload only the rows a redraw changed (typing changes a few rows).
4. GrBlot3's source stepping and `Raster.rect` on ART (BomberGolf's remaining kernel time on the phone).
5. `IOSShellEnv.processCpuNs` so the iOS perf line reports process CPU.
6. The release-mode stack overflow in the Swift deep-nesting fuzz probe.
