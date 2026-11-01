#!/bin/zsh
# Drives the iPhone Duo simulator: fold state and orientation through DeviceHub's own controls (axctl, the
# macOS accessibility API; simctl has no fold command), display-aware screenshots through simctl.
# Development tool (tools/foldable/README.md). DUO=<udid> overrides the device (default: the first iPhone Duo).
#   closed | partial | open            DeviceHub's Closed / Partially Open / Open (waits until the display is lit)
#   portrait | landleft | landright    DeviceHub Device > Orientation
#   rotright                           DeviceHub's Rotate Right control
#   state                              which display is lit: outer=0|1 inner=0|1
#   shot <file.png>                    masked screenshot of the lit display
#   mem                                phys_footprint (bytes) of the running TempleOS app process
setopt no_nomatch
T=${0:A:h}
D=${DUO:-$(xcrun simctl list devices available | grep -m1 "iPhone Duo (" | grep -oE '[0-9A-F-]{36}')}
CACHE=${TMPDIR:-/tmp}/templeos-foldable; mkdir -p $CACHE
[[ $CACHE/axctl -nt $T/axctl.swift ]] || swiftc -O $T/axctl.swift -o $CACHE/axctl || exit 1
PID=$(pgrep -f "DeviceHub.app/Contents/MacOS/DeviceHub" | head -1)
if [[ -z $PID && $1 != shot && $1 != state && $1 != mem ]]; then
  open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app; sleep 5
  PID=$(pgrep -f "DeviceHub.app/Contents/MacOS/DeviceHub" | head -1)
fi
# every DeviceHub call has a hard time limit: a DeviceHub that stops answering accessibility requests must not
# stall a campaign (seen once after hours of fold cycles); the caller then retries or reports a failure
axt() {
  [[ -n $PID ]] || { echo "DeviceHub is not running" >&2; return 1 }
  perl -e 'alarm shift; exec @ARGV' 30 $CACHE/axctl $PID "$@"
}
ax() { axt "$@" | grep -E "press:|no match" }
lit() { local f=$CACHE/lit_$$.png; xcrun simctl io $D screenshot --display=$1 $f >/dev/null 2>&1; python3 -I $T/lit.py $f; rm -f $f }
front() { open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app; axt front >/dev/null; sleep 1 }
# DeviceHub shows the device selected in its sidebar: make sure it is the Duo
select_duo() {
  # DeviceHub may launch with only a menu bar. A booted simulator alone creates no window.
  axt front >/dev/null || return 1
  local windows=$(axt windows) || return 1
  if [[ -n $windows && $windows != *AXWindow* ]]; then
    echo "DeviceHub exposes application aliases instead of accessible windows; posture control is blocked" >&2
    return 1
  fi
  if [[ -z $windows ]]; then
    axt press "AXMenuBarItem t=File d=" >/dev/null || return 1
    axt press "AXMenuItem t=New Window d=" >/dev/null || return 1
    sleep 2
  fi
  axt windows | grep -q "iPhone Duo" || { axt selectrow "TableRow.Device.$D" >/dev/null || return 1; sleep 2 }
  # Orientation menu actions apply to the front device window, not any background Duo tab.
  axt raisewindow "iPhone Duo" >/dev/null
}
# presses a fold button until the expected display is lit (outer for closed, inner otherwise)
fold() {
  select_duo || return 1
  for attempt in 1 2 3; do
    ax press "$1" >/dev/null
    for i in 1 2 3 4 5 6 7 8; do sleep 1; [[ $(lit $2) == 1 ]] && { sleep 1.5; echo "fold ok ($1, attempt $attempt)"; return 0 } ; done
  done
  echo "fold FAILED ($1)"; return 1
}
# a Device > Orientation menu item: DeviceHub's menu bar exists only while it is frontmost
orient() {
  select_duo || return 1
  for attempt in 1 2 3 4; do
    front
    r=$(axt press "AXMenuItem t=$1 d=" | grep -E "press:|no match")
    [[ $r == "press: 0" ]] && { sleep 2; echo "orientation $1"; return 0 }
    sleep 1
  done
  echo "orientation FAILED ($1)"; return 1
}
case $1 in
  closed) fold "d=Closed id= h=Closed" 1 ;;
  partial) fold "d=Partially Open" 3 ;;
  open) fold "d=Open id= h=Open" 3 ;;
  portrait) orient Portrait ;;
  landleft) orient "Landscape Left" ;;
  landright) orient "Landscape Right" ;;
  rotright) select_duo || exit 1; ax press "d=Rotate Right id= h=Rotate Right"; sleep 2 ;;
  state) echo "outer=$(lit 1) inner=$(lit 3)" ;;
  shot) disp=3; [[ $(lit 1) == 1 ]] && disp=1; xcrun simctl io $D screenshot --display=$disp --mask=black "$2" >/dev/null 2>&1 && echo "shot $2" ;;
  mem) p=$(pgrep -f "TempleOSMobile.app/TempleOSMobile" | head -1); [[ -n $p ]] && footprint -p $p 2>/dev/null | grep -m1 -i "phys_footprint:" | grep -oE "[0-9.]+ [KMG]B" || echo "no app" ;;
  *) echo "usage: duo.sh closed|partial|open|portrait|landleft|landright|rotright|state|shot <png>|mem"; exit 2 ;;
esac
