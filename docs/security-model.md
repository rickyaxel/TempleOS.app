# Security model — TempleOS Mobile Classic (Version 1)

> **Store-readiness audit (2026-10-23), `docs/store-audit/HOLYC_EXECUTION_SECURITY_AUDIT.md`.**
> - Fixed: constant global initializers were stored without `Arena.check` (an out-of-bounds write on Swift); array
>   sizes could wrap (Kotlin) or trap the app (Swift); redefining a prelude class trapped the Swift app; a Terminal
>   Tab completion could crash the Android app; `Msg` bypassed the 256-message bound; Terminal commands kept
>   running (and sounding) in the background.
> - Corrections below: 180 natives (not 171); 32/72/96 MiB program memory; the low 64 KiB of the arena is
>   ordinary memory (as in TempleOS), not a faulting guard region; the registry is persisted.
> - Open (P2/P3, documented there): some host structures are not charged to the program's memory (runtime
>   compilation, `FramePtrAdd`, `Define*`, UI requests), empty files and directories are not charged to the
>   64 MiB quota, case-variant directory names on case-sensitive storage.

> **Verification pass (2026-10-16), `docs/verification-pass/OFFLINE_AND_SECURITY_AUDIT.md`.**
> - Four P0 native memory-safety bugs in the **Swift** VM were found and fixed: heap metadata (V-05), operand stack (V-06), raster stride (V-07), `Spawn` (V-21). Swift is now ASan-clean under fuzzing.
> - Also fixed: compiler recursion limits (V-08, V-22); unkillable hangs (V-23); task-stack leaks (V-18); a use-after-free of `Shell` on background threads (V-19).
> - Remaining limitation (V-17): a HolyC callback inside a native cannot be preempted. The 100M-instruction guard ends it.


This document describes what HolyC code can and cannot do inside TempleOS
Mobile, how the interpreter is isolated from the app process, and which
checks exist. It applies to both apps: the Kotlin runtime
(`temple_os_kotlin/core`) and its line-for-line Swift port
(`temple_os_swift/TempleCore`). Where the two differ, it says so.

It does **not** claim the interpreter is "safe because it is sandboxed".
Interpreter and host-function bugs are possible; the measures below limit
their reach, and the deferred work for imported code is listed at the end.

## 1. Threat model for Version 1

| Source of HolyC code | Present in V1? | Trust |
|---|---|---|
| Original TempleOS V5.03 programs and libraries bundled read-only in the app | yes | trusted content, still executed through the same checks |
| Examples written for this project (`C:/Home/Examples`) | yes | trusted content, same checks |
| Code the user types in the Terminal or the Editor on the device | yes | untrusted input from the device owner, same checks |
| Code imported from Files/SAF, URLs, share sheets, other apps | **no** — no import path exists | — |
| Code downloaded from the network | **no** — no network access exists | — |

There is exactly one execution path for all of these: source text from the
virtual filesystem (or typed into the terminal) → Lexer → Parser → CodeGen →
bytecode → VM. Bundled programs do not bypass any check.

## 2. Platform-level isolation

| Property | Android | iOS |
|---|---|---|
| Network permission | none requested; `AndroidManifest.xml` declares no `<uses-permission>` at all (verified with `aapt2 dump permissions`) | no networking code; no ATS exceptions; privacy manifest declares no tracking and no domains |
| Network libraries | none (the app depends only on the Android framework and the `:core` module; no AndroidX) | none (UIKit, AVFoundation, Foundation) |
| Inbound content | only the launcher `MAIN/LAUNCHER` intent filter; no `VIEW`/`SEND` filters, no file/URL schemes, nothing else exported | no URL types, no document types, `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` false, no share extension |
| Backup / transfer | `allowBackup=false`, `fullBackupContent=false`, data-extraction rules exclude everything | user drive and session in Application Support marked `isExcludedFromBackup` |
| Cleartext traffic | `usesCleartextTraffic=false` (no traffic exists) | n/a |
| Native code loading | none (`System.loadLibrary` is never called) | none (no `dlopen`) |
| Dynamic code generation | none: bytecode is interpreted; no JIT, no classloading, no reflection | none: no JIT, no `dlopen`, no JavaScriptCore |
| Accounts, analytics, ads, purchases | none | none |

## 3. Interpreter isolation

### 3.1 Memory

Every program (one `Kernel` per program window, one for the terminal) gets its
own `Vm` with its own **arena**: a private byte address space, never real
process memory.

- HolyC pointers are integers into the arena. No interpreter value is ever
  converted into a JVM reference or a Swift pointer that HolyC can control.
  (The Swift arena is a raw `calloc` block, but every access goes through
  `Arena.check(addr, size)` first, exactly like Kotlin.)
