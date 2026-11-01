import Foundation

/** Build-time source indexes. A reference opens a file, document, or directory. */
public struct ProgramGroup {
    public struct Reference {
        public let label: String, path: String
        public let directory: Bool
        public let available: Bool
    }
    public let id: String, title: String, parent: String, source: String, directory: String, document: String
    public let programIds: [String]
    public let menuIds: [String]
    public let references: [Reference]
    public var localizedTitle: String {
        let key = "catalog.group.\(id)"
        return L10n.has(key) ? tr(key) : title
    }
}

// Port of ui/Catalog.kt.

/** One registered program (from the bundled catalog.json). */
public final class ProgramInfo {
    public let id: String
    public let title: String
    public let category: String
    public let path: String
    public let kind: String
    public let author: String
    public let license: String
    public let source: String
    public let controls: [String]
    public let capabilities: [String]
    public let orientation: String
    public let description: String
    /** "runs", "partial" or "unsupported" (shared/program-manifests/compatibility.json). */
    public let status: String
    public let note: String

    public init(_ id: String, _ title: String, _ category: String, _ path: String, _ kind: String, _ author: String,
                _ license: String, _ source: String, _ controls: [String], _ capabilities: [String],
                _ orientation: String, _ description: String, _ status: String = "runs", _ note: String = "") {
        self.id = id; self.title = title; self.category = category; self.path = path; self.kind = kind
        self.author = author; self.license = license; self.source = source; self.controls = controls
        self.capabilities = capabilities; self.orientation = orientation; self.description = description
        self.status = status; self.note = note
    }

    /** Why a program is partial or unsupported, in the UI language (catalog.<id>.note). */
    public var noteLocalizationKey: String? {
        if note.isEmpty { return nil }
        let key = "catalog.\(id).note"
        if L10n.has(key) { return key }
        if note.hasPrefix("compile error: ") { return "catalog.note.compile_error" }
        if note.hasSuffix("execution has not been verified on mobile.") { return "catalog.note.unverified" }
        if note.hasPrefix("Original source and genuine native execution verified") { return "catalog.note.verified" }
        return nil
    }
    public var localizedNote: String {
        guard let key = noteLocalizationKey else { return note }
        // Compiler diagnostics are technical content; the app-owned frame is localized.
        return key == "catalog.note.compile_error" ? tr(key, ("detail", String(note.dropFirst("compile error: ".count)))) : tr(key)
    }
    /** The example's description in the UI language (catalog.<id>.description). */
    public var localizedDescription: String { L10n.has("catalog.\(id).description") ? tr("catalog.\(id).description") : description }
    public var unsupported: Bool { status == "unsupported" }

    public var usesMouse: Bool { controls.contains("mouse") }
    public var usesArrows: Bool { controls.contains("arrows") }
    /** Needs a held CTRL key, a held SHIFT key, or the mouse wheel (shared/program-manifests: source-derived). */
    public var usesCtrl: Bool { controls.contains("ctrl") }
    public var usesShift: Bool { controls.contains("shift") }
    public var usesWheel: Bool { controls.contains("wheel") }
    /** Instruments and keyboard-driven programs open with the TempleOS keyboard. */
    public var prefersFullKeyboard: Bool { controls.contains("full_keyboard") }
    public var usesGraphics: Bool { capabilities.contains("graphics") }
}

/**
 * The program registry. Identity (id) is separate from how a program is
 * loaded (kind + path), so other approved sources could be added later
 * without changing the launcher.
 */
public final class Catalog {
    public let programs: [ProgramInfo]
    public let groups: [ProgramGroup]

    public init(_ programs: [ProgramInfo], _ groups: [ProgramGroup] = []) { self.programs = programs; self.groups = groups }
    public func group(_ id: String) -> ProgramGroup? { groups.first { $0.id == id } }
    public func children(_ id: String) -> [ProgramGroup] { groups.filter { $0.parent == id } }

    public func byId(_ id: String) -> ProgramInfo? { programs.first { $0.id == id } }
    public func byPath(_ path: String) -> ProgramInfo? { programs.first { $0.path.equalsIgnoreCase(path) } }
    public func inCategory(_ c: String) -> [ProgramInfo] { programs.filter { $0.category == c } }

