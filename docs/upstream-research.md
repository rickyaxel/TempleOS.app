# Upstream and reference research

This document records the reference material that was studied while building
TempleOS Mobile Classic, what each reference contains, and what this project
did and did not take from it. Everything here was checked against the
checkouts under `reference/` (gitignored) on 2026-10-16. Where something could
not be verified, the text says so.

## 1. Reference checkouts

All four ParkerrDev repositories and the cia-foundation mirror are **shallow
clones of depth 1** (`git rev-list --count HEAD` = 1), so only the head commit
below is available locally. No history was inspected.

| Directory | Remote (`git remote -v`, fetch) | HEAD commit | Commit date |
|---|---|---|---|
| `reference/templeos-web` | https://github.com/ParkerrDev/TempleOS-Web.git | `937a2db7f6acfa158ec3adb3608ea3bc9e8069d7` | 2026-09-18 09:48:48 -0700 |
| `reference/holyc-wasm` | https://github.com/ParkerrDev/HolyC-wasm.git | `7e7213397c5db64ffba6e4ebbf29cf8aa26b86a8` | 2026-09-18 09:47:35 -0700 |
| `reference/hemu` | https://github.com/ParkerrDev/HEMU.git | `3daa7135a3453a4ac93744a614aa532ac5d7e0bc` | 2026-09-18 09:47:35 -0700 |
| `reference/holyc-fmt` | https://github.com/ParkerrDev/HolyC-fmt.git | `71cf984540628dab121bec05dbca59e53f98b07a` | 2026-09-13 15:29:11 -0700 |
| `reference/original-templeos` | https://github.com/cia-foundation/TempleOS.git | `c26482bb6ad3f80106d28504ec5db3c6a360732c` | 2020-02-24 14:16:30 +0100 |
| `reference/iso/TempleOS.ISO` | not a git repo (official ISO file) | sha256 `5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26` | 17,350,656 bytes |
| `reference/templeos-iso/` | not a git repo: output of `tools/asset-extraction/extract_templeos_iso.py` | `MANIFEST.json` lists 652 files and the ISO sha256 above | n/a |

The cia-foundation head commit message is "Fix corrupted Compiler.BIN, remove
files that were not present in the final snapshot". `Kernel/KGlbls.HC` in the
ISO extraction sets `sys_os_version=5.030`, consistent with TempleOS V5.03.

## 2. License status

Searched for `LICEN*`, `COPYING*` and `UNLICENSE*` files (excluding `.git`)
and for license statements in each README and `package.json`.

| Repository | License file at repo level | README statement | package.json | Conclusion |
|---|---|---|---|---|
| TempleOS-Web | **None** | "Credits & licenses" section states TempleOS is public domain and lists third-party parts (ffmpeg.wasm, TempleOS-tribute font/styling "(MIT)"), but grants **no license for the site's own code** | none present | No license is granted for its code, so none can be reused. Used as a **behaviour reference only**; no code copied (see section 8). |
| HolyC-wasm | **None** | "## License: The compiler and runtime in this directory are MIT-licensed." | `"license": "MIT"` | MIT is claimed but no LICENSE text (copyright line + permission notice) is shipped. Not used as code. |
| HEMU | **None** | No license statement found | no package.json | No license. Not used. |
| HolyC-fmt | **None** | No license statement found | `"license": "MIT"` | MIT claimed only in package.json. Not used. |
| cia-foundation/TempleOS | **None** | `ReadMe.TXT` says "TempleOS is 100% open source with all source present" | n/a | TempleOS's own files declare public domain (see `docs/licensing-and-provenance.md`). Not a source of shipped files; see section 8 and `docs/licensing-and-provenance.md`. |

