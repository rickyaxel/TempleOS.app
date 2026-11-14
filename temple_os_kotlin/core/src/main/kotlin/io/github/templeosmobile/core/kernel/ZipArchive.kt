package io.github.templeosmobile.core.kernel

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.zip.CRC32
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * The container of a ZIP archive the user imports (ui/FileImport), read as untrusted input. The end record and
 * the whole central directory are parsed, and every entry's local header is checked (signature, the same name,
 * data inside the file and before the central directory, no overlap with the previous entry) before anything
 * is extracted. Every offset and length is checked against the file before it is read. An entry inflates into
 * a buffer of exactly its declared size and must match its CRC-32. Policy (names, encryption, methods, sizes,
 * links) is FileImport's; nothing here creates files.
 *
 * Single-disk archives only: ZIP64 and split archives are [ZipError.Kind.UNSUPPORTED]. Deflate and CRC-32 are
 * java.util.zip's (Inflater, CRC32; Swift: the Compression framework and its own CRC-32). The container format
 * (a few records with fixed fields) is parsed here instead of by ZipFile/ZipInputStream so that both platforms
 * check exactly the same things (Apple platforms have no public API that reads ZIP archives).
 */
class ZipArchive(path: String, maxEntries: Int) {
    class Entry(
        /** The stored name bytes (UTF-8 when [utf8], else usually CP437). */
        val rawName: ByteArray,
        /** General purpose flag bit 11: the name is UTF-8. */
        val utf8: Boolean,
        val flags: Int,
        val method: Int,
        /** A folder: the name ends with "/" (or "\"), or the attributes say so. */
        val isDir: Boolean,
        /** A symbolic link, device, FIFO or socket (the Unix file type in the external attributes). */
        val isSpecial: Boolean,
        val crc: Long,
        val compressedSize: Int,
        val size: Int,
        internal val localOffset: Int,
    ) {
        /** Where the data starts (after the local header); set when the local header was checked. */
        internal var dataStart = 0
    }

    var entries: List<Entry> = emptyList()
        private set
    private var file: RandomAccessFile? = try { RandomAccessFile(File(path), "r") } catch (e: IOException) { null }
    private val fileSize: Int

    init {
        val f = file
        val n = try { f?.length() ?: -1L } catch (e: IOException) { -1L }
        if (f == null || n < 0 || n > Int.MAX_VALUE) { close(); throw ZipError(ZipError.Kind.READ) }
        fileSize = n.toInt()
        try { parse(maxEntries) } catch (e: Throwable) { close(); throw e }
    }

    fun close() { try { file?.close() } catch (_: IOException) {}; file = null }

    private fun u16(b: ByteArray, o: Int) = (b[o].toInt() and 255) or ((b[o + 1].toInt() and 255) shl 8)
    private fun u32(b: ByteArray, o: Int): Long = u16(b, o).toLong() or (u16(b, o + 2).toLong() shl 16)

    /** [n] bytes at [off], which must lie inside the file. */
    private fun read(off: Long, n: Int): ByteArray {
        val buf = ByteArray(n)
        readInto(buf, off, n)
        return buf
    }

    private fun readInto(buf: ByteArray, off: Long, n: Int) {
        if (off < 0 || n < 0 || off > fileSize || n > fileSize - off) throw ZipError(ZipError.Kind.INVALID)
        val f = file ?: throw ZipError(ZipError.Kind.READ)
        try { f.seek(off); f.readFully(buf, 0, n) } catch (e: IOException) { throw ZipError(ZipError.Kind.READ) }
    }