    /** Menu entries; unsupported programs are left out (they stay reachable in Files), partial ones are marked. */
    public func menuItems(_ shell: Shell, _ category: String) -> [MenuItem] {
        inCategory(category).filter { !$0.unsupported }
            .enumerated()
            .sorted { a, b in
                let ka = a.element.title.lowercased(), kb = b.element.title.lowercased()
                return ka != kb ? ka < kb : a.offset < b.offset // stable, like Kotlin sortedBy
            }
            .map { pair in
                let p = pair.element
                return MenuItem(p.status == "partial" ? tr("catalog.partial_suffix", ("title", p.title)) : p.title) { Launch.program(shell, p.path, p) }
            }
    }

    public static func parse(_ text: String) throws -> Catalog {
        guard let root = try Json.parse(text) as? [String: Any?] else { throw JsonError("catalog root is not an object") }
        guard let progs = root["programs"] as? [Any?] else { throw JsonError("catalog has no program list") }
        var list: [ProgramInfo] = []
        for o in progs {
            guard let m = o as? [String: Any?] else { throw JsonError("catalog entry is not an object") }
            func s(_ k: String) -> String { (m[k] ?? nil) as? String ?? "" }
            func l(_ k: String) -> [String] {
                guard let a = (m[k] ?? nil) as? [Any?] else { return [] }
                return a.map { v -> String in
                    guard let v = v else { return "null" }
                    if let str = v as? String { return str }
                    return "\(v)"
                }
            }
            list.append(ProgramInfo(s("id"), s("title"), s("category"), s("path"), s("kind"), s("author"), s("license"),
                                    s("source"), l("controls"), l("capabilities"), s("orientation"), s("description"),
                                    s("status").isEmpty ? "runs" : s("status"), s("note")))
        }
        if list.contains(where: { $0.id.isEmpty || !$0.path.hasPrefix("C:/") }) { throw JsonError("invalid program identity/path") }
        if Set(list.map { $0.id }).count != list.count { throw JsonError("duplicate program ID") }
        if Set(list.map { $0.path.lowercased() }).count != list.count { throw JsonError("duplicate program path") }
        let groupList = ((root["groups"] ?? nil) as? [[String: Any?]] ?? []).map { m -> ProgramGroup in
            func s(_ k: String) -> String { (m[k] ?? nil) as? String ?? "" }
            let refs = ((m["references"] ?? nil) as? [[String: Any?]] ?? []).map { r in
                ProgramGroup.Reference(label: (r["label"] ?? nil) as? String ?? "", path: (r["path"] ?? nil) as? String ?? "", directory: (r["directory"] ?? nil) as? Bool ?? false,available:(r["available"] ?? nil) as? Bool ?? true)
            }
            return ProgramGroup(id: s("id"), title: s("title"), parent: s("parent"), source: s("source"), directory: s("directory"), document: s("document"), programIds: (m["programIds"] ?? nil) as? [String] ?? [], menuIds: (m["menuIds"] ?? nil) as? [String] ?? [], references: refs)
        }
        if Set(groupList.map { $0.id }).count != groupList.count { throw JsonError("duplicate group ID") }
        let ids = Set(list.map { $0.id }), gids = Set(groupList.map { $0.id })
        for g in groupList {
            if g.id.isEmpty || (!g.parent.isEmpty && !gids.contains(g.parent)) || !g.programIds.allSatisfy({ ids.contains($0) }) || Set(g.programIds).count != g.programIds.count { throw JsonError("invalid group route") }
            var seen = Set<String>(), cur: ProgramGroup? = g
            while let c = cur {
                if !seen.insert(c.id).inserted { throw JsonError("group cycle") }
                cur = groupList.first { $0.id == c.parent }
            }
        }
        return Catalog(list, groupList)
    }

    public static func load(_ shell: Shell) -> Catalog {
        guard let bytes = shell.env.runtimeFile("catalog.json") else { return Catalog([]) }
        do { return try parse(String(decoding: bytes, as: UTF8.self)) } catch { return Catalog([]) }
    }
}
