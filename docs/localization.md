# Localization

> How localized text is rendered (TempleOS font vs platform text runs, sharpness, tall scripts): see
> `typography/TEMPLEOS_TYPOGRAPHY.md`.

TempleOS Mobile shows its own user interface in **89 locales, served by 73 translation
catalogs**. The request asked for "90 languages". The reference locale set it was based on
(an earlier project by the same author) has 89 canonical locales,
so that is the set used here. Nothing was added to round it up.

Everything happens on the device:
- no server, no IP geolocation, no remote translation, no downloads;
- the catalogs are bundled runtime files, like the HolyC prelude and the font.

## What is translated and what is not

**Translated (app-owned UI):**
- the top bar, the start menu, window menus, dialogs and toasts;
- Settings, Language, About, Files, the Editor's toolbar, Paint, God Words' controls;
- program-catalog notes, filesystem error messages;
- screen-reader labels (TalkBack and VoiceOver).

**Never translated (TempleOS content and technical text):**
- HolyC source, commands, identifiers and error messages from the compiler and kernel;
- paths and file names, DolDoc documents and the Bible text;
- program output;
- the names TempleOS, HolyC and DolDoc;
- the key caps of the TempleOS keyboard (ESC, TAB, SHIFT…), which are labels on keys, like on a
  hardware keyboard. Their spoken names *are* translated (`key.*`, `char.*`).

**Text written into TempleOS console windows** (the Terminal banner, program-runner messages)
goes through `L10n.tr8`. A console holds 8-bit CP437 cells, so it shows the translation when the
TempleOS font can display every character of it (English, French, German, Spanish, Portuguese
and other Western European languages). Otherwise it shows English.

## Files

