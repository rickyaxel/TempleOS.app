#!/usr/bin/env python3
"""Checks a recording of the device speaker against the TempleOS reference trace of the Sound example.

The recordings come from the apps' debug sound capture: iOS `-soundcapture` (the engine's main mixer
output, Documents/sound-capture.wav) and Android `--ez soundcapture true` (the samples written to the
AudioTrack, <external files>/sound-capture.wav). See docs/audio/TEMPLEOS_SOUND.md.

For every speaker change of shared/test-vectors/audio/sound-example.json (TempleOS V5.03's own timing for
C:/Home/Examples/Sound.HC) it measures, relative to the first onset:
  * the pitch inside each note (rising zero crossings, 2 ms trimmed at both ends),
  * when each note starts: after a rest from the envelope; after another note (no rest) from the 8254
    restart (a new count starts a new period with OUT high), located from the half-periods;
  * when each note before a rest stops.
It then checks the timing relationships: start-to-start intervals, note and rest lengths (each within the
reference's tolerance) and the overall tempo (drift within 1%).

    python3 tools/audio/analyze_capture.py sound-capture.wav [--json out.json]
    python3 tools/audio/analyze_capture.py sound-capture.wav --stats    # any other program: tones, pitches, level

Exit status 0 when every pitch is within 0.3% and every timing relationship within tolerance.
Development tool only (stdlib).
"""
import json
import math
import os
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REF = os.path.join(ROOT, "shared", "test-vectors", "audio", "sound-example.json")