Vendored inside TempleOS-Web (not the site itself): `games/upstream/TinkerOS/LICENSE`
(begins "This is free and unencumbered software released into the public
domain", i.e. Unlicense text) and `games/upstream/TOOM/freedoom-0.12.1/COPYING.TXT`
(Freedoom copyright notice). Neither directory is used by this project.

## 3. TempleOS-Web (ParkerrDev/TempleOS-Web)

A static web site (README title "TempleOS-wasm"). The README and `games/README.md`
describe **two execution strategies**, both visible in the source tree:

### 3.1 Strategy A: emulate the real TempleOS (HEMU)

"Run in TempleOS" boots the unmodified TempleOS V5.03 kernel inside **HEMU**, an
x86-64 emulator written in HolyC and compiled to WebAssembly by HolyC-wasm. The
browser side lives in `engine/` (documented in `engine/README.md`):

| File | Role (from `engine/README.md` and file headers) |
|---|---|
| `engine/compile.js`, `engine/build.mjs` | compile `../hemu/src` with HolyC-wasm into `hemu.wasm`, `hemu-smp.wasm`, `hemu-smp.json` |
| `engine/host.js` | implements HEMU's `host.HC` contract on top of HolyC-wasm `createHost()`: snapshot, present, disk, palette, input, pacing, JIT hooks |
| `engine/jit.js` | x86-64 to WASM block JIT for hot guest code |
| `engine/guestexec.js`, `engine/guestinput.js` | guest-call API (exec/include/mkdir/writeFile/launch) and keyboard/mouse state injection |
| `engine/qcow2.js` | qcow2/raw disk reader, RedSea and FAT32 listing |
| `engine/hemu-worker.js`, `engine/hemu-smp-worker.js` | single-core worker (shipping path) and experimental SMP workers |

It resumes from a RAM snapshot (`hemu/live.bin.gz`) and reads a disk image
(`vendor/images/templeos-hd.qcow2.gz`). The README credits "HLE" (native
re-implementations) of hot render routines, shadow-verified against emulation.

### 3.2 Strategy B: compile HolyC to WebAssembly with browser host functions

"Run in Browser" and the HolyC Editor compile game sources directly with
HolyC-wasm in a Web Worker; per `games/README.md` they "never create a HEMU
session". `editor/worker.js` runs the module with blocking semantics via
`Atomics.wait`; `editor/app.js` wires input and drains the sound ring into
WebAudio. Per the README only HolyCraft and Snake are native-playable; "the 61
upstream packages still require native compatibility work".

### 3.3 Other subsystems (files as they exist at `937a2db`)

| Area | Files | Notes |
|---|---|---|
| Framebuffer | `framebuffer.js` (25 lines), `tools/framebuffer.test.mjs` | skips palette expansion/canvas upload for byte-identical guest frames |
| Sprite codec | `sprite-codec.js` (129 lines), `tools/sprite-codec.test.mjs` | "TempleOS uncompressed CDC/GR codec. Layout verified against Adam/Gr/GrDC.HC"; credits PNG2GR by greg0-4 as format reference |
| Sprite Studio | `sprite-studio.js`, `sprite-color.js`, `sprite-noise.js`, `sprite-player.js`, `sprite-convert-worker.js`, `sprites.html`, `terry-sprite.js` | image/GIF/video to 16-colour .GR conversion |
| Game library | `game-library.js`, `game-packages.js`, `game-source.js`, `game-view.js`, `game-credits.js`, `games.js`, `games/catalog.json`, `games/AUTHORS.md`, `games/provenance.json`, `games/upstream/` (AustinArchive, MaliciousTestimonies, MarioClone, TerrySupplement, TinkerOS, TOOM) | README: 63 catalog entries; sources pinned by revision and sha256; embedded DolDoc sprite bytes preserved |
| Terminal | no standalone terminal module found | the command line is the real TempleOS running in HEMU; `index.html` build notes describe a resident HolyC daemon posting commands to the foreground terminal |
| God Words | inline in `index.html` (around lines 590 and 1439-1456) | GodBits/GodPick written as an inline HolyC string compiled in-browser by HolyC-wasm; keystroke timing as entropy; `assets/godwords.txt` |
| Sound | `index.html` (`AudioContext` oscillator, `snd(freq)`), `engine/hemu-worker.js` (posts `snd` messages), HolyC-wasm `src/runtime/sound.js` | single square-wave PC-speaker tone |
| Font | `fonts/templeos.ttf`, `fonts/templeos_orig.ttf`, `fonts/dos_vga_new.woff2`, `tools/cleanfont.mjs`; `@font-face` in `index.html` and `sprites.css` | README attributes the TempleOS font to TempleOS-tribute by Alberto del Real (MIT) |
| Other | `transearch.js` (transcript search), `convert.js` (ffmpeg.wasm), `xsel.js` (XOR text selection), `holyfmt.js` (runs HolyC-fmt), `guest-fps.js` | not relevant to this project |

### 3.4 Test and validation material

- `VALIDATION.md` (159 lines, "Validated locally on 2026-09-13"): tables of
  regression/smoke checks (emitter self-test 10/10, guest execution 12/12,
  "Desktop JIT comparison 0 differing pixels out of 307,200", TOOM, Sprite
  Studio, formatter 16/16 + 150/150). It states: "These are regression and smoke
  checks, not complete game playthroughs or full x86 conformance."
- `tools/*.test.mjs` (sprite codec, sprite player, guest FPS, HolyCraft input,
  game capture, native clicks, game view, native project, framebuffer, game
  source, game credits), `tools/redsea.test.py`, `tools/check-text.py`,
  `tools/verify-games.mjs`, `tools/native-games-audit.mjs`.
- `tools/hemu/` emulator harnesses and `tools/snapshot/` QEMU capture recipes.

None of these tests were executed for this document.

## 4. HolyC-wasm (ParkerrDev/HolyC-wasm)

A HolyC to WebAssembly compiler in JavaScript plus a browser runtime. The README
notes the checkout "tracks `src/` only"; its older CLI/test tables describe a
pre-split layout (`cli/`, `tests/`, `npm test`) that is **not present** in this
checkout. Line counts are from `wc -l` (4,441 lines total).

| Stage | File | Lines | Summary (from file headers) |
|---|---|---|---|
| Driver | `src/compiler.js` | 35 | lex, preprocess, parse, codegen; prelude compiled with the program |
| Lexer | `src/lexer.js` | 241 | comments, hex/binary/float/char literals, high-byte identifiers, DolDoc skipping |
| Preprocessor | `src/preprocess.js` | 215 | `#define` (object/function-like), `#include`, `#ifdef/#ifndef/#else/#endif`; ignores `#exe{}`, `#help_index`, `#assert` |
| Parser | `src/parser.js`, `src/ast.js` | 653, 7 | recursive descent + Pratt |
| Type system | `src/types.js`, `src/fold.js` | 127, 56 | non-F64 values as wasm i64, F64 as f64; constant folding |
| Codegen | `src/codegen.js`, `src/abi.js` | 1533, 85 | AST to WASM module; shadow stack, bump heap; host import ABI |
| WASM encoder | `src/wasm/emitter.js` | 462 | dependency-free binary encoder |
| Stdlib | `src/prelude.js` | 297 | HolyC prelude: `Gr*`, math, `Rand`, `Play/Snd/Note`, `Sleep/Yield`, `MAlloc`, strings |
| Host functions | `src/runtime/host.js`, `protocol.js`, `console.js`, `graphics.js`, `font.js`, `sound.js` | 112, 42, 242, 165, 8, 48 | import object for `__xxx` intrinsics; SharedArrayBuffer control block; printf + DolDoc colour; 640x480 16-colour framebuffer; 8x8 font from `Kernel/FontStd.HC`; WebAudio PC speaker |
| Tests | `src/wasm/emitter.selftest.js`, `src/atomic.selftest.mjs`, `src/import.selftest.mjs` | 113, 13, 24 | the only checks the README lists as supported for this checkout |

## 5. HEMU (ParkerrDev/HEMU)

"A TempleOS x86-64 emulator in HolyC" that "runs the unmodified TempleOS V5.03
kernel from a saved RAM image" (README). `src/` holds 2,155 lines of HolyC:
`cpu.HC` (1,357; fetch/decode/execute for integer, x87, SSE plus PIC, PIT,
HPET, CMOS, LAPIC/IOAPIC, PS/2, ATA, VGA DAC), `host.HC` (55; the host
contract), `core.HC`, `guestcall.HC`, `snapshot.HC`, `snapregs*.HC`
(generated), `boot.HC`, `anim.HC`, `test.HC` (instruction battery). It also
ships `live.bin.gz` and `live-smp.bin.gz` RAM snapshots (README: 384 MiB flat
images, gzipped). No build tooling is in the repo; TempleOS-Web's `engine/` is
its host.

## 6. HolyC-fmt (ParkerrDev/HolyC-fmt)

A HolyC source formatter written in HolyC (`HolyCFmt.HC`, 366 lines; `Fmt.HC`,
34 lines) with Node harnesses (`cli.mjs`, `runhc.mjs`, `sweep.mjs`,
`test.mjs`) that run it through HolyC-wasm checked out as a sibling. Its
README documents style rules measured over 519 `.HC` files and notes TempleOS
has no standalone formatter. Not used by this project.

## 7. What this project reused

### 7.1 Ideas and behaviour only (no code)

From TempleOS-Web / HolyC-wasm, by observation: that a native HolyC compiler
can run TempleOS programs without emulating x86 (Strategy B); that DolDoc
files must keep the binary sprite records after the NUL untouched (cf.
`game-source.js`; this project's `holyc/Source.kt` and `ui/EditorApp.kt`
implement the same rule independently); that God Words takes entropy from user
input timing. The apps' About text (Kotlin `ui/SmallApps.kt`, Swift
`UI/SmallApps.swift`) states: "TempleOS-Web by ParkerrDev was studied as a
behavioural reference; no code from it is included."

