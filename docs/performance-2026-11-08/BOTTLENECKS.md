# Bottlenecks found (performance pass, 2026-11-08)

Ranked by effect on real use: how often the work runs, whether it runs on the UI thread or delays something
the user waits for, and how much of it was redundant. Evidence and commands: [BASELINE.md](BASELINE.md).
Outcomes: [OVERNIGHT_FINAL_SUMMARY.md](OVERNIGHT_FINAL_SUMMARY.md).

| # | Bottleneck | Platform | Where | Evidence | Outcome |
|---|---|---|---|---|---|
| B-1 | Every program and terminal start ran the prelude's `GrSetUpPens` in the interpreter: 64 pen widths x 4 brush DCs plus circle and bit tables, about 350,000 HolyC loop iterations, on each kernel boot | both | `Kernel.initGlobals` (`Kernel.kt`, `Kernel.swift`) | JFR: 88% of `Kernel.boot` on the JVM; Swift boot 75 ms | Fixed (`3da0048`) |
| B-2 | While a program ran, each new program frame marked its window dirty, the shell redrew, and the surface version advanced 30 times a second, so both platforms converted and re-uploaded the whole desktop surface (iOS also redrew every system-font text run) although the program picture is a separate overlay | both | `Shell.render`, `Surface.touch`, `TempleView` | Harness: 29-30 surface uploads/s during play; OPPO: 15-36 janky UI frames per 25 s of BomberGolf | Fixed (`624e837`) |
| B-3 | The host JVM never compiled the interpreter loop: `Vm.exec` is 8,258 bytes of bytecode, above HotSpot's 8,000-byte limit | Kotlin tests only (ART has no such limit; `exec` is 5,456 dex units there) | `core/build.gradle.kts` | Host BattleLines 7 fps and 17 M instr/s; boot 0.8 s | Fixed for tests (`82f49c2`) |
| B-4 | `Surface.glyph` tested every pixel of every 8x8 glyph against the clip and visited every pixel of a transparent glyph's empty rows | both | `Surface.kt`, `Surface.swift` | JFR: 78% of a terminal redraw | Fixed (`c39429c`) |
| B-5 | GrBlot3 made about 14 arena accesses and three calls per drawn pixel (color store, depth-buffer pointer, `plot0` re-reading the DC) | both | `Raster.blot3Steps` | simpleperf on the OPPO: `blot3Steps` 41% (inclusive) of BomberGolf's process CPU | Improved (`b9d1e43`); the stepping and source reads remain |
| B-6 | Each overlay-filesystem lookup resolved the overlay folder's canonical path again (a `realpath` per call) | both | `LayeredFs.hostFile` | Whole-drive `stat` sweep 47-49 ms | Fixed (`70085e2`) |
| B-7 | Prelude compilation after B-1: lexing and parsing ~200 KB of HolyC per boot | both | `Lexer`, `Parser`, `CodeGen` | Kotlin JFR: 82% of the remaining boot; Swift `sample`: `Lexer.punct` about 16% of boot (candidate strings hashed into a set) | Swift: punctuators matched on bytes (`9e29aac`, boot -9.5%); Kotlin unchanged (no JVM gain); the rest open |
| B-8 | Pure Kotlin: 14 generated functions are above ART's default 10,000-dex-unit "huge method" compile threshold (`Prelude.dispatch` 16,354; `GrFillTri0` 27,938; X-Caliber, Castle Frankenstein and To The Front `DrawIt`; KeepAway `AnimateTask`; Psalmody) | Kotlin, native engine only | `temple_os_kotlin/purekotlin/gen` (translator output) | `dexdump` of the bench APK. Not confirmed that ART leaves them interpreted: a 10 s simpleperf of Pure Kotlin X-Caliber showed no interpreter symbol above 2% | Open: verify per program; a fix belongs in the translator (split functions); not changed |
| B-9 | Per-frame composition in Kotlin: `loadScreen` packs 307,200 bytes into arena words one byte at a time; `composeAndPublish` unpacks them per byte (Swift already uses `memcpy` and 8-byte loads) | Kotlin | `Gfx.kt` | Host JFR 1-2%; under the 1.5% report threshold on the OPPO | Not changed (no measured case) |
| B-10 | Overlay lookups for files that only exist in the bundle still list the overlay folder (`listFiles`) for the case-insensitive walk | both | `LayeredFs.overlayFind` | After B-6, a `stat` still costs about 65 µs on the host | Not changed: a correct cache needs invalidation on every overlay mutation; few calls per user action |
| B-11 | An unchanged redraw now pays one comparison of the surface (about 288 KB at 360x800 logical px) | both | `Surface.commit` (introduced by B-2) | Empty-desktop redraw +3 to +10 µs | Accepted: it saves the platform's conversion and upload of the same frame |

## Where time goes after the changes (device and host profiles)

- **BomberGolf on the OPPO** (simpleperf, 12 s): the kernel thread's raster routines (`blot3Steps`, `rect`,
  `plot0`) and `Kernel.compose` dominate; the interpreter's own loop (`Vm.exec`) is about 2% self. The UI
  thread (`doFrame`, `onDraw`) and RenderThread together are about 20%.
- **Program start**: compiling the prelude (B-7).
- **Typing** (terminal, editor): glyph drawing and the console view's layout; each key redraws the window.
