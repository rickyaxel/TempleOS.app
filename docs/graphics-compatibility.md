# Graphics compatibility

## 1. Model

Each program draws exactly as on TempleOS: into `CDC` device contexts with
the original graphics library (`Adam/Gr/*.HC`, compiled from the ISO into
`shared/runtime/GrLib.HC`). The kernel keeps TempleOS's screen layout:

- 640×480, 16 colours, TempleOS palette (programs may change it with
  `GrPaletteColorSet`);
- a text layer (80×60 cells of the 8×8 font) under the graphics layer, as
  `gr.text_base`, with DolDoc colours, inversion, underline and blink;
- `gr.dc` (persistent screen) and per-window `draw_it` callbacks run every
  frame at `WINMGR_FPS` (≈29.97 Hz) on `gr.dc2`;
- depth buffers, 3D transforms (`Mat4x4*`, `DCTransform`), lighting,
  symmetry, dithering, ROPs (`ROP_EQU`, `ROP_XOR`, `ROP_COLLISION`,
  `ROP_MONO`), collision counting, extents, brushes, flood fill, sprites and
  meshes (`Sprite3`, `Gr3Mesh`, `SpriteInterpolate`, `SpriteTransform`), ODE
  physics (`CMathODE`), controls (`CCtrl` sliders/buttons), menus.

Frames are published to the UI thread and scaled to the window with the
aspect ratio preserved.

## 2. Native fast paths

The hottest routines run natively; each is checked against the original HolyC
(kept as `NAME_HC`) by `RasterDiffTest` on random inputs, comparing pixels,
depth buffer, collision count, extents, return value and random-number use.

| Routine | Diff test |
|---|---|
| `GrPlot`, `GrPlot1`, `GrPeek` | 0 mismatches |
| `GrRect`, `GrHLine`, `GrVLine` | 0 mismatches |
| `GrBlot`, `GrBlot3` | 0 mismatches |
| `GrFillTri0` | 0 mismatches |
| `DCReflect` | 0 mismatches |
| `GrLineFat3`, `GrFillCircle`, `GrFillSemiCircle` | 0 mismatches |
| `Line` (with callbacks into HolyC) | 0 mismatches (600 cases) |
| `SpriteSize`, `SpriteElemSize` | 0 mismatches on all 325 sprites embedded in bundled files |
| `GrPlot0`, `GrFloodFillRay`, text-layer blitters | native ports of TempleOS's internal routines (the originals use x86 asm or a 16 MiB buffer) |

The Swift runtime uses the same algorithms (line-for-line port); the
cross-platform frame comparison (`tools/parity/compare_frames.py`) shows
88 of 91 catalog programs producing byte-identical frames after 3 s.

## 3. Graphics demos (47 in the catalog: `Demo/Graphics` plus `Apps/GrModels`)

| Status | Count | Programs |
|---|---|---|
| runs | 36 | 3DPoly, BSpline, Bounce, Box, CharAnimation, Cartesian, Collision, CommonAncestor, Doodle, Elephant, Extents, Hanoi, Lattice, Life, LightTable, Lines, LowPassFilter, MathAudioDemo, MouseDemo, NetOfDots, Palette, PanText, Pick, Pick3D, RotateTank, ScrollBars, Shading, Shadow, Slider, Speedline, SpritePlot3D, SunMoon, Symmetry, Transform, WallPaperFish, WinZBuf |
| partial | 1 | PredatorPrey (correct but about one frame per second on the interpreter) |
| unsupported | 10 | Blot, EdSprite, SpritePut, SpriteRaw (sprites inside documents), SpriteText (sprite editor), FontEd and GrModels (DolDoc API / forms), Grid (mouse grid globals), PoleZeros (multi-core jobs), Balloon (direct VGA memory) |

(The authoritative per-program list with notes is `bundled-app-catalog.md`.)

## 4. Known differences

- **No VGA hardware**: programs that write VGA memory or ports directly do
  not work (port writes are ignored, reads return 0).
- **Sprites in documents** (`$SP$` in DolDoc, `Sprite()`): the document
  viewer shows a placeholder; programs that insert sprites into documents are
  unsupported.
- **Window manager**: one TempleOS window per program window; desktop-wide
  features (wallpaper, other tasks' windows inside one program) are not
  modelled. `IsPixCovered0` always reports "not covered".
- **Floating point**: last-bit differences between platform math libraries
  can change pixels in simulations (Squirt, RocketScience, X-Caliber).
- **Sprite walks**: an element type ≥ `SPT_TYPES_NUM` ends a sprite (see
  `holyc-compatibility.md` §4).
