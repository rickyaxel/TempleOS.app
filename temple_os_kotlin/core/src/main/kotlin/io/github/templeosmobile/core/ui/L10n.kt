package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.Brand

/**
 * UI localization (docs/localization.md). Everything is on the device: the manifest
 * (`l10n/locales.json`, 89 locales over 73 catalogs) and one JSON catalog per language
 * (`l10n/<catalog>.json`) are bundled runtime files. Only English and the current catalog are
 * loaded. Missing keys fall back to English, never to the key itself in a release.
 */
class UiLocale(
    val id: String, val catalog: String, val parent: String?, val language: String, val script: String?,
    val englishName: String, val nativeName: String, val rtl: Boolean, val familyDefault: Boolean,
    val aliases: List<String>,
)

/**
 * Picks the UI locale (same contract as tools/l10n/resolver.py and the Swift port; shared vectors
 * in shared/test-vectors/l10n/resolver_vectors.json): an explicit in-app choice, else the first
 * supported language in the device's preference order, else en-US. Region and script variants go
 * through aliases, exclusions and language families (longest whole-subtag prefix). The device's
 * own region setting only picks a member of a family (bare "fr" on a Canadian device -> fr-CA);
 * no geography is ever used.
 */
class LocaleResolver(manifest: Map<String, Any?>) {
    val default = manifest["default_locale"] as String
    val locales: List<UiLocale>
    private val inputTag = Regex(manifest["input_tag"] as String)
    private val countries: Map<String, List<String>>
    private val ids: Map<String, String>
    private val families = HashMap<String, Pair<List<String>, String?>>()
    private val prefixes: List<Triple<String, Int, String?>> // (prefix, kind, target); kind 0 locale, 1 family, 2 exclude

    init {
        @Suppress("UNCHECKED_CAST")
        locales = (manifest["locales"] as List<Map<String, Any?>>).map { m ->
            UiLocale(m["id"] as String, m["catalog"] as String, m["parent"] as String?, m["language"] as String, m["script"] as String?,
                m["english_name"] as? String ?: "", m["native_name"] as? String ?: "", m["direction"] == "rtl", m["family_default"] == true,
                (m["aliases"] as List<*>).map { it as String })
        }
        @Suppress("UNCHECKED_CAST")
        countries = (manifest["countries"] as Map<String, List<String>>)
        ids = locales.associate { it.id.lowercase() to it.id }
        @Suppress("UNCHECKED_CAST")
        val familyScripts = (manifest["family_scripts"] as List<String>).toSet()
        val groups = LinkedHashMap<String, MutableList<UiLocale>>()
        for (l in locales) {
            val key = (l.language + (if (l.script != null) "-" + l.script else "")).lowercase()
            groups.getOrPut(key) { ArrayList() }.add(l)
            if (l.language in familyScripts) groups.getOrPut(l.language) { ArrayList() }.add(l)
        }
        for ((key, members) in groups) {
            val defaults = members.filter { it.familyDefault }.map { it.id }
            families[key] = members.map { it.id } to (if (key in familyScripts) null else defaults.firstOrNull())
        }
        val items = ArrayList<Triple<String, Int, String?>>()
        for (k in families.keys) items.add(Triple(k, 1, k))
        for (l in locales) for (tag in listOf(l.id) + l.aliases) if (tag.lowercase() !in families) items.add(Triple(tag.lowercase(), 0, l.id))
        @Suppress("UNCHECKED_CAST")
        for (x in manifest["exclusions"] as List<String>) items.add(Triple(x.lowercase(), 2, null))
        prefixes = items.sortedWith(compareBy({ -it.first.length }, { it.first }))
    }

    fun byId(id: String) = locales.firstOrNull { it.id == id }

    private fun tagRegion(tag: String): String? {
        for (part in tag.split('-').drop(1)) {
            if (part.length == 2 && part.all { it.isLetter() }) return part.uppercase()
            if (part.length == 3 && part.all { it.isDigit() }) return null
        }
        return null
    }

    /** Normalizes one tag (device, persisted or legacy value) to a supported locale id, or null. */
    fun match(value: String?, deviceRegion: String? = null): String? {
        if (value == null) return null
        val tag = value.trim(' ', '\t', '\r', '\n').replace('_', '-').lowercase()
        if (!inputTag.matches(tag)) return null
        ids[tag]?.let { return it }
        val region = deviceRegion?.takeIf { it.length == 2 && it.all { c -> c in 'A'..'Z' || c in 'a'..'z' } }?.uppercase()
        for ((prefix, kind, target) in prefixes) {
            if (tag == prefix || tag.startsWith("$prefix-")) {
                when (kind) {
                    0 -> return target
                    2 -> return null
                }
                val (members, def) = families[target]!!
                for (hint in listOf(tagRegion(tag), region)) {
                    for (c in countries[hint ?: continue].orEmpty()) if (c in members) return c
                }
                return def
            }
        }
        return null
    }

    /** (locale id, source): "manual", "preferred" or "default". */
    fun resolve(manual: String?, preferred: List<String>, deviceRegion: String?): Pair<String, String> {
        match(manual, deviceRegion)?.let { return it to "manual" }
        for (p in preferred) match(p, deviceRegion)?.let { return it to "preferred" }
        return default to "default"
    }
}

