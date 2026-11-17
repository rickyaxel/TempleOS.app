# Performance

> **Performance pass (2026-11-17): Varoom and the graphics library.**
> - **Varoom on the OPPO CPH2669, in the app** (portrait, accelerator held, 2 x 20 s per build and engine, median of
>   the per-second FPS readout): Pure Terry 4 -> 15 fps, Pure Kotlin 6 -> 26 fps (peaks at 30); UI 60 fps throughout.
>   Frame composition: Pure Terry 243 -> 65 ms, Pure Kotlin 161 -> 38 ms. (Before = `main` at `2c10ed3`, so this
>   includes the 2026-11-08 pass below.)
> - **Headless bench mode on the same phone**, frame composition per frame for 5-6 s of game time, Pure Terry /
>   Pure Kotlin: Varoom 163 -> 64 / 81 -> 34.5 ms, CastleFrankenstein 2.3x / 2.2x faster, KeepAway 2.3x / 2.3x,
>   ZoneOut 2.2x / 2.1x, Titanium 2.0x / 1.8x, BattleLines 1.7x / 1.1x, BomberGolf and RawHide 1.4x / 1.4x.
>   Program boot (Pure Terry) about 570 -> 230 ms.
> - What changed: depth-tested spans checked once per span instead of per pixel, dithered spans draw their random
>   numbers without a clock read per pixel, word-level MemSetU32/I64 (depth-buffer reset) and frame copies (Kotlin),
>   no synchronized lazies or getter chains in the raster code (Kotlin); and GrLine3 (with DCClipLine/ClipLine),
>   GrFillPoly3, Gr3Mesh, Sprite3 and Mat4x4Scale run natively on both platforms (originals kept as `*_HC`).
> - Verification: RasterDiffTest/RasterDiffTests compare every native with its HolyC original on random inputs,
>   including the heap; before the new natives, the catalog parity sweep's checkpoints were byte-identical for
>   every program (except the two that print the date); after, 145 of 149 programs have every checkpoint frame
>   identical (the other four diverge only after their budget ticks do), and Terry/Pure Kotlin parity is unchanged.
>   Commits from `57656b6` to the merge of this pass.
> - **Swift on the M3 Pro host** (release, `BenchmarkTests`, 6 s of game time, 3 runs, wall time including boot), Pure
>   Terry / Pure Swift: Varoom 2.14x / 1.83x faster, Talons 1.78x / 1.19x, Maze 1.52x / 1.08x, BattleLines
>   1.35x / 1.03x, BomberGolf 1.26x / 1.08x; X-Caliber, Squirt and Bounce unchanged. Swift's raster code was
>   already free of the Kotlin-on-ART overheads, so most of its gain is the native library routines. iOS devices
>   were not measured (simulator and host only, as for the earlier passes).

> **Performance pass (2026-11-08), [performance-2026-11-08/](performance-2026-11-08/OVERNIGHT_FINAL_SUMMARY.md).**
> - Program and terminal start: the prelude's pen tables are set up natively; on the OPPO CPH2669 boot plus program
>   load went from about 570 to about 245 ms.
> - A running program no longer makes the desktop surface re-upload 30 times a second (`Surface.commit`); on the
>   OPPO, BomberGolf's janky UI frames dropped from 15-36 to 0-3 per 25 s.
> - Typing and window redraws 15-44% cheaper (glyph drawing), a GrBlot3 fast path, a lexer change (Swift).
> - New opt-in harness `ShellPerfTest` / `ShellPerfTests`; the Kotlin test JVM now compiles the interpreter loop.

> **Native engines (2026-10-20), `docs/native-translation/REPORT.md` §F.**
> Bundled programs can run as ahead-of-time translated Kotlin/Swift (Settings › Engine). Same program,
> same input, alternating runs: on the OPPO CPH2669, Squirt 14→30 fps, PredatorPrey 5→30 fps,
> BattleLines 11→22 fps, Varoom 6→11 fps, flat-out programs 2.8–13× more HolyC work per second, and
> 5× faster program start; BomberGolf is break-even on the simulator and slightly slower on the
> phone (thread switches). Host: 1.13–12× (Swift release), 1.30–29× (JVM).

> **Performance pass (2026-10-17), `docs/performance/`.**
> - The BomberGolf lag came from TempleOS's sound-effect `Yield` spin reaching the platform at about
>   200,000 speaker changes per second. iOS also queued one main-thread block per change.
> - Other fixes: frame fairness, six native library routines, and a duplicate Android frame callback.
> - Catalog on the host JVM: 62 programs improved and 7 unchanged. Repeated runs found none slower.
> - Measurements are in TEMPLEOS_PERFORMANCE_BENCHMARKS.md.

> **Verification pass (2026-10-16), `docs/verification-pass/PERFORMANCE_VERIFICATION.md`.** Two fixes change the numbers below:
> - The idle desktop redrew at display rate whenever a Terminal was open or a program was booting (V-13). Measured on the 1-vCPU emulator: 61% CPU, and 22 s program boot.
> - Unchanged frames were re-uploaded 30 times a second (V-10).
>
> After the fixes:
> - Android emulator: idle 0.3% CPU, 0 frames rendered while static, 35.8 MB PSS; cold start 233–261 ms.
> - iOS simulator: idle footprint 18 MB.
>
> No physical device was available.


