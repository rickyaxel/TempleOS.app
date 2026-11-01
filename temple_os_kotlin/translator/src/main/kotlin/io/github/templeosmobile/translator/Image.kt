package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*

/**
 * Writes a module's data segment and symbol table (purenative.Segment reads it on both platforms).
 * Text, one record per line; addresses are the translator's (hex), bytes are hex.
 */
object Image {
    fun typeString(t: Type): String = when (t) {
        is VoidType -> "U0"
        is F64Type -> "F64"
        is IntType -> t.name
        is PtrType -> "*" + typeString(t.target)
        is ArrType -> "[${t.count}]" + typeString(t.elem)
        is ClassType -> "$" + t.name
        is FuncType -> "(" + typeString(t.ret) + ";" + t.params.joinToString(",") { typeString(it.type) } + ";" + (if (t.varargs) "v" else "-") + ")"
    }

    private fun hex(b: ByteArray): String {
        val sb = StringBuilder(b.size * 2)
        for (x in b) { val v = x.toInt() and 0xFF; sb.append("0123456789abcdef"[v shr 4]).append("0123456789abcdef"[v and 15]) }
        return sb.toString()
    }

    fun write(units: List<CapturedUnit>): String {
        val sb = StringBuilder()
        sb.append("TOSIMG 1\n")
        for (u in units) {
            sb.append("unit ").append(u.name).append('\n')
            u.registry?.let { sb.append("registry ").append(it).append('\n') }
            for(service in u.services) sb.append("service ").append(service).append('\n')
            for((name,value) in u.constants.toSortedMap()) sb.append("value ").append(name).append(' ').append(value).append('\n')
            // classes first: the symbols' types name them
            // bases before the classes derived from them
            val ordered = ArrayList<Pair<String, ClassType>>()
            val pending = u.classes.toMutableList()
            while (pending.isNotEmpty()) {
                val next = pending.firstOrNull { (_, c) -> pending.none { it.second === c.base } } ?: pending.first()
                ordered.add(next); pending.remove(next)
            }
            for ((name, c) in ordered) {
                sb.append("class ").append(name).append(' ').append(c.size).append(' ').append(if (c.isUnion) 1 else 0).append(' ')
                    .append(c.valueType?.name ?: "-").append(' ').append(c.base?.name ?: "-")
                if (!c.defined) sb.append(" fwd")
                sb.append('\n')
                for (m in c.members.values) sb.append("m ").append(m.name).append(' ').append(m.offset).append(' ').append(typeString(m.type)).append(m.format?.let { " " + hex(it) } ?: "").append('\n')
            }
            for (ev in u.events) when (ev) {
                is SegEvent.Global -> sb.append("g ").append(Integer.toHexString(ev.addr)).append(' ').append(ev.size).append('\n')
                is SegEvent.Str -> sb.append("s ").append(Integer.toHexString(ev.addr)).append(' ').append(hex(ev.bytes)).append('\n')
                is SegEvent.Bin -> sb.append("b ").append(Integer.toHexString(ev.addr)).append(' ').append(hex(ev.bytes)).append('\n')
                is SegEvent.Const -> {
                    sb.append("c ").append(Integer.toHexString(ev.addr)).append(' ').append(ev.width).append(' ').append(java.lang.Long.toHexString(ev.value))
                    if (ev.isString) sb.append(" s")
                    sb.append('\n')
                }
            }
            for (cf in u.functions) sb.append("fn ").append(cf.f.index).append(' ').append(cf.f.name).append(' ').append(typeString(cf.f.ftype)).append('\n')
            for ((name, s) in u.symbols) when (s) {
                is GlobalSym -> sb.append("sym g ").append(name).append(' ').append(Integer.toHexString(s.addr)).append(' ').append(typeString(s.type)).append('\n')
                is FuncSym -> {
                    sb.append("sym f ").append(name).append(' ').append(s.index).append(' ').append(typeString(s.ftype))
                    if (s.isNative) sb.append(" n ").append(s.name)
                    sb.append('\n')
                }
                is LocalSym -> {}
            }
            u.init?.let { sb.append("init ").append(it.index).append('\n') }
        }
        return sb.toString()
    }
}
