# Content moderation of the original TempleOS material

TempleOS.app (iOS and Android) ships Terry A. Davis' TempleOS V5.03 files: games, demos, source and
documentation. Most of it is technical, religious or eccentric, and it is kept as he wrote it. A
small part contains slurs and derogatory remarks about groups of people. This document records the
editorial policy for that material, what was changed, how it is built, and what is left for human
judgement. Offensive wording is not quoted here: items are named by id, file and line.

This is a project-internal standard for a PG-oriented presentation. It is not an Apple or Google
Play age rating, which must be assessed separately under each store's criteria.

## 1. Policy

**Moderated:**
- racial, ethnic, antisemitic, homophobic and other identity-directed slurs;
- derogatory remarks, stereotypes, generalizations or dehumanizing statements about groups of
  people or religious communities;
- remarks that trivialize mass killings or disasters;
- explicit profanity.

A statement whose *meaning* is offensive is redacted as a whole. Masking one word would leave it
intact.

**Kept:**
- religious themes and theology;
- Terry's beliefs and his conversations with God;
- scripture and its links;
- technical text;
- eccentric humor;
- program names and terminology;
- historical context;
- mild profanity acceptable at PG ("crap", "screw", "hell");
- his political and conspiracy opinions, where they are not directed at a protected group.

**How it's done:**
1. **Visible markers, never invented wording.** Redacted text is replaced by a marker the reader
   can recognize as the project's edit:
   - `[Derogatory remark redacted]` and `[Derogatory remarks redacted]` for statements about
     groups or religious communities;
   - `[Offensive remark redacted]` for other statements;
   - `[slur redacted]` for a slur.

   No statement is rewritten into a benign one in Terry's name. Markers are short ASCII, so they
   fit TempleOS' fixed-width font, and documents are English in every UI language.
2. **Minimal scope.** A word, clause, sentence, answer or passage is redacted, never a whole
   document. Questions, headings, technical paragraphs and scripture links around a redaction stay.
3. **Exceptions that do not use a marker**, each documented:
   - **CH-36 is masked.** It is a profane programming-language name, so the result stays readable as
     a name.
   - **VO-5593 is replaced by a synonym.** It is one word in the God Words list: an archaic verb
     meaning "delay" that reads as a slur out of context. God Words picks entries by index, so the
     list must keep 7,569 one-word entries. "delay" is the word's meaning, and the substitution is
     disclosed in About and on the website.
   - **TI-94 and TI-314 rename an identifier.** A slur was used as a variable name in Titanium. It is
     renamed with the same length at both uses, so the program compiles and runs identically. It is
     never printed.

## 2. Architecture

- **Originals.** `reference/templeos-iso/` is the byte-exact extraction of the official ISO
  (sha256 in `docs/licensing-and-provenance.md`). It is a development-only, gitignored source and
  is never modified or shipped.
- **Rules.** `tools/resource-packaging/moderation.json` holds one entry per edited span:
  - `path`, `line`, and byte columns `start`/`end` in the text part (before the first NUL);
  - the `sha256` of the original bytes;
  - `replace`, either a literal or `@marker`;
  - `category`, `scope` and a neutral `note`.

  The manifest identifies the original wording by hash and never repeats it. Maintainers locate a
  new span with `moderation.py span`.
- **Application.** `tools/resource-packaging/moderation.py` is used by `build_bundled_fs.py` when the
  bundled drive is built.
  - It edits the text part only. Embedded sprites after the NUL are untouched.
  - Edits are applied right to left per line.
  - **A hash mismatch fails the build**, so a changed original is never edited blindly.
  - Markers are checked to be ASCII without `$` (the DolDoc command delimiter) or NUL.
  - `moderation.py check reference/templeos-iso` verifies the manifest.
- **What ships.** Only the moderated copies, in `shared/bundled-fs/`. Both apps package that
  directory unchanged: Xcode folder reference on iOS, Gradle `Sync` on Android. No unmoderated
  copy exists in either app.
  - Every way into a file reads the same bytes: the document viewer, the editor, Files, the
    terminal's `Type`, and God Words' "Holy Spirit instructions".
  - Moderation is static, so it costs nothing at run time. There is no string scanner in the
    renderer or the terminal.
