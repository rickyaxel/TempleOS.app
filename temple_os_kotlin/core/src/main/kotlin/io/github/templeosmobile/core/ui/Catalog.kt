package io.github.templeosmobile.core.ui

/** Build-time source indexes. References open a file, document, or directory. */
class ProgramGroup(val id: String, val title: String, val parent: String, val source: String,
                   val directory: String, val document: String, val programIds: List<String>, val menuIds: List<String>, val references: List<Reference>) {
    class Reference(val label: String, val path: String, val directory: Boolean, val available:Boolean = true)
    val localizedTitle get() = "catalog.group.$id".let { if (L10n.has(it)) tr(it) else title }
}

/** One registered program (from the bundled catalog.json). */
class ProgramInfo(
    val id: String,
    val title: String,
    val category: String,
    val path: String,
    val kind: String,
    val author: String,
    val license: String,
    val source: String,
    val controls: List<String>,
    val capabilities: List<String>,
    val orientation: String,
    val description: String,
    /** "runs", "partial" or "unsupported" (shared/program-manifests/compatibility.json). */
    val status: String = "runs",
    val note: String = "",
) {
    /** Why a program is partial or unsupported, in the UI language (catalog.<id>.note). */
    val noteLocalizationKey: String? get() = when {
        note.isEmpty() -> null
        L10n.has("catalog.$id.note") -> "catalog.$id.note"
        note.startsWith("compile error: ") -> "catalog.note.compile_error"
        note.endsWith("execution has not been verified on mobile.") -> "catalog.note.unverified"
        note.startsWith("Original source and genuine native execution verified") -> "catalog.note.verified"
        else -> null
    }
    val localizedNote get() = noteLocalizationKey?.let { key ->
        // Compiler diagnostics are technical content; the app-owned frame is localized.
        if (key == "catalog.note.compile_error") tr(key, "detail" to note.removePrefix("compile error: ")) else tr(key)
    } ?: note
    /** The example's description in the UI language (catalog.<id>.description). */
    val localizedDescription get() = if (L10n.has("catalog.$id.description")) tr("catalog.$id.description") else description
    val unsupported get() = status == "unsupported"
    val usesMouse get() = "mouse" in controls
    val usesArrows get() = "arrows" in controls
    /** Needs a held CTRL key, a held SHIFT key, or the mouse wheel (shared/program-manifests: source-derived). */
    val usesCtrl get() = "ctrl" in controls
    val usesShift get() = "shift" in controls
    val usesWheel get() = "wheel" in controls
    /** Instruments and keyboard-driven programs open with the TempleOS keyboard. */
    val prefersFullKeyboard get() = "full_keyboard" in controls
    val usesGraphics get() = "graphics" in capabilities
}

/**
 * The program registry. Identity (id) is separate from how a program is
 * loaded (kind + path), so other approved sources could be added later
 * without changing the launcher.
 */
class Catalog(val programs: List<ProgramInfo>, val groups: List<ProgramGroup> = emptyList()) {
    fun group(id: String) = groups.firstOrNull { it.id == id }
    fun children(id: String) = groups.filter { it.parent == id }
    fun byId(id: String) = programs.firstOrNull { it.id == id }
    fun byPath(path: String) = programs.firstOrNull { it.path.equals(path, ignoreCase = true) }
    fun inCategory(c: String) = programs.filter { it.category == c }

    /** Menu entries; unsupported programs are left out (they stay reachable in Files), partial ones are marked. */
    fun menuItems(shell: Shell, category: String): List<MenuItem> =
        inCategory(category).filter { !it.unsupported }.sortedBy { it.title.lowercase() }
            .map { p -> MenuItem( { if (p.status == "partial") tr("catalog.partial_suffix", "title" to p.title) else p.title }) { Launch.program(shell, p.path, p) } }

    companion object {
        fun parse(text: String): Catalog {
            val root = Json.parse(text) as Map<*, *>
            val list = (root["programs"] as List<*>).map { o ->
                val m = o as Map<*, *>
                fun s(k: String) = m[k] as? String ?: ""
                fun l(k: String) = (m[k] as? List<*>)?.map { it.toString() } ?: emptyList()
                ProgramInfo(s("id"), s("title"), s("category"), s("path"), s("kind"), s("author"), s("license"),
                    s("source"), l("controls"), l("capabilities"), s("orientation"), s("description"),
                    s("status").ifEmpty { "runs" }, s("note"))
            }
            require(list.all { it.id.isNotBlank() && it.path.startsWith("C:/") }) { "invalid program identity/path" }
            require(list.map { it.id }.distinct().size == list.size) { "duplicate program ID" }
            require(list.map { it.path.lowercase() }.distinct().size == list.size) { "duplicate program path" }
            val groups = (root["groups"] as? List<*>)?.map { o ->
                val m = o as Map<*, *>
                fun s(k: String) = m[k] as? String ?: ""
                val refs = (m["references"] as? List<*>)?.map { r ->
                    val ref = r as Map<*, *>
                    ProgramGroup.Reference(ref["label"] as? String ?: "", ref["path"] as? String ?: "", ref["directory"] == true,ref["available"]!=false)
                } ?: emptyList()
                ProgramGroup(s("id"), s("title"), s("parent"), s("source"), s("directory"), s("document"),
                    (m["programIds"] as? List<*>)?.map { it as String } ?: emptyList(),
                    (m["menuIds"] as? List<*>)?.map { it as String } ?: emptyList(), refs)
            } ?: emptyList()
            require(groups.map { it.id }.distinct().size == groups.size) { "duplicate group ID" }
            val ids = list.map { it.id }.toSet(); val gids = groups.map { it.id }.toSet()
            for (g in groups) {
                require(g.id.isNotEmpty() && (g.parent.isEmpty() || g.parent in gids) && g.programIds.all { it in ids } && g.programIds.distinct().size == g.programIds.size) { "invalid group route" }
                val seen = HashSet<String>(); var cur: ProgramGroup? = g
                while (cur != null) {
                    require(seen.add(cur.id)) { "group cycle" }
                    val parent = cur.parent; cur = groups.firstOrNull { it.id == parent }
                }
            }
            return Catalog(list, groups)
        }

        fun load(shell: Shell): Catalog {
            val bytes = shell.env.runtimeFile("catalog.json") ?: return Catalog(emptyList())
            return try { parse(String(bytes, Charsets.UTF_8)) } catch (e: Exception) { Catalog(emptyList()) } catch (e: StackOverflowError) { Catalog(emptyList()) }
        }
    }
}
