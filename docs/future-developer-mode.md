# Future Developer Mode — design notes (NOT implemented)

**Status: documentation only.** Version 1 contains no import feature, no file
picker, no package format, no permission prompts, no paywall and no dormant
code for any of this. Nothing described here exists in the apps.

This document records how a later version could let users bring their own
HolyC programs into TempleOS Mobile, what the current architecture already
provides for that, and what must be built and reviewed first.

## 1. Possible user workflow

1. Open Developer Mode (a separate, clearly labelled area).
2. Choose **Import Program**.
3. Pick a file with the system picker (iOS: `UIDocumentPickerViewController`;
   Android: Storage Access Framework `ACTION_OPEN_DOCUMENT`). No broad storage
   permission would be requested.
4. Inspect the source before anything runs (read-only editor view).
5. Review what the program would be allowed to do (see §4).
6. Copy approved content into a sandboxed workspace on the virtual drive
   (for example `C:/Imported/<project>/`).
7. Edit it in the existing HolyC editor if desired.
8. Run it through the same interpreter used for everything else.
9. Stop or close it (existing Stop/Restart controls).
10. Keep the project locally.

Candidate inputs, if they are ever supported: `.HC`, `.HH`, TempleOS DolDoc
documents (`.DD`) with embedded sprites, and simple project folders. No new
proprietary package format is proposed; if a manifest is ever needed it
should be a small, documented JSON file alongside unchanged TempleOS sources.

## 2. What the V1 architecture already provides

These properties exist today because Version 1 itself needs them, not as
speculative infrastructure:

| Property | Where it lives today |
|---|---|
| Interpreter independent of bundled assets | `Kernel.runProgram(path, bytes)` compiles any source bytes; the VM never reads the app bundle directly. Bundled files reach it only through `VirtualFs`. |
| Stable program identifiers | `shared/program-manifests/catalog.json` gives every bundled program an `id` (e.g. `game.battlelines`), separate from its path. |
| Provenance metadata | catalog entries carry `author`, `license`, `source`; `bundled-fs.index` records sha256 and provenance per file. |
| Safe writable storage | `LayeredFs` overlay: path normalization, sandbox containment, atomic writes, quota (see `security-model.md` §4). |
| Explicit host API surface | the fixed native table (171 functions, no network/host access), see `security-model.md` §3.4. |
| Cancellation | per-program kernel thread, branch budget, `Break`, Stop/Restart. |
| Memory limits | per-program arena with a hard cap (32/64 MiB). |
| Safe failure | compile errors and runtime faults are HolyC exceptions reported in the console; they do not crash the app. |
| Registration separate from execution | the catalog/start menu only *describes* programs; `ProgramApp` executes a path. |

## 3. What would still have to be built

- Picker integration and copy-in (never execute in place from external storage).
- Size limits per file and per project; rejection of binary files that are
  not DolDoc-with-sprites; text encoding checks.
- Manifest validation, if manifests are adopted.
- A capability model that is actually enforced per program (V1 only records
  capabilities as metadata), e.g. separate grants for file writes outside the
  project folder, sound, and spawning tasks.
- Per-project resource quotas (disk, memory, CPU time) and an infinite-loop
  watchdog with a user-visible indicator.
- Provenance display: where the program came from, its hash, whether it was
  modified after import.
- An "imported" trust label in the UI wherever imported code runs.

## 4. Security work required before shipping imports

Running untrusted code from other people is a different risk class from
running code the device owner typed. Before any import feature ships:

- Grammar-aware fuzzing of the lexer, preprocessor (`#define`, `#include`,
  `#exe`), parser and code generator on both platforms.
- VM fuzzing with random and mutated bytecode-producing programs, with the
  Swift build under Address Sanitizer.
- Argument-validation fuzzing of every host function.
- Malformed-asset handling (sprites, `.GR` images, DolDoc binaries).
- Path-traversal tests for every file host function with imported projects.
- A review of where an imported program could interfere with other projects
  on the shared virtual drive (consider one drive per project).
- An external security review.

An interpreter running inside an app sandbox is not automatically safe:
bugs in the interpreter or host functions can still be exploited by hostile
input. The V1 checks (`security-model.md`) are the baseline, not the finish line.

## 5. Store policy review

Both stores restrict apps that download or execute code. Before Developer
Mode, re-read the then-current Apple App Review Guidelines (notably 2.5.2 and
4.7) and Google Play's Device and Network Abuse policy, and confirm that
user-initiated import of source code into an interpreter is acceptable as
designed. Do not assume approval.

## 6. Monetization

A paid Developer Mode is a possible future direction. No payment code, store
SDK, entitlement check or locked UI exists in V1, and the bundled experience
is not limited to encourage a purchase. Revisit only after the free app is
stable and there is demonstrated demand.

## 7. Relationship to Online Mode

Local import and online discovery are separate features (see
`future-online-mode.md`). Developer Mode must be shippable without any
network capability, and Online Mode must not depend on Developer Mode.
