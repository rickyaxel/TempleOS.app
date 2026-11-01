#!/usr/bin/env python3
"""Run the app's headless benchmark mode on a physical device and collect the results.

The bench builds install beside the user's app under their own ids (Android
com.digitalcircuitstudios.templeosapp.bench, iOS io.github.templeosmobile.bench), so the user's
installation and data are never touched. Each launch runs one spec (see
BenchMode.kt / BenchMode.swift) in a fresh process and exits.

    tools/native-validation/device_bench.py devices
    tools/native-validation/device_bench.py android SERIAL "programs=C:/Apps/X-Caliber/Run.HC;engines=native;secs=4;memmb=128;mode=parity;tag=xc" OUTDIR
    tools/native-validation/device_bench.py ios UDID "programs=...;tag=xc" OUTDIR
    tools/native-validation/device_bench.py android-install SERIAL APK  |  ios-install UDID APP
    tools/native-validation/device_bench.py android-uninstall SERIAL    |  ios-uninstall UDID

Results: OUTDIR/<tag>.jsonl (one JSON object per line: device, run, run_failed, error), the
checkpoint files of mode=parity runs, and OUTDIR/<tag>.console.txt. Waiting has no fixed
timeout: a run is considered alive while the app process exists (Android) or the console
stream is open (iOS); --max-minutes sets an upper bound (the run is then reported as
incomplete, never as finished).
"""
import json
import os
import subprocess
import sys
import time

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
PKG = "io.github.templeosmobile.bench"  # iOS bench bundle id
ANDROID_PKG = "com.digitalcircuitstudios.templeosapp.bench"
ACTIVITY = ANDROID_PKG + "/io.github.templeosmobile.android.MainActivity"


def sh(*args, check=True, capture=True, timeout=None):
    r = subprocess.run(args, capture_output=capture, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout if capture else ""


def tag_of(spec):
    for part in spec.split(";"):
        if part.startswith("tag="):
            return part[4:]
    return "bench"


def devices():
    print("Android (adb):")
    print(sh(ADB, "devices", "-l", check=False))
    print("iOS (devicectl):")
    out = sh("xcrun", "devicectl", "list", "devices", check=False)
    print("\n".join(l for l in out.splitlines() if "physical" in l or "Identifier" in l))


def android(serial, spec, outdir, max_minutes=None):
    a = [ADB, "-s", serial]
    os.makedirs(outdir, exist_ok=True)
    tag = tag_of(spec)
    # wake and dismiss an insecure keyguard (no setting is changed; the bench window keeps the screen on)
    sh(*a, "shell", "input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard", check=False)
    sh(*a, "logcat", "-c", check=False)
    sh(*a, "shell", "rm", "-rf", f"/sdcard/Android/data/{ANDROID_PKG}/files/bench/{tag}.jsonl", check=False)
    sh(*a, "shell", "am", "start", "-n", ACTIVITY, "--es", "bench", f"'{spec}'")
    t0 = time.time()
    time.sleep(3)
    complete = False
    while True:
        log = sh(*a, "logcat", "-d", "-s", "TOSBENCH", check=False)
        if f"DONE {tag}" in log:
            complete = True
            break
        alive = sh(*a, "shell", "pidof", ANDROID_PKG, check=False).strip()
        if not alive:
            break
        if max_minutes and time.time() - t0 > max_minutes * 60:
            break
        time.sleep(10)
    open(os.path.join(outdir, f"{tag}.console.txt"), "w").write(sh(*a, "logcat", "-d", "-s", "TOSBENCH:I", "AndroidRuntime:E", check=False))
    sh(*a, "pull", f"/sdcard/Android/data/{ANDROID_PKG}/files/bench/.", outdir, check=False)
    print(f"android {tag}: {'complete' if complete else 'INCOMPLETE (process ended or time bound)'} after {time.time() - t0:.0f} s")
    summarize(os.path.join(outdir, f"{tag}.jsonl"))
    return complete


def ios(udid, spec, outdir, max_minutes=None):
    os.makedirs(outdir, exist_ok=True)
    tag = tag_of(spec)
    t0 = time.time()
    with open(os.path.join(outdir, f"{tag}.console.txt"), "w") as con:
        p = subprocess.Popen(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "--console",
                              "--terminate-existing", PKG, "-bench", spec], stdout=con, stderr=subprocess.STDOUT)
        try:
            p.wait(timeout=max_minutes * 60 if max_minutes else None)
        except subprocess.TimeoutExpired:
            p.terminate()
    console = open(os.path.join(outdir, f"{tag}.console.txt")).read()
    complete = f"TOSBENCH DONE {tag}" in console
    sh("xcrun", "devicectl", "device", "copy", "from", "--device", udid, "--domain-type", "appDataContainer",
       "--domain-identifier", PKG, "--source", "Documents/bench", "--destination", outdir, check=False)
    print(f"ios {tag}: {'complete' if complete else 'INCOMPLETE'} after {time.time() - t0:.0f} s")
    summarize(os.path.join(outdir, f"{tag}.jsonl"))
    return complete


def summarize(path):
    if not os.path.exists(path):
        print("  (no results file)")
        return
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("event") == "run":
            print("  {program} {engine}{w}: {virtual_ms}/{requested_ms} ms virtual, wall {wall_ms:.0f} ms, cpu {cpu_ms:.0f} ms, ticks {ticks}, completed {completed}".format(
                w=" (warm-up)" if d.get("warmup") else "", **d))
        elif d.get("event") in ("run_failed", "error"):
            print("  " + json.dumps(d))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    maxm = None
    if "--max-minutes" in sys.argv:
        i = sys.argv.index("--max-minutes")
        maxm = float(sys.argv[i + 1])
        del sys.argv[i:i + 2]
    if cmd == "devices":
        devices()
    elif cmd == "android":
        sys.exit(0 if android(sys.argv[2], sys.argv[3], sys.argv[4], maxm) else 1)
    elif cmd == "ios":
        sys.exit(0 if ios(sys.argv[2], sys.argv[3], sys.argv[4], maxm) else 1)
    elif cmd == "android-install":
        print(sh(ADB, "-s", sys.argv[2], "install", "-r", sys.argv[3]))
    elif cmd == "android-uninstall":
        print(sh(ADB, "-s", sys.argv[2], "uninstall", ANDROID_PKG, check=False))
    elif cmd == "ios-install":
        print(sh("xcrun", "devicectl", "device", "install", "app", "--device", sys.argv[2], sys.argv[3]))
    elif cmd == "ios-uninstall":
        print(sh("xcrun", "devicectl", "device", "uninstall", "app", "--device", sys.argv[2], PKG, check=False))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
