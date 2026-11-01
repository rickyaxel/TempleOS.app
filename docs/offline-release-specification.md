# Offline release specification — TempleOS Mobile Classic (Version 1)

Version 1 is a complete offline product. This document lists what V1 contains,
what it deliberately excludes, and how each property is verified.

## 1. Included (works with no network from first launch)

| Area | Included |
|---|---|
| Desktop | TempleOS-style desktop, start menu, windows (landscape), window deck (portrait), top bar, key row |
| Programming | Terminal (HolyC command line), HolyC editor with RUN/SAVE/UNDO/REDO, sandboxed interpreter, local files on the virtual `C:` drive, nine example programs |
| Content | original TempleOS V5.03 sources, documentation, games and demos (646 files, 9.7 MB) |
| Apps | Files, DolDoc documentation viewer, God Words, Paint, Settings, About & Credits |
| Games and demos | 35 games and 47 demos/apps in the menus (unsupported ones hidden; see `bundled-app-catalog.md`) |
| Persistence | user files, editor drafts, open windows, settings, terminal history |
| Input | touch, multi-touch game controls, soft keyboard, hardware keyboard |
| Audio | TempleOS `Snd()` square-wave tones |

## 2. Excluded (not present in any form)

No file import (Files app / Storage Access Framework / document pickers),
no URL schemes or deep links, no share extensions or intent filters for
content, no drag-and-drop import, no program downloads, no online catalog or
community, no cloud sync, no accounts or login, no analytics, no ads, no
in-app purchases or subscriptions, no remote configuration or feature flags,
no web browsing or WebView, no background network services, no dormant
networking code, no "coming soon" screens or placeholder import buttons.

Clipboard paste into the editor/terminal is an ordinary text-editing
operation and is the only way text enters the app from outside.

## 3. Platform configuration

| | Android | iOS |
|---|---|---|
| Permissions | none (`<uses-permission>` absent) | none requested |
| Network | no INTERNET permission; no networking libraries | no networking code; no ATS exceptions |
| Inbound content | launcher intent only; nothing else exported | no URL types, no document types, file sharing off, no extensions |
| Backup | `allowBackup=false`, data-extraction rules exclude all | user drive excluded from backup |
| Privacy | — | `PrivacyInfo.xcprivacy`: no tracking, no collected data, required-reason APIs declared (file timestamps C617.1, system boot time 35F9.1) |

## 4. Verification

| Property | Evidence |
|---|---|
| No network capability in the artifacts | `tools/compatibility-validation/offline_audit.sh`: all checks pass (APK manifest/dex, iOS Info.plist/linkage/symbols, sources, dependencies) |
| Works offline from first launch | Android emulator in airplane mode (no default network, ping unreachable), app data cleared: first launch shows the Welcome document in 836 ms; Terminal ran `Dir;` and a HolyC expression. iOS: the app has no network code (audit); the simulator test ran with the host network available but the app makes no network calls |
| Local programming | iOS XCUITest: create, save and run `C:/Home/MyTest.HC`; headless tests on both platforms |
| Bundled programs run | catalog sweeps on both runtimes (`testing.md`) |
| Persistence | session restore tests (headless, both platforms) and relaunch in the iOS XCUITest and on the Android emulator |

## 5. Store-review notes

- The app executes code: HolyC typed by the user or bundled with the app,
  interpreted in a sandbox with no access outside the app (no network, no
  host files, no native code). No code is downloaded.
  Relevant guidelines to cite in review notes: Apple App Review Guidelines
  2.5.2 (apps may not download executable code; this app does not), Google
  Play Device and Network Abuse policy (no code downloaded from outside
  Google Play).
- Name/branding: "TempleOS Mobile Classic" is a working title subject to a
  trademark and branding review. The app states it is independent and not
  affiliated with Terry A. Davis or his estate.
- Content review: the bundled TempleOS material is the original
  distribution, which includes Terry A. Davis's religious content and his own
  writing. Slurs and derogatory remarks about groups of people found by a full
  content audit (six files) are censored or redacted with visible markers at
  packaging time (`tools/resource-packaging/moderation.json`, applied by
  `build_bundled_fs.py`); policy, findings and the items left for editorial
  review are in `docs/content-moderation/CONTENT_MODERATION.md`. This is not a
  store age rating, which must be assessed separately.
