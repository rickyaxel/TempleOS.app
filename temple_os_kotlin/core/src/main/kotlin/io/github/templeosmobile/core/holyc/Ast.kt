package io.github.templeosmobile.core.holyc

// ------------------------------------------------------------------ symbols

sealed class Sym(val name: String, var type: Type)

class LocalSym(name: String, type: Type, val offset: Int) : Sym(name, type)

class GlobalSym(name: String, type: Type, var addr: Int) : Sym(name, type)

class FuncSym(name: String, type: FuncType) : Sym(name, type) {
    val ftype get() = type as FuncType
    var index = -1               // index into Program.funcs
    var nativeIndex = -1         // >= 0 for host functions
    var defined = false
    var entry = -1               // code address
    var frameSize = 0
    var argcSlot = -1            // frame offset of argc (varargs functions)
    var argvSlot = -1
    var paramOffsets = IntArray(0)
    var file = ""
    var line = 0
    val isNative get() = nativeIndex >= 0
}

// ------------------------------------------------------------------ expressions

sealed class Expr {
    lateinit var type: Type
    var file = ""
    var line = 0
    /** Height of this expression tree (the parser bounds it: see Parser.MAX_EXPR_DEPTH). */
    var depth = 1
        protected set
    protected fun under(vararg xs: Expr?) { for (x in xs) if (x != null && x.depth >= depth) depth = x.depth + 1 }
    protected fun under(xs: List<Expr?>) { for (x in xs) if (x != null && x.depth >= depth) depth = x.depth + 1 }
}

class IntLit(val v: Long) : Expr()
class FloatLit(val v: Double) : Expr()
class StrLit(val bytes: ByteArray) : Expr()
class BinLit(val bytes: ByteArray) : Expr()
class VarRef(val sym: Sym) : Expr()
class FuncAddr(val fn: FuncSym) : Expr()
class Unary(val op: String, val e: Expr) : Expr() { init { under(e) } }          // - ~ !
class Binary(val op: String, val l: Expr, val r: Expr) : Expr() { init { under(l, r) } }
class Chain(val ops: List<String>, val xs: List<Expr>) : Expr() { init { under(xs) } }
class Logical(val op: String, val l: Expr, val r: Expr) : Expr() { init { under(l, r) } } // && || ^^
class Assign(val op: String, val target: Expr, val value: Expr) : Expr() { init { under(target, value) } }
class IncDec(val target: Expr, val delta: Int, val post: Boolean) : Expr() { init { under(target) } }
class Call(val fn: FuncSym?, val callee: Expr?, val ftype: FuncType, val args: List<Expr?>) : Expr() { init { under(callee); under(args) } }
class Index(val base: Expr, val idx: Expr) : Expr() { init { under(base, idx) } }
class MemberAccess(val base: Expr, val offset: Int, val viaPtr: Boolean) : Expr() { init { under(base) } }
class Deref(val e: Expr) : Expr() { init { under(e) } }
class AddrOf(val e: Expr) : Expr() { init { under(e) } }
class Cast(val e: Expr) : Expr() { init { under(e) } }
class Comma(val xs: List<Expr>) : Expr() { init { under(xs) } }
/** Hidden argc/argv access inside varargs functions. */
class ArgvRef : Expr()

// ------------------------------------------------------------------ statements

sealed class Stmt {
    var file = ""
    var line = 0
}

class Block(val list: List<Stmt>) : Stmt()
class ExprStmt(val e: Expr) : Stmt()
class If(val c: Expr, val t: Stmt, val f: Stmt?) : Stmt()
class While(val c: Expr, val body: Stmt) : Stmt()
class DoWhile(val body: Stmt, val c: Expr) : Stmt()
class For(val init: Stmt?, val c: Expr?, val step: Expr?, val body: Stmt) : Stmt()
class Switch(val e: Expr, val body: List<Stmt>, val unchecked: Boolean) : Stmt()
class CaseLabel(val lo: Long, val hi: Long, val isDefault: Boolean) : Stmt()
class SubStart : Stmt()
class SubEnd : Stmt()
class Break : Stmt()
class Continue : Stmt()
class Return(val e: Expr?) : Stmt()
class Goto(val label: String) : Stmt()
class Label(val name: String) : Stmt()
class Try(val body: Stmt, val handler: Stmt) : Stmt()
class LocalInit(val sym: LocalSym, val init: Init?) : Stmt()
class GlobalInit(val sym: GlobalSym, val init: Init) : Stmt()
object Nop : Stmt()

/** Initializer: either a single expression or a brace list. */
sealed class Init
class ExprInit(val e: Expr) : Init()
class ListInit(val items: List<Init>) : Init()