- **Index and notice.** A moderated file's origin in `shared/bundled-fs.index` ends with
  `; modified: offensive content censored or redacted by TempleOS.app`. `DocProvenance` therefore
  classifies it **ADAPTED**, and the document viewer shows the localized notice
  `doc.notice.adapted.*`. The notice says that offensive words and statements were censored or
  redacted by the project, mostly with visible markers, and that those edits are not Terry's
  wording. Unedited original files stay ORIGINAL ("the original documentation text is preserved
  here").
- **Audit.** `tools/provenance/doc_attribution_audit.py` re-hashes every bundled file and checks it
  against the ISO. A file must be byte-identical, or exactly the original with its listed edits.
  Results are in `docs/fidelity-audit/evidence/doc-attribution.md`.
- **Program logic.** Only Titanium's identifier touches executable text, and it compiles and runs
  identically. No program reads the edited documents as data. God Words keeps every entry index.
  No string a program compares, parses or indexes was changed.

## 3. What was found and what was done

These are the full-bundle audit results (2026-10-18, origin class 1 = original documentation unless
noted). All edits are applied in both apps, because both ship the same files.

| Id | File:line | Category | Treatment |
|---|---|---|---|
| HS-37a | `Adam/God/HSNotes.DD:37` | remark calling a religion's historical practice satanic | clause → `[Derogatory remark redacted]`; the theological point around it is kept |
| HS-37b | `Adam/God/HSNotes.DD:37` | sentence whose meaning is a homophobic slur | sentence → `[Derogatory remark redacted]` |
| HS-39 | `Adam/God/HSNotes.DD:39` | five sentences of ethnic and anti-immigrant generalizations | → `[Derogatory remarks redacted]`; last sentence and its scripture link kept |
| HS-64 | `Adam/God/HSNotes.DD:64` | passage calling slavery just, with insults | → `[Derogatory remarks redacted]`; the question row above is kept |
| HS-72 | `Adam/God/HSNotes.DD:72` | answer trivializing the Holocaust | answer → marker; question kept |
| HS-73 | `Adam/God/HSNotes.DD:73` | flippant answer about an ethnic/religious conflict | answer → marker |
| HS-74 | `Adam/God/HSNotes.DD:74` | answer blaming an ethnic group | answer → marker |
| HS-103, 104, 107 | `Adam/God/HSNotes.DD` | homophobic slur used as an answer | word → `[slur redacted]` |
| HS-115 | `Adam/God/HSNotes.DD:115` | derogatory label for early Jews | answer → marker |
| HS-189, 217 | `Adam/God/HSNotes.DD` | answers calling a deadly flood justice | answer → `[Offensive remark redacted]` |
| HS-219 | `Adam/God/HSNotes.DD:219` | answer trivializing a school shooting | answer → `[Offensive remark redacted]` |
| ST-7 | `Doc/Strategy.DD:7` | sentence ridiculing a person by race and sex | sentence → marker; the paragraph's point is kept |
| CH-36 | `Doc/Charter.DD:36` | profanity in a programming-language name | masked |
| PN-3 | `Demo/AcctExample/PersonalNotes.DD:3` | racial slur (was `[censored]`) | → `[slur redacted]` |
| TI-94, TI-314 | `Apps/Titanium/Titanium.HC` | racial slur as an identifier (class 2) | renamed, same length |
| VO-5593 | `Adam/God/Vocab.DD`, entry 5592 | homograph of a slur (class 1, executable data) | → "delay", index kept |

- **Origin classes.** There is no class 3: text written by the mobile port was clean. There is no
  class 4 either: the 72 God Words vocabulary translations were reviewed and use neutral terms.
  Class 5 metadata (catalog descriptions) was clean.
- **Program output.** No class 2 runtime output needed moderation. All 182 program sources' strings
  were reviewed. BigGuns and ZoneOut print "crappy" in their help text, which is kept at PG.
- **Where the material was.** `HSNotes.DD`, Terry's "Holy Spirit" notes and Q/A table, is opened by
  God Words' menu and three documentation links. It held almost all of the material. The rest of
  the file (oracle instructions, prayers, scripture links, harmless Q/A rows) is kept.

## 4. Kept on purpose, for human editorial review

These were reviewed and **not** changed under the policy above. They are listed so an editor can
decide differently. None of them is approved silently.

1. `HSNotes.DD:102`: a question on homosexuality answered only by a scripture link (Matthew 15:11).
   Kept as a scripture reference, but its context is sensitive.
2. `HSNotes.DD:108`: a crude joke whose answer is a Biblical place name. Not a slur. Kept.
3. `HSNotes.DD:220`: God "claimed credit" for an industrial disaster. Kept.
4. `HSNotes.DD:37`: "the people were primitive", about Bible-era people. Kept; compare HS-115, which
   names a group.
5. `HSNotes.DD:184, 109, 113, 35, 25`: a commandment naming child abuse as forbidden; remarks on
   women's dress and adultery; a theological remark about famine relief; a comparison with Native
   Americans. Low severity; kept.
6. Mild profanity across the docs and the BigGuns/ZoneOut help text. Kept at PG.
7. Political and conspiracy remarks: CIA, "Japan, China and Korea must switch to alphabets", an
   analogy to reservations. Kept as eccentric opinions.
8. `Misc/Bible.TXT` (KJV) and God Words' random PASSAGE/WORD output can show archaic scriptural
   words. This is scripture and is not moderated. The store age rating should take it into account.
9. God Words vocabulary entries such as "jew"/"jews" are neutral words. A random line of ten words
   can put them next to negative words. They are kept, since removing them would change every later
   index. Some translations render "infidels" with the standard religious term `kafir`.
10. The Titanium sprites drawn for the renamed "CIA agent" units were not reviewed as images in this
    pass. Someone should look at them in the game.
11. Terry's home address and phone number appear in `Doc/AboutTempleOS.DD` and
    `Demo/Lectures/NegDisp.HC`. This is a privacy matter, not a PG one, and is left to the owner.

Added by the second review (§7). These were also judged acceptable and kept:

12. `HSNotes.DD:72–74, 217, 219`: Q/A rows whose answers are markers. The question stays (a date or
    event). One reviewer suggested dropping these rows from the light-hearted list. They are kept,
    because a visible marker shows the edit, and silently deleting the row would hide it (policy B, D).
13. `HSNotes.DD:206` is a whimsical answer about how a named disabled scientist could communicate.
    `HSNotes.DD:186` is a commandment that names domestic violence as forbidden. `HSNotes.DD:218`,
    after a hurricane, says "suffering simplifies life". All low severity.
14. `Demo/AcctExample/PersonalNotes.DD:33`: a game idea named after a 1991 war event with mass
    casualties.
15. `Doc/Demands.DD:30`: a dismissive remark about users with special input needs.
    `Doc/StdTempleOSPC.DD:52`: a light quip about British people.
16. God Words entries 7399 and 3149 are archaic scriptural words for sexual immorality and
    prostitution. 2039 is the archaic word for "mute". 7470 is an archaic word for "effeminate".
    The list is the vocabulary of Augustine's *Confessions*, and none of these is a slur.
17. "Master/slave" multiprocessor and ATA terminology: `Doc/Welcome.DD:86`, `Doc/Features.DD:7`,
    `Doc/Glossary.DD:287`, `Misc/OSInstall.HC:118`. It is technical, and the install prompt is part
    of a program.
18. `Misc/PCIDevices.DD` is a third-party, user-submitted PCI ID database. It is not PG-relevant,
    but it carries junk entries for the owner to judge:
    - line 4927 has a 16-digit number formatted like a payment card (privacy check);
    - line 4693 uses a person's name as a vendor;
    - lines 7333 and 5091–5096 are spam with phone numbers;
    - line 3759 has inert web-script markup that DolDoc does not run.

Considered and cleared, with no action: the "Red man" comment at `Demo/Games/BlackDiamond.HC:187`
is the player sprite's red collision color. Four bytes of compressed bitmap data in
`Demo/Games/Stadium/StadiumBG.GR` happen to spell a slang term; they are not text and are never
drawn.

## 5. Disclosure

- **In the apps.** `about.how.body` and `doc.notice.adapted.body` in all 73 catalogs. The
  translations were machine-assisted and are listed in each catalog's `$review` for a native
  speaker.
  - The About sentence was reworded on 2026-10-19 (§7). It used to read as if every offensive
    remark had been removed, and it did not say whose wording the edits are. It now reads: "Some
    of the original wording, including slurs and derogatory remarks about groups of people, was
    censored or redacted by this project; these edits are not Terry A. Davis' wording. Including
    his work does not mean endorsing every statement in it."
  - The document notice was already accurate and is unchanged: it ends "the rest is as he wrote
    it", and it says "mostly" marked, which covers the two unmarked edits (VO-5593, TI-94/314).
- **On the website.** `templeos_app_site_golang/content/en/legal.json`, sections "What comes from
  where" and "Admiration, not endorsement". It says:
  - six files were edited;
  - slurs and several statements and passages were replaced by visible markers, and one profane word
    was masked;
  - one God Words word was replaced by its meaning, and an identifier was renamed;
  - these are the project's edits, not Terry's wording;
  - mild profanity and his opinions remain.

  The site's other pages say the documentation comes from the ISO, which is still true; they make
  no claim that it is unmodified.

## 6. Tests

- Swift `ContentModerationTests` and Kotlin `ContentModerationTest`. Each checks:
  - every edit is present and every modified file is listed;
  - with the ISO extraction, each file equals the original plus its edits, and nothing else
    differs;
  - no redacted wording reaches the viewer's text or accessibility labels (checked by rebuilding the
    original in memory);
  - religious and technical text is kept;
  - there is no substring collateral;
  - markers are safe DolDoc;
  - the editor, the viewer and the filesystem read the same moderated bytes;
  - documents are identical in every UI language;
  - every catalog has the notice strings, flagged for review;
  - About says that only some wording was edited, that the edits are the project's, and that inclusion
    is not endorsement. The screen shows the localized paragraph in five UI languages
    (`aboutDescribesTheEditsWithoutClaimingCompleteness`).
