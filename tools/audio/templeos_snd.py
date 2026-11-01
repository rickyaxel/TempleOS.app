#!/usr/bin/env python3
"""TempleOS V5.03 sound semantics, ported line by line from the original HolyC, for reference fixtures.

This model is the independent reference for TempleOS Mobile's sound tests (docs/audio/TEMPLEOS_AUDIO_FIDELITY.md).
It is written from the official ISO's source (reference/templeos-iso), never from the Kotlin or Swift code:

* Kernel/KernelA.HH  SYS_TIMER_FREQ = 18333*65536/1000; JIFFY_FREQ = 1000;
                     SYS_TIMER0_PERIOD = 65536*182/10/JIFFY_FREQ = 1192 (PIT channel 0 count, Kernel/KMain.HC)
* Kernel/KMisc.HC    Ona2Freq, Freq2Ona, Snd (PIT channel 2, mode 3, count = ClampI64(SYS_TIMER_FREQ/Ona2Freq(ona),
                     1,U16_MAX); the same ona leaves the PIT alone), Sleep(mS) = SleepUntil(cnts.jiffies+mS)
* Adam/ASnd.HC       Play, MusicSetMeter/Octave/NoteLen, Note2Ona, MusicSettingsRst, music's initial values

Time is counted in jiffies, as TempleOS counts it. A jiffy is one period of PIT channel 0, 1192 clocks of the
PC's 1193182 Hz oscillator: 0.999009 ms, not 1 ms (the reference VM counts 20019 jiffies in 20 RTC seconds).
Pitch uses the same oscillator: the speaker plays 1193182/count Hz, about 0.7 % flat, because SYS_TIMER_FREQ is
1201471. F64 to I64 conversion truncates (Compiler/BackFA.HC FISTTP). `I64 += F64` rounds the sum to a double
before truncating; the reference VM gives the same results as IEEE double arithmetic (docs §4.4).

    python3 tools/audio/templeos_snd.py              # writes the fixtures (sound-example.json, play-fixtures.json)
    python3 tools/audio/templeos_snd.py --check-vm   # compares the model with the reference-VM captures

Development tool only (stdlib).
"""
import json
import math
import os
import re
import sys

SYS_TIMER_FREQ = 18333 * 65536 // 1000            # Kernel/KernelA.HH: 1201471, the frequency TempleOS assumes
PIT_FREQ = 1193182                                # the PC's 8254 input clock
JIFFY_FREQ = 1000                                 # Kernel/KernelA.HH (nominal)
SYS_TIMER0_PERIOD = 65536 * 182 // 10 // JIFFY_FREQ  # 1192: PIT channel 0 count (mode 2), one jiffy
U16_MAX, I8_MAX = 0xFFFF, 127
NOTE_MAP = [0, 2, 3, 5, 7, 8, 10]                 # Adam/ASnd.HC music.note_map (A B C D E F G)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FS = os.path.join(ROOT, "shared", "bundled-fs")
VECTORS = os.path.join(ROOT, "shared", "test-vectors", "audio")


class UndefinedBehaviour(Exception):
    """The original reads outside music.note_map (a note character below 'A'): no defined result."""


def i8(v):
    v = int(v) & 0xFF
    return v - 256 if v >= 128 else v


