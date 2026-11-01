package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import java.io.File
import java.nio.file.Files
import java.text.Collator
import java.util.Locale
import kotlin.random.Random
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * The order of language lists (LanguageList; docs/localization.md, "Language lists"). Expected
 * orders are never written out whole: every result is checked against the display locale's own
 * collator, and only orders that hold in any CLDR-based collation are spelled out. The JVM's
 * collator is not Android's ICU one; the device run (tools/l10n/language_order.py) covers that.
 */
class LanguageListTest {
    private val l10n = File(SHARED, "runtime/l10n")

    @Suppress("UNCHECKED_CAST")
    private fun manifest() = Json.parse(File(l10n, "locales.json").readText()) as Map<String, Any?>

    private fun manifestOptions(m: Map<String, Any?> = manifest()) = LocaleResolver(m).locales.map(LanguageList::option)

    private fun o(id: String, name: String, gloss: String) = LanguageOption(id, name, gloss)

    // realistic rows: Latin with and without accents, Arabic (RTL), CJK, Cyrillic, Devanagari, region variants
    private val sample = listOf(
        o("es-ES", "Español (España)", "Spanish (Spain)"), o("ar", "العربية", "Arabic"), o("ja-JP", "日本語", "Japanese"),
        o("en-US", "English (United States)", "English (United States)"), o("fr-FR", "Français (France)", "French (France)"),
        o("de-DE", "Deutsch", "German"), o("ru-RU", "Русский", "Russian"), o("hi-IN", "हिन्दी", "Hindi"),
        o("cs-CZ", "Čeština", "Czech"), o("is-IS", "Íslenska", "Icelandic"), o("zu", "isiZulu", "Zulu"),
        o("es-419", "Español (Latinoamérica)", "Spanish (Latin America)"), o("fa", "فارسی", "Persian"),
    )

    private fun ids(l: List<LanguageOption>) = l.map { it.id }

    /** Every neighbouring pair is in order for [locale] (the definition of the contract, not a copy of the result). */
    private fun assertOrdered(l: List<LanguageOption>, locale: String) {
        val c = LanguageList.comparator(locale)
        for (i in 1 until l.size) assertTrue("${l[i - 1]} before ${l[i]} ($locale)", c.compare(l[i - 1], l[i]) < 0)
    }

    private fun before(l: List<LanguageOption>, a: String, b: String) =
        assertTrue("$a before $b in ${ids(l)}", ids(l).indexOf(a).let { it >= 0 && it < ids(l).indexOf(b) })

    @After fun english() { L10n.use("en-US") }

    @Test fun shuffledInputsGiveOneOrder() {
        val a = listOf("es-ES", "ar", "ja-JP", "en-US", "fr-FR", "de-DE")
        val pick = { order: List<String> -> order.map { id -> sample.first { it.id == id } } }
        for (loc in listOf("en-US", "es-ES", "ja-JP", "ar", "ru-RU")) {
            val want = LanguageList.sorted(pick(a), loc)
            assertEquals(want, LanguageList.sorted(pick(listOf("de-DE", "fr-FR", "en-US", "ja-JP", "ar", "es-ES")), loc))
            assertEquals(want, LanguageList.sorted(pick(listOf("ja-JP", "es-ES", "fr-FR", "ar", "de-DE", "en-US")), loc))
            assertOrdered(want, loc)
        }
    }

    @Test fun propertiesOverRandomPermutations() {
        val all = manifestOptions()
        val rnd = Random(89)
        for (loc in listOf("en-US", "de-DE", "es-419", "sv-SE", "tr-TR", "ru-RU", "ja-JP", "zh-CN", "ar", "he-IL", "hi-IN", "th")) {
            val want = LanguageList.sorted(all, loc)
            assertOrdered(want, loc)
            assertEquals("same identities", all.map { it.id }.toSet(), want.map { it.id }.toSet())
            assertEquals(all.size, want.size)
            assertEquals("idempotent", want, LanguageList.sorted(want, loc))
            assertEquals("already sorted", want, LanguageList.sorted(want.toList(), loc))
            assertEquals("reverse", want, LanguageList.sorted(want.reversed(), loc))
            repeat(25) { assertEquals("permutation", want, LanguageList.sorted(all.shuffled(rnd), loc)) }
        }
    }

