# God Words vocabulary localization

TempleOS Mobile's God Words window (the "WORD" and "10 WORDS" buttons) picks entries from Terry A.
Davis' vocabulary exactly as TempleOS does. It can show each picked entry in the app's language.
This page describes how that works.
- Fidelity findings: fidelity-audit/TEMPLEOS_10_WORDS_FIDELITY_AUDIT.md.
- Coverage numbers: [localization-vocabulary-coverage.md](localization-vocabulary-coverage.md).

## The principle

**Terry's algorithm selects the entry; the localization layer only decides how the selected entry is
shown.**

```
tap ─▶ GodApp.latch()           timer >> 4, 24 bits into the FIFO      (GodPick / GodBitsIns)
     ─▶ GodApp.godBits(17)      17 bits out of the FIFO               (GodBits)
     ─▶ id = bits % 7569        entry index into Terry's word list    (GodWordStr)
     ─▶ log: Out.Words.ids += id        the window stores ids, never text
draw ─▶ Vocabulary.display(id)  translation of entry id for the current UI catalog, or the English entry
     ─▶ GodApp.layout / Surface.uiText  TempleOS font, or the platform text engine for other scripts
```

## Canonical vocabulary and entry identity

- **Source.** `C:/Adam/God/Vocab.DD` on the bundled drive. It is TempleOS V5.03's file, with one word
  replaced at build time (§ "The one replaced entry").
- **Tokenizer.** `GodVocab.tokenize` (Kotlin and Swift) and `tools/l10n/vocab.py canonical` all do the
  same thing as GodInit in `Adam/God/HolySpirit.HC`. They take the text part of the file, up to the
  first NUL, and split it into runs of `char_bmp_word` characters (`Kernel/StrA.HC`: `'`, `0-9`,
  `A-Z`, `_`, `a-z` and every byte ≥ 128). Entries are decoded as CP437.
- **Size.** The result is **7,569 entries**. Nothing is sorted, merged or deduplicated.
- **Identity.** An entry's identity is its index (0…7568). That is the index GodWordStr computes:
  `god.words[GodBits(17) % god.num_words]`.
- **Digest.** The identity of the whole list is the sha256 of the entries joined by `\n`, as UTF-8:
  `5c8d0fef1b73e2a0bea0806fcdd61ec75279fd1b67a0f2631831de287f7e3cce`. Every translation file names
  the digest it translates.

### The one replaced entry

- **The replacement.** An earlier owner decision censors one word in the bundled copy
  (content-moderation edit VO-5593, `tools/resource-packaging/moderation.json`; the original word, a
  homograph of a slur, is not repeated here). Entry 5592 is `delay` in the app.
- **Why the tokens still line up.** One word replaces one word, so the token count and every other
  index are unchanged. `GodWordsTest(s).bundledVocabularyMatchesTheIsoExceptTheDocumentedReplacement`
  checks this.
- **The side effect.** The list now contains `delay` twice (entries 1625 and 5592). The probability of
  showing the word "delay" is therefore 2/7569 instead of 1/7569. The probability of each entry index
  is unchanged.
- **Disclosure.** The replacement is stated in the About page (offensive words and remarks censored or redacted), on the website's legal page, in
  the document viewer's notice for `Vocab.DD`, and in `docs/licensing-and-provenance.md`.

## Translation files

- **Location.** `shared/runtime/l10n/vocab/<catalog>.deflate`: one file for each UI catalog in
  `shared/runtime/l10n/locales.json`. That manifest is the only list of languages; nothing hardcodes
  a count.
- **Format.** Raw DEFLATE (RFC 1951) of UTF-8 text:
  ```
  #templeos-vocab 1 count=7569 sha256=5c8d0fef…
  <translation of entry 0>
  <translation of entry 1>
  …
  ```
  An empty line means "not translated": the English entry is shown.
- **Size.** About 30–45 KB per catalog, 2–3 MB for all 72 (see coverage page).
- **Loading.** A file is read and decoded only when God Words is drawn in that language. Only the
  current catalog is kept in memory (`GodVocab.table` caches one).
- **Decoding.** Kotlin decompresses with `java.util.zip.Inflater(nowrap)`. Swift uses the system
  Compression framework (`COMPRESSION_ZLIB`, which is raw DEFLATE). Neither app adds a dependency or
  uses the network.

### Fallback and errors (runtime: never crash, show English)

| Situation | Status | Shown |
|---|---|---|
| English UI | `english` | the entries |
| Translation present | `ok` | the translation |
| Entry left empty by the translator | `ok` | the English entry (counted as missing in the coverage report) |
| Entry with a control character or a decoding error (U+FFFD) | `ok` | the English entry |
| No file for the catalog | `missing` | English entries |

