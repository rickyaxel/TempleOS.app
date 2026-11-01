package io.github.templeosmobile.core.kernel

/** TempleOS V5.03 Adam/Gr/GrDC.HC DCSave/DCLoad. Keep indices, padding and metadata intact.
 * Allocation limits are mobile guards, not restrictions of the historical format. */
class GRImage private constructor(val width: Int, val height: Int, val stride: Int,
    val header: ByteArray, val palette: ByteArray?, val body: ByteArray) {
    constructor(width: Int = 320, height: Int = 240) : this(width, height, (width + 7) and 7.inv(),
        ByteArray(32), null, newBody(width, height))

    var pixels: ByteArray
        get() = ByteArray(width * height).also { p ->
            for (y in 0 until height) body.copyInto(p, y * width, y * stride, y * stride + width)
        }
        set(value) {
            require(value.size == width * height)
            for (y in 0 until height) value.copyInto(body, y * stride, y * width, (y + 1) * width)
        }

    /** Uncompressed DCSave encoding (compression is optional in the original format). */
    fun encode(): ByteArray {
        val out = ByteArray(32 + (palette?.size ?: 0) + body.size)
        header.copyInto(out)
        fun put(o: Int, n: Int) { for (i in 0..3) out[o+i] = (n shr (8*i)).toByte() }
        put(16, width); put(20, stride); put(24, height)
        put(28, if (palette == null) 0 else 2) // DCSave clears runtime optimization flags.
        palette?.copyInto(out, 32)
        body.copyInto(out, 32 + (palette?.size ?: 0))
        return out
    }

    companion object {
        const val MAX_BODY = 16 * 1024 * 1024
        private fun newBody(w: Int, h: Int): ByteArray {
            require(w in 1..16384 && h in 1..16384)
            val stride = (w + 7) and 7.inv()
            require(stride <= MAX_BODY / h)
            return ByteArray(stride * h) { Palette.WHITE.toByte() }
        }

        fun decode(bytes: ByteArray): GRImage {
            if (bytes.size < 32) throw FsError("Truncated GR header")
            fun word(o: Int) = (bytes[o].toInt() and 255) or ((bytes[o+1].toInt() and 255) shl 8) or
                ((bytes[o+2].toInt() and 255) shl 16) or (bytes[o+3].toInt() shl 24)
            val w = word(16); val s = word(20); val h = word(24); val flags = word(28)
            if (w !in 1..16384 || h !in 1..16384 || s < w || s > MAX_BODY / h ||
                s and 7 != 0 || flags and 7.inv() != 0) throw FsError("Invalid GR geometry or flags")
            val off = 32 + if (flags and 2 != 0) 128 else 0
            if (bytes.size < off) throw FsError("Truncated GR palette")
            val size = s * h
            val body = if (flags and 1 != 0) TempleArc.expand(bytes.copyOfRange(off, bytes.size), size)
                else {
                    if (size > bytes.size - off) throw FsError("Truncated GR body")
                    bytes.copyOfRange(off, off + size)
                }
            return GRImage(w, h, s, bytes.copyOfRange(0, 32),
                if (flags and 2 != 0) bytes.copyOfRange(32, off) else null, body)
        }

        fun decodeFile(bytes: ByteArray, outerArchive: Boolean): GRImage {
            if (!outerArchive) return decode(bytes)
            // Earlier mobile saves wrote raw GR even with a .Z suffix. This fallback
            // accepts a fully validated image, not malformed archive data or a blank canvas.
            try { return decode(bytes) } catch (_: FsError) { /* try original outer archive */ }
            return decode(TempleArc.expand(bytes))
        }
    }
}

/** Bounded port of Kernel/Compress.HC ArcEntryGet/ArcExpandBuf (TempleOS 7/8-bit LZW).
 * Truncated codes, invalid dictionary references and cycles fail before replacing an image. */