def jiffy_ns(j):
    """Start of jiffy j in ns since jiffy 0 (exact integer arithmetic, rounded up)."""
    t = j * SYS_TIMER0_PERIOD
    return (t // PIT_FREQ) * 1_000_000_000 + -(-(t % PIT_FREQ) * 1_000_000_000 // PIT_FREQ)


def jiffy_ms(j):
    return j * SYS_TIMER0_PERIOD * 1000.0 / PIT_FREQ


# ------------------------------------------------------------------ Kernel/KMisc.HC

def ona2freq(ona):
    """Ona2Freq(I8 ona): 440.0/32*2.0`(ona/12.0); 0 is a rest."""
    ona = i8(ona)
    return 0.0 if ona == 0 else 440.0 / 32 * 2.0 ** (ona / 12.0)


def freq2ona(freq):
    """Freq2Ona(F64 freq): ClampI64(12*Log2(32.0/440.0*freq),1,I8_MAX), 0 for freq <= 0."""
    if not freq > 0:
        return 0
    return max(1, min(I8_MAX, int(12 * math.log2(32.0 / 440.0 * freq))))


def pit_count(ona):
    """The count Snd(ona) writes to PIT channel 2: ClampI64(SYS_TIMER_FREQ/Ona2Freq(ona),1,U16_MAX)."""
    return max(1, min(U16_MAX, int(SYS_TIMER_FREQ / ona2freq(ona))))


def speaker_hz(ona):
    """The tone the PC speaker makes after Snd(ona); 0 = off."""
    return 0.0 if i8(ona) == 0 else PIT_FREQ / pit_count(ona)


def table_hashes():
    """The two hashes the reference VM printed (docs §4.2): every nonzero I8 ona's PIT count, Freq2Ona(k*0.37)."""
    m = (1 << 64) - 1
    h = 0
    for k in range(-128, 128):
        if k:
            h = (h * 31 + pit_count(k)) & m
    f = 0
    for k in range(1, 24001):
        f = (f * 31 + freq2ona(k * 0.37)) & m
    return "%X" % h, "%X" % f


class Speaker:
    """Snd/Mute as Kernel/KMisc.HC: one setting at a time; the ona already set leaves the PIT alone (scrncast.ona).
    `changes` lists (jiffy, ona) for every audible change of the speaker."""

    def __init__(self):
        self.ona = 0
        self.muted = False
        self.changes = []

    def snd(self, j, ona=0):
        ona = i8(ona)
        if self.muted:
            return
        if ona != self.ona:
            self.changes.append((j, ona))
        self.ona = ona


# ------------------------------------------------------------------ Adam/ASnd.HC

class Music:
    """CMusicGlbls music={NULL,NULL,4,1.0,{0,2,3,5,7,8,10},FALSE,4,4,2.5,0.9,0,0,0,0}."""

    def __init__(self):
        self.octave = 4
        self.note_len = 1.0
        self.mute = 0
        self.meter_top, self.meter_bottom = 4, 4
        self.tempo = 2.5
        self.stacatto_factor = 0.9
        self.play_note_num = 0
        self.tM_correction = 0.0

    def settings_rst(self, spk, j):
        """MusicSettingsRst (SndRst turns the speaker off)."""
        self.play_note_num = 0
        self.stacatto_factor = 0.9
        self.tempo = 2.5
        self.octave = 4
        self.note_len = 1.0
        self.meter_top = self.meter_bottom = 4
        spk.snd(j, 0)


def _ch(st, i):
    return st[i] if i < len(st) else 0


def _set_meter(m, st, i):
    ch = _ch(st, i); i += 1
    while ch == ord('M'):
        ch = _ch(st, i); i += 1
        if ord('0') <= ch <= ord('9'):
            m.meter_top = ch - ord('0')
            ch = _ch(st, i); i += 1
        if ch == ord('/'):
            ch = _ch(st, i); i += 1
        if ord('0') <= ch <= ord('9'):
            m.meter_bottom = ch - ord('0')
            ch = _ch(st, i); i += 1
    return i - 1


def _set_octave(m, st, i):
    ch = _ch(st, i); i += 1
    while ord('0') <= ch <= ord('9'):
        m.octave = ch - ord('0')
        ch = _ch(st, i); i += 1
    return i - 1


def _set_note_len(m, st, i):
    while True:
        c = _ch(st, i); i += 1
        if c == ord('w'): m.note_len = 4.0
        elif c == ord('h'): m.note_len = 2.0
        elif c == ord('q'): m.note_len = 1.0
        elif c == ord('e'): m.note_len = 0.5
        elif c == ord('s'): m.note_len = 0.25
        elif c == ord('t'): m.note_len = 2.0 * m.note_len / 3.0
        elif c == ord('.'): m.note_len = 1.5 * m.note_len
        else:
            return i - 1


def note2ona(note, octave=4):
    """Note2Ona: mid C is ona 51 (note 3, octave 4); returns I8."""
    return i8((octave + 1) * 12 + note if note < 3 else octave * 12 + note)


def play(m, spk, st, j):
    """Play(U8 *st): the speaker changes go to spk; returns the jiffy at which Play returns.
    j is cnts.jiffies when Play is called. A task that wakes exactly at its jiffy is assumed (no lateness)."""
    if isinstance(st, str):
        st = st.encode("latin-1")
    m.play_note_num = 0
    i = 0
    while _ch(st, i):
        timeout_val = j
        tie = False
        while True:
            last = i
            if _ch(st, i) == ord('('):
                tie = True
                i += 1
            else:
                i = _set_meter(m, st, i)
                i = _set_octave(m, st, i)
                i = _set_note_len(m, st, i)
            if i == last:
                break
        if not _ch(st, i):
            break
        note = _ch(st, i) - ord('A'); i += 1
        if note < 7:
            if note < 0:
                raise UndefinedBehaviour(f"note character {chr(note + 65)!r} reads music.note_map[{note}]")
            note = NOTE_MAP[note]
            octave = m.octave
            if _ch(st, i) == ord('b'):
                note -= 1
                if note == 2:
                    octave -= 1
                i += 1
            elif _ch(st, i) == ord('#'):
                note += 1
                if note == 3:
                    octave += 1
                i += 1
            ona = note2ona(note, octave)
        else:
            ona = 0
        d = JIFFY_FREQ * m.note_len / m.tempo
        on_jiffies = d * m.stacatto_factor
        off_jiffies = d * (1.0 - m.stacatto_factor)
        timeout_val = int(float(timeout_val) + on_jiffies)     # I64 += F64: the sum as F64, truncated
        timeout_val2 = int(float(timeout_val) + off_jiffies)
        if not m.mute:
            spk.snd(j, ona)
        j = max(j, timeout_val)                                 # SleepUntil(timeout_val)
        m.tM_correction += on_jiffies - int(on_jiffies)
        if not m.mute and not tie:
            spk.snd(j, 0)
        j = max(j, timeout_val2)
        m.tM_correction += off_jiffies - int(off_jiffies)
        m.play_note_num += 1
    return j


def sleep(j, ms):
    """Sleep(mS) from jiffy j: SleepUntil(cnts.jiffies+mS*JIFFY_FREQ/1000); Sleep(0) is Yield."""
    return j + ms * JIFFY_FREQ // 1000 if ms > 0 else j


# ------------------------------------------------------------------ programs and fixtures

def sound_example(j0):
    """C:/Home/Examples/Sound.HC (a TempleOS Mobile example that calls the original Snd and Play)."""
    spk, m, j = Speaker(), Music(), j0
    for ona in range(60, 73, 2):          # for (ona=60;ona<=72;ona+=2) {"%d ",ona;Snd(ona);Sleep(150);}
        spk.snd(j, ona)
        j = sleep(j, 150)
    spk.snd(j, 0)                         # Snd;
    j = play(m, spk, "4eCDEFGAB5C", j)    # Play("4eCDEFGAB5C");
    return spk.changes, j


def events_json(changes, j0):
    return [[j - j0, ona] for j, ona in changes]


HC_STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def hc_unescape(s):
    return re.sub(r"\\(.)", lambda mo: {"n": "\n", "t": "\t", "0": "\0"}.get(mo.group(1), mo.group(1)), s)


def play_literals(path):
    """The literal first arguments of Play(...) in a HolyC file (comments removed)."""
    text = open(path, "rb").read().decode("latin-1")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    out = []
    # (not inside a string: JukeBox.HC searches files for the text "Play(")
    for mo in re.finditer(r'(?<!")\bPlay\s*\(\s*"', text):
        lit = HC_STRING.match(text, mo.end() - 1)
        if lit:
            out.append(hc_unescape(lit.group(1)))
    return out


def song_settings(path):
    """music.tempo / music.stacatto_factor assignments of a Psalmody song file, in order."""
    text = open(path, "rb").read().decode("latin-1")
    tempo = re.search(r"music\.tempo\s*=\s*([0-9.]+)", text)
    sf = re.search(r"music\.stacatto_factor\s*=\s*([0-9.]+)", text)
    return (float(tempo.group(1)) if tempo else 2.5), (float(sf.group(1)) if sf else 0.9)


def fixture(fid, provenance, strings, j0=2_000, tempo=2.5, stacatto=0.9, note=""):
    """One Play fixture: MusicSettingsRst, the settings, then each string with Play, from cnts.jiffies = j0."""
    spk, m = Speaker(), Music()
    m.settings_rst(spk, j0)
    m.tempo, m.stacatto_factor = tempo, stacatto
    j = j0
    for s in strings:
        j = play(m, spk, s, j)
    return {"id": fid, "provenance": provenance, "note": note, "j0": j0, "tempo": tempo, "stacatto_factor": stacatto,
            "play": strings, "events": events_json(spk.changes, j0), "end": j - j0,
            "state": {"octave": m.octave, "note_len": m.note_len, "meter": [m.meter_top, m.meter_bottom]}}


SYNTHETIC = [
    # (id, strings, tempo, stacatto, note)
    ("durations", ["4wChCqCeCsCtCtC.C"], 2.5, 0.9, "w h q e s, t applied twice, then dotted"),
    ("dotted-and-triplet", ["q.CeDetEFGq.A"], 2.5, 0.9, "q. then e then triplet eighths"),
    ("ties", ["qC(qC(eCDeD(qEF"], 2.5, 0.9, "a tie leaves the note sounding into the next one"),
    ("tie-at-end", ["qCD(qE"], 2.5, 0.9, "a final tied note is left sounding when Play returns"),
    ("tie-across-pitch", ["eC(eDE(sFGA"], 2.5, 0.9, "a tie to a different pitch changes it without a gap"),
    ("accidentals", ["4C#DbEbFF#GbG#AbA#BbB#Cb"], 2.5, 0.9, "B# is C of the next octave, Cb B of the one below"),
    ("octaves", ["0C1C2C3C4C5C6C7C8C9C9G#9B#"], 4.0, 0.9, "every octave digit; 9B# is ona 123"),
    ("low-octave-flats", ["0AbAB0Cb"], 2.5, 0.9, "Ab in octave 0 is ona 11; 0Cb is ona -1... (I8)"),
    ("rests", ["qCReDRRsE"], 2.5, 0.9, "letters after G are rests (R)"),
    ("lowercase-rest", ["qCxD"], 2.5, 0.9, "a lowercase letter that is not a duration is a rest"),
    ("meters", ["M3/4qCM6/8eDM2EM/F"], 2.5, 0.9, "meters only set music.meter_top/bottom"),
    ("meter-then-octave", ["M3/45qC"], 2.5, 0.9, "M3/4 then octave 5"),
    ("staccato-1", ["qCDE"], 2.5, 1.0, "stacatto_factor 1.0: no gap, Snd off and the next note in the same jiffy"),
    ("staccato-0.5", ["qCDhE"], 2.5, 0.5, "half on, half off"),
    ("staccato-0", ["qCD"], 2.5, 0.0, "stacatto_factor 0.0: every note only a Snd and an off in the same jiffy"),
    ("tempo-fast", ["sCDEFGAB5C"], 7.3, 0.9, "fractional jiffy durations"),
    ("tempo-slow", ["eCtDEF"], 0.77, 0.83, "long fractional durations"),
    ("tempo-odd", ["etCDEFGetAB"], 3.3, 0.75, "triplets at an odd tempo"),
    ("persistent-state", ["5eC", "D", "tE", "F"], 2.5, 0.9, "octave and length persist from one Play to the next"),
    ("empty", [""], 2.5, 0.9, "nothing"),
    ("only-settings", ["5h."], 2.5, 0.9, "only an octave and a length: no note, the settings persist"),
]

VM_CASES = {
    # captured on the original TempleOS V5.03 in the reference VM (tools/audio/vm_semantics.py), CPU 1, QEMU -icount
    "vm-sound-example": {"captured": [[60, 0], [62, 150], [64, 300], [66, 450], [68, 600], [70, 750], [72, 900], [51, 1050],
                                      [0, 1230], [53, 1250], [0, 1430], [55, 1450], [0, 1630], [56, 1650], [0, 1830],
                                      [58, 1850], [0, 2030], [60, 2050], [0, 2230], [62, 2250], [0, 2430], [63, 2450],
                                      [0, 2630]], "j0": 127910},
    "vm-play-complex": {"captured": [[63, 0], [0, 227], [63, 302], [65, 604], [0, 679], [67, 704], [0, 779], [68, 804],
                                     [0, 879], [58, 904], [0, 1585], [61, 1812], [0, 1868], [61, 1886], [0, 1942],
                                     [39, 1960], [0, 2869], [38, 4384], [0, 4611], [87, 4686], [0, 4913], [83, 4988],
                                     [0, 5101], [82, 5138], [0, 5365]], "j0": 198658,
                        "tempo": 3.3, "stacatto": 0.75, "play": "M3/45qC(qCetDEF4h.GsA#Bb3wCRqCb6B#eAbqG"},
}


def vm_model(name):
    c = VM_CASES[name]
    if name == "vm-sound-example":
        ch, _ = sound_example(c["j0"])
    else:
        spk, m = Speaker(), Music()
        m.tempo, m.stacatto_factor = c["tempo"], c["stacatto"]
        play(m, spk, c["play"], c["j0"])
        m.settings_rst(spk, 0)
        ch = spk.changes
    j0 = ch[0][0]
    return [[ona, j - j0] for j, ona in ch]


def check_vm():
    """The model against the reference-VM captures. The capture polls scrncast.ona from a task on the same CPU,
    so two changes in one jiffy show as the last one (the Sound example's Snd; and Play's first note)."""
    ok = True
    for name, c in VM_CASES.items():
        model = vm_model(name)
        # collapse changes within one jiffy, as the poller sees them
        seen = []
        for ona, j in model:
            if seen and seen[-1][1] == j:
                seen[-1] = [ona, j]
            else:
                seen.append([ona, j])
        seen = [e for k, e in enumerate(seen) if k == 0 or e[0] != seen[k - 1][0]]
        good = seen == c["captured"]
        ok &= good
        print(f"{name}: {'MATCH' if good else 'DIFFERENT'} ({len(c['captured'])} changes)")
        if not good:
            print("  model:   ", seen)
            print("  captured:", c["captured"])
    h, f = table_hashes()
    good = (h, f) == ("F2B15FAF231EBC7F", "43F7F076B2A8A3C0")
    ok &= good
    print(f"PIT count and Freq2Ona tables: {'MATCH' if good else 'DIFFERENT'} ({h} {f})")
    return ok


def program_fixtures():
    """Every literal Play string of the bundled programs (default settings unless the program's song file sets them)."""
    cat = json.load(open(os.path.join(ROOT, "shared", "program-manifests", "catalog.json")))["programs"]
    out, seen = [], set()
    paths = []
    for e in cat:
        d = os.path.dirname(os.path.join(FS, e["path"].replace("C:/", "")))
        main = os.path.join(FS, e["path"].replace("C:/", ""))
        files = [main] if not e["path"].startswith("C:/Apps/") else \
            [os.path.join(dp, f) for dp, _, fs in os.walk(d) for f in sorted(fs) if f.endswith(".HC")]
        for p in files:
            if p not in paths and os.path.isfile(p):
                paths.append((e["title"], p))
    for title, p in paths:
        for s in play_literals(p):
            key = (os.path.relpath(p, FS), s)
            if key in seen or not s:
                continue
            seen.add(key)
            rel = os.path.relpath(p, FS)
            try:
                out.append(fixture(f"lit:{rel}:{len([k for k in seen if k[0] == rel])}", "source-derived (literal in " + rel + ")",
                                   [s], note=title))
            except UndefinedBehaviour as ex:
                out.append({"id": f"lit:{rel}", "provenance": "source", "note": f"{title}: {ex}", "skip": True, "play": [s]})
    return out


def psalmody_fixtures():
    out = []
    d = os.path.join(FS, "Apps", "Psalmody", "Examples")
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        tempo, sf = song_settings(p)
        strings = play_literals(p)
        out.append(fixture(f"psalmody:{f}", "source-derived (Apps/Psalmody/Examples/" + f + ", one pass of its loop)",
                           strings, tempo=tempo, stacatto=sf, note=f"music.tempo={tempo} stacatto_factor={sf}"))
    return out


def main():
    if "--check-vm" in sys.argv:
        return 0 if check_vm() else 1
    changes, end = sound_example(200_000)
    doc = {
        "program": "C:/Home/Examples/Sound.HC",
        "derivation": "tools/audio/templeos_snd.py from Kernel/KMisc.HC Snd/Ona2Freq/Sleep and Adam/ASnd.HC Play "
                      "(TempleOS V5.03); confirmed jiffy for jiffy on the original in the reference VM (vm-sound-example)",
        "jiffy_ns": SYS_TIMER0_PERIOD * 1e9 / PIT_FREQ,
        "tolerance": {"t_ms": 3, "hz_rel": 0.003},  # device captures (tools/audio/analyze_capture.py)
        "events": [{"jiffy": j - changes[0][0], "t_ms": round(jiffy_ms(j - changes[0][0]), 4), "ona": ona,
                    "hz": round(speaker_hz(ona), 4)} for j, ona in changes],
        "end_jiffy": end - changes[0][0],
    }
    os.makedirs(VECTORS, exist_ok=True)
    with open(os.path.join(VECTORS, "sound-example.json"), "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    cases = []
    for name in VM_CASES:
        c = VM_CASES[name]
        if name == "vm-play-complex":
            cases.append(fixture(name, "original execution (reference VM capture, tools/audio/vm_semantics.py)",
                                 [c["play"]], tempo=c["tempo"], stacatto=c["stacatto"],
                                 note=f"captured from cnts.jiffies {c['j0']}; the model gives the same events from 2000"))
    for fid, strings, tempo, sf, note in SYNTHETIC:
        cases.append(fixture("syn:" + fid, "synthetic edge case, expected values from the source-derived model",
                             strings, tempo=tempo, stacatto=sf, note=note))
    cases += psalmody_fixtures()
    cases += program_fixtures()
    for c in cases:
        if not c.get("skip"):
            far = fixture(c["id"], "", c["play"], j0=200_000, tempo=c["tempo"], stacatto=c["stacatto_factor"])
            assert (far["events"], far["end"]) == (c["events"], c["end"]), c["id"]
    pitch = [[o, pit_count(o), PIT_FREQ / pit_count(o)] for o in range(-128, 128) if o]
    fx = {
        "generated_by": "tools/audio/templeos_snd.py",
        "spec": "docs/audio/TEMPLEOS_AUDIO_FIDELITY.md",
        "j0_note": "every case gives the same events (relative to j0) for any j0 from 2000 to 200000 (checked when "
                   "generated); 2000 keeps the virtual-time runs short",
        "how_to_run": "SleepUntil(j0); MusicSettingsRst; music.tempo=..; music.stacatto_factor=..; Play(each string). "
                      "events: [jiffies after j0, ona] for each audible speaker change, starting with the MusicSettingsRst off "
                      "only if the speaker was on; end: jiffies after j0 when the last Play returns.",
        "jiffy_pit_clocks": SYS_TIMER0_PERIOD, "pit_hz": PIT_FREQ, "sys_timer_freq": SYS_TIMER_FREQ,
        "table_hashes_from_reference_vm": {"pit_counts": "F2B15FAF231EBC7F", "freq2ona_k_0_37": "43F7F076B2A8A3C0"},
        # I64 += F64 on the original (x87, FNINIT precision): typed into the reference VM, printed values
        "arith_from_reference_vm": {
            "source": "F64 o=400.0*(1.0-0.9);I64 a=60000,b=70000,c=300000,d=10,e=1000;a+=o;b+=o;c+=o;d+=o;e+=o;",
            "printed": {"a": 40, "b": 40, "c": 40, "d": 39, "e": 40}},
        "pit_counts": pitch,
        "cases": [c for c in cases if not c.get("skip")],
        "skipped": [c for c in cases if c.get("skip")],
    }
    with open(os.path.join(VECTORS, "play-fixtures.json"), "w") as f:
        json.dump(fx, f, indent=1)
        f.write("\n")
    print(f"wrote sound-example.json ({len(changes)} changes) and play-fixtures.json ({len(fx['cases'])} cases, "
          f"{len(fx['skipped'])} skipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
