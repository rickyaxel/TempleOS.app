# Importing TempleOS files (Start menu > Import...)

Users can bring external TempleOS programs onto the virtual C: drive and run them on the same HolyC
interpreter as everything else. This document describes how the import works on both platforms, the
decisions behind it, its limits and what is still open.

## 1. What the user sees

1. **Start menu > Import...** (the row after Files).
2. The first time, an explanation: what Import does, the three supported types, where files go, that
   some programs need TempleOS features the app does not have, and to import only from trusted
   sources. **CHOOSE FILES** continues; **CANCEL** (or back/Esc) leaves it unacknowledged, so it is
   shown again next time. Continuing is stored with the session settings (`i=1`).
3. The system picker: iOS `UIDocumentPickerViewController` (Files, iCloud Drive, other providers),
   Android Storage Access Framework (`ACTION_OPEN_DOCUMENT`: local storage, Downloads, Drive, USB...).
   Several files can be chosen.
4. "Importing..." while the files are read and checked off the UI thread.
5. When a name is already taken: **REPLACE** (drawn as destructive) / **KEEP BOTH** (`Name_2.HC`) / **CANCEL**.
6. A summary: one line per file ("o.HC.Z was imported as C:/Home/Imports/o.HC", "Span.zip was
   extracted to C:/Home/Imports/Span (files: 8)", or the reason it was not). **OPEN FOLDER** opens
   Files there; **RUN** appears when exactly one program was imported. **Nothing ever runs by itself.**

Imported files are ordinary files on C:: they appear in Files, open in the editor, can be renamed,
moved or deleted, run from Files (tap > Run) or the Terminal (`#include "..."`), and survive restarts.

## 2. Formats

| Picked file | Stored as | Notes |
|---|---|---|
| `Name.HC` | `C:/Home/Imports/Name.HC`, bytes unchanged | Refused if the content is a ZIP or a TempleOS-compressed archive (the name is wrong), or empty. Text is never converted: DolDoc binary sections (sprites) are kept. |
| `Name.HC.Z` | `C:/Home/Imports/Name.HC`, expanded | TempleOS's own compression (`Kernel/Compress.HC`, LZW, types 1-3), **not** ZIP or Unix compress. |
| `Name.zip` | a folder in `C:/Home/Imports` | Folders kept. One folder that holds everything becomes the import folder (`MyGame.zip` of `MyGame/...` gives `C:/Home/Imports/MyGame`); otherwise a folder named after the archive. Every file type is kept (`.HC`, `.HH`, `.DD`, `.GR`, `.BIN`, ...); any TempleOS `.Z` inside is expanded like a picked `.HC.Z`. Finder metadata (`__MACOSX/`, `.DS_Store`) is skipped. Archives inside archives are stored as files, never extracted. |

The kind is decided by the file's name (any case), never by the MIME type: providers report `.HC` and
`.HC.Z` with arbitrary types, so the pickers offer every file and the content is checked instead.

**Why `.HC.Z` is expanded at import (not at read time):** the bundled drive already stores the ISO's
645 compressed files expanded under their names without `.Z`, and `LayeredFs` resolves `X.HC.Z` to
`X.HC`; `#include "X"` tries `X.HC`, `X.HH`, `X.HC.Z`. Storing the expansion keeps one representation
for bundled and imported files, so Files, the editor, `#include`, `Cd(__DIR__)` and the DolDoc and GR
loaders need no change. The expander (`TempleArc.expand`, a bounded port of `ArcExpandBuf`) produces
exactly the output of TempleOS's own Linux tool `TOSZ.CPP` for all 927 compressed files on the V5.03 ISO
and the three supplemental discs.

## 3. Where files go and how they are stored

- **Destination:** `C:/Home/Imports`, inside the user's TempleOS home (Files and the Terminal open in
  `C:/Home`, so the folder is one tap away). Nothing is scattered over the root, and nothing can land
  outside this folder.
- **Storage:** the drive's writable overlay (`LayeredFs`, app-private: iOS Application Support, excluded
  from backup; Android `filesDir`). The bundled drive is never modified. Imports count toward the
  overlay's quota (64 MiB for all of the user's files).
- **Staging:** an import is written into a hidden `.tmp-import-<id>` folder at the top of the overlay
  (`list` hides `.tmp-` names) and made visible with **one rename**. A refused or failed import leaves
  nothing behind; the next start deletes abandoned staging folders.
- **Replace:** the earlier entry is moved aside into the staging folder and the move is recorded in
  `import-journal.txt`; the new one is renamed into place; the old one is then deleted off the UI
  thread. If the app is killed between the two renames, the next start puts the earlier entry back.
- **Protected files:** a bundled original is never replaced by an import, even when asked.
- **Names:** RedSea rules (`Paths.normalize`): at most 38 characters, TempleOS character set (CP437,
  the same set the editor accepts; names are normalized to NFC first, so decomposed `é` works), no
  `: * ? " < > |`, no `.`/`..`, no `.tmp-` prefix. The drive ignores case, so names that differ only in
  case collide. ZIP names in UTF-8 (flag 11, or valid UTF-8 without it, as macOS and Linux tools write)
  are converted to CP437; names without the flag are CP437, which is TempleOS's own character set.

## 4. Archive checks and limits

Archives are untrusted. Everything below is checked **before anything is extracted**, from the central
directory and every local header (`ZipArchive`, the same parser on both platforms):

