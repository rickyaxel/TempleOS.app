# Native UI design

> **Verification pass (2026-10-16):**
> - Held on-screen key buttons auto-repeat at TempleOS's keyboard rate (`KbdTypeMatic(0)`: 250 ms, then 30/s).
> - Arrow and Home/End keys use TempleOS scan codes without the E0 bit (V-28).
> - In landscape, a program window covered by another window draws its picture into the desktop surface at its own z-position (V-29).
> - Open: menu rows and action buttons are about 23–24 dp, below the 48 dp / 44 pt minimum (V-32).


Both apps draw the TempleOS Mobile desktop the same way: the shared `ui/`
code (Kotlin `core/ui`, Swift `TempleCore/UI`) renders everything into an
indexed 16-colour framebuffer using the TempleOS 8×8 system font, and the
platform layer only scales that framebuffer, overlays program frames and
delivers input. No platform widgets, no translucency, no rounded cards, no
animations — the look comes from TempleOS's own palette, font and
double-line window borders.

## 1. Rendering model

| Element | How it is drawn |
|---|---|
| Desktop, windows, menus, dialogs, text apps | Shell `Surface` in *logical pixels* (1 font pixel = 1 logical pixel). |
| Scale | integer factor chosen so the short side has at least 360 logical px (`min(w, h) / 360`, clamped so the logical size stays ≥ 320×240); user override in Settings ("Display scale"). Nearest-neighbour sampling keeps the font crisp. |
| Program graphics (640×480) | platform overlay: Android `Canvas.drawBitmap` into the window's 4:3 canvas rect; iOS a `CALayer` per program. Aspect ratio is always preserved (`fit43`); never stretched. Optional "crisp" (nearest) or smooth scaling (Settings). |
| Palette | TempleOS's 16 colours; programs that change their palette (`GrPaletteColorSet`) are drawn with their own palette. |
| Safe areas / cutouts / keyboard | passed to the shell as insets; the top bar sits below the status bar, content above the home indicator and above the soft keyboard. |

## 2. Landscape: TempleOS desktop

- Overlapping windows with TempleOS double-line borders and a blue title
  strip; the focused window is drawn last.
- Drag the title strip to move, drag the bottom-right corner to resize,
  maximize/restore and **Tile windows** from the window menu.
- Top bar: blue **MENU** chip (start menu), one tab per window, clock.
- Running a 640×480 program: the frame is fitted 4:3 in the window; if the
  side margins are at least 96 px the on-screen controls go in the left
  margin, so they never cover the picture.

## 3. Portrait: window deck

- One window fills the content area; the other open windows are tabs in the
  top bar (focused tab first). When they do not fit, a **+N** chip opens a
  list of all windows.
- Window chrome stays TempleOS-style (≡ MENU button, title, red X close).
- Programs: frame at the top (4:3, full width), controls below it.
- A **key row** at the bottom for text apps (Terminal, Editor, programs
  waiting for keys): `ESC TAB CTRL ALT ← ↑ ↓ → HOME END ⌨`. CTRL/ALT latch for
  the next key; ⌨ shows/hides the soft keyboard. The arrow glyphs are drawn
  from a small shell-only glyph table because TempleOS's font leaves control
  codes 0x10–0x1B blank.

## 4. Rotation and state

Rotation only changes layout. The shell keeps one window list; `resize()`
re-lays out windows. Kernels keep running on their threads, editor buffers
and terminal state are untouched, and nothing restarts. Android declares the
relevant `configChanges` so the Activity is not recreated; iOS keeps the same
view controller.

## 5. Touch input

| Gesture | Meaning |
|---|---|
| Tap | click (buttons, menus, file rows, document links, editor cursor) |
| Long press (≥ 550 ms) | context menu (e.g. file rename/copy/move/delete/restore) |
| Drag | scroll (documents, files, editor, console); move/resize windows in landscape |
| Touch on a program's frame | TempleOS mouse: down = button pressed, move = drag, up = release; coordinates mapped to 640×480 |
| L-CLICK / R-CLICK toggle | selects which mouse button canvas touches press |
| Second finger while the first is held | delivered to the program's on-screen controls (two buttons at once) |

## 6. Keyboards

- **Soft keyboard**: shown automatically while the focused app needs text
  (editor, terminal, a program waiting in `GetS`/`GetKey`, a text dialog),
  hidden otherwise; the key-row ⌨ key overrides. Autocorrect, suggestions
  and smart punctuation are off; input outside Latin-1 becomes `?`.
- **Hardware keyboard**: arrows, Page Up/Down, Home/End, Insert, Delete,
  Escape, F1–F10, Tab, Enter, Backspace and characters with Shift/Ctrl/Alt are
  mapped to TempleOS scan codes (`Keys.kt`/`Keys.swift`), with real key-up
  events for games.
- Android back / iOS ⌘-. close the open menu or dialog.

## 7. Game controls

Generated per program from its catalog entry and its own TempleOS menu:

- D-pad (arrow keys) when the program uses arrows.
- SPACE, ENTER, ESC buttons.
- Buttons for the program's menu shortcuts (e.g. BattleLines: Abort,
  TimeLapse, TapMode), sending the same messages TempleOS's menu would.
- L-CLICK/R-CLICK toggle for canvas touches.
- Held buttons send key-down and key-up; focus loss, rotation and going to the
  background release everything so no key sticks.

## 8. Not implemented (honest list)

- Pinch-zoom and pan of program frames, immersive full-screen mode.
- Virtual analog joystick; user-configurable control placement and opacity
  (a `controlsOpacity` setting exists in the settings model but has no UI and
  is not applied yet).
- Precision cursor mode for mouse-driven programs.
- Double-tap gestures.
