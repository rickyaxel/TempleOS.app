# Swift (iOS) optimization report (2026-11-08)

Baseline `ad9f15a`. Environment and methods: [BASELINE.md](BASELINE.md). Host numbers are thread CPU time of
`swift test -c release -Xswiftc -enable-testing` on the M3 Pro, alternating baseline and candidate builds. iOS
numbers are from the iOS Simulator only (iPhone 17, iOS 27.0, Release); no physical iPhone was used.

The Swift package is a line-for-line port of the Kotlin core, so the same bottlenecks applied; each change below
is the port of the Kotlin change with the same commit.

## Changes kept

### 1. Upload the desktop surface only when a redraw changes it (`624e837`, `Surface.swift`, `Shell.swift`)
- **Bottleneck (B-2):** while a program ran, `TempleView.render` converted the whole surface to RGBA, made a new
  `CGImage` (copying the pixels), replaced `layer.contents` and redrew the text layer (Core Text) 30 times a second.
- **Change:** `Surface.commit()`; `TextRun` and `Occluder` are `Equatable`. `TempleView` is unchanged: it already
  skipped all of that work when `s.version` did not change.
- **Host:** surface uploads 29.6-30.0/s -> 0.07-0.13/s; UI-thread CPU (shell ticks plus the RGBA conversion the
  harness does in place of `TempleView`) Varoom 11.4-12.1 -> 8.5-9.3 ms/s. The harness does not include the
  `CGImage`, Core Animation upload or text-layer drawing, which are also skipped.
- **iOS Simulator (BomberGolf, portrait, `testPerfProgram` 30 s, 3 alternating runs):** app process CPU 24.5-26.7%
  -> 20.1-24.0% of one host core (median 25.8 -> 23.4); game 30 fps and UI 60 fps with no stalls on both; the final
  screenshots of both builds show the same window, controls and labels.

### 2. Native pen tables at kernel boot (`3da0048`, `Kernel.swift`)
- **Host:** `Kernel.boot` 75 -> 42 ms. `PenTablesTests` (arena and frame equivalence) and `PureSwiftTests` (engine
  parity) pass.

### 3. Overlay folder's canonical path resolved once (`70085e2`, `LayeredFs.swift`)
- Whole-drive sweeps: `stat` 48.2-48.7 -> 39.7-41.0 ms, `list` 8.8 -> 7.3 ms, `readFile` 63.1-63.5 -> 54.2-55.2 ms.

### 4. Glyphs inside the clip drawn without per-pixel clip tests (`c39429c`, `Surface.swift`)
- **Host (with the earlier commits):** terminal keystroke 300-315 -> 172-174 µs, editor keystroke 204-214 ->
  144-149 µs, editor redraw 197-209 -> 137-140 µs, window open and close 741-792 -> 670-679 µs, landscape redraw
  with four windows 324-385 -> 272-279 µs, focus change 264-306 -> 221-233 µs, window drag 331-390 -> 278-288 µs.

### 5. GrBlot3 fast path (`b9d1e43`, `Raster.swift`)
- **Host `PerfTests` (8 s, 3 alternating runs):** BomberGolf compose p50 1.19-1.25 -> 1.14-1.15 ms, p95 1.39-1.46 ->
  1.32-1.33 ms, kernel thread CPU 4.1-4.3% -> 3.9%; RawHide compose p50 1.55-1.60 -> 1.50-1.55 ms.
  `RasterDiffTests.testBlot3` passes.

### 6. HolyC punctuators matched on bytes (`9e29aac`, `Lexer.swift`, Swift only)
- **Bottleneck (B-7):** a `sample` profile of repeated boots put `Lexer.punct` at about 16% of `Kernel.boot`: up to
  three candidate `String`s per punctuation token, each hashed into a `Set`.
- **Change:** the source bytes are compared with the punctuators grouped by length; same longest match, same token text.
- **Host (quiet machine, 40 samples x 4 alternating runs):** `Kernel.boot` 41.2-42.6 -> 37.2-38.2 ms. The compiler-facing
  suites pass in debug (87 tests). The Kotlin lexer was not changed: the same change measured within noise on the JVM.

## Remaining (Swift)
- B-7: prelude compilation (`sample`: string creation, hashing and comparison in the lexer and the parser's scope
  lookups are the largest items).
- `IOSShellEnv` does not implement `processCpuNs`, so the iOS perf line reports `cpu_pct=-1`; process CPU was read
  from the host for the simulator runs.
- `TempleView.render` copies the RGBA buffer into a new `Data` for every changed frame (`makeImage`); a reused
  backing store would avoid the copy but must not be modified while Core Animation still reads it.