### 7.2 Original TempleOS files actually bundled or compiled

All from the official V5.03 ISO via `reference/templeos-iso/` (details and
counts in `docs/licensing-and-provenance.md`):

- 637 files copied (since then: 636, and 6 of them with offensive content censored or redacted, `docs/content-moderation/CONTENT_MODERATION.md`) into `shared/bundled-fs/` (games, demos, apps,
  docs, kernel/compiler sources as readable files, `Misc/Bible.TXT`, ...).
- `shared/runtime/GrLib.HC`: original HolyC from 15 Adam files (graphics,
  math, ODE, sound, menu, controls), 347 top-level chunks kept, 34 excluded.
- `shared/runtime/KernelClasses.HC`: 36 class layouts from `Kernel/KernelA.HH`.
- `shared/runtime/PreludeDefines.HC`: 1,600 `#define`s from `Kernel/KernelA.HH`
  and `Adam/Gr/Gr.HH`.
- `shared/runtime/font8x8.bin`: `sys_font_std` from `Kernel/FontStd.HC`.

### 7.3 Original source used for reading/porting

Native code that is a port of a named TempleOS file (per its header comment):
`holyc/Format.kt` (StrPrintJoin, `Kernel/StrPrint.HC`), `kernel/Gfx.kt`
(GrPlot0, `Adam/Gr/GrBitMap.HC`), `kernel/Raster.kt` (fast paths of
GrBitMap/GrPrimatives), `ui/GodApp.kt` (`Adam/God/HolySpirit.HC`,
`GodBible.HC`), the prelude's DC/matrix code (adapted from `GrDC.HC`,
`GrMath.HC`) and window-manager glue (after `Adam/WinMgr.HC`,
`Adam/Gr/GrScrn.HC`). `extract_templeos_iso.py` re-implements RedSea and LZW
from `Kernel/BlkDev/FileSysRedSea.HC`, `Kernel/Compress.HC`, `Kernel/KernelA.HH`.