| Refused | How |
|---|---|
| ZIP slip: `..`, absolute paths, drive prefixes (`C:`, `::`), backslash variants | names are split and checked; every staged path is also re-checked to stay inside the staging folder |
| links, devices, FIFOs, sockets | Unix file type in the external attributes |
| encryption (traditional, strong, AES) | flags 0 and 6, method 99 |
| methods other than Stored and Deflate | method field |
| two entries that differ only in case; `X.HC` and `X.HC.Z` together; a file that is also a folder | case-insensitive path sets |
| inconsistent structure: truncation, a local header that names another file, data outside the file or after the central directory, overlapping entries | local header checks in file order |
| ZIP64 and split archives | end-record markers |
| damaged data | exact declared size and CRC-32 per entry |

| Limit | Value |
|---|---|
| picked `.HC` / `.HC.Z`, and each extracted file after expansion | 16 MiB |
| picked `.zip` | 32 MiB |
| total extracted from one archive | 48 MiB (and the 64 MiB overlay quota) |
| entries | 2000 |
| folder depth | 8 |
| expansion ratio for entries over 1 MiB | 200:1 |
| files per selection | 32 |

Inflating writes into a buffer of exactly the declared size plus one spare byte (a stream that fills it is
refused); TempleOS `.Z` expansion checks the declared size before allocating. Work is bounded by these
limits. Swift inflates with the Compression framework (`COMPRESSION_ZLIB` is raw RFC 1951 Deflate) and its
own CRC-32; Kotlin with `java.util.zip.Inflater` and `CRC32`. Apple platforms have no public API that reads
ZIP archives, so the container format is parsed by our own bounded reader on both platforms, rather than by
`ZipFile` on Android only, so that both refuse exactly the same archives.

## 5. Running imported programs

There is no separate pipeline: an imported file is a path on C:, and Files > Run (or RUN in the summary)
calls the same `Launch.program` as for any file. The kernel sets the program's directory as its current
folder and resolves `#include` relative to the including file, so `C:/Home/Imports/Span/Run.HC` finds
`Load.HC`, `Span.HH` and its other siblings next to it. Programs that are not in the bundled catalog run
with no per-program settings (title from the file name, not maximized).

**Import success is not execution success.** A program that needs something the interpreter does not have
imports normally and then stops with the compiler's message in its window, for example "inline x86 assembly
(asm {}) is not supported" (NewOS) or "undefined identifier 'snd'" (HD Audio, in the supplemental sound
library). The app stays usable.

**Sandbox (unchanged):** imported HolyC runs in the same interpreter as typed code: its own arena with a
hard memory limit, a branch budget per slice on a background thread (an endless loop never blocks the UI),
Stop and closing the window end it, no native code, no host files beyond the C: drive, no network
(`security-model.md`). An imported program can read and write the user's C: files like any program the
user runs.

## 6. Threading and lifecycle

- The menu, dialogs and publishing (renames) run on the UI thread; reading, checking, expanding, extracting
  and staging run on a background thread; deleting staging folders too.
- One picker at a time: while a picker is open or an import is running, Import does nothing.
- The import's dialogs never replace another dialog: while a program's dialog is open they wait, and a
  question that a program's dialog pushed away is asked again.
- Open Files windows re-list their folder when an import ends.
- Android: the picker is another activity; the app pauses and resumes as for any other app (programs
  pause, the session is saved). A result that reaches a recreated activity is still imported. iOS: the
  picker is presented over the desktop; after it closes the desktop takes the hardware keys again.

## 7. Platform parity

Same formats, destination, explanation, limits, checks, collision handling, messages (46 catalog strings)
and tests on both platforms (`ImportTests.swift`, `ImportTest.kt`). Intentional differences are only in
the platform adapters (`DocumentImportAdapter.swift` / `.kt`):

| | iOS | Android |
|---|---|---|
| Picker | `UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)` | `ACTION_OPEN_DOCUMENT`, `*/*`, `CATEGORY_OPENABLE` |
| Copy | by the system (asCopy: cloud files are downloaded first) into the app's temporary folder | by the app from the content URI into its cache, stopping at the largest accepted size |
| Name | the copy's file name | `OpenableColumns.DISPLAY_NAME` |
| Permissions | none (no document types, no entitlements) | none (no storage permission, no persistable grant) |

## 8. Tests and fixtures

`ImportTests` / `ImportTest` (17 tests each) drive the real paths: start menu, explanation, picker hook,
`FileImport`, the drive, Files (tap, Run) and the interpreter. Genuine programs the app does not bundle,
from TempleOS supplemental disc 1, are in `shared/test-vectors/import` with their origin, license
(public domain) and SHA-256: a hymn (`o.HC.Z`) plays, `B17.HC.Z` and `DiningStars.HC` draw, `Span.zip`
runs with its sibling includes, `NewOS.HC.Z` and `Sup1Snd.zip` import and stop with a clear compile error.
Adversarial archives are built by the tests (section 4). The offline audit
(`tools/compatibility-validation/offline_audit.sh`) allows document pickers only in the two adapters and
still refuses URL handlers, other pickers and inbound intent filters.

## 9. Known limitations and open items

- The import has been verified by the headless tests on both platforms and by building both apps. The
  picker itself (Files/SAF UI, cloud providers, cancellation, rotation and background with the picker open,
  activity recreation) still needs a run on the iOS simulator and on an Android device.
- Many supplemental programs need TempleOS services the interpreter lacks (HD Audio, block devices,
  inline assembly, some DolDoc and graphics internals); they import fine and report the compile error.
- iOS: when two chosen documents have the same name, the system's copy of the second may be renamed
  (for example with a number); it is then imported under that name.
- Not done, from `security-model.md` §7 and `future-developer-mode.md` §4-§5: an external security review,
  a per-program capability model, a provenance or "imported" label in the UI, and a re-reading of the App
  Store Review Guidelines (2.5.2, 4.7) and Google Play's policies for user-imported source code. The owner
  should decide on these before a store release with this feature.