    @Test fun visibleNamesNotIdsOrEnglishNames() {
        val en = LanguageList.sorted(manifestOptions(), "en-US")
        // the list used to be sorted by the English name while showing the language's own name first
        before(en, "de-DE", "et")     // Deutsch, Eesti (German came after Estonian)
        before(en, "sq", "fi-FI")     // Shqip, Suomi
        before(en, "fi-FI", "sv-SE")  // Suomi, Svenska
        before(en, "nl-NL", "pl-PL")  // Nederlands, Polski (Dutch was among the D's)
        // and never by locale id: "hr" (Hrvatski) sorts among the H's, "eu-ES" (Euskara) among the E's
        before(en, "eu-ES", "fil")
        before(en, "gl-ES", "hr")
        assertEquals("Automatic stays outside the language rows", 89, en.size)
    }

    @Test fun latinAccentsAndCase() {
        for (loc in listOf("en-US", "fr-FR", "de-DE", "pt-BR")) {
            val l = LanguageList.sorted(manifestOptions(), loc)
            // é, č, í are their base letters at the first level
            before(l, "ca", "cs-CZ"); before(l, "cs-CZ", "da-DK")                  // Català, Čeština, Dansk
            before(l, "en-US", "es-ES"); before(l, "es-MX", "eu-ES")              // English, Español, Euskara
            before(l, "zu", "is-IS"); before(l, "is-IS", "it-IT")                 // isiZulu, Íslenska, Italiano
            before(l, "sk", "sl")                                                 // Slovenčina, Slovenščina
        }
        // canonical equivalence: precomposed and decomposed "ñ" are the same label; the id decides
        val nfc = o("zz-b", "Español", "Spanish"); val nfd = o("zz-a", "Español", "Spanish")
        assertEquals(listOf("zz-a", "zz-b"), ids(LanguageList.sorted(listOf(nfc, nfd), "es-ES")))
        assertEquals(listOf("zz-a", "zz-b"), ids(LanguageList.sorted(listOf(nfd, nfc), "es-ES")))
        // case is a later level than letters
        val mixed = listOf(o("x1", "beta", "b"), o("x2", "Alpha", "a"), o("x3", "ALPHA", "a"), o("x4", "Beta", "b"))
        val got = LanguageList.sorted(mixed, "en-US")
        assertEquals(setOf("x2", "x3"), ids(got).take(2).toSet())
        assertEquals(got, LanguageList.sorted(mixed.reversed(), "en-US"))
    }

    @Test fun otherScriptsKeepTheirText() {
        val all = manifestOptions()
        val byId = all.associateBy { it.id }
        for (loc in listOf("en-US", "ru-RU", "ar", "ja-JP", "hi-IN")) {
            val l = LanguageList.sorted(all, loc)
            // labels are shown exactly as the manifest spells them: no romanization, no stripped marks
            for (x in l) assertEquals(byId[x.id]!!.label, x.label)
            before(l, "be", "bg"); before(l, "bg", "ru-RU"); before(l, "ru-RU", "uk") // Беларуская, Български, Русский, Українська
            before(l, "ur", "ar"); before(l, "ar", "fa")                               // اردو, العربية, فارسی (right to left)
            before(l, "fa", "fa-AF")                                                   // فارسی, فارسی دری (افغانستان)
            before(l, "ne-NP", "mr-IN"); before(l, "mr-IN", "hi-IN")                   // नेपाली, मराठी, हिन्दी
        }
        assertEquals("العربية - Arabic", byId["ar"]!!.label)
        assertEquals("日本語 - Japanese", byId["ja-JP"]!!.label)
    }

