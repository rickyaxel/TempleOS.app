package io.github.templeosmobile.translator

/**
 * The translator's typed, lowered intermediate representation.
 *
 * It sits between the HolyC typed AST (from the :core parser) and the two source printers
 * (Kotlin, Swift). Every HolyC semantic decision is made while lowering to it (conversions,
 * widths, signedness, evaluation order, budget ticks, frame and handler bookkeeping), so the
 * printers only spell it. Expressions are pure (they may fault, never change state); all
 * effects are statements, in VM evaluation order. Nothing here exists at run time.
 */

/** Native value kinds: I = 64-bit word (Long / Int64), F = Double, B = Boolean (conditions only). */
enum class K { I, F, B }

class Var(val name: String, val k: K, val mutable: Boolean)

sealed class X { abstract val k: K }

class XI(val v: Long) : X() { override val k get() = K.I }
class XF(val bits: Long) : X() { override val k get() = K.F }
class XB(val v: Boolean) : X() { override val k get() = K.B }
class XVar(val v: Var) : X() { override val k get() = v.k }
/** Address of a global (field set when the data segment is loaded). */
class XGlob(val name: String) : X() { override val k get() = K.I }
/** Address of an interned string literal / binary literal. */
class XStr(val name: String) : X() { override val k get() = K.I }
class XBin(val name: String) : X() { override val k get() = K.I }
/** fp + off: an address in the function's arena frame. */
class XFp(val off: Int) : X() { override val k get() = K.I }
/** A native function's pointer value (FPTR_NATIVE | index), resolved by name at load. */
class XNatPtr(val name: String) : X() { override val k get() = K.I }
class XOp(val op: Op, val a: X, val b: X? = null) : X() { override val k get() = op.res }
/** Checked arena load of [w] bytes, sign- or zero-extended. */
class XLoad(val w: Int, val signed: Boolean, val a: X) : X() { override val k get() = K.I }
/** Checked 8-byte load reinterpreted as F64. */
class XLoadF(val a: X) : X() { override val k get() = K.F }

enum class Op(val res: K, val arity: Int) {
    // I x I -> I
    ADD(K.I, 2), SUB(K.I, 2), MUL(K.I, 2), AND(K.I, 2), OR(K.I, 2), XOR(K.I, 2),
    SHL(K.I, 2), SHRS(K.I, 2), SHRU(K.I, 2),
    /** Division and remainder fault with 'DivZero' (signed: also MIN / -1), as the VM does. */
    DIVS(K.I, 2), DIVU(K.I, 2), MODS(K.I, 2), MODU(K.I, 2), POWI(K.I, 2),
    // I x I -> B
    EQ(K.B, 2), NE(K.B, 2), LTS(K.B, 2), LES(K.B, 2), GTS(K.B, 2), GES(K.B, 2),
    LTU(K.B, 2), LEU(K.B, 2), GTU(K.B, 2), GEU(K.B, 2),
    // F x F -> F
    FADD(K.F, 2), FSUB(K.F, 2), FMUL(K.F, 2), FDIV(K.F, 2), FMOD(K.F, 2), FPOW(K.F, 2),
    // F x F -> B
    FEQ(K.B, 2), FNE(K.B, 2), FLT(K.B, 2), FLE(K.B, 2), FGT(K.B, 2), FGE(K.B, 2),
    // I -> I
    NEG(K.I, 1), COM(K.I, 1), SX1(K.I, 1), SX2(K.I, 1), SX4(K.I, 1), ZX1(K.I, 1), ZX2(K.I, 1), ZX4(K.I, 1),
    // F -> F
    FNEG(K.F, 1),
    // conversions
    I2F(K.F, 1), U2F(K.F, 1), F2I(K.I, 1), BITS2F(K.F, 1), F2BITS(K.I, 1),
    B2I(K.I, 1), I2B(K.B, 1), F2B(K.B, 1),
    // B -> B, B x B -> B (BAND/BOR short-circuit; BXOR evaluates both)
    BNOT(K.B, 1), BAND(K.B, 2), BOR(K.B, 2), BXOR(K.B, 2),
}

/** Source position for comments in the generated code (and the map back to HolyC). */
class Pos(val file: String, val line: Int)

sealed class S { var pos: Pos? = null }

