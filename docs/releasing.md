# Releasing

Store updates are built from this public repository. Anyone can build and test both apps from a
clone without anything private; signing and uploading use the owner's keys and accounts, which
never enter the repository. Rules for contributors and coding agents: [`AGENTS.md`](../AGENTS.md).

## What is private, and where it lives

| What | Where it lives | Needed for |
|---|---|---|
| Apple developer account and signing team | Apple; signed in to Xcode (Settings → Accounts); team identifier in ignored `temple_os_swift/App/Config/Signing.local.xcconfig` | every iOS upload |
| Apple Distribution signing | Xcode automatic signing creates and fetches certificates and profiles | every iOS upload |
| Google Play upload key: keystore file, store password, key alias, key password | the owner's machine, outside any repository, plus an encrypted backup kept off that machine | every Android upload |
| Google Play app signing key | Google Play (Play App Signing) | Google re-signs each upload |
| App Store Connect and Play Console access | Apple and Google accounts with two-factor authentication | uploading and publishing |

None of these are tracked in Git or posted to the wiki, issues or pull requests. Release outputs (`*.aab`, `*.apk`,
`*.ipa`, `*.xcarchive`, `temple_os_kotlin/app/release/`) are gitignored; don't force-add them.

## Before every upload: version numbers

| Platform | Where | Rule |
|---|---|---|
| iOS | Xcode → target `TempleOSMobile` → General → Version (`MARKETING_VERSION`) and Build (`CURRENT_PROJECT_VERSION`) | Build must be higher than every build already uploaded for that version |
| Android | `versionCode` and `versionName` in `temple_os_kotlin/app/build.gradle.kts` | `versionCode` must be higher than every one already uploaded |

The Xcode project generator keeps the version numbers it finds, so
`python3 tools/xcode/gen_xcodeproj.py --check` still passes after a bump.

## iOS: archive and upload

1. Sign in to Xcode with an Apple ID on the existing app owner's team whose role can distribute to the App
   Store (Account Holder or Admin, or a role with access to cloud-managed distribution certificates).
   Once per clone, run `python3 tools/xcode/configure_signing.py` from the repository root and enter
   that team's identifier from the Apple developer account. The prompt hides the value and writes
   only `temple_os_swift/App/Config/Signing.local.xcconfig`, which Git ignores.
   Use `python3 tools/xcode/configure_signing.py --check`
   to check setup without displaying the value.
2. Open `temple_os_swift/App/TempleOSMobile.xcodeproj`, choose the `TempleOSMobile` scheme and
   **Any iOS Device (arm64)**.
3. **Product → Archive** (the scheme archives the Release configuration).
4. In the Organizer: **Distribute App → App Store Connect → Upload**, with automatic signing.
5. Commit only the version change. If Xcode changed anything else in the project, check it with
   `git diff` and `python3 tools/xcode/gen_xcodeproj.py --check` before committing.

Both Debug and Release inherit the ignored file through `Config/Signing.xcconfig`. After the
one-time setup, **Product → Archive → Distribute App → App Store Connect → Upload** works as
usual. Keep automatic signing enabled. Keep the published bundle identifier and the app owner's
team unchanged when shipping updates. Don't select a team in Xcode's project editor: it can write
the identifier into the tracked project. Edit the local configuration instead. The pre-commit
check rejects team identifiers and local signing files if they are staged.

For development under another Apple account, use your own team in the ignored file and a local
bundle-identifier override for device builds. Never commit that override or use it for store updates.

If Xcode reports that no distribution certificate is available, an Admin creates one in
Xcode → Settings → Accounts → Manage Certificates. A certificate's private key stays in that Mac's
keychain; an exported `.p12` belongs only in the encrypted backup.

From the command line (same signing; `build/` is gitignored):

```sh
xcodebuild -project temple_os_swift/App/TempleOSMobile.xcodeproj -scheme TempleOSMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/TempleOSMobile.xcarchive -allowProvisioningUpdates archive
```

Open the `.xcarchive` to add it to the Organizer, then upload it from there.

## Android: signed App Bundle and upload

The release build reads the upload key from one of these (`temple_os_kotlin/app/build.gradle.kts`):

1. **Android Studio:** Build → Generate Signed App Bundle or APK → Android App Bundle; pick the
   keystore file (outside the repository), the key alias and both passwords; variant `release`.
   Output: `temple_os_kotlin/app/release/app-release.aab`.
2. **`keystore.properties`:** copy `temple_os_kotlin/keystore.properties.example` to
   `temple_os_kotlin/keystore.properties` (gitignored), fill it in, then
   `cd temple_os_kotlin && ./gradlew :app:bundleRelease`.
   Output: `temple_os_kotlin/app/build/outputs/bundle/release/app-release.aab`.
3. **Environment variables:** `TEMPLEOS_UPLOAD_STORE_FILE`, `TEMPLEOS_UPLOAD_STORE_PASSWORD`,
   `TEMPLEOS_UPLOAD_KEY_ALIAS` and `TEMPLEOS_UPLOAD_KEY_PASSWORD`, then `./gradlew :app:bundleRelease`.

Without the key, `bundleRelease` stops with "bundleRelease needs the upload key". It can still
leave a debug-signed `app-release.aab` in `app/build/outputs/bundle/release/`; Google Play
rejects that file, so never upload it.

Check the signature before uploading:

```sh
keytool -printcert -jarfile app-release.aab | grep SHA256
```

The SHA-256 must equal the upload key certificate in Play Console → your app → App integrity.
Upload to an internal testing release first, then promote it.

## A new machine

- Clone the repository, run `git config core.hooksPath tools/git-hooks`, and install Xcode 16+,
  JDK 21, the Android SDK with platform 36 (`temple_os_kotlin/local.properties` or `ANDROID_HOME`)
  and Python 3. Build details are in the wiki's Build Android and Build iOS pages.
- iOS: sign in to Xcode and run `python3 tools/xcode/configure_signing.py` with the existing app
  owner's team identifier. No signing keys or profiles need copying.
- Android: restore the upload keystore from the encrypted backup to a folder outside any
  repository, then supply the passwords through the wizard, `keystore.properties` or environment
  variables.

## Backups

Keep one encrypted copy, away from the development machine, of the upload keystore, its two
passwords, its alias and its certificate's SHA-256. Check once that the copy opens
(`keytool -list -keystore <file>`). Apple signing needs no file backup while Xcode manages it;
keep the Apple ID's two-factor recovery options current.

## If something goes wrong

| Problem | What to do |
|---|---|
| Upload key lost | Play Console → App integrity → request an upload key reset (Play App Signing). Google registers a new upload key after a waiting period; the app signing key and users' updates are unaffected. |
| Upload key or password leaked, including into this repository | Treat it as compromised: request an upload key reset first, then remove it from Git history. Clones and caches may keep a copy, so the reset is what protects the app. |
| Distribution certificate expired or revoked | Create a new one (Xcode → Settings → Accounts → Manage Certificates, or let Xcode do it while distributing). The app and its users are unaffected. |
| Apple ID access lost | Apple account recovery. The app belongs to the team, not to a certificate. |
| A secret was committed but not pushed | Undo the commit (`git reset HEAD~1`), remove the file and check `.gitignore`. Once pushed, rotate the secret first. |
