# TempleOS.app

An independent, fully offline recreation of the TempleOS user environment for
phones and tablets ("Classic" edition: no online features), built as **two
native apps**:

- **Android** — Kotlin, in [`temple_os_kotlin/`](temple_os_kotlin/README.md)
- **iOS** — Swift, in [`temple_os_swift/`](temple_os_swift/README.md)

TempleOS was created by **Terry A. Davis** (1969–2018), who wrote its kernel,
compiler, HolyC language, graphics, games and documentation and placed them in
the public domain. This project is not affiliated with him or his estate and
is not an official TempleOS release.

TempleOS.app was made by me, Ricky Axel, as a hobby project. It was a lot of fun making it
and truly a bit surreal at times going through Terry's files he wrote himself when I was
vibecoding this.

## Wiki

New here? The [TempleOS.app Wiki](https://github.com/rickyaxel/TempleOS.app/wiki) is a guided
introduction: what the apps are and are not, how the HolyC compiler, bytecode interpreter and
per-program kernel work on Android and iOS, how to build and test both apps, compatibility
and known limitations, and how to contribute.

## Names

| Where | Name |
|---|---|
| The installed apps (label under the icon, desktop, About, Terminal, messages, every language) | **TempleOS.app** |
| The website (titles, headings, sharing and structured-data metadata) | **TempleOS Mobile App** |
| The domain and canonical URLs | `https://templeos.app/` (lowercase) |
| Terry A. Davis' operating system | **TempleOS**, never renamed |

The two product names differ on purpose: the apps carry the `.app` brand, the website uses
words people search for. In this repository the apps' name has one source,
`app_name` in `shared/runtime/l10n/locales.json`:
- `tools/l10n/gen_platform.py` writes it into the iOS `CFBundleDisplayName` and the Android
  `app_name` string (`--check` verifies them);
- catalogs write it as `{app}`, which `L10n.tr` fills in, so no translation can alter it;
- `Brand.APP_NAME` (Kotlin) and `Brand.appName` (Swift) hold it for code that runs without
  the catalogs (kernel, compiler messages); `BrandTest`/`BrandTests` compare all of them.

The store identity is `com.digitalcircuitstudios.templeosapp`: the Android application id (the Google
Play package name) and the iOS app's bundle id. Technical identities keep their historical
names: `io.github.templeosmobile` for the Kotlin packages, the Android namespace and the
iOS test and bench bundle ids, the Xcode target `TempleOSMobile`, the
repository name, the app-data folder, and the provenance token `TempleOS Mobile` in
`shared/bundled-fs.index`. Changing them would break upgrades or saved data. "TempleOS
Mobile" in engineering documents and code comments is the project's working name and dated
reports are left as written.

## How it works

Neither app emulates a PC or boots the TempleOS kernel, and neither contains a
WebView, JavaScript, WebAssembly or downloaded code. Each app has its own
native HolyC compiler and sandboxed bytecode interpreter (Kotlin and a
line-for-line Swift port) plus the TempleOS services HolyC programs call. The
original TempleOS V5.03 graphics, sprite, menu, control and math libraries,
games, demos and documentation are bundled unmodified from the official ISO (except six files in which offensive content is censored or redacted with visible markers, `docs/content-moderation/CONTENT_MODERATION.md`)
and run on that interpreter. See [`docs/architecture.md`](docs/architecture.md).

What you can do, offline from the first launch:

- use a TempleOS-style desktop (windows in landscape, a window deck in portrait);
- type HolyC in a terminal; write, save and run your own programs in an editor;
- browse the `C:` drive; read the original documentation;
- play the original games (BattleLines, Varoom, Maze, TicTacToe, X-Caliber …)
  and run graphics demos with touch controls or a keyboard;
- God Words, Paint, and your work restored when you reopen the app.

## Repository layout

| Path | Contents |
|---|---|
| `temple_os_kotlin/` | Android app (`app/`) and the pure-Kotlin runtime (`core/`) |
| `temple_os_swift/` | Swift package `TempleCore` (runtime) and the iOS app project (`App/`) |
| `shared/` | platform-neutral content: HolyC runtime prelude and generated libraries (`runtime/`), the bundled `C:` drive (`bundled-fs/`), program catalog, HolyC test vectors, runtime specification |
| `tools/` | development-only tools: ISO/font extraction, asset packaging, Xcode project generation, parity comparison, offline audit |
| `docs/` | architecture, research, licensing, compatibility, security, performance, testing, release readiness, future modes |
| `reference/` | upstream material for research (gitignored, not shipped) |

## Build

```sh
# Android (JDK 21, Android SDK 36)
cd temple_os_kotlin && ./gradlew :core:test :app:assembleRelease

# iOS (Xcode 16+)
cd temple_os_swift/TempleCore && swift test
cd ../App && xcodebuild -project TempleOSMobile.xcodeproj -scheme TempleOSMobile \
  -destination 'generic/platform=iOS Simulator' build
```

## Status

Both apps build and pass their tests. An independent verification pass
(2026-10-16) found and fixed 4 P0, 7 P1 and 12 P2 defects. Its verdict is
**CONDITIONAL PASS**: conditionally ready for release, blocked by device
testing, signing, license, branding and content decisions. See
[`docs/testing.md`](docs/testing.md) and
[`docs/release-readiness.md`](docs/release-readiness.md).

## Documentation

For a guided introduction, start with the [Wiki](https://github.com/rickyaxel/TempleOS.app/wiki).
The documents below are the detailed engineering references and dated reports it links to.

| Document | Topic |
|---|---|
| [architecture](docs/architecture.md) | layers, program lifecycle, compiler/VM, shell, filesystem |
| [upstream-research](docs/upstream-research.md) | reference projects studied, commits, licenses, capability audit |
| [licensing-and-provenance](docs/licensing-and-provenance.md) | what is bundled, where it comes from, how to reproduce it |
| [native-ui-design](docs/native-ui-design.md) | portrait/landscape design, input, game controls |
| [holyc-compatibility](docs/holyc-compatibility.md) | supported language, adaptations, unsupported features |
| [graphics-compatibility](docs/graphics-compatibility.md) | graphics model, native fast paths, demo results |
| [game-compatibility](docs/game-compatibility.md) | per-game results and evidence |
| [bundled-app-catalog](docs/bundled-app-catalog.md) | every bundled program and its status |
| [offline-release-specification](docs/offline-release-specification.md) | what V1 includes and excludes, offline verification |
| [security-model](docs/security-model.md) | sandbox, memory model, capabilities, filesystem |
| [performance](docs/performance.md) | measured numbers and conditions |
| [testing](docs/testing.md) | test suites, results, gaps |
| [release-readiness](docs/release-readiness.md) | open items before release |
| [future-developer-mode](docs/future-developer-mode.md) | design notes only (not implemented) |
| [future-online-mode](docs/future-online-mode.md) | design notes only (not implemented) |
| [HolyC runtime specification](shared/specifications/holyc-runtime-spec.md) | the authoritative cross-platform spec |

## License

The TempleOS.app code is released into the public domain under the [Unlicense](LICENSE).
TempleOS V5.03 itself (the files bundled in `shared/bundled-fs/`) is Terry A. Davis' public-domain
work; a few files he included came from elsewhere (the FreeDOS font, the Project Gutenberg Bible
text). See [`docs/licensing-and-provenance.md`](docs/licensing-and-provenance.md).
