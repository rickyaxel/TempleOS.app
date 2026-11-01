package io.github.templeosmobile.core.dynexpr

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.holyc.CompileError

enum class DTok { IDENT, INT, FLOAT, STR, CHAR, PUNCT, BIN, EOF }

class DToken(@JvmField val kind: DTok, @JvmField val text: String, @JvmField val line: Int) {
    @JvmField var ival = 0L
    @JvmField var fval = 0.0
    @JvmField var bytes: ByteArray? = null
    @JvmField var charLen = 0
    /** Macro names that must not expand again in this token (the compiler's hide set). */
    @JvmField var hidden: Set<String>? = null

    /** As the compiler prints a token in its messages (Token.toString). */
    override fun toString(): String = when (kind) {
        DTok.STR -> "\"" + DynText.latin1(bytes!!) + "\""
        DTok.INT -> ival.toString()
        DTok.EOF -> "end of file"
        else -> text
    }
}

/** Latin-1 helpers (TempleOS text is 8-bit). */
object DynText {
    fun latin1(b: ByteArray, off: Int = 0, len: Int = b.size - off): String {
        val ch = CharArray(len) { (b[off + it].toInt() and 0xFF).toChar() }
        return String(ch)
    }
    fun latin1(s: String): ByteArray = ByteArray(s.length) { s[it].code.toByte() }
}

/**
 * The engine's tokenizer: the rules of the app's HolyC lexer (holyc/Lexer.kt) for what an expression
 * can contain — whitespace and nested comments, DolDoc commands in code, identifiers (8-bit, DolDoc
 * inside names), decimal/hex/binary integers, floats, char constants up to 8 bytes, strings, escapes —
 * with the same error messages. Macros are an allow-list ([DynMacros]) instead of the kernel's
 * `#define` table, and every directive is reported (none is executed).
 *
 * Tokens are produced lazily, as the parser asks for them, so a malformed token after a parse error is
 * never reached (the compiler's lexer is lazy too, and the first error is the one reported).
 */
class DynLexer(text: ByteArray, private val bins: Map<Int, ByteArray>, private val file: String, firstLine: Int = 1) {
    private val b = text
    private var pos = 0
    private var line = firstLine
    private val out = ArrayList<DToken>()
    private var eof = false
    /** Tokens produced so far (bounded by [DynLimits.MAX_TOKENS]). */
    val produced get() = out.size

    operator fun get(i: Int): DToken {
        while (i >= out.size && !eof) pull()
        return if (i < out.size) out[i] else out[out.size - 1]
    }

    /** Lazily: Int.MAX_VALUE until the end has been lexed (as the compiler's TokenSource). */
    val size: Int get() = if (eof) out.size else Int.MAX_VALUE

    private fun err(msg: String, ln: Int): Nothing = throw CompileError(msg, file, ln)

    private fun pull() {
        val before = out.size
        while (out.size == before) {
            val t = lexOne()
            if (t == null) {
                out.add(DToken(DTok.EOF, "", 0))
                eof = true
                return
            }
            handle(t)
        }
    }

    private fun emit(t: DToken) {
        if (out.size >= DynLimits.MAX_TOKENS)
            throw DynExpr.limit("longer than ${DynLimits.MAX_TOKENS} tokens", file, t.line)
        out.add(t)
    }

    private fun handle(t: DToken) {
        if (t.kind == DTok.PUNCT && t.text == "#") { directive(t); return }
        if (t.kind == DTok.IDENT) {
            when (t.text) {
                "__DIR__", "__FILE__" -> {
                    val v = if (t.text == "__FILE__") file else file.substringBeforeLast('/', "C:/")
                    emit(DToken(DTok.STR, "", t.line).also { it.bytes = DynText.latin1(v) }); return
                }
                "__LINE__" -> { emit(DToken(DTok.INT, "", t.line).also { it.ival = t.line.toLong() }); return }
            }
            expand(t, emptySet(), 0)
            return
        }
        emit(t)
    }

