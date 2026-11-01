package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.Brand
import java.io.File

/** Read-only bundled C:/ drive (app assets). Paths are relative, e.g. "Demo/Games/Maze.HC". */
interface BundleSource {
    /** Contents of bundled-fs.index. */
    fun index(): String
    fun open(rel: String): ByteArray?
}

/** Bundle backed by a host directory plus its index file (tests, tools). */
class DirBundle(private val root: File, private val indexFile: File) : BundleSource {
    override fun index() = indexFile.readText()
    override fun open(rel: String): ByteArray? = File(root, rel).let { if (it.isFile) it.readBytes() else null }
}

/**
 * The TempleOS Mobile virtual filesystem: an immutable bundled layer with a
 * writable overlay stored under [overlayRoot] (inside the app sandbox).
 *
 * - Logical paths are absolute "C:/..." paths; [Paths.normalize] rejects
 *   anything that could escape (no drive other than C:, no ".." past root).
 * - Writes go to the overlay (copy-on-write over bundled files) atomically:
 *   data is written to a temp file, synced, then renamed.
 * - Deleting a bundled file records a whiteout so it disappears from listings.
 * - The overlay is limited to [quotaBytes].
 *
 * Thread-safe (all public methods synchronized).
 */
class LayeredFs(
    private val bundle: BundleSource,
    private val overlayRoot: File,
    private val quotaBytes: Long = 64L shl 20,
) : VirtualFs {
    /** [modified]: the ISO's wall-clock date in ms (V-04), 0 if unknown. [origin]: the index's provenance field. */
    private class BEntry(val path: String, val isDir: Boolean, val size: Long, val modified: Long = 0, val origin: String = "")

    private val bundled = HashMap<String, BEntry>()          // lower-case logical path -> entry
    private val bundledChildren = HashMap<String, MutableList<BEntry>>() // lower-case dir -> children
    private val filesDir = File(overlayRoot, "files")
    private val whiteoutFile = File(overlayRoot, "deleted.txt")
    private val whiteouts = HashSet<String>()                // lower-case logical paths
    private var used = 0L

    init {
        filesDir.mkdirs()
        bundled["c:/"] = BEntry("C:/", true, 0)
        for (line in bundle.index().split('\n')) {
            val f = line.split('\t')
            if (f.size < 3) continue
            val path = "C:/" + f[1]
            val e = BEntry(path, f[0] == "D", f[2].toLongOrNull() ?: 0, f.getOrNull(5)?.toLongOrNull() ?: 0, f.getOrNull(4)?.takeIf { it != "-" } ?: "")
            bundled[path.lowercase()] = e
            bundledChildren.getOrPut(Paths.parent(path).lowercase()) { ArrayList() }.add(e)
        }
        if (whiteoutFile.exists()) whiteoutFile.readLines().filter { it.isNotBlank() }.forEach { whiteouts.add(it) }
        used = filesDir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    // ------------------------------------------------------------ mapping

    private fun check(path: String): String =
        Paths.normalize("C:/", path) ?: throw FsError("Invalid path: $path", "fs.error.invalid_path", mapOf("path" to path))

    /** Host file for a logical path; never outside [filesDir]. */
    private fun hostFile(logical: String): File {
        val rel = logical.removePrefix("C:/")
        val f = if (rel.isEmpty()) filesDir else File(filesDir, rel)
        val canon = try { f.canonicalFile } catch (e: java.io.IOException) { throw FsError("Invalid path: $logical", "fs.error.invalid_path", mapOf("path" to logical)) }
        if (!canon.path.startsWith(filesDir.canonicalPath)) throw FsError("Invalid path: $logical", "fs.error.invalid_path", mapOf("path" to logical))
        return f
    }

    /** Overlay file matching [logical] case-insensitively, or null. */
    private fun overlayFind(logical: String): File? {
        val direct = hostFile(logical)
        if (direct.exists()) return direct
        val parts = logical.removePrefix("C:/").split('/').filter { it.isNotEmpty() }
        var cur = filesDir
        for (p in parts) {
            val next = cur.listFiles()?.firstOrNull { it.name.equals(p, ignoreCase = true) } ?: return null
            cur = next
        }
        return cur
    }

    private fun isWhiteout(logical: String): Boolean {
        var p = logical.lowercase()
        while (true) {
            if (p in whiteouts) return true
            if (p == "c:/" || !p.contains('/')) return false
            val parent = Paths.parent(p).lowercase()
            if (parent == p) return false
            p = parent
        }
    }

    private fun bundledEntry(logical: String): BEntry? =
        if (isWhiteout(logical)) null else bundled[logical.lowercase()] ?: logical.takeIf {it.endsWith(".Z",true)}?.dropLast(2)?.let {if(isWhiteout(it)) null else bundled[it.lowercase()]}

    // ------------------------------------------------------------ queries

    @Synchronized override fun readFile(path: String): ByteArray? {
        val p = Paths.normalize("C:/", path) ?: return null
        (overlayFind(p) ?: p.takeIf {it.endsWith(".Z",true)}?.dropLast(2)?.let {overlayFind(it)})?.let {if(it.isFile) return it.readBytes() else return null}
        val e = bundledEntry(p) ?: return null
        if (e.isDir) return null
        return bundle.open(e.path.removePrefix("C:/"))
    }

    @Synchronized override fun exists(path: String): Boolean {
        val p = Paths.normalize("C:/", path) ?: return false
        return overlayFind(p) != null || p.endsWith(".Z",true) && overlayFind(p.dropLast(2))!=null || bundledEntry(p) != null
    }

    @Synchronized override fun isDir(path: String): Boolean {
        val p = Paths.normalize("C:/", path) ?: return false
        if (p == "C:/") return true
        overlayFind(p)?.let { return it.isDirectory }
        return bundledEntry(p)?.isDir ?: false
    }

    @Synchronized override fun stat(path: String): FsEntry? {
        val p = Paths.normalize("C:/", path) ?: return null
        overlayFind(p)?.let { return FsEntry(it.name, p, it.isDirectory, if (it.isFile) it.length() else 0, it.lastModified(), false) }
        val e = bundledEntry(p) ?: return null
        return FsEntry(Paths.name(e.path).ifEmpty { "C:" }, e.path, e.isDir, e.size, e.modified, true)
    }

    @Synchronized override fun list(dir: String): List<FsEntry>? {
        val p = Paths.normalize("C:/", dir) ?: return null
        if (!isDir(p)) return null
        val res = LinkedHashMap<String, FsEntry>()
        if (!isWhiteout(p) || p == "C:/") {
            for (e in bundledChildren[p.lowercase()].orEmpty()) {
                if (isWhiteout(e.path)) continue
                res[Paths.name(e.path).lowercase()] = FsEntry(Paths.name(e.path), e.path, e.isDir, e.size, e.modified, true)
            }
        }
        overlayFind(p)?.listFiles()?.forEach { f ->
            if (f.name.startsWith(".tmp-")) return@forEach
            val lp = if (p == "C:/") "C:/${f.name}" else "$p/${f.name}"
            res[f.name.lowercase()] = FsEntry(f.name, lp, f.isDirectory, if (f.isFile) f.length() else 0, f.lastModified(), false)
        }
        return res.values.toList()
    }

    @Synchronized override fun isReadOnly(path: String): Boolean = false

    // ------------------------------------------------------------ mutations

    private fun ensureParentDir(logical: String) {
        val parent = Paths.parent(logical)
        if (parent != "C:/" && !isDir(parent)) throw FsError("Directory not found: $parent", "fs.error.dir_not_found", mapOf("path" to parent))
        val hp = hostFile(parent)
        hp.mkdirs()
    }

    @Synchronized override fun writeFile(path: String, data: ByteArray) {
        val p = check(path)
        if (p == "C:/") throw FsError("Invalid path: $path", "fs.error.invalid_path", mapOf("path" to path))
        if (isDir(p)) throw FsError("Is a directory: $p", "fs.error.is_directory", mapOf("path" to p))
        ensureParentDir(p)
        val target = overlayFind(p) ?: hostFile(p)
        val old = if (target.exists()) target.length() else 0L
        if (used - old + data.size > quotaBytes)
            throw FsError("Storage full: ${Brand.APP_NAME} keeps at most ${quotaBytes shr 20} MiB of your files", "fs.error.storage_full", mapOf("mib" to (quotaBytes shr 20)))
        val tmp = File(target.parentFile, ".tmp-${target.name}-${System.nanoTime()}")
        try {
            java.io.FileOutputStream(tmp).use { out ->
                out.write(data)
                out.fd.sync()
            }
            if (!tmp.renameTo(target)) {
                target.delete()
                if (!tmp.renameTo(target)) throw FsError("Could not save $p", "fs.error.could_not_save", mapOf("path" to p))
            }
        } catch (e: java.io.IOException) {
            tmp.delete()
            throw FsError("Could not save $p: ${e.message}", "fs.error.could_not_save", mapOf("path" to p))
        }
        used += data.size - old
        unWhiteout(p)
    }

    private fun unWhiteout(p: String) {
        var q = p.lowercase()
        var changed = false
        while (true) {
            if (whiteouts.remove(q)) changed = true
            if (q == "c:/") break
            q = Paths.parent(q).lowercase()
        }
        if (changed) saveWhiteouts { FsError("Could not save $p", "fs.error.could_not_save", mapOf("path" to p)) }
    }

    /**
     * Persists the deleted-bundled-files list atomically. A failure (storage full, I/O error) is
     * reported as [failure]'s [FsError], which the Files and Editor windows show; a plain IOException
     * escaped to the UI thread and ended the app.
     */
    private fun saveWhiteouts(failure: () -> FsError) {
        val tmp = File(overlayRoot, "deleted.txt.tmp")
        val ok = try { tmp.writeText(whiteouts.joinToString("\n")); tmp.renameTo(whiteoutFile) } catch (_: java.io.IOException) { false }
        if (!ok) { tmp.delete(); throw failure() }
    }

    @Synchronized override fun mkdir(path: String) {
        val p = check(path)
        if (exists(p)) { if (isDir(p)) return else throw FsError("A file named ${Paths.name(p)} exists", "fs.error.file_exists", mapOf("name" to Paths.name(p))) }
        ensureParentDir(p)
        hostFile(p).mkdirs()
        unWhiteout(p)
    }

    @Synchronized override fun delete(path: String, recursive: Boolean) {
        val p = check(path)
        if (p == "C:/") throw FsError("Cannot delete the drive", "fs.error.delete_drive")
        if (!exists(p)) throw FsError("File not found: $p", "fs.error.not_found", mapOf("path" to p))
        if (isDir(p) && !recursive && list(p)!!.isNotEmpty()) throw FsError("Directory not empty: $p", "fs.error.dir_not_empty", mapOf("path" to p))
        overlayFind(p)?.let { f ->
            val freed = f.walkTopDown().filter { it.isFile }.sumOf { it.length() }
            if (!f.deleteRecursively()) throw FsError("Could not delete $p", "fs.error.could_not_delete", mapOf("path" to p))
            used -= freed
        }
        if (bundled.containsKey(p.lowercase()) && whiteouts.add(p.lowercase())) {
            // not persisted: the original would come back on the next launch, so the delete did not happen
            saveWhiteouts { whiteouts.remove(p.lowercase()); FsError("Could not delete $p", "fs.error.could_not_delete", mapOf("path" to p)) }
        }
    }

    @Synchronized override fun move(from: String, to: String) {
        val a = check(from); val b = check(to)
        if (!exists(a)) throw FsError("File not found: $a", "fs.error.not_found", mapOf("path" to a))
        if (exists(b)) throw FsError("Already exists: $b", "fs.error.already_exists", mapOf("path" to b))
        if (b.lowercase().startsWith(a.lowercase() + "/")) throw FsError("Cannot move a directory into itself", "fs.error.move_into_itself")
        if (isDir(a)) {
            mkdir(b)
            for (e in list(a)!!) move(e.path, "$b/${e.name}")
            delete(a, recursive = true)
        } else {
            writeFile(b, readFile(a) ?: throw FsError("Could not read $a", "fs.error.could_not_read", mapOf("path" to a)))
            delete(a)
        }
    }

    /** Immutable source bytes for validating non-executable document metadata edits. */
    @Synchronized fun bundledBytes(path:String):ByteArray? {
        val p=Paths.normalize("C:/",path) ?: return null
        val e=bundled[p.lowercase()] ?: p.takeIf {it.endsWith(".Z",true)}?.dropLast(2)?.let {bundled[it.lowercase()]} ?: return null
        return if(e.isDir) null else bundle.open(e.path.removePrefix("C:/"))
    }

    /** True if [path] is a bundled original that the user has not modified. */
    @Synchronized fun isOriginal(path: String): Boolean {
        val p = Paths.normalize("C:/", path) ?: return false
        return overlayFind(p) == null && bundledEntry(p) != null
    }

    /** True if a bundled original exists at [path] (whether or not the user changed it). */
    @Synchronized fun hasBundledOriginal(path: String): Boolean {
        val p = Paths.normalize("C:/", path) ?: return false
        return bundled.containsKey(p.lowercase())
    }

    /**
     * Where the bundled file at [path] comes from (bundled-fs.index, written by
     * tools/resource-packaging/build_bundled_fs.py), or null if no bundled file is there.
     */
    @Synchronized fun bundledOrigin(path: String): String? {
        val p = Paths.normalize("C:/", path) ?: return null
        return bundled[p.lowercase()]?.takeIf { !it.isDir }?.origin
    }

    /** Removes the user's copy of a bundled file, restoring the original. */
    @Synchronized fun restoreOriginal(path: String) {
        val p = check(path)
        overlayFind(p)?.let { used -= it.length(); it.delete() }
        unWhiteout(p)
    }

    @Synchronized fun usedBytes() = used
    val quota get() = quotaBytes
}
