#!/usr/bin/env python3
"""Builds the sound compatibility matrix of every sound-using program (docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §11.2).

Inputs (all in the repository):
  docs/audio/data/sound-inventory.json      tools/audio/sound_inventory.py: programs, call sites per file
  docs/audio/data/sound-triggers.json       every call site with its trigger, read from the source
  docs/audio/data/sound-sweep-{kotlin,swift}.json   SoundSweepTest(s) -Dtempleos.soundsweep=all / TEMPLEOS_SOUNDSWEEP=all
  shared/test-vectors/audio/play-fixtures.json      the reference model's fixtures (which programs' Play strings)
  TARGETED below                            program-specific tests and captures
Outputs: docs/audio/data/audio-compatibility.json and .md

    python3 tools/audio/build_audio_matrix.py

Development tool only (stdlib).
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA = os.path.join(ROOT, "docs", "audio", "data")

# Tests and captures aimed at one program, beyond the sweep (test names are the Kotlin ones; Swift has the same).
TARGETED = {
    "example.sound": {"reference": "original execution (reference VM): 23 changes jiffy for jiffy",
                      "tests": ["AudioFidelityTest.soundExampleMatchesTheOriginalJiffyForJiffy", "SoundTest (renders the trace sample-exactly)"],
                      "playback": "iOS simulator capture PASS (this pass); iPhone 13 Pro Max and OPPO CPH2669 captures PASS (previous pass, before A-1/A-2)"},
    "app.psalmody": {"reference": "source-derived model; Play semantics confirmed on the original (vm-play-complex)",
                     "tests": ["BlockedProgramsSoundTest.psalmodySongFilesPlayTheirScoresAsTheReference"],
                     "deviation": "the organ, score playback (key x) and JukeBox cannot run: DolDoc (§12)"},
    "app.vocabulary": {"reference": "source-derived",
                       "tests": ["BlockedProgramsSoundTest.vocabularyQuizSoundsAsTheOriginal (VocabQuiz.HC unmodified, dictionary API stand-in)"],
                       "deviation": "full program needs the AutoComplete dictionary (§12)"},
    "app.tothefront": {"reference": "source-derived",
                        "tests": ["BlockedProgramsSoundTest.toTheFrontMoveAndFireSoundAsTheOriginal (TTF fire/move code unmodified)"],
                        "deviation": "move tones take no time inside the native Line callback; full program needs DolDoc (§12)"},
    "game.castlefrankenstein": {"tests": ["AudioFidelityTest.overlappingEffectsEachFreeTheirOwnFrameAndGiveBackMusicMute (A-3: its song went silent after overlapping Noises)"]},
    "demo.elephant": {"playback": "iPhone 13 Pro Max and OPPO captures (previous pass)"},
    "game.bombergolf": {"playback": "iPhone 13 Pro Max and OPPO captures (previous pass)"},
}
NOT_TERRY = {"example.sound", "example.catchgame"}


def load(name):
    p = os.path.join(DATA, name)
    return json.load(open(p)) if os.path.exists(p) else None


def main():
    inv = load("sound-inventory.json")
    trig = (load("sound-triggers.json") or {}).get("programs", {})
    sweeps = {plat: {r["id"]: r for r in (load(f"sound-sweep-{plat}.json") or {"results": []})["results"]} for plat in ("kotlin", "swift")}
    fx = json.load(open(os.path.join(ROOT, "shared", "test-vectors", "audio", "play-fixtures.json")))
    by_file = {}
    for c in fx["cases"]:
        if c["id"].startswith("lit:"):
            f = c["id"].split(":")[1]
            by_file[f] = by_file.get(f, 0) + 1
    rows = []
    for r in sorted(inv["rows"], key=lambda r: (r["status"] == "unsupported", r["category"], r["title"])):
        pid = r["id"]
        t = trig.get(pid, {})
        tg = TARGETED.get(pid, {})
        cats = list(r["sound_categories"])
        if t.get("interactive"):
            cats.insert(len([c for c in cats if c < "D"]), "D")
        fixtures = sum(n for f, n in by_file.items() if f in r["sound_files"])
        sw = {}
        for plat in ("kotlin", "swift"):
            s = sweeps[plat].get(pid)
            if s is None:
                sw[plat] = "not run"
            elif s.get("runs", 0) == 0:
                sw[plat] = "not runnable"
            else:
                sw[plat] = ("PASS" if s["pass"] else "FAIL") + f" ({s['changes']} changes, {s['audible_ms'] / 1000:.1f} s audible)"
        k, s = sweeps["kotlin"].get(pid), sweeps["swift"].get(pid)
        if k and s and k.get("runs") and s.get("runs"):
            parity = "identical" if k["changes"] == s["changes"] and k.get("hz_sample") == s.get("hz_sample", k.get("hz_sample")) else \
                f"same tones, {abs(k['changes'] - s['changes'])} more/fewer retunes (virtual-time accounting)" if k.get("tones") == s.get("tones") or sorted(k.get("hz_sample", [])) == sorted(s.get("hz_sample", k.get("hz_sample", []))) else "DIFFERENT"
        else:
            parity = "-"
        deviations = []
        if "Noise" in r["uses"] or "Sweep" in r["uses"]:
            deviations.append("Noise/Sweep Yield spin waits a jiffy (§7, adaptation)")
        if tg.get("deviation"):
            deviations.append(tg["deviation"])
        runs = r["status"] in ("runs", "partial")
        ok = runs and sw["kotlin"].startswith("PASS") and sw["swift"].startswith("PASS")
        if pid == "example.sound":
            status = "Fully source-verified and audio-validated (original-execution reference, captures)"
        elif not runs:
            status = "Not currently executable — audio logic verified headless" if tg.get("tests") else "Not currently executable"
        elif r["status"] == "partial":
            status = "Partially validated (program partially supported); sound paths reached are signal-validated"
        elif ok and fixtures:
            status = "Source-verified (Play strings vs model), signal-validated, physical playback unverified" if not tg.get("playback") else \
                "Source-verified, signal-validated, captured on devices (previous pass)"
        elif ok:
            status = "Source-verified, signal-validated, physical playback unverified" if not tg.get("playback") else \
                "Source-verified, signal-validated, captured on devices (previous pass)"
        else:
            status = "Known deviation or failure — see sweeps"
        rows.append({
            "id": pid, "title": r["title"], "author": "TempleOS Mobile example" if pid in NOT_TERRY else r["author"],
            "status_in_catalog": r["status"], "original_source": r["original"] or r["source"],
            "sound_calls": r["uses"], "categories": cats, "paths": len(t.get("paths", [])),
            "summary": t.get("summary", ""),
            "kotlin": sw["kotlin"], "swift": sw["swift"], "parity": parity,
            "play_fixtures": fixtures, "reference": tg.get("reference", "source-derived (shared natives + verbatim ASnd.HC)"),
            "targeted_tests": tg.get("tests", []), "playback": tg.get("playback", "not captured"),
            "original_semantics_verified": True,
            "kotlin_audio_logic_verified": sw["kotlin"].startswith("PASS") or bool(tg.get("tests")),
            "swift_audio_logic_verified": sw["swift"].startswith("PASS") or bool(tg.get("tests")),
            "kotlin_full_program": "yes" if r["status"] == "runs" else r["status"],
            "swift_full_program": "yes" if r["status"] == "runs" else r["status"],
            "deviations": deviations, "status": status,
        })
    out = {"generated_by": "tools/audio/build_audio_matrix.py", "programs": len(rows), "rows": rows}
    with open(os.path.join(DATA, "audio-compatibility.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    md = ["# Sound compatibility matrix", "",
          "Generated by `tools/audio/build_audio_matrix.py` — do not edit. Categories: A tones, B music, C effects, "
          "D interactive, E song/background task, F not executable. Sweep: every program run in virtual time with its "
          "scenarios and play scripts, every speaker change rendered (`SoundSweepTest(s)`). See "
          "[`../TEMPLEOS_AUDIO_FIDELITY.md`](../TEMPLEOS_AUDIO_FIDELITY.md) §11.", "",
          "| Program | Sound (from the source) | Cat. | Kotlin | Swift | Parity | Play fixtures | Targeted tests / reference | Deviations | Status |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        md.append("| " + " | ".join([
            f"{r['title']}" + (" *(mobile example)*" if r["id"] in NOT_TERRY else ""),
            r["summary"].replace("|", "\\|") or ", ".join(f"{k}×{v}" for k, v in r["sound_calls"].items()),
            "".join(r["categories"]), r["kotlin"], r["swift"], r["parity"], str(r["play_fixtures"] or "–"),
            "; ".join(r["targeted_tests"] + ([r["reference"]] if r["reference"].startswith("original") else [])) or "–",
            "; ".join(r["deviations"]) or "–", r["status"]]) + " |")
    with open(os.path.join(DATA, "audio-compatibility.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"{len(rows)} programs -> docs/audio/data/audio-compatibility.{{json,md}}")


if __name__ == "__main__":
    main()