    private fun expand(t: DToken, hide: Set<String>, depth: Int) {
        val body = DynMacros.body(t.text)
        if (body == null || t.text in hide || (t.hidden?.contains(t.text) == true) || depth > 16) { emit(t); return }
        val h = hide + t.text + (t.hidden ?: emptySet())
        for (x in body) {
            val c = DToken(x.kind, x.text, t.line)
            c.ival = x.ival; c.fval = x.fval; c.bytes = x.bytes; c.charLen = x.charLen
            if (c.kind == DTok.IDENT) expand(c, h, depth + 1) else emit(c)
        }
    }

    /** `#...`: no directive is executed; the compiler's errors are kept for those it rejects too. */
    private fun directive(hash: DToken) {
        skipSpaces(stopAtNewline = true)
        val nameTok = lexOne() ?: err("bad directive", hash.line)
        val name = nameTok.text
        when (name) {
            "else" -> err("#else without #if", hash.line)
            "endif" -> err("#endif without #if", hash.line)
            "exe" -> err("#exe {} (compile-time code execution) is not supported by ${Brand.APP_NAME}", hash.line)
            "ifdef", "ifndef", "if", "ifjit", "ifaot", "define", "undef", "include", "help_index", "help_file", "assert", "pragma" ->
                throw DynExpr.outside("the preprocessor directive #$name", file, hash.line)
            else -> err("unknown directive #$name", hash.line)
        }
    }

    // ---------------------------------------------------------------- raw lexing (holyc/Lexer.kt)

    private fun skipSpaces(stopAtNewline: Boolean) {
        while (pos < b.size) {
            val c = b[pos].toInt() and 0xFF
            when {
                c == '\n'.code -> {
                    if (stopAtNewline) return
                    line++; pos++
                }
                c == ' '.code || c == '\t'.code || c == '\r'.code || c == 0x0C || c == 5 -> pos++
                c == '/'.code && pos + 1 < b.size && b[pos + 1] == '/'.code.toByte() -> {
                    while (pos < b.size && b[pos] != '\n'.code.toByte()) pos++
                }
                c == '/'.code && pos + 1 < b.size && b[pos + 1] == '*'.code.toByte() -> {
                    pos += 2
                    var depth = 1
                    while (pos < b.size && depth > 0) {
                        val d = b[pos].toInt()
                        if (d == '\n'.code) line++
                        if (d == '*'.code && pos + 1 < b.size && b[pos + 1] == '/'.code.toByte()) { depth--; pos += 2; continue }
                        if (d == '/'.code && pos + 1 < b.size && b[pos + 1] == '*'.code.toByte()) { depth++; pos += 2; continue }
                        pos++
                    }
                }
                c == '$'.code -> {
                    val end = dollarEnd(pos)
                    if (end < 0) { pos++; continue }
                    if (end == pos + 1) { pos += 2; continue }
                    val code = DynText.latin1(b, pos + 1, end - pos - 1).take(2)
                    if (code == "IB" || code == "IS" || code == "TX") return
                    pos = end + 1
                }
                else -> return
            }
        }
    }

    private fun dollarEnd(p: Int): Int {
        var i = p + 1
        var inQ = false
        while (i < b.size) {
            val c = b[i].toInt()
            if (c == '\n'.code) return -1
            if (c == '"'.code) inQ = !inQ
            else if (c == '\\'.code && inQ) i++
            else if (c == '$'.code && !inQ) return i
            i++
        }
        return -1
    }

    private fun lexOne(): DToken? {
        skipSpaces(stopAtNewline = false)
        if (pos >= b.size) return null
        val start = pos
        val c = b[start].toInt() and 0xFF
        return when {
            c == '$'.code -> dollarToken()
            isIdStart(c) -> {
                var p = start + 1
                var seg = start
                val name = StringBuilder()
                while (true) {
                    while (p < b.size && isIdChar(b[p].toInt() and 0xFF)) p++
                    if (p < b.size && b[p] == '$'.code.toByte()) {
                        val end = dollarEnd(p)
                        if (end > p + 1 && end + 1 < b.size && isIdChar(b[end + 1].toInt() and 0xFF)) {
                            val code = DynText.latin1(b, p + 1, minOf(2, end - p - 1))
                            if (code != "IB" && code != "IS" && code != "TX") {
                                name.append(DynText.latin1(b, seg, p - seg)); p = end + 1; seg = p; continue
                            }
                        }
                    }
                    break
                }
                name.append(DynText.latin1(b, seg, p - seg))
                pos = p
                DToken(DTok.IDENT, name.toString(), line)
            }
            c in '0'.code..'9'.code || (c == '.'.code && start + 1 < b.size && (b[start + 1].toInt() and 0xFF) in '0'.code..'9'.code) -> number()
            c == '"'.code -> { val ln = line; val bytes = literal('"'.code); DToken(DTok.STR, "", ln).also { it.bytes = bytes } }
            c == '\''.code -> charLit()
            else -> punct()
        }
    }

