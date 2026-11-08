# Localization string inventory

Every application-owned string of both apps lives in one registry, shared by the Swift and Kotlin
clients: `shared/runtime/l10n/en.json` (the English source) and one catalog per language beside it.
Both apps bundle these same files and look strings up by the same keys (`tr`, `tr8`), so a key means
the same thing on iOS and Android by construction. This page summarizes the registry; the JSON files
are the machine-readable inventory.

State on 2026-11-08: **386 English keys**, **73 catalogs** (72 translations plus English) serving
**89 locales**. `python3 tools/l10n/validate.py` reports every catalog complete, with identical
placeholders and line breaks. The per-catalog table is
[localization-coverage.md](../localization-coverage.md) (`validate.py --report`).

## Keys by namespace

| Namespace | Keys | Where it appears (both platforms) |
|---|---|---|
| `menu` | 31 | Start menu, window menus, edit menus, program menus |
| `files` | 33 | Files window: toolbar, rows, menus, dialogs, screen-reader labels |
| `catalog` | 48 | Program catalog: group headings, status, licenses, author, app-written notes and descriptions |
| `char` | 33 | Spoken names of TempleOS keyboard symbols |
| `key` | 24 | Spoken names of keys (the key caps themselves are not translated) |
| `program` | 22 | Program windows: starting, ended, paused, menus, About this program, unsupported dialog |
| `doc` | 19 | Document viewer: menus, link errors, provenance notices |
| `about` | 17 | About & Credits |
| `color` | 16 | Paint colors and the desktop color setting |
| `editor` | 14 | HolyC editor toolbar, menus, dialogs, error line, screen-reader position |
| `fs` | 14 | File-system errors (an `FsError` carries its key and arguments) |
| `settings` | 12 | Settings rows |
| `a11y` | 11 | Screen-reader labels for windows, menus, text fields |
| `god` | 11 | God Words window |
| `paint` | 11 | Paint tools and dialogs |
| `controls` | 10 | Game controls: touch-mode toggle and wheel buttons (labels and spoken names) |
| `terminal` | 10 | Terminal banner, menus, screen-reader output |
| `app` | 8 | Window titles |
| `dialog` | 8 | Shared confirmations |
| `button` | 7 | Shared dialog buttons |
| `engine` | 6 | Pure Terry / native engine availability messages |
| `games`, `toast`, `value` | 5 each | Games window, toasts, setting values |
| `input` | 2 | Character-input policy messages |
| `error`, `language`, `topbar`, `window` | 1 each | Generic error, language filter hint, MENU chip, window menu chip |

## Keys added on 2026-11-08

| Key | English | Context |
|---|---|---|
| `controls.button.left_click` | `L-CLICK` | Game controls: touch-mode toggle, a touch on the picture is a left click |
| `controls.button.right_click` | `R-CLICK` | Same toggle: a touch is a right click |
| `controls.button.hover` | `MOVE` | Same toggle: a touch only moves the pointer |
| `controls.button.wheel_up` | `WHL+` | Wheel button (programs that read the wheel, e.g. BattleLines) |
| `controls.button.wheel_down` | `WHL-` | Wheel button |
| `catalog.author.project` | `{app} contributors` | About this program: author of the examples written for this project |
| `fs.error.path_too_long` | `Path is too long` | Save as after a document program ends: the chosen path does not fit |

Notes for translators and reviewers:
- The five control labels are short on purpose: a button in the control grid has room for about 8
  characters of the TempleOS font (64 logical px on a 360-px-wide screen; non-Latin scripts are drawn
  with the system font and usually fit more). A label that needs more space takes two grid cells.
  They are uppercase like the other TempleOS buttons, and use the same terms as the catalog's
  `controls.a11y.*` sentences. All five are listed in each catalog's `$review`.
- `fil` keeps `L-CLICK` and `R-CLICK`, as its `controls.a11y.*` sentences already use the English
  loanword "click".
- The `WHL+`/`WHL-` labels keep the `+`/`-` at the end in every language.

## Shared terms (semantic glossary)

These concepts have one key each, used by both apps, so iOS and Android cannot drift apart. Keep the
distinctions when translating:

| Concept | Key | Not to be confused with |
|---|---|---|
| Run a program or the editor's code | `editor.button.run`, `files.menu.run`, `button.run_in` | Play, Resume |
| Stop a running program | `menu.stop_program` | Close (window), Pause |
| Pause / resume a program | `program.menu.pause`, `program.menu.resume` | Stop |
| Restart a program from the start | `program.menu.restart` | Reset settings (no such action exists) |
| Program has ended | `program.ended`, `program.ended_with`, `program.title_suffix.ended` | Program paused |
| Close a window | `menu.window.close`, `a11y.close_window` | Delete, Stop |
| Close all windows | `settings.close_all` | Reset |
| Delete a file | `files.menu.delete`, `button.delete` | Close, Restore original |
| Restore a bundled original | `files.menu.restore_original` | Undo |
| Show / hide the TempleOS keyboard | `program.menu.show_keyboard`, `program.menu.hide_keyboard`, `key.hide_keyboard`, `key.show_hide_keyboard` | — |
| Left click / right click / move the pointer | `controls.button.*`, `controls.a11y.*` | The d-pad's left/right arrows (`key.left`, `key.right`) |

## Intentional English (not leaks)

See [TEMPLEOS_LOCALIZATION_AUTHENTICITY_BOUNDARY.md](TEMPLEOS_LOCALIZATION_AUTHENTICITY_BOUNDARY.md)
for the full classification. In short: TempleOS content (source, output, menus, documents, titles),
compiler and kernel messages, names, paths and file names, key caps, and the product-required brand
intro (`Brand.INTRO_LINES`).

## Regenerating the machine-readable reports

- `python3 tools/l10n/validate.py --report docs/localization-coverage.md`
- `python3 tools/l10n/census.py --out <dir> --baseline HEAD` writes `census.json` (every locale:
  catalog, script, platform tags, coverage, review flags), `RECENT_STRINGS.tsv` (keys added or changed
  since the baseline, and catalogs still identical to English), `ENGLISH_COPIES.tsv` and
  `UNREGISTERED_METADATA.tsv` (program metadata outside the catalogs and its classification).
