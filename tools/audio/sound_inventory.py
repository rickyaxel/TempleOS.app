#!/usr/bin/env python3
"""Inventory of the catalog programs that use TempleOS sound, by API (docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §10).

Scans each catalog program's source (shared/bundled-fs, the same files the apps run): the program file, every file
it #includes, and, for programs under C:/Apps/, every HolyC file of the application's directory (ToTheFront loads
its AIs with ExeFile, Psalmody's songs are files it runs). It counts the sound calls of Kernel/KMisc.HC and
Adam/ASnd.HC: Snd, Beep, Mute, SndRst, Play, Noise, Sweep, music.* settings, song tasks (song_task, CurSongTask,
SndTaskEndCB), Ona2Freq/Freq2Ona, and the mobile-only SndFreq. Every one of them ends in the same natives
(Snd/Mute/SndRst), so they all use the shared speaker path.

Library paths that make sound for a program without a call in its source (SettingsPush/SettingsPop turn the
speaker off; Kernel/KDbg.HC beeps on entering the debugger; DolDoc $SO$ songs) are listed in the document, §10.4.

    python3 tools/audio/sound_inventory.py      # writes docs/audio/data/sound-inventory.json, prints a table

Development tool only (stdlib).
"""
import json
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FS = os.path.join(ROOT, "shared", "bundled-fs")
ISO = os.path.join(ROOT, "reference", "templeos-iso")
CATALOG = os.path.join(ROOT, "shared", "program-manifests", "catalog.json")
OUT = os.path.join(ROOT, "docs", "audio", "data", "sound-inventory.json")

APIS = [
    ("Snd", r"\bSnd\s*(\(|;)"),
    ("Beep", r"\bBeep\s*(\(|;)"),
    ("Play", r"(?<!\")\bPlay\s*\("),
    ("Noise", r"\bNoise\s*\("),
    ("Sweep", r"\bSweep\s*\("),
    ("Mute", r"\b(Mute|IsMute)\s*\("),
    ("SndRst", r"\bSndRst\b"),
    ("music", r"\bmusic\.\w+"),
    ("song task", r"\b(song_task|CurSongTask|cur_song|SndTaskEndCB)\b"),
    ("Ona2Freq/Freq2Ona", r"\b(Ona2Freq|Freq2Ona)\s*\("),
    ("SndFreq", r"\bSndFreq\s*\("),
]


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def resolve(path, base_dir):
    p = path.replace("::/", "").replace("C:/", "")
    if p.startswith("~/"):
        p = "Home/" + p[2:]
    cand = [os.path.join(FS, p), os.path.join(base_dir, p)]
    for c in cand:
        for ext in ("", ".HC", ".HH"):
            if os.path.isfile(c + ext):
                return c + ext
    return None


def sources(entry):
    """The program file, everything it #includes (transitively), and for an application its directory's HolyC."""
    first = os.path.join(FS, entry["path"].replace("C:/", ""))
    seen, todo = [], [first]
    if entry["path"].startswith("C:/Apps/"):
        app = os.path.join(FS, *entry["path"].replace("C:/", "").split("/")[:2])
        for dp, _, fs in sorted(os.walk(app)):
            todo += [os.path.join(dp, f) for f in sorted(fs) if f.endswith((".HC", ".HH"))]
    while todo:
        f = todo.pop(0)
        if f in seen or not os.path.isfile(f):
            continue
        seen.append(f)
        text = open(f, "rb").read().decode("latin-1")
        for inc in re.findall(r'#include\s+"([^"]+)"', text):
            r = resolve(inc, os.path.dirname(f))
            if r:
                todo.append(r)
    return seen


def categories(uses, status):
    """Doc §10.1: A basic tones, B music, C procedural effects, E background/task sound, F not executable.
    (D, interactive, is per-trigger and comes from the compatibility matrix.)"""
    c = []
    if uses.get("Snd") or uses.get("Beep") or uses.get("SndFreq"):
        c.append("A")
    if uses.get("Play") or uses.get("music"):
        c.append("B")
    if uses.get("Noise") or uses.get("Sweep") or uses.get("Ona2Freq/Freq2Ona"):
        c.append("C")
    if uses.get("song task"):
        c.append("E")
    if status == "unsupported":
        c.append("F")
    return c


def original_path(rel):
    """The ISO file the bundled one came from, and whether it is byte-identical (TempleOS Mobile examples have none)."""
    iso = os.path.join(ISO, rel)
    if not os.path.isfile(iso):
        return None, None
    return rel, open(iso, "rb").read() == open(os.path.join(FS, rel), "rb").read()


def main():
    cat = json.load(open(CATALOG))["programs"]
    rows = []
    for e in cat:
        files = sources(e)
        per_file, total = {}, {}
        for f in files:
            text = strip_comments(open(f, "rb").read().decode("latin-1"))
            u = {name: len(re.findall(rx, text)) for name, rx in APIS}
            u = {k: v for k, v in u.items() if v}
            if u:
                per_file[os.path.relpath(f, FS)] = u
                for k, v in u.items():
                    total[k] = total.get(k, 0) + v
        rel = os.path.relpath(os.path.join(FS, e["path"].replace("C:/", "")), FS)
        orig, identical = original_path(rel) if os.path.isdir(ISO) else (None, None)
        rows.append({"id": e["id"], "title": e["title"], "category": e["category"], "status": e["status"],
                     "author": e["author"], "source": rel, "original": orig, "identical_to_iso": identical,
                     "files": [os.path.relpath(f, FS) for f in files], "uses": total, "sound_files": per_file,
                     "sound_categories": categories(total, e["status"]),
                     "declares_sound": "sound" in e.get("capabilities", [])})
    sound = [r for r in rows if r["uses"]]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    doc = {"generated_by": "tools/audio/sound_inventory.py", "programs": len(rows), "with_sound": len(sound),
           "mismatch_with_catalog_capability": [r["id"] for r in rows if bool(r["uses"]) != r["declares_sound"]],
           "rows": sound}
    with open(OUT, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print(f"{len(sound)} of {len(rows)} catalog programs call TempleOS sound; wrote {os.path.relpath(OUT, ROOT)}")
    for r in sorted(sound, key=lambda r: (r["category"], r["title"])):
        print(f"  {r['category']:8s} {r['title']:20s} {r['status']:12s} {''.join(r['sound_categories']):5s} "
              + ", ".join(f"{k}x{v}" for k, v in r["uses"].items()))
    if doc["mismatch_with_catalog_capability"]:
        print("catalog 'sound' capability differs from the source for:", doc["mismatch_with_catalog_capability"])


if __name__ == "__main__":
    main()
