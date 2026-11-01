package io.github.templeosmobile.core.holyc

import java.io.ByteArrayOutputStream

/**
 * Port of TempleOS `StrPrintJoin` (Kernel/StrPrint.HC, public domain).
 * Formats [fmt] with raw 64-bit arguments exactly as TempleOS does, including
 * its quirks (e.g. `%f` without a precision rounds to an integer).
 */
class Formatter(private val mem: Arena) {
    private companion object {
        const val LEFT = 1; const val PAD_ZERO = 2; const val DECIMAL = 4; const val DOLLAR = 8
        const val SLASH = 16; const val COMMA = 32; const val TRUNCATE = 64; const val AUX = 128
        const val QUESTION = 256; const val NEG_AUX = 512; const val NEG = 1024; const val NEG_E = 2048
        const val POS_LETS = " KMGTPEZY"
        val NEG_LETS = byteArrayOf(' '.code.toByte(), 'm'.code.toByte(), 0xE6.toByte(), 'n'.code.toByte(),
            'p'.code.toByte(), 'f'.code.toByte(), 'a'.code.toByte(), 'z'.code.toByte(), 'y'.code.toByte())
        val STR_PRINT = chCode("StrPrint")
        /** Largest field width, precision or repeat count honoured. */
        const val MAX_FIELD = 1L shl 20
        /** Largest formatted string (bytes). */
        const val MAX_OUT = 16 shl 20
    }

    /** Hook for %p/%P symbol names (address -> text), %D/%T dates. */
    var symbolName: (Long) -> String? = { null }
    /** %Z: entry [sub] of the DEFINE list named by the string at [nameAddr] (TempleOS DefineSub). */
    var defineSub: (Long, Long) -> ByteArray? = { _, _ -> null }

