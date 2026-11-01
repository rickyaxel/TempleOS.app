package io.github.templeosmobile.core.holyc

class IntList(cap: Int = 1024) {
    var data = IntArray(cap)
        private set
    var size = 0
        private set
    fun add(v: Int) {
        if (size == data.size) data = data.copyOf(size * 2)
        data[size++] = v
    }
    operator fun get(i: Int) = data[i]
    operator fun set(i: Int, v: Int) { data[i] = v }
}

/** Where the main task's code comes from, one executable chunk at a time (TempleOS JIT order). */
interface ChunkSource {
    /** The next chunk's function (its top-level statements), or null when the program is done. */
    fun next(): FuncSym?
    /** Command-line answer kind of the last chunk (Program.ANS_*). */
    val answerKind: Int
}

/** A host function implementation. Arguments are t.st[base until base+argc]. */
/**
 * A host function body with a primitive signature: a Kotlin `fun interface`, so lambdas registered as
 * natives are not boxed per call (a `(Task, Int, Int) -> Long` lambda boxes its two Ints and its Long
 * result on every call, which was most of the native engine's allocation in X-Caliber's ODE).
 */
fun interface NativeFn { fun call(t: Task, base: Int, argc: Int): Long }

abstract class Native(val name: String) {
    var index = -1
    abstract fun call(t: Task, base: Int, argc: Int): Long
}

/** Registry of host functions available to the prelude's `native` declarations. */
class NativeTable {
    val list = ArrayList<Native>()
    private val byName = HashMap<String, Native>()
    fun add(n: Native) {
        n.index = list.size
        list.add(n)
        byName[n.name] = n
    }
    fun find(name: String) = byName[name]
}

/**
 * Compiled program state: symbol tables, bytecode and constant pools. Units are
 * compiled incrementally (the terminal compiles each command into the same
 * program, as the TempleOS shell does).
 */
class Program(val vm: Vm) {
    val requiredServices = LinkedHashSet<String>()
    val uiConstants = HashMap<String,Long>()
    var serviceHandler: ((String)->Unit)? = null
    fun requireService(name:String) {if(requiredServices.add(name)) serviceHandler?.invoke(name)}
    val classes = HashMap<String, ClassType>()
    val globals = HashMap<String, Sym>()
    val funcs = ArrayList<FuncSym>()
    val code = IntList(16384)
    val consts = ArrayList<Long>()
    private val constIndex = HashMap<Long, Int>()
    val switchTables = ArrayList<SwitchTable>()
    val codegen = CodeGen(this)
    private val strings = HashMap<String, Int>()

    // function metadata arrays used by the VM (indexed by FuncSym.index)
    var fnEntry = IntArray(256); var fnFrame = IntArray(256); var fnNParams = IntArray(256)
    var fnArgc = IntArray(256); var fnArgv = IntArray(256)
    var fnParamOff = arrayOfNulls<IntArray>(256)
    var konstArr = LongArray(0)

    // line table
    private var linePc = IntArray(1024); private var lineNo = IntArray(1024); private var lineFile = IntArray(1024)
    private var lineCount = 0
    private val files = ArrayList<String>()
    private val fileIdx = HashMap<String, Int>()

    fun konst(v: Long): Int = constIndex.getOrPut(v) { consts.add(v); konstArr = consts.toLongArray(); consts.size - 1 }

    fun addFunc(f: FuncSym) {
        if (f.index >= 0) return
        f.index = funcs.size
        funcs.add(f)
        if (f.index >= fnEntry.size) {
            val n = fnEntry.size * 2
            fnEntry = fnEntry.copyOf(n); fnFrame = fnFrame.copyOf(n); fnNParams = fnNParams.copyOf(n)
            fnArgc = fnArgc.copyOf(n); fnArgv = fnArgv.copyOf(n); fnParamOff = fnParamOff.copyOf(n)
        }
        fnEntry[f.index] = -1
    }

    fun registerFunc(f: FuncSym) {
        addFunc(f)
        val i = f.index
        fnEntry[i] = f.entry
        fnFrame[i] = f.frameSize
        fnNParams[i] = f.ftype.params.size
        fnArgc[i] = if (f.ftype.varargs) f.argcSlot else -1
        fnArgv[i] = f.argvSlot
        fnParamOff[i] = f.paramOffsets
    }

