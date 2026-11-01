#!/bin/sh
# Runs Examples > Sound on an iOS simulator or device with the debug sound capture (XCUITest
# testSoundExample), pulls Documents/sound-capture.{wav,json} from the app's container and checks the
# recording against TempleOS's trace (tools/audio/analyze_capture.py). Development tool only.
#
#   tools/audio/check_ios_sound.sh SIMULATOR_OR_DEVICE_ID OUTDIR [xcodebuild args...]
#   TEST=testSoundStopsInBackground (default testSoundExample); for other programs set
#   TEST_RUNNER_TEMPLEOS_SOUND_PROGRAM/_MENU/_TAPS/_SECONDS (the analysis is then --stats)
#   e.g. tools/audio/check_ios_sound.sh <simulator-udid> /tmp/snd
#        tools/audio/check_ios_sound.sh <device-udid> /tmp/snd DEVELOPMENT_TEAM=XXXX -allowProvisioningUpdates
set -e
ID="$1"; OUT="$2"; shift 2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=io.github.templeosmobile
mkdir -p "$OUT"
cd "$ROOT/temple_os_swift/App"
xcodebuild -project TempleOSMobile.xcodeproj -scheme TempleOSMobile -destination "id=$ID" \
  -only-testing:TempleOSMobileUITests/TempleOSMobileUITests/${TEST:-testSoundExample} "$@" test > "$OUT/xcodebuild.log" 2>&1 \
  || { tail -30 "$OUT/xcodebuild.log"; exit 1; }
if xcrun simctl list devices | grep -q "$ID"; then
  DATA="$(xcrun simctl get_app_container "$ID" "$BUNDLE" data)"
  cp "$DATA/Documents/sound-capture.wav" "$DATA/Documents/sound-capture.json" "$OUT/"
else
  for f in sound-capture.wav sound-capture.json; do
    xcrun devicectl device copy from --device "$ID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source "Documents/$f" --destination "$OUT/$f" > /dev/null
  done
fi
cat "$OUT/sound-capture.json"; echo
if [ -n "$TEST_RUNNER_TEMPLEOS_SOUND_PROGRAM" ] || [ "${TEST:-}" = testSoundStopsInBackground ]; then STATS=--stats; fi
python3 "$ROOT/tools/audio/analyze_capture.py" "$OUT/sound-capture.wav" --json "$OUT/analysis.json" $STATS