    fun format(fmt: ByteArray, args: LongArray, argBase: Int, argc: Int): ByteArray {
        val out = ByteArrayOutputStream(fmt.size + 16)
        var fi = 0
        var cur = 0
        fun arg(): Long {
            if (cur >= argc) throw VmFault(STR_PRINT, "not enough arguments for format")
            return args[argBase + cur++]
        }
        fun at(i: Int): Int = if (i < fmt.size) fmt[i].toInt() and 0xFF else 0
        val tmp = ByteArray(512)
        while (fi < fmt.size) {
            if (out.size() > MAX_OUT) tooLong()
            val ch = at(fi++)
            if (ch == 0) break
            if (ch != '%'.code) { out.write(ch); continue }
            var flags = 0
            if (at(fi) == '-'.code) { flags = flags or LEFT; fi++ }
            if (at(fi) == '0'.code) { flags = flags or PAD_ZERO; fi++ }
            var len = 0L
            while (at(fi) in '0'.code..'9'.code) len = len * 10 + (at(fi++) - '0'.code)
            if (at(fi) == '*'.code) { fi++; len = arg() }
            var decLen = 0L
            if (at(fi) == '.'.code) {
                fi++
                while (at(fi) in '0'.code..'9'.code) decLen = decLen * 10 + (at(fi++) - '0'.code)
                if (at(fi) == '*'.code) { fi++; decLen = arg() }
                flags = flags or DECIMAL
            }
            // program-supplied widths and repeat counts are bounded (they could hang or exhaust host memory)
            len = len.coerceAtMost(MAX_FIELD); decLen = decLen.coerceAtMost(MAX_FIELD)
            var aux = 0L
            loop@ while (true) {
                when (at(fi)) {
                    '$'.code -> { flags = flags or DOLLAR; fi++ }
                    '/'.code -> { flags = flags or SLASH; fi++ }
                    ','.code -> { flags = flags or COMMA; fi++ }
                    't'.code -> { flags = flags or TRUNCATE; fi++ }
                    'l'.code -> fi++
                    'h'.code -> {
                        fi++
                        flags = flags or AUX
                        if (at(fi) == '?'.code) { fi++; flags = flags or QUESTION }
                        else if (at(fi) == '*'.code) { fi++; aux = arg() }
                        else {
                            if (at(fi) == '-'.code) { fi++; flags = flags or NEG_AUX }
                            while (at(fi) in '0'.code..'9'.code) aux = aux * 10 + (at(fi++) - '0'.code)
                            if (flags and NEG_AUX != 0) aux = -aux
                        }
                    }
                    else -> break@loop
                }
            }
            var k = 0
            val code = at(fi++)
            when (code) {
                'Q'.code -> outStr(out, mprintQ(mem.readStrBytes(arg()), flags), len, flags)
                'q'.code -> outStr(out, mprintq(mem.readStrBytes(arg())), len, flags)
                'D'.code -> outStr(out, latin1(dateStr(arg())), len, flags)
                'T'.code -> outStr(out, latin1(timeStr(arg())), len, flags)
                'F'.code -> { arg(); outStr(out, ByteArray(0), len, flags) }
                's'.code -> outStr(out, mem.readStrBytes(arg()), len, flags)
                'S'.code -> { arg(); outStr(out, ByteArray(0), len, flags) }
                'z'.code -> {
                    val sub = arg(); val lst = arg()
                    outStr(out, lstSub(sub, lst), len, flags)
                }
                'Z'.code -> {
                    val sub = arg(); val name = arg()
                    outStr(out, defineSub(sub, name) ?: ByteArray(0), len, flags)
                }
                'c'.code, 'C'.code -> {
                    val v = arg()
                    val b = ArrayList<Byte>()
                    for (i in 0 until 8) {
                        var c = ((v ushr (8 * i)) and 0xFF).toInt()
                        if (c == 0) break
                        if (code == 'C'.code && c in 'a'.code..'z'.code) c -= 32
                        b.add(c.toByte())
                    }
                    if (flags and AUX == 0) aux = 1
                    val bytes = b.toByteArray()
                    if (aux > MAX_FIELD) aux = MAX_FIELD
                    while (aux-- > 0) { outStr(out, bytes, len, flags); if (out.size() > MAX_OUT) tooLong() }
                }
                'p'.code, 'P'.code -> {
                    val v = arg()
                    val s = symbolName(v) ?: ("0x" + java.lang.Long.toHexString(v).uppercase().padStart(8, '0'))
                    outStr(out, latin1(s), len, flags)
                }
                'd'.code, 'u'.code -> {
                    var m = arg()
                    if (code == 'd'.code && m < 0) { flags = flags or NEG; m = -m }
                    if (flags and AUX != 0) {
                        if (len == 0L) len = 12
                        val d = u2f(m)
                        k = engineering(tmp, d, flags, len, decLen, aux, out)
                        continue
                    }
                    if (flags and COMMA != 0) {
                        var cc = 3
                        while (true) {
                            tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte()
                            m = java.lang.Long.divideUnsigned(m, 10)
                            if (m == 0L) break
                            if (--cc == 0) { tmp[k++] = ','.code.toByte(); cc = 3 }
                        }
                        outCommaNum(out, tmp, k, len, flags, 3, cc)
                    } else {
                        while (true) {
                            tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte()
                            m = java.lang.Long.divideUnsigned(m, 10)
                            if (m == 0L) break
                        }
                        outNum(out, tmp, k, len, flags)
                    }
                }
                'f'.code -> {
                    var d = d(arg())
                    if (d < 0) { flags = flags or NEG; d = -d }
                    if (d == Double.POSITIVE_INFINITY) { outInf(out, len, flags); continue }
                    outF(out, tmp, 0, d, decLen, flags, len)
                }
                'e'.code -> {
                    if (len == 0L) len = 12
                    flags = flags or TRUNCATE
                    var d = d(arg())
                    if (d < 0) { flags = flags or NEG; d = -d }
                    if (d == Double.POSITIVE_INFINITY) { outInf(out, len, flags); continue }
                    val n = if (d != 0.0) f2i(Math.floor(StrictMath.log10(d))) else 0
                    outE(out, tmp, d, n, flags, len)
                }
                'g'.code -> {
                    if (len == 0L) len = 12
                    flags = flags or TRUNCATE
                    var d = d(arg())
                    if (d < 0) { flags = flags or NEG; d = -d }
                    if (d == Double.POSITIVE_INFINITY) { outInf(out, len, flags); continue }
                    val n = if (d != 0.0) f2i(Math.floor(StrictMath.log10(d))) else 0
                    if (n >= len - 1 - decLen || n < -(decLen - 1)) outE(out, tmp, d, n, flags, len)
                    else outF(out, tmp, 0, d, decLen, flags, len)
                }
                'n'.code -> {
                    if (len == 0L) len = 12
                    flags = flags or TRUNCATE
                    var d = d(arg())
                    if (d < 0) { flags = flags or NEG; d = -d }
                    engineering(tmp, d, flags, len, decLen, aux, out)
                }
                'X'.code, 'x'.code -> {
                    var m = arg()
                    val base = if (code == 'X'.code) 'A'.code else 'a'.code
                    if (flags and COMMA != 0) {
                        var cc = 4
                        while (true) {
                            val dgt = (m and 15).toInt()
                            tmp[k++] = (if (dgt < 10) '0'.code + dgt else base + dgt - 10).toByte()
                            m = m ushr 4
                            if (m == 0L) break
                            if (--cc == 0) { tmp[k++] = ','.code.toByte(); cc = 4 }
                        }
                        outCommaNum(out, tmp, k, len, flags, 4, cc)
                    } else {
                        do {
                            val dgt = (m and 15).toInt()
                            tmp[k++] = (if (dgt < 10) '0'.code + dgt else base + dgt - 10).toByte()
                            m = m ushr 4
                        } while (m != 0L)
                        outNum(out, tmp, k, len, flags)
                    }
                }
                'b'.code, 'B'.code -> {
                    var m = arg()
                    if (flags and COMMA != 0) {
                        var cc = 4
                        while (true) {
                            tmp[k++] = ('0'.code + (m and 1).toInt()).toByte()
                            m = m ushr 1
                            if (m == 0L) break
                            if (--cc == 0) { tmp[k++] = ','.code.toByte(); cc = 4 }
                        }
                        outCommaNum(out, tmp, k, len, flags, 4, cc)
                    } else {
                        do { tmp[k++] = ('0'.code + (m and 1).toInt()).toByte(); m = m ushr 1 } while (m != 0L)
                        outNum(out, tmp, k, len, flags)
                    }
                }
                '%'.code -> out.write('%'.code)
                0 -> {}
                else -> {}
            }
        }
        return out.toByteArray()
    }

