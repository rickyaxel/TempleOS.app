#!/usr/bin/env python3
"""God Words vocabulary localization (docs/localization-vocabulary.md).

The canonical vocabulary is Terry Davis' Adam/God/Vocab.DD split exactly as GodInit
(Adam/God/HolySpirit.HC) splits it: runs of char_bmp_word characters (Kernel/StrA.HC:
' 0-9 A-Z _ a-z and every byte >= 128) in the text part of the file. Entry i is identified by
its index; GodWordStr picks god.words[GodBits(17) % god.num_words], so translations never
change which entry is picked, only how it is shown.

Commands:
  vocab.py extract [--out FILE]        canonical entries as TSV: index, English (for translators)
  vocab.py import CATALOG TSV...       translations (index<TAB>English<TAB>translation) -> shipped file
  vocab.py check                       every shipped file matches the canonical vocabulary
  vocab.py report [--out MD]           coverage per catalog (Markdown)
  vocab.py vectors                     shared/test-vectors/god-words/vectors.json (Kotlin and Swift tests)

Shipped files: shared/runtime/l10n/vocab/<catalog>.deflate, raw DEFLATE of UTF-8 text:
  line 1: "#templeos-vocab 1 count=<n> sha256=<hex of the canonical entries joined by \\n>"
  line 1+i: the translation of entry i ("" = not translated: the app shows the English entry)
"""
import argparse
import hashlib
import json
import os
import sys
import unicodedata
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VOCAB = os.path.join(ROOT, "shared", "bundled-fs", "Adam", "God", "Vocab.DD")
L10N = os.path.join(ROOT, "shared", "runtime", "l10n")
OUT = os.path.join(L10N, "vocab")


def is_word(c):
    """Kernel/StrA.HC char_bmp_word."""
    return c == 0x27 or 0x30 <= c <= 0x39 or 0x41 <= c <= 0x5A or c == 0x5F or 0x61 <= c <= 0x7A or c >= 0x80


def canonical(path=VOCAB):
    data = open(path, "rb").read().split(b"\0")[0]  # FileRead text part; GodInit stops at the NUL
    out, i, n = [], 0, len(data)
    while i < n:
        while i < n and not is_word(data[i]):
            i += 1
        if i < n:
            j = i
            while i < n and is_word(data[i]):
                i += 1
            out.append(data[j:i].decode("cp437"))  # TempleOS text is CP437 (GodVocab.tokenize)
    return out


def digest(entries):
    return hashlib.sha256("\n".join(entries).encode("utf-8")).hexdigest()


def catalogs():
    m = json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))
    return sorted({l["catalog"] for l in m["locales"]} - {"en"})


def write_shipped(cat, lines, entries):
    head = "#templeos-vocab 1 count=%d sha256=%s" % (len(entries), digest(entries))
    text = "\n".join([head] + lines) + "\n"
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, cat + ".deflate"), "wb").write(c.compress(text.encode("utf-8")) + c.flush())


def read_shipped(cat):
    p = os.path.join(OUT, cat + ".deflate")
    if not os.path.exists(p):
        return None, None
    text = zlib.decompress(open(p, "rb").read(), -15).decode("utf-8")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines[0], lines[1:]


def clean(s):
    s = unicodedata.normalize("NFC", s.strip())
    # one entry per line: no line breaks or tabs inside a translation
    return " ".join(s.replace("\t", " ").split())


def cmd_import(cat, files, entries):
    have = {}
    _, old = read_shipped(cat)
    if old:
        for i, t in enumerate(old):
            if t:
                have[i] = t
    bad = 0
    for f in files:
        for ln, raw in enumerate(open(f, encoding="utf-8"), 1):
            raw = raw.rstrip("\n")
            if not raw.strip() or raw.startswith("#"):
                continue
            parts = raw.split("\t")
            if len(parts) < 3:
                print("%s:%d: expected index<TAB>English<TAB>translation" % (f, ln), file=sys.stderr); bad += 1; continue
            try:
                i = int(parts[0])
            except ValueError:
                print("%s:%d: bad index %r" % (f, ln, parts[0]), file=sys.stderr); bad += 1; continue
            if not 0 <= i < len(entries) or parts[1] != entries[i]:
                # the English column must match the canonical entry: misaligned work is rejected, never shifted
                print("%s:%d: index %d is %r, not %r" % (f, ln, i, entries[i] if 0 <= i < len(entries) else None, parts[1]), file=sys.stderr)
                bad += 1; continue
            t = clean("\t".join(parts[2:]))
            if t:
                have[i] = t
    write_shipped(cat, [have.get(i, "") for i in range(len(entries))], entries)
    print("%s: %d/%d entries translated, %d rejected lines" % (cat, len(have), len(entries), bad))
    return bad