    fun bindNative(f: FuncSym) {
        val n = vm.natives.find(f.name) ?: throw CompileError("host function '${f.name}' is not implemented", f.file, f.line)
        f.nativeIndex = n.index
        f.defined = true
    }

    /** Build-time compile observer (the native translator); see [CompileObserver]. */
    var observer: CompileObserver? = null
    /** > 0 while compiling: only then does [observer] see allocations (natives intern strings at run time too). */
    private var compiling = 0
    private val watch get() = if (compiling > 0) observer else null

    fun allocGlobal(size: Int): Int = vm.mem.calloc(maxOf(size, 8).toLong()).also { watch?.global(it, maxOf(size, 8)) }

    fun stringAddr(b: ByteArray): Int {
        val key = latin1(b)
        return strings.getOrPut(key) {
            val a = vm.mem.malloc(b.size + 1L)
            vm.mem.writeBytes(a, b)
            vm.mem.st1(a + b.size, 0)
            a
        }.also { watch?.string(b, it) }
    }

    fun binAddr(b: ByteArray): Int {
        val a = vm.mem.malloc(b.size.toLong().coerceAtLeast(1))
        vm.mem.writeBytes(a, b)
        watch?.bin(b, a)
        return a
    }

    /** Runs [block] as compilation, reporting the unit to [observer]. */
    private inline fun observed(name: String, block: () -> FuncSym?): FuncSym? {
        compiling++
        observer?.unitStart(name)
        var init: FuncSym? = null
        try { init = block(); return init } finally { compiling--; observer?.unitEnd(init) }
    }

    fun funcPtr(f: FuncSym): Long {
        if (f.isNative) return FPTR_NATIVE or f.nativeIndex.toLong()
        addFunc(f)
        return FPTR_TAG or f.index.toLong()
    }

    fun markLine(pc: Int, file: String, line: Int) {
        if (line <= 0) return
        val fi = fileIdx.getOrPut(file) { files.add(file); files.size - 1 }
        if (lineCount > 0 && lineNo[lineCount - 1] == line && lineFile[lineCount - 1] == fi) return
        if (lineCount == linePc.size) {
            linePc = linePc.copyOf(lineCount * 2); lineNo = lineNo.copyOf(lineCount * 2); lineFile = lineFile.copyOf(lineCount * 2)
        }
        linePc[lineCount] = pc; lineNo[lineCount] = line; lineFile[lineCount] = fi
        lineCount++
    }

    /** Source location for a pc, e.g. "C:/Home/Test.HC:12". */
    fun where(pc: Int): String {
        var lo = 0; var hi = lineCount - 1; var best = -1
        while (lo <= hi) {
            val m = (lo + hi) ushr 1
            if (linePc[m] <= pc) { best = m; lo = m + 1 } else hi = m - 1
        }
        if (best < 0) return "?"
        return "${files[lineFile[best]]}:${lineNo[best]}"
    }

    fun funcAt(pc: Int): String {
        var best: FuncSym? = null
        for (f in funcs) if (f.entry in 0..pc && (best == null || f.entry > best.entry)) best = f
        return best?.name ?: "?"
    }

    /**
     * Compiles a source unit. Returns the hidden function containing the unit's
     * top-level statements (call it to run them).
     */
    fun compile(src: SourceFile, dir: String, provider: SourceProvider?, defines: MutableMap<String, List<Token>>, allowNative: Boolean = false): FuncSym = nestingGuard {
        observed(src.name) { compile0(src, dir, provider, defines, allowNative) }!!
    }

    private fun compile0(src: SourceFile, dir: String, provider: SourceProvider?, defines: MutableMap<String, List<Token>>, allowNative: Boolean): FuncSym {
        refuseNative()
        val toks = Lexer(provider, defines) { n -> globals.containsKey(n) || classes.containsKey(n) }.stream(src, dir)
        val parser = Parser(this, toks, allowNative)
        val init = FuncSym("\$init:${src.name}", FuncType(Types.I64, emptyList(), false))
        init.file = src.name; init.line = 1
        val (stmts, frame) = parser.parseTopLevel()
        init.frameSize = frame
        init.defined = true
        addFunc(init)
        codegen.compileFunction(init, Block(stmts))
        return init
    }

    /**
     * Deeply nested source (the parser and code generator are recursive) is a
     * compile error, never a crash. The Swift version checks the remaining
     * thread stack instead (Basics.swift checkStack).
     */
    private inline fun <T> nestingGuard(block: () -> T): T =
        try { block() } catch (e: StackOverflowError) { throw CompileError(DEEP_NESTING) }

