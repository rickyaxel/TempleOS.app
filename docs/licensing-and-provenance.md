# Licensing and provenance

What TempleOS Mobile Classic ships, where every shipped asset comes from, how
to regenerate it, and the license status of the material involved. All
figures were produced on 2026-10-16 by reading files and running the
project's own tools into a scratch directory (no project file was modified).
This document is a factual record, not legal advice.

## 1. TempleOS public-domain status

TempleOS V5.03 was written by Terry A. Davis, who declared it public domain.
Statements found in the files extracted from the official ISO
(`reference/templeos-iso/`, identical copies are bundled in `shared/bundled-fs/`):

| File | Statement (DolDoc markup removed) |
|---|---|
| `Doc/Credits.DD` line 3 | "I, Terry A. Davis, wrote all of TempleOS over the past 13.9 years (full-time). [...] It is public domain, not GPL." |
| `Doc/Charter.DD` line 56 | "* Free and public domain." |
| `Doc/Features.DD` line 9 | "* Free, public domain, 100% open source." |
| `Doc/Start.DD` line 3 | "Public Domain Operating System" |
| `Doc/FAQ.DD` line 3 | entry "How come it is public domain, not GPL?" |

The cia-foundation mirror has no LICENSE file; its `ReadMe.TXT` says
"TempleOS is 100% open source with all source present".

### 1.1 Third-party material inside TempleOS itself

`Doc/Credits.DD` also names material Davis did not originate. Their status
rests on Davis's own notes, which this project cannot independently verify.
After this audit the bundling tool was changed (see §2.0): `FontCyrillic.HC`
is no longer bundled, and `Bible.TXT` / `FontStd.HC` carry their real origin
in the index; the other rows below are still bundled with the generic label:

| Bundled file | What `Doc/Credits.DD` says |
|---|---|
| `Kernel/FontStd.HC` (also the source of `font8x8.bin`) | "is taken from FreeDOS. It's public domain." |
| `Kernel/FontCyrillic.HC` | "is taken from OrientDisplay [...] without permission." |
| `Misc/Bible.TXT` (4,345,143 bytes) | King James Bible "from Project Gutenberg". The file starts with the Project Gutenberg Etext #10 header and its "small print" section. |
| `Misc/PCIDevices.DD` | "I included PCIDevice Lst File" (link to pcidatabase.com) |
| `Demo/ToHtmlToTXTDemo/ToHtml.HC` | "Thanks to whoever wrote this CppHtml.HC.Z" |
| Game images (mountain, BlackDiamond wolf) | taken from public-domain-photos.com |

## 2. What is bundled (`shared/bundled-fs/`)

### 2.0 Changes made after this audit

