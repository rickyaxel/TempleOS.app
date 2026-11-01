#!/bin/zsh
# Runs the iPhone Duo campaign (DuoPostureUITests) on the iPhone Duo simulator with real DeviceHub fold and
# rotation transitions, and keeps the evidence: screenshots, the server log, the xcodebuild log, memory
# samples, the result bundle and (D16) the sound recording with its analysis. Development tool
# (tools/foldable/README.md; needs the Accessibility permission for the terminal, for DeviceHub).
#   run_duo_campaign.sh OUTDIR [test ...]     tests default to all of DuoPostureUITests
#   e.g. run_duo_campaign.sh /tmp/duo testD13_TerminalAndKeyboardAcrossFolds
#   DUO=<udid>  DUO_CYCLES=20  DUO_KB_CYCLES=40  DUO_LANGS=en-US,ar,...
setopt no_nomatch
T=${0:A:h}; ROOT=${T:h:h}; OUT=${1:A}; shift
D=${DUO:-$(xcrun simctl list devices available | grep -m1 "iPhone Duo (" | grep -oE '[0-9A-F-]{36}')}
[[ -z $D ]] && { echo "no iPhone Duo simulator"; exit 1 }
mkdir -p $OUT; rm -rf $OUT/ctl $OUT/result.xcresult; mkdir -p $OUT/ctl
xcrun simctl boot $D 2>/dev/null; xcrun simctl bootstatus $D -b >/dev/null
$T/posture_server.sh $OUT/ctl &
SERVER=$!
trap 'touch $OUT/ctl/stop; wait $SERVER 2>/dev/null' EXIT
only=()
derived=()
[[ -n $DUO_DERIVED_DATA ]] && derived=(-derivedDataPath "$DUO_DERIVED_DATA")
if (( $# )); then for t in "$@"; do only+=(-only-testing:TempleOSMobileUITests/DuoPostureUITests/$t); done
else only=(-only-testing:TempleOSMobileUITests/DuoPostureUITests); fi
cd $ROOT/temple_os_swift/App
TEST_RUNNER_DUO_CTL=$OUT/ctl TEST_RUNNER_DUO_CYCLES=${DUO_CYCLES:-20} TEST_RUNNER_DUO_KB_CYCLES=${DUO_KB_CYCLES:-40} TEST_RUNNER_DUO_LANGS=${DUO_LANGS:-} \
  xcodebuild test -project TempleOSMobile.xcodeproj -scheme TempleOSMobile -configuration Debug -destination "id=$D" "${derived[@]}" -collect-test-diagnostics never \
  -resultBundlePath $OUT/result.xcresult "${only[@]}" > $OUT/xcodebuild.log 2>&1 &
XB=$!
# xcodebuild (27.1) sometimes stays idle after the last test: stop it 90 s after the final summary
while kill -0 $XB 2>/dev/null; do
  if grep -qE "Test Suite 'Selected tests' (passed|failed) at" $OUT/xcodebuild.log 2>/dev/null; then
    for i in {1..90}; do kill -0 $XB 2>/dev/null || break; sleep 1; done
    kill -0 $XB 2>/dev/null && { echo "xcodebuild idle after the tests: stopped"; kill $XB }
    break
  fi
  sleep 5
done
wait $XB; rc=$?
grep -q "Executed .* with 0 failures" $OUT/xcodebuild.log && grep -q "Test Suite 'Selected tests' passed" $OUT/xcodebuild.log && rc=0
grep -E "DUOMEM|POSTURE .* ok|DUOCYCLE|DUOKB" $OUT/xcodebuild.log | sort -u > $OUT/samples.txt
grep -E "error:|Test Case .*(passed|failed)|Executed" $OUT/xcodebuild.log | grep -v "^$" > $OUT/summary.txt
# D16: the recording of Examples > Sound with a fold in the middle, against TempleOS's own trace
if grep -q "testD16_SoundAcrossFold\]' passed" $OUT/xcodebuild.log; then
  DATA=$(xcrun simctl get_app_container $D io.github.templeosmobile data)
  cp $DATA/Documents/sound-capture.wav $DATA/Documents/sound-capture.json $OUT/ 2>/dev/null &&
    python3 $ROOT/tools/audio/analyze_capture.py $OUT/sound-capture.wav --json $OUT/sound-analysis.json > $OUT/sound-analysis.txt 2>&1
  echo "sound analysis: exit $? ($OUT/sound-analysis.txt)"
fi
cat $OUT/summary.txt | tail -40
exit $rc