The current bundled tables contain no blank entries. The 221 former blanks at 24 original
token indices are explicitly recorded in `shared/test-vectors/god-words/preserved-tokens.json`
as preserved names, abbreviations, fragments or standalone function words. Their displayed
output is unchanged from the former English fallback; they are not claimed as translated or
native-approved vocabulary. The validator checks the ledger against the canonical digest and
the compressed tables, and coverage reports count these tokens separately.
| File not raw DEFLATE, wrong header, wrong line count | `corrupt` | English entries |
| Header digest is not the vocabulary in use (e.g. the user wrote their own `C:/Adam/God/Vocab.DD`) | `mismatch` | English entries |

- **The pick never changes.** A missing translation never changes, rerolls or drops the picked
  entry.
- **Regional variants.** These follow the app's existing locale rules, because the vocabulary file is
  chosen by the UI catalog. For example, es-MX uses the `es` file, fr-CA the `fr` file, zh-HK the
  `zh-Hant` file, and pt-PT the `pt-BR` file.
- **No second preference.** God Words has no language setting of its own.

## Rendering

- **Language changes.** `GodApp` keeps a log of what was output: the intro, runs of picked entry ids,
  notices as l10n keys with arguments, and Bible passages. It renders that log in the current
  language every time the language version (`L10n.version`), the window width or the log changes. A
  language change therefore re-renders the same picks and never reads the timer or the bit FIFO;
  `GodWordsTest(s).changingTheLanguageShowsTheSamePicksAndDrawsNoBits` checks this.
- **Text drawing.** Text is drawn with `Surface.uiText`. CP437-representable text uses the TempleOS
  8×8 font; any other script is drawn as a platform text run. Platform runs handle shaping, bidi,
  Arabic joining, Indic clusters and CJK, so grapheme clusters are never split by the app.
- **Right-to-left.** RTL languages are right-aligned, as on the rest of the UI.
- **Wrapping.** Words are measured one at a time, so a long session stays cheap to wrap. A word wider
  than the window breaks through `Surface.wrapUi`.
- **Separators.** Picks are joined with a space, as Terry's `"%s "`. A translation may contain
  several words, and that is still one pick.
- **Bible passages.** Passages and their book names stay in English (Misc/Bible.TXT, the King James
  Bible). Only the "(line N)" header is localized.

## Tools

`tools/l10n/vocab.py`:

| Command | Purpose |
|---|---|
| `extract [--out FILE]` | the canonical entries as `index<TAB>English` (input for translators) |
| `import CATALOG TSV…` | translations `index<TAB>English<TAB>translation` → the shipped file. A line whose English column does not match the canonical entry at that index is **rejected**, never shifted. Translations are NFC-normalized, and whitespace is collapsed |
| `check` | every catalog has a file whose header matches the canonical vocabulary, with one line per entry and no control characters (exit 1 otherwise) |
| `report [--out MD]` | the coverage report |
| `vectors` | `shared/test-vectors/god-words/vectors.json`: fixed timer latches, the expected picks, the English and 15 locales' display strings. Both test suites use it |

### Adding a language or correcting a translation

1. Add the locale to `locales.json` (see `docs/localization.md`).
2. Run `vocab.py extract`, translate the `English` column, and keep the index and English columns
   exactly.
3. Run `vocab.py import <catalog> file.tsv`. Re-importing merges: new lines replace old ones, and
   other entries are kept.
4. Run `vocab.py check`, `vocab.py report --out docs/localization-vocabulary-coverage.md` and
   `vocab.py vectors`, then the test suites.

Program logic never changes for a translation fix.

### If the vocabulary itself changes

If `Vocab.DD` changes (for example the replacement is reverted), the digest changes. Every shipped
translation then reports `mismatch` and the app shows English until the files are rebuilt: re-import
(the English column check will flag changed entries), then run `check`.

## Swift / Kotlin parity

| | Kotlin | Swift |
|---|---|---|
| Tokenizer, digest, provider | `core/ui/GodVocab.kt` (`GodVocab`, `Vocabulary`) | `TempleCore/UI/GodVocab.swift` |
| Window | `core/ui/GodApp.kt` | `TempleCore/UI/GodApp.swift` |
| Tests | `GodWordsTest` | `GodWordsTests` |

- **Same inputs.** Both read the same files, the same `locales.json` resolution and the same vectors.
  For the same latches they produce the same entry ids and the same displayed strings
  (`translationsMatchTheSharedVectors`).
- **Platform difference: caching.** Android's runtime-file cache no longer keeps `l10n/` files; iOS
  already did not. So neither app holds every visited language's bytes.