    private fun tooLong(): Nothing = throw VmFault(Arena.OUT_MEM, "formatted string longer than ${MAX_OUT shr 20} MiB")

    private fun outStr(out: ByteArrayOutputStream, s: ByteArray, len: Long, flags: Int) {
        var i = s.size.toLong()
        if (flags and TRUNCATE != 0 && i > len) i = len
        if (i < 0) i = 0
        if (flags and LEFT != 0) {
            out.write(s, 0, i.toInt())
            var j = 0L; while (j < len - i) { out.write(' '.code); j++ }
        } else {
            var j = 0L; while (j < len - i) { out.write(' '.code); j++ }
            out.write(s, 0, i.toInt())
        }
    }

    private fun outInf(out: ByteArrayOutputStream, len0: Long, flags: Int) {
        var i = if (flags and NEG != 0) 1L else 0L
        var k = 1L
        val len = if (len0 < 0) 0 else len0
        if (flags and TRUNCATE != 0 && k + i > len) k = len - i
        if (k < 0) k = 0
        while (i < len - k) { out.write(' '.code); i++ }
        if (flags and NEG != 0) out.write('-'.code)
        for (x in 0 until k) out.write(0xEC) // CP437 infinity
    }

    private fun outNum(out: ByteArrayOutputStream, tmp: ByteArray, k0: Int, len0: Long, flags: Int) {
        var k = k0.toLong()
        var i = if (flags and NEG != 0) 1L else 0L
        val len = if (len0 < 0) 0 else len0
        if (flags and TRUNCATE != 0 && k + i > len) k = len - i
        if (k < 0) k = 0
        if (flags and PAD_ZERO != 0) {
            if (flags and NEG != 0) out.write('-'.code)
            while (i < len - k) { out.write('0'.code); i++ }
        } else {
            while (i < len - k) { out.write(' '.code); i++ }
            if (flags and NEG != 0) out.write('-'.code)
        }
        var j = k - 1
        while (j >= 0) { out.write(tmp[j.toInt()].toInt()); j-- }
    }

