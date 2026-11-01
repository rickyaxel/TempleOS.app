# Architecture

TempleOS.app (README, "Names"; working name TempleOS Mobile Classic) recreates the TempleOS user environment as two
independent native apps:

- **Android**: Kotlin, `temple_os_kotlin/` (`core` JVM library + `app` Android module).
- **iOS**: Swift, `temple_os_swift/` (`TempleCore` Swift package + `App` Xcode project).

Neither app emulates a PC, boots the TempleOS kernel, embeds a WebView, or
ships a JavaScript/WebAssembly runtime. Instead, each contains its own
implementation of a HolyC compiler and bytecode virtual machine plus the
TempleOS services that HolyC programs call. The original TempleOS V5.03
graphics, sprite, menu, control and math libraries are *HolyC source* taken
unmodified from the official ISO (six files have offensive content
censored or redacted, see content-moderation/CONTENT_MODERATION.md) and run on that VM, so programs see the same
library code they saw on TempleOS.

The Swift package is a line-for-line port of the Kotlin `core` module
(conventions in `temple_os_swift/PORTING.md`); both read the same shared,
platform-neutral content from `shared/` and pass the same test vectors.

## 1. Layers

```text
┌───────────────────────────────────────────────────────────────────────────┐
│ Platform shell (per app)                                                  │
│  Android: MainActivity + TempleView (Canvas, MotionEvent, IME, AudioTrack)│
│  iOS:     TempleViewController + TempleView (CALayer, UITouch, UIKeyInput,│
│           AVAudioEngine)                                                  │
├───────────────────────────────────────────────────────────────────────────┤
│ ui/  TempleOS Mobile desktop (identical logic on both platforms)          │
│  Shell: window manager, top bar, start menu, gestures, keyboard row,      │
│         dialogs, session save/restore                                     │
│  Apps: Terminal, HolyC Editor, Files, Doc viewer, Program host, God Words,│
│        Paint, Settings, About                                             │
│  Surface: indexed (16-colour) framebuffer drawn with the TempleOS 8x8 font│
├───────────────────────────────────────────────────────────────────────────┤
│ kernel/  one Kernel per program window / terminal                         │
│  Kernel: cooperative tasks, virtual/real time, frames at WINMGR_FPS,      │
│          input messages, popups, menus                                    │
│  Natives (171 host functions), Gfx + Raster (screen, palette, native fast │
│  paths), Console (DolDoc text document), VirtualFs/LayeredFs (C: drive)   │
├───────────────────────────────────────────────────────────────────────────┤
│ holyc/  compiler + VM                                                     │
│  Lexer (DolDoc-aware, #define/#include/#exe) → Parser (HolyC precedence,  │
│  chained comparisons, classes/unions, varargs, default args, try/catch)   │
│  → CodeGen (stack bytecode) → Quicken (superinstructions) → Vm            │
│  Arena: isolated byte-addressed memory with MAlloc/Free                   │
├───────────────────────────────────────────────────────────────────────────┤
│ shared/runtime  (HolyC, loaded at every kernel boot)                      │
│  KernelClasses.HC  CTask, CDC, CMenu, CCtrl, CMathODE ... (generated)     │
│  PreludeDefines.HC #defines from KernelA.HH + Gr.HH (generated)           │
│  GrLib.HC          original Adam/Gr, Menu, Ctrls, AMath, AMathODE, ASnd   │
│                    files (generated; hot routines renamed *_HC and backed │
│                    by natives)                                            │
│  Prelude.HC        glue written for this project (PopUp*, settings, ...)  │
│  font8x8.bin       TempleOS system font extracted from the ISO            │
└───────────────────────────────────────────────────────────────────────────┘
```

## 2. Program lifecycle

1. The user taps a program (start menu, Games/Demos/Examples lists, Files,
   a DolDoc link, or **RUN** in the editor). `Launch.program` opens a
   `ProgramApp` window.
2. `ProgramApp` creates a `Kernel` and a `KernelRunner` thread. The runner
   boots the kernel: it compiles `KernelClasses.HC`, `PreludeDefines.HC`,
   `GrLib.HC` and `Prelude.HC` into a fresh `Program`, then compiles and runs
   the program source read from the virtual filesystem. Top-level code is
   compiled and executed chunk by chunk, as TempleOS's JIT does.
3. The runner calls `Kernel.step(~12 ms)` in a loop. Inside, tasks run until
   they block (`Sleep`, `Refresh`, `GetKey`...), the slice ends, or the VM's
   branch budget triggers a reschedule.
4. Once per `WINMGR_FPS` (30000/1001 Hz, as in TempleOS) the kernel composes
   the frame: TempleOS's `DrawIt` callbacks run, the window's text layer and
   graphics layer are merged, and the result is published (640×480 indexed
   pixels + 16-entry palette) under a lock.
5. The UI thread polls `publishedVersion` each display frame and draws the
   frame scaled into the window (overlay), so rendering never waits on HolyC.
6. Input from touch, the on-screen game controls, the soft keyboard and
   hardware keys is translated to TempleOS scan codes and mouse messages and
   posted to the kernel's queue.