    @Test fun regionAndScriptVariantsStayDistinct() {
        val l = LanguageList.sorted(manifestOptions(), "en-US")
        for (v in listOf("en-US", "en-GB", "en-AU", "en-CA", "en-IN", "en-SG", "en-ZA", "es-419", "es-ES", "es-MX", "es-US",
            "fr-FR", "fr-CA", "pt-BR", "pt-PT", "zh-CN", "zh-TW", "zh-HK", "ms", "ms-MY", "fa", "fa-IR", "fa-AF", "fa-AE")) {
            assertEquals(v, 1, l.count { it.id == v })
        }
        assertEquals("every row reads differently", l.size, l.map { it.label }.toSet().size)
        before(l, "es-ES", "es-US"); before(l, "es-US", "es-419"); before(l, "es-419", "es-MX") // España, Estados Unidos, Latinoamérica, México
        before(l, "ms", "ms-MY")                                                                // Bahasa Melayu, Bahasa Melayu (Malaysia)
        // script variants, as a manifest could add them
        val sr = listOf(o("sr-Latn", "Srpski (latinica)", "Serbian (Latin)"), o("sr-Cyrl", "Српски (ћирилица)", "Serbian (Cyrillic)"))
        assertEquals(setOf("sr-Latn", "sr-Cyrl"), ids(LanguageList.sorted(sr, "en-US")).toSet())
        assertEquals(LanguageList.sorted(sr, "sr"), LanguageList.sorted(sr.reversed(), "sr"))
    }

    @Test fun missingNamesUnknownCodesAndDuplicates() {
        assertEquals(emptyList<LanguageOption>(), LanguageList.sorted(emptyList(), "en-US"))
        assertEquals(listOf("de-DE"), ids(LanguageList.sorted(listOf(sample.first { it.id == "de-DE" }), "en-US")))
        // a manifest entry without names (or with an unknown code) still gets a row, named by what there is
        val m = manifest().toMutableMap()
        @Suppress("UNCHECKED_CAST")
        val locs = (m["locales"] as List<Map<String, Any?>>).toMutableList()
        locs.add(mapOf("id" to "qaa", "catalog" to "en", "parent" to null, "language" to "qaa", "script" to null, "direction" to "ltr",
            "family_default" to false, "aliases" to emptyList<String>()))
        locs.add(mapOf("id" to "qab", "catalog" to "en", "parent" to null, "language" to "qab", "script" to null, "english_name" to "Testish",
            "native_name" to "  ", "direction" to "ltr", "family_default" to false, "aliases" to emptyList<String>()))
        m["locales"] = locs
        val opts = manifestOptions(m)
        assertEquals("qaa - qaa", opts.first { it.id == "qaa" }.label)
        assertEquals("Testish - Testish", opts.first { it.id == "qab" }.label)
        val l = LanguageList.sorted(opts, "en-US")
        assertEquals(91, l.size)
        before(l, "pl-PL", "qaa"); before(l, "qaa", "ro")  // Polski, qaa, Română
        before(l, "sv-SE", "qab"); before(l, "qab", "th")  // Svenska, Testish, ไทย
        // duplicates: one row per id, whatever the input order
        val de = sample.first { it.id == "de-DE" }
        val dup = listOf(de, sample.first { it.id == "ar" }, de, o("de-DE", "Deutsch (alt)", "German (alt)"))
        val once = LanguageList.sorted(dup, "en-US")
        assertEquals(listOf("de-DE", "ar"), ids(once))
        assertEquals("Deutsch", once[0].name)
        assertEquals(once, LanguageList.sorted(dup.reversed(), "en-US"))
    }