/** `var v = init` (register locals and temporaries; temporaries are immutable). */
class SDecl(val v: Var, val init: X?) : S()
class SSet(val v: Var, val x: X) : S()
/** Checked store of the low [w] bytes of the word [x] at [a]; [a] is evaluated before [x]. */
class SStore(val w: Int, val a: X, val x: X) : S()
/** Evaluates a pure expression for its faults only (the VM evaluates discarded loads too). */
class SEval(val x: X) : S()
/** MemCpy within the arena (class value assignment, string array initializers). */
class SCopy(val dst: X, val src: X, val n: Int) : S()

sealed class Callee
/** A HolyC function compiled to native code: direct call with typed arguments. */
class CDirect(val fn: FnRef) : Callee()
/** A host function (the runtime's natives): word arguments through the task's stack. */
class CNative(val name: String, val index: Int) : Callee()
/** Through a function pointer: word arguments, dispatched by the runtime. */
class CPtr(val fp: X) : Callee()

/** A reference to a generated function: which module it lives in and its native name. */
class FnRef(val index: Int, val module: String, val name: String, val params: List<K>, val ret: K?, val varargs: Boolean)

/**
 * A call. [args] are already converted (typed for [CDirect], words otherwise). [extra] are the
 * varargs words of a direct call to a varargs function. [result] receives the return value
 * (as [resultK]); null when the value is unused.
 */
class SCall(val callee: Callee, val args: List<X>, val extra: List<X>, val result: Var?, val resultK: K?, val tick: Boolean) : S()

class SIf(val c: X, val t: List<S>, val f: List<S>?) : S()

/**
 * `while (true)` with an optional head condition: [pre] then `if (!cond) break`, then [body]
 * (inside a breakable block [cont] when `continue` targets it), then [post] (for-step), then a
 * budget tick (the VM's backward jump). [doWhile]: the condition is tested after the body instead.
 */
class SLoop(val label: String, val pre: List<S>, val cond: X?, val body: List<S>, val cont: String?, val post: List<S>, val doWhile: Boolean) : S()

/** A breakable block: `break label` continues after it. */
class SBlock(val label: String, val body: List<S>) : S()
/** A loop entered once whose `continue label` re-runs it (backward goto); ends with a break. */
class SRetryLoop(val label: String, val body: List<S>) : S()
class SBreak(val label: String) : S()
class SContinue(val label: String) : S()
/** Budget tick: a backward branch or a call in the VM (scheduling slices, virtual time). */
class STick : S()
/** Adjust the task's live handler count (leaving try blocks by break/continue/goto). */
class SHandlers(val delta: Int) : S()
class SReturn(val x: X?, val tries: Int) : S()

/** try/catch with the VM's handler semantics (except_ch, catch_except, rethrow at the end). */
class STry(val id: Int, val body: List<S>, val handler: List<S>) : S()

/** A switch without fallthrough: each arm ends by leaving the switch. */
class SWhen(val x: X, val arms: List<Arm>, val dflt: List<S>?) : S()
class Arm(val ranges: List<LongRange>, val body: List<S>)

/**
 * Fallback for unstructured control flow (gotos into blocks): the function body becomes numbered
 * blocks run by a dispatch loop; jumps are `state = n; continue`. [tries] maps blocks to the try
 * region that is active in them (-1: none) and gives each region's handler block.
 */
class SMachine(val label: String, val stateVar: Var, val blocks: List<MBlock>, val regions: List<MRegion>) : S()
class MBlock(val id: Int, val body: List<S>, val region: Int)
class MRegion(val id: Int, val handler: Int, val outer: Int)
/** Jump to a machine block ([tick] for backward jumps). */
class SGoto(val machine: String, val stateVar: Var, val target: Int, val tick: Boolean) : S()
/** End of a machine try region's handler: rethrow unless the handler set catch_except (VM ENDCATCH). */
class SEndCatch : S()
/** Entering a machine try region: save the state its handler restores. */
class SRegionEnter(val region: MRegion) : S()

class IrFunction(
    val ref: FnRef,
    val holyName: String,
    val file: String,
    val line: Int,
    val params: List<Var>,
    /** Parameters the body uses through memory: copied to the frame at entry. (param index, frame offset) */
    val paramSpills: List<Pair<Int, Int>>,
    val locals: List<Var>,
    /** Arena frame bytes (0: no frame). */
    val frameSize: Int,
    /** varargs: frame offsets of argc and argv. */
    val argcOff: Int, val argvOff: Int,
    val body: List<S>,
    val isInit: Boolean,
    val argc: Var?,
    val argv: Var?,
    /** Lowered with the dispatch-loop fallback (unstructured gotos). */
    val machine: Boolean,
)