    private fun outCommaNum(out: ByteArrayOutputStream, tmp: ByteArray, k0: Int, len0: Long, flags: Int, cfc: Int, cc0: Int) {
        var k = k0.toLong()
        var i = if (flags and NEG != 0) 1L else 0L
        val len = if (len0 < 0) 0 else len0
        if (flags and TRUNCATE != 0 && k + i > len) k = len - i
        if (k < 0) k = 0
        if (flags and PAD_ZERO != 0) {
            if (flags and NEG != 0) out.write('-'.code)
            var cc = ((len - k - i + cfc - cc0 + 1) % (cfc + 1) + 1)
            while (i < len - k) {
                if (--cc == 0L) {
                    out.write(','.code)
                    cc = cfc.toLong()
                    if (++i >= len - k) break
                }
                out.write('0'.code)
                i++
            }
        } else {
            while (i < len - k) { out.write(' '.code); i++ }
            if (flags and NEG != 0) out.write('-'.code)
        }
        var j = k - 1
        while (j >= 0) { out.write(tmp[j.toInt()].toInt()); j-- }
    }

    private fun pow10(i: Long): Double = when {
        i > 308 -> Double.POSITIVE_INFINITY
        i < -308 -> 0.0
        else -> "1e$i".toDouble()
    }

    /** sp_out_f: tmp already holds k chars (exponent suffix, reversed). */
    private fun outF(out: ByteArrayOutputStream, tmp: ByteArray, k0: Int, d0: Double, decLen0: Long, flags: Int, len: Long) {
        var k = k0
        var d = d0
        val decLen = if (decLen0 < 0) 0 else decLen0
        var n = f2i(StrictMath.log10(d))
        var i: Long
        if (decLen != 0L) {
            i = decLen
            if (flags and COMMA != 0) i -= i / 4
            if (n + i > 17) { n += i - 17; d *= pow10(i - n) } else { n = 0; d *= pow10(i) }
            i = decLen
        } else if (n > 17) {
            n -= 17; d *= pow10(-n); i = 0
        } else { n = 0; i = 0 }
        var m = f2u(Math.rint(d))
        if (flags and COMMA != 0) {
            var cc = (i and 3)
            while (i-- != 0L && k < tmp.size - 20) {
                if (i > 2 && cc-- == 0L) {
                    tmp[k++] = ','.code.toByte()
                    cc = 2
                    if (--i == 0L) break
                }
                if (n != 0L) { n--; tmp[k++] = '0'.code.toByte() }
                else { tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte(); m = java.lang.Long.divideUnsigned(m, 10) }
                if (i == 0L) break
            }
        } else {
            while (i-- != 0L && k < tmp.size - 20) {
                if (n != 0L) { n--; tmp[k++] = '0'.code.toByte() }
                else { tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte(); m = java.lang.Long.divideUnsigned(m, 10) }
            }
        }
        if (decLen != 0L) tmp[k++] = '.'.code.toByte()
        if (flags and COMMA != 0) {
            var cc = 3
            while (k < tmp.size - 20) {
                if (n != 0L) { n--; tmp[k++] = '0'.code.toByte() }
                else { tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte(); m = java.lang.Long.divideUnsigned(m, 10) }
                if (m == 0L) break
                if (--cc == 0) { tmp[k++] = ','.code.toByte(); cc = 3 }
            }
        } else {
            while (k < tmp.size - 20) {
                if (n != 0L) { n--; tmp[k++] = '0'.code.toByte() }
                else { tmp[k++] = ('0'.code + java.lang.Long.remainderUnsigned(m, 10).toInt()).toByte(); m = java.lang.Long.divideUnsigned(m, 10) }
                if (m == 0L) break
            }
        }
        outNum(out, tmp, k, len, flags)
    }

