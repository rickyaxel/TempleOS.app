package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import java.io.File
import java.security.MessageDigest
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Hex sha256 of [b] (tests that identify original wording by hash instead of spelling it out). */
fun sha256Hex(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

/**
 * Content moderation of the bundled TempleOS files (docs/content-moderation/CONTENT_MODERATION.md;
 * Swift ContentModerationTests). The edits are made when the bundled drive is built
 * (tools/resource-packaging/moderation.json); these tests check what the app actually shows. The original
 * wording is never written here: it is identified by the manifest's hashes, and checks that need it rebuild
 * it in memory from the ISO extraction (reference/templeos-iso, on development machines).
 */
@Suppress("UNCHECKED_CAST")
class ContentModerationTest {
    private val dir = kotlin.io.path.createTempDirectory("tosm-moderation").toFile()
    private val env = HeadlessEnv(dir)

    @After fun cleanup() { dir.deleteRecursively() }

    private data class Edit(val id: String, val path: String, val line: Int, val start: Int, val end: Int, val sha256: String, val replace: String)

    private val manifest = Json.parse(File(SHARED.parentFile, "tools/resource-packaging/moderation.json").readText()) as Map<String, Any?>
    private val markers = (manifest["markers"] as Map<String, Any?>).mapValues { it.value as String }
    private val edits = (manifest["edits"] as List<Any?>).map {
        val d = it as Map<String, Any?>
        fun i(k: String) = (d[k] as Number).toInt()
        Edit(d["id"] as String, d["path"] as String, i("line"), i("start"), i("end"), d["sha256"] as String, d["replace"] as String)
    }

    private fun replacement(e: Edit) = if (e.replace.startsWith("@")) markers.getValue(e.replace.substring(1)) else e.replace

    /** Lines of the text part (before the first NUL). */
    private fun lines(b: ByteArray): List<ByteArray> {
        val n = b.indexOf(0.toByte()).let { if (it < 0) b.size else it }
        val out = ArrayList<ByteArray>(); var s = 0
        for (i in 0 until n) if (b[i] == '\n'.code.toByte()) { out += b.copyOfRange(s, i); s = i + 1 }
        out += b.copyOfRange(s, n)
        return out
    }

    private fun bundled(path: String) = env.fs.readFile("C:/$path")!!
    private fun iso(path: String) = File(REFERENCE, "templeos-iso/$path").let { if (it.exists()) it.readBytes() else null }

    private val origins: Map<String, String> = File(SHARED, "bundled-fs.index").readLines().mapNotNull { l ->
        val f = l.split("\t"); if (f.size >= 5 && f[0] == "F") f[1] to f[4] else null
    }.toMap()

    private val terry = "TempleOS V5.03 (public domain, Terry A. Davis)"

    @Test fun everyEditIsInTheBundledFiles() {
        assertTrue(edits.size >= 20)
        for (e in edits) {
            val ln = lines(bundled(e.path))[e.line - 1]
            val r = replacement(e).toByteArray(Charsets.ISO_8859_1)
            // earlier edits on the same line moved this one by their change in length
            val shift = edits.filter { it.path == e.path && it.line == e.line && it.start < e.start }
                .sumOf { replacement(it).length - (it.end - it.start) }
            val at = e.start + shift
            assertArrayEquals("${e.id}: replacement in place", r, ln.copyOfRange(at, minOf(ln.size, at + r.size)))
            assertTrue("${e.id}: the index marks ${e.path} modified", origins.getValue(e.path).startsWith("$terry; modified:"))
            assertEquals("${e.id}: the viewer says adapted", DocProvenance.ADAPTED, DocProvenance.of(env.fs, "C:/${e.path}"))
        }
        val edited = edits.map { it.path }.toSet()
        for ((path, origin) in origins) if ("; modified:" in origin) assertTrue("$path modified without an edit", path in edited)
    }

    @Test fun onlyTheManifestEditsDifferFromTheOriginals() {
        assumeTrue("reference/templeos-iso is not on this machine", iso("Adam/God/HSNotes.DD") != null)
        for ((path, origin) in origins) {
            if (!origin.startsWith(terry)) continue
            val o = iso(path)!!; val b = bundled(path)
            val mine = edits.filter { it.path == path }
            if (mine.isEmpty()) { assertArrayEquals("$path is byte-identical to the ISO", o, b); continue }
            val ol = lines(o).toMutableList()
            for (e in mine.sortedWith(compareByDescending<Edit> { it.line }.thenByDescending { it.start })) {
                val l = ol[e.line - 1]
                assertEquals("${e.id}: the manifest matches the original", e.sha256, sha256Hex(l.copyOfRange(e.start, e.end)))
                ol[e.line - 1] = l.copyOfRange(0, e.start) + replacement(e).toByteArray(Charsets.ISO_8859_1) + l.copyOfRange(e.end, l.size)
            }
            val bl = lines(b)
            assertEquals("$path: line count", ol.size, bl.size)
            for (i in ol.indices) assertArrayEquals("$path:${i + 1}", ol[i], bl[i])
            val oi = o.indexOf(0.toByte())
            if (oi >= 0) assertArrayEquals("$path: sprites", o.copyOfRange(oi, o.size), b.copyOfRange(b.indexOf(0.toByte()), b.size))
        }
    }

    @Test fun redactedWordingIsNotShownAnywhere() {
        assumeTrue("reference/templeos-iso is not on this machine", iso("Adam/God/HSNotes.DD") != null)
        val sh = Shell(env); sh.resize(402, 874)
        for (path in edits.filter { it.path.endsWith(".DD") }.map { it.path }.toSet()) {
            Launch.doc(sh, "C:/$path")
            repeat(3) { sh.invalidate(); sh.tick() }
            val d = sh.focused!!.app as DocViewerApp
            val shown = d.documentText(200) + "\n" + sh.accessibilityNodes().joinToString("\n") { it.label }
            val squashed = shown.filterNot { it.isWhitespace() }
            for (e in edits) {
                if (e.path != path || e.end - e.start < 6) continue
                val original = String(lines(iso(path)!!)[e.line - 1].copyOfRange(e.start, e.end), Charsets.ISO_8859_1)
                val prose = original.replace(Regex("\\$[^$]*\\$"), "").filterNot { it.isWhitespace() }
                if (prose.length >= 6) assertFalse("${e.id}: redacted wording is shown", prose in squashed)
            }
            assertTrue("$path: the marker is shown", "redacted]" in shown)
            sh.close(sh.focused!!, force = true)
        }
    }

    @Test fun religiousAndTechnicalTextIsKept() {
        val hs = String(bundled("Adam/God/HSNotes.DD"), Charsets.ISO_8859_1)
        assertTrue("God is everywhere in the Holy Spirit notes", hs.split("God").size > 60)
        for (kept in listOf("Matthew,15:11", "1 Corinthians,12:1-31", "Numbers,11:1-35", "Are you calling me lazy?", "Favorite sport?", "Hockey"))
            assertTrue("kept: $kept", kept in hs)
        assertEquals(DocProvenance.INCLUDED, DocProvenance.of(env.fs, "C:/Misc/Bible.TXT"))
        assertTrue("In the beginning God created the heaven and the earth." in String(bundled("Misc/Bible.TXT"), Charsets.ISO_8859_1))
        assertFalse(edits.any { it.path == "Misc/Bible.TXT" })
        assertEquals(1, edits.count { it.path == "Adam/God/Vocab.DD" })
    }

    @Test fun noSubstringCollateral() {
        val all = listOf("Doc/Glossary.DD", "Doc/HolyC.DD", "Misc/PCIDevices.DD", "Doc/Charter.DD").joinToString("") { String(bundled(it), Charsets.ISO_8859_1) }
        for (w in listOf("class", "assembl", "Matsushita", "brainf***")) assertTrue("$w present", w in all)
        assertTrue("Homosexuality?" in String(bundled("Adam/God/HSNotes.DD"), Charsets.ISO_8859_1))
    }

    @Test fun markersAreSafeDolDocText() {
        for (m in markers.values) assertTrue(m, m.all { it.code < 128 } && '$' !in m && '\u0000' !in m)
        for (path in edits.map { it.path }.toSet()) {
            lines(bundled(path)).forEachIndexed { i, l ->
                val singles = String(l, Charsets.ISO_8859_1).replace("$$", "").count { it == '$' }
                assertEquals("$path:${i + 1} DolDoc commands balanced", 0, singles % 2)
            }
        }
    }

    @Test fun everyPathReadsTheModeratedText() {
        val sh = Shell(env); sh.resize(360, 640)
        assertTrue("[Derogatory remark redacted]" in String(env.fs.readFile("C:/Adam/God/HSNotes.DD")!!, Charsets.ISO_8859_1))
        Launch.editor(sh, "C:/Adam/God/HSNotes.DD"); sh.tick()
        assertTrue("[Derogatory remark redacted]" in (sh.focused!!.app as EditorApp).text())
        Launch.doc(sh, "C:/Adam/God/HSNotes.DD"); sh.tick()
        assertTrue("[Derogatory remark redacted]" in (sh.focused!!.app as DocViewerApp).documentText())
    }

    @Test fun languagesShowTheSameModeratedDocument() {
        val sh = Shell(env); sh.resize(360, 640)
        val texts = listOf("en-US", "ar", "ja-JP", "de-DE").map { loc ->
            sh.settings.language = loc; sh.applyLanguage()
            DocViewerApp(sh, "C:/Adam/God/HSNotes.DD").documentText(80)
        }
        assertEquals("the document does not change with the language", 1, texts.toSet().size)
        val files = File(SHARED, "runtime/l10n").listFiles()!!.filter { it.name.endsWith(".json") && it.name != "locales.json" }
        assertEquals(73, files.size)
        for (f in files) {
            val c = Json.parse(f.readText()) as Map<String, Any?>
            for (k in listOf("doc.notice.adapted.body", "about.how.body")) {
                assertFalse("${f.name}: $k", (c[k] as? String).isNullOrEmpty())
                if (f.name != "en.json") assertTrue("${f.name}: $k flagged for review", ((c["\$review"] as? List<Any?>) ?: emptyList()).contains(k))
            }
            assertTrue("${f.name}: About names Terry A. Davis", (c["about.how.body"] as String).contains("Terry A. Davis"))
        }
    }

    /** About says that some wording was edited, by the project, and that inclusion is not endorsement (CONTENT_MODERATION.md §5). */
    @Test fun aboutDescribesTheEditsWithoutClaimingCompleteness() {
        val en = (Json.parse(File(SHARED, "runtime/l10n/en.json").readText()) as Map<String, Any?>)["about.how.body"] as String
        for (s in listOf("Some of the original wording", "censored or redacted by this project", "these edits are not Terry A. Davis' wording",
                "does not mean endorsing every statement"))
            assertTrue(s, en.contains(s))
        assertFalse("no claim that every offensive remark was removed", en.contains("Offensive words and remarks about groups of people in the original files were"))
        for (loc in listOf("en-US", "de-DE", "ja-JP", "ar", "zh-CN")) {
            val sh = Shell(env); sh.resize(360, 640)
            sh.settings.language = loc; sh.applyLanguage()
            sh.open(AboutApp(sh)); sh.tick()
            val text = sh.accessibilityNodes().joinToString("\n") { it.label }
            assertTrue("$loc shows the About moderation text", text.contains(L10n.tr("about.how.body")))
            if (loc != "en-US") assertNotEquals("$loc is translated", en, L10n.tr("about.how.body"))
        }
    }
}
