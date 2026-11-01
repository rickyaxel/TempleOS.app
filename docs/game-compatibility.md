# Game compatibility

> **Current status — 2026-10-24:** the source-only restoration, [generated catalog](bundled-app-catalog.md), inventory and verification supersede the historical baseline below. All former catalog source-only entries now have executable HolyC and genuine compiled Swift/Kotlin paths. Four programs retain explicit partial limitations. The older interpreter-only architecture and omission statements below are retained as historical audit context.

> **Verification pass (2026-10-16), `docs/verification-pass/GAME_VERIFICATION.md`:**
> - **Arrow keys were broken until this pass** (V-28). The d-pad and hardware arrow keys sent scan code `0xC8` instead of TempleOS's `0x48`, so 17 games that read `sc.u8[0]==SC_CURSOR_*` ignored them.
> - Held on-screen keys now auto-repeat like TempleOS's keyboard (250 ms, then 30/s; V-26).
> - Played after the fixes (Android emulator): CastleFrankenstein (walk, turn, pause/resume/exit), Varoom (accelerate, steer, 10× rotation stress) and X-Caliber (thrust, turn).
> - An automated gameplay test on both runtimes walks CastleFrankenstein's player.

> **Fidelity audit (2026-10-17), `docs/fidelity-audit/`:** every game
> was compared with its original source (and some with the original TempleOS on a reference VM);
> fixes FA-01..FA-28 (window geometry, scheduling, mouse and keyboard semantics, line input, scroll
> bars, …) and per-game records are there. Where this page and the audit disagree, the audit is newer.


All games are the **original TempleOS V5.03 HolyC sources**, unmodified (Titanium has one
offensive identifier renamed), run
by the TempleOS Mobile interpreter (no native re-implementations of games).
The Games menu lists the 30 programs in `Demo/Games` plus the game-like
programs from `Apps` (KeepAway, Strut, Titanium, X-Caliber, ToTheFront).

## 1. How compatibility was checked

| Level | What it shows | Coverage |
|---|---|---|
| A. Automated sweep (both runtimes) | the program compiles, starts and runs 3 s of virtual time with synthetic mouse/keyboard input without a compile error or unhandled exception | all 35 games |
| B. Cross-platform frame parity | Kotlin and Swift produce the same final frame for the same input | all 35 (identical except X-Caliber, RocketScience, Squirt: last-bit float differences) |
| C. Interactive check on a running app | a person-like input sequence on the Android emulator (release build) or iOS simulator, judged from screenshots | BattleLines, Varoom, Maze, TicTacToe, FlapBat (Android); BattleLines (iOS, automated XCUITest) |

Level A/B commands: `./gradlew :core:test --tests '*SweepTest*' -Dtempleos.sweep=Catalog -Dtempleos.memmb=64`
(Kotlin), `TEMPLEOS_MEMMB=64 TEMPLEOS_SWEEP=Catalog swift test -c release -Xswiftc -enable-testing --filter SweepTests`
(Swift), then `python3 tools/parity/compare_frames.py Catalog`.

"Runs" (level A) is not the same as "verified playable" (level C). Only the
games in level C were actually played.

## 2. Results

| Game | A: sweep | C: interactive check | Notes |
|---|---|---|---|
| BattleLines | runs | **played** (Android emulator, iOS simulator): popup, troops move, pause/resume; 30 FPS on the emulator | holding a button pulls (left) or pushes (right) the troops toward the pointer with a force set by the wheel (`BattleLines.HC:258`, `j=400000000*ms.pos.z`): WHL+/WHL- buttons (fidelity audit FA-19) |
| BigGuns | runs | — | |
| BlackDiamond | runs | — | |
| BomberGolf | runs | — | |
| CastleFrankenstein | runs | — | |
| CharDemo | runs | — | |
| CircleTrace | runs | — | |
| Collision | runs | — | a double click ends it, as on TempleOS (double click = ESC, fidelity audit FA-05; seen on the reference VM) |
| Digits | runs | — | text mode |
| DunGen | runs | — | |
| ElephantWalk | runs | — | draws on the screen (fidelity audit FA-11) |
| FlapBat | runs | **played** (Android emulator): flapping lifts the bat | a flap's lift grows with the time since the last one, up to `FLAP_TIME` (0.5 s): `delta_phase=-0.005*Min(1.0,(tS-flap_time)/FLAP_TIME)` (`FlapBat.HC:180`; `Min` is F64, `Kernel/KernelC.HH:545`), so quick presses give proportionally less lift |
| FlatTops | runs | — | |
| Halogen | runs | — | |
| KeepAway | runs | — | needed `#define` line continuation |
| MassSpring | runs | — | |
| Maze | runs | **played** (Android emulator): walls drawn by dragging, solver runs from a right-click (R-CLICK toggle) | |
| RainDrops | runs | — | |
| RawHide | runs | — | |
| Rocket | runs | — | |
| RocketScience | runs | — | |
| Squirt | runs | — | heaviest physics (ODE solver) |
| Strut | runs | — | needed define lists |
| Talons | partial | — | needs 72 MiB program memory (Android per-app heap class ≥ 256 MB / iOS ≥ 2.6 GB RAM, 2026-10-20); computes terrain for a minute or more before play (about 90 s on the OPPO CPH2669 with the interpreter). Before the fidelity audit (FA-36) it ran out of memory while generating terrain on every device |
| TheDead | runs | — | |
| TicTacToe | runs | **played** (Android emulator): X/O placed by taps | two players take turns (`TakeTurn(player)`, `TicTacToe.HC:47`); there is no computer player |
| Titanium | partial | — | starts, then stops with a memory fault in `DCLighting` while drawing; one of its sprites is corrupt in the original ISO |
| TreeCheckers | runs | — | two players take turns (`cur_player`, `TreeCheckers.HC:25`) |
| Varoom | runs | **observed** (Android emulator): 3D road renders at 30 FPS; steering not exercised | |
| Wenceslas | runs | — | |
| Whap | runs (ends on synthetic input) | — | |
| X-Caliber | runs | — | needed fall-off-the-end return value semantics |
| Zing | runs | — | |
| ZoneOut | runs | — | |
| ToTheFront | unsupported | — | needs the DolDoc document API (`CDoc`); hidden from the menu |

## 3. Controls on phones

Each game gets on-screen controls derived from its own TempleOS menu and
catalog entry (D-pad for arrow-key games, SPACE/ENTER/ESC, the game's menu
shortcuts, and an L-CLICK/R-CLICK toggle for touches on the picture). Holding
two buttons at once works (multi-touch). A hardware keyboard works on both
platforms. See `native-ui-design.md` §7.

Bugs found and fixed while playing (all fixed on both platforms, with
regression tests):

- drags on a game's picture were dropped after the first point (Maze could
  not draw);
- very short taps were invisible to games that poll the mouse button or key
  state once per frame (TicTacToe, key-state games) → press/release latching;
- on iOS, after a dialog the next taps were routed as "second finger"
  touches (new touch ids per touch) → gestures end when a popup consumes them.

## 4. Performance in games

Measured numbers and conditions are in `performance.md`. Summary: on the
Android emulator (release build) BattleLines and Varoom run at TempleOS's own
29.97 FPS; programs whose window is hidden pause automatically.

## 5. Not yet verified

- 29 of the 35 games have only automated (level A/B) evidence.
- No game has been played on a physical phone yet: the attached Android phone
  was locked during testing, and no iPhone was attached.
- Sound was not verified by ear (tones are generated; see `testing.md`).