| Finding | Change |
|---|---|
| `Kernel/FontCyrillic.HC` was taken "without permission" (Doc/Credits.DD) | excluded in `build_bundled_fs.py` (`EXCLUDE_FILES`); not used by the apps |
| `Misc/Bible.TXT` labelled as Davis's public-domain work | index origin now "Project Gutenberg Etext #10, King James Bible (public-domain text; Gutenberg header retained), as distributed with TempleOS V5.03" |
| `Kernel/FontStd.HC` origin | index origin now notes the FreeDOS font data |
| `Misc/PCIDevices.DD` labelled as Davis's work (found 2026-10-17, documentation attribution audit) | index origin now "PCI vendor and device list from pcidatabase.com (Doc/Credits.DD), as distributed with TempleOS V5.03"; the document viewer labels it "Included with TempleOS" |
| `.DS_Store` files could be bundled | the tool now skips every path component starting with `.`; existing `.DS_Store` files deleted |
| `Demo/WebLogDemo/access_170622.log` is a real 2017 templeos.org web-server log with about 213 visitor IP addresses, not known to be scrambled (verification pass, V-09) | excluded in `build_bundled_fs.py` (`EXCLUDE_FILES`); WebLogDemo is not in the catalog. The drive now has 645 files. |
| About screen credited the system font to Terry A. Davis (verification pass, V-30) | About now credits FreeDOS for `Kernel/FontStd.HC` (per `Doc/Credits.DD`), and the Android About lists the bundled Kotlin standard library (Apache-2.0). The full Apache-2.0 text still has to be shipped with Android releases (owner task). |
| `PreludeDefines.HC` header named the cia-foundation commit | tool now takes the ISO tree only and its header says so; file regenerated |
| offensive content in original files (owner request) | the content-moderation manifest `tools/resource-packaging/moderation.json` (applied by `build_bundled_fs.py` through `moderation.py`) censors or redacts slurs and derogatory statements with visible markers in the text part of six files: `Adam/God/HSNotes.DD`, `Doc/Strategy.DD`, `Doc/Charter.DD`, `Demo/AcctExample/PersonalNotes.DD`, `Adam/God/Vocab.DD` (one word, index kept) and `Apps/Titanium/Titanium.HC` (identifier renamed); the index origin ends with "; modified: offensive content censored or redacted by TempleOS.app". These 6 files are therefore no longer byte-identical to the ISO; the originals stay in the ISO extraction (`docs/content-moderation/CONTENT_MODERATION.md`) |
| catalog labelled the project's examples "Public domain (CC0)" without a project license | label changed to "Same license as the TempleOS Mobile project", which is the Unlicense (`LICENSE`) |

After these changes the bundle has **646 files** (636 TempleOS + 10 TempleOS
Mobile). The tables below describe the state *before* the changes (647 files)
except where noted.

`shared/bundled-fs.index` has 702 lines: 55 directory (`D`) entries and 647
file (`F`) entries. Each `F` line is `F <TAB> path <TAB> size <TAB> sha256 <TAB> origin`.
All 647 files on disk match their index sha256 (0 mismatches).

### 2.1 By provenance (5th column)

| Provenance value | Files | Bytes |
|---|---|---|
| `TempleOS V5.03 (public domain, Terry A. Davis)` | 637 | 10,168,014 |
| `TempleOS Mobile` | 10 | 5,380 |
| **Total** | **647** | **10,173,394** |

All 637 TempleOS files are **byte-identical** to the ISO extraction in
`reference/templeos-iso/`. The 10 `TempleOS Mobile` files come from
`shared/home-src/Home/`: `Welcome.DD` and nine `Examples/*.HC` (Animation,
Arithmetic, CatchGame, Functions, Graphics, Hello, Loops, Palette, Sound).

### 2.2 By top-level directory

| Directory | Files | Bytes |
|---|---|---|
| `Adam/` | 119 | 979,336 |
| `Apps/` | 73 | 458,273 |
| `Compiler/` | 35 | 525,572 |
| `Demo/` | 212 | 2,502,417 |
| `Doc/` | 95 | 272,409 |
| `Downloads/` | 2 | 1,956 |
| `Home/` (TempleOS Mobile) | 10 | 5,380 |
| `Kernel/` | 74 | 577,997 |
| `Misc/` | 18 | 4,777,857 |
| root files (`StartOS.HC`, `MakeHome.HC`, `Home*.HC`, `Once.HC`, `Personal*.DD`) | 9 | 72,197 |

### 2.3 Program catalog

`shared/program-manifests/catalog.json` lists 96 programs: 87 with
`author` "Terry A. Davis" / `license` "Public domain (TempleOS)" and 9 with
"TempleOS Mobile contributors" / "Same license as the TempleOS Mobile project".
The license strings are assigned by `tools/resource-packaging/build_catalog.py`
(constants `TERRY` and `OURS`). The project's own code is released into the public
domain under the Unlicense (`LICENSE`), which is the license that string refers to.

## 3. Generated runtime files (`shared/runtime/`)