- `GodWordsTest(s)`: the vocabulary keeps 7,569 entries, and only entry 5592 differs, identified by
  hash. HSNotes and Strategy are ADAPTED.
- `tools/resource-packaging/moderation.py check` and `tools/provenance/doc_attribution_audit.py`.

## 7. Second, independent review (2026-10-19)

The second review read the moderated bundle in context, the way a user meets it. It did not repeat
the first pass's search terms. Nine reviewers covered everything the apps ship except the KJV Bible,
which is scripture and kept by policy:
- every line of the 114 documents (`.DD`/`.TXT`), including every remaining HSNotes Q/A row;
- every comment and string literal of the HolyC sources;
- all 16,636 unique source identifiers (for slurs used as names, as in Titanium);
- the printable text inside embedded sprite data;
- the third-party PCI ID list;
- every God Words vocabulary entry;
- the port's own text (`en.json`, `home-src/`).

The vocabulary translations were spot-checked rather than read in full (544,747 strings):
- entry 5592's translation in all 72 catalogs means "delay";
- the religious terms for gentiles, heathen, infidels and unbelievers were checked where a term could
  be a regional slur (af, zu, sw). Swahili `makafiri` is the standard Swahili word.

**Results**
- **No new span needed moderation.** Every slur and derogatory remark about a group that the
  reviewers found was already redacted. The new borderline items are listed in §4 (12–18), not
  approved silently.
