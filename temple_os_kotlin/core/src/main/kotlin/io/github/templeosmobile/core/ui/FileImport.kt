package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.FsError
import io.github.templeosmobile.core.kernel.LayeredFs
import io.github.templeosmobile.core.kernel.Paths
import io.github.templeosmobile.core.kernel.TempleArc
import io.github.templeosmobile.core.kernel.ZipArchive
import io.github.templeosmobile.core.kernel.ZipError
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** Why an import was refused: a catalog key (import.error.*) and its placeholders, ready to show. */
class ImportError(val key: String, vararg val args: Pair<String, Any?>) : Exception(key + args.joinToString("") { " ${it.first}=${it.second}" })

/**
 * A document the user picked, as the platform hands it over: its own name (Unicode, from the provider) and a
 * private copy in app storage ([hostPath], which the import deletes when done), or why there is none.
 */
class PickedFile(val name: String, val hostPath: String?, val problem: ImportError? = null)

/**
 * Imports external TempleOS files onto the C: drive (docs/file-import.md): HolyC source (.HC), TempleOS-compressed
 * source (.HC.Z: expanded with Kernel/Compress.HC's algorithm and stored under its name without .Z, as the bundled
 * drive stores the ISO's compressed files) and ZIP archives (extracted with their folders; TempleOS-compressed
 * files inside are expanded the same way). Everything goes to [DESTINATION] in the user's overlay, where Files,
 * the Terminal, the editor and the HolyC interpreter find it like any other file.
 *
 * [prepare] (any thread) reads, checks and decodes one picked file into a hidden staging folder ([LayeredFs.Stage]);
 * nothing is visible until [publish] (UI thread) renames it into place, so a refused or failed import leaves no
 * trace. Input is untrusted: names are checked as RedSea names, archives against the limits below before anything
 * is extracted, and type is decided by name and checked against content (MIME types are never used).
 */
object FileImport {
    /** Where imports go: a folder of the user's home (Files and the Terminal start in C:/Home). */
    const val DESTINATION = "C:/Home/Imports"

    /** A picked .HC or .HC.Z, and any one file from an archive, after expansion. */
    const val MAX_FILE_BYTES = 16 shl 20
    /** A picked .zip. */
    const val MAX_ARCHIVE_BYTES = 32 shl 20
    /** Everything one archive extracts to (the drive's quota, 64 MiB for all the user's files, also applies). */
    const val MAX_TOTAL_BYTES = 48 shl 20
    const val MAX_ENTRIES = 2000
    /** Folders inside an archive. */
    const val MAX_DEPTH = 8
    /** Expansion ratio above which an entry larger than [RATIO_MIN_BYTES] is treated as a ZIP bomb. */
    const val MAX_RATIO = 200
    const val RATIO_MIN_BYTES = 1 shl 20
    /** Documents handled from one selection. */
    const val MAX_PICKED = 32

    enum class Kind { SOURCE, COMPRESSED, ARCHIVE }

    /** The kind by name only (any case): .HC, .HC.Z or .zip; null for anything else. */
    fun kind(name: String): Kind? {
        val n = name.trim().lowercase()
        return when {
            n.endsWith(".zip") && n.length > 4 -> Kind.ARCHIVE
            n.endsWith(".hc.z") && n.length > 5 -> Kind.COMPRESSED
            n.endsWith(".hc") && n.length > 3 -> Kind.SOURCE
            else -> null
        }
    }

    /** One picked file after [prepare]: staged ([error] null) or refused. */
    class Prepared private constructor(
        /** The picked document's own name (for messages). */
        val source: String,
        val error: Throwable?,
        val kind: Kind?,
        /** The name it is published under in [DESTINATION] (a TempleOS byte string). */
        val name: String,
        val isDir: Boolean,
        /** Files staged (an archive's count; 1 otherwise). */
        val files: Int,
        internal val stage: LayeredFs.Stage?,
    ) {
        internal constructor(source: String, error: Throwable) : this(source, error, null, "", false, 0, null)
        internal constructor(source: String, kind: Kind, name: String, isDir: Boolean, files: Int, stage: LayeredFs.Stage) :
            this(source, null, kind, name, isDir, files, stage)
    }

    /** A picked file that is not imported at all (deletes its copy). */
    fun refuse(p: PickedFile, e: ImportError): Prepared {
        p.hostPath?.let { File(it).delete() }
        return Prepared(p.name, e)
    }