- `check(a, n)` faults (`BadMem`) unless `0 <= a` and `a + n <= size`.
  (Corrected 2026-10-23: addresses `0..0xFFFF` are ordinary arena memory, as
  TempleOS's own low memory is; they are not a faulting guard region.
  `shared/test-vectors/holyc/220_NullPage.HC` pins the behaviour.)
- The arena starts at 1 MiB and grows on demand up to a hard limit
  (`memoryLimit`): 32, 72 or 96 MiB by device class (Android heap class
  < 256 / >= 256 / >= 384 MB; iOS physical memory < 2.6 / >= 2.6 / >= 3.5 GB).
  Exceeding it raises the HolyC exception `OutMem`.
- `MAlloc` is a size-class allocator with 16-byte block headers carrying a
  magic value. `Free` faults (`BadFree`) on pointers outside the heap,
  misaligned pointers, pointers without a valid header, and double frees.
- **Limitation (stated honestly):** checks are at arena granularity. A HolyC
  program can read or write anywhere inside its *own* arena, including other
  allocations, freed blocks and its own task stacks — as on real TempleOS,
  where there is no memory protection at all. This can corrupt the program
  itself but cannot reach other programs, the app, or the device.
- Integer arithmetic wraps (64-bit two's complement, as on x86-64). Division
  by zero raises `DivZero`. `I64_MIN / -1` yields `I64_MIN` (no host trap).

### 3.2 Stacks and recursion

| Resource | Limit | On overflow |
|---|---|---|
| Call depth per task | 2048 frames | `StkOver` |
| Locals/frame stack per task (in the arena) | 256 KiB | `StkOver` |
| Operand stack per task | 8192 words | `StkOver` (Kotlin: array bounds; Swift: explicit check, see §6) |
| Nested `try` handlers per task | 256 | `StkOver` |

### 3.3 Time, cancellation and the UI thread

- Programs never run on the UI thread. Each program's kernel runs on its own
  background thread (`KernelRunner`), in slices of about 12 ms of wall time.
- Inside a slice the VM counts backward branches and calls; it returns to
  the scheduler when the budget is used up or when `interrupt` is set. A
  `while (TRUE) {}` therefore cannot freeze the interface.
- **Stop program** sends TempleOS's `Break` (Ctrl-Alt-C) first so the program
  can clean up, then the window can be closed, which terminates the kernel
  thread. **Restart** recreates the program from its source. Neither touches
  the user's files.
- Callbacks from native code back into HolyC (e.g. `Line()` calling a plot
  function, `QSort` comparators, `JobQue`) are bounded: a callback that runs
  for more than 500 slices of 200 000 branches raises an uncatchable
  `VmKill`.
- The app going to the background pauses every program; returning resumes them.

### 3.4 Host functions (capability surface)

HolyC can only reach the outside world through the **native table**: 180
host functions (identical name sets on both platforms, 2026-10-23) registered by `kernel/Natives.kt` and `kernel/NativesSys.kt`
(and their Swift ports). The complete list is generated from the source by
`grep -ohE 'reg\((nt, )?"[A-Za-z0-9_]+"' kernel/*.kt`. They fall into these groups:

| Capability | Functions (examples) | Reach |
|---|---|---|
| Console text | `Print`, `PutS`, `StrPrint`, `GetS`, `GetChar`, `DocClear` | the program's own console document |
| Memory and strings | `MAlloc`, `Free`, `MemCpy`, `StrCmp`, `QSort` | the program's own arena |
| Math, time, random | `Pow`, `Rand*`, `Seed`, `Now`, `tS`, `Sleep`, `Yield` | none outside the VM |
| Graphics | `GrPlot*`, `GrRect`, `GrBlot*`, `GrFill*`, `Line`, palette | the program's own 640×480 framebuffer |
| Sound | `Snd`, `Mute` | one square-wave tone generator |
| Input | `GetKey`, `ScanMsg`, `GetMsg`, `MsSet` | events from its own window only |
| Tasks | `Spawn`, `Kill`, `Suspend`, `JobQue` | cooperative tasks inside the same kernel (no OS threads or processes) |
| Files | `FileRead`, `FileWrite`, `Dir`, `Cd`, `Del`, `DelTree`, `Copy`, `Move`, `DirMk`, `FileFind`, `Type` | the virtual `C:` drive only (§4) |
| UI requests | `Ed`, `Man`, `Help`, `DocLink`, `PopUpChoose`, `MenuNew` | ask the shell to open the editor, a document or a choice dialog; publish the program's menu |
| Runtime compilation | `ExePrint`, `ExeFile` | compile HolyC text into *bytecode in the same VM* (TempleOS's JIT entry points); same sandbox, no machine code |
| Registry | `RegDft`, `RegExe`, `RegWrite`, `RegCnt` | TempleOS's registry: HolyC text kept in `C:/Home/Registry.HC` on the virtual drive (as in TempleOS) and run by `RegExe` in the calling program's VM; never the host's registry or settings |

There is **no** host function for: network access, host filesystem paths,
process launching, loading native libraries, reflection or calling arbitrary
Kotlin/Swift/Java/Objective-C methods, sensors, location, camera, microphone,
contacts, clipboard (the clipboard is only reachable by the user through the
editor/terminal menus), or background monitoring. `Raw` and `Option` are
accepted for source compatibility and do nothing.

Every program gets the same native table. Per-program capability metadata
exists in the catalog (`shared/program-manifests/catalog.json`,
`capabilities` field) and is shown to the user, but V1 does not enforce
per-program capability grants — all bundled and local programs get the same
fixed, offline-only surface above.

### 3.5 Compiler

- The compiler is an ahead-of-execution bytecode compiler inside the same
  sandbox. Malformed source raises `CompileError` (reported in the console),
  never a host crash; this is exercised by `shared/test-vectors/holyc/012_Errors.HC`.
- `#include` resolves only through the virtual filesystem.
- `asm {}` blocks and `#exe {}` are not supported (rejected with a compile
  error); there is no way to produce machine code. `ExePrint`/`ExeFile`
  compile source text at run time, but only into bytecode for the same VM.
- Bytecode is generated only by CodeGen. The quickening pass
  (`holyc/Quicken.kt`) rewrites opcode words of already-generated code into
  fused superinstructions; HolyC cannot write to bytecode (code is not in
  the arena), so there is no self-modifying code.

## 4. Virtual filesystem

`LayeredFs` presents a TempleOS `C:` drive built from:

1. **Bundled layer** (read-only): the original TempleOS V5.03 files plus the
   project's examples, inside the APK assets / iOS app bundle.
2. **Overlay** (writable): `files/` under the app's private storage
   (Android `filesDir/drive`, iOS Application Support `TempleOSMobile/drive`).

Rules enforced on every operation:

- Paths are normalized by `Paths.normalize`: only drive `C:`; `\` becomes
  `/`; `.`/`..` are resolved logically and cannot go above `C:/`; segments
  with control characters or `:*?"<>|` are rejected; segment length ≤ 38
  (RedSea limit).
- The host file for a logical path is resolved and canonicalized and must lie
  inside the overlay directory; otherwise the call fails (`Invalid path`).
  `LayeredFsTest.traversalCannotEscapeSandbox` checks `C:/../../../outside.txt`
  stays inside the overlay.
- Writes are atomic: temp file in the same directory, `fsync`, rename.
- Writing a bundled file creates a copy in the overlay (copy-on-write);
  deleting a bundled file records a whiteout. "Restore original" removes the
  user's copy. Bundled files are never modified.
- The overlay is limited to 64 MiB (`Storage full` error beyond that).

## 5. Session and user data

- Session state (open windows, editor drafts, settings) is a small text file
  next to the drive. It contains only paths, cursor positions and drafts the
  user typed. Programs are restarted from source on restore; no VM memory is
  persisted.
- Nothing leaves the device: no sync, no backup, no telemetry.

## 6. Swift-specific notes

The Swift port uses unsafe pointers in the hot paths (operand stack, frame
arrays, arena, bytecode) for speed. Kotlin gets bounds checks from the JVM;
the Swift port must perform every such check explicitly. The checks that
replace JVM bounds checking are:

- operand-stack headroom checked on every call entry (fault `StkOver`);
- function indices and switch-table indices validated before use;
- every arena access preceded by `Arena.check` (same as Kotlin);
- arena reservation of `maxBytes + 16` so unaligned 8-byte loads at the
  logical end never leave the allocation.

These checks are covered by the shared HolyC test vectors (`012_Errors.HC`,
`013_Recursion.HC`) on both platforms.

## 7. Known limitations and deferred work

- Arena-granular (not per-allocation) memory checks, as described in §3.1.
- No per-program capability enforcement (§3.4); acceptable in V1 because the
  surface is identical for all code and contains no network or host access.
- The interpreter has not been fuzzed. Before any import feature (see
  `future-developer-mode.md`), add: grammar-aware fuzzing of the lexer,
  parser and codegen; randomized bytecode/VM fuzzing; fuzzing of every host
  function's argument validation; resource quotas per imported project;
  source/size limits; provenance display and capability prompts.
- DolDoc rendering in the document viewer is a subset; malformed documents
  render as text, they are never executed. `$MA$`/`$BT$` macro links only
  run when the user taps them, in a terminal, through the same interpreter.
