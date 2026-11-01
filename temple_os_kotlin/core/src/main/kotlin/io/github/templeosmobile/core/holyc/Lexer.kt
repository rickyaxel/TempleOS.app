package io.github.templeosmobile.core.holyc

import io.github.templeosmobile.core.Brand

enum class T { IDENT, INT, FLOAT, STR, CHAR, PUNCT, INS_BIN, EOF }

/** Random-access view of a (possibly still being lexed) token stream. */
interface TokenSource {
    operator fun get(i: Int): Token
    val size: Int
}

class Token(
    val kind: T,
    val text: String,          // identifier / punctuator text
    val file: String,
    val line: Int,
) {
    var ival: Long = 0         // INT and CHAR value
    var fval: Double = 0.0
    var bytes: ByteArray? = null // STR contents (without NUL), INS_BIN data
    var charLen = 0            // number of chars in a CHAR literal
    /** True when the token was the first on its source line (used for statement-level heuristics). */
    var lineStart = false
    /** Set on identifiers that came out of a macro expansion. */
    var hidden: Set<String>? = null
    override fun toString() = when (kind) {
        T.STR -> "\"" + latin1(bytes!!) + "\""
        T.INT -> ival.toString()
        T.EOF -> "end of file"
        else -> text
    }
}

/**
 * HolyC tokenizer with the TempleOS preprocessor integrated. Operates on raw
 * DolDoc source bytes (see Source.kt for the DolDoc rules).
 */
/** See Lexer.expandBudget. */
const val MAX_EXPANSION = 1_000_000

