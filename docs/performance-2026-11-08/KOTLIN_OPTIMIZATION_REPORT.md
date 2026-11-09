# Kotlin (Android) optimization report (2026-11-08)

Baseline `ad9f15a`. Environment and methods: [BASELINE.md](BASELINE.md). Host numbers are thread CPU time on the
Gradle test JVM (with the B-3 flag on both sides), alternating baseline and candidate builds; device numbers are
from the OPPO CPH2669 (Android 14, Snapdragon 662-class SM6115, 3.6 GB), bench build type (R8, profileable).

## Changes kept

### 1. Test JVM compiles the interpreter loop (`82f49c2`, `core/build.gradle.kts`)
- **Bottleneck (B-3):** `Vm.exec` is 8,258 bytes of JVM bytecode, above HotSpot's 8,000-byte limit, so the unit-test
  JVM interpreted it. Host benchmarks of the Kotlin interpreter measured the bytecode interpreter, not the JIT.
- **Change:** `jvmArgs("-XX:-DontCompileHugeMethods")` for `:core` tests (`:purekotlin` already passed it). No app code.
- **Result (host `PerfTest`, 6 s each):** BattleLines 7.0 -> 30.0 fps (17.4 -> 72.2 M instr/s), Varoom 4.6 -> 27.7 fps,
  Squirt 6.6 -> 29.5 fps; warm kernel boot about 0.8 s -> 0.13-0.15 s. Full `:core:test` 4 min 40 s (the previous
  session measured about 27 min, on a busier machine).
- On Android, ART's limit is 10,000 dex code units and `exec` is 5,456 (`dexdump` of the bench APK): unaffected.

### 2. Upload the desktop surface only when a redraw changes it (`624e837`, `Surface.kt`, `Shell.kt`)
- **Bottleneck (B-2):** 29-30 surface conversions and uploads per second while a program ran.
- **Change:** `Surface.commit()` replaces `touch()` at the end of `Shell.render`: the version advances only when the
  pixels, text runs or occluders differ from the last committed frame, after a resize, or when the system chrome
  changes. `TextRun` and `Occluder` became data classes (value equality). Memory: one surface-sized copy (about
  288 KB at 360x800 logical px).
- **Invariants:** same pixels and text on screen; every redraw still runs (program menus, sprite links, accessibility
  nodes, the clock are read as before); the platform still receives every changed frame.
- **Host:** surface uploads 29.3-30.0/s -> 0.07-0.13/s (BomberGolf, Varoom).
- **Device (BomberGolf, portrait, 3 alternating runs of 25 s):** whole-app CPU median 127% -> 120% of one core;
  UI frame time p50 12-13 -> 10-11 ms, p95 15-16 -> 13-14 ms, p99 17-19 -> 14-15 ms; janky frames 15-36 -> 0-3 of
  about 790; game 30 fps on both; PSS 70-76 MB on both.

### 3. Native pen tables at kernel boot (`3da0048`, `Kernel.kt`)
- **Bottleneck (B-1):** 88% of `Kernel.boot` (JFR).
- **Change:** `setUpPens()` does GrSetUpPens' work on the host: the same `MAlloc` and `DCNew` calls in the same order
  (`DCNew` still runs as HolyC), `GrPlot0`'s native routine for the pixels, the same circle and bit tables. Used on
  both engines, so Pure Terry and Pure Kotlin keep the same budget ticks. The HolyC function stays in the prelude.
- **Verification:** `PenTablesTest`: the whole arena is byte-identical to a boot that runs the HolyC function, except the
  dead space above the boot task's memory-stack pointer (stack garbage left by the last calls); a program drawing
  with all 64 pen widths draws the same frame. `:core:test` 416 tests and `:purekotlin:test` 70 tests (engine parity)
  pass.
- **Host:** boot 116-119 -> 26-33 ms. **Device (bench mode, boot plus program compile, 4 runs each):** BomberGolf
  median 937 -> 456 ms, Varoom 351 -> 176 ms (wide spread: first runs after process start include ART JIT warm-up).

### 4. Overlay folder's canonical path resolved once (`70085e2`, `LayeredFs.kt`)
- Whole-drive sweeps (56 directories, 645 files): `stat` 47.3-47.8 -> 41.7-42.0 ms, `list` 8.7-8.9 -> 7.5-7.7 ms,
  `readFile` 64-66 -> 58-59 ms. The per-path containment check is unchanged.

### 5. Glyphs inside the clip drawn without per-pixel clip tests (`c39429c`, `Surface.kt`)
- **Bottleneck (B-4):** 78% of a terminal redraw.
- **Host (with the earlier commits):** terminal keystroke 194-307 -> 109-116 µs, editor keystroke 177-184 ->
  120-135 µs, editor redraw 183-201 -> 122-129 µs, landscape redraw with four windows 184-208 -> 151-163 µs.

### 6. GrBlot3 fast path (`b9d1e43`, `Raster.kt`)
- **Bottleneck (B-5):** `blot3Steps` 41% (inclusive) of BomberGolf's process CPU on the OPPO (simpleperf).
- **Change:** when the target DC records neither extents nor the nearest point, may draw, and the colour cannot dither,
  the depth test and the pixel are written in the loop with `plot0`'s rules; `dc->color` / `dc->db_z` are stored when
  they change (same final values). `RasterDiffTest.blot3` (500 random cases against the original HolyC) passes.
- **Device (bench mode, 6 s deterministic scenario, 8 runs each):** BomberGolf composition 4,695-4,763 ->
  4,456-4,512 ms (-5%), RawHide 6,618-6,682 -> 6,511-6,595 ms (-2%), CastleFrankenstein unchanged.

## Attempted and not kept
- **Byte-matching punctuators in the lexer** (`Lexer.punct`): host JVM boot 20.2-26.8 -> 19.8-21.7 ms, within noise
  (HotSpot removes the temporary strings); reverted. See the Swift report for the Swift measurement.

## Remaining (Kotlin)
- B-8: Pure Kotlin functions above ART's compile threshold (translator change).
- B-7: prelude compilation at every boot (a compiled-prelude snapshot is the known large win; not attempted).
- B-9: byte-wise `loadScreen` / `composeAndPublish` (Swift already uses `memcpy`); no device case measured.
- Partial surface uploads (only the changed rows) during typing: not attempted.
