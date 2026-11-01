package io.github.templeosmobile.core.purenative

import io.github.templeosmobile.core.holyc.*

/**
 * The data segment and symbol table of a translated program, written by the translator from what
 * the compiler did (temple_os_kotlin/translator, Image.kt) and read here instead of compiling.
 *
 * A unit is the prelude or one chunk of a program (TempleOS JIT order). Loading a unit repeats the
 * compiler's arena effects in the compiler's order: globals (zeroed), interned string literals,
 * binary literals (sprites), constant initializers. The interpreter makes the same calls when it
 * compiles, so a native program's arena layout is the interpreted program's. Addresses in the file
 * are the translator's; [addr] maps them to this arena's (they are equal unless run-time
 * allocations differ before a chunk). The unit's classes, globals and functions are registered in
 * the [Program] symbol tables the kernel reads (Offsets, callHolyC, probes).
 */
class Segment(private val prog: Program, private val natives: NativeTable) {
    class Unit(val name: String) {
        val lines = ArrayList<String>()
        var init = -1
        /** Registry path when this unit is a RegExe compilation of the program's RegDft default. */
        var registry: String? = null
    }

    val units = ArrayList<Unit>()
    /** Translator address -> arena address, for every allocation of the loaded units. */
    private val reloc = HashMap<Int, Int>()
    /** Global storage by translator address (start, size), to relocate constant writes inside them. */
    private val globalStarts = java.util.TreeMap<Int, Int>()

    /** Translator address of a global/string/binary -> this arena's address. */
    fun a(buildAddr: Int): Long = (reloc[buildAddr] ?: error("segment: no allocation at 0x${Integer.toHexString(buildAddr)}")).toLong()

    /** Index of the native function [name] (generated modules call natives by these indices). */
    fun nat(name: String): Int = natives.find(name)?.index ?: error("segment: host function $name is missing")

    companion object {
        const val MAGIC = "TOSIMG 1"

        fun parse(text: String): List<Unit> {
            val out = ArrayList<Unit>()
            var cur: Unit? = null
            val lines = text.split('\n')
            require(lines.firstOrNull()?.trim() == MAGIC) { "not a TempleOS native image" }
            for (i in 1 until lines.size) {
                val l = lines[i]
                if (l.isEmpty()) continue
                if (l.startsWith("unit ")) { cur = Unit(l.substring(5)); out.add(cur); continue }
                val u = cur ?: error("segment: data before the first unit")
                if (l.startsWith("init ")) { u.init = l.substring(5).toInt(); continue }
                if (l.startsWith("registry ")) { u.registry = l.substring(9); continue }
                u.lines.add(l)
            }
            return out
        }

        fun hex(s: String): ByteArray {
            val b = ByteArray(s.length / 2)
            for (i in b.indices) b[i] = ((Character.digit(s[2 * i], 16) shl 4) or Character.digit(s[2 * i + 1], 16)).toByte()
            return b
        }
    }

