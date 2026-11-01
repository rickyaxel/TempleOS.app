package io.github.templeosmobile.core.ui

/** Minimal JSON reader for bundled manifests (objects, arrays, strings, numbers, booleans, null). */
object Json {
    fun parse(s: String): Any? = Reader(s).run { val v = value(); ws(); v }

    private class Reader(val s: String) {
        var i = 0
        /** Nesting depth (the reader is recursive): corrupt input fails cleanly instead of overflowing the stack. */
        var depth = 0
        fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun nested(f: () -> Any?): Any? {
            if (++depth > 512) error("JSON nested too deeply")
            try { return f() } finally { depth-- }
        }
        fun value(): Any? {
            ws()
            if (i >= s.length) error("unexpected end of JSON")
            return when (s[i]) {
                '{' -> nested { obj() }
                '[' -> nested { arr() }
                '"' -> str()
                't' -> { i += 4; true }
                'f' -> { i += 5; false }
                'n' -> { i += 4; null }
                else -> num()
            }
        }
        fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++; ws()
            if (s[i] == '}') { i++; return m }
            while (true) {
                ws(); val k = str(); ws()
                if (s[i++] != ':') error("expected ':' at $i")
                m[k] = value(); ws()
                when (s[i++]) { ',' -> continue; '}' -> return m; else -> error("expected ',' or '}' at $i") }
            }
        }
        fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            i++; ws()
            if (s[i] == ']') { i++; return l }
            while (true) {
                l.add(value()); ws()
                when (s[i++]) { ',' -> continue; ']' -> return l; else -> error("expected ',' or ']' at $i") }
            }
        }
        fun str(): String {
            if (s[i] != '"') error("expected string at $i")
            i++
            val sb = StringBuilder()
            while (s[i] != '"') {
                val c = s[i++]
                if (c == '\\') {
                    when (val e = s[i++]) {
                        'n' -> sb.append('\n'); 't' -> sb.append('\t'); 'r' -> sb.append('\r'); 'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C'); 'u' -> { sb.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                        else -> sb.append(e)
                    }
                } else sb.append(c)
            }
            i++
            return sb.toString()
        }
        fun num(): Number {
            val st = i
            while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
            val t = s.substring(st, i)
            return if (t.contains('.') || t.contains('e') || t.contains('E')) t.toDouble() else t.toLong()
        }
    }
}
