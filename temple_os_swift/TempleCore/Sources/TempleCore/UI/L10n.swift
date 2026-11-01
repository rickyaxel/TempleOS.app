import Foundation

// Port of ui/L10n.kt.

/**
 * UI localization (docs/localization.md). Everything is on the device: the manifest
 * (`l10n/locales.json`, 89 locales over 73 catalogs) and one JSON catalog per language
 * (`l10n/<catalog>.json`) are bundled runtime files. Only English and the current catalog are
 * loaded. Missing keys fall back to English, never to the key itself in a release.
 */
public final class UiLocale {
    public let id: String, catalog: String, parent: String?, language: String, script: String?
    public let englishName: String, nativeName: String, rtl: Bool, familyDefault: Bool
    public let aliases: [String]
    public init(_ id: String, _ catalog: String, _ parent: String?, _ language: String, _ script: String?,
                _ englishName: String, _ nativeName: String, _ rtl: Bool, _ familyDefault: Bool, _ aliases: [String]) {
        self.id = id; self.catalog = catalog; self.parent = parent; self.language = language; self.script = script
        self.englishName = englishName; self.nativeName = nativeName; self.rtl = rtl; self.familyDefault = familyDefault
        self.aliases = aliases
    }
}

/** `m[k]` of a parsed JSON object (Kotlin `m[k] as T?`; Swift's [String: Any?] lookup is doubly optional). */
private func jget<T>(_ m: [String: Any?], _ k: String, _ t: T.Type) -> T? {
    guard let v = m[k], let x = v else { return nil }
    return x as? T
}

/**
 * Picks the UI locale (same contract as tools/l10n/resolver.py and the Kotlin core; shared vectors
 * in shared/test-vectors/l10n/resolver_vectors.json): an explicit in-app choice, else the first
 * supported language in the device's preference order, else en-US. Region and script variants go
 * through aliases, exclusions and language families (longest whole-subtag prefix). The device's
 * own region setting only picks a member of a family (bare "fr" on a Canadian device -> fr-CA);
 * no geography is ever used.
 */
public final class LocaleResolver {
    public let `default`: String
    public let locales: [UiLocale]
    private let inputTag: NSRegularExpression?
    private let countries: [String: [String]]
    private let ids: [String: String]
    private var families: [String: ([String], String?)] = [:]
    private var prefixes: [(String, Int, String?)] = [] // (prefix, kind, target); kind 0 locale, 1 family, 2 exclude

    /**
     * Kotlin casts the manifest's fields (a malformed manifest throws ClassCastException);
     * Swift reads them defensively (a missing or mistyped field is treated as empty).
     */
    public init(_ manifest: [String: Any?]) {
        `default` = jget(manifest, "default_locale", String.self) ?? "en-US"
        locales = (jget(manifest, "locales", [Any?].self) ?? []).compactMap { $0 as? [String: Any?] }.map { m in
            UiLocale(jget(m, "id", String.self) ?? "", jget(m, "catalog", String.self) ?? "", jget(m, "parent", String.self),
                     jget(m, "language", String.self) ?? "", jget(m, "script", String.self),
                     jget(m, "english_name", String.self) ?? "", jget(m, "native_name", String.self) ?? "",
                     jget(m, "direction", String.self) == "rtl", jget(m, "family_default", Bool.self) == true,
                     (jget(m, "aliases", [Any?].self) ?? []).compactMap { $0 as? String })
        }
        inputTag = try? NSRegularExpression(pattern: "\\A(?:" + (jget(manifest, "input_tag", String.self) ?? "") + ")\\z")
        var cs: [String: [String]] = [:]
        for (k, v) in jget(manifest, "countries", [String: Any?].self) ?? [:] {
            cs[k] = ((v as? [Any?]) ?? []).compactMap { $0 as? String }
        }
        countries = cs
        var idm: [String: String] = [:]
        for l in locales { idm[l.id.lowercased()] = l.id }
        ids = idm
        let familyScripts = Set((jget(manifest, "family_scripts", [Any?].self) ?? []).compactMap { $0 as? String })
        // Kotlin LinkedHashMap: keep insertion order
        var groupKeys: [String] = []
        var groups: [String: [UiLocale]] = [:]
        func add(_ key: String, _ l: UiLocale) {
            if groups[key] == nil { groupKeys.append(key); groups[key] = [] }
            groups[key]!.append(l)
        }
        for l in locales {
            let key = (l.language + (l.script != nil ? "-" + l.script! : "")).lowercased()
            add(key, l)
            if familyScripts.contains(l.language) { add(l.language, l) }
        }
        for key in groupKeys {
            let members = groups[key]!
            let defaults = members.filter { $0.familyDefault }.map { $0.id }
            families[key] = (members.map { $0.id }, familyScripts.contains(key) ? nil : defaults.first)
        }
        var items: [(String, Int, String?)] = []
        for k in groupKeys { items.append((k, 1, k)) }
        for l in locales { for tag in [l.id] + l.aliases where families[tag.lowercased()] == nil { items.append((tag.lowercased(), 0, l.id)) } }
        for x in (jget(manifest, "exclusions", [Any?].self) ?? []).compactMap({ $0 as? String }) { items.append((x.lowercased(), 2, nil)) }
        // Kotlin sortedWith(compareBy({ -length }, { it })) is stable: the index breaks ties
        prefixes = items.enumerated().sorted { a, b in
            let la = a.element.0.utf16.count, lb = b.element.0.utf16.count
            if la != lb { return la > lb }
            if a.element.0 != b.element.0 { return a.element.0.utf16.lexicographicallyPrecedes(b.element.0.utf16) }
            return a.offset < b.offset
        }.map { $0.element }
    }