    private fun f2u(x: Double): Long = if (x >= 9.223372036854775807E18) (x - 9.223372036854775808E18).toLong() + Long.MIN_VALUE else f2i(x)

    private fun outE(out: ByteArrayOutputStream, tmp: ByteArray, d0: Double, n0: Long, flags0: Int, len: Long) {
        var d = d0
        var n = n0
        var flags = flags0
        d /= pow10(n)
        var k = 0
        var decLen = 0L
        for (l in 0 until 2) {
            val nn = n
            var e = n
            if (e < 0) { e = -e; flags = flags or NEG_E } else flags = flags and NEG_E.inv()
            var i = 3
            do { tmp[k++] = ('0'.code + (e % 10).toInt()).toByte(); e /= 10 } while (e != 0L && i-- != 0)
            if (flags and NEG_E != 0) tmp[k++] = '-'.code.toByte()
            tmp[k++] = 'e'.code.toByte()
            decLen = len - k - 2
            if (flags and NEG != 0) decLen--
            if (d != 0.0) {
                val d1 = d + pow10(-decLen) / 2
                if (d1 < 1.0) { d *= 10; n = nn - 1; k = 0 }
                else if (d1 >= 10) { d /= 10; n = nn + 1; k = 0 }
                else break
            } else break
        }
        outF(out, tmp, k, d, decLen, flags, len)
    }

    private fun engineering(tmp: ByteArray, d0: Double, flags0: Int, len: Long, decLen0: Long, aux: Long, out: ByteArrayOutputStream): Int {
        var d = d0
        var flags = flags0
        var decLen = decLen0
        var k = 0
        if (d == Double.POSITIVE_INFINITY) { outInf(out, len, flags); return 0 }
        var n = if (d != 0.0) { val f = f2i(Math.floor(StrictMath.log10(d))); f - Math.floorMod(f, 3L) } else 0L
        d /= pow10(n)
        if (n < 0) { n = -n; flags = flags or NEG_E }
        if (flags and AUX != 0 && n in -24..24) {
            val i: Long
            var j = 0L
            if (flags and QUESTION != 0) {
                i = if (flags and NEG_E != 0) -n / 3 else n / 3
            } else {
                j = if (flags and NEG_E != 0) -n - aux else n - aux
                d *= pow10(j)
                i = aux / 3
            }
            if (i < 0) tmp[k++] = NEG_LETS[(-i).toInt().coerceAtMost(8)]
            else if (i > 0) tmp[k++] = POS_LETS[i.toInt().coerceAtMost(8)].code.toByte()
            else if (len != 0L) tmp[k++] = ' '.code.toByte()
            if (flags and DECIMAL == 0) {
                decLen = len - k - 2
                if (flags and NEG != 0) decLen--
                if (j > 0) decLen -= if (flags and COMMA != 0) 4 * j / 3 else j
                val d1 = d + pow10(-decLen + 1) / 2
                if (d1 >= 10) { decLen--; if (d1 >= 100) decLen-- }
            }
        } else {
            var e = n
            var i = 3
            do { tmp[k++] = ('0'.code + (e % 10).toInt()).toByte(); e /= 10 } while (e != 0L && i-- != 0)
            if (flags and NEG_E != 0) tmp[k++] = '-'.code.toByte()
            tmp[k++] = 'e'.code.toByte()
            if (decLen == 0L) {
                decLen = len - k - 2
                if (flags and NEG != 0) decLen--
                val d1 = d + pow10(-decLen + 1) / 2
                if (d1 >= 10) { decLen--; if (d1 >= 100) decLen-- }
            }
        }
        if (flags and COMMA != 0) {
            if (len != 0L && decLen > 0 && (decLen and 3) == 0L) tmp[k++] = ','.code.toByte()
            decLen -= decLen / 4
        }
        outF(out, tmp, k, d, decLen, flags, len)
        return k
    }