    /**
     * Reads, checks and decodes [p] into a staging folder of [fs]; deletes the platform's copy. Any thread (the
     * drive is thread-safe). The result is refused with the reason, or staged and invisible until [publish].
     */
    fun prepare(fs: LayeredFs, p: PickedFile): Prepared = try {
        p.problem?.let { throw it }
        val host = p.hostPath?.let { File(it) }?.takeIf { it.isFile } ?: throw ImportError("import.error.read")
        val kind = kind(p.name) ?: throw ImportError("import.error.unsupported_type")
        val size = host.length()
        if (size == 0L) throw ImportError("import.error.empty")
        if (kind == Kind.ARCHIVE) {
            if (size > MAX_ARCHIVE_BYTES) throw ImportError("import.error.archive_too_large", "mib" to (MAX_ARCHIVE_BYTES shr 20))
            prepareArchive(fs, host.path, p.name)
        } else {
            if (size > MAX_FILE_BYTES) throw ImportError("import.error.too_large", "mib" to (MAX_FILE_BYTES shr 20))
            var bytes = try { host.readBytes() } catch (e: java.io.IOException) { throw ImportError("import.error.read") }
            var name = p.name.trim()
            if (kind == Kind.COMPRESSED) {
                val h = TempleArc.header(bytes) ?: throw ImportError("import.error.corrupt_z")
                if (h.second > MAX_FILE_BYTES) throw ImportError("import.error.too_large", "mib" to (MAX_FILE_BYTES shr 20))
                bytes = try { TempleArc.expand(bytes, limit = MAX_FILE_BYTES) } catch (e: FsError) { throw ImportError("import.error.corrupt_z") }
                name = name.dropLast(2)
            } else {
                // the bytes are stored unchanged; only content that is certainly something else is refused
                if (startsWith(bytes, 0x50, 0x4B, 3, 4) || startsWith(bytes, 0x50, 0x4B, 5, 6)) throw ImportError("import.error.is_zip")
                val h = TempleArc.header(bytes)
                if (h != null && h.first == bytes.size && runCatching { TempleArc.expand(bytes, limit = MAX_FILE_BYTES) }.isSuccess)
                    throw ImportError("import.error.is_compressed")
            }
            val driveName = driveName(name) ?: throw ImportError("import.error.bad_name", "entry" to name)
            val stage = fs.beginStage()
            try { fs.stageFile(stage, driveName, bytes) } catch (e: Throwable) { fs.discardStage(stage); throw e }
            Prepared(p.name, kind, driveName, false, 1, stage)
        }
    } catch (e: Exception) {
        Prepared(p.name, e)
    } finally {
        p.hostPath?.let { File(it).delete() }
    }

    private fun startsWith(b: ByteArray, vararg prefix: Int) = b.size >= prefix.size && prefix.indices.all { (b[it].toInt() and 255) == prefix[it] }