| File | Role |
|---|---|
| `shared/runtime/l10n/locales.json` | The manifest: 89 locales (id, catalog, parent, script, direction, native and English names, aliases), language families, exclusions, device-region candidates, input tag grammar. |
| `shared/runtime/l10n/en.json` | English source: 379 keys. `$comment` explains the conventions. |
| `shared/runtime/l10n/<catalog>.json` | One catalog per language (72 plus English). `$review` lists keys a native speaker should check. |
| `shared/test-vectors/l10n/resolver_vectors.json` | 108 resolution cases run by Python, Kotlin and Swift. |
| `temple_os_kotlin/core/.../ui/L10n.kt`, `temple_os_swift/TempleCore/.../UI/L10n.swift` | `LocaleResolver`, `L10n` (`tr`, `tr8`, `use`), `Cp437`. Line-for-line ports. |
| `tools/l10n/resolver.py` | Reference resolver; `--make-vectors` regenerates the vectors. |
| `tools/l10n/validate.py` | Catalog validator; `--report docs/localization-coverage.md` writes the coverage table. |
| `tools/l10n/hardcoded_audit.py` | Finds English literals that bypass the catalogs in the shared UI code. |
| `tools/l10n/census.py` | Audits data-driven program metadata and current keys; `--strict-coverage` rejects tracked English omissions/unresolved app-owned metadata; optional app/APK arguments compare actual bundled bytes. |
| `tools/l10n/gen_platform.py` | Writes the platform language lists: Android `res/xml/locales_config.xml` and iOS `CFBundleLocalizations`. `--check` verifies them. |
| `temple_os_kotlin/core/.../ui/LanguageList.kt`, `temple_os_swift/TempleCore/.../UI/LanguageList.swift` | `LanguageOption` and `LanguageList`: the order of language lists (see [Language lists](#language-lists)). Same contract, native collators. |
| `tools/l10n/language_order.py` | Reads the Language window's order on an Android device; compares it with the iOS UI test's. |

Only English and the current catalog are in memory. Switching languages loads one file.

## Choosing the language

`LocaleResolver.resolve(manual, preferred, deviceRegion)` returns a locale id and its source:

1. **manual:** the in-app choice (Start menu → Language…, or Settings → Language), if it still
   names a supported locale.
2. **preferred:** the first supported language in the device's preference list. This is iOS
   `Locale.preferredLanguages`, or the Android configuration's locale list. On Android 13+ and
   iOS that list includes the per-app language chosen in system Settings.
3. **default:** en-US.

Tags are normalized:
- `_` becomes `-`, case is ignored, and extensions (`-u-ca-japanese`) are tolerated;
- aliases (`iw` → Hebrew, `nb`/`nn`/`no` → Norwegian, `tl` → Filipino) and exclusions
  (`sr-Latn`) apply;
- matching uses the longest whole-subtag prefix.

The device's **region** setting is used only to choose a member of a language family. For
example, bare `fr` on a device set to Canada resolves to fr-CA. There is no geography: the
reference resolver's IP-country steps were removed, and its 10 vectors that depended on them
were rewritten to expect en-US. Bare `zh` is never guessed; it needs a script or region.

**Persistence:** the choice is stored in the session settings (`g=<locale id>`; empty means
Automatic). Choosing "Automatic" in the Language window clears it, and the device language takes
over again. An unknown stored id is ignored.

**Live changes:** the language can change at any time without restarting or closing windows.
- **Android:** `MainActivity` handles `locale|layoutDirection` configuration changes and calls
  `Shell.applyLanguage()`.
- **iOS:** the view controller observes `NSLocale.currentLocaleDidChangeNotification`.
- **Both:** every window is marked dirty and redrawn. Open documents, programs and drafts are
  untouched.

App-owned menus, dialog titles/actions and toasts retain a `L10n.Presentation` provider. It
caches the resolved value and refreshes once when `L10n.version` changes, preserving input,
selection and callbacks. Swift call sites use autoclosures; Kotlin uses providers. Original
program strings and existing terminal history remain literal data. Placeholder arguments are
inserted in one template scan, so a path containing `{engine}` is never treated as a second
translation template.

The four-line branded introduction and its MENU chip intentionally remain English under the
current Brand/distribution contract. Source menu names and executable expressions remain
original; synthetic navigation headings and compatibility-message frames are localized.
Files/editor toolbars and language names adapt to available width. File size labels use the
technical unit B instead of an English plural sentence.

## Language lists

The app has one list of languages to choose from: the **Language window** (Start menu → Language…,
or Settings → Language). The system's own per-app language pickers (Android 13+ Settings, iOS
Settings) are built by the OS from `locales_config.xml` / `CFBundleLocalizations`. Android's picker
sorts that list itself (checked on Android 16: `language-order/android-system-app-language-picker.png`),
so the order of the generated file does not matter there; the iOS Settings list was not checked.
God Words and the other programs have no language selector: they follow the UI language, and their
content (word picks, menus, output) is never sorted. The website project has no language selection.

**What a row shows** (unchanged): the language's own name, then its English name, in every UI
language: `Deutsch - German`, `日本語 - Japanese`, `العربية - Arabic`. Above the languages is the
special row **Automatic (device language)**. It is translated, it is not a language, and it always
comes first; choosing it clears the saved choice (`g=`), as before.

**The order** is alphabetical by what the row shows, collated for the current UI language:
1. the language's own name, then the English name, compared with the platform collator for the UI
   locale: `java.text.Collator` (ICU on Android, canonical decomposition) and Foundation's
   `compare(_:options:range:locale:)` on iOS. Accents, case, other scripts and canonically
   equivalent spellings are handled by the collator, never by rewriting the names;
2. rows that still compare equal: the locale id (lowercase, then exact), so the order is total and
   never depends on the input order.

The collator puts the UI language's own script first (with a Russian UI the Cyrillic names lead,
with an Arabic UI the Arabic-script names), then the CLDR script order (Latin, Greek, Cyrillic, …,
Han). The rows themselves do not change with the UI language, but their order can.

**Where it lives:** `LanguageList.current()` builds the rows from the manifest, sorts them and keeps
the result until the UI language (or the manifest) changes; drawing and scrolling do no collation.
`LanguageList.sorted(options, displayLocale)` is the pure, testable function underneath. The
manifest is never reordered, and its order (and its `sort_order` field, inherited from the reference
locale set) never reaches the screen: a language added to `locales.json` takes its place by its
names alone. A missing name falls back to the other name, then to the id.

**Selection** is by locale id: the highlighted row is the saved id, and nothing stores row
positions. When a choice re-sorts the open window, the chosen row stays where it was tapped.

**Why it changed (2026-10-18):** both apps sorted by the English name (`sortedBy { englishName }`)
while each row starts with the language's own name, so the visible list looked scrambled:
`Afrikaans`, `Shqip`, `አማርኛ`, `العربية`, `Հայերեն`, … with `Deutsch` after `ქართული`.

**Platform differences:** both platforms use their own collator, so the order can differ where
Android's ICU data and Apple's differ. On 2026-10-18 the real windows (Android 16 emulator, iOS 26.1
simulator; `language-order/android.json`, `ios.json`) were identical for en-US, ru-RU, ar and es-ES.
For ja-JP, Android puts the Japanese and Chinese names first and iOS puts them after the Latin names
(before Greek). The order within every block is the same. This is a difference between the native
collators, not a bug, and it is left as it is.