| File | Size | Generator | Input | Header says |
|---|---|---|---|---|
| `GrLib.HC` | 193,764 B, 7,288 lines | `tools/resource-packaging/build_runtime_lib.py` | ISO extraction | "Original TempleOS V5.03 graphics library (public domain, Terry A. Davis), from the official TempleOS.ISO (sha256 5d0fc944...)" |
| `KernelClasses.HC` | 8,147 B | `tools/resource-packaging/build_kernel_classes.py` | ISO `Kernel/KernelA.HH` | "Class layouts from TempleOS V5.03 Kernel/KernelA.HH (public domain, Terry A. Davis)" |
| `PreludeDefines.HC` | 45,808 B | `tools/resource-packaging/build_prelude_defines.py` | `Kernel/KernelA.HH`, `Adam/Gr/Gr.HH` | "cia-foundation/TempleOS commit c26482bb..." (see note) |
| `font8x8.bin` | 2,048 B | `tools/asset-extraction/extract_font.py` | `Kernel/FontStd.HC` | binary, no header |
| `Prelude.HC` | 40,923 B | **hand-written** (not generated) | n/a | "Class layouts and constants follow TempleOS V5.03 (public domain, Terry A. Davis); implementations are independent." Its graphics section is marked "Adapted from TempleOS V5.03 Adam/Gr/GrDC.HC and Adam/Gr/GrMath.HC". |

`GrLib.HC` copies top-level chunks verbatim from 15 files (`Adam/Gr/Gr.HH`,
`AMath.HC`, `GrMath.HC`, `GrBitMap.HC`, `GrPrimatives.HC`, `GrComposites.HC`,
`SpriteNew.HC`, `GrSpritePlot.HC`, `GrTextBase.HC`, `AMathODE.HC`, `ASnd.HC`,
`Menu.HC`, `Ctrls/CtrlsA.HC`, `CtrlsBttn.HC`, `CtrlsSlider.HC`): 347 chunks
kept, 34 excluded. The only textual patch removes `Option(OPTf_...,ON|OFF);`
("compiler options are not modelled"). Functions in `NATIVE_FAST` are renamed
`NAME_HC` and kept as a fallback/reference.

**Note on `PreludeDefines.HC`:** its header names the cia-foundation commit
because that commit is passed as the tool's third argument. Regenerating from
`reference/original-templeos` does **not** reproduce the shipped file (one
line differs: `STD_DISTRO_DVD_CFG`, where the mirror has a space `0x20`
instead of `0x1F`). Regenerating from `reference/templeos-iso` **does**
reproduce it byte-for-byte. The shipped content is therefore ISO-derived; the
header's source attribution is inaccurate.

## 4. Font origin

`shared/runtime/font8x8.bin` is the 256-glyph `sys_font_std[256]` table
parsed out of `Kernel/FontStd.HC` by `extract_font.py` (8 bytes per glyph, row
per byte, LSB = leftmost pixel). Running the tool on the ISO copy and on the
mirror copy of `FontStd.HC` both give sha256
`8176cae6f2909460e49e01528c2a3e46f66a0f869ed58d1aca656d1a55c9e49c`,
identical to the shipped file. Per `Doc/Credits.DD`, that font "is taken from
FreeDOS. It's public domain." No TrueType/web font is shipped.

## 5. ISO verification and the mirror

- `shasum -a 256 reference/iso/TempleOS.ISO` =
  `5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26`
  (17,350,656 bytes). The same value is hard-coded as `ISO_SHA256` in
  `extract_templeos_iso.py` (which prints a warning, but does not stop, on
  mismatch) and recorded in `reference/templeos-iso/MANIFEST.json`.
- Where the ISO was downloaded from is not recorded in the repository and
  could not be verified.
- The extractor is an independent RedSea reader + LZW expander written from
  `Kernel/BlkDev/FileSysRedSea.HC`, `Kernel/Compress.HC`, `Kernel/KernelA.HH`.
  The manifest lists 652 files, 645 of them stored compressed on the ISO.
  Re-running it on the ISO reproduced `reference/templeos-iso/` exactly
  (`diff -r` clean).

