# TempleOS.app — iOS (Swift)

Native iOS app. No WebView, no emulator, no JavaScript/WebAssembly, no
network code. HolyC programs run on a sandboxed bytecode interpreter written
in Swift.

## Layout

| Path | What it is |
|---|---|
| `TempleCore/` | Swift package (library `TempleCore`, no UIKit): HolyC lexer/parser/code generator/VM (`HolyC/`), TempleOS kernel services, graphics, console and virtual filesystem (`Kernel/`), and the TempleOS Mobile desktop shell and apps drawn into an indexed framebuffer (`UI/`). Line-for-line port of `temple_os_kotlin/core`; conventions in `PORTING.md`. Tests in `TempleCore/Tests/TempleCoreTests` run on macOS with `swift test`. |
| `App/TempleOSMobile.xcodeproj` | The iOS app target. Depends on `TempleCore` as a local package. |
| `App/TempleOSMobile/` | `AppDelegate.swift` (app, scene, `TempleViewController`), `TempleView.swift` (CALayer rendering with integer scaling, multi-touch, `UIKeyInput` soft keyboard, hardware keys), `DisplayContextAdapter.swift` (measures the view: safe area, corner-adapted top-bar insets, fold and occlusion reserved regions, hinge updates; `docs/foldable/IPHONE_DUO_ADAPTATION.md`), `IOSShellEnv.swift` (bundled drive, session file, `AVAudioEngine` square-wave tone), `Info.plist`, `PrivacyInfo.xcprivacy`, asset catalog. |

The app bundles the platform-neutral content from `../shared/` as folder
references (`runtime/`, `bundled-fs/`, `bundled-fs.index`, `catalog.json`);
nothing is downloaded at run time.

## Requirements

- Xcode 16 or newer (developed with Xcode 27.1, Swift 6.4 toolchain, Swift 5 language mode)
- iOS 16.0+ deployment target, iPhone and iPad

## Build and test

```sh
cd temple_os_swift/TempleCore
swift test                                   # HolyC vectors, filesystem, headless UI tests (macOS)
TEMPLEOS_SWEEP=Games swift test --filter SweepTests   # optional: run every original game (needs ../../reference/templeos-iso)

cd ../App
xcodebuild -project TempleOSMobile.xcodeproj -scheme TempleOSMobile \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

For a physical device, open `App/TempleOSMobile.xcodeproj` in Xcode and choose
your own signing team and bundle id (the project uses automatic signing with the
store team and bundle id, which only the owner can sign; don't commit that change).
Store releases: [`docs/releasing.md`](../docs/releasing.md).

## App facts

- Bundle id `com.digitalcircuitstudios.templeosapp` (the App Store identity; UI tests use
  `io.github.templeosmobile.uitests`), iOS 16.0+.
- No entitlements, no capabilities, no URL schemes, no document types,
  no file sharing, no network usage keys; privacy manifest declares no
  tracking and no collected data.
- User files: Application Support/TempleOSMobile/drive (excluded from backup).
- Orientation: portrait and landscape. The desktop mode follows the usable size (one window at a time on a
  narrow screen, overlapping windows when there is room), and folds and occlusions are laid out around
  (iPhone Duo: `docs/foldable/IPHONE_DUO_ADAPTATION.md`).