## 8. What we deliberately did not use

| Not used | Evidence |
|---|---|
| HEMU / any x86 emulation, RAM snapshots, disk images | No `hemu`, `live.bin`, qcow2 or x86 decoder in the app sources. About text: "does not boot the real TempleOS kernel or emulate a PC". Inline `asm {}` is rejected by `holyc/Parser.kt`: "inline x86 assembly (asm {}) is not supported by TempleOS Mobile". |
| WebAssembly / HolyC-wasm runtime | `temple_os_kotlin/README.md`: "No WebView, no emulator, no JavaScript/WebAssembly, no network access." The compiler emits this project's own stack bytecode (`holyc/Op.kt`, shared numbering with Swift). |
| Browser code (JS, HTML, CSS, fonts, Sprite Studio, ffmpeg.wasm, transcripts) | No `.js`/`.mjs`/`.html`/`.ttf`/`.woff*`/`.wasm` files in `shared/` (checked with `find`); font comes from `FontStd.HC`. A sha256 comparison of every file in the four ParkerrDev checkouts against `shared/`, `tools/`, `temple_os_kotlin/`, `temple_os_swift/` found 20 identical files; all 20 are original TempleOS files that TempleOS-Web also vendors (e.g. `games/upstream/TinkerOS/Talons.HC`, `games/upstream/AustinArchive/Temple/Vocab.DD`), and this project's copies are byte-identical to the ISO extraction. |
| TempleOS-Web game packages (TinkerOS, TOOM, Freedoom, HolyCraft, Snake, ...) | Not in `shared/bundled-fs.index`; only ISO files and this project's `Home/` examples are listed. |
| cia-foundation mirror as source of shipped files | Bundled files come from the ISO; see licensing doc section on mirror differences. |

