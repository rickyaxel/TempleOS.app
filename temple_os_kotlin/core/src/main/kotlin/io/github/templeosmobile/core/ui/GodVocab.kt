package io.github.templeosmobile.core.ui

import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/**
 * Terry Davis' God vocabulary and its translations (docs/localization-vocabulary.md).
 *
 * The English entries are the reference: [tokenize] splits Adam/God/Vocab.DD exactly as GodInit
 * (Adam/God/HolySpirit.HC) does, and entry i keeps index i. GodWordStr picks
 * god.words[GodBits(17) % god.num_words]; translations only change how a picked entry is shown,
 * never which entry is picked or how many there are.
 *
 * Translations are bundled runtime files, one per UI catalog (`l10n/vocab/<catalog>.deflate`,
 * written by tools/l10n/vocab.py): raw DEFLATE of UTF-8 lines, a header
 * `#templeos-vocab 1 count=<n> sha256=<hex>` naming the English vocabulary they translate, then one
 * line per entry ("" = not translated). Only the current catalog is loaded, on first use; a missing,
 * corrupt or mismatched file shows the English entries.
 */
object GodVocab {
    const val FORMAT = "#templeos-vocab 1"

    /** Kernel/StrA.HC char_bmp_word: ' 0-9 A-Z _ a-z and every byte >= 128. */
    fun isWordChar(b: Int) = b == 0x27 || b in 0x30..0x39 || b in 0x41..0x5A || b == 0x5F || b in 0x61..0x7A || b >= 0x80

    /** GodInit's word list: runs of word characters in the text part (FileRead's string ends at the first NUL). */
    fun tokenize(data: ByteArray): List<String> {
        val out = ArrayList<String>(8192)
        var i = 0
        val n = data.indexOf(0.toByte()).let { if (it < 0) data.size else it }
        val sb = StringBuilder()
        while (i < n) {
            while (i < n && !isWordChar(data[i].toInt() and 0xFF)) i++
            if (i >= n) break
            sb.setLength(0)
            while (i < n && isWordChar(data[i].toInt() and 0xFF)) { sb.append((data[i].toInt() and 0xFF).toChar()); i++ }
            out.add(Cp437.decode(sb.toString()))
        }
        return out
    }

    /** sha256 of the entries joined by '\n' (UTF-8), as in the translation files' header. */
    fun digest(entries: List<String>): String {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(entries.joinToString("\n").toByteArray(Charsets.UTF_8))
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** Why a catalog shows English entries: "ok" (translations loaded), "english", "missing", "mismatch" or "corrupt". */
    class Table(val catalog: String, val status: String, private val lines: Array<String>?) {
        /** The translation of entry [i], or null (shown in English). */
        fun translation(i: Int): String? = lines?.getOrNull(i)?.takeIf { it.isNotEmpty() }
        val translated get() = lines?.count { it.isNotEmpty() } ?: 0
    }

    private var cached: Table? = null
    private var cachedDigest = ""
    /** How many translation files were read and decoded (tests: language switches load once). */
    @Volatile var loads = 0
        private set

    /**
     * The translations of the vocabulary with [digest] for [catalog], from [source] (runtime files).
     * One catalog is kept; asking for another releases it.
     */
    @Synchronized fun table(catalog: String, digest: String, count: Int, source: (String) -> ByteArray?): Table {
        cached?.let { if (it.catalog == catalog && cachedDigest == digest) return it }
        val t = if (catalog == "en") Table(catalog, "english", null) else load(catalog, digest, count, source)
        cached = t; cachedDigest = digest
        return t
    }

    private fun load(catalog: String, digest: String, count: Int, source: (String) -> ByteArray?): Table {
        val raw = source("l10n/vocab/$catalog.deflate") ?: return Table(catalog, "missing", null)
        loads++
        val text = try {
            InflaterInputStream(ByteArrayInputStream(raw), Inflater(true)).use { it.readBytes() }.toString(Charsets.UTF_8)
        } catch (e: java.io.IOException) { return Table(catalog, "corrupt", null) }
        val lines = text.split('\n').let { if (it.lastOrNull() == "") it.dropLast(1) else it }
        if (lines.isEmpty() || !lines[0].startsWith(FORMAT)) return Table(catalog, "corrupt", null)
        // the file must translate this exact vocabulary (a user copy of Vocab.DD has other entries)
        if (lines[0] != "$FORMAT count=$count sha256=$digest") return Table(catalog, "mismatch", null)
        if (lines.size != count + 1) return Table(catalog, "corrupt", null)
        return Table(catalog, "ok", Array(count) { i -> lines[i + 1].takeIf { valid(it) } ?: "" })
    }

    /** No control characters or U+FFFD (a decoding error); such an entry is shown in English. */
    private fun valid(s: String) = s.none { it.code < 0x20 || it == '�' }
}

/**
 * The vocabulary God Words picks from: the English entries of a Vocab.DD file and their display in
 * the current UI language.
 */
class Vocabulary(val entries: List<String>, private val source: (String) -> ByteArray?) {
    val digest = GodVocab.digest(entries)
    val size get() = entries.size

    /** Entry [i] in the current UI language (the English entry when there is no translation). */
    fun display(i: Int): String = table().translation(i) ?: entries[i]

    /** The current catalog's translations. */
    fun table() = GodVocab.table(L10n.locale?.catalog ?: "en", digest, entries.size, source)
}