object TempleArc {
    fun store(bytes: ByteArray): ByteArray {
        val out = ByteArray(17 + bytes.size)
        for (i in 0..7) {
            out[i] = ((bytes.size.toLong() + 17) shr (8*i)).toByte()
            out[8+i] = (bytes.size.toLong() shr (8*i)).toByte()
        }
        out[16] = 1 // CT_NONE (Kernel/Compress.HC CompressBuf)
        bytes.copyInto(out, 17)
        return out
    }
    fun expand(src: ByteArray, expected: Int? = null): ByteArray {
        fun bad(): Nothing = throw FsError("Invalid TempleOS compressed data")
        if (src.size < 17) bad()
        fun size(o: Int): Int {
            var n = 0L
            for (i in 0..7) n = n or ((src[o+i].toLong() and 255) shl (8*i))
            if (n < 0 || n > Int.MAX_VALUE) bad()
            return n.toInt()
        }
        val compressed = size(0); val expanded = size(8); val type = src[16].toInt() and 255
        val maxExpanded = if (expected == null) GRImage.MAX_BODY + 160 else GRImage.MAX_BODY
        if (compressed < 17 || compressed > src.size || expanded > maxExpanded ||
            expected != null && expected != expanded) bad()
        if (type == 1) {
            if (expanded > compressed - 17) bad()
            return src.copyOfRange(17, 17 + expanded)
        }
        if (type != 2 && type != 3) bad()
        if (expanded == 0) return ByteArray(0)
        val minimum = 1 shl if (type == 2) 7 else 8
        val next = IntArray(4096) { -1 }; val base = IntArray(4096)
        val char = ByteArray(4096); val hash = IntArray(4096) { -1 }; val valid = BooleanArray(4096)
        var free = minimum; var bits = if (type == 2) 8 else 9; var limit = 1 shl bits
        var current = -1; var pending = -1; var bit = 17L * 8
        fun entry() {
            current = pending
            if (bits < 12) {
                pending = free++
                if (free == limit) { bits++; limit = 1 shl bits }
            } else {
                var tries = 0
                do {
                    if (++free == limit) free = minimum
                    if (++tries > 4096) bad()
                } while (hash[free] != -1)
                pending = free
                val head = base[free]
                if (hash[head] == free) hash[head] = next[free]
                else {
                    var p = hash[head]; var steps = 0
                    while (p != -1 && next[p] != free) {
                        p = next[p]; if (++steps > 4096) bad()
                    }
                    if (p != -1) next[p] = next[free]
                }
                valid[free] = false
            }
        }
        fun read(): Int {
            if (bit + bits > compressed.toLong() * 8) bad()
            var code = 0
            for (i in 0 until bits) code = code or (((src[((bit+i)/8).toInt()].toInt() ushr ((bit+i).toInt() and 7)) and 1) shl i)
            bit += bits; return code
        }
        entry()
        var last = read()
        if (last >= minimum) bad()
        val out = ByteArray(expanded); var count = 1; out[0] = last.toByte()
        var lastChar = last.toByte()
        entry()
        val stack = ByteArray(4098) // special-case byte + 4096 bounded hops + terminal byte
        while (count < expanded) {
            val code = read(); var cursor = code; var sp = 0
            if (code == current) { stack[sp++] = lastChar; cursor = last }
            var hops = 0
            while (cursor >= minimum) {
                if (cursor >= 4096 || !valid[cursor] || hops++ >= 4096) bad()
                stack[sp++] = char[cursor]; cursor = base[cursor]
            }
            lastChar = cursor.toByte(); stack[sp++] = lastChar
            if (current < minimum || last >= 4096 || sp > expanded - count) bad()
            base[current] = last; char[current] = lastChar; next[current] = hash[last]
            hash[last] = current; valid[current] = true
            entry()
            while (sp > 0) out[count++] = stack[--sp]
            last = code
        }
        return out
    }
}