object L10n {
    /** View-owned values refresh once per language change, preserving input and callbacks. */
    class Presentation<T>(private val render: () -> T) {
        private var generation = L10n.version
        private var cached = render()
        val value: T get() {
            if (generation != L10n.version) { cached = render(); generation = L10n.version }
            return cached
        }
    }

    @Volatile private var source: ((String) -> ByteArray?)? = null
    @Volatile private var english: Map<String, String> = emptyMap()
    @Volatile private var strings: Map<String, String> = emptyMap()
    @Volatile var resolver: LocaleResolver? = null
        private set
    @Volatile var locale: UiLocale? = null
        private set
    /** Increases on every language change (views redraw, cached labels refresh). */
    @Volatile var version = 0
        private set

    val rtl get() = locale?.rtl == true

    private fun catalog(name: String): Map<String, String> {
        val b = source?.invoke("l10n/$name.json") ?: return emptyMap()
        @Suppress("UNCHECKED_CAST")
        return (Json.parse(String(b, Charsets.UTF_8)) as? Map<String, Any?>).orEmpty()
            .filterKeys { !it.startsWith("$") }.mapValues { it.value as? String ?: "" }.filterValues { it.isNotEmpty() }
    }

    /** Loads the manifest and English from bundled runtime files (idempotent). */
    @Synchronized fun init(runtimeFile: (String) -> ByteArray?) {
        if (source != null && resolver != null) return
        source = runtimeFile
        val m = runtimeFile("l10n/locales.json")
        @Suppress("UNCHECKED_CAST")
        resolver = m?.let { LocaleResolver(Json.parse(String(it, Charsets.UTF_8)) as Map<String, Any?>) }
        english = catalog("en")
        if (locale == null) { locale = resolver?.byId("en-US"); strings = english }
    }

    /** Switches the UI language; only the chosen catalog (plus English) stays in memory. */
    @Synchronized fun use(localeId: String) {
        val r = resolver ?: return
        val l = r.byId(localeId) ?: r.byId(r.default) ?: return
        if (locale?.id == l.id && strings.isNotEmpty()) return
        strings = if (l.catalog == "en") english else catalog(l.catalog)
        locale = l
        version++
    }

    fun has(key: String) = key in strings || key in english

    /**
     * The text for [key] in the current language, English if missing; `{name}` placeholders are
     * filled from [args], and `{app}` with [Brand.APP_NAME] (the name is never in a catalog).
     */
    fun tr(key: String, vararg args: Pair<String, Any?>): String = fill(strings[key] ?: english[key] ?: key, args)

    private val placeholder = Regex("\\{[a-z_]+\\}")

    private fun fill(text: String, args: Array<out Pair<String, Any?>>): String =
        placeholder.replace(text) { match ->
            val name = match.value.substring(1, match.value.length - 1)
            // Inserted filenames, errors and program text are literal data, never another template.
            if (name == "app") Brand.APP_NAME
            else args.firstOrNull { it.first == name }?.let { it.second.toString() } ?: match.value
        }

    /**
     * For text written into TempleOS console windows, which hold 8-bit CP437 cells: the
     * translation when the TempleOS font can show all of it, otherwise English.
     */
    fun tr8(key: String, vararg args: Pair<String, Any?>): String {
        val t = tr(key, *args)
        if (Cp437.representable(t)) return Cp437.encode(t)
        return fill(english[key] ?: key, args)
    }
}

/** A filesystem error in the UI language. */
fun io.github.templeosmobile.core.kernel.FsError.localized(): String =
    key?.takeIf { L10n.has(it) }?.let { k ->
        L10n.tr(k, *args.map { (name, value) ->
            name to if (name in listOf("path", "name") && value is String) InputCharacterPolicy.display(value) else value
        }.toTypedArray())
    } ?: (message ?: tr("error.generic"))

/** Shorthand for [L10n.tr]. */
fun tr(key: String, vararg args: Pair<String, Any?>) = L10n.tr(key, *args)

/** The TempleOS font's character set (IBM code page 437) for Unicode text. */
object Cp437 {
    private const val HIGH = "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "
    private val map = HashMap<Char, Int>().apply { for ((i, c) in HIGH.withIndex()) put(c, 0x80 + i) }

    /** CP437 code of [c], or -1 if the TempleOS font has no such glyph. */
    fun code(c: Char): Int = when {
        // 0x01-0x1F: the TempleOS font's graphic glyphs (arrows, borders), used by the UI on purpose
        c.code in 0x01..0x7E -> c.code
        else -> map[c] ?: -1
    }

    fun representable(s: String) = s.all { code(it) >= 0 }

    /** A CP437 byte string (one char per byte, as HolyC programs produce) as Unicode. */
    fun decode(bytes: String): String {
        val sb = StringBuilder(bytes.length)
        for (c in bytes) { val b = c.code and 0xFF; sb.append(if (b >= 0x80) HIGH[b - 0x80] else c) }
        return sb.toString()
    }

    /** [s] as CP437 codes in a String (one char per code), for the TempleOS font and console. */
    fun encode(s: String): String {
        val sb = StringBuilder(s.length)
        for (c in s) { val k = code(c); sb.append(if (k >= 0) k.toChar() else '?') }
        return sb.toString()
    }
}