def read_wav(path):
    """(samples of channel 0 as floats, rate). PCM 16/24/32-bit, IEEE float 32/64, extensible."""
    b = open(path, "rb").read()
    if b[:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise SystemExit(f"{path}: not a WAV file")
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(b):
        cid, size = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        body = b[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, align, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, rate, align, bits)
        elif cid == b"data":
            data = body if size != 0xFFFFFFFF else b[pos + 8:]
        pos += 8 + size + (size & 1)
    tag, ch, rate, align, bits = fmt
    n = len(data) // align
    if tag == 3:
        code = "f" if bits == 32 else "d"
        vals = struct.unpack(f"<{n * ch}{code}", data[:n * align])
        x = list(vals[0::ch])
    elif tag == 1 and bits == 16:
        x = [v / 32768.0 for v in struct.unpack(f"<{n * ch}h", data[:n * align])[0::ch]]
    elif tag == 1 and bits in (24, 32):
        w = bits // 8
        x = []
        for i in range(n):
            o = i * align
            v = int.from_bytes(data[o:o + w], "little", signed=True)
            x.append(v / float(1 << (bits - 1)))
    else:
        raise SystemExit(f"{path}: unsupported WAV format tag {tag}, {bits} bits")
    return x, rate


def crossings(x, a, b):
    """Interpolated sign changes in x[a:b]: (position, rising)."""
    out = []
    for j in range(max(a, 1), min(b, len(x))):
        p, q = x[j - 1], x[j]
        if (p < 0) != (q < 0) and p != q:
            out.append((j - 1 + (0 - p) / (q - p), q >= 0))
    return out


def pitch(x, rate, a, b):
    r = [c for c, up in crossings(x, a, b) if up]
    return (len(r) - 1) / ((r[-1] - r[0]) / rate) if len(r) > 2 else 0.0


def segment(x, rate):
    """The tones in x: [(start sample, end sample, Hz)]. A tone ends at a silence (0.5 ms near zero) or where
    the half-period changes to a new stable value; that boundary follows the 8254 (a new count restarts the
    period with OUT high), so it is placed exactly, not at the next edge."""
    peak = max(abs(v) for v in x) or 1.0
    quiet = peak * 0.1
    gap = max(2, int(rate * 0.0005))
    tones, i, n = [], 0, len(x)
    while i < n:
        while i < n and abs(x[i]) < quiet:
            i += 1
        if i >= n:
            break
        a = i
        run = 0
        while i < n and run < gap:
            run = run + 1 if abs(x[i]) < quiet else 0
            i += 1
        b = i - run  # end of the sounding run
        # sign changes inside [a, b), then split where the half-period settles on another value
        e = [j - 1 + (0 - x[j - 1]) / (x[j] - x[j - 1]) for j in range(a + 1, b) if (x[j - 1] < 0) != (x[j] < 0) and x[j] != x[j - 1]]
        hp = [q - p for p, q in zip(e, e[1:])]
        start = a
        k = 1
        while k + 3 < len(hp):
            ref_h = hp[k - 1]
            new_h = hp[k + 1]
            if abs(new_h - ref_h) > max(1.5, 0.02 * ref_h) and all(abs(hp[k + d] - new_h) <= max(1.5, 0.02 * new_h) for d in (1, 2, 3)):
                # the edge e[k+1] starts the new note's stable half-periods; if the run before it was high the
                # restart was inside that run, one new half-period earlier
                high_before = x[int(e[k]) + 1] > 0
                bnd = e[k + 1] - new_h if high_before else e[k + 1]
                tones.append((start, int(round(bnd))))
                start = int(round(bnd))
                k += 3
            else:
                k += 1
        tones.append((start, b))
    out = []
    for a, b in tones:
        hz = pitch(x, rate, a + int(rate * 0.002), b - int(rate * 0.002)) or pitch(x, rate, a, b)
        out.append((a, b, hz))
    return out


def analyze(x, rate, ref, time_rate=None):
    """time_rate: the device's samples per second of the system clock (Android sidecar device_hz), used to turn
    sample positions into the system time the kernel dated its settings in; pitch stays as rendered."""
    tr = time_rate or rate
    tones = segment(x, rate)
    if not tones:
        return {"ok": False, "problems": ["no sound in the recording"]}
    ev = ref["events"]
    tol_ms = ref["tolerance"]["t_ms"]
    tol_hz = ref["tolerance"]["hz_rel"]
    s0 = tones[0][0]
    ms = lambda i: (i - s0) * 1000.0 / tr
    want = [(k, e) for k, e in enumerate(ev) if e["ona"] != 0]
    problems = []
    if len(tones) != len(want):
        problems.append(f"{len(tones)} tones in the recording, TempleOS plays {len(want)}: " +
                        ", ".join(f"{t[2]:.0f}Hz@{ms(t[0]):.0f}" for t in tones[:30]))
    notes, rests = [], []
    for (k, e), (a, b, hz) in zip(want, tones):
        nxt = next((f for f in ev[k + 1:] if f["t_ms"] > e["t_ms"] or f["ona"] != 0), None)
        rest_after = nxt is not None and nxt["ona"] == 0
        notes.append({"ona": e["ona"], "ref_ms": e["t_ms"], "ref_hz": e["hz"], "start_ms": round(ms(a), 2),
                      "end_ms": round(ms(b), 2), "hz": round(hz, 3), "rest_after": rest_after,
                      "ref_len_ms": (nxt["t_ms"] - e["t_ms"]) if nxt is not None else None})
        if abs(hz - e["hz"]) > e["hz"] * tol_hz:
            problems.append(f"ona {e['ona']} at {e['t_ms']} ms: {hz:.2f} Hz, TempleOS {e['hz']} Hz")
    intervals, lengths = [], []
    for p_, q in zip(notes, notes[1:]):
        got, w = q["start_ms"] - p_["start_ms"], q["ref_ms"] - p_["ref_ms"]
        intervals.append(round(got - w, 2))
        if abs(got - w) > tol_ms:
            problems.append(f"interval ona {p_['ona']} -> {q['ona']}: {got:.2f} ms, TempleOS {w} ms")
        if p_["rest_after"] and p_["ref_len_ms"] and p_["ref_len_ms"] < w:
            note_len, rest_len = p_["end_ms"] - p_["start_ms"], q["start_ms"] - p_["end_ms"]
            lengths.append({"note_ms": round(note_len, 2), "ref_note_ms": p_["ref_len_ms"], "rest_ms": round(rest_len, 2), "ref_rest_ms": w - p_["ref_len_ms"]})
            if abs(note_len - p_["ref_len_ms"]) > tol_ms:
                problems.append(f"note ona {p_['ona']} lasts {note_len:.2f} ms, TempleOS {p_['ref_len_ms']} ms")
            if abs(rest_len - (w - p_["ref_len_ms"])) > tol_ms:
                problems.append(f"rest after ona {p_['ona']} lasts {rest_len:.2f} ms, TempleOS {w - p_['ref_len_ms']} ms")
    last = notes[-1] if notes else None
    if last and last["ref_len_ms"]:
        lengths.append({"note_ms": round(last["end_ms"] - last["start_ms"], 2), "ref_note_ms": last["ref_len_ms"], "rest_ms": None, "ref_rest_ms": None})
    drift = notes[-1]["start_ms"] - notes[-1]["ref_ms"] if notes else None
    if drift is not None and abs(drift) > max(tol_ms, 0.01 * notes[-1]["ref_ms"]):
        problems.append(f"overall drift {drift:.2f} ms by {notes[-1]['ref_ms']} ms")
    return {
        "ok": not problems, "rate": rate, "first_onset_s": round(s0 / rate, 4), "notes": notes, "rests": lengths,
        "interval_dev_ms": intervals, "max_interval_dev_ms": round(max((abs(v) for v in intervals), default=0), 2),
        "max_note_len_dev_ms": round(max((abs(l["note_ms"] - l["ref_note_ms"]) for l in lengths), default=0), 2),
        "max_rest_len_dev_ms": round(max((abs(l["rest_ms"] - l["ref_rest_ms"]) for l in lengths if l["rest_ms"] is not None), default=0), 2),
        "drift_ms": None if drift is None else round(drift, 2),
        "max_pitch_dev_pct": round(max((abs(n["hz"] - n["ref_hz"]) / n["ref_hz"] * 100 for n in notes), default=0), 4),
        "problems": problems,
    }


def stats(x, rate):
    """For programs without a reference trace: audible time, tone segments and their pitches, level, DC."""
    peak = max((abs(v) for v in x), default=0.0)
    thr = 0.0625 if peak > 0.1 else peak / 2  # half of PcSpeaker.AMPLITUDE (the mixer may lower the level)
    win = max(1, int(rate * 0.001))
    segs, cur = [], None
    for i in range(0, len(x), win):
        on = max((abs(v) for v in x[i:i + win]), default=0) >= thr
        if on and cur is None:
            cur = i
        if not on and cur is not None:
            segs.append((cur, i)); cur = None
    if cur is not None:
        segs.append((cur, len(x)))
    tones = [{"start_ms": round(a * 1000 / rate, 1), "ms": round((b - a) * 1000 / rate, 1), "hz": round(pitch(x, rate, a, b), 1)} for a, b in segs]
    audible = sum(t["ms"] for t in tones)
    mean = sum(x) / len(x) if x else 0.0
    return {"ok": audible > 20 and peak <= 0.13, "rate": rate, "peak": round(peak, 4), "dc": round(mean, 6), "audible_ms": round(audible, 1),
            "segments": len(tones), "tones": tones[:40], "problems": [] if audible > 20 else ["no audible tone"]}


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    x, rate = read_wav(sys.argv[1])
    if "--stats" in sys.argv:
        r = stats(x, rate)
        r["file"] = os.path.abspath(sys.argv[1])
        if "--json" in sys.argv:
            with open(sys.argv[sys.argv.index("--json") + 1], "w") as f:
                json.dump(r, f, indent=1)
        print(f"{r['file']}: {rate} Hz, {len(x) / rate:.2f} s, peak {r['peak']}, DC {r['dc']}, audible {r['audible_ms']} ms in {r['segments']} tones")
        for t in r["tones"][:20]:
            print(f"  {t['start_ms']:9.1f} ms  {t['ms']:7.1f} ms  {t['hz']:9.1f} Hz")
        print("PASS" if r["ok"] else "FAIL")
        sys.exit(0 if r["ok"] else 1)
    ref = json.load(open(REF))
    side = os.path.splitext(sys.argv[1])[0] + ".json"
    dev = json.load(open(side)).get("device_hz") if os.path.exists(side) else None
    if dev:
        print(f"device plays {dev} samples per system second (rendered at {rate})")
    r = analyze(x, rate, ref, dev if dev and abs(dev / rate - 1) < 0.05 else None)
    r["device_hz"] = dev
    r["file"] = os.path.abspath(sys.argv[1])
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w") as f:
            json.dump(r, f, indent=1)
    print(f"{r['file']}: {rate} Hz")
    for n in r.get("notes", []):
        s = f"{n['start_ms']:8.2f}"
        print(f"  ona {n['ona']:3d}  start {s} ms (TempleOS {n['ref_ms']:8.2f})  {n['hz']:9.3f} Hz (TempleOS {n['ref_hz']:9.4f})")
    for l in r.get("rests", []):
        print(f"  note {l['note_ms']:7.2f} ms (TempleOS {l['ref_note_ms']:.2f})  rest {l['rest_ms']} ms (TempleOS {l['ref_rest_ms'] if l['ref_rest_ms'] is None else round(l['ref_rest_ms'], 2)})")
    if r.get("notes"):
        print(f"  max deviation: interval {r['max_interval_dev_ms']} ms, note length {r['max_note_len_dev_ms']} ms, "
              f"rest length {r['max_rest_len_dev_ms']} ms; drift {r['drift_ms']} ms; pitch {r['max_pitch_dev_pct']}%")
    for p in r["problems"]:
        print("  PROBLEM:", p)
    print("PASS" if r["ok"] else "FAIL")
    sys.exit(0 if r["ok"] else 1)


if __name__ == "__main__":
    main()