    /** Evaluates an expression by running it (set by the kernel). */
    var evalAtCompileTime: ((Expr) -> Long?)? = null
    private var evalCounter = 0

    /** Compiles `return e;` into a hidden function and returns it. */
    fun compileExprFunc(e: Expr): FuncSym = nestingGuard {
        observed("\$eval") { compileExprFunc0(e) }!!
    }

    private fun compileExprFunc0(e: Expr): FuncSym {
        refuseNative()
        val f = FuncSym("\$eval${evalCounter++}", FuncType(Types.I64, emptyList(), false))
        f.file = e.file; f.line = e.line; f.defined = true
        addFunc(f)
        codegen.compileFunction(f, Return(e).also { it.file = e.file; it.line = e.line })
        return f
    }

    /**
     * Set for a native kernel (Pure Kotlin mode): its symbols come from the translated image
     * (purenative.Segment) and nothing is ever compiled; [compile] and [session] refuse.
     */
    var nativeMode = false
        set(v) { field = v }

    private fun refuseNative() { if (nativeMode) throw CompileError(NATIVE_NO_COMPILE) }

    /** Registers function [f] at [index] (the translated image keeps the compiler's numbering). */
    fun installFunc(f: FuncSym, index: Int) {
        while (funcs.size <= index) funcs.add(FuncSym("\$unused${funcs.size}", FuncType(Types.U0, emptyList(), false)).also { it.index = funcs.size })
        f.index = index
        funcs[index] = f
    }

    /** Incremental compilation of a unit, one executable chunk at a time (TempleOS JIT order). */
    inner class Session(private val src: SourceFile, dir: String, provider: SourceProvider?, defines: MutableMap<String, List<Token>>, private val answers: Boolean = false) : ChunkSource {
        private val parser: Parser
        private var n = 0
        /** Command-line answer of the last compiled chunk (TempleOS Fs->answer_type): ANS_NONE, ANS_INT or ANS_F64. */
        override var answerKind = ANS_NONE; private set
        init {
            refuseNative()
            val toks = Lexer(provider, defines) { nm -> globals.containsKey(nm) || classes.containsKey(nm) }.stream(src, dir)
            parser = Parser(this@Program, toks, false)
        }
        /** Compiles the next chunk; returns its function, or null when the unit is done. */
        override fun next(): FuncSym? = nestingGuard { observed("${src.name}#$n") { next0() } }

        private fun next0(): FuncSym? {
            var (stmts, frame) = parser.parseChunk() ?: return null
            // Shell answers: like TempleOS's LexStmt2Bin, the value of a final
            // expression statement is returned so the command line can print it.
            answerKind = ANS_NONE
            var ret: Type = Types.I64
            val last = stmts.lastOrNull()
            if (answers && last is ExprStmt) {
                val t = last.e.type
                val kind = when {
                    t is F64Type -> ANS_F64
                    t is IntType || t is PtrType || (t is ClassType && t.valueType != null) -> ANS_INT
                    else -> ANS_NONE
                }
                if (kind != ANS_NONE) {
                    answerKind = kind
                    if (kind == ANS_F64) ret = F64Type
                    stmts = stmts.dropLast(1) + Return(last.e).also { it.file = last.file; it.line = last.line }
                }
            }
            val init = FuncSym("\$init:${src.name}#${n++}", FuncType(ret, emptyList(), false))
            init.file = src.name; init.line = stmts.firstOrNull()?.line ?: 1
            init.frameSize = frame
            init.defined = true
            addFunc(init)
            codegen.compileFunction(init, Block(stmts))
            return init
        }
    }

    fun session(src: SourceFile, dir: String, provider: SourceProvider?, defines: MutableMap<String, List<Token>>, answers: Boolean = false) =
        Session(src, dir, provider, defines, answers)

    companion object {
        const val FPTR_TAG = 0x7FFF000000000000L
        const val FPTR_NATIVE = 0x7FFF000100000000L
        const val DEEP_NESTING = "program too deeply nested"
        const val NATIVE_NO_COMPILE = "HolyC compilation is not available to a natively translated program"
        const val ANS_NONE = 0
        const val ANS_INT = 1
        const val ANS_F64 = 2
    }
}
