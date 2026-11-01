# Instructions for coding agents

TempleOS.app is developed in this one **public** repository, `github.com/rickyaxel/TempleOS.app`.
There is no private copy, mirror or second remote, and there must not be one. Everything needed to
build both apps and ship store updates is here. The only things kept outside it are the owner's
signing keys and store-account access. Treat every commit as published the moment it's made.

## Rules

1. **Never commit secrets or signing material:** keystores (`.jks`, `.keystore`), `keystore.properties`,
   passwords, `.p12`, `.p8`, `.pem` and `.cer` files, provisioning profiles, App Store Connect API keys,
   Google Play service-account JSON, `.env` files, access tokens. Don't copy them into the working tree
   (not even into an ignored path), don't print their contents, and don't ask the owner for them.
2. **Never commit anything that identifies a machine, a device or a person:** absolute home paths
   (`/Users/<name>/…`), device identifiers (UDIDs, serial numbers), signing identity names, personal
   e-mail addresses, crash reports (`.ips`), `.xcresult` bundles, and screenshots or logs from
   personal devices. Validation evidence stays on the machine that produced it (`docs/**/evidence/`
   is ignored); commit a summary written without those details, or nothing.
3. **Never change the store identity.** These values connect the code to the published apps;
   changing them breaks updates for every existing user. They are public, not secrets.

   | Identity | Value | Where |
   |---|---|---|
   | iOS bundle identifier | `com.digitalcircuitstudios.templeosapp` | `project.pbxproj` (app target), `tools/xcode/gen_xcodeproj.py` |
   | Apple team | `LOCAL_SIGNING_TEAM` | `project.pbxproj` (`DEVELOPMENT_TEAM`), `tools/xcode/gen_xcodeproj.py` |
   | Android application id | `com.digitalcircuitstudios.templeosapp` | `temple_os_kotlin/app/build.gradle.kts` |

   The `io.github.templeosmobile` names (Kotlin packages, Android namespace, test and bench ids) are
   code-level names and stay as they are.
4. **Don't give the source a second home:** no private repository, mirror, submodule or extra remote,
   and no importing history from elsewhere into this repository.
5. **Keep release signing outside the repository.** Xcode stays on automatic signing with no
   certificates or profiles committed. Android release signing keeps reading the upload key from
   outside the repository, and `bundleRelease` keeps refusing to build without it
   (`temple_os_kotlin/app/build.gradle.kts`). Don't add CI that signs or uploads unless the owner asks.
6. **Commit as a GitHub noreply address** (`…@users.noreply.github.com`), never a personal one.
7. **Don't bypass the pre-commit check** (`--no-verify`) and don't loosen it to make a commit pass;
   remove the material instead. If something is a false positive, narrow the rule in
   `tools/public-safety/check_public_tree.py` and say so in the commit message.

## Before committing

- Enable the hook once per clone: `git config core.hooksPath tools/git-hooks`. It runs
  `tools/public-safety/check_public_tree.py --staged` and gitleaks (`.gitleaks.toml`) when installed.
- Whole tree: `python3 tools/public-safety/check_public_tree.py`.
- A new kind of local-only file (a credential, a machine setting) goes in `.gitignore` and in the
  check, and `docs/releasing.md` says how the owner supplies it.

## Releasing

[`docs/releasing.md`](docs/releasing.md) covers version numbers, the iOS archive and upload, the
signed Android App Bundle, and recovery. Agents can prepare a release: bump versions, build, run
tests and unsigned checks. Signing and uploading use the owner's keys and accounts; leave those
steps to the owner, and don't move, copy or recreate signing files.

## Generated files

- `temple_os_swift/App/TempleOSMobile.xcodeproj` comes from `tools/xcode/gen_xcodeproj.py`. After
  changing the project in Xcode, run `python3 tools/xcode/gen_xcodeproj.py --check`; if it reports a
  difference, update the generator so it writes the intended project. The generator writes the
  store identity and keeps the version numbers already in the project.
- `Info.plist` languages and display name come from `tools/l10n/gen_platform.py` (`--check`).
- `PureSwift/Generated` and the Pure Kotlin `gen` sources come from the translator in
  `temple_os_kotlin/translator`; don't edit them by hand.

## Documentation

Some documents cite dated validation reports (paths like `docs/<area>/REPORT.md`) that were kept
out of the public repository because they held device identifiers and local paths. They aren't
needed to build, test or release. Don't recreate them, and keep new reports free of those details.