    private fun dollarToken(): DToken {
        val end = dollarEnd(pos)
        val cmd = DynText.latin1(b, pos + 1, end - pos - 1)
        pos = end + 1
        val code = cmd.take(2)
        val bi = Regex("BI=(\\d+)").find(cmd)?.groupValues?.get(1)?.toIntOrNull()
        return when (code) {
            "IB" -> {
                val data = bi?.let { bins[it] } ?: err("missing binary attachment in $$cmd$", line)
                DToken(DTok.BIN, "<bin>", line).also { it.bytes = data }
            }
            "IS" -> DToken(DTok.INT, "", line).also { it.ival = (bi?.let { bins[it] }?.size ?: 0).toLong() }
            else -> {
                val m = Regex("^TX[^\"]*\"((?:[^\"\\\\]|\\\\.)*)\"").find(cmd)
                val txt = m?.groupValues?.get(1) ?: ""
                val sub = DynLexer(DynText.latin1(txt), emptyMap(), file, line)
                sub.lexOne() ?: DToken(DTok.PUNCT, ";", line)
            }
        }
    }

    private fun isIdStart(c: Int) = c in 'A'.code..'Z'.code || c in 'a'.code..'z'.code || c == '_'.code || c >= 128
    private fun isIdChar(c: Int) = isIdStart(c) || c in '0'.code..'9'.code
    private fun hexDigit(c: Int): Int = when (c) {
        in '0'.code..'9'.code -> c - '0'.code
        in 'a'.code..'f'.code -> c - 'a'.code + 10
        in 'A'.code..'F'.code -> c - 'A'.code + 10
        else -> -1
    }
    private fun isDigit(x: Byte) = x in '0'.code.toByte()..'9'.code.toByte()

    private fun number(): DToken {
        var p = pos
        val tok: DToken
        if (b[p] == '0'.code.toByte() && p + 1 < b.size && (b[p + 1] == 'x'.code.toByte() || b[p + 1] == 'X'.code.toByte())) {
            p += 2
            var v = 0L
            while (p < b.size) {
                val d = hexDigit(b[p].toInt() and 0xFF)
                if (d < 0) break
                v = (v shl 4) or d.toLong(); p++
            }
            tok = DToken(DTok.INT, "", line); tok.ival = v
        } else if (b[p] == '0'.code.toByte() && p + 1 < b.size && (b[p + 1] == 'b'.code.toByte() || b[p + 1] == 'B'.code.toByte())) {
            p += 2
            var v = 0L
            while (p < b.size && (b[p] == '0'.code.toByte() || b[p] == '1'.code.toByte())) {
                v = (v shl 1) or (b[p] - '0'.code.toByte()).toLong(); p++
            }
            tok = DToken(DTok.INT, "", line); tok.ival = v
        } else {
            val s = p
            while (p < b.size && isDigit(b[p])) p++
            var isFloat = false
            if (p < b.size && b[p] == '.'.code.toByte() && !(p + 1 < b.size && b[p + 1] == '.'.code.toByte())) {
                isFloat = true; p++
                while (p < b.size && isDigit(b[p])) p++
            }
            if (p < b.size && (b[p] == 'e'.code.toByte() || b[p] == 'E'.code.toByte())) {
                var q = p + 1
                if (q < b.size && (b[q] == '-'.code.toByte() || b[q] == '+'.code.toByte())) q++
                if (q < b.size && isDigit(b[q])) {
                    isFloat = true
                    p = q
                    while (p < b.size && isDigit(b[p])) p++
                }
            }
            val str = DynText.latin1(b, s, p - s)
            if (isFloat) {
                tok = DToken(DTok.FLOAT, str, line); tok.fval = str.toDouble()
            } else {
                tok = DToken(DTok.INT, str, line)
                tok.ival = try { java.lang.Long.parseUnsignedLong(str.ifEmpty { "0" }) }
                    catch (e: NumberFormatException) { err("integer constant too large: $str", line) }
            }
        }
        pos = p
        return tok
    }

