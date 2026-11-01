#!/usr/bin/env python3
"""Runs a program on an Android device or emulator with the debug sound capture and checks what it played.

Installs the debug APK, launches it with `--ez soundcapture true`, opens START MENU > <menu> > <program>
through the accessibility tree (tools/performance-analysis/android_ui.py), optionally taps buttons, waits,
pulls <external files>/sound-capture.wav (written when the speaker idles) and runs
tools/audio/analyze_capture.py: against TempleOS's trace for the Sound example, --stats for others.

    check_android_sound.py -s emulator-5554 --apk app-debug.apk --out DIR                       # Examples > Sound
    check_android_sound.py -s 49c56f82 --menu Games... --program TicTacToe --taps L-CLICK --seconds 20 --out DIR

Development tool only.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "performance-analysis"))
from android_ui import Device, PKG  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", required=True)
    ap.add_argument("--apk")
    ap.add_argument("--out", required=True)
    ap.add_argument("--menu", default="Examples...")
    ap.add_argument("--program", default="Sound")
    ap.add_argument("--taps", default="", help="comma-separated button labels to tap while it runs")
    ap.add_argument("--seconds", type=float, default=8)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    d = Device(a.serial)
    if a.apk:
        d.install(a.apk)
    remote = "/sdcard/Android/data/%s/files/sound-capture.wav" % PKG
    remote_all = remote.replace(".wav", "-all.wav")
    d.shell("rm -f %s %s %s" % (remote, remote_all, remote.replace(".wav", ".json")), check=False)
    d.logcat_clear()
    d.launch(clear=False, extras="--ez soundcapture true")
    # a restored session may reopen this program from an earlier check: close those windows (only windows of
    # the program under test; anything else in the session is left alone), so the last burst is ours
    time.sleep(3)
    for _ in range(8):
        n = d.find("Close " + a.program, timeout=1)
        if n is None:
            break
        x0, y0, x1, y1 = n["bounds"]
        d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        time.sleep(2)
    time.sleep(1)
    d.tap("MENU", timeout=20)
    d.tap(a.menu)
    for _ in range(12):  # a long menu scrolls (Games... > Whap)
        if d.find(a.program, timeout=0.5) or not d.find("Scroll menu down", timeout=0.3):
            break
        d.tap("Scroll menu down", settle=0.4)
    d.tap(a.program)
    t0 = time.time()
    taps = [t for t in a.taps.split(",") if t]
    i = 0
    while time.time() - t0 < a.seconds:
        if taps:
            n = d.find(taps[i % len(taps)], timeout=1)
            if n:
                x0, y0, x1, y1 = n["bounds"]
                d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
            i += 1
        time.sleep(0.6)
    d.shot(os.path.join(a.out, "%s.png" % a.program))
    # a task that died with an unhandled exception prints it to the program's output (e.g. the Whap BadMem,
    # docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §15.1)
    fault = d.find("Unhandled exception", exact=False, timeout=1)
    print("unhandled exception on screen:", fault["label"] if fault else "none")
    if a.program == "Sound":
        done = d.find("Done.", exact=False, timeout=30)
        print("console shows Done.:", bool(done))
    # the capture is written when the speaker has been silent for half a second: leave the program
    d.key("KEYCODE_HOME")
    time.sleep(3)
    for l in d.logcat("TempleOS-Snd"):
        print(l)
    wav = os.path.join(a.out, "sound-capture.wav")
    # Sound is one burst (the last); a game's sounds are bursts separated by silences (all of this run's)
    d.adb("pull", remote if a.program == "Sound" else remote_all, wav)
    side = os.path.join(a.out, "sound-capture.json")
    if os.path.exists(side):
        os.remove(side)
    if a.program == "Sound":
        d.adb("pull", remote.replace(".wav", ".json"), side, check=False)
    args = [sys.executable, os.path.join(HERE, "analyze_capture.py"), wav, "--json", os.path.join(a.out, "analysis.json")]
    if a.program != "Sound":
        args.append("--stats")
    sys.exit(subprocess.run(args).returncode or (1 if fault else 0))


if __name__ == "__main__":
    main()
