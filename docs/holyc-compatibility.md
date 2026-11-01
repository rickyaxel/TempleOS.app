# HolyC compatibility

> **Verification pass (2026-10-16), `docs/verification-pass/HOLYC_VERIFICATION.md`.** Semantics corrected to match the TempleOS compiler and kernel sources (V-14, V-15):
> - Language: mixed comparison chains (`2<3==1` is 0); `` ` `` is right-associative and always F64, and `-x`y` is `-(x`y)`; comparisons are unsigned when either operand has any unsigned type; `I64_MIN/-1` raises `DivZero`.
> - Library: `MemCpy`/`MemSet` return `dst+cnt`, `MemCpy` copies forward, and counts are 64-bit; `StrCmp` and friends return ±1; exact `Str2I64`, `StrUtil`, `LstMatch` and `StrCpy(NULL)`.
> - Terminal: prints TempleOS's `ans=` line.
> - Still unsupported: `#exe`, nested `start:`, the `''` char constant, `asm`, and the DolDoc document API.


TempleOS Mobile runs HolyC on its own compiler and bytecode VM, implemented
twice (Kotlin `temple_os_kotlin/core/.../holyc`, Swift
`temple_os_swift/TempleCore/Sources/TempleCore/HolyC`). The authoritative
language definition is `shared/specifications/holyc-runtime-spec.md`; this
document summarizes what is supported, what is not, and the evidence.

## 1. Evidence

| Check | Kotlin | Swift | How |
|---|---|---|---|
| Conformance vectors `shared/test-vectors/holyc/001–016` | 16/16 pass | 16/16 pass | `HolyCVectorTest` / `HolyCVectorTests` compare console output (or the expected error) exactly |
| Bundled catalog programs (96) started and run for 3 s of virtual time with synthetic input | 80 without error (incl. 37 that finish), 16 report an error | identical status for all 96 | `SweepTest`/`SweepTests` with `-Dtempleos.sweep=Catalog` / `TEMPLEOS_SWEEP=Catalog`, 64 MiB program memory |
| Cross-platform frame parity on the same run | — | 88 of 91 final frames byte-identical; 3 differ slightly (X-Caliber 34 px, RocketScience 44 px, Squirt 2597 px) | `tools/parity/compare_frames.py Catalog` |
| Original library routines replaced by native code | pixel/return/RNG-identical on random inputs | same natives ported 1:1 | `RasterDiffTest` (GrPlot…GrFillSemiCircle, `Line`, `SpriteSize`/`SpriteElemSize` on all 325 embedded sprites) |

The three parity differences come from transcendental math (`Sin`, `Cos`,
`Exp`, `Pow`…): each platform uses its own math library, which can differ in
the last bit, and physics simulations (Squirt) amplify that over time.

"Runs" in the sweep means *starts and executes without a compile error or an
unhandled exception*; it is not a claim that every feature of every program
was exercised. Interactive verification is recorded in
`game-compatibility.md`.

## 2. Language constructs implemented

- **Types**: `U0 I8 U8 I16 U16 I32 U32 I64 U64 F64 Bool`, the `i` variants
  (`I64i`…), pointers, multi-dimensional arrays, `class`/`union` (packed),
  inheritance (`class B : A`), `I64 class` value types, intrinsic integer
  unions (`x.u8[3]`, `x.i32[1]`), `sizeof`, `offset(Class.member)`, forward
  declarations (`extern class X;`).