    /** An escape after a backslash at [p0]: (byte, next position). */
    private fun escape(p0: Int): Pair<Int, Int> {
        var p = p0
        val c = b[p].toInt() and 0xFF
        p++
        return when (c) {
            'n'.code -> 10 to p
            't'.code -> 9 to p
            'r'.code -> 13 to p
            in '0'.code..'7'.code -> {
                var v = c - '0'.code
                var n = 1
                while (n < 3 && p < b.size && (b[p].toInt() and 0xFF) in '0'.code..'7'.code) {
                    v = v * 8 + (b[p] - '0'.code.toByte()); p++; n++
                }
                (v and 0xFF) to p
            }
            'x'.code, 'X'.code -> {
                var v = 0
                var n = 0
                while (n < 2 && p < b.size && hexDigit(b[p].toInt() and 0xFF) >= 0) {
                    v = v * 16 + hexDigit(b[p].toInt() and 0xFF); p++; n++
                }
                v to p
            }
            'a'.code -> 7 to p
            'b'.code -> 8 to p
            'f'.code -> 12 to p
            'v'.code -> 11 to p
            'e'.code -> 27 to p
            'd'.code -> '$'.code to p
            else -> c to p
        }
    }

    private fun literal(quote: Int): ByteArray {
        var p = pos + 1
        val res = java.io.ByteArrayOutputStream()
        while (true) {
            if (p >= b.size) err("unterminated literal", line)
            val c = b[p].toInt() and 0xFF
            if (c == quote) { p++; break }
            if (c == '\n'.code) line++
            if (c == '\\'.code && p + 1 < b.size) {
                val (v, np) = escape(p + 1)
                res.write(v); p = np; continue
            }
            if (c == '$'.code) {
                if (p + 1 < b.size && b[p + 1] == '$'.code.toByte()) { res.write('$'.code); p += 2; continue }
                val end = dollarEnd(p)
                if (end > p) { res.write(b, p, end - p + 1); p = end + 1; continue }
            }
            res.write(c); p++
        }
        pos = p
        return res.toByteArray()
    }

    private fun charLit(): DToken {
        val ln = line
        val bytes = literal('\''.code)
        if (bytes.size > 8) err("char constant longer than 8 chars", ln)
        var v = 0L
        for (i in bytes.indices.reversed()) v = (v shl 8) or (bytes[i].toLong() and 0xFF)
        return DToken(DTok.CHAR, "", ln).also { it.ival = v; it.charLen = bytes.size }
    }

    private fun punct(): DToken {
        for (len in 3 downTo 1) {
            if (pos + len > b.size) continue
            val s = DynText.latin1(b, pos, len)
            if (s in PUNCTS) {
                pos += len
                return DToken(DTok.PUNCT, s, line)
            }
        }
        val ch = b[pos].toInt() and 0xFF
        err("unexpected character '${ch.toChar()}' (0x${ch.toString(16)})", line)
    }

    /** The whole text as tokens without macro expansion (macro bodies). */
    internal fun rawTokens(): List<DToken> {
        val res = ArrayList<DToken>()
        while (true) res.add(lexOne() ?: break)
        return res
    }

    companion object {
        val PUNCTS = setOf(
            "<<=", ">>=", "...",
            "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "^^",
            "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::",
            "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<", ">", "=", "(", ")",
            "[", "]", "{", "}", ",", ";", ":", ".", "?", "`", "#", "@", "\\",
        )
    }
}