    public func byId(_ id: String) -> UiLocale? { locales.first { $0.id == id } }

    private static func isAsciiLetter(_ c: Character) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }

    private func tagRegion(_ tag: String) -> String? {
        for part in tag.split(separator: "-", omittingEmptySubsequences: false).dropFirst() {
            if part.count == 2 && part.allSatisfy({ $0.isLetter }) { return part.uppercased() }
            if part.count == 3 && part.allSatisfy({ $0.isNumber }) { return nil }
        }
        return nil
    }

    /** Normalizes one tag (device, persisted or legacy value) to a supported locale id, or nil. */
    public func match(_ value: String?, _ deviceRegion: String? = nil) -> String? {
        guard let value = value else { return nil }
        let tag = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n")).replacingOccurrences(of: "_", with: "-").lowercased()
        guard let re = inputTag, re.firstMatch(in: tag, range: NSRange(location: 0, length: tag.utf16.count)) != nil else { return nil }
        if let id = ids[tag] { return id }
        var region: String? = nil
        if let d = deviceRegion, d.count == 2, d.allSatisfy({ LocaleResolver.isAsciiLetter($0) }) { region = d.uppercased() }
        for (prefix, kind, target) in prefixes {
            if tag == prefix || tag.hasPrefix(prefix + "-") {
                switch kind {
                case 0: return target
                case 2: return nil
                default: break
                }
                let (members, def) = families[target!]!
                for hint in [tagRegion(tag), region] {
                    guard let hint = hint else { continue }
                    for c in countries[hint] ?? [] where members.contains(c) { return c }
                }
                return def
            }
        }
        return nil
    }

    /** (locale id, source): "manual", "preferred" or "default". */
    public func resolve(_ manual: String?, _ preferred: [String], _ deviceRegion: String?) -> (String, String) {
        if let m = match(manual, deviceRegion) { return (m, "manual") }
        for p in preferred { if let m = match(p, deviceRegion) { return (m, "preferred") } }
        return (`default`, "default")
    }
}

/**
 * Kotlin `object L10n` with @Volatile fields and @Synchronized init/use: static vars, the
 * synchronized methods hold [lock] (readers see whole-map swaps, as on the JVM).
 */
public enum L10n {
    /** View-owned values refresh once per language change; callbacks, input and technical data stay intact. */
    public final class Presentation<Value> {
        private let render: () -> Value
        private var generation: Int
        private var cached: Value
        public init(_ render: @escaping () -> Value) {
            self.render = render; generation = L10n.version; cached = render()
        }
        public var value: Value {
            if generation != L10n.version { cached = render(); generation = L10n.version }
            return cached
        }
    }

    private static let lock = NSLock()
    private static var source: ((String) -> [UInt8]?)? = nil
    private static var english: [String: String] = [:]
    private static var strings: [String: String] = [:]
    public private(set) static var resolver: LocaleResolver? = nil
    public private(set) static var locale: UiLocale? = nil
    /** Increases on every language change (views redraw, cached labels refresh). */
    public private(set) static var version = 0

    public static var rtl: Bool { locale?.rtl == true }

    private static func catalog(_ name: String) -> [String: String] {
        guard let b = source?("l10n/\(name).json") else { return [:] }
        guard let m = (try? Json.parse(String(decoding: b, as: UTF8.self))) as? [String: Any?] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in m where !k.hasPrefix("$") {
            if let s = v as? String, !s.isEmpty { out[k] = s }
        }
        return out
    }

    /** Loads the manifest and English from bundled runtime files (idempotent). */
    public static func initialize(_ runtimeFile: @escaping (String) -> [UInt8]?) {
        lock.lock(); defer { lock.unlock() }
        if source != nil && resolver != nil { return }
        source = runtimeFile
        let m = runtimeFile("l10n/locales.json")
        resolver = m.flatMap { (try? Json.parse(String(decoding: $0, as: UTF8.self))) as? [String: Any?] }.map { LocaleResolver($0) }
        english = catalog("en")
        if locale == nil { locale = resolver?.byId("en-US"); strings = english }
    }