**Why the ISO and not the GitHub mirror.** The extractor docstring says the
mirror "has CRLF-normalized binary sections, which corrupts the sprites
embedded in DolDoc files". Comparing the 636 bundled TempleOS files that also
exist in the mirror (one, `Downloads/TemplarLetters/TSheikhs/171207SerialPort.DD`,
is missing there): 447 are identical and **189 differ**. Observed differences:

| Kind | Files |
|---|---|
| Text part: byte `0x1F` replaced by `0x20` (same length) | 152 |
| Binary record tail after the NUL (sprites etc.) differs; the mirror's tail is shorter in every case | 40 |
| Other text differences (`Demo/AcctExample/PersonalNotes.DD`, `Registry.HC`) | 2 |

(Categories overlap.) The sprite corruption is confirmed, but the exact
mechanism is **not**: none of the 40 ISO tails contains a `0D 0A` pair, and 16
contain no `0x0D` byte at all, so plain CRLF-to-LF conversion does not explain
all of it. Either way the mirror is not byte-exact and the ISO is used.

## 6. What is excluded and why

From the ISO's 652 files, `build_bundled_fs.py` excludes 15 (28,423,132 bytes):

| Rule in tool | Tool's stated reason | Files excluded | Bytes |
|---|---|---|---|
| prefix `Adam/AutoComplete/` | "26 MB word-completion dictionary for the desktop editor" | 7 | 27,656,592 |
| prefix `0000Boot/` | "x86 boot image" | 1 (`0000Kernel.BIN.C`) | 189,760 |
| prefix `Downloads/Linux/` | "host-side Linux helper tools" | 4 (`TOSZ`, `TOSZ.CPP`, `gw`, `make_tosz`) | 57,457 |
| suffix `.BIN`, `.BIN.C`, `.MAP`, `.ISO`, `.ISO.C` | (no comment; x86 binaries and symbol maps) | 3 (`Compiler/Compiler.BIN`, `Compiler/Compiler.MAP`, `Kernel/Kernel.MAP`) | 519,323 |
| file `MANIFEST.json` | extractor output, not TempleOS | n/a | n/a |

`build_runtime_lib.py` additionally drops `GrLib.HC` chunks that need x86,
hardware, the DolDoc engine, the window manager or the editor (explicit
`EXCLUDE` table with per-entry reasons, plus automatic exclusion of any chunk
using identifiers such as `DocPut`, `CDoc`, `InU8`, `OutU8`, `PopUpForm`,
`CCmpCtrl`). `build_kernel_classes.py` makes members of absent subsystems
(heaps, drives, compiler, debugger) opaque.

## 7. Third-party reference material

| Reference | License status (details in `docs/upstream-research.md`) | Code in this project? |
|---|---|---|
| ParkerrDev/TempleOS-Web | no license file, no license grant for its code | **No** |
| ParkerrDev/HolyC-wasm | MIT claimed in README and package.json, no LICENSE file | **No** |
| ParkerrDev/HEMU | no license file or statement | **No** |
| ParkerrDev/HolyC-fmt | MIT claimed in package.json only, no LICENSE file | **No** |
| cia-foundation/TempleOS | TempleOS public domain; no LICENSE file | Only via `PreludeDefines.HC` header text (content is ISO-identical, see 3) |

How "no code copied" was checked:

1. **Hash comparison.** sha256 of every file of 16 bytes or more in the four
   ParkerrDev checkouts (631 files, `.git` and `node_modules` skipped) against
   every file in `shared/`, `tools/`, `temple_os_kotlin/`, `temple_os_swift/`
   (822 files, build directories skipped). 20 identical files were found. All
   are original TempleOS files that TempleOS-Web also redistributes under
   `games/upstream/` (e.g. `TinkerOS/Talons.HC` = `Demo/Games/Talons.HC`,
   `AustinArchive/Temple/Vocab.DD` = `Adam/God/Vocab.DD`, `TinkerOS/Apps/*/Run.HC`).
   This project's copies are byte-identical to the ISO extraction, so they come
   from the ISO.
