package io.github.templeosmobile.core.ui

import java.text.Collator
import java.util.Locale

/**
 * One choice in a list of languages: the canonical locale id (what is selected and saved) and the
 * text the row shows. [name] is the language's own name and [gloss] its English name, so the row
 * reads "Deutsch - German" in every UI language.
 */
data class LanguageOption(val id: String, val name: String, val gloss: String) {
    val label get() = "$name - $gloss"
    override fun toString() = label
}

/**
 * The order of every list of languages the user picks from (docs/localization.md, "Language
 * lists"; same contract as the Swift port). Rows are in alphabetical order of their visible text,
 * collated for the current UI language: first the language's own name, then its English name,
 * then, for rows that still compare equal, the locale id. The manifest's order (and its
 * `sort_order` field) never reaches the screen, so a language added to `locales.json` takes its
 * place in the list by its names alone.
 *
 * Collation is `java.text.Collator`, which Android backs with ICU: the UI language's own script
 * comes first (Cyrillic before Latin for Russian, for example), then the CLDR script order.
 */
object LanguageList {
    /** The row for a manifest locale; a missing name falls back to the other name, then to the id. */
    fun option(l: UiLocale): LanguageOption {
        val name = l.nativeName.trim().ifEmpty { l.englishName.trim() }.ifEmpty { l.id }
        return LanguageOption(l.id, name, l.englishName.trim().ifEmpty { l.id })
    }

    /** Alphabetical order of rows for the UI locale [displayLocale] (a locale id such as "es-419"). */
    fun comparator(displayLocale: String): Comparator<LanguageOption> {
        val c = Collator.getInstance(Locale.forLanguageTag(displayLocale))
        c.decomposition = Collator.CANONICAL_DECOMPOSITION // "é" and "e" + U+0301 compare equal
        return Comparator<LanguageOption> { a, b -> c.compare(a.name, b.name) }
            .thenComparator { a, b -> c.compare(a.gloss, b.gloss) }
            .thenBy { it.id.lowercase(Locale.ROOT) }
            .thenBy { it.id }
    }

    /** [options] in alphabetical order for [displayLocale], one row per id; the input is not changed. */
    fun sorted(options: Iterable<LanguageOption>, displayLocale: String): List<LanguageOption> =
        options.sortedWith(comparator(displayLocale)).distinctBy { it.id }

    private var cachedFor: Pair<LocaleResolver, String>? = null
    private var cached: List<LanguageOption> = emptyList()

    /**
     * Every supported UI language, in order for the current UI language. Rebuilt only when the UI
     * language (or the manifest) changes, so drawing and scrolling a list do no collation.
     */
    @Synchronized fun current(): List<LanguageOption> {
        val r = L10n.resolver ?: return emptyList()
        val display = L10n.locale?.id ?: r.default
        if (cachedFor?.first !== r || cachedFor?.second != display) {
            cached = sorted(r.locales.map(::option), display)
            cachedFor = r to display
        }
        return cached
    }
}