def cmd_check(entries):
    h = "#templeos-vocab 1 count=%d sha256=%s" % (len(entries), digest(entries))
    errors = 0
    for cat in catalogs():
        head, lines = read_shipped(cat)
        if head is None:
            print("%s: missing" % cat); errors += 1; continue
        if head != h:
            print("%s: header %r does not match the canonical vocabulary %r" % (cat, head, h)); errors += 1
        if len(lines) != len(entries):
            print("%s: %d lines for %d entries" % (cat, len(lines), len(entries))); errors += 1
        for i, t in enumerate(lines):
            if "�" in t or any(ord(c) < 32 for c in t):
                print("%s: entry %d (%s) has invalid characters" % (cat, i, entries[i])); errors += 1
    ledger_path = os.path.join(ROOT, 'shared/test-vectors/god-words/preserved-tokens.json')
    if os.path.exists(ledger_path):
        ledger = json.load(open(ledger_path, encoding='utf-8'))
        if ledger['count'] != len(entries) or ledger['sha256'] != digest(entries):
            print('preserved-token ledger has a different canonical vocabulary'); errors += 1
        for token in ledger['tokens']:
            i = token['index']
            if not 0 <= i < len(entries) or entries[i] != token['english']:
                print('preserved-token ledger index mismatch:', i); errors += 1; continue
            for cat in token['catalogs']:
                if cat not in catalogs():
                    print('preserved-token ledger unknown catalog:', cat); errors += 1; continue
                _, lines = read_shipped(cat)
                if not lines or lines[i] != token['english']:
                    print('preserved-token ledger no longer matches:', cat, i); errors += 1
    print("check: %d errors" % errors)
    return errors


def coverage(entries):
    rows = []
    for cat in catalogs():
        head, lines = read_shipped(cat)
        if head is None:
            rows.append((cat, 0, len(entries), "missing")); continue
        n = sum(1 for t in lines if t)
        same = sum(1 for i, t in enumerate(lines) if t and t == entries[i])
        rows.append((cat, n, same, "complete" if n == len(entries) else "partial"))
    return rows


def cmd_report(entries, out):
    rows = coverage(entries)
    total = len(entries) * len(rows)
    present = sum(r[1] for r in rows)
    ledger_path = os.path.join(ROOT, 'shared/test-vectors/god-words/preserved-tokens.json')
    preserved = json.load(open(ledger_path, encoding='utf-8'))['tokens'] if os.path.exists(ledger_path) else []
    kept = sum(len(t['catalogs']) for t in preserved)
    kept_by_catalog = {cat: sum(cat in t['catalogs'] for t in preserved) for cat, *_ in rows}
    md = ["# God Words vocabulary coverage", "",
          "Generated by `tools/l10n/vocab.py report`. Canonical vocabulary: `Adam/God/Vocab.DD`, %d entries "
          "(GodInit's tokenizer), sha256 `%s`." % (len(entries), digest(entries)), "",
          "| | |", "|---|---|",
          "| Catalogs (non-English) | %d |" % len(rows),
          "| Expected resource entries | %d |" % total,
          "| Present resource entries | %d |" % present,
          "| Supplied localized entries (not native-certified) | %d |" % (present - kept),
          "| Explicitly preserved original tokens (included in Present, not certified translations) | %d |" % kept,
          "| Missing (shown in English) | %d |" % (total - present),
          "| Fully populated resource tables | %d |" % sum(1 for r in rows if r[3] == "complete"), "",
          "Translations identical to the English entry are counted as present: proper names and tokens such as `etext00` are "
          "kept as they are by design. The preserved-token ledger identifies the former blank entries retained verbatim; "
          "this does not turn them into translated words. Translations are machine-assisted and have not been certified by native speakers.", "",
          "| Catalog | Present | Same as English | Explicitly preserved | Resource status |", "|---|---|---|---|---|"]
    for cat, n, same, st in rows:
        md.append("| %s | %d / %d | %s | %d | %s |" % (cat, n, len(entries), same if isinstance(same, int) and st != "missing" else "—", kept_by_catalog[cat], st))
    text = "\n".join(md) + "\n"
    if out:
        open(out, "w", encoding="utf-8").write(text)
    print("\n".join(md[6:15]))


VECTOR_LOCALES = ["es-ES", "fr-FR", "de-DE", "ja-JP", "ar", "he-IL", "fa", "zh-CN", "zh-TW", "ko-KR", "hi-IN", "ru-RU", "th", "am", "el-GR"]