    /** Replays [u]'s arena effects and registers its symbols; returns its init function (or null). */
    fun load(u: Unit): FuncSym? {
        val mem = prog.vm.mem
        var cls: ClassType? = null
        for (l in u.lines) {
            val f = l.split(' ')
            when (f[0]) {
                "service" -> prog.requireService(f[1])
                "value" -> prog.uiConstants[f[1]]=f[2].toLong()
                "g" -> {
                    val build = f[1].toInt(16); val size = f[2].toInt()
                    val at = prog.allocGlobal(size)
                    reloc[build] = at
                    globalStarts[build] = size
                }
                "s" -> reloc[f[1].toInt(16)] = prog.stringAddr(hex(f.getOrElse(2) { "" }))
                "b" -> reloc[f[1].toInt(16)] = prog.binAddr(hex(f.getOrElse(2) { "" }))
                "c" -> {
                    val build = f[1].toInt(16); val w = f[2].toInt()
                    var v = java.lang.Long.parseUnsignedLong(f[3], 16)
                    if (f.size > 4 && f[4] == "s") v = a(v.toInt())
                    val base = globalStarts.floorKey(build) ?: error("segment: constant outside any global")
                    val at = a(base).toInt() + (build - base)
                    when (w) { 1 -> mem.st1(at, v); 2 -> mem.st2(at, v); 4 -> mem.st4(at, v); else -> mem.st8(at, v) }
                }
                "class" -> {
                    val name = f[1]
                    val old = prog.classes[name]
                    val c = if (old != null && !old.defined) old else ClassType(name, f[3] == "1")
                    c.members.clear()
                    c.size = f[2].toInt()
                    c.valueType = if (f[4] == "-") null else Types.builtins[f[4]] as IntType
                    c.base = if (f[5] == "-") null else prog.classes[f[5]]
                    c.defined = f.getOrNull(6) != "fwd"
                    prog.classes[name] = c
                    cls = c
                }
                "m" -> cls!!.members[f[1]] = Member(f[1], type(f[3]), f[2].toInt(), f.getOrNull(4)?.let { h -> ByteArray(h.length / 2) { h.substring(it*2,it*2+2).toInt(16).toByte() } })
                "sym" -> when (f[1]) {
                    "g" -> {
                        val name = f[2]
                        prog.globals[name] = GlobalSym(name, type(f[4]), a(f[3].toInt(16)).toInt())
                    }
                    "f" -> {
                        val name = f[2]; val idx = f[3].toInt()
                        prog.globals[name] = function(name, idx, f[4], if (f.size > 6 && f[5] == "n") f[6] else null)
                    }
                }
                "fn" -> function(f[2], f[1].toInt(), f[3], null)
                else -> error("segment: unknown record ${f[0]}")
            }
        }
        return if (u.init >= 0) prog.funcs.getOrNull(u.init)?.takeIf { it.index == u.init } else null
    }

    private val funcsByIndex = HashMap<Int, FuncSym>()

    /** The FuncSym for function [idx] (one object per index, as the compiler has). */
    private fun function(name: String, idx: Int, type: String, native: String?): FuncSym {
        if (native != null) {
            val fs = FuncSym(name, type(type) as FuncType)
            fs.nativeIndex = nat(native)
            fs.defined = true
            return fs
        }
        funcsByIndex[idx]?.let { return it }
        val fs = FuncSym(name, type(type) as FuncType)
        fs.defined = true
        prog.installFunc(fs, idx)
        funcsByIndex[idx] = fs
        return fs
    }

    // ------------------------------------------------------------ types: U0 I64 F64 *T [n]T $Class (R;P,P;v)

    fun type(s: String): Type = TypeReader(s).read()

    private inner class TypeReader(private val s: String) {
        private var p = 0
        fun read(): Type {
            val t = one()
            check(p == s.length) { "segment: bad type $s" }
            return t
        }
        private fun one(): Type {
            when (s[p]) {
                '*' -> { p++; return PtrType(one()) }
                '[' -> {
                    val e = s.indexOf(']', p)
                    val n = s.substring(p + 1, e).toInt()
                    p = e + 1
                    return ArrType(one(), n)
                }
                '$' -> {
                    val st = ++p
                    while (p < s.length && (s[p].isLetterOrDigit() || s[p] == '_' || s[p].code >= 128)) p++
                    val n = s.substring(st, p)
                    return prog.classes[n] ?: ClassType(n, false).also { prog.classes[n] = it }
                }
                '(' -> {
                    p++
                    val ret = one()
                    check(s[p] == ';'); p++
                    val params = ArrayList<Param>()
                    while (s[p] != ';') {
                        params.add(Param("", one(), null))
                        if (s[p] == ',') p++
                    }
                    p++
                    val va = s[p] == 'v'; p++
                    check(s[p] == ')'); p++
                    return FuncType(ret, params, va)
                }
                else -> {
                    val st = p
                    while (p < s.length && s[p].isLetterOrDigit()) p++
                    return Types.builtins[s.substring(st, p)] ?: error("segment: unknown type ${s.substring(st, p)}")
                }
            }
        }
    }
}
