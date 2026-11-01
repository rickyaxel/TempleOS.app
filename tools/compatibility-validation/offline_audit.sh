#!/bin/bash
# Offline / capability audit for TempleOS Mobile Classic (development tool).
# Checks built artifacts and sources for network access, import paths and
# exported entry points. Run from the repository root after building:
#   (cd temple_os_kotlin && ./gradlew :app:assembleRelease)
#   (cd temple_os_swift/App && xcodebuild -project TempleOSMobile.xcodeproj -scheme TempleOSMobile \
#      -destination 'generic/platform=iOS Simulator' -configuration Release -derivedDataPath /tmp/tosm-dd build)
# Usage: tools/compatibility-validation/offline_audit.sh [ios-derived-data-dir]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DD="${1:-/tmp/tosm-dd}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | tail -1)"
APK="$ROOT/temple_os_kotlin/app/build/outputs/apk/release/app-release.apk"
fail=0
pass() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
note() { echo "INFO  $*"; }

echo "== Android ($APK)"
if [ -f "$APK" ] && [ -x "$BT/aapt2" ]; then
  perms="$("$BT/aapt2" dump permissions "$APK" | grep -v '^package:' || true)"
  [ -z "$perms" ] && pass "no permissions requested" || bad "permissions: $perms"
  man="$("$BT/aapt2" dump xmltree "$APK" --file AndroidManifest.xml)"
  echo "$man" | grep -q 'android.permission.INTERNET' && bad "INTERNET permission present" || pass "no INTERNET permission"
  actions="$(echo "$man" | grep -A1 'E: action' | grep -o '"android.intent.action[^"]*"' | sort -u | tr '\n' ' ')"
  [ "$actions" = '"android.intent.action.MAIN" ' ] && pass "only intent action: MAIN" || bad "intent actions: $actions"
  echo "$man" | grep -q 'E: data' && bad "intent filter with <data> (URL/file import path)" || pass "no <data> intent filters (no URL schemes, no file types)"
  echo "$man" | grep -E -q 'E: (provider|service|receiver)' && bad "provider/service/receiver declared" || pass "no providers, services or receivers"
  echo "$man" | grep -q 'allowBackup([^)]*)=false' && pass "allowBackup=false" || bad "allowBackup is not false"
  echo "$man" | grep -q 'usesCleartextTraffic([^)]*)=false' && pass "usesCleartextTraffic=false" || bad "usesCleartextTraffic is not false"
  [ "$(echo "$man" | grep -c 'exported([^)]*)=true')" = "1" ] && pass "exactly one exported component (the launcher)" || bad "exported components: $(echo "$man" | grep -c 'exported([^)]*)=true')"
  tmp="$(mktemp -d)"; (cd "$tmp" && unzip -q -o "$APK" 'classes*.dex')
  netrefs="$(for d in "$tmp"/classes*.dex; do strings "$d"; done | grep -E 'Ljava/net/(Socket|URL;|HttpURLConnection|ServerSocket|DatagramSocket)|Ljavax/net/|okhttp|Landroid/net/http' | sort -u | head -5)"
  [ -z "$netrefs" ] && pass "no networking classes referenced in dex" || bad "networking references in dex: $netrefs"
  rm -rf "$tmp"
else
  note "APK or aapt2 not found; build the release APK first"
fi

echo "== iOS"
# a simulator build's derived data, a device build's, or an .xcarchive
APP="$(ls -d "$DD"/Build/Products/*-iphonesimulator/TempleOSMobile.app "$DD"/Build/Products/*-iphoneos/TempleOSMobile.app "$DD"/Products/Applications/TempleOSMobile.app 2>/dev/null | head -1)"
if [ -n "$APP" ]; then
  plist="$APP/Info.plist"
  for k in CFBundleURLTypes CFBundleDocumentTypes UTImportedTypeDeclarations UTExportedTypeDeclarations NSAppTransportSecurity NSBonjourServices NSLocalNetworkUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$k" "$plist" >/dev/null 2>&1 && bad "Info.plist has $k" || pass "Info.plist has no $k"
  done
  [ "$(/usr/libexec/PlistBuddy -c 'Print :UIFileSharingEnabled' "$plist" 2>/dev/null)" = "false" ] && pass "UIFileSharingEnabled=false" || bad "UIFileSharingEnabled not false"
  links="$(otool -L "$APP/TempleOSMobile" | grep -E 'Network.framework|libnetwork|WebKit|JavaScriptCore' || true)"
  [ -z "$links" ] && pass "no Network/WebKit/JavaScriptCore linkage" || bad "linked: $links"
  syms="$(nm -u "$APP/TempleOSMobile" 2>/dev/null | grep -E 'URLSession|NWConnection|CFSocket|WKWebView|JSContext' | head -5)"
  [ -z "$syms" ] && pass "no URLSession/NWConnection/socket/WebView/JSContext symbols" || bad "symbols: $syms"
  [ -d "$APP/PlugIns" ] && bad "app extensions present: $(ls "$APP/PlugIns")" || pass "no app extensions (no share/action extensions)"
else
  note "iOS app not found under $DD; build it first"
fi

echo "== Sources"
src_net="$(grep -rEl 'java\.net\.|HttpURLConnection|okhttp|URLSession|NWConnection|WKWebView|JSContext|WebView' \
  "$ROOT/temple_os_kotlin/core/src/main" "$ROOT/temple_os_kotlin/app/src/main" \
  "$ROOT/temple_os_swift/TempleCore/Sources" "$ROOT/temple_os_swift/App/TempleOSMobile" 2>/dev/null || true)"
[ -z "$src_net" ] && pass "no networking or WebView APIs in app sources" || bad "networking APIs in: $src_net"
src_imp="$(grep -rEl 'ACTION_OPEN_DOCUMENT|ACTION_GET_CONTENT|UIDocumentPicker|UIDocumentBrowser|openURL|onOpenURL|application\(_ app: UIApplication, open' \
  "$ROOT/temple_os_kotlin/app/src/main" "$ROOT/temple_os_swift/App/TempleOSMobile" 2>/dev/null || true)"
[ -z "$src_imp" ] && pass "no document pickers or URL-open handlers (no import path)" || bad "import paths in: $src_imp"
deps="$(grep -E 'implementation\(|api\(' "$ROOT/temple_os_kotlin/app/build.gradle.kts" "$ROOT/temple_os_kotlin/core/build.gradle.kts" | grep -vE 'project\(":(core|purekotlin)"\)' || true)"
[ -z "$deps" ] && pass "Android app depends only on :core and :purekotlin (no third-party libraries)" || bad "dependencies: $deps"
grep -q 'dependencies:' "$ROOT/temple_os_swift/TempleCore/Package.swift" && grep -A3 'dependencies:' "$ROOT/temple_os_swift/TempleCore/Package.swift" | grep -q 'url:' && bad "Swift package has remote dependencies" || pass "Swift package has no remote dependencies"

echo
[ $fail -eq 0 ] && echo "RESULT: all checks passed" || echo "RESULT: some checks FAILED"
exit $fail
