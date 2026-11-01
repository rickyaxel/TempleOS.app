package io.github.templeosmobile.core.purenative

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import java.security.MessageDigest

/** The translated prelude: its data segment ([image], under the runtime's native/) and its module. */
class NativePreludeImage(
    val image: String,
    /** sha256 of the runtime HolyC it was translated from (Prelude, PreludeDefines, GrLib, KernelClasses). */
    val sourceHash: String,
    /** Number of prelude functions: program function indices start here. */
    val split: Int,
    val create: (NativeRuntime) -> NativeModule,
)

/** A translated program: its C:/ path, data segment, the sources it was translated from, and its module. */
class NativeProgramImage(
    val path: String,
    val image: String,
    /** sha256 of every source file the program's compilation read (the file and its #includes). */
    val closure: Map<String, String>,
    /**
     * Set when the translation cannot do what the program needs (e.g. "runtime_compile": it compiles
     * HolyC the user types): the app then offers Pure Terry instead.
     */
    val requiresTerry: String? = null,
    /** Programs completed at run time: units every variant shares (loaded before the choice is made). */
    val common: Int = 0,
    /**
     * Programs completed at run time (TreeCheckers: macros from a PopUp answer, `DefinePrint`): one
     * translation per possible choice. [image] and [create] are the first variant's, used for the common units.
     */
    val variants: List<NativeVariant> = emptyList(),
    val create: (NativeRuntime, NativeModule) -> NativeModule,
)

/** One specialization of a program completed at run time, selected by the macro texts the program defined. */
class NativeVariant(
    val image: String,
    /** Macro name -> the text `DefinePrint` gave it when this variant's source was compiled. */
    val defines: Map<String, String>,
    val create: (NativeRuntime, NativeModule) -> NativeModule,
)

/** What the generated code provides (the generated NativeCatalog object). */
interface NativeCatalogSource {
    val generator: String
    val prelude: NativePreludeImage
    val programs: List<NativeProgramImage>
}

/**
 * The app's registry of translated programs (Pure Kotlin mode). The app installs the generated
 * catalog at startup; the core never depends on generated code.
 */
object NativePrograms {
    @Volatile var catalog: NativeCatalogSource? = null

    private val byPath: Map<String, NativeProgramImage> by lazy { catalog?.programs?.associateBy { it.path.lowercase() } ?: emptyMap() }

    /** The translation of [path], if there is one. */
    fun find(path: String): NativeProgramImage? = byPath[path.lowercase()]

    /** Why [p] cannot run natively from [fs] now (a source file differs from the one translated), or null when it can. */
    fun staleReason(p: NativeProgramImage, fs: VirtualFs?): String? {
        if (fs == null) return "no file system"
        for ((file, hash) in p.closure) {
            val b = fs.readFile(file) ?: return "$file is missing"
            if (!sourceMatches(fs,file,b,hash)) return "$file was changed after translation"
        }
        return null
    }

    /** A leading // metadata line may change; every byte of executable text and attachments must match. */
    fun sourceMatches(fs:VirtualFs?,path:String,current:ByteArray,hash:String):Boolean {
        if(sha256(current)==hash) return true
        val original=(fs as? LayeredFs)?.bundledBytes(path) ?: return false
        if(sha256(original)!=hash || current.size<3 || original.size<3 || current[0]!=47.toByte() || current[1]!=47.toByte() || original[0]!=47.toByte() || original[1]!=47.toByte()) return false
        val a=current.indexOf(10);val b=original.indexOf(10)
        return a>=0 && b>=0 && current.take(a).none {it==0.toByte()} && current.copyOfRange(a,current.size).contentEquals(original.copyOfRange(b,original.size))
    }

    fun sha256(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
}

/**
 * Connects a kernel to the translated prelude and program (set as [Kernel.native] before boot).
 * Boot installs the [NativeRuntime] as the VM's engine and switches the program's compiler off.
 */
class NativeBinding(val prelude: NativePreludeImage, val program: NativeProgramImage?) {
    lateinit var runtime: NativeRuntime
        private set
    private lateinit var seg: Segment

