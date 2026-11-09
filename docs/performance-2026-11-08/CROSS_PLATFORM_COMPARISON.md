# Cross-platform comparison (performance pass, 2026-11-08)

Each platform is compared only with its own baseline. The Android numbers come from a physical low-end phone,
the iOS numbers from the iOS Simulator on the development Mac, and the host numbers from the same Mac running the
Kotlin core on the JVM and the Swift core natively. These are different machines and runtimes; nothing here says
one platform is faster than the other.

## Improved on both platforms (same change, ported line for line)

| Change | Kotlin evidence | Swift evidence |
|---|---|---|
| Surface uploaded only when a redraw changes it | OPPO: app CPU 127% -> 120%, UI p99 17-19 -> 14-15 ms, janky frames 15-36 -> 0-3 per 25 s | Simulator: app CPU median 25.8% -> 23.4%; host: uploads 30/s -> 0.1/s |
| Native pen tables at boot | Host boot 116-119 -> 26-33 ms; OPPO boot+compile median 937 -> 456 ms (BomberGolf) | Host boot 75 -> 42 ms |
| Canonical overlay path resolved once | Host `stat` sweep -12% | Host `stat` sweep -17% |
| Glyph fast path | Host terminal keystroke 194-307 -> 109-116 µs | Host terminal keystroke 300-315 -> 172-174 µs |
| GrBlot3 fast path | OPPO BomberGolf composition -5% | Host BomberGolf compose p50 -5% |

## Platform-specific

- **Kotlin only:** the unit-test JVM's huge-method limit (B-3) is a host-JVM matter; ART compiles the
  interpreter loop. Pure Kotlin has 14 generated functions above ART's compile threshold (B-8); Swift compiles
  everything ahead of time and has no such limit.
- **Swift only:** the per-frame composition copies (`loadScreen`, `composeAndPublish`) already use `memcpy` and
  8-byte loads; the Kotlin versions work byte by byte (B-9, unchanged).
- **Different costs of the same work:** on iOS each surface upload also redrew the Core Text layer, so B-2 saved
  more per frame there than the RGBA conversion alone; on Android the text runs are drawn in every `onDraw` and
  were not affected.

## Behavioural parity checks

- The Kotlin and Swift harnesses (`ShellPerfTest`, `ShellPerfTests`) run the same scenarios.
- `PenTablesTest(s)` on both platforms: identical arena after boot and identical frames for all pen widths.
- `RasterDiffTest(s)` on both platforms: the native raster routines, including GrBlot3, against the original HolyC.
- Pure Terry versus Pure Kotlin parity (`:purekotlin:test`, 70 tests) and Pure Swift (`PureSwiftTests`, 43 tests) pass.
- The shared scenario suites (`ScenarioTest(s)`) pass on both.

## Device coverage

| Platform | Physical | Virtual |
|---|---|---|
| Android | OPPO CPH2669, Android 14, Snapdragon 662-class, 3.6 GB RAM (bench build beside the user's app) | none used (another project's emulator was running; it was not touched) |
| iOS | none (a paired iPhone was present; by the owner's instruction it was not used) | iPhone 17 simulator, iOS 27.0, created for this pass |

Not covered: tablets, foldables (Duo), landscape gameplay on devices, Android emulators, older iPhones, battery and
thermal measurements (only CPU time was measured; lower CPU time is not a measured energy saving).
