#!/bin/zsh
# Serves posture requests from the Duo UI tests (DuoPostureUITests): a test writes <dir>/req-<n> holding one
# duo.sh command line (e.g. "partial", "shot <name>", "mem"); this runs it and writes the output to
# <dir>/ack-<n>. A simulator test can read and write the host's files, so the transitions are real DeviceHub
# fold and rotation changes in the middle of a running test. Screenshots go to <dir>/shots/<name>.png.
# Stops when <dir>/stop exists. Development tool (tools/foldable/README.md).
#   posture_server.sh <dir>
setopt no_nomatch
T=${0:A:h}; DIR=$1; mkdir -p $DIR/shots
echo "posture server on $DIR" > $DIR/server.log
n=1
while [[ ! -e $DIR/stop ]]; do
  if [[ -e $DIR/req-$n ]]; then
    cmd=$(cat $DIR/req-$n)
    if [[ $cmd == shot\ * ]]; then out=$($T/duo.sh shot $DIR/shots/${cmd#shot }.png 2>&1)
    else out=$($T/duo.sh ${=cmd} 2>&1); fi
    # the front Mac app: while DeviceHub is in front, typing on the Mac reaches the simulator as hardware keys
    front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
    echo "$(date +%H:%M:%S) #$n $cmd -> $out [front: $front]" >> $DIR/server.log
    echo "$out" > $DIR/ack-$n.tmp && mv $DIR/ack-$n.tmp $DIR/ack-$n
    n=$((n + 1))
  else
    sleep 0.2
  fi
done
echo "stopped" >> $DIR/server.log
