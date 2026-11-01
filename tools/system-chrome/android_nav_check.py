#!/usr/bin/env python3
"""Checks that Android's navigation region continues the TempleOS screen (docs/ui-normalization/SYSTEM_CHROME.md).

Drives the installed app through its accessibility tree (tools/performance-analysis/android_ui.py), takes a
screenshot per state and compares, in device pixels:
  nav     the most common color inside the navigation bar frame (from `dumpsys window`), i.e. under the
          gesture handle or between the three buttons;
  edge    the most common color of the 3-pixel band of app content touching the bar;
  icons   the mean color of the handle / button pixels and its WCAG contrast with `nav`.
A state passes when nav == edge (within 6 per channel) and the icons have the polarity (dark/light) that
contrasts more with that color, or when the device keyboard is up (its window draws the region). The
icon contrast is reported, not judged: its exact value is the system's icon style (compare a baseline run). A transition check records the screen while
navigating quickly and reports any frame whose navigation region turned black under non-black content.

  android_nav_check.py -s emulator-5554 --out DIR [--mode gestural|threebutton|keep] [--install APK]
                       [--scenarios a,b,...] [--no-transitions] [--no-clear]

`--mode` switches the emulator's navigation overlay (cmd overlay; emulator only) and restores the
previous mode at the end. Writes DIR/<mode>/<scenario>.png and DIR/<mode>/results.json, prints a table.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "performance-analysis"))
from android_ui import ADB, Device  # noqa: E402

from PIL import Image  # noqa: E402

OVERLAY = "com.android.internal.systemui.navbar."


def lum(c):
    def lin(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def mode_color(im, box):
    x0, y0, x1, y1 = box
    crop = im.crop((x0, y0, x1, y1))
    colors = crop.getcolors(maxcolors=1 << 20) or []
    return max(colors)[1] if colors else None


def close(a, b, tol=6):
    return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))


def window_state(d):
    out = d.shell("dumpsys window", check=False)
    nav = re.search(r"InsetsSource id=\w+ type=navigationBars frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\] visible=(\w+)", out)
    ime = re.search(r"InsetsSource id=\w+ type=ime frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\] visible=(\w+)", out)
    frame = tuple(int(v) for v in nav.groups()[:4]) if nav and nav.group(5) == "true" else None
    ime_up = bool(ime and ime.group(5) == "true" and int(ime.group(4)) > int(ime.group(2)))
    if not nav:  # Android 10 and older: no InsetsSource lines; read the NavigationBar / InputMethod windows
        out = d.shell("dumpsys window windows", check=False)

        def win(name):
            m = re.search(r"Window\{\w+ u0 " + name + r"\}:(.*?)isOnScreen=(\w+)", out, re.S)
            if not m or m.group(2) != "true" or "mViewVisibility=0x0" not in m.group(1):
                return None
            f = re.search(r"mFrame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", m.group(1))
            return tuple(int(v) for v in f.groups()) if f else None
        frame = win(r"NavigationBar\d*")
        ime_up = win("InputMethod") is not None
    return frame, ime_up


NAV_HEIGHT = None


def measure(d, path):
    d.shot(path)
    frame, ime_up = window_state(d)
    if frame and NAV_HEIGHT and (frame[2] - frame[0]) >= (frame[3] - frame[1]):
        frame = (frame[0], frame[3] - NAV_HEIGHT, frame[2], frame[3])
    im = Image.open(path).convert("RGB")
    w, h = im.size
    r = {"shot": os.path.basename(path), "nav_frame": frame, "ime": ime_up}
    if not frame:
        r.update(ok=True, note="no navigation bar shown")
        return r
    x0, y0, x1, y1 = frame
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    if y1 - y0 <= 0 or x1 - x0 <= 0:
        r.update(ok=True, note="navigation bar outside the screenshot")
        return r
    side = "bottom" if (x1 - x0) >= (y1 - y0) else ("right" if x1 >= w else "left")
    nav = mode_color(im, (x0, y0, x1, y1))
    band = {"bottom": (x0, y0 - 3, x1, y0), "right": (x0 - 3, y0, x0, y1), "left": (x1, y0, x1 + 3, y1)}[side]
    edge = mode_color(im, band)
    # handle / button pixels: clearly different from the bar's background. A side bar also spans the
    # TempleOS top bar (drawn across the full width): rows whose adjacent content is not the bar's color
    # belong to it, not to the buttons.
    def differs(p):
        return sum(abs(u - v) for u, v in zip(p, nav)) > 60
    px = []
    for y in range(y0, y1):
        if side != "bottom":
            ax = x0 - 1 if side == "right" else x1
            if 0 <= ax < w and differs(im.getpixel((ax, y))):
                continue
        for x in range(x0, x1):
            p = im.getpixel((x, y))
            if differs(p):
                px.append(p)
    icon = tuple(sum(c[i] for c in px) // len(px) for i in range(3)) if px else None
    icon_contrast = round(contrast(icon, nav), 2) if icon else None
    match = close(nav, edge)
    black_strip = nav is not None and lum(nav) < 0.01 and not (edge and lum(edge) < 0.01)
    # The app only chooses dark or light icons; their exact color is the system's (ColorOS draws mid-gray
    # outlines in both styles). Pass: the matching color and the polarity that contrasts more with it.
    icons = ("dark" if lum(icon) < lum(nav) else "light") if icon else None
    want = "dark" if nav and lum(nav) > 0.1791 else "light"
    polarity_ok = icons is None or icons == want
    ok = ime_up or (match and polarity_ok)
    r.update(side=side, nav=nav, edge=edge, icon=icon, icon_contrast=icon_contrast,
             icons=icons, polarity_ok=polarity_ok,
             match=match, black_strip=black_strip, ok=ok)
    return r


def record_transitions(d, out_dir, actions, seconds=8):
    """Screen-records [actions] and returns frames whose navigation region is black under non-black content."""
    remote = "/sdcard/templeos-nav.mp4"
    frame, _ = window_state(d)
    rec = subprocess.Popen([ADB, "-s", d.serial, "shell", "screenrecord", "--time-limit", str(seconds), "--bit-rate", "8000000", remote])
    time.sleep(1.0)
    actions()
    rec.wait(timeout=seconds + 20)
    local = os.path.join(out_dir, "transitions.mp4")
    d.adb("pull", remote, local, check=False)
    frames_dir = os.path.join(out_dir, "transition-frames")
    os.makedirs(frames_dir, exist_ok=True)
    for f in os.listdir(frames_dir):
        os.remove(os.path.join(frames_dir, f))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", local, "-fps_mode", "passthrough", os.path.join(frames_dir, "f%04d.png")], check=False)
    bad, total = [], 0
    for f in sorted(os.listdir(frames_dir)):
        im = Image.open(os.path.join(frames_dir, f)).convert("RGB")
        w, h = im.size
        if not frame:
            continue
        x0, y0, x1, y1 = frame
        if y1 > h or x1 > w:  # rotated while recording: skip
            continue
        total += 1
        nav = mode_color(im, (x0, y0, x1, y1))
        edge = mode_color(im, (x0, max(0, y0 - 3), x1, y0)) if (x1 - x0) >= (y1 - y0) else None
        if nav and lum(nav) < 0.01 and edge and lum(edge) > 0.01:
            bad.append(f)
    return {"frames": total, "black_frames": bad[:20], "black_count": len(bad)}


def set_rotation(d, landscape):
    """Fixed rotation: the settings provider, or `wm user-rotation` where shell may not write settings (ColorOS)."""
    r = 1 if landscape else 0
    ok = "Exception" not in d.shell("settings put system accelerometer_rotation 0 && settings put system user_rotation %d 2>&1" % r, check=False)
    if not ok:
        d.shell("wm user-rotation lock %d" % r, check=False)
    time.sleep(2)


def scenarios(d, out, clear=True):
    """(name, action) pairs; each action leaves the app in the state to measure."""
    def tap(label, settle=1.0):
        d.tap(label, settle=settle)

    def back():
        d.key(4)
        time.sleep(0.8)

    def close_focused():
        n = next((n for n in d.nodes() if n["label"].startswith("Close ")), None)
        if n:
            x0, y0, x1, y1 = n["bounds"]
            d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
            time.sleep(1.0)

    def game():
        tap("MENU"); tap("Games..."); tap("CharDemo", settle=4.0)

    def rotate(landscape):
        set_rotation(d, landscape)
        time.sleep(1.5)

    def background_resume():
        d.key(3)
        time.sleep(1.5)
        d.shell("am start -n com.digitalcircuitstudios.templeosapp/io.github.templeosmobile.android.MainActivity")
        time.sleep(2.0)

    def desktop_color():
        tap("MENU"); tap("Settings")
        n = d.find("Desktop color", exact=False)
        x0, y0, x1, y1 = n["bounds"]
        d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
        time.sleep(1.0)

    def device_keyboard():
        tap("MENU"); tap("Terminal"); tap("Use the device keyboard", settle=2.0)

    return [
        ("01-welcome-doc" if clear else "01-launch", lambda: (d.launch(clear=clear), time.sleep(2))),
        ("02-start-menu", lambda: tap("MENU")),
        ("03-menu-closed", back),
        ("04-terminal-templeos-keyboard", lambda: (tap("MENU"), tap("Terminal", settle=1.5))),
        ("05-terminal-key-row", lambda: tap("Hide keyboard")),
        ("06-terminal-closed", close_focused),
        ("07-documentation", lambda: (tap("MENU"), tap("Documentation", settle=1.5))),
        ("08-game", game),
        ("09-game-closed", close_focused),
        ("10-landscape", lambda: rotate(True)),
        ("11-landscape-menu", lambda: tap("MENU")),
        ("12-landscape-menu-closed", back),
        ("13-portrait-again", lambda: rotate(False)),
        ("14-background-resume", background_resume),
        ("15-settings-desktop-color", desktop_color),
        ("16-all-closed-desktop", lambda: (tap("Close all windows", settle=1.5), close_focused())),
        ("17-device-keyboard", device_keyboard),
        ("18-device-keyboard-hidden", back),
        ("19-back-to-templeos-keyboard", lambda: (tap("Use the TempleOS keyboard", settle=1.5) if d.find("Use the TempleOS keyboard", timeout=2) else None)),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--serial", default="emulator-5554")
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="keep", choices=["keep", "gestural", "threebutton"])
    ap.add_argument("--install")
    ap.add_argument("--scenarios", help="comma-separated name prefixes (default: all)")
    ap.add_argument("--no-transitions", action="store_true")
    ap.add_argument("--no-clear", action="store_true", help="keep the app's data (a personal device): start from its saved session")
    ap.add_argument("--nav-height", type=int, help="bottom bar height in px when dumpsys reports another (Android 10 gesture mode reports the "
                                                    "48 dp button frame; apps get the 16 dp gesture inset: 42 px at 420 dpi)")
    a = ap.parse_args()
    global NAV_HEIGHT
    NAV_HEIGHT = a.nav_height
    d = Device(a.serial)
    if a.install:
        d.install(a.install)
    previous = None
    if a.mode != "keep":
        listing = d.shell("cmd overlay list", check=False)
        m = re.search(r"\[x\] " + re.escape(OVERLAY) + r"(\w+)", listing)
        previous = m.group(1) if m else None
        d.shell("cmd overlay enable-exclusive --category " + OVERLAY + a.mode)
        time.sleep(4)
    label = a.mode if a.mode != "keep" else (re.search(r"\[x\] " + re.escape(OVERLAY) + r"(\w+)", d.shell("cmd overlay list", check=False)) or [None, "default"])[1]
    out = os.path.join(a.out, label)
    os.makedirs(out, exist_ok=True)
    auto_rotate = d.shell("settings get system accelerometer_rotation", check=False).strip()
    set_rotation(d, False)
    results = {"device": a.serial, "sdk": d.shell("getprop ro.build.version.sdk").strip(),
               "model": d.shell("getprop ro.product.model").strip(), "mode": label, "states": {}}
    try:
        for name, act in scenarios(d, out, clear=not a.no_clear):
            if a.scenarios and not any(name.startswith(p) or p in name for p in a.scenarios.split(",")):
                continue
            try:
                act()
                time.sleep(0.6)
                results["states"][name] = measure(d, os.path.join(out, name + ".png"))
            except Exception as e:  # keep going: report the state as not measured
                results["states"][name] = {"ok": False, "error": str(e)}
        if not a.no_transitions:
            def rapid():
                for _ in range(3):
                    d.tap("MENU", settle=0.15); d.key(4)
                    d.tap("MENU", settle=0.15); d.tap("Terminal", settle=0.3)
                    n = next((n for n in d.nodes() if n["label"] == "Close Terminal"), None)
                    if n:
                        x0, y0, x1, y1 = n["bounds"]; d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
                    time.sleep(0.2)
            d.launch()
            time.sleep(1.5)
            results["transitions"] = record_transitions(d, out, rapid)
    finally:
        # never leave the app on the device keyboard (state 17 switches to it; the setting persists)
        if d.find("Use the TempleOS keyboard", timeout=1):
            d.tap("Use the TempleOS keyboard", settle=1.0)
        set_rotation(d, False)
        if auto_rotate == "1":
            d.shell("settings put system accelerometer_rotation 1 2>/dev/null || wm user-rotation free", check=False)
        if previous and previous != a.mode:
            d.shell("cmd overlay enable-exclusive --category " + OVERLAY + previous)
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    print("%s sdk %s %s" % (results["model"], results["sdk"], label))
    print("%-32s %-6s %-6s %-15s %-15s %-6s %s" % ("state", "ok", "side", "nav", "edge", "icons", "contrast"))
    for k, r in results["states"].items():
        print("%-32s %-6s %-6s %-15s %-15s %-6s %s %s" % (k, r.get("ok"), r.get("side", "-"), r.get("nav"), r.get("edge"), r.get("icons"),
                                                        r.get("icon_contrast"), ("IME " if r.get("ime") else "") + (r.get("error") or r.get("note") or "")))
    if "transitions" in results:
        t = results["transitions"]
        print("transitions: %d frames, %d with a black navigation region under non-black content" % (t["frames"], t["black_count"]))
    return 0 if all(r.get("ok") for r in results["states"].values()) and not results.get("transitions", {}).get("black_count") else 1


if __name__ == "__main__":
    sys.exit(main())