    private fun utf8OrNull(b: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(b)).toString()
    } catch (e: CharacterCodingException) { null }

    /** An archive entry's name: Unicode for messages, and the C: byte string (null when it cannot be one). */
    internal fun entryName(e: ZipArchive.Entry): Pair<String, String?> {
        // flag 11 marks UTF-8; macOS and Linux tools write UTF-8 without it, so valid UTF-8 with non-ASCII counts too
        val utf8 = e.utf8 || (e.rawName.any { it < 0 } && utf8OrNull(e.rawName) != null)
        if (utf8) {
            val u = utf8OrNull(e.rawName) ?: return "?" to null
            val shown = u.replace('\\', '/')
            return shown to InputCharacterPolicy.encode(shown, singleLine = true)
        }
        // CP437, the ZIP default, is also TempleOS's character set: the bytes are the name
        val bytes = String(CharArray(e.rawName.size) { (e.rawName[it].toInt() and 255).toChar() }).replace('\\', '/')
        return InputCharacterPolicy.display(bytes) to bytes
    }

    /** A provider's or archive's name as one C: name (NFC, CP437), or null when it cannot be one. */
    fun driveName(unicode: String): String? {
        val t = unicode.trim()
        if (t.isEmpty()) return null
        val bytes = InputCharacterPolicy.encode(t, singleLine = true) ?: return null
        return bytes.takeIf { validSegment(it) }
    }

    /** One RedSea name ([Paths.normalize]: at most 38 characters, no : * ? " < > |), not hidden from listings. */
    internal fun validSegment(b: String): Boolean {
        if (b.isEmpty() || b == "." || b == ".." || b.contains('/') || b.contains('\\') || b.startsWith(".tmp-")) return false
        return Paths.normalize(DESTINATION, b) == "$DESTINATION/$b"
    }

    private fun zipError(e: ZipError, entry: String?): ImportError = when (e.kind) {
        ZipError.Kind.INVALID -> ImportError("import.error.invalid_zip")
        ZipError.Kind.UNSUPPORTED -> ImportError("import.error.zip_unsupported")
        ZipError.Kind.TOO_MANY_ENTRIES -> ImportError("import.error.too_many_entries", "count" to MAX_ENTRIES)
        ZipError.Kind.DAMAGED -> ImportError("import.error.damaged", "entry" to (entry ?: "?"))
        ZipError.Kind.READ -> ImportError("import.error.read")
    }

    private class Item(val entry: ZipArchive.Entry, val shown: String, val parts: List<String>, val expand: Boolean)

    /**
     * Checks every entry of the archive at [host] before extracting any: no encryption or unsupported method, no
     * link or special file, names that are valid C: names and stay inside the import folder (no "..", absolute
     * path or drive), no two entries whose names differ only in case (the drive ignores case), no file that is
     * also a folder, the depth, size, ratio and total limits. Then extracts into a staging folder: one folder of
     * the archive that holds everything becomes the import folder, otherwise a folder named after the archive.
     */
    private fun prepareArchive(fs: LayeredFs, host: String, source: String): Prepared {
        val zip = try { ZipArchive(host, MAX_ENTRIES) } catch (e: ZipError) { throw zipError(e, null) }
        try {
            val items = ArrayList<Item>()
            val files = HashSet<String>(); val dirs = HashSet<String>()
            var total = 0L
            for (e in zip.entries) {
                val (shown, b) = entryName(e)
                if (e.flags and 0x41 != 0 || e.method == 99) throw ImportError("import.error.encrypted")
                if (e.isSpecial) throw ImportError("import.error.link", "entry" to shown)
                val bytes = b ?: throw ImportError("import.error.bad_name", "entry" to shown)
                if (bytes.startsWith("/") || bytes.contains(':')) throw ImportError("import.error.unsafe_path", "entry" to shown)
                val parts = bytes.split('/').toMutableList()
                if (e.isDir && parts.size > 1 && parts.last() == "") parts.removeAt(parts.size - 1)
                if (parts.any { it == "." || it == ".." }) throw ImportError("import.error.unsafe_path", "entry" to shown)
                if (parts.any { it.isEmpty() }) throw ImportError("import.error.bad_name", "entry" to shown)
                // Finder's resource forks and folder settings are not content
                if (parts[0] == "__MACOSX" || parts[parts.size - 1] == ".DS_Store") continue
                if (!e.isDir && e.method != 0 && e.method != 8) throw ImportError("import.error.method", "entry" to shown)
                var expand = false
                val last = parts[parts.size - 1]
                if (!e.isDir && last.length > 2 && last.uppercase().endsWith(".Z")) { parts[parts.size - 1] = last.dropLast(2); expand = true }
                if (!parts.all { validSegment(it) }) throw ImportError("import.error.bad_name", "entry" to shown)
                if (parts.size - (if (e.isDir) 0 else 1) > MAX_DEPTH) throw ImportError("import.error.too_deep", "entry" to shown, "count" to MAX_DEPTH)
                if (!e.isDir) {
                    if (e.size > MAX_FILE_BYTES) throw ImportError("import.error.entry_too_large", "entry" to shown, "mib" to (MAX_FILE_BYTES shr 20))
                    if (e.size > RATIO_MIN_BYTES && e.size / maxOf(1, e.compressedSize) > MAX_RATIO) throw ImportError("import.error.ratio", "entry" to shown)
                    total += e.size
                    if (total > MAX_TOTAL_BYTES) throw ImportError("import.error.expands_too_large", "mib" to (MAX_TOTAL_BYTES shr 20))
                }
                val key = parts.joinToString("/").lowercase()
                if (e.isDir) {
                    if (key in files) throw ImportError("import.error.file_and_folder", "entry" to shown)
                    dirs.add(key)
                } else {
                    if (key in files) throw ImportError("import.error.duplicate", "entry" to shown)
                    if (key in dirs) throw ImportError("import.error.file_and_folder", "entry" to shown)
                    files.add(key)
                }
                for (k in 1 until parts.size) {
                    val parent = parts.subList(0, k).joinToString("/").lowercase()
                    if (parent in files) throw ImportError("import.error.file_and_folder", "entry" to shown)
                    dirs.add(parent)
                }
                items.add(Item(e, shown, parts, expand))
            }
            // a file listed before a folder of the same name
            items.firstOrNull { !it.entry.isDir && it.parts.joinToString("/").lowercase() in dirs }?.let {
                throw ImportError("import.error.file_and_folder", "entry" to it.shown)
            }
            if (files.isEmpty()) throw ImportError("import.error.empty_archive")
            val top = items[0].parts[0].lowercase()
            val single = items.all { it.parts[0].lowercase() == top && (it.parts.size > 1 || it.entry.isDir) }
            val folder = if (single) (items.firstOrNull { it.parts.size > 1 }?.parts?.get(0) ?: items[0].parts[0]) else {
                val base = source.trim().dropLast(4)
                driveName(base) ?: throw ImportError("import.error.bad_name", "entry" to base)
            }
            val stage = fs.beginStage()
            try {
                fs.stageDir(stage, folder)
                var count = 0
                for (it in items) {
                    val rel = (listOf(folder) + it.parts.drop(if (single) 1 else 0)).joinToString("/")
                    if (it.entry.isDir) { fs.stageDir(stage, rel); continue }
                    var data = try { zip.data(it.entry) } catch (e: ZipError) { throw zipError(e, it.shown) }
                    if (it.expand) {
                        val h = TempleArc.header(data) ?: throw ImportError("import.error.corrupt_z_entry", "entry" to it.shown)
                        if (h.second > MAX_FILE_BYTES) throw ImportError("import.error.entry_too_large", "entry" to it.shown, "mib" to (MAX_FILE_BYTES shr 20))
                        total += h.second - data.size
                        if (total > MAX_TOTAL_BYTES) throw ImportError("import.error.expands_too_large", "mib" to (MAX_TOTAL_BYTES shr 20))
                        data = try { TempleArc.expand(data, limit = MAX_FILE_BYTES) } catch (e: FsError) { throw ImportError("import.error.corrupt_z_entry", "entry" to it.shown) }
                    }
                    fs.stageFile(stage, rel, data)
                    count++
                }
                return Prepared(source, Kind.ARCHIVE, folder, true, count, stage)
            } catch (e: Throwable) {
                fs.discardStage(stage)
                throw e
            }
        } finally {
            zip.close()
        }
    }

    /** Makes [p] visible as [DESTINATION]/[name]; [replace] replaces the user's earlier file or folder there. UI thread. */
    fun publish(fs: LayeredFs, p: Prepared, name: String, replace: Boolean): String {
        val stage = p.stage ?: throw (p.error ?: ImportError("import.error.interrupted"))
        for (d in listOf("C:/Home", DESTINATION)) if (!fs.isDir(d)) fs.mkdir(d)
        val target = "$DESTINATION/$name"
        fs.publishStaged(stage, p.name, target, replace)
        return target
    }

    /** Deletes what [p] still holds (after [publish]: a replaced entry; otherwise everything staged). */
    fun discard(fs: LayeredFs, p: Prepared) { p.stage?.let { fs.discardStage(it) } }

    /** Keep Both: "Name.HC" -> "Name_2.HC", "Name_3.HC", ... the first free valid name in [DESTINATION], or null. */
    fun freeName(fs: LayeredFs, name: String): String? {
        val dot = name.indexOf('.').takeIf { it > 0 } ?: name.length
        val ext = name.substring(dot)
        for (n in 2..999) {
            val suffix = "_$n"
            var base = name.substring(0, dot)
            while (base.isNotEmpty() && base.length + suffix.length + ext.length > 38) base = base.dropLast(1)
            val candidate = base + suffix + ext
            if (validSegment(candidate) && !fs.exists("$DESTINATION/$candidate")) return candidate
        }
        return null
    }

    /** [e] as the reason shown after the file's name. */
    fun reason(e: Throwable): String = when (e) {
        is ImportError -> tr(e.key, *e.args)
        is FsError -> e.localized()
        else -> tr("import.error.interrupted")
    }
}