- **Operators**: HolyC precedence (`` ` `` power, shifts above `*`), chained
  comparisons (`a<b<=c`), `^^` logical xor, compound assignments, pre/post
  increment on any lvalue, casts `(type)` and postfix `x(type)`, address-of
  functions (`&F`), function pointers in variables and members.
- **Statements**: `if`, `while`, `do`, `for`, `switch` and `switch []` with
  ranges, auto-numbered empty cases, `start:`/`end:` groups, `goto`/labels,
  `try`/`catch`/`throw`, declarations anywhere, `lock {}`, `no_warn`.
- **HolyC conventions**: string/char statements print, calls without
  parentheses use default arguments, skipped arguments (`F(,3)`), default
  arguments anywhere, varargs with `argc`/`argv`, top-level code runs in order
  (JIT-style, chunk by chunk), `#define`/`#undef`/`#include`/`#ifdef`/`#ifndef`/
  `#if`/`#else`/`#endif`/`#ifjit`/`#ifaot`, backslash line continuation.
- **DolDoc in source**: text extraction, `$$`, binary attachments (`$IB$`,
  `$IS$`) for embedded sprites, `$TX$`, formatting commands inside literals and
  identifiers.
- **Runtime compilation**: `ExePrint`, `ExeFile` (compile and run text in the
  same VM), `#include` of files from the virtual drive.
- **Exceptions**: TempleOS exception codes, `PutExcept`, catchable runtime
  faults (`DivZero`, `BadMem`, `BadFree`, `StkOver`), `Break` on Stop.
- **Tasks**: `Spawn`, `Kill`, `Suspend`, `Yield`, `Sleep`, messages, frame
  callbacks (`Fs->draw_it`, `Fs->animate_task` style programs), `JobQue`
  (run synchronously).

## 3. Not supported

| Feature | Behaviour | Why |
|---|---|---|
| `asm {}` inline assembly | compile error with explanation | no machine code is ever generated or executed |
| `#exe {}` compile-time execution | compile error with explanation | not implemented |
| DolDoc document API (`CDoc`, `DocNew`, `DocPrint`, `DocForm`, `PopUpMenu(doc)`…) | `undefined identifier` | the console is a simpler cell document; affects Budget, Psalmody, ToTheFront, GrModels, FontEd |
| Sprites inserted into documents (`Sprite()`), sprite editor | `undefined identifier` | affects Demo/Graphics Blot, EdSprite, SpritePut, SpriteRaw, SpriteText |
| Hardware access (VGA memory, PCI, disk, ports) | port I/O reads 0 / writes ignored; direct VGA memory faults | no PC hardware (Balloon) |
| Multi-core jobs (`CJob`, `mp_cnt>1`) | one core (`mp_cnt` is 1) | PoleZeros needs `CJob` |
| AutoComplete dictionary (`acd`) | not bundled (26 MB) | Vocabulary |
| Compiler internals (`CCmpCtrl`, `Lex*` APIs, hash tables) | not available | — |
| x87-exact floating point | IEEE double via the platform math library | results can differ from real hardware (and between platforms) in the last bit |

## 4. Adaptations (documented differences from TempleOS)

- **Catch before unwind**: the stack is unwound to the handler before the
  catch block runs (TempleOS runs it first).
- **Falling off the end**: a non-`U0` function that ends with an expression
  statement returns that expression's value (TempleOS returns RAX).
- **Memory**: each program has a private arena (32, 64 or 96 MiB by device
  class); real TempleOS has the whole machine. Blocks are rounded like TempleOS's
  MAlloc (8 bytes) and freed blocks keep their bytes. Talons needs 96 MiB
  (fidelity audit FA-29, FA-36).
- **Sprites**: an element type ≥ `SPT_TYPES_NUM` ends a sprite (the original
  reads past its size table; one sprite in the ISO's Titanium.HC has a corrupt
  terminator).
- **Frame rate**: frames at `WINMGR_FPS` (≈29.97 Hz) like TempleOS; programs
  run on their own thread and are paused while hidden or in the background.
- **Registry**: `RegDft`/`RegExe`/`RegWrite` work on an in-memory registry
  per program run (nothing is persisted).
- **Popups**: `PopUp*` functions are native mobile dialogs; `OneTimePopUp`
  offers "OKAY" / "OKAY, don't show again" instead of a check box.

## 5. Performance of the interpreter

Bytecode interpreter with in-place superinstructions ("quickening") and native
fast paths for the hottest original library routines. Measured on 3 s of
virtual game time (instructions executed): BattleLines 215 M, Varoom 342 M,
Squirt 534 M. On an Android emulator (arm64, release build) BattleLines and
Varoom render at TempleOS's full 29.97 FPS; see `performance.md` for all
measurements and their conditions.