- **The About text overstated the edits.** The old sentence could be read as "every offensive remark
  was removed", and it did not say the edits were not Terry's wording. It was reworded in all 73
  catalogs (§5). The new translations are flagged in `$review`, as before, for a native speaker.
  The new rm (Romansh) wording in particular has no existing catalog terms to match.
- **No program, document or manifest change.** `moderation.json`, the bundled drive and the ISO
  originals are unchanged. Program behavior is therefore unchanged.
- **Website.** `templeos_app_site_golang/content/en/legal.json` ("What comes from where",
  "Admiration, not endorsement") already describes these edits exactly: six files, markers, one
  masked word, the vocabulary word and the renamed identifier, and the content that remains. It was
  not changed. The site's page text is English-only until its translation pass (its
  docs/LOCALIZATION.md); `/de/legal` and similar are 404, so every visitor reads this English page.

**Validation (2026-10-19)**
- Unit tests:
  - Kotlin `:core:test` and `:app:testDebugUnitTest`: 291 tests, 0 failures.
  - Swift `swift test`: 307 tests, 0 failures, 1 skip (`FuzzTests.testReplay`, which skips when there is no repro).
  - `moderation.py check`, `doc_attribution_audit.py` (0 errors), `l10n/validate.py` (0 errors), `gen_platform.py --check` and `hardcoded_audit.py` (0) all pass.
- iOS (iPhone 17 Pro simulator): UI tests `testModeratedDocumentsShowRedactionMarkers` and `testAppNameInAbout` passed. The About screenshots (en, es) show the new paragraph without clipping.
- Android (emulator-5554, debug APK): About in en-US, ja-JP and ar shows the new paragraph in the accessibility tree and on screen.
- Website (clean export of HEAD): `go test ./...` passes. `browsercheck` (Chromium, WebKit) reports 0 failures. `/legal` shows the disclaimer with no horizontal scroll at 320, 393, 844 (landscape) and 1440 px.
- No physical device was used.
