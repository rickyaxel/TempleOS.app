package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** A headless shell whose device prefers [langs] (docs/localization.md). */
class LangEnv(val inner: HeadlessEnv, var langs: List<String>, var region: String? = null) : ShellEnv by inner {
    override fun preferredLanguages() = langs
    override fun deviceRegion() = region
    override fun measureText(s: String) = s.length * 9
}

class L10nTest {
    private val l10n = File(SHARED, "runtime/l10n")

    @Suppress("UNCHECKED_CAST")
    private fun json(f: File) = Json.parse(f.readText()) as Map<String, Any?>

    private fun shell(langs: List<String>, region: String? = null): Pair<Shell, LangEnv> {
        val env = LangEnv(HeadlessEnv(Files.createTempDirectory("l10n").toFile()), langs, region)
        val sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); sh.tick()
        return sh to env
    }

    @After fun english() { L10n.use("en-US") }

    @Test fun resolverVectors() {
        val r = LocaleResolver(json(File(l10n, "locales.json")))
        @Suppress("UNCHECKED_CAST")
        val vectors = json(File(SHARED, "test-vectors/l10n/resolver_vectors.json"))["vectors"] as List<Map<String, Any?>>
        assertTrue(vectors.size >= 100)
        for (v in vectors) {
            @Suppress("UNCHECKED_CAST")
            val got = r.resolve(v["manual"] as String?, v["preferred"] as List<String>, v["device_region"] as String?)
            assertEquals(v["name"] as String, v["expected"] to v["source"], got)
        }
    }

    @Test fun manifestAndCatalogs() {
        val m = json(File(l10n, "locales.json"))
        @Suppress("UNCHECKED_CAST")
        val locales = m["locales"] as List<Map<String, Any?>>
        assertEquals(89, locales.size)
        val catalogs = locales.map { it["catalog"] as String }.toSet()
        assertEquals(73, catalogs.size)
        val en = json(File(l10n, "en.json")).keys.filter { !it.startsWith("$") }.toSet()
        for (c in catalogs) {
            val f = File(l10n, "$c.json")
            if (!f.exists()) continue // reported by tools/l10n/validate.py
            val keys = json(f).keys.filter { !it.startsWith("$") }.toSet()
            assertEquals("catalog $c", en, keys)
        }
    }

    @Test fun fallbackPlaceholdersAndCp437() {
        shell(listOf("en-US"))
        assertEquals("missing.key.for.test", tr("missing.key.for.test"))
        assertTrue(L10n.has("button.cancel"))
        val s = "é ñ ß Ü"
        assertTrue(Cp437.representable(s))
        assertEquals(s, Cp437.decode(Cp437.encode(s)))
        assertFalse(Cp437.representable("日本語"))
        assertEquals("?", Cp437.encode("日"))
        L10n.use("ja-JP")
        assertEquals("ja-JP", L10n.locale?.id)
        // a Japanese string cannot go into a CP437 console: English instead
        val key = "button.cancel"
        assertFalse(Cp437.representable(tr(key)))
        assertEquals(Cp437.encode(L10n.tr8(key)), L10n.tr8(key))
        assertTrue(Cp437.representable(L10n.tr8(key)))
        L10n.use("de-DE")
        assertTrue(Cp437.representable(L10n.tr8(key)))
    }

    @Test fun deviceLanguageAndManualOverride() {
        val (sh, env) = shell(listOf("cy-GB", "ja-JP"), "JP")
        assertEquals("ja-JP", L10n.locale?.id)
        val settings = SettingsApp(sh); sh.open(settings); sh.tick()
        val windows = sh.windows.size
        val jaTitle = settings.title
        // manual choice wins over the device and keeps every window
        sh.settings.language = "de-DE"; sh.applyLanguage(); sh.tick()
        assertEquals("de-DE", L10n.locale?.id)
        assertEquals(windows, sh.windows.size)
        assertNotEquals(jaTitle, settings.title)
        assertTrue(L10n.version > 0)
        // persisted, restored
        sh.saveSession()
        L10n.use("en-US")
        val sh2 = Shell(env); sh2.resize(320, 480); sh2.restoreSession(); sh2.tick()
        assertEquals("de-DE", sh2.settings.language)
        assertEquals("de-DE", L10n.locale?.id)
        // "Automatic" restores the device language
        sh2.settings.language = ""; sh2.applyLanguage()
        assertEquals("ja-JP", L10n.locale?.id)
        // device language changes while running
        env.langs = listOf("fr-CA"); sh2.applyLanguage()
        assertEquals("fr-CA", L10n.locale?.id)
        env.langs = listOf("fr"); env.region = "CA"; sh2.applyLanguage()
        assertEquals("fr-CA", L10n.locale?.id)
        env.langs = emptyList(); sh2.applyLanguage()
        assertEquals("en-US", L10n.locale?.id)
    }

    @Test fun textRunsForScriptsOutsideTheFont() {
        val (sh, _) = shell(listOf("ja-JP"))
        // The required intro is locale-independent; exercise translated settings instead.
        Launch.settings(sh); sh.invalidate(); sh.tick()
        val s = sh.surface
        assertTrue("Japanese UI text is drawn by the platform", s.runs.isNotEmpty())
        for (r in s.runs) {
            assertFalse(Cp437.representable(r.text))
            assertTrue(r.clip.w > 0 && r.clip.h > 0)
            assertTrue(r.clip.x >= 0 && r.clip.right <= s.width && r.clip.y >= 0 && r.clip.bottom <= s.height)
        }
        // a window drawn later hides earlier text runs under it
        Launch.terminal(sh); sh.tick()
        assertTrue(s.occluders.isNotEmpty())
        assertTrue(s.runs.any { r -> s.occluders.any { it.z > r.z } })
        // German fits the TempleOS font: no platform text at all on the desktop
        L10n.use("de-DE"); sh.invalidate(); sh.tick()
        assertTrue(s.runs.all { !Cp437.representable(it.text) })
    }

    @Test fun rightToLeft() {
        shell(listOf("ar-EG"), "EG")
        assertEquals("ar", L10n.locale?.id)
        assertTrue(L10n.rtl)
        L10n.use("he-IL"); assertTrue(L10n.rtl)
        L10n.use("en-US"); assertFalse(L10n.rtl)
    }
}
