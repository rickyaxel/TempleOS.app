import Foundation

// Port of ui/LanguageList.kt.

/**
 * One choice in a list of languages: the canonical locale id (what is selected and saved) and the
 * text the row shows. `name` is the language's own name and `gloss` its English name, so the row
 * reads "Deutsch - German" in every UI language.
 */
public struct LanguageOption: Equatable, CustomStringConvertible {
    public let id: String, name: String, gloss: String
    public init(_ id: String, _ name: String, _ gloss: String) { self.id = id; self.name = name; self.gloss = gloss }
    public var label: String { "\(name) - \(gloss)" }
    public var description: String { label }
}

/**
 * The order of every list of languages the user picks from (docs/localization.md, "Language
 * lists"; same contract as the Kotlin core). Rows are in alphabetical order of their visible text,
 * collated for the current UI language: first the language's own name, then its English name,
 * then, for rows that still compare equal, the locale id. The manifest's order (and its
 * `sort_order` field) never reaches the screen, so a language added to `locales.json` takes its
 * place in the list by its names alone.
 *
 * Collation is Foundation's locale-aware `compare(_:options:range:locale:)`: the UI language's own
 * script comes first (Cyrillic before Latin for Russian, for example), then the CLDR script order.
 */
public enum LanguageList {
    /** The row for a manifest locale; a missing name falls back to the other name, then to the id. */
    public static func option(_ l: UiLocale) -> LanguageOption {
        let english = l.englishName.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = l.nativeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = english }
        if name.isEmpty { name = l.id }
        return LanguageOption(l.id, name, english.isEmpty ? l.id : english)
    }

    /** Alphabetical order of rows for the UI locale `displayLocale` (a locale id such as "es-419"). */
    public static func comparator(_ displayLocale: String) -> (LanguageOption, LanguageOption) -> Bool {
        let loc = Locale(identifier: displayLocale)
        return { a, b in
            // canonically equivalent strings ("é" and "e" + U+0301) compare equal
            let n = a.name.compare(b.name, options: [], range: nil, locale: loc)
            if n != .orderedSame { return n == .orderedAscending }
            let g = a.gloss.compare(b.gloss, options: [], range: nil, locale: loc)
            if g != .orderedSame { return g == .orderedAscending }
            let ia = a.id.lowercased(), ib = b.id.lowercased()
            return ia != ib ? ia < ib : a.id < b.id
        }
    }

    /** `options` in alphabetical order for `displayLocale`, one row per id; the input is not changed. */
    public static func sorted<S: Sequence>(_ options: S, _ displayLocale: String) -> [LanguageOption] where S.Element == LanguageOption {
        var seen = Set<String>()
        return options.sorted(by: comparator(displayLocale)).filter { seen.insert($0.id).inserted }
    }

    private static let lock = NSLock()
    private static var cachedFor: (ObjectIdentifier, String)? = nil
    private static var cached: [LanguageOption] = []

    /**
     * Every supported UI language, in order for the current UI language. Rebuilt only when the UI
     * language (or the manifest) changes, so drawing and scrolling a list do no collation.
     */
    public static func current() -> [LanguageOption] {
        guard let r = L10n.resolver else { return [] }
        let display = L10n.locale?.id ?? r.default
        lock.lock(); defer { lock.unlock() }
        if cachedFor?.0 != ObjectIdentifier(r) || cachedFor?.1 != display {
            cached = sorted(r.locales.map(option), display)
            cachedFor = (ObjectIdentifier(r), display)
        }
        return cached
    }
}
