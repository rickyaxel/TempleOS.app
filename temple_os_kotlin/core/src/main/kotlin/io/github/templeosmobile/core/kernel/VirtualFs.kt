package io.github.templeosmobile.core.kernel

/** A directory entry of the virtual TempleOS filesystem. */
data class FsEntry(
    val name: String,
    val path: String,
    val isDir: Boolean,
    val size: Long,
    val modified: Long,
    val readOnly: Boolean,
)

/**
 * A filesystem error. [message] is English (HolyC programs and the TempleOS console show it);
 * the UI shows [key] translated with [args] (`ui.localized()`).
 */
class FsError(message: String, val key: String? = null, val args: Map<String, Any?> = emptyMap()) : Exception(message)

/**
 * The logical TempleOS filesystem (C:/...). Implementations map logical paths to
 * an immutable bundled layer plus a writable overlay inside the app sandbox.
 * All paths are absolute logical paths such as "C:/Home/Hello.HC".
 */
interface VirtualFs {
    fun readFile(path: String): ByteArray?
    /** Atomically writes a file. Throws [FsError] (read-only, quota, invalid path). */
    fun writeFile(path: String, data: ByteArray)
    fun exists(path: String): Boolean
    fun isDir(path: String): Boolean
    fun list(dir: String): List<FsEntry>?
    fun stat(path: String): FsEntry?
    fun mkdir(path: String)
    /** Deletes a file or an empty directory (or a tree when [recursive]). */
    fun delete(path: String, recursive: Boolean = false)
    fun move(from: String, to: String)
    fun isReadOnly(path: String): Boolean
}

object Paths {
    /** Normalizes a TempleOS path relative to [cwd] ("C:/Home"). Returns null if invalid. */
    fun normalize(cwd: String, p0: String): String? {
        var p = p0.trim().replace('\\', '/')
        if (p.isEmpty()) return cwd
        p = when {
            p.startsWith("::/") -> "C:" + p.substring(2)
            p == "::" -> "C:/"
            p.length >= 2 && p[1] == ':' -> p.substring(0, 1).uppercase() + p.substring(1)
            p.startsWith("~/") -> "C:/Home" + p.substring(1)
            p == "~" -> "C:/Home"
            p.startsWith("/") -> "C:$p"
            else -> "${cwd.trimEnd('/')}/$p"
        }
        if (!p.startsWith("C:")) return null
        val parts = ArrayList<String>()
        for (seg in p.substring(2).split('/')) {
            when (seg) {
                "", "." -> {}
                ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.size - 1)
                else -> {
                    // RedSea names are bytes: Latin-1 only (also keeps Unicode combining marks out of paths)
                    if (seg.any { it.code < 32 || it.code > 0xFF || it == ':' || it == '*' || it == '?' || it == '"' || it == '<' || it == '>' || it == '|' }) return null
                    if (seg.length > 38) return null // RedSea name limit
                    parts.add(seg)
                }
            }
        }
        return "C:/" + parts.joinToString("/")
    }

    fun parent(p: String): String {
        val i = p.lastIndexOf('/')
        return if (i <= 2) "C:/" else p.substring(0, i)
    }

    fun name(p: String): String = p.substringAfterLast('/')

    /** TempleOS wildcard match ("*.HC", "*", "Hello*"); case-insensitive. */
    fun matches(mask: String, name: String): Boolean {
        val masks = mask.split(';').filter { it.isNotEmpty() }
        if (masks.isEmpty()) return true
        return masks.any { m -> globMatch(m.lowercase(), 0, name.lowercase(), 0) }
    }

    private fun globMatch(p: String, pi: Int, s: String, si: Int): Boolean {
        if (pi == p.length) return si == s.length
        return when (p[pi]) {
            '*' -> (si..s.length).any { globMatch(p, pi + 1, s, it) }
            '?' -> si < s.length && globMatch(p, pi + 1, s, si + 1)
            else -> si < s.length && s[si] == p[pi] && globMatch(p, pi + 1, s, si + 1)
        }
    }
}