## 9. Capability audit

How TempleOS Mobile provides each capability, derived from
`temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/`
(`holyc/`, `kernel/`, `ui/`) and `shared/runtime/`. The Swift `TempleCore` is
documented in `temple_os_swift/PORTING.md` as a line-for-line port of the
Kotlin core; Swift sources were not audited file by file here.

Legend: **VM** = native HolyC compiler + bytecode VM; **Native** = native
(Kotlin/Swift) reimplementation; **Original** = original TempleOS HolyC running
on the VM; **No** = not supported.

| TempleOS capability | Provided by | Where |
|---|---|---|
| HolyC compilation and execution (JIT in TempleOS) | VM | `holyc/Lexer.kt`, `Parser.kt`, `CodeGen.kt`, `Quicken.kt`, `Vm.kt`, `Arena.kt` |
| Runtime compile (`ExePrint`, `ExeFile`), registry (`RegDft/RegExe/RegWrite`) | VM + Native | `kernel/NativesSys.kt` |
| `#exe {}` compile-time execution | No | `holyc/Lexer.kt` error message |
| Inline x86 `asm {}` | No | `holyc/Parser.kt` error message |
| Kernel class layouts, constants | Original (generated) | `shared/runtime/KernelClasses.HC`, `PreludeDefines.HC` |
| `Print`/`StrPrint` formatting | Native port of `Kernel/StrPrint.HC` | `holyc/Format.kt` |
| Strings, memory, math, random, bit ops, sorting | Native (prelude `native` decls) + some HolyC in prelude | `shared/runtime/Prelude.HC` (181 `native` declarations), `kernel/Natives.kt` |
| Graphics primitives `GrPlot0`, `GrPeek0`, flood fill ray | Native | `kernel/Gfx.kt`, prelude |
| Hot primitives (GrPlot, GrRect, GrHLine/VLine, GrBlot, GrFillTri0, Line, ...) | Native, with original kept as `*_HC` | `kernel/Raster.kt`; `NATIVE_FAST` in `build_runtime_lib.py` |
| Rest of graphics library (lines, circles, polygons, 3D, sprites) | Original | `shared/runtime/GrLib.HC` (from `Adam/Gr/*`) |
| DC and 4x4 matrix math | HolyC adapted in prelude; `Mat4x4MulXYZ`, `DCTransform` native | `Prelude.HC` graphics section |
| Text layer, 8x8 font | Native (replaces x86 asm in `GrTextBase.HC`); font data Original | `kernel/Gfx.kt`, `shared/runtime/font8x8.bin` |
| Palette | Native | `kernel/Palette.kt`, `GrPaletteColorSet/Get` natives |
| Sound `Snd`, `SndFreq`, `Mute` | PC-speaker renderer (`PcSpeaker`) behind dated speaker settings | `kernel/Natives.kt`, `kernel/PcSpeaker.kt`; outputs in `AndroidShellEnv.kt` / `IOSShellEnv.swift`; see `docs/audio/TEMPLEOS_SOUND.md` |
| Music `Play`, `Note`, `Ona2Freq` helpers | Original (`Adam/ASnd.HC`) plus native `Ona2Freq/Freq2Ona` | `GrLib.HC`, prelude |
| ODE solver, masses/springs | Original (`Adam/AMathODE.HC`) | `GrLib.HC` |
| Menus | Original (`Adam/Menu.HC`) except `DrawMenu`/`MenuTask`, drawn natively by host | `GrLib.HC`, `ui/Shell.kt` |
| Controls (buttons, sliders) | Original (`Adam/Ctrls/*`) | `GrLib.HC` |
| Tasks `Spawn`, `Kill`, `Suspend`, `Exit` | Native kernel tasks (max 64) | `kernel/Natives.kt`, `kernel/Kernel.kt` |
| Multicore `JobQue`, `MPInt`, `mp_cnt` | Native stand-ins: `JobQue` runs synchronously, `mp_cnt`=1, `MPInt` returns 0 | `kernel/Natives.kt`, `NativesSys.kt` |
| Keyboard/mouse (set-1 scan codes, `GetKey`, `GetMsg`, `ms`) | Native | `kernel/Keys.kt`, `kernel/Natives.kt` |
| PopUps (`PopUpChoose` etc.) | Native modal dialog | `NativesSys.kt`, `ui/ProgramHost.kt` |
| Window manager, desktop | Native (TempleOS-style), per-frame glue in HolyC after `WinMgr.HC` | `ui/Shell.kt`, `Prelude.HC`; `WinMax`, `WinHorz`, etc. are no-ops |
| Command line (HolyC shell) | Native app + VM | `ui/TerminalApp.kt` |
| Program console / DolDoc inline colour commands | Native | `kernel/Console.kt` |
| DolDoc document engine (`DocPut`, `CDoc`, ...) | No (chunks using it are auto-excluded from GrLib) | `AUTO_EXCLUDE_USES` in `build_runtime_lib.py` |
| DolDoc viewer (help, links, macros) | Native subset; `$SP` sprites shown as placeholders | `ui/DocViewerApp.kt` |
| Editor (`Ed`) | Native editor; preserves binary sprite tail | `ui/EditorApp.kt` |
| File system (RedSea/FAT32, block devices) | No; Native virtual FS: read-only bundle + writable overlay (64 MiB quota) | `kernel/LayeredFs.kt`, `FsCommands.kt` |
| `Dir`, `Cd`, `Copy`, `Del`, `FileRead/Write` | Native | `kernel/FsCommands.kt`, `Natives.kt` |
| God Words / Bible passages | Native port of `Adam/God/HolySpirit.HC`; data Original (`Vocab.DD`, `Bible.TXT`) | `ui/GodApp.kt` |
| `AutoComplete` | No (native stub returns 0; dictionary excluded) | `kernel/Natives.kt` |
| Hardware I/O ports (`InU8/OutU8`), debugger, compiler internals | No | `AUTO_EXCLUDE_USES`; opaque members in `KernelClasses.HC` |
| Networking | No (TempleOS has none either); Android manifest requests no permissions | `AndroidManifest.xml` comment |
| Paint | Native app (not a TempleOS program); saves uncompressed .GR | `ui/SmallApps.kt` `PaintApp` |
