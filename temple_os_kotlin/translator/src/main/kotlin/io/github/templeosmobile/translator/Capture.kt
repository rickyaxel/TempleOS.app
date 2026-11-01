package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import java.io.File

/** One arena effect of compilation, in the order the compiler made it (the data segment). */
sealed class SegEvent {
    class Global(val addr: Int, val size: Int) : SegEvent()
    class Str(val bytes: ByteArray, val addr: Int) : SegEvent()
    class Bin(val bytes: ByteArray, val addr: Int) : SegEvent()
    class Const(val addr: Int, val width: Int, val value: Long, val isString: Boolean) : SegEvent()
}

class CapturedFunction(val f: FuncSym, val body: Stmt, val unit: Int)

/**
 * A compilation unit (the prelude) or chunk (a program's top-level statements up to the next
 * executable one, TempleOS JIT order): its data-segment events, the functions it compiled, its
 * init function and the symbols it defined or redefined.
 */
class CapturedUnit(val index: Int, val name: String) {
    val events = ArrayList<SegEvent>()
    val functions = ArrayList<CapturedFunction>()
    var init: FuncSym? = null
    /** prog.globals entries this unit added or replaced, in insertion order. */
    val symbols = ArrayList<Pair<String, Sym>>()
    /** prog.classes entries this unit added or replaced. */
    val classes = ArrayList<Pair<String, ClassType>>()
    /** Diagnostics raised while compiling this unit. */
    val notes = ArrayList<String>()
    /** Set for the unit RegExe compiles from a registry entry (its path): loaded by the native RegExe. */
    var registry: String? = null
    val services = ArrayList<String>()
    val constants = LinkedHashMap<String,Long>()
}

/** Records units, functions and data-segment events through [CompileObserver]. */
class Recorder(private val prog: Program,private val defines:()->Map<String,List<Token>> = {emptyMap()}) : CompileObserver {
    private val servicesBefore=HashSet<String>()
    private val constantsBefore=HashMap<String,Long>()
    val units = ArrayList<CapturedUnit>()
    private var cur: CapturedUnit? = null
    private var globalsBefore: Map<String, Sym> = emptyMap()
    private var classesBefore: Map<String, ClassType> = emptyMap()
    var evalAtCompileTime = 0
    /** Address of each binary literal node (first placement). */
    val binNodes = java.util.IdentityHashMap<Expr, Int>()

    /** Nesting depth: a compile-time evaluation ($eval, e.g. `b_head[mp_cnt]`) compiles inside the unit being compiled. */
    private var depth = 0

    override fun unitStart(name: String) {
        if (depth++ > 0) return // its arena effects and function belong to the enclosing unit, in order
        cur = CapturedUnit(units.size, name)
        globalsBefore = HashMap(prog.globals)
        classesBefore = HashMap(prog.classes)
    }

    override fun unitEnd(init: FuncSym?) {
        if (--depth > 0) return
        val u = cur ?: return
        u.init = init
        u.services.addAll(prog.requiredServices.filter {servicesBefore.add(it)})
        for((name,raw) in defines()) {
            val ts=raw.filter {it.text!="(" && it.text!=")"}
            val v=if(ts.size==1 && ts[0].kind in listOf(T.INT,T.CHAR)) ts[0].ival else if(ts.size==2 && ts[0].text=="-" && ts[1].kind==T.INT) -ts[1].ival else continue
            if(constantsBefore.put(name,v)!=v) u.constants[name]=v
        }
        // symbols in a stable order: by name (HashMap iteration order is not deterministic across JVMs)
        for ((n, s) in prog.globals.entries.sortedBy { it.key }) if (globalsBefore[n] !== s) u.symbols.add(n to s)
        for ((n, c) in prog.classes.entries.sortedBy { it.key }) if (classesBefore[n] !== c) u.classes.add(n to c)
        units.add(u)
        cur = null
    }

