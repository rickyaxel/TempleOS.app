# Localization and authenticity: where translation stops

This page is for anyone (developer or coding agent) about to translate something in TempleOS.app. It
explains which English text is a localization defect and which English text is TempleOS itself and
must stay as it is. It complements [localization.md](../localization.md), which describes the
mechanics (catalogs, `tr`, `tr8`, text runs).

## The rule

**Translate the presentation layer, never the execution semantics.**

TempleOS.app has two layers of text:

1. **TempleOS** — Terry A. Davis' operating system as distributed on the V5.03 ISO: HolyC source, the
   compiler and kernel behavior, DolDoc documents, program output, menus defined by the programs,
   file names, the Bible text, God's vocabulary. It is preserved, not localized.
2. **TempleOS.app** — the mobile shell written for this project around it: windows, menus the app
   adds, dialogs, toasts, settings, the touch controls, screen-reader labels, and the explanatory
   text the project wrote. It is localized into every catalog.

A string's language never decides what the software does. Buttons carry their scan codes, wheel
deltas and actions separately from their labels; programs are found by id and path, not by title;
nothing compares a localized string to make a decision.

## How to classify a string

Ask, in order:

1. Is it in the TempleOS V5.03 distribution (`shared/bundled-fs`, `reference/original-templeos`)?
   **Preserve.**
2. Is it produced at run time by a preserved program or by the HolyC compiler/kernel emulation
   (console output, compile errors, exception names such as `Break`, `OutMem`)? **Preserve**; the
   app may translate the frame around it (`Ended: {reason}`, `Line {line}: {message}`).
3. Is it a name or technical token: TempleOS, HolyC, DolDoc, `C:/...` paths, file names, key caps,
   engine names (Pure Terry, Pure Kotlin, Pure Swift), CP437? **Preserve.**
4. Was it written by this project and is it shown to the user or a screen reader? **Translate**
   (catalog key, `tr`, or `tr8` for console text).
5. Is it a developer diagnostic only reachable in debug/benchmark builds or logs? **Not required.**

If the evidence is insufficient, preserve and document the ambiguity.

## Content classes in this codebase

| Class | Policy | Examples (files) |
|---|---|---|
| App navigation, menus, dialogs, toasts | Translate | `menu.*`, `dialog.*`, `toast.*` (`Shell`, `Widgets`) |
| App buttons and touch controls | Translate | `editor.button.*`, `files.button.*`, `controls.button.*` (`ProgramHost` `GameControls`) |
| App lifecycle messages | Translate | `program.ended`, `program.starting`, `program.title_suffix.*` (`ProgramApp`) |
| App errors | Translate | `fs.error.*` (an `FsError` carries its catalog key), `error.generic` |
| Screen-reader text | Translate | `a11y.*`, `key.*`, `char.*`, `controls.a11y.*` |
| App-written program notes and descriptions | Translate | `catalog.<id>.note`, `catalog.note.*`, `catalog.author.project` |
| App-written documentation notices | Translate | `doc.notice.*` |
| Original HolyC source and comments | Preserve | `shared/bundled-fs/**/*.HC` |
| Original program output and menus | Preserve | console cells, `MenuPush` labels shown on game buttons (e.g. RainDrops `OpenUpper`) |
| Compiler and kernel messages | Preserve (frame translated) | `Compile error: ...`, exit reasons such as `Break`, `'OutMem'` |
| Original documents, Bible, vocabulary | Preserve (God Words displays the picked entry in the UI language; the pick never depends on it, see [localization-vocabulary.md](../localization-vocabulary.md)) | `Doc/*.DD`, `Misc/Bible.TXT`, `Adam/God/Vocab.DD` |
| Original program titles and source excerpts | Preserve | catalog `title`, `source.*` descriptions, `index.*` headings |
| File and folder names, paths | Preserve | `C:/Home`, `Untitled.HC`, `New.HC`, `Folder` (ASCII defaults on the TempleOS drive) |
| Key caps | Preserve (spoken name translated) | `ESC TAB CTRL ALT SHIFT SPACE ENTER BKSP DEL HOME END PGUP PGDN INS F1-F12 FN SYM ABC EXT HIDE CAPS TOS` |
| Names | Preserve | TempleOS, HolyC, DolDoc, TempleOS.app (`{app}`), Terry A. Davis, Pure Terry/Kotlin/Swift |
| Product-required brand copy | Preserve (owner decision) | `Brand.INTRO_LINES` and the empty-desktop `MENU` chip |
| Developer diagnostics | Not required | perf log lines, `BenchMode`, input diagnostics in debug builds |

## Decisions made in the 2026-11-08 audit

- **Game controls.** The d-pad arrows, `SPACE`, `ENTER`, `ESC`, `CTRL` and `SHIFT` are keys and keep
  their key caps. The buttons named after a program's own menu entries show the program's text. The
  touch-mode toggle (`L-CLICK` / `R-CLICK` / `MOVE`) and the wheel buttons (`WHL+` / `WHL-`) are not
  keys: they are this project's controls, so their labels are translated (`controls.button.*`). Their
  screen-reader text used to be found by comparing the visible English label; it is now attached to
  the button, so translating a label can never change what the screen reader says or what the button
  sends.
- **Program end line.** The exit reason a kernel reports (`Break`, a HolyC exception, a compile error)
  is engine text and stays in `Kernel.exitMessage` and in the console. When the user chose **Stop
  program**, the app shows its own `program.ended` line instead of the engine's English reason; a
  failure of the host runtime shows `Ended: {error.generic}`. Programs that catch `Break` themselves
  (Halogen, for example) still end their own way.
- **Terminal banner.** The word "Terminal" after the app's name now comes from `app.terminal.title`
  through `tr8`; the commands `Dir;` and `Help;` stay HolyC.
- **Kernel console lines.** `Program stopped (Break).` and other lines the kernel emulation writes
  into a program's console are kernel output and stay English (the kernel does not depend on the UI
  language; benchmarks and tests compare it).
- **New HolyC file template.** The editor's starter program (`//New HolyC program. Press RUN...`) is
  HolyC source saved as CP437 bytes; it stays English.
- **Picture decoder details.** `Cannot open picture: {detail}` is translated; `{detail}` is the GR
  decoder's technical reason.

## Right-to-left languages

Application containers (menus, dialogs, text) align to the end in Arabic, Persian, Urdu and Hebrew.
The TempleOS desktop, program frames, the HolyC editor and the TempleOS keyboard are not mirrored, and
the d-pad's left arrow always sends the left-arrow scan code. A localized label never changes a
coordinate or a direction.

## Checks that enforce this

- `python3 tools/l10n/hardcoded_audit.py`: literals passed to UI calls (including the game controls'
  `Btn`), literal screen-reader labels in the platform layers, and `FsError`s without a catalog key.
  Reviewed exceptions are listed in the script with their reasons.
- `LocalizationRegressionTest` / `LocalizationRegressionTests`: game-control input parity in all 89
  locales, the localized end line after Stop with the engine message preserved, authors, the
  Terminal banner.
- `python3 tools/l10n/validate.py`: catalogs complete, placeholders and line breaks identical.