    @Test fun equalLabelsBreakTiesById() {
        val twins = listOf(o("xx-b", "Same", "Same"), o("xx-c", "Same", "Same"), o("xx-a", "Same", "Same"), o("XX-A", "Same", "Same"))
        for (p in listOf(twins, twins.reversed(), twins.shuffled(Random(3))))
            assertEquals(listOf("XX-A", "xx-a", "xx-b", "xx-c"), ids(LanguageList.sorted(p, "en-US")))
        // the English name decides between equal own names
        val g = listOf(o("a2", "Norsk", "Norwegian Nynorsk"), o("a1", "Norsk", "Norwegian Bokmal"))
        assertEquals(listOf("a1", "a2"), ids(LanguageList.sorted(g, "en-US")))
    }

    @Test fun languagesAddedLaterFindTheirPlace() {
        val m = manifest().toMutableMap()
        @Suppress("UNCHECKED_CAST")
        val locs = (m["locales"] as List<Map<String, Any?>>).toMutableList()
        fun add(id: String, native: String, english: String, at: Int) = locs.add(at, mapOf("id" to id, "catalog" to "en", "parent" to null,
            "language" to id, "script" to null, "english_name" to english, "native_name" to native, "direction" to "ltr",
            "family_default" to false, "aliases" to emptyList<String>()))
        // appended, prepended and inserted: the manifest position must not matter
        add("an", "Aragonés", "Aragonese", locs.size)
        add("cy-GB", "Cymraeg", "Welsh", 0)
        add("mt", "Malti", "Maltese", 40)
        add("yo", "Yorùbá", "Yoruba", locs.size)
        m["locales"] = locs
        val l = LanguageList.sorted(manifestOptions(m), "en-US")
        assertEquals(93, l.size)
        assertOrdered(l, "en-US")
        before(l, "af", "an"); before(l, "an", "az-AZ")       // near the beginning: Afrikaans, Aragonés, Azərbaycan
        before(l, "cs-CZ", "cy-GB"); before(l, "cy-GB", "da-DK")
        before(l, "hu-HU", "mt"); before(l, "mt", "nl-NL")     // the middle: Magyar, Malti, Nederlands
        before(l, "tr-TR", "yo"); before(l, "yo", "el-GR")     // the end of the Latin names: Türkçe, Yorùbá, Ελληνικά
        // the shipped manifest is unchanged by the fixture
        assertEquals(89, manifestOptions().size)
    }