    override fun function(f: FuncSym, body: Stmt) { cur?.functions?.add(CapturedFunction(f, body, cur!!.index)) }
    override fun global(addr: Int, size: Int) { cur?.events?.add(SegEvent.Global(addr, size)) }
    override fun string(bytes: ByteArray, addr: Int) { cur?.events?.add(SegEvent.Str(bytes, addr)) }
    override fun bin(bytes: ByteArray, addr: Int) { cur?.events?.add(SegEvent.Bin(bytes, addr)) }
    override fun binLit(e: Expr, addr: Int) { binNodes.putIfAbsent(e, addr) }
    override fun constWrite(addr: Int, width: Int, value: Long, isString: Boolean) { cur?.events?.add(SegEvent.Const(addr, width, value, isString)) }
}

/** The repository layout the translator reads and writes. */
class Repo(val root: File) {
    val shared = File(root, "shared")
    val runtime = File(shared, "runtime")
    val bundled = File(shared, "bundled-fs")
    val bundledIndex = File(shared, "bundled-fs.index")
    val catalog = File(shared, "program-manifests/catalog.json")

    companion object {
        fun locate(): Repo {
            System.getProperty("templeos.repo")?.let { return Repo(File(it)) }
            var d: File? = File(".").absoluteFile
            while (d != null) {
                if (File(d, "shared/runtime/Prelude.HC").exists()) return Repo(d)
                d = d.parentFile
            }
            error("cannot find the repository root (shared/runtime/Prelude.HC)")
        }
    }
}

/** Kernel environment for build-time compilation: bundled drive read-only, nothing runs in real time. */
class BuildEnv(private val repo: Repo, override val fs: VirtualFs) : KernelEnv {
    override fun runtimeFile(name: String): ByteArray? = File(repo.runtime, name).takeIf { it.exists() }?.readBytes()
    override fun entropy(): Long = 12345
    /** Large programs (Talons: 96 MiB of globals) compile only with a large arena; addresses do not depend on the limit. */
    override val memoryLimit: Int get() = 512 shl 20

    /** Variant capture (programs run at build time): the answer to the first PopUp, and the choices it offered. */
    var firstAnswer: Long? = null
    var firstChoices: List<Long>? = null
    override fun popupRequested(kernel: Kernel, req: PopupRequest) {
        val choices = req.items.map { it.value }.filter { it != -1L }
        val first = firstChoices == null
        if (first) firstChoices = choices
        req.result = (if (first) firstAnswer else null) ?: choices.firstOrNull() ?: -1
    }
}

/**
 * One specialization of a program whose later source depends on a run-time choice: the units compiled
 * when the first PopUp was answered [answer], and the macros the program had defined at run time then.
 */
class ProgramVariant(val answer: Long, val chunks: List<CapturedUnit>, val defines: Map<String, String>, val binNodes: Map<Expr, Int>)

/** A whole program as compiled for one kernel: the prelude unit and the program's chunks. */
class ProgramCapture(val path: String, val kernel: Kernel, val prelude: CapturedUnit, val chunks: List<CapturedUnit>, val error: String?,
                     val binNodes: Map<Expr, Int> = emptyMap())

/** Names [body] defines as macros at run time (DefinePrint/DefineLoad/DefineLstLoad with a constant name). */
fun runTimeDefines(body: Stmt): List<String> {
    val out = ArrayList<String>()
    object : AstWalk() {
        override fun expr(e: Expr) {
            if (e is Call && e.fn?.isNative == true && e.fn!!.name in setOf("DefinePrint", "DefineLoad", "DefineLstLoad"))
                (e.args.getOrNull(0) as? StrLit)?.let { out.add(latin1(it.bytes)) }
            super.expr(e)
        }
    }.stmt(body)
    return out
}

/** RegDft/RegExe calls in a chunk's top-level code, in evaluation order. */
fun registryCalls(body: Stmt): List<Call> {
    val out = ArrayList<Call>()
    object : AstWalk() {
        override fun expr(e: Expr) {
            super.expr(e)
            if (e is Call && e.fn?.isNative == true && (e.fn!!.name == "RegDft" || e.fn!!.name == "RegExe")) out.add(e)
        }
    }.stmt(body)
    return out
}

