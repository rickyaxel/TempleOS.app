package io.github.templeosmobile.core.holyc

sealed class Type {
    abstract val size: Int
    abstract val name: String
    override fun toString() = name
}

object VoidType : Type() {
    override val size = 0
    override val name = "U0"
}

class IntType(override val name: String, override val size: Int, val signed: Boolean) : Type()

object F64Type : Type() {
    override val size = 8
    override val name = "F64"
}

class PtrType(val target: Type) : Type() {
    override val size = 8
    override val name get() = "$target *"
}

class ArrType(val elem: Type, val count: Int) : Type() {
    override val size get() = elem.size * count
    override val name get() = "$elem[$count]"
}

class Member(val name: String, val type: Type, val offset: Int, val format: ByteArray? = null)

class ClassType(override val name: String, val isUnion: Boolean) : Type() {
    val members = LinkedHashMap<String, Member>()
    var base: ClassType? = null
    /** For `I64 class X` style declarations: the type used when the class is used as a whole value. */
    var valueType: IntType? = null
    var defined = false
    override var size = 0

    fun find(n: String): Member? = members[n]
}

class Param(val name: String, val type: Type, val default: Expr?)

class FuncType(val ret: Type, val params: List<Param>, val varargs: Boolean) : Type() {
    override val size = 8
    override val name get() = "$ret(${params.joinToString(",") { it.type.name }}${if (varargs) ",..." else ""})"
}

object Types {
    val U0 = VoidType
    val I8 = IntType("I8", 1, true)
    val U8 = IntType("U8", 1, false)
    val I16 = IntType("I16", 2, true)
    val U16 = IntType("U16", 2, false)
    val I32 = IntType("I32", 4, true)
    val U32 = IntType("U32", 4, false)
    val I64 = IntType("I64", 8, true)
    val U64 = IntType("U64", 8, false)
    val Bool = IntType("Bool", 1, false)
    val F64 = F64Type
    val U8Ptr = PtrType(U8)

    val builtins: Map<String, Type> = mapOf(
        "U0" to U0, "I0" to U0, "I8" to I8, "U8" to U8, "I16" to I16, "U16" to U16,
        "I32" to I32, "U32" to U32, "I64" to I64, "U64" to U64, "F64" to F64, "Bool" to Bool,
        "I8i" to I8, "U8i" to U8, "I16i" to I16, "U16i" to U16, "I32i" to I32, "U32i" to U32,
        "I64i" to I64, "U64i" to U64, "F64i" to F64, "U0i" to U0,
    )

    fun isInt(t: Type) = t is IntType || (t is ClassType && t.valueType != null)
    fun isScalar(t: Type) = isInt(t) || t is F64Type || t is PtrType
    fun isPtrLike(t: Type) = t is PtrType || t is ArrType

    /** Integer view of a type (classes with a value type behave as that integer). */
    fun asInt(t: Type): IntType? = when (t) {
        is IntType -> t
        is ClassType -> t.valueType
        else -> null
    }

    fun isUnsigned64(t: Type): Boolean {
        val i = asInt(t)
        return (i != null && !i.signed && i.size == 8) || t is PtrType || t is ArrType
    }

    /** Any unsigned integer width (or pointer): TempleOS compares unsigned if either operand is (Compiler/OptLib.HC). */
    fun isUnsignedAny(t: Type): Boolean {
        val i = asInt(t)
        return (i != null && !i.signed) || t is PtrType || t is ArrType
    }

    fun pointee(t: Type): Type = when (t) {
        is PtrType -> t.target
        is ArrType -> t.elem
        else -> U8
    }

    /** Element size used for pointer arithmetic (U0 pointers scale by 1). */
    fun scale(t: Type): Int {
        val s = pointee(t).size
        return if (s == 0) 1 else s
    }

    /** Sub-integer members available on intrinsic integer unions (x.u8[i] etc). */
    fun intSubMember(t: IntType, n: String): Type? {
        val sizes = mapOf("i8" to I8, "u8" to U8, "i16" to I16, "u16" to U16, "i32" to I32, "u32" to U32, "i64" to I64, "u64" to U64)
        val e = sizes[n] ?: return null
        if (e.size >= t.size && !(e.size == t.size && e.size == 8)) return null
        return ArrType(e, t.size / e.size)
    }
}
