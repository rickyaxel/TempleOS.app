# TempleOS.app — Android (Kotlin)

Native Android app. No WebView, no emulator, no JavaScript/WebAssembly, no
network access. HolyC programs run on a sandboxed bytecode interpreter
written in Kotlin.

## Modules

| Module | What it is |
|---|---|
| `core/` | Pure Kotlin/JVM library (no Android dependencies): HolyC lexer/parser/code generator/VM (`holyc/`), TempleOS kernel services, graphics, console and virtual filesystem (`kernel/`), and the TempleOS Mobile desktop shell and apps drawn into an indexed framebuffer (`ui/`). Unit-tested on the JVM. |
| `app/` | The Android app: one `Activity` and one custom `View` (`TempleView`) that scales the shell's framebuffer, draws program frames, and turns touch / IME / hardware keys into shell events; an `AudioTrack` square-wave generator; asset-backed bundled `C:` drive. Framework-only (no AndroidX). |

Shared, platform-neutral content (HolyC prelude, generated TempleOS graphics
library, font, bundled `C:` drive, program catalog, test vectors) lives in
`../shared/` and is copied into the APK assets by the `syncTempleAssets`
Gradle task at build time.

## Requirements

- JDK 21 (the build uses Gradle's toolchain support; `JAVA_HOME` must point at a JDK 21)
- Android SDK with platform 36 and build-tools 36.x (`local.properties`: `sdk.dir=...`)
- Gradle wrapper 8.13 (included), Android Gradle Plugin 8.12.3, Kotlin 2.2.10

## Build and test

```sh
cd temple_os_kotlin
./gradlew :core:test            # HolyC vectors, raster differential tests, filesystem, headless UI
./gradlew :app:assembleDebug    # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease  # minified; signed with the debug key unless you configure signing
```

Signed store bundles need the owner's upload key, which never enters the repository:
[`docs/releasing.md`](../docs/releasing.md).

Optional, informational test runs (need the extracted ISO in `../reference/templeos-iso`):

```sh
./gradlew :core:test --tests '*SweepTest*' -Dtempleos.sweep=Games        # run every original game for 3 s of virtual time
./gradlew :core:test --tests '*SweepTest*' -Dtempleos.sweep=Games -Dtempleos.only=BattleLines -Dtempleos.profile=true
```

The sweep writes final frames to `core/build/frames/<Dir>/` (`.png` and raw
`.idx`); `tools/parity/compare_frames.py` compares them with the Swift sweep.

## App facts

- `applicationId` `com.digitalcircuitstudios.templeosapp` (the Google Play package name), `minSdk` 24, `targetSdk` 36.
- Permissions: none.
- Exported components: the launcher activity only.
- Backup and device transfer disabled.
- Orientation: follows the device (portrait deck layout / landscape windows).

## Layout of the source

```
core/src/main/kotlin/io/github/templeosmobile/core/
  holyc/   Source, Lexer, Parser, Types, Ast, CodeGen, Op, Quicken, Program, Vm, Arena, Format
  kernel/  Kernel, Natives, NativesSys, Gfx, Raster, Console, Keys, Palette, VirtualFs, LayeredFs, FsCommands
  ui/      Shell, App, Surface, Widgets, Catalog, Json, ProgramHost, ProgramApp, TerminalApp,
           EditorApp, FilesApp, DocViewerApp, GodApp, SmallApps (Paint, Settings, About, Launch)
app/src/main/kotlin/io/github/templeosmobile/android/
  MainActivity, TempleView, AndroidShellEnv (assets, session file, tone generator)
```

See `../docs/architecture.md` for how the pieces fit together.