object Capture {
    /**
     * Programs whose source is completed at run time (TreeCheckers: DefinePrint macros from the board size
     * chosen in a PopUp) are compiled once per possible answer of that PopUp: the program runs at build
     * time on the interpreter, in virtual time, until its source is fully compiled (TempleOS JIT order),
     * with the answer given; the units compiled and the macro texts defined are recorded. The native
     * program later loads the variant whose macros equal the ones it defined itself. Returns null when
     * the program's source does not become complete that way (it compiles at run time from other input).
     */
    fun variants(repo: Repo, fs: VirtualFs, path: String, defined: Set<String>, staticChunks: Int): List<ProgramVariant>? {
        val probe = runPast(repo, fs, path, null, staticChunks) ?: return null
        val choices = probe.second ?: return listOf(variantOf(probe.first,0,defined))
        probe.first.first.terminate("translated")
        if (choices.isEmpty() || choices.size > 32) return null
        return choices.map { v -> runPast(repo, fs, path, v, staticChunks)?.first?.let { variantOf(it, v, defined) } ?: return null }
    }

    private fun variantOf(r: Pair<Kernel, Recorder>, answer: Long, defined: Set<String>): ProgramVariant {
        val (k, rec) = r
        val defs = defined.sorted().associateWith { n -> k.defineStrs[n]?.let { k.vm.mem.readStr(it.data.toLong()) } ?: "" }
        k.terminate("translated")
        return ProgramVariant(answer, rec.units.drop(1), defs, rec.binNodes)
    }

    /**
     * Runs [path] on the interpreter (virtual time, the first PopUp answered [answer]) until it has compiled more
     * chunks than the static capture could ([staticChunks], the chunks compiled before the error), then compiles the rest of its source without running
     * it. Returns the kernel and recorder, and the first PopUp's choices; null when the run does not get there.
     */
    private fun runPast(repo: Repo, fs: VirtualFs, path: String, answer: Long?, staticChunks: Int): Pair<Pair<Kernel, Recorder>, List<Long>?>? {
        val env = BuildEnv(repo, fs)
        env.firstAnswer = answer
        val k = Kernel(env, "translate")
        k.virtualTime = true
        val rec = Recorder(k.prog) {k.defines}
        k.prog.observer = rec
        k.boot()
        k.runProgram(path, fs.readFile(path) ?: return null)
        k.virtualStopAt = 20_000_000_000L
        fun compiled() = rec.units.drop(1).count { it.init != null }
        while (compiled() <= staticChunks && !k.finished && k.now() < k.virtualStopAt) if (k.step(1_000_000_000) < 0) break
        val ok = compiled() > staticChunks && !k.finished && k.exitMessage == null &&
            try { k.compileRestOfProgram(); true } catch (e: CompileError) { false }
        if (System.getenv("TEMPLEOS_DEBUGVARIANTS") != null) System.err.println("variant run $path answer=$answer: ok=$ok units=${rec.units.size} exit=${k.exitMessage} now=${k.now()} choices=${env.firstChoices}")
        if (!ok) { k.terminate("translated"); return null }
        dynamicSources(fs,path,k,rec)
        return (k to rec) to env.firstChoices
    }

    private var overlay: File? = null

    fun fs(repo: Repo): VirtualFs {
        val o = overlay ?: java.nio.file.Files.createTempDirectory("templeos-translate").toFile().also { it.deleteOnExit(); overlay = it }
        return LayeredFs(DirBundle(repo.bundled, repo.bundledIndex), o)
    }