**Checks:** Kotlin `LanguageListTest`, Swift `LanguageListTests` (permutations, accents, case,
scripts, RTL, variants, missing names, duplicates, ties, languages added later, language switches,
the window's rows and selection); `validate.py` rejects a locale without both names and two locales
whose rows read alike; the iOS UI test `testLanguageListOrder` and `tools/l10n/language_order.py`
read the real window on a simulator and an emulator and compare the platforms.

## Drawing text the TempleOS font cannot show

The UI is drawn into an indexed framebuffer with the 8×8 TempleOS font, which covers IBM code
page 437:
- ASCII;
- Western European accented letters;
- some Greek letters, plus symbols.

`Surface.uiText` draws a string with that font when `Cp437.representable(s)` is true.
Otherwise it records a `TextRun`:
- its position, width, color and clip, in logical pixels;
- whether it is right-to-left;
- its stacking layer.

The platform draws the run with its own text engine after the framebuffer. That gives:
- correct shaping (Arabic, Indic scripts), bidi and system font fallback (CJK, Ethiopic,
  Myanmar…);
- sharp text at device resolution.

Windows, menus, dialogs, the keyboard and toasts each start a new layer (`Surface.layer`) and
register an **occluder** rectangle. A run is clipped out of every occluder from a later layer, so
a window on top hides the text of the window under it, just like pixels in the framebuffer.

- **Android:** `TempleView.drawTextRuns`: `clipRect` plus `clipOutRect`, using the `textPaint`
  measured by `AndroidShellEnv.measureText`, so measurement and drawing agree.
- **iOS:** the text-run layer in `TempleView.swift`, with the same rules.

**Line breaking:** `Surface.wrapUi` breaks at spaces, and by character for scripts without
spaces (Chinese, Japanese, Thai, Lao, Khmer, Burmese).

**Right-to-left** (Arabic, Persian, Urdu, Hebrew): text and menu items align to the end. Window
layout, the TempleOS keyboard and HolyC text are not mirrored: TempleOS's desktop is a
left-to-right environment and its content stays as it is.

**Numbers:** clocks, sizes, dates and FPS are formatted with `Locale.ROOT` (Kotlin) or
`String(format:)` (Swift, locale-neutral). Device locales with other digit systems therefore
never produce characters the TempleOS font cannot show.

## Input

The custom TempleOS keyboard is the only software keyboard on both platforms. Android exposes no
native InputConnection; iOS has no UIKeyInput/UITextInput client. Hardware keyboards, paste and the
CP437 character picker feed the same application-owned input model. See
Android input and iOS input.

HolyC source, console cells and filenames use TempleOS byte strings. External text is normalized to
NFC, with CRLF/CR converted to LF, and converted atomically to CP437. Unsupported text is rejected
without changing the draft; it is not silently replaced with question marks. General filenames and
editor content therefore do not support arbitrary Unicode, independently of the UI language. The
CP437 picker supplies extended Western European characters without opening a system keyboard.

The Language window can be filtered by ASCII locale codes or English names, so every language
remains selectable with the custom keyboard. Localized display text uses the platform fallback
fonts described above. Long UI words wrap at logical character boundaries rather than splitting
UTF-16 surrogate pairs or combining sequences; technical byte-oriented editing remains unchanged.

## Accessibility

Screen-reader labels come from the catalog (`a11y.*`, `key.*`, `char.*`, button labels).
- **Android:** every label carries a `LocaleSpan` for the UI locale (`AccessibilityAdapter.spoken`).
- **iOS:** elements get `accessibilityLanguage` set to the UI locale, so VoiceOver uses the
  right voice.

## The apps' name

The apps call themselves **TempleOS.app** (README, "Names"). Catalogs never contain the name:
they write `{app}`, and `L10n.tr`/`tr8` fill it in, so every language shows exactly the same
name and a rename changes one value (`app_name` in `locales.json`). Translations adapt the words
around it; in languages that attach endings to names the ending suits "TempleOS.app"
(Turkish `{app}'in`, Hungarian `{app}-ben`, Basque `{app}-ek`; Finnish uses
`{app}-sovelluksessa`), and those keys are in the catalog's `$review`. `validate.py` rejects a
catalog that writes the name itself or the retired name "TempleOS Mobile".

## Adding a string

1. Add the key and English text to `en.json`. Use `{name}` placeholders and `\n` for line breaks.
2. Use `tr("key", "name" to value)` in Kotlin, then make the same change in Swift. Use `tr8` for
   console text.
3. Add the key to every catalog. Until a translation exists, the English text falls back
   automatically at run time, but `validate.py` reports the catalog as incomplete.
4. Run:
   - `python3 tools/l10n/validate.py`
   - `python3 tools/l10n/hardcoded_audit.py`

## Adding a language

1. Add the locale to `locales.json`. Include its catalog, script, direction, names, aliases and
   family default, and update the expected counts in `validate.py` and the tests. Its position in
   the file does not matter: the Language window sorts by the names.
2. Write `shared/runtime/l10n/<catalog>.json` with every English key.
3. Run, in order:
   - `python3 tools/l10n/gen_platform.py`
   - `python3 tools/l10n/resolver.py --make-vectors`
   - `python3 tools/l10n/validate.py`

## Validation

The current regression audit and its explicit limits are in
localization-validation. Catalog key parity is a
resource check; copied English values and unregistered metadata require separate coverage review.

| Check | Command |
|---|---|
| Catalogs: keys, placeholders, line breaks, Unicode, branding | `python3 tools/l10n/validate.py` |
| Coverage table | `python3 tools/l10n/validate.py --report docs/localization-coverage.md` |
| Hard-coded strings | `python3 tools/l10n/hardcoded_audit.py` |
| Platform language lists up to date | `python3 tools/l10n/gen_platform.py --check` |
| Language window order | Kotlin `LanguageListTest`, Swift `LanguageListTests`; on devices `testLanguageListOrder` (iOS) and `tools/l10n/language_order.py android` + `compare` |
| Resolver vectors, catalogs, switching, text runs, RTL | Kotlin `L10nTest`, Swift `L10nTests` |

## Translation quality

The catalogs were machine-translated by an AI model with platform terminology guidance. No native
speaker has reviewed them yet.
- Keys the translator was unsure of are listed in each catalog's `$review`. Lower-resource
  languages have more flags.
- `docs/localization-coverage.md` gives the counts.
- **Locales sharing a catalog** (the reference locale set's mapping):

  | Catalog | Locales |
  |---|---|
  | `en` | the 7 English locales |
  | `es` | es-419, es-ES, es-MX, es-US |
  | `fr` | fr-FR, fr-CA |
  | `pt-BR` | pt-BR, pt-PT |
  | `zh-Hant` | zh-TW, zh-HK |
  | `ms` | ms, ms-MY |
  | `fa` | fa, fa-IR, fa-AF, fa-AE |

  Portuguese users therefore see Brazilian wording. A pt-PT catalog would be a worthwhile
  addition.

## Evidence

Screenshots are in `docs/localization-evidence/`. Each pair is the platform and the screen.

| Language | Android (emulator, Android 16) | iOS (simulator, iPhone 17) |
|---|---|---|
| Japanese | `android_ja_editor.png`: the editor, toolbar and menu chip | `ios_ja_game.png`: tabs, plus a game frame drawn over the text runs |
| Language window | – | `ios_ja_language_window.png`: filter "ja", current choice highlighted |
| German (CP437 path) | – | `ios_de_device.png`: a German device, with UI drawn in the TempleOS font |
| Arabic (RTL) | `android_ar_settings.png`: settings | `ios_ar_start_menu.png`: start menu hiding the window text under it |
| Language window order | `language-order/android-*.png` (en-US, ru-RU, ar, ja-JP, es-ES; in-app Russian, landscape) | `language-order/ios-*.png` (the same) |
| Mongolian (long labels) | `android_mn_settings.png`: settings | – |
| Amharic (Ethiopic font fallback) | `android_am_settings.png`: settings | – |

Method:
- **Android:** language set with `cmd locale set-app-locales com.digitalcircuitstudios.templeosapp --locales <tag>`.
  This is the per-app language API, and it was applied while the app was running.
- **iOS:** language set by the XCUITest `testLanguageFollowsDeviceAndInAppChoice` with
  `-AppleLanguages`.

## God Words vocabulary (2026-10-17)

The God Words window shows Terry Davis' vocabulary entries in the UI language. The entry picked
never depends on the language. See [localization-vocabulary.md](localization-vocabulary.md) for the
design and tools (`tools/l10n/vocab.py`), and
[localization-vocabulary-coverage.md](localization-vocabulary-coverage.md) for the per-catalog
coverage. The document viewer's attribution notices and the About page's "Original work and modern
additions" section are ordinary UI strings in every catalog.

The 2026-10-27 audit records 544,968 populated vocabulary resource entries. Of these, 221
formerly blank entries explicitly preserve ambiguous original tokens in
`shared/test-vectors/god-words/preserved-tokens.json`. They are counted separately from supplied
localized entries and still require linguistic review. See the current
validation reports for the resource, device and simulator
evidence and its limits.