2. **Identifier search** (`grep -rIl`) in the same project directories for
   `ParkerrDev`, `TempleOS-Web`, `holyc-wasm`, `HolyC-wasm`, `HEMU`,
   `createHost`, `__host_`, `BrowserMouseCapture`, `PNG2GR`, `OffscreenCanvas`,
   `WebAssembly`. Only three hits: the About text in Kotlin `ui/SmallApps.kt`
   and Swift `UI/SmallApps.swift` (credit line), and `temple_os_kotlin/README.md`
   ("no JavaScript/WebAssembly").
3. No `.js`, `.mjs`, `.html`, `.ttf`, `.woff*` or `.wasm` file exists in `shared/`.

This rules out verbatim file copies and the listed identifiers. It cannot by
itself rule out a hand-translated fragment; no such case is known.

## 8. Attribution shown in the apps

The About window (`AboutApp` in Kotlin `ui/SmallApps.kt`, same text in Swift
`UI/SmallApps.swift`) shows, with DolDoc colour codes removed:

> TempleOS was created by Terry A. Davis (1969-2018), who wrote its kernel,
> compiler, HolyC language, graphics, games and documentation, and dedicated it
> to the public domain.
>
> This app is an independent mobile recreation of the TempleOS user
> environment. It is not an official TempleOS release, is not affiliated with
> Terry A. Davis or his estate, and does not boot the real TempleOS kernel or
> emulate a PC.
>
> Credits
> - TempleOS V5.03, programs, font, games, docs: Terry A. Davis (public domain).
> - Bible text (Misc/Bible.TXT): as distributed with TempleOS.
> - TempleOS-Web by ParkerrDev was studied as a behavioural reference; no code from it is included.
> - Native implementation: TempleOS Mobile contributors.

It also says the original libraries, games, demos and documentation "are
included unmodified from the official TempleOS ISO" (verified: section 2.1),
and that the app has "no network access, no accounts, no analytics and no ads"
(the Android manifest comment says no permissions are requested; the Swift
app's entitlements were not checked here).

## 9. Independence statement

TempleOS Mobile Classic is an independent project. It is not an official
TempleOS release and is not affiliated with, endorsed by, or connected to
Terry A. Davis or his estate. It is also not affiliated with the authors of
TempleOS-Web, HolyC-wasm, HEMU, HolyC-fmt or the cia-foundation mirror.

The license of TempleOS Mobile's own source code (Kotlin, Swift, tools,
prelude) could not be determined: no LICENSE file was found at the project
root or in `temple_os_kotlin/`, `temple_os_swift/`, `tools/` or `shared/`.

## 10. Reproducing the assets

Prerequisites: Python 3, `reference/iso/TempleOS.ISO` with the sha256 above.
Run from the repository root. (`build_bundled_fs.py` now skips dotfiles such
as `.DS_Store`; the `find ... -delete` line below is kept as a harmless extra.)

```sh
shasum -a 256 reference/iso/TempleOS.ISO   # expect 5d0fc944...ba26

# 1. ISO -> byte-exact file tree (+ MANIFEST.json)
python3 tools/asset-extraction/extract_templeos_iso.py reference/iso/TempleOS.ISO reference/templeos-iso

# 2. Bundled C: drive + index (rebuilds shared/bundled-fs/ from scratch)
find shared/home-src -name .DS_Store -delete
python3 tools/resource-packaging/build_bundled_fs.py reference/templeos-iso shared

# 3. Program catalog (reads shared/bundled-fs/)
python3 tools/resource-packaging/build_catalog.py shared

# 4. Runtime files
python3 tools/resource-packaging/build_runtime_lib.py reference/templeos-iso shared/runtime/GrLib.HC
python3 tools/resource-packaging/build_kernel_classes.py reference/templeos-iso shared/runtime/KernelClasses.HC
python3 tools/resource-packaging/build_prelude_defines.py reference/templeos-iso shared/runtime/PreludeDefines.HC
python3 tools/asset-extraction/extract_font.py reference/templeos-iso/Kernel/FontStd.HC shared/runtime/font8x8.bin
```

