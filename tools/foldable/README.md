# tools/foldable — iPhone Duo simulator tooling

Development tools for the iPhone Duo campaign (`docs/foldable/IPHONE_DUO_ADAPTATION.md`). They
drive real fold and rotation transitions of the **iPhone Duo simulator** (Xcode 27.1, iOS 27.1
runtime) in the middle of running UI tests. Nothing here ships in the app.

`simctl` has no fold command. Xcode 27's DeviceHub (`Xcode.app/Contents/Applications/DeviceHub.app`)
shows **Closed**, **Partially Open** and **Open** buttons under the Duo and a **Device > Orientation**
menu. These tools press them through the macOS accessibility API. The terminal that runs them needs
the Accessibility permission (System Settings > Privacy & Security > Accessibility).

| File | What it does |
|---|---|
| `axctl.swift` | Small accessibility client for DeviceHub: `dump`, `press`, `selectrow`, `front`, `click`, `windows`, `raisewindow`. Guards against application/window cycles. Compiled on first use into `$TMPDIR/templeos-foldable/`. |
| `duo.sh` | Commands for the Duo: `closed`, `partial`, `open` (each waits until the expected display is lit and retries the press), `portrait`, `landleft`, `landright` (brings DeviceHub to the front, retries), `rotright`, `state`, `shot <png>` (masked screenshot of the lit display), `mem` (the app's `phys_footprint`). `DUO=<udid>` selects a device. |
| `lit.py` | Tells whether a screenshot shows a powered display (used to know which panel is active). |
| `posture_server.sh` | Serves the UI tests: a test writes `<dir>/req-<n>` with one `duo.sh` command and waits for `<dir>/ack-<n>`. |
| `run_duo_campaign.sh` | Runs `DuoPostureUITests` with the server and keeps the evidence (shots, logs, memory samples, the xcresult, the D16 sound recording and its analysis). |

```sh
tools/foldable/run_duo_campaign.sh /tmp/duo                       # every Duo test
tools/foldable/run_duo_campaign.sh /tmp/duo testD22_RepeatedCycles  # one test
DUO_CYCLES=5 DUO_LANGS=en-US,ar,ja-JP tools/foldable/run_duo_campaign.sh /tmp/duo testD22_RepeatedCycles testD23_LanguagesAcrossFolds
tools/foldable/duo.sh partial && tools/foldable/duo.sh landleft     # book posture by hand
```

Postures as DeviceHub produces them on the iOS 27.1 simulator:

| Posture | DeviceHub | What the app measures (pt) |
|---|---|---|
| closed, portrait | Closed + Portrait | outer 466 x 678, status-bar block top-right (right inset 84) |
| closed, landscape | Closed + Landscape Left / Right | outer 678 x 466, camera block at the left / at the bottom-right |
| open, wide | Open + Landscape | inner 951 x 669, no division |
| open, tall | Open + Portrait | inner 669 x 951, no division |
| book | Partially Open, wide | inner 951 x 669, vertical division 455-496 |
| tabletop | Partially Open, tall | inner 669 x 951, horizontal division 455-496 |

Notes:
- DeviceHub's menu bar exists only while it is the front app, so orientation commands bring it to
  the front. Don't use the Mac while a campaign runs.
- With Partially Open, the orientation menu sometimes doesn't take. The UI tests check the app's own
  measurement and fall back to **Rotate Right**.
- `simctl io screenshot` without `--display` captures the inner panel even when it is off. `duo.sh shot`
  picks the lit one.
- DeviceHub has no tent or standing pose control, and no hinge-angle slider is exposed to
  accessibility (see the report).
- If DeviceHub returns application aliases for `AXWindows`, the driver reports a blocked
  posture command instead of walking that cycle or repeatedly creating windows. Restore a
  usable DeviceHub accessibility window tree before rerunning a campaign; captured closed
  screens or fixture geometry alone do not establish a passing live fold test.
- `DUO_DERIVED_DATA=/path/to/derived` isolates the campaign build from other simulator suites.