/**
 * The TempleOS constants an expression may use: the numeric `#define`s of Kernel/KernelA.HH as
 * shipped in shared/runtime/PreludeDefines.HC, with their bodies verbatim (DynExprUnitTest checks them
 * token for token against the interpreter's macro table). They expand exactly as the compiler expands
 * them (`pi` is `(0x400921FB54442D18(F64))`, so `pi*x` and `-I64_MIN` mean what they mean in TempleOS).
 */
object DynMacros {
    /** name -> body text (`\u00EC` and `\u00E3` are CP437's infinity and pi signs, as in KernelA.HH). */
    val TEXT: Map<String, String> = linkedMapOf(
        "NULL" to "0", "TRUE" to "1", "FALSE" to "0", "ON" to "1", "OFF" to "0",
        "I8_MIN" to "(-0x80)", "I8_MAX" to "0x7F", "U8_MIN" to "0", "U8_MAX" to "0xFF",
        "I16_MIN" to "(-0x8000)", "I16_MAX" to "0x7FFF", "U16_MIN" to "0", "U16_MAX" to "0xFFFF",
        "I32_MIN" to "(-0x80000000)", "I32_MAX" to "0x7FFFFFFF", "U32_MIN" to "0", "U32_MAX" to "0xFFFFFFFF",
        "I64_MIN" to "(-0x8000000000000000)", "I64_MAX" to "0x7FFFFFFFFFFFFFFF", "U64_MIN" to "0", "U64_MAX" to "0xFFFFFFFFFFFFFFFF",
        "U64_F64_MAX" to "(0x43F0000000000000(F64))", "F64_MAX" to "(0x7FEFFFFFFFFFFFFF(F64))", "F64_MIN" to "(0xFFEFFFFFFFFFFFFF(F64))",
        "inf" to "(0x7FF0000000000000(F64))", "\u00EC" to "(0x7FF0000000000000(F64))",
        "pi" to "(0x400921FB54442D18(F64))", "\u00E3" to "(0x400921FB54442D18(F64))",
        "exp_1" to "(0x4005BF0A8B145769(F64))", "log2_10" to "(0x400A934F0979A371(F64))", "log2_e" to "(0x3FF71547652B82FE(F64))",
        "log10_2" to "(0x3FD34413509F79FF(F64))", "loge_2" to "(0x3FE62E42FEFA39EF(F64))", "sqrt2" to "(0x3FF6A09E667F3BCD(F64))",
        "eps" to "(0x3CB0000000000000(F64))",
    )

    private val bodies: Map<String, List<DToken>> = TEXT.mapValues { (_, text) ->
        DynLexer(DynText.latin1(text), emptyMap(), "macro").rawTokens()
    }

    fun body(name: String): List<DToken>? = bodies[name]

    /**
     * Names of every macro the TempleOS headers define (from the runtime files, read once): such a name
     * is reported as outside the subset rather than as an undefined identifier.
     */
    @Volatile private var known: Set<String>? = null

    fun isKnownMacro(name: String, runtimeFile: (String) -> ByteArray?): Boolean {
        val k = known ?: synchronized(this) {
            known ?: HashSet<String>().also { set ->
                for (f in listOf("PreludeDefines.HC", "Prelude.HC", "GrLib.HC")) {
                    val text = runtimeFile(f) ?: continue
                    var i = 0
                    while (i < text.size) {
                        var e = i
                        while (e < text.size && text[e] != '\n'.code.toByte()) e++
                        var s = i
                        while (s < e && (text[s] == ' '.code.toByte() || text[s] == '\t'.code.toByte())) s++
                        if (e - s > 8 && DynText.latin1(text, s, 8) == "#define ") {
                            var n = s + 8
                            while (n < e && text[n] == ' '.code.toByte()) n++
                            var ne = n
                            while (ne < e && text[ne] != ' '.code.toByte() && text[ne] != '\t'.code.toByte() && text[ne] != '\r'.code.toByte()) ne++
                            if (ne > n) set.add(DynText.latin1(text, n, ne - n))
                        }
                        i = e + 1
                    }
                }
            }.also { known = it }
        }
        return name in k
    }
}