def god_session(actions, latches, n, good=24, bad=4):
    """GodApp's buttons on a timer that returns `latches` in order. Every button is TempleOS's F7:
    FifoU8Flush, then GodBitsIns(GOD_GOOD_BITS, t >> GOD_BAD_BITS) (least significant bit first).
    "word" is one GodWord, "ten" ten GodWord calls. GodBits takes bits oldest first
    (res = res<<1 + b: << binds tighter than + in HolyC) and latches again whenever the FIFO is
    empty, where TempleOS's GodPick would wait for an OKAY press. Returns (picks, latches read)."""
    from collections import deque
    it = iter(latches)
    fifo, picks, used = deque(), [], [0]

    def latch():
        v = next(it) >> bad
        used[0] += 1
        fifo.extend((v >> i) & 1 for i in range(good))

    def bits(k):
        r = 0
        while k:
            if fifo:
                r = (r << 1) + fifo.popleft(); k -= 1
            else:
                latch()
        return r

    for a in actions:
        fifo.clear(); latch()
        for _ in range(10 if a == "ten" else 1):
            picks.append(bits(17) % n)
    return picks, used[0]


def previous_mobile(latches, n, count):
    """The app before this pass: no flush, a latch before every pick, then 17 bits."""
    from collections import deque
    fifo, out, it = deque(), [], iter(latches)
    for _ in range(count):
        v = next(it) >> 4
        fifo.extend((v >> i) & 1 for i in range(24))
        r = 0
        for _ in range(17):
            r = (r << 1) + fifo.popleft()
        out.append(r % n)
    return out


def cmd_vectors(entries):
    import re
    latches, t, x = [], 1234567890123, 0x2545F491
    for _ in range(40):  # nanosecond timestamps of taps, 1-4000 us apart
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        t += 1000 + x % 4000000
        latches.append(t)
    actions = ["ten", "ten", "word", "ten", "word"]
    picks, used = god_session(actions, latches, len(entries))
    reads, done = [], []
    for k in range(1, len(actions) + 1):
        reads.append(god_session(actions[:k], latches, len(entries))[1])
    m = json.load(open(os.path.join(L10N, "locales.json"), encoding="utf-8"))
    cat_of = {l["id"]: l["catalog"] for l in m["locales"]}
    tr = {}
    for loc in VECTOR_LOCALES:
        _, lines = read_shipped(cat_of[loc])
        tr[loc] = [(lines[i] if lines and lines[i] else entries[i]) for i in picks]
    iso = canonical(os.path.join(ROOT, "reference", "templeos-iso", "Adam", "God", "Vocab.DD"))
    old = re.findall(r"[A-Za-z']+", open(VOCAB, "rb").read().split(b"\0")[0].decode("latin-1"))
    v = {
        "$comment": "Generated by tools/l10n/vocab.py vectors. GodApp with clock() returning `latches` in order, pressing `actions` (ten = 10 WORDS, word = WORD).",
        "count": len(entries), "sha256": digest(entries),
        "spot": {str(i): entries[i] for i in list(range(0, 12)) + [2313, 2314, 3100, 6586, 6588, 7568]},
        "iso_differs_at": {str(i): [a, b] for i, (a, b) in enumerate(zip(iso, entries)) if a != b},
        "iso_count": len(iso),
        "latches": latches,
        "actions": actions,
        "reads_after_action": reads,
        "picks": picks,
        "english": [entries[i] for i in picks],
        "display": tr,
        "previous_mobile": {"$comment": "The app before this pass (Regex [A-Za-z']+ tokenizer with one more entry, a latch before every pick, no F7 flush), same latches, first ten picks.",
                            "count": len(old), "english": [old[i] for i in previous_mobile(latches, len(old), 10)]},
    }
    out = os.path.join(ROOT, "shared", "test-vectors", "god-words")
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "vectors.json"), "w", encoding="utf-8").write(json.dumps(v, ensure_ascii=False, indent=1) + "\n")
    print("vectors: %d picks, %d locales" % (len(picks), len(tr)))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract"); e.add_argument("--out")
    im = sub.add_parser("import"); im.add_argument("catalog"); im.add_argument("tsv", nargs="+")
    sub.add_parser("check")
    r = sub.add_parser("report"); r.add_argument("--out")
    sub.add_parser("vectors")
    a = ap.parse_args()
    entries = canonical()
    if a.cmd == "extract":
        text = "".join("%d\t%s\n" % (i, w) for i, w in enumerate(entries))
        if a.out:
            open(a.out, "w", encoding="utf-8").write(text)
        else:
            sys.stdout.write(text)
        print("entries %d sha256 %s" % (len(entries), digest(entries)), file=sys.stderr)
    elif a.cmd == "import":
        return 1 if cmd_import(a.catalog, a.tsv, entries) else 0
    elif a.cmd == "check":
        return 1 if cmd_check(entries) else 0
    elif a.cmd == "report":
        cmd_report(entries, a.out)
    elif a.cmd == "vectors":
        cmd_vectors(entries)
    return 0


if __name__ == "__main__":
    sys.exit(main())
