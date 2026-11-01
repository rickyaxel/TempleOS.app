package io.github.templeosmobile.core.holyc

/**
 * A HolyC/DolDoc source file split into its text part and its binary records
 * (sprites etc.). TempleOS stores binaries after a NUL that terminates the text:
 * `U32 num, U32 flags, U32 size, U32 use_cnt, U8 data[size]` repeated.
 */
class SourceFile(val name: String, val text: ByteArray, val bins: Map<Int, ByteArray>) {
    companion object {
        fun parse(name: String, raw: ByteArray): SourceFile {
            var end = raw.indexOf(0.toByte())
            if (end < 0) return SourceFile(name, raw, emptyMap())
            val text = raw.copyOfRange(0, end)
            val bins = HashMap<Int, ByteArray>()
            var p = end + 1
            while (p + 16 <= raw.size) {
                val num = le32(raw, p)
                val size = le32(raw, p + 8)
                p += 16
                if (size < 0 || size > raw.size - p) break // (p + size can overflow)
                bins[num] = raw.copyOfRange(p, p + size)
                p += size
            }
            return SourceFile(name, text, bins)
        }

        fun ofString(name: String, s: String) = SourceFile(name, latin1(s), emptyMap())

        private fun le32(b: ByteArray, p: Int): Int =
            (b[p].toInt() and 0xFF) or ((b[p + 1].toInt() and 0xFF) shl 8) or
                ((b[p + 2].toInt() and 0xFF) shl 16) or ((b[p + 3].toInt() and 0xFF) shl 24)
    }
}

/** Resolves `#include` paths. Implemented by the virtual filesystem. */
fun interface SourceProvider {
    /** Returns the raw file bytes for an absolute logical path, or null. */
    fun read(path: String): ByteArray?
}

fun latin1(s: String): ByteArray = ByteArray(s.length) { s[it].code.toByte() }
fun latin1(b: ByteArray, off: Int = 0, len: Int = b.size - off): String {
    val ch = CharArray(len) { (b[off + it].toInt() and 0xFF).toChar() }
    return String(ch)
}

class CompileError(msg: String, val file: String = "", val line: Int = 0) :
    Exception(if (file.isNotEmpty()) "$file:$line: $msg" else msg) {
    val bare = msg
}