    private fun dynamicSources(fs:VirtualFs,path:String,k:Kernel,rec:Recorder) {
        var uses=false
        object:AstWalk() {override fun expr(e:Expr) {if(e is Call && e.fn?.name in setOf("ExeFile","TaskExe")) uses=true;super.expr(e)}}.also {walk->rec.units.drop(1).forEach {u->u.functions.forEach {walk.stmt(it.body)}}}
        if(!uses) return
        val root=Paths.parent(path)
        for(dir in listOf("AIs","Examples")) for(entry in fs.list("$root/$dir").orEmpty().sortedBy {it.name}) {
            if(entry.isDir || !entry.name.endsWith(".HC",true)) continue
            val start=rec.units.size
            val source=fs.readFile(entry.path) ?: continue
            val session=k.prog.session(SourceFile.parse(entry.path,source),Paths.parent(entry.path),k.vfsProvider(),k.defines)
            while(session.next()!=null) {}
            for(unit in rec.units.drop(start)) unit.registry="file:${entry.path}"
        }
    }

    /** Boots a kernel with a recorder (the prelude is captured), then compiles [path] chunk by chunk without running it. */
    fun program(repo: Repo, fs: VirtualFs, path: String?): ProgramCapture {
        val k = Kernel(BuildEnv(repo, fs), "translate")
        k.virtualTime = true
        val rec = Recorder(k.prog) {k.defines}
        k.prog.observer = rec
        k.boot()
        val prelude = rec.units.single()
        // every later compile-time evaluation would read run-time state the translator does not have
        val evalHook = k.prog.evalAtCompileTime
        k.prog.evalAtCompileTime = { e -> rec.evalAtCompileTime++; evalHook?.invoke(e) }
        if (path == null) return ProgramCapture("", k, prelude, emptyList(), null)
        var error: String? = null
        try {
            val src = fs.readFile(path) ?: error("no such file $path")
            val dir = Paths.parent(path)
            val session = k.prog.session(SourceFile.parse(path, src), dir, k.vfsProvider(), k.defines)
            val regDefaults = HashMap<String, ByteArray>()
            while (true) {
                val f = session.next() ?: break
                val body = rec.units.last().functions.lastOrNull { it.f === f }?.body ?: continue
                // TempleOS registry: RegExe compiles the stored settings code, which declares globals
                // the rest of the program uses (I64 best_score=...;). Compile the default as RegExe would,
                // at the same point, so later chunks see those globals (Natives RegExe at run time).
                for (call in registryCalls(body)) {
                    val name = call.fn!!.name
                    val p0 = (call.args.getOrNull(0) as? StrLit)?.let { latin1(it.bytes) } ?: continue
                    if (name == "RegDft") (call.args.getOrNull(1) as? StrLit)?.let { if (!regDefaults.containsKey(p0)) regDefaults[p0] = it.bytes }
                    else if (name == "RegExe") {
                        val code = regDefaults[p0] ?: continue
                        val rs = k.prog.session(SourceFile.parse("C:/Home/Registry.HC", code), "C:/Home", k.vfsProvider(), k.defines, answers = true)
                        while (rs.next() != null) rec.units.last().registry = p0
                    }
                }
            }
            dynamicSources(fs,path,k,rec)
        } catch (e: CompileError) {
            error = "compile error: ${e.message}"
            // TempleOS JIT programs may complete their own source at run time (DefinePrint: TreeCheckers' board
            // size from a PopUp): such source cannot be compiled ahead of time
            val defined = rec.units.drop(1).flatMap { u -> u.functions.flatMap { cf -> runTimeDefines(cf.body) } }.toSet()
            val missing = Regex("undefined identifier '([^']+)'").find(e.message ?: "")?.groupValues?.get(1)
            if (missing != null && missing in defined)
                error = "run-time source: macros defined by DefinePrint while the program runs are used by its later code (${e.message})"
        } catch (e: Exception) {
            error = "translator capture failed: $e"
        }
        if (rec.evalAtCompileTime > 0) rec.units.last().notes.add("compile-time evaluation used ${rec.evalAtCompileTime} times")
        return ProgramCapture(path, k, prelude, rec.units.drop(1), error, rec.binNodes)
    }
}