    fun bootPrelude(k: Kernel): FuncSym {
        val rt = NativeRuntime(k.vm)
        runtime = rt
        k.vm.engine = rt
        k.prog.nativeMode = true
        seg = Segment(k.prog, k.vm.natives)
        val units = units(k, prelude.image)
        val init = seg.load(units.single()) ?: error("native prelude has no init function")
        val m = prelude.create(rt)
        m.bind(0, seg)
        rt.prelude = m
        rt.split = prelude.split
        return init
    }

    /** The program's chunks, loaded one by one as the kernel runs them. */
    fun session(k: Kernel): ChunkSource {
        val p = program ?: error("no native program bound")
        var units = units(k, p.image)
        var m = p.create(runtime, runtime.prelude)
        runtime.program = m
        programUnits = units
        return object : ChunkSource {
            private var i = 0
            override val answerKind: Int get() = Program.ANS_NONE
            override fun next(): FuncSym? {
                if (i == p.common && p.variants.isNotEmpty()) {
                    // the program has made its run-time choice: continue with the translation of that choice
                    val v = variantFor(k, p) ?: throw CompileError(
                        "this run-time choice has no translation (${p.variants.first().defines.keys.joinToString { "$it=" + defineText(k, it) }}); run it in Pure Terry")
                    units = units(k, v.image)
                    m = v.create(runtime, runtime.prelude)
                    for (j in 0 until i) m.bind(j, seg) // the common units, already loaded (same image text)
                    runtime.program = m
                    programUnits = units
                }
                // registry units are loaded by RegExe, where the program runs it
                while (i < units.size && units[i].registry != null) i++
                if (i >= units.size) return null
                val f = seg.load(units[i])
                m.bind(i, seg)
                i++
                return f ?: next()
            }
        }
    }

    /** Deferred original source units share this program's compiled module and symbol realm. */
    fun fileCurrent(k:Kernel,path:String):Boolean {val key=path.removeSuffix(".Z");val h=program?.closure?.entries?.firstOrNull{it.key.equals(key,true)}?.value ?: return false;val bytes=k.env.fs?.readFile(path) ?: return false;return hasFile(path) && NativePrograms.sourceMatches(k.env.fs,path,bytes,h)}
    fun hasFile(path:String)=programUnits.any {it.registry?.equals("file:"+path.removeSuffix(".Z"),true)==true}
    fun fileSession(k:Kernel,path:String):ChunkSource {
        val key="file:"+path.removeSuffix(".Z")
        val ids=programUnits.indices.filter {programUnits[it].registry?.equals(key,true)==true}
        if(ids.isEmpty()) throw CompileError("No compiled native source package for $path")
        val expected=program?.closure?.entries?.firstOrNull {it.key.equals(path.removeSuffix(".Z"),true)}?.value
        val bytes=k.env.fs?.readFile(path)
        if(expected==null || bytes==null || !NativePrograms.sourceMatches(k.env.fs,path,bytes,expected)) throw CompileError("Native source package changed: $path")
        var at=0
        return object:ChunkSource {
            override val answerKind:Int get()=Program.ANS_NONE
            override fun next():FuncSym? {
                if(at>=ids.size) return null
                val index=ids[at++];val result=seg.load(programUnits[index]);runtime.program!!.bind(index,seg);return result ?: next()
            }
        }
    }

    private fun defineText(k: Kernel, name: String): String? = k.defineStrs[name]?.let { k.mem.readStr(it.data.toLong()) }

    /** The variant whose macros have the texts the program defined, or null. */
    private fun variantFor(k: Kernel, p: NativeProgramImage): NativeVariant? =
        p.variants.firstOrNull { v -> v.defines.all { (n, text) -> defineText(k, n) == text } }

    private var programUnits: List<Segment.Unit> = emptyList()
    private val registryLoaded = HashSet<String>()