7. Stop → `Break`; closing the window terminates the kernel thread; going to
   the background pauses all runners.

Each program has its own kernel, arena and tasks, so a crash or runaway loop
in one program cannot affect another or the desktop.

## 3. Compiler and VM

- **Bytecode**: stack machine with ~110 opcodes, fixed-width int operands
  (`Op.kt` / `Op.swift`, numbers shared by both platforms).
- **Quickening**: after each function is compiled, frequent instruction
  sequences (local-pointer field loads, indexed loads, compare-and-branch,
  immediate arithmetic) get a fused opcode written over their first opcode
  word only. Original instructions stay in place, so jump targets remain
  valid and no relocation is needed.
- **Values**: every HolyC value is a 64-bit word; `F64` is stored as raw bits.
- **Memory**: the arena is a private byte address space (guard page below
  `0x10000`, growth up to a per-program cap). Globals, strings, heap
  allocations and task frame stacks all live there, so HolyC pointer
  arithmetic behaves as on TempleOS while never reaching host memory.
- **Exceptions**: `try`/`catch`/`throw` with TempleOS exception codes;
  runtime faults (`BadMem`, `DivZero`, `StkOver`, `OutMem`, `BadFree`) are
  ordinary HolyC exceptions.
- **Natives**: registered by name; the prelude declares them with the
  `native` keyword using TempleOS's real signatures.
- **Native fast paths**: `GrPlot`, `GrRect`, `GrBlot`, `GrFillTri0`,
  `GrLineFat3`, `GrFillCircle`, `Line` and others are implemented natively
  for speed; the original HolyC versions remain compiled as `*_HC` and a
  differential test (`RasterDiffTest`) checks pixel-exact equality on random
  inputs.

### Execution engines (Settings › Engine)

The VM above is **Pure Terry**, the default. Bundled programs can also run as **Pure Kotlin**
(Android) or **Pure Swift** (iOS): HolyC translated ahead of time, at build time, by
`temple_os_kotlin/translator` (which reuses this compiler front end) into Kotlin
(`temple_os_kotlin/purekotlin`) and Swift (`TempleCore/Sources/PureSwift`) that is compiled into the
app. A native kernel installs `NativeRuntime` as `Vm.engine`: the VM refuses to execute and the
compiler refuses to compile in it. Everything else (scheduler, natives, Gfx, sound, files, input,
the prelude's data layout) is shared, so both engines see the same TempleOS services. User HolyC
and edited bundled files always run on Pure Terry. Details, results and findings:
native-translation/README.md, REPORT.md.

## 4. Desktop shell

- **Surface**: the desktop is drawn into an indexed framebuffer in *logical
  pixels*; the platform scales it by an integer factor (nearest neighbour)
  so the TempleOS font stays crisp. Program frames (640×480) are drawn by the
  platform on top as overlays, scaled to fit the window.
- **Portrait**: one window at a time ("deck"), with tabs in the top bar,
  a TempleOS-style key row (ESC, TAB, CTRL, ALT, arrows, HOME, END,
  keyboard) and on-screen game controls under the program frame.
- **Landscape**: overlapping, movable, resizable TempleOS windows with
  double-line borders; maximize and tile.
- **Session**: window list, positions, editor drafts and cursors, terminal
  history and settings are saved whenever windows change and when the app
  goes to the background; programs restart from source on restore.

## 5. Virtual filesystem

`LayeredFs` = bundled read-only layer (APK assets / app bundle, indexed by
`shared/bundled-fs.index`) + writable overlay in app-private storage, with
copy-on-write, whiteouts for deleted originals, atomic writes, a quota and
strict path normalization. See `security-model.md` §4.

## 6. Shared content and tools

| Path | Produced by |
|---|---|
| `shared/bundled-fs/`, `shared/bundled-fs.index` | `tools/resource-packaging/build_bundled_fs.py` from the ISO extraction plus `shared/home-src` |
| `shared/runtime/GrLib.HC` | `tools/resource-packaging/build_runtime_lib.py` |
| `shared/runtime/KernelClasses.HC` | `tools/resource-packaging/build_kernel_classes.py` |
| `shared/runtime/PreludeDefines.HC` | `tools/resource-packaging/build_prelude_defines.py` |
| `shared/runtime/font8x8.bin` | `tools/asset-extraction/extract_font.py` |
| `shared/program-manifests/catalog.json` | `tools/resource-packaging/build_catalog.py` |
| `reference/templeos-iso/` (gitignored) | `tools/asset-extraction/extract_templeos_iso.py` from the official ISO |

These tools are development-time Python; nothing Python ships in the apps.

## 7. Cross-platform parity

- One functional specification: `shared/specifications/holyc-runtime-spec.md`.
- Same test vectors (`shared/test-vectors/holyc`) run by both test suites.
- Same opcode numbering, memory layout, frame timing and random-number
  generator, so a program run for N virtual seconds with the same input
  produces the same frame; `tools/parity/compare_frames.py` compares the
  Kotlin and Swift sweeps pixel by pixel.