    @Test fun currentFollowsTheUiLanguage() {
        val env = LangEnv(HeadlessEnv(Files.createTempDirectory("langlist").toFile()), listOf("en-US"))
        val sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); sh.tick()
        val all = L10n.resolver!!.locales.map(LanguageList::option)
        val en = LanguageList.current()
        assertSame("cached while the language stays", en, LanguageList.current())
        assertEquals(LanguageList.sorted(all, "en-US"), en)
        for (loc in listOf("ru-RU", "ar", "es-419", "ja-JP", "ru-RU", "en-US")) {
            L10n.use(loc)
            val now = LanguageList.current()
            assertEquals(loc, LanguageList.sorted(all, loc), now)
            assertSame(now, LanguageList.current())
        }
        assertEquals("rebuilt, not stale", en, LanguageList.current())
    }

    /** The rows the Language window shows, top to bottom, collected by scrolling through it. */
    private fun windowRows(sh: Shell, lang: LanguageApp, known: Set<String>): Pair<List<String>, String?> {
        val r = sh.clientRect(sh.findWindow("language")!!)
        lang.scroll(0, 100_000, r); sh.tick()
        val out = ArrayList<String>()
        var selected: String? = null
        repeat(200) {
            sh.invalidate(); sh.tick()
            val rows = sh.accessibilityNodes().filter { it.button && it.label in known }.sortedBy { it.rect.y }
            rows.firstOrNull { it.selected }?.let { selected = it.label }
            val fresh = rows.map { it.label }.dropWhile { it in out }
            if (fresh.isEmpty()) return out to selected
            out.addAll(fresh)
            lang.scroll(0, -ROW_H * maxOf(1, rows.size - 1), r)
        }
        return out to selected
    }

    @Test fun languageWindowShowsTheOrderAndKeepsTheSelection() {
        val env = LangEnv(HeadlessEnv(Files.createTempDirectory("langwin").toFile()), listOf("en-US"))
        val sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); sh.tick()
        Launch.language(sh); sh.tick()
        val lang = sh.findWindow("language")!!.app as LanguageApp
        val auto = tr("settings.language.automatic")
        val labels = LanguageList.current().map { it.label }
        val (rows, sel) = windowRows(sh, lang, labels.toSet() + auto)
        assertEquals(listOf(auto) + labels, rows)
        assertEquals("Automatic is the current choice", auto, sel)

        // choose Russian by tapping its row (it is somewhere down the list): Cyrillic collation reorders it
        val r = sh.clientRect(sh.findWindow("language")!!)
        lang.scroll(0, 100_000, r)
        var node: A11yNode? = null
        for (i in 0 until 200) {
            sh.invalidate(); sh.tick()
            node = sh.accessibilityNodes().firstOrNull { it.button && it.label == "Русский - Russian" }
            if (node != null) break
            lang.scroll(0, -ROW_H, r)
        }
        sh.accessibilityActivate(node!!); sh.invalidate(); sh.tick()
        assertEquals("ru-RU", sh.settings.language)
        assertEquals("ru-RU", L10n.locale?.id)
        val after = sh.accessibilityNodes().first { it.button && it.label == "Русский - Russian" }
        assertTrue("selected by id", after.selected)
        assertEquals("the chosen row stays under the finger", node.rect.y, after.rect.y)
        val ru = LanguageList.current().map { it.label }
        val autoRu = tr("settings.language.automatic")
        assertNotEquals("the special row is translated, the language rows are not", auto, autoRu)
        assertEquals(LanguageList.sorted(LanguageList.current(), "ru-RU").map { it.label }, ru)
        val (rowsRu, selRu) = windowRows(sh, lang, ru.toSet() + autoRu)
        assertEquals(listOf(autoRu) + ru, rowsRu)
        assertEquals("Русский - Russian", selRu)

        // restored from the session: same language, same selection (ids are saved, never row positions)
        sh.saveSession(); L10n.use("en-US")
        val sh2 = Shell(env); sh2.resize(480, 320); sh2.restoreSession(); sh2.tick()
        assertEquals("ru-RU", sh2.settings.language)
        val lang2 = (sh2.findWindow("language") ?: run { Launch.language(sh2); sh2.tick(); sh2.findWindow("language")!! }).app as LanguageApp
        assertEquals("Русский - Russian", windowRows(sh2, lang2, ru.toSet() + autoRu).second)
    }

    @Test fun collatorIsTheDisplayLocales() {
        // the same names, two orders: Swedish has Å, Ä, Ö as letters after Z, English as accented A and O
        val words = listOf("Ö", "Z", "Å", "A", "Ä").mapIndexed { i, w -> o("x$i", w, w) }
        val sv = LanguageList.sorted(words, "sv-SE").map { it.name }
        val en = LanguageList.sorted(words, "en-US").map { it.name }
        assertTrue(sv.toString(), sv.indexOf("Z") < sv.indexOf("Å") && sv.indexOf("Z") < sv.indexOf("Ö"))
        assertTrue(en.toString(), en.indexOf("Ö") < en.indexOf("Z") && en.indexOf("Å") < en.indexOf("Z"))
        // and it is the display locale's own collator, with canonical decomposition
        val c = Collator.getInstance(Locale.forLanguageTag("sv-SE")).apply { decomposition = Collator.CANONICAL_DECOMPOSITION }
        assertEquals(words.map { it.name }.sortedWith(c), sv)
    }
}