class Lexer(
    private val provider: SourceProvider?,
    private val defines: MutableMap<String, List<Token>> = HashMap(),
    /** Answers `#ifdef` for non-macro symbols (functions, globals, classes). */
    private val symbolDefined: (String) -> Boolean = { false },
) {
    private class Input(val src: SourceFile, val dir: String) {
        var pos = 0
        var line = 1
        var atLineStart = true
    }

    private val inputs = ArrayList<Input>()
    private val out = ArrayList<Token>()
    // Conditional compilation stack: each entry = (currently active, some branch taken)
    private val conds = ArrayList<BooleanArray>()

    fun tokenize(src: SourceFile, dir: String): List<Token> {
        val s = stream(src, dir)
        var i = 0
        while (s[i].kind != T.EOF) i++
        return out
    }

    private var eof = false
    private var mainName = ""

    /**
     * Lazily lexed tokens. TempleOS compiles (and the kernel runs) top-level code
     * as it goes, so macros defined at run time (DefinePrint) apply to later code.
     */
    fun stream(src: SourceFile, dir: String): TokenSource {
        inputs.add(Input(src, dir))
        mainName = src.name
        return object : TokenSource {
            override fun get(i: Int): Token {
                while (i >= out.size && !eof) pull()
                return if (i < out.size) out[i] else out[out.size - 1]
            }
            override val size: Int get() = if (eof) out.size else Int.MAX_VALUE
        }
    }

    private fun pull() {
        val before = out.size
        while (out.size == before) {
            val t = rawNext()
            if (t == null) {
                if (conds.isNotEmpty()) throw CompileError("missing #endif", mainName, 0)
                out.add(Token(T.EOF, "", mainName, 0))
                eof = true
                return
            }
            handle(t)
        }
    }

    private fun active() = conds.isEmpty() || conds.last()[0]

    private fun handle(t: Token) {
        if (t.kind == T.PUNCT && t.text == "#") {
            directive(t)
            return
        }
        if (!active()) return
        if (t.kind == T.IDENT) {
            when (t.text) {
                "__DIR__", "__FILE__" -> {
                    val f = t.file
                    val v = if (t.text == "__FILE__") f else f.substringBeforeLast('/', "C:/")
                    out.add(Token(T.STR, "", t.file, t.line).also { it.bytes = latin1(v) }); return
                }
                "__LINE__" -> { out.add(Token(T.INT, "", t.file, t.line).also { it.ival = t.line.toLong() }); return }
            }
            expandBudget = MAX_EXPANSION
            expand(t, emptySet(), out)
            return
        }
        out.add(t)
    }

    /** Tokens one macro use may produce: doubling #define chains would otherwise hang the compiler. */
    private var expandBudget = MAX_EXPANSION

    private fun expand(t: Token, hide: Set<String>, sink: MutableList<Token>) {
        if (--expandBudget < 0) throw CompileError("macro expansion too large", t.file, t.line)
        val body = defines[t.text]
        if (body == null || t.text in hide || (t.hidden?.contains(t.text) == true)) {
            sink.add(t); return
        }
        val h = hide + t.text + (t.hidden ?: emptySet())
        for (b in body) {
            val c = copyTok(b, t)
            if (c.kind == T.IDENT) expand(c, h, sink) else sink.add(c)
        }
    }

    private fun copyTok(b: Token, at: Token): Token {
        val c = Token(b.kind, b.text, at.file, at.line)
        c.ival = b.ival; c.fval = b.fval; c.bytes = b.bytes; c.charLen = b.charLen
        c.lineStart = false
        return c
    }

    // ---------------------------------------------------------------- directives

    private fun restOfLine(): List<Token> {
        val inp = inputs.last()
        val res = ArrayList<Token>()
        val b = inp.src.text
        while (true) {
            skipSpaces(inp, stopAtNewline = true)
            // backslash-newline continues a directive on the next line (Apps/KeepAway)
            if (inp.pos < b.size && b[inp.pos] == '\\'.code.toByte()) {
                var q = inp.pos + 1
                while (q < b.size && (b[q] == ' '.code.toByte() || b[q] == '\t'.code.toByte() || b[q] == '\r'.code.toByte())) q++
                if (q < b.size && b[q] == '\n'.code.toByte()) { inp.pos = q + 1; inp.line++; continue }
            }
            if (inp.pos >= b.size || b[inp.pos] == '\n'.code.toByte()) break
            val t = lexOne(inp) ?: break
            res.add(t)
        }
        return res
    }

    private fun directive(hash: Token) {
        val inp = inputs.last()
        skipSpaces(inp, stopAtNewline = true)
        val nameTok = lexOne(inp) ?: throw CompileError("bad directive", hash.file, hash.line)
        val name = nameTok.text
        when (name) {
            "ifdef", "ifndef" -> {
                val id = restOfLine().firstOrNull()?.text ?: ""
                val def = defines.containsKey(id) || symbolDefined(id)
                pushCond(if (name == "ifdef") def else !def)
            }
            "if" -> {
                val toks = restOfLine()
                pushCond(if (active()) evalCond(toks, hash) else false)
            }
            "ifjit" -> { restOfLine(); pushCond(true) }
            "ifaot" -> { restOfLine(); pushCond(false) }
            "else" -> {
                restOfLine()
                val c = conds.lastOrNull() ?: throw CompileError("#else without #if", hash.file, hash.line)
                val parentActive = conds.size < 2 || conds[conds.size - 2][0]
                c[0] = parentActive && !c[1]
                c[1] = true
            }
            "endif" -> {
                restOfLine()
                if (conds.isEmpty()) throw CompileError("#endif without #if", hash.file, hash.line)
                conds.removeAt(conds.size - 1)
            }
            else -> {
                if (!active()) { restOfLine(); return }
                when (name) {
                    "define" -> {
                        val toks = restOfLine()
                        if (toks.isEmpty()) throw CompileError("#define needs a name", hash.file, hash.line)
                        defines[toks[0].text] = toks.subList(1, toks.size).toList()
                    }
                    "undef" -> restOfLine().firstOrNull()?.let { defines.remove(it.text) }
                    "include" -> {
                        val toks = restOfLine()
                        val f = toks.firstOrNull()
                        if (f == null || f.kind != T.STR) throw CompileError("#include needs a \"file\"", hash.file, hash.line)
                        include(latin1(f.bytes!!), hash)
                    }
                    "help_index", "help_file", "assert", "pragma" -> restOfLine()
                    "exe" -> throw CompileError(
                        "#exe {} (compile-time code execution) is not supported by ${Brand.APP_NAME}",
                        hash.file, hash.line)
                    else -> throw CompileError("unknown directive #$name", hash.file, hash.line)
                }
            }
        }
    }

    private fun pushCond(v: Boolean) {
        val parentActive = active()
        conds.add(booleanArrayOf(parentActive && v, v))
    }

    private fun include(path: String, at: Token) {
        if (inputs.size > 16) throw CompileError("#include nested too deeply", at.file, at.line)
        val cur = inputs.last()
        val full = resolvePath(cur.dir, path)
        // TempleOS adds a default extension when none is given
        val candidates = if (full.substringAfterLast('/').contains('.')) listOf(full, "$full.Z")
            else listOf("$full.HC", "$full.HH", "$full.HC.Z", full)
        var data: ByteArray? = null
        var found = full
        for (c in candidates) { data = provider?.read(c); if (data != null) { found = c; break } }
        if (data == null) throw CompileError("#include file not found: $path", at.file, at.line)
        val dir = found.substringBeforeLast('/', "C:")
        inputs.add(Input(SourceFile.parse(found, data), dir))
    }

    private fun evalCond(toks: List<Token>, at: Token): Boolean {
        val expanded = ArrayList<Token>()
        for (t in toks) if (t.kind == T.IDENT) { expandBudget = MAX_EXPANSION; expand(t, emptySet(), expanded) } else expanded.add(t)
        return try {
            ConstEval(expanded).eval() != 0L
        } catch (e: Exception) {
            throw CompileError("cannot evaluate #if expression", at.file, at.line)
        }
    }

    // ---------------------------------------------------------------- raw lexing

    /** Next raw token across include boundaries, or null at end of the main file. */
    private fun rawNext(): Token? {
        while (inputs.isNotEmpty()) {
            val inp = inputs.last()
            val t = lexOne(inp)
            if (t != null) return t
            inputs.removeAt(inputs.size - 1)
        }
        return null
    }

    private fun skipSpaces(inp: Input, stopAtNewline: Boolean) {
        val b = inp.src.text
        while (inp.pos < b.size) {
            val c = b[inp.pos].toInt() and 0xFF
            when {
                c == '\n'.code -> {
                    if (stopAtNewline) return
                    inp.line++; inp.pos++; inp.atLineStart = true
                }
                c == ' '.code || c == '\t'.code || c == '\r'.code || c == 0x0C || c == 5 || c == 31 -> inp.pos++
                c == '/'.code && inp.pos + 1 < b.size && b[inp.pos + 1] == '/'.code.toByte() -> {
                    while (inp.pos < b.size && b[inp.pos] != '\n'.code.toByte()) inp.pos++
                }
                c == '/'.code && inp.pos + 1 < b.size && b[inp.pos + 1] == '*'.code.toByte() -> {
                    inp.pos += 2
                    var depth = 1 // TempleOS allows nested /* */ comments
                    while (inp.pos < b.size && depth > 0) {
                        val d = b[inp.pos].toInt()
                        if (d == '\n'.code) inp.line++
                        if (d == '*'.code && inp.pos + 1 < b.size && b[inp.pos + 1] == '/'.code.toByte()) {
                            depth--; inp.pos += 2; continue
                        }
                        if (d == '/'.code && inp.pos + 1 < b.size && b[inp.pos + 1] == '*'.code.toByte()) {
                            depth++; inp.pos += 2; continue
                        }
                        inp.pos++
                    }
                }
                c == '$'.code -> {
                    // DolDoc command in code context
                    val end = dollarEnd(b, inp.pos)
                    if (end < 0) { inp.pos++; continue }
                    if (end == inp.pos + 1) { inp.pos += 2; continue } // "$$" in code: ignore
                    val cmd = latin1(b, inp.pos + 1, end - inp.pos - 1)
                    val code = cmd.take(2)
                    if (code == "IB" || code == "IS" || code == "TX") return // handled by lexOne
                    inp.pos = end + 1
                }
                else -> return
            }
        }
    }

    /** Index of the `$` closing a DolDoc command starting at [p], or -1. */
    private fun dollarEnd(b: ByteArray, p: Int): Int {
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

    private fun lexOne(inp: Input): Token? {
        skipSpaces(inp, stopAtNewline = false)
        val b = inp.src.text
        if (inp.pos >= b.size) return null
        val start = inp.pos
        val c = b[start].toInt() and 0xFF
        val first = inp.atLineStart
        inp.atLineStart = false
        val tok: Token
        when {
            c == '$'.code -> tok = dollarToken(inp)
            isIdStart(c) -> {
                var p = start + 1
                var seg = start
                val name = StringBuilder()
                while (true) {
                    while (p < b.size && isIdChar(b[p].toInt() and 0xFF)) p++
                    // A DolDoc formatting command inside an identifier (e.g. θ$SY,3$n$SY,0$
                    // in Demo/Graphics/LightTable.HC) is not part of the text TempleOS lexes:
                    // skip it and continue the identifier.
                    if (p < b.size && b[p] == '$'.code.toByte()) {
                        val end = dollarEnd(b, p)
                        if (end > p + 1 && end + 1 < b.size && isIdChar(b[end + 1].toInt() and 0xFF)) {
                            val code = latin1(b, p + 1, minOf(2, end - p - 1))
                            if (code != "IB" && code != "IS" && code != "TX") {
                                name.append(latin1(b, seg, p - seg)); p = end + 1; seg = p; continue
                            }
                        }
                    }
                    break
                }
                name.append(latin1(b, seg, p - seg))
                tok = Token(T.IDENT, name.toString(), inp.src.name, inp.line)
                inp.pos = p
            }
            c in '0'.code..'9'.code || (c == '.'.code && start + 1 < b.size && (b[start + 1].toInt() and 0xFF) in '0'.code..'9'.code) ->
                tok = number(inp)
            c == '"'.code -> tok = string(inp)
            c == '\''.code -> tok = charLit(inp)
            else -> tok = punct(inp)
        }
        tok.lineStart = first
        return tok
    }

    /** DolDoc BP imports a sprite by number or tag from another source document. */
    private fun binaryData(inp: Input, cmd: String, bi: Int?): ByteArray? {
        val bp = Regex("""BP="([^"]+)"""").find(cmd)?.groupValues?.get(1)
            ?: return bi?.let { inp.src.bins[it] }
        val comma = bp.lastIndexOf(',')
        if (comma < 1) return null
        val full = resolvePath(inp.dir, bp.substring(0, comma))
        val ref = bp.substring(comma + 1)
        val candidates = if (full.substringAfterLast('/').contains('.')) listOf(full, "$full.Z")
            else listOf("$full.HC", "$full.HH", "$full.HC.Z", full)
        for (path in candidates) {
            val raw = provider?.read(path) ?: continue
            val source = SourceFile.parse(path, raw)
            val num = ref.toIntOrNull() ?: Regex(Regex.escape("\$SP") + """[^\n$]*,"${Regex.escape(ref)}"[^\n$]*BI=(\d+)""")
                .find(latin1(source.text))?.groupValues?.get(1)?.toIntOrNull()
            return num?.let { source.bins[it] }
        }
        return null
    }

    private fun dollarToken(inp: Input): Token {
        val b = inp.src.text
        val end = dollarEnd(b, inp.pos)
        val cmd = latin1(b, inp.pos + 1, end - inp.pos - 1)
        inp.pos = end + 1
        val code = cmd.take(2)
        val bi = Regex("BI=(\\d+)").find(cmd)?.groupValues?.get(1)?.toInt()
        return when (code) {
            "IB" -> {
                val data = binaryData(inp, cmd, bi)
                    ?: throw CompileError("missing binary attachment in $$cmd$", inp.src.name, inp.line)
                Token(T.INS_BIN, "<bin>", inp.src.name, inp.line).also { it.bytes = data }
            }
            "IS" -> {
                val data = binaryData(inp, cmd, bi)
                Token(T.INT, "", inp.src.name, inp.line).also { it.ival = (data?.size ?: 0).toLong() }
            }
            else -> { // TX: literal text; tokenise it in place
                val m = Regex("^TX[^\"]*\"((?:[^\"\\\\]|\\\\.)*)\"").find(cmd)
                val txt = m?.groupValues?.get(1) ?: ""
                val sub = Lexer(null, defines).tokenizeFragment(txt, inp.src.name, inp.line)
                // Only single-token text entries are meaningful in code; otherwise return first.
                sub.firstOrNull() ?: Token(T.PUNCT, ";", inp.src.name, inp.line)
            }
        }
    }

    internal fun tokenizeFragment(s: String, file: String, line: Int): List<Token> {
        val inp = Input(SourceFile.ofString(file, s), "")
        inp.line = line
        val res = ArrayList<Token>()
        while (true) res.add(lexOne(inp) ?: break)
        return res
    }

    private fun isIdStart(c: Int) = c in 'A'.code..'Z'.code || c in 'a'.code..'z'.code || c == '_'.code || c >= 128
    private fun isIdChar(c: Int) = isIdStart(c) || c in '0'.code..'9'.code

    private fun number(inp: Input): Token {
        val b = inp.src.text
        var p = inp.pos
        val tok: Token
        if (b[p] == '0'.code.toByte() && p + 1 < b.size && (b[p + 1] == 'x'.code.toByte() || b[p + 1] == 'X'.code.toByte())) {
            p += 2
            var v = 0L
            while (p < b.size) {
                val d = Character.digit(b[p].toInt() and 0xFF, 16)
                if (d < 0) break
                v = (v shl 4) or d.toLong(); p++
            }
            tok = Token(T.INT, "", inp.src.name, inp.line); tok.ival = v
        } else if (b[p] == '0'.code.toByte() && p + 1 < b.size && (b[p + 1] == 'b'.code.toByte() || b[p + 1] == 'B'.code.toByte())) {
            p += 2
            var v = 0L
            while (p < b.size && (b[p] == '0'.code.toByte() || b[p] == '1'.code.toByte())) {
                v = (v shl 1) or (b[p] - '0'.code.toByte()).toLong(); p++
            }
            tok = Token(T.INT, "", inp.src.name, inp.line); tok.ival = v
        } else {
            val s = p
            while (p < b.size && b[p] in '0'.code.toByte()..'9'.code.toByte()) p++
            var isFloat = false
            if (p < b.size && b[p] == '.'.code.toByte() && !(p + 1 < b.size && b[p + 1] == '.'.code.toByte())) {
                isFloat = true; p++
                while (p < b.size && b[p] in '0'.code.toByte()..'9'.code.toByte()) p++
            }
            if (p < b.size && (b[p] == 'e'.code.toByte() || b[p] == 'E'.code.toByte())) {
                var q = p + 1
                if (q < b.size && (b[q] == '-'.code.toByte() || b[q] == '+'.code.toByte())) q++
                if (q < b.size && b[q] in '0'.code.toByte()..'9'.code.toByte()) {
                    isFloat = true
                    p = q
                    while (p < b.size && b[p] in '0'.code.toByte()..'9'.code.toByte()) p++
                }
            }
            val str = latin1(b, s, p - s)
            if (isFloat) {
                tok = Token(T.FLOAT, str, inp.src.name, inp.line); tok.fval = str.toDouble()
            } else {
                tok = Token(T.INT, str, inp.src.name, inp.line)
                tok.ival = try { java.lang.Long.parseUnsignedLong(str.ifEmpty { "0" }) }
                    catch (e: NumberFormatException) { throw CompileError("integer constant too large: $str", inp.src.name, inp.line) }
            }
        }
        inp.pos = p
        return tok
    }

    /** Reads an escape after a backslash at b[p]; returns (byte, newPos). */
    private fun escape(b: ByteArray, p0: Int): Pair<Int, Int> {
        var p = p0
        val c = b[p].toInt() and 0xFF
        p++
        return when (c) {
            'n'.code -> 10 to p
            't'.code -> 9 to p
            'r'.code -> 13 to p
            '0'.code, '1'.code, '2'.code, '3'.code, '4'.code, '5'.code, '6'.code, '7'.code -> {
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
                while (n < 2 && p < b.size && Character.digit(b[p].toInt() and 0xFF, 16) >= 0) {
                    v = v * 16 + Character.digit(b[p].toInt() and 0xFF, 16); p++; n++
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

    /** Appends literal content handling escapes and DolDoc ($$ -> $, $..$ kept). */
    private fun literal(inp: Input, quote: Int): ByteArray {
        val b = inp.src.text
        var p = inp.pos + 1
        val res = java.io.ByteArrayOutputStream()
        while (true) {
            if (p >= b.size) throw CompileError("unterminated literal", inp.src.name, inp.line)
            val c = b[p].toInt() and 0xFF
            if (c == quote) { p++; break }
            if (c == '\n'.code) inp.line++
            if (c == '\\'.code && p + 1 < b.size) {
                val (v, np) = escape(b, p + 1)
                res.write(v); p = np; continue
            }
            if (c == '$'.code) {
                if (p + 1 < b.size && b[p + 1] == '$'.code.toByte()) { res.write('$'.code); p += 2; continue }
                val end = dollarEnd(b, p)
                if (end > p) { res.write(b, p, end - p + 1); p = end + 1; continue }
            }
            res.write(c); p++
        }
        inp.pos = p
        return res.toByteArray()
    }

    private fun string(inp: Input): Token {
        val line = inp.line
        val bytes = literal(inp, '"'.code)
        return Token(T.STR, "", inp.src.name, line).also { it.bytes = bytes }
    }

    private fun charLit(inp: Input): Token {
        val line = inp.line
        val bytes = literal(inp, '\''.code)
        if (bytes.size > 8) throw CompileError("char constant longer than 8 chars", inp.src.name, line)
        var v = 0L
        for (i in bytes.indices.reversed()) v = (v shl 8) or (bytes[i].toLong() and 0xFF)
        return Token(T.CHAR, "", inp.src.name, line).also { it.ival = v; it.charLen = bytes.size }
    }

    private fun punct(inp: Input): Token {
        val b = inp.src.text
        for (len in 3 downTo 1) {
            if (inp.pos + len > b.size) continue
            val s = latin1(b, inp.pos, len)
            if (s in PUNCTS) {
                inp.pos += len
                return Token(T.PUNCT, s, inp.src.name, inp.line)
            }
        }
        val ch = b[inp.pos].toInt() and 0xFF
        throw CompileError("unexpected character '${ch.toChar()}' (0x${ch.toString(16)})", inp.src.name, inp.line)
    }

    companion object {
        val PUNCTS = setOf(
            "<<=", ">>=", "...",
            "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "^^",
            "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::",
            "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<", ">", "=", "(", ")",
            "[", "]", "{", "}", ",", ";", ":", ".", "?", "`", "#", "@", "\\",
        )

        fun resolvePath(dir: String, path: String): String {
            var p = path.replace('\\', '/')
            p = when {
                p.startsWith("::/") -> "C:" + p.substring(2)
                p.length >= 2 && p[1] == ':' -> p.substring(0, 1).uppercase() + p.substring(1)
                p.startsWith("~/") -> "C:/Home" + p.substring(1)
                p.startsWith("/") -> "C:$p"
                else -> "$dir/$p"
            }
            val parts = ArrayList<String>()
            val drive = p.substring(0, 2)
            for (seg in p.substring(2).split('/')) {
                when (seg) {
                    "", "." -> {}
                    ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.size - 1)
                    else -> parts.add(seg)
                }
            }
            return drive + "/" + parts.joinToString("/")
        }
    }
}

/** Minimal constant-expression evaluator for `#if`. */
private class ConstEval(val t: List<Token>) {
    var i = 0
    fun eval(): Long = or()
    private fun peek() = if (i < t.size) t[i].text else ""
    private fun or(): Long { var v = and(); while (peek() == "||") { i++; val r = and(); v = if (v != 0L || r != 0L) 1 else 0 }; return v }
    private fun and(): Long { var v = cmp(); while (peek() == "&&") { i++; val r = cmp(); v = if (v != 0L && r != 0L) 1 else 0 }; return v }
    private fun cmp(): Long {
        var v = add()
        while (peek() in setOf("==", "!=", "<", ">", "<=", ">=")) {
            val op = t[i++].text; val r = add()
            v = when (op) { "==" -> v == r; "!=" -> v != r; "<" -> v < r; ">" -> v > r; "<=" -> v <= r; else -> v >= r }.let { if (it) 1L else 0L }
        }
        return v
    }
    private fun add(): Long {
        var v = mul()
        while (peek() == "+" || peek() == "-" || peek() == "|" || peek() == "&") {
            val op = t[i++].text; val r = mul()
            v = when (op) { "+" -> v + r; "-" -> v - r; "|" -> v or r; else -> v and r }
        }
        return v
    }
    private fun mul(): Long {
        var v = un()
        while (peek() == "*" || peek() == "/" || peek() == "<<" || peek() == ">>") {
            val op = t[i++].text; val r = un()
            v = when (op) { "*" -> v * r; "/" -> v / r; "<<" -> v shl r.toInt(); else -> v shr r.toInt() }
        }
        return v
    }
    private fun un(): Long {
        val tk = t[i++]
        return when {
            tk.text == "!" -> if (un() == 0L) 1 else 0
            tk.text == "-" -> -un()
            tk.text == "(" -> { val v = or(); i++; v }
            tk.kind == T.INT || tk.kind == T.CHAR -> tk.ival
            tk.text == "TRUE" -> 1
            tk.text == "FALSE" -> 0
            else -> 0
        }
    }
}