All numbers below were measured in this repository's development environment
on 2026-10-16. **No physical phone was measured**: the attached Android phone
(OPPO CPH2669, Android 14) was locked during testing, and no iPhone was
attached. Emulator and simulator numbers run on a laptop CPU and are not a
substitute for device measurements; treat them as relative indicators.

Host: Apple M3 Pro, 18 GB RAM, macOS 27, Xcode 27.1, JDK 21.

## 1. Targets (from the specification) and status

| Target | Status |
|---|---|
| Original games at TempleOS's frame rate | Met on the Android emulator and iOS simulator for BattleLines and Varoom (29.97 FPS = TempleOS `WINMGR_FPS`). Not yet measured on devices. |
| Responsive UI while programs run | Programs run on their own threads; the UI thread only copies finished frames. |
| No CPU use by hidden programs | Programs pause while their window is hidden (portrait) or the app is in the background; measured 0 % CPU for a hidden BattleLines. |
| Small download | Android release APK 10.4 MB; iOS simulator app bundle 17 MB (device size not measured). |

## 2. Android emulator (sdk_gphone64_arm64, Android 16, release APK)

| Metric | Value | How |
|---|---|---|
| APK size | 10,383,556 bytes | `app-release.apk` (R8, resources shrunk; 9.7 MB of it is the bundled TempleOS drive) |
| Cold start, first launch after install/clear | 708 ms (836 ms in airplane mode) | `am start -W` TotalTime |
| Cold start, later launches | 416–600 ms | same, process killed between runs |
| Cold start restoring two program windows | 1,107–1,214 ms | same, programs restart from source |
| Idle desktop memory | 32.5 MB PSS | `dumpsys meminfo`, Welcome document open |
| Program boot (compile prelude + graphics library + program) | 1,142 ms first program, 567 ms next | app log line `TempleOSMobile boot` |
| BattleLines | 29–30 FPS steady; HolyC thread 40–44 % of one core; 50 MB PSS | FPS readout (window menu → Show frame rate), `top -H`, `dumpsys meminfo` |
| Varoom (BattleLines hidden and paused) | 29–31 FPS; 74–85 % of one core | same |
| Varoom with BattleLines also running (before hidden-program pausing) | 12–15 FPS | same; motivated the pausing change |
| Two programs open | 70.7 MB PSS | `dumpsys meminfo` |

## 3. iOS simulator (iPhone 17, iOS 26.1, Release configuration)

| Metric | Value | How |
|---|---|---|
| BattleLines | 30 FPS | FPS readout captured by the XCUITest `testFrameRates` |
| Varoom (BattleLines hidden) | 30 FPS | same |
| Memory after relaunch with a restored session | 53 MB footprint (peak 62 MB) | `footprint <pid>` on the simulator process |
| App bundle | 17 MB | simulator build (`du -sh`) |

## 4. Interpreter throughput (host CPU)

3 s of virtual game time each (fixed work, deterministic input); wall time on
the M3 Pro:

| Game | Instructions | Swift release (`swift test -c release`) | Kotlin on the JVM (unit-test JVM, includes JIT warm-up) |
|---|---|---|---|
| BattleLines | 223 M | 0.62 s | 1.93 s |
| RawHide | 278 M | 0.72 s | 2.35 s |
| Varoom | 358 M | 1.29 s | 3.32 s |
| Squirt | 525–534 M | 1.13 s | 4.16 s |

So the Swift interpreter runs roughly 280–470 M bytecode instructions per
second on this host. Phones are slower; the Android emulator (also on this
host, ART JIT) sustains BattleLines and Varoom at full frame rate.

## 5. Optimizations in place

| Optimization | Effect (measured) |
|---|---|
| In-place superinstructions ("quickening", `Quicken.kt`/`.swift`) | instructions per 3 s: BattleLines 338 M → 230 M, Squirt 783 M → 534 M, Varoom 482 M → 355 M |
| Native `Line()` with HolyC callbacks | BattleLines 578 M → 338 M instructions |
| Native raster primitives, `SpriteSize`, flood fill | Titanium's `SpriteSize` hot spot (92 % of samples) removed |
| Pausing hidden/background programs | Varoom 12–15 → 30 FPS when another program was open |
| UI rendering: integer-scaled indexed framebuffer, program frames uploaded only when changed; idle UI polls at 10 Hz | — |

## 6. Known bottlenecks

- Program start compiles the system prelude and graphics library (≈ 200 KB of
  HolyC) for every program: 0.5–1.1 s on the emulator. A compiled-prelude
  snapshot would remove most of it (not implemented).
- Heavy physics and 3D (Squirt, Varoom, PredatorPrey) are the most
  CPU-intensive; PredatorPrey is very slow.
- Kotlin's interpreter loop must stay under HotSpot's 8000-byte JIT limit
  (`exec` is 7921 bytes); ART has no such limit (4504 dex code units).
- Physical-device numbers are missing (see top).

## 7. How to reproduce

- Android: install the release APK, then `adb shell am start -W -n com.digitalcircuitstudios.templeosapp/io.github.templeosmobile.android.MainActivity`;
  open a game, window menu → **Show frame rate**; `adb logcat | grep TempleOSMobile`
  prints boot times and FPS once per second.
- iOS: `xcodebuild ... -configuration Release -only-testing:TempleOSMobileUITests/TempleOSMobileUITests/testFrameRates test`
  with `TEST_RUNNER_TEMPLEOS_SHOTS=<dir>` to keep the screenshots.
- Interpreter throughput: the sweep commands in `testing.md`.