    private fun mprintQ(s: ByteArray, flags: Int): ByteArray {
        val o = ByteArrayOutputStream()
        for (b in s) {
            val ch = b.toInt() and 0xFF
            when (ch) {
                '$'.code -> if (flags and DOLLAR != 0) { o.write('\\'.code); o.write('d'.code) } else { o.write(ch); o.write(ch) }
                '%'.code -> { o.write(ch); if (flags and SLASH != 0) o.write(ch) }
                '\n'.code -> { o.write('\\'.code); o.write('n'.code) }
                '\r'.code -> { o.write('\\'.code); o.write('r'.code) }
                '\t'.code -> { o.write('\\'.code); o.write('t'.code) }
                '"'.code, '\\'.code -> { o.write('\\'.code); o.write(ch) }
                else -> if (ch >= 32 && ch != 0x7F) o.write(ch) else o.write(latin1("\\x%02X".format(java.util.Locale.ROOT, ch)))
            }
        }
        return o.toByteArray()
    }

    private fun mprintq(s: ByteArray): ByteArray {
        val o = ByteArrayOutputStream()
        var i = 0
        while (i < s.size) {
            val ch = s[i].toInt() and 0xFF
            if (ch == '\\'.code && i + 1 < s.size) {
                i++
                when (val c = s[i].toInt() and 0xFF) {
                    'n'.code -> o.write(10); 'r'.code -> o.write(13); 't'.code -> o.write(9)
                    'd'.code -> o.write('$'.code)
                    'x'.code -> {
                        val h = latin1(s, i + 1, minOf(2, s.size - i - 1))
                        o.write(h.toIntOrNull(16) ?: 0); i += h.length
                    }
                    else -> o.write(c)
                }
                i++
            } else { o.write(ch); i++ }
        }
        return o.toByteArray()
    }

    private fun lstSub(sub: Long, lst: Long): ByteArray {
        if (lst == 0L || sub < 0) return ByteArray(0)
        var p = mem.check(lst, 1)
        var n = sub
        while (n > 0) {
            if (mem.ld1(p) == 0L) {
                if (mem.ld1(p + 1) == 0L && n > 0) return ByteArray(0)
                n--
            }
            p++
        }
        return mem.readStrBytes(p.toLong())
    }

    // TempleOS CDate: upper 32 bits = days since year 0, lower 32 bits = fraction of day.
    private fun dateStr(cdt: Long): String {
        val (y, mo, dd) = Dates.civil(cdt)
        return "%02d/%02d/%02d".format(java.util.Locale.ROOT, mo, dd, y % 100)
    }

    private fun timeStr(cdt: Long): String {
        val secs = ((cdt and 0xFFFFFFFFL) * 86400L) ushr 32
        return "%02d:%02d:%02d".format(java.util.Locale.ROOT, secs / 3600, (secs / 60) % 60, secs % 60)
    }
}

object Dates {
    /** Days from 0000-03-01-based civil algorithm; TempleOS day 0 = Jan 1, year 0. */
    fun civil(cdt: Long): Triple<Long, Long, Long> {
        val days = cdt shr 32
        // shift so that 0 = 0000-03-01 (Howard Hinnant's algorithm), TempleOS day 0 = 0000-01-01
        val z = days - 60
        val era = Math.floorDiv(z, 146097)
        val doe = z - era * 146097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = doy - (153 * mp + 2) / 5 + 1
        val m = if (mp < 10) mp + 3 else mp - 9
        return Triple(if (m <= 2) y + 1 else y, m, d)
    }

    /** Converts epoch milliseconds (UTC) plus a local offset into a TempleOS CDate. */
    fun fromEpochMillis(ms: Long, offsetMs: Long): Long {
        val local = ms + offsetMs
        val dayMs = 86_400_000L
        val epochDays = Math.floorDiv(local, dayMs)
        val frac = Math.floorMod(local, dayMs)
        // days from 0000-01-01 to 1970-01-01 in the proleptic Gregorian calendar
        val days = epochDays + 719528L
        return (days shl 32) or ((frac shl 32) / dayMs)
    }
}