    /** Switches the UI language; only the chosen catalog (plus English) stays in memory. */
    public static func use(_ localeId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let r = resolver else { return }
        guard let l = r.byId(localeId) ?? r.byId(r.default) else { return }
        if locale?.id == l.id && !strings.isEmpty { return }
        strings = l.catalog == "en" ? english : catalog(l.catalog)
        locale = l
        version += 1
    }

    public static func has(_ key: String) -> Bool { strings[key] != nil || english[key] != nil }

    private static let placeholder = try! NSRegularExpression(pattern: "\\{[a-z_]+\\}")

    static func fill(_ template: String, _ args: [(String, Any?)]) -> String {
        var result = "", cursor = template.startIndex
        for match in placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template) else { continue }
            result += template[cursor..<range.lowerBound]
            let name = String(template[range].dropFirst().dropLast())
            // Inserted filenames, errors and program text are literal data, never another template.
            if name == "app" { result += Brand.appName }
            else if let argument = args.first(where: { $0.0 == name }) { result += argument.1.map { "\($0)" } ?? "null" }
            else { result += template[range] }
            cursor = range.upperBound
        }
        result += template[cursor...]
        return result
    }

    /**
     * The text for [key] in the current language, English if missing; `{name}` placeholders are
     * filled from [args], and `{app}` with [Brand.appName] (the name is never in a catalog).
     */
    public static func tr(_ key: String, _ args: (String, Any?)...) -> String { trArgs(key, args) }

    public static func trArgs(_ key: String, _ args: [(String, Any?)]) -> String {
        fill(strings[key] ?? english[key] ?? key, args)
    }

    /**
     * For text written into TempleOS console windows, which hold 8-bit CP437 cells: the
     * translation when the TempleOS font can show all of it, otherwise English.
     */
    public static func tr8(_ key: String, _ args: (String, Any?)...) -> String {
        let t = trArgs(key, args)
        if Cp437.representable(t) { return Cp437.encode(t) }
        return fill(english[key] ?? key, args)
    }
}

extension FsError {
    /** A filesystem error in the UI language. */
    public func localized() -> String {
        if let k = key, L10n.has(k) {
            return L10n.trArgs(k, args.map { entry in
                if ["path", "name"].contains(entry.key), let bytes = entry.value as? String {
                    return (entry.key, InputCharacterPolicy.display(bytes))
                }
                return (entry.key, entry.value)
            })
        }
        return message
    }
}

/**
 * Swift-only helper for Kotlin's `catch (e: FsError) { e.localized() }` where Swift catches any
 * Error: an FsError in the UI language, any other error as before ([errorMessage]).
 */
public func localizedError(_ e: Error) -> String { (e as? FsError)?.localized() ?? errorMessage(e) }

/** Shorthand for [L10n.tr]. */
public func tr(_ key: String, _ args: (String, Any?)...) -> String { L10n.trArgs(key, args) }

/** The TempleOS font's character set (IBM code page 437) for Unicode text. Kotlin Char = one Unicode scalar here. */
public enum Cp437 {
    private static let HIGH: [Unicode.Scalar] = Array("ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}".unicodeScalars)
    private static let map: [Unicode.Scalar: Int] = {
        var m: [Unicode.Scalar: Int] = [:]
        for (i, c) in HIGH.enumerated() { m[c] = 0x80 + i }
        return m
    }()

    /** CP437 code of [c], or -1 if the TempleOS font has no such glyph. */
    public static func code(_ c: Unicode.Scalar) -> Int {
        // 0x01-0x1F: the TempleOS font's graphic glyphs (arrows, borders), used by the UI on purpose
        if c.value >= 0x01 && c.value <= 0x7E { return Int(c.value) }
        return map[c] ?? -1
    }

    public static func representable(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { code($0) >= 0 } }

    /** A CP437 byte string (one char per byte, as HolyC programs produce) as Unicode. */
    public static func decode(_ bytes: String) -> String {
        var sb = String.UnicodeScalarView()
        for c in bytes.unicodeScalars { let b = Int(c.value & 0xFF); sb.append(b >= 0x80 ? HIGH[b - 0x80] : c) }
        return String(sb)
    }

    /** [s] as CP437 codes in a String (one char per code), for the TempleOS font and console. */
    public static func encode(_ s: String) -> String {
        var sb = String.UnicodeScalarView()
        for c in s.unicodeScalars { let k = code(c); sb.append(k >= 0 ? Unicode.Scalar(UInt8(k)) : "?") }
        return String(sb)
    }
}