    private fun parse(maxEntries: Int) {
        if (fileSize < 22) throw ZipError(ZipError.Kind.INVALID)
        // the end record: the last signature whose comment ends exactly at the end of the file
        val tailLen = minOf(fileSize, 22 + 0xFFFF)
        val tail = read((fileSize - tailLen).toLong(), tailLen)
        var at = tailLen - 22
        var eocd = -1
        while (at >= 0) {
            if (tail[at].toInt() == 0x50 && tail[at + 1].toInt() == 0x4B && tail[at + 2].toInt() == 5 && tail[at + 3].toInt() == 6 && at + 22 + u16(tail, at + 20) == tailLen) { eocd = at; break }
            at--
        }
        if (eocd < 0) throw ZipError(ZipError.Kind.INVALID)
        val eocdPos = fileSize - tailLen + eocd
        val disk = u16(tail, eocd + 4); val cdDisk = u16(tail, eocd + 6)
        val onDisk = u16(tail, eocd + 8); val total = u16(tail, eocd + 10)
        val cdSize = u32(tail, eocd + 12); val cdOffset = u32(tail, eocd + 16)
        // ZIP64: values that do not fit, or its locator right before the end record; split: more than one disk
        if (total == 0xFFFF || cdSize == 0xFFFF_FFFFL || cdOffset == 0xFFFF_FFFFL) throw ZipError(ZipError.Kind.UNSUPPORTED)
        if (eocdPos >= 20 && read((eocdPos - 20).toLong(), 4).contentEquals(byteArrayOf(0x50, 0x4B, 6, 7))) throw ZipError(ZipError.Kind.UNSUPPORTED)
        if (disk != 0 || cdDisk != 0 || onDisk != total) throw ZipError(ZipError.Kind.UNSUPPORTED)
        if (total > maxEntries) throw ZipError(ZipError.Kind.TOO_MANY_ENTRIES)
        if (cdOffset + cdSize > eocdPos) throw ZipError(ZipError.Kind.INVALID)
        val cd = read(cdOffset, cdSize.toInt())
        var p = 0
        val list = ArrayList<Entry>()
        repeat(total) {
            if (p + 46 > cd.size || u32(cd, p) != 0x0201_4B50L) throw ZipError(ZipError.Kind.INVALID)
            val madeBy = u16(cd, p + 4); val flags = u16(cd, p + 8); val method = u16(cd, p + 10)
            val crc = u32(cd, p + 16); val csize = u32(cd, p + 20); val usize = u32(cd, p + 24)
            val nameLen = u16(cd, p + 28); val extraLen = u16(cd, p + 30); val commentLen = u16(cd, p + 32)
            val external = u32(cd, p + 38); val local = u32(cd, p + 42)
            if (p + 46 + nameLen + extraLen + commentLen > cd.size) throw ZipError(ZipError.Kind.INVALID)
            if (csize == 0xFFFF_FFFFL || usize == 0xFFFF_FFFFL || local == 0xFFFF_FFFFL) throw ZipError(ZipError.Kind.UNSUPPORTED)
            if (csize > Int.MAX_VALUE || usize > Int.MAX_VALUE) throw ZipError(ZipError.Kind.INVALID)
            val raw = cd.copyOfRange(p + 46, p + 46 + nameLen)
            p += 46 + nameLen + extraLen + commentLen
            // Unix (3) and OS X (19) keep the file type in the high half of the external attributes; DOS has a folder bit
            val host = madeBy shr 8; val type = ((external shr 16) and 0xF000).toInt()
            val unix = host == 3 || host == 19
            val last = raw.lastOrNull()?.toInt()
            val isDir = last == 0x2F || last == 0x5C || (unix && type == 0x4000) || (!unix && external and 0x10L != 0L)
            list.add(Entry(raw, flags and 0x800 != 0, flags, method, isDir, unix && type != 0 && type != 0x8000 && type != 0x4000,
                crc, csize.toInt(), usize.toInt(), local.toInt()))
        }
        // local headers in file order: the same name, data inside the file before the central directory, no overlap
        var end = 0L
        for (e in list.sortedBy { it.localOffset }) {
            if (e.localOffset < end) throw ZipError(ZipError.Kind.INVALID)
            val h = read(e.localOffset.toLong(), 30)
            if (u32(h, 0) != 0x0403_4B50L) throw ZipError(ZipError.Kind.INVALID)
            val n = u16(h, 26); val x = u16(h, 28)
            if (n != e.rawName.size || !read(e.localOffset + 30L, n).contentEquals(e.rawName)) throw ZipError(ZipError.Kind.INVALID)
            e.dataStart = e.localOffset + 30 + n + x
            if (e.dataStart > cdOffset || e.compressedSize > cdOffset - e.dataStart) throw ZipError(ZipError.Kind.INVALID)
            end = e.dataStart.toLong() + e.compressedSize
        }
        entries = list
    }

    /**
     * The entry's bytes: exactly [Entry.size] of them, checked against its CRC-32. The data is read in 64 KiB
     * chunks; Deflate output beyond the declared size, a stream that ends early or never ends, and a CRC
     * mismatch are all [ZipError.Kind.DAMAGED]. The caller has limited [Entry.size].
     */
    fun data(e: Entry): ByteArray {
        if (e.isDir) return ByteArray(0)
        val out = when (e.method) {
            0 -> { if (e.compressedSize != e.size) throw ZipError(ZipError.Kind.DAMAGED); read(e.dataStart.toLong(), e.size) }
            8 -> inflate(e)
            else -> throw ZipError(ZipError.Kind.DAMAGED)
        }
        if (CRC32().apply { update(out) }.value != e.crc) throw ZipError(ZipError.Kind.DAMAGED)
        return out
    }

    private fun inflate(e: Entry): ByteArray {
        // one spare byte: a stream that fills it is longer than declared
        val out = ByteArray(e.size + 1)
        val chunk = ByteArray(1 shl 16)
        val inf = Inflater(true)
        try {
            var pos = e.dataStart.toLong(); var left = e.compressedSize; var produced = 0
            var dummy = false
            var stalls = 0
            while (!inf.finished()) {
                if (inf.needsInput()) {
                    if (left > 0) {
                        val n = minOf(left, chunk.size)
                        readInto(chunk, pos, n)
                        pos += n; left -= n
                        inf.setInput(chunk, 0, n)
                    } else if (!dummy) {
                        // nowrap needs one extra byte after the stream (Inflater's documentation)
                        dummy = true; inf.setInput(ByteArray(1))
                    } else throw ZipError(ZipError.Kind.DAMAGED) // all input given and the stream does not end: truncated
                }
                if (inf.needsDictionary()) throw ZipError(ZipError.Kind.DAMAGED)
                val n = try { inf.inflate(out, produced, out.size - produced) } catch (x: DataFormatException) { throw ZipError(ZipError.Kind.DAMAGED) }
                produced += n
                // output beyond the spare byte
                if (produced == out.size) throw ZipError(ZipError.Kind.DAMAGED)
                if (n == 0 && !inf.needsInput() && !inf.finished()) { if (++stalls > 1) throw ZipError(ZipError.Kind.DAMAGED) } else stalls = 0
            }
            if (produced != e.size) throw ZipError(ZipError.Kind.DAMAGED)
            return out.copyOf(e.size)
        } finally {
            inf.end()
        }
    }
}

/** Why an archive could not be read; ui/FileImport turns these into messages. */
class ZipError(val kind: Kind) : Exception(kind.name) {
    enum class Kind {
        /** Not a ZIP archive, or its structure is inconsistent (truncated, overlapping, offsets outside the file). */
        INVALID,
        /** ZIP64 or a split archive. */
        UNSUPPORTED,
        TOO_MANY_ENTRIES,
        /** An entry's data does not inflate to its declared size or does not match its CRC-32. */
        DAMAGED,
        /** The file could not be read. */
        READ,
    }
}