    /**
     * RegExe in a native program. The interpreter compiles the stored settings code (declarations such as
     * `F64 best_score=12.3456;`) into the program; the translator compiled the program's RegDft default the
     * same way, at the same point, so the globals and functions it creates are in a registry unit of the
     * image: load it (the same allocations), run its init, then give the declared globals the stored values.
     * Stored code that is not plain declarations with numeric constants is reported and the defaults stay.
     */
    fun regExe(k: Kernel, t: Task, path: String, stored: String): Long {
        val m = runtime.program ?: return 0
        var res = 0L
        if (registryLoaded.add(path)) {
            for ((i, u) in programUnits.withIndex()) {
                if (u.registry != path) continue
                val f = seg.load(u)
                m.bind(i, seg)
                if (f != null) res = k.vm.callFunction(t, k.prog.funcPtr(f))
            }
        }
        val decls = RegistryDecls.parse(stored)
        if (decls == null) {
            k.console.write("\$RED\$Registry $path: only declarations with numeric values can be read natively; using the defaults\$FG\$\n")
            return res
        }
        for ((name, v) in decls) {
            val g = k.prog.globals[name] as? GlobalSym ?: continue
            RegistryDecls.store(k.mem, g, v)
        }
        return res
    }

    private fun units(k: Kernel, image: String): List<Segment.Unit> = cache.getOrPut(image) {
        val bytes = k.env.runtimeFile("native/$image") ?: error("native image $image is missing")
        Segment.parse(String(bytes, Charsets.ISO_8859_1))
    }

    companion object {
        /** Parsed images (immutable once parsed), shared by every kernel. */
        private val cache = java.util.concurrent.ConcurrentHashMap<String, List<Segment.Unit>>()
    }
}

/**
 * Reads registry settings code that consists only of declarations with numeric initializers
 * (`I64 best_score0=0,best_score1=9999;` `F64 best_score=12.3456;`), which is all RegWrite
 * stores for the bundled programs, and stores the values as the compiler's constant initializers do.
 */
object RegistryDecls {
    class Value(val isFloat: Boolean, val i: Long, val f: Double)

    fun parse(src: String): List<Pair<String, Value>>? {
        val out = ArrayList<Pair<String, Value>>()
        var p = 0
        fun ws() { while (p < src.length && (src[p].isWhitespace())) p++ }
        fun ident(): String? {
            ws()
            val st = p
            while (p < src.length && (src[p].isLetterOrDigit() || src[p] == '_')) p++
            return if (p > st) src.substring(st, p) else null
        }
        while (true) {
            ws()
            if (p >= src.length) return out
            if (ident() == null) return null // the type
            while (true) {
                val name = ident() ?: return null
                ws()
                if (p >= src.length || src[p] != '=') return null
                p++; ws()
                val st = p
                if (p < src.length && (src[p] == '-' || src[p] == '+')) p++
                while (p < src.length && (src[p].isLetterOrDigit() || src[p] == '.')) p++
                val lit = src.substring(st, p)
                out.add(name to (number(lit) ?: return null))
                ws()
                if (p < src.length && src[p] == ',') { p++; continue }
                if (p < src.length && src[p] == ';') { p++; break }
                return null
            }
        }
    }

    fun number(s: String): Value? {
        val neg = s.startsWith("-")
        val b = s.removePrefix("-").removePrefix("+")
        if (b.isEmpty()) return null
        if (b.startsWith("0x") || b.startsWith("0X")) {
            val v = java.lang.Long.parseUnsignedLong(b.substring(2).ifEmpty { return null }, 16)
            return Value(false, if (neg) -v else v, 0.0)
        }
        if (b.all { it.isDigit() }) {
            val v = b.toBigInteger().toLong()
            return Value(false, if (neg) -v else v, 0.0)
        }
        val d = b.toDoubleOrNull() ?: return null
        return Value(true, 0, if (neg) -d else d)
    }

    /** Stores [v] into [g] as CodeGen.writeConst would (integers truncated to the width; F64 as bits). */
    fun store(mem: Arena, g: GlobalSym, v: Value) {
        val t = g.type
        val a = g.addr
        if (t is F64Type) { mem.st8(a, (if (v.isFloat) v.f else v.i.toDouble()).toRawBits()); return }
        if (!Types.isInt(t) && t !is PtrType) return
        val x = if (v.isFloat) v.f.toLong() else v.i
        when (t.size) { 1 -> mem.st1(a, x); 2 -> mem.st2(a, x); 4 -> mem.st4(a, x); else -> mem.st8(a, x) }
    }
}