Step 4's `build_prelude_defines.py` takes the **ISO** tree (it no longer
accepts a commit argument).

### 10.1 Verification result

Each step was run into a scratch directory and compared with the shipped
files:

| Output | Result |
|---|---|
| `reference/templeos-iso/` | identical (`diff -r`) |
| `shared/bundled-fs/` and `bundled-fs.index` | identical apart from the two `.DS_Store` entries described above |
| `program-manifests/catalog.json` | identical (96 programs) |
| `runtime/GrLib.HC` | identical |
| `runtime/KernelClasses.HC` | identical (36 classes) |
| `runtime/PreludeDefines.HC` | identical from the ISO tree (1,600 defines); differs by one line from the mirror |
| `runtime/font8x8.bin` | identical |

The Android build copies `shared/` into APK assets via the `syncTempleAssets`
Gradle task (per `temple_os_kotlin/README.md`); the app builds were not run
for this document.

## 7. Verification pass (2026-10-16): items for human review

The independent recheck (`docs/verification-pass/`) did the following:
- hashed all 646 then-bundled files against the ISO extraction: 633 identical, 3 censored, 10 project-authored (2026-10-18: 6 moderated, `docs/content-moderation/CONTENT_MODERATION.md`);
- compared shipped code with `reference/` (TempleOS-Web, HolyC-wasm, HEMU, holyc-fmt): no copied code.

It flagged these items for **legal or content review**. They are not resolved by engineering:

| Item | Concern |
|---|---|
| `Adam/God/HSNotes.DD` | Remarks about religious, ethnic and sexual-orientation groups. Possible store content-policy issue (Apple 1.1.1, Google Play Inappropriate Content). Owner decision C5. |
| `Misc/Bible.TXT` | Keeps the 1989 Project Gutenberg "Small Print": a trademark-license clause if distributed for profit under the PG name. UK Crown rights in the KJV. |
| `Adam/AMathODE.HC` (also compiled into `GrLib.HC`) | "adapted from Numeric Recipies in C" (`Doc/Credits.DD`). Is it an algorithm-only derivation? |
| Mountain / BlackDiamond sprites | "watermarked photos" from public-domain-photos.com (`Doc/Credits.DD`). Public-domain status unverified. |
| `Misc/PCIDevices.DD`, `Demo/ToHtmlToTXTDemo/ToHtml.HC`, ATA definitions, speaker code | third-party origins named in `Doc/Credits.DD` |
| Terry A. Davis's public-domain dedication | informal ("public domain, not GPL"). Its robustness outside the US is not established. |
| "TempleOS" name | trademark status unknown. Branding review C4. |

## 11. Store-readiness audit additions (2026-10-23)

Full review: `docs/store-audit/LICENSING_AND_IP_REVIEW.md`.

- **fdlibm (iOS math).** `TempleCore/HolyC/FdLibm.swift` previously described itself as a line-for-line port of
  OpenJDK's `java/lang/FdLibm.java`, which is GPLv2 with the Classpath exception. It was replaced on 2026-10-23
  by a port written directly from Sun's fdlibm 5.3 C sources from netlib (`https://netlib.org/fdlibm/`, permissive
  notice "Permission to use, copy, modify, and distribute this software is freely granted, provided that this
  notice is preserved"; the notices are kept in the file header). The new file was written without reading the
  JDK source or the previous Swift body. It is bit-identical on the 38,188 `FdLibmTests` vectors and on 1.8 million
  random inputs compared with `StrictMath`. Android uses the platform's `StrictMath` and is unaffected.
- **App icon.** `TempleOS.png`, the source of both app icons, carries an OpenAI C2PA record (ChatGPT `gpt-image`,
  2026-10-16) and recreates the TempleOS logo. The website's statements that the icon is "project-original" /
  "created for this project" are therefore not accurate. Owner decision pending (see the store-audit review).
