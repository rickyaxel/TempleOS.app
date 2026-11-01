package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import java.io.File
import java.security.MessageDigest

/** Records the files a compilation reads (the program's source closure, for stale-translation checks). */
class RecordingFs(private val inner: VirtualFs) : VirtualFs by inner {
    val reads = LinkedHashMap<String, ByteArray>()
    override fun readFile(path: String): ByteArray? = inner.readFile(path)?.also { if (!reads.containsKey(path)) reads[path] = it }
}

fun sha256(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

/** Where generated sources and images go. */
class Outputs(repo: Repo) {
    val kotlinDir = File(repo.root, "temple_os_kotlin/purekotlin/src/main/kotlin/io/github/templeosmobile/purekotlin/gen")
    val swiftDir = File(repo.root, "temple_os_swift/TempleCore/Sources/PureSwift/Generated")
    val imageDir = File(repo.root, "shared/runtime/native")
    val manifest = File(repo.root, "shared/native-translation/manifest.json")
    val report = File(repo.root, "shared/native-translation/translation-report.txt")
}

const val GENERATOR_VERSION = "1"
const val KOTLIN_PKG = "io.github.templeosmobile.purekotlin.gen"

class ProgramResult(
    val path: String,
    val className: String?,
    val status: String,
    val detail: String,
    val closure: Map<String, String>,
    val functions: Int,
    val machineFunctions: Int,
    val chunks: Int,
    /** Why the translation needs Pure Terry for part of what the program does (e.g. "runtime_compile"), or null. */
    val requiresTerry: String? = null,
    /** Programs completed at run time: one module per specialization (see [Capture.variants]), else empty. */
    val variants: List<VariantInfo> = emptyList(),
    /** Leading units all [variants] share (loaded before the program has made its choice). */
    val common: Int = 0,
)

/** A specialization's module and the run-time macro texts that select it. */
class VariantInfo(val className: String, val defines: Map<String, String>) {
    /** Manifest form: `Class:NAME=text,NAME=text` (macro texts are numbers or identifiers). */
    fun encode() = className + ":" + defines.entries.joinToString(",") { "${it.key}=${it.value}" }
    companion object {
        fun decode(s: String) = VariantInfo(s.substringBefore(':'),
            s.substringAfter(':').split(',').filter { it.isNotEmpty() }.associate { it.substringBefore('=') to it.substringAfter('=') }.toSortedMap())
    }
}

fun classNameFor(path: String): String {
    val rel = path.removePrefix("C:/").substringBeforeLast('.')
    return "N_" + Lowerer.ident(rel.replace('/', '_'))
}

/** Every bundled .HC file (the source inventory). */
fun bundledSources(repo: Repo): List<String> =
    repo.bundledIndex.readLines().map { it.split('\t') }.filter { it.size > 2 && it[0] == "F" && it[1].uppercase().endsWith(".HC") }.map { "C:/" + it[1] }.sorted()

fun translate(repo: Repo, only: Set<String>?, emitSwift: Boolean, force: Boolean = false) {
    val out = Outputs(repo)
    val base = Capture.fs(repo)
    val fs = RecordingFs(base)
    val t0 = System.nanoTime()

    // ---- prelude
    val pre = Capture.program(repo, fs, null)
    val split = pre.kernel.prog.funcs.size
    val runtimeHash = sha256(listOf("Prelude.HC", "PreludeDefines.HC", "GrLib.HC", "KernelClasses.HC", "DocLib.HC", "TaskLib.HC", "GraphicsCompat.HC").map { File(repo.runtime, it).readBytes() }.fold(ByteArray(0)) { a, b -> a + b })
    val preModel = ModuleModel("Prelude", true, "shared/runtime/Prelude.HC, PreludeDefines.HC, KernelClasses.HC, GrLib.HC (TempleOS V5.03 Adam/Gr, Menu, Ctrls, AMath, AMathODE, ASnd)", runtimeHash)
    val preB = ModuleBuilder(preModel, listOf(pre.prelude), null, pre.binNodes)
    preB.declareAllGlobals(pre.kernel.prog.globals)
    preB.lowerAll()
    val undefinedInPrelude = pre.kernel.prog.funcs.filter { it.index in 0 until split && !it.isNative && it.name.isNotEmpty() && !preB.defined.containsKey(it.index) && !it.name.startsWith("\$unused") }
    if (undefinedInPrelude.isNotEmpty()) preModel.diagnostics.add("declared but not defined in the prelude: ${undefinedInPrelude.joinToString { it.name }}")

    val preEvents = pre.prelude.events.map { evKey(it) }
    val results = java.util.Collections.synchronizedList(ArrayList<ProgramResult>())
    val models = java.util.Collections.synchronizedList(ArrayList<Pair<ModuleModel, List<CapturedUnit>>>())
    val sources = bundledSources(repo).filter { only == null || it in only || only.any { o -> it.contains(o) } }

    // incremental: a source whose recorded closure is unchanged, translated by the same generator against the
    // same runtime, keeps its earlier result and files
    val fingerprint = generatorFingerprint(repo)
    val prev = readManifest(out).associateBy { it.path }
    val prevHeader = manifestHeader(out)
    val reusable = !force && prevHeader["generator"] == fingerprint && prevHeader["runtime"] == runtimeHash
    val todo = ArrayList<String>()
    var reused = 0
    for (path in sources) {
        val r = prev[path]
        if (reusable && r != null && closureCurrent(base, r.closure) && outputsExist(out, r, emitSwift)) { results.add(r); reused++ }
        else todo.add(path)
    }

    // captures and lowering in parallel: each source has its own kernel; the prelude builder is shared (synchronized)
    val pool = java.util.concurrent.Executors.newFixedThreadPool(maxOf(1, minOf(8, Runtime.getRuntime().availableProcessors() - 2)))
    val jobs = todo.map { path -> pool.submit {
        val rfs = RecordingFs(base)
        val cap = Capture.program(repo, rfs, path)
        val closure = rfs.reads.filterKeys { it.uppercase().let { p -> p.endsWith(".HC") || p.endsWith(".HH") || p.endsWith(".DD") || p.endsWith(".Z") } }
            .mapValues { sha256(it.value) }.toSortedMap()
        if (cap.error != null && cap.error.startsWith("run-time source")) {
            // complete the source at build time, once per possible run-time choice (TreeCheckers' board size)
            val defined = cap.chunks.flatMap { u -> u.functions.flatMap { cf -> runTimeDefines(cf.body) } }.toSet()
            val vs = Capture.variants(repo, rfs, path, defined, cap.chunks.count { it.init != null })
            val variantClosure=rfs.reads.filterKeys { it.uppercase().let { p -> p.endsWith(".HC") || p.endsWith(".HH") || p.endsWith(".DD") || p.endsWith(".Z") } }.mapValues {sha256(it.value)}.toSortedMap()
            val r = vs?.let { translateVariants(path, it, variantClosure, preB, models) }
            results.add(r ?: ProgramResult(path, null, "translation-blocked", cap.error, closure, 0, 0, 0)); return@submit
        }
        if (cap.error != null) {
            results.add(ProgramResult(path, null, "not-compilable", cap.error, closure, 0, 0, 0)); return@submit
        }
        if (cap.prelude.events.map { evKey(it) } != preEvents) {
            results.add(ProgramResult(path, null, "translation-blocked", "prelude compiled differently for this program", closure, 0, 0, 0)); return@submit
        }
        val cls = classNameFor(path)
        val model = ModuleModel(cls, false, path, sha256((closure.entries.joinToString("\n") { "${it.key} ${it.value}" }).toByteArray()))
        val b = ModuleBuilder(model, cap.chunks, preB, cap.binNodes)
        b.lowerAll()
        val nFn = cap.chunks.sumOf { it.functions.size }
        if (model.diagnostics.isNotEmpty()) {
            results.add(ProgramResult(path, cls, "translation-blocked", model.diagnostics.joinToString("; "), closure, nFn, 0, cap.chunks.size)); return@submit
        }
        models.add(model to cap.chunks)
        // HolyC compiled at run time from text the program builds: ExePrint/ExePrint2 text is evaluated by the
        // native dynamic expression engine (core/dynexpr, TempleCore/DynExpr; what is outside its subset is a
        // compile error at run time, as TempleOS reports invalid text); a file compiled at run time (ExeFile)
        // needs Pure Terry
        val rt = if (model.natives.any { it == "ExeFile" } && cap.chunks.none {it.registry?.startsWith("file:")==true}) "runtime_compile" else null
        results.add(ProgramResult(path, cls, "translated", "", closure, nFn, model.functions.count { it.machine }, cap.chunks.size, rt))
    } }
    for (j in jobs) j.get()
    pool.shutdown()
    results.sortBy { it.path }
    models.sortBy { it.first.className }
    println("reused $reused unchanged sources, translated ${todo.size}")

    // ---- write (the prelude last: programs may have added fields for prelude globals)
    // a full run removes files of sources that are no longer translated (stale outputs)
    if (only == null) {
        val keep = results.flatMap { r -> listOfNotNull(r.className) + r.variants.map { it.className } }.toSet() + setOf("Prelude", "NativeCatalog")
        for (d in listOf(out.kotlinDir, out.imageDir, out.swiftDir)) d.listFiles()?.forEach { f -> if (f.nameWithoutExtension !in keep) f.delete() }
    }
    out.kotlinDir.mkdirs(); out.imageDir.mkdirs()
    for ((model, chunks) in models) {
        write(File(out.kotlinDir, "${model.className}.kt"), KotlinPrinter(model, KOTLIN_PKG, "Prelude").print())
        write(File(out.imageDir, "${model.className}.tosimg"), Image.write(chunks))
        if (emitSwift) { out.swiftDir.mkdirs(); write(File(out.swiftDir, "${model.className}.swift"), SwiftPrinter(model, "Prelude").print()) }
    }
    write(File(out.kotlinDir, "Prelude.kt"), KotlinPrinter(preModel, KOTLIN_PKG, "Prelude").print())
    write(File(out.imageDir, "Prelude.tosimg"), Image.write(listOf(pre.prelude)))
    if (emitSwift) write(File(out.swiftDir, "Prelude.swift"), SwiftPrinter(preModel, "Prelude").print())

    // a partial run keeps the other programs' earlier results (incremental translation)
    if (only != null) {
        val done = results.map { it.path }.toSet()
        for (r in readManifest(out)) if (r.path !in done) results.add(r)
        results.sortBy { it.path }
    }
    val translated = results.filter { it.status == "translated" }
    write(File(out.kotlinDir, "NativeCatalog.kt"), catalogKotlin(translated, runtimeHash, split))
    if (emitSwift) write(File(out.swiftDir, "NativeCatalog.swift"), catalogSwift(translated, runtimeHash, split))
    writeManifest(out, results, preModel, runtimeHash, split, fingerprint)
    val secs = (System.nanoTime() - t0) / 1e9
    println("translated ${translated.size} programs (+ prelude, ${preModel.functions.size} functions) of ${results.size} sources in %.1f s".format(secs))
    for (r in results.filter { it.status != "translated" }) println("  ${r.status.padEnd(20)} ${r.path}: ${r.detail.take(140)}")
    if (preModel.diagnostics.isNotEmpty()) println("prelude diagnostics:\n  " + preModel.diagnostics.joinToString("\n  "))
}

/**
 * Lowers each specialization of a program completed at run time to its own module (`<Class>_v<answer>`).
 * Null (translation-blocked) when the specializations do not share the units compiled before the choice
 * or one of them cannot be lowered.
 */
private fun translateVariants(path: String, vs: List<ProgramVariant>, closure: Map<String, String>, preB: ModuleBuilder,
                              models: MutableList<Pair<ModuleModel, List<CapturedUnit>>>): ProgramResult? {
    val first = vs.first().chunks
    fun same(a: CapturedUnit, b: CapturedUnit) = a.events.map { evKey(it) } == b.events.map { evKey(it) } &&
        a.functions.map { it.f.name } == b.functions.map { it.f.name } && a.symbols.map { it.first } == b.symbols.map { it.first }
    val common = (0 until vs.minOf { it.chunks.size }).takeWhile { i -> vs.all { same(it.chunks[i], first[i]) } }.count()
    if (common == 0 || vs.map { it.defines }.toSet().size != vs.size) return null
    val cls = classNameFor(path)
    val hash = sha256((closure.entries.joinToString("\n") { "${it.key} ${it.value}" }).toByteArray())
    val built = ArrayList<Pair<ModuleModel, List<CapturedUnit>>>()
    var nFn = 0; var machine = 0
    for (v in vs) {
        val model = ModuleModel("${cls}_v${v.answer}", false, "$path (run-time choice ${v.answer}: ${v.defines.entries.joinToString(", ") { "${it.key}=${it.value}" }})", hash)
        ModuleBuilder(model, v.chunks, preB, v.binNodes).lowerAll()
        if (model.diagnostics.isNotEmpty()) return null
        built.add(model to v.chunks)
        nFn += v.chunks.sumOf { it.functions.size }; machine += model.functions.count { it.machine }
    }
    models.addAll(built)
    return ProgramResult(path, cls, "translated", "specialized for ${vs.size} run-time choices", closure, nFn, machine, vs.first().chunks.size,
        null, vs.zip(built).map { (v, b) -> VariantInfo(b.first.className, v.defines) }, common)
}

private fun evKey(e: SegEvent): String = when (e) {
    is SegEvent.Global -> "g${e.addr}:${e.size}"
    is SegEvent.Str -> "s${e.addr}:${latin1(e.bytes)}"
    is SegEvent.Bin -> "b${e.addr}:${e.bytes.size}"
    is SegEvent.Const -> "c${e.addr}:${e.width}:${e.value}"
}

/** Images are Latin-1 (TempleOS identifiers are CP437 bytes); sources are UTF-8. */
private fun write(f: File, text: String) {
    val cs = if (f.name.endsWith(".tosimg")) Charsets.ISO_8859_1 else Charsets.UTF_8
    f.parentFile.mkdirs()
    if (f.exists() && f.readText(cs) == text) return
    f.writeText(text, cs)
}

private fun catalogKotlin(ps: List<ProgramResult>, runtimeHash: String, split: Int): String {
    val sb = StringBuilder()
    sb.append("// GENERATED by the TempleOS HolyC-to-native translator. Do not edit.\n")
    sb.append("@file:Suppress(\"ClassName\")\n\npackage $KOTLIN_PKG\n\nimport io.github.templeosmobile.core.purenative.*\n\n")
    sb.append("/** Every program translated to Kotlin, with the source hashes it was translated from. */\n")
    sb.append("object NativeCatalog : NativeCatalogSource {\n")
    sb.append("    override val generator = \"$GENERATOR_VERSION\"\n")
    sb.append("    override val prelude = NativePreludeImage(\"Prelude.tosimg\", \"$runtimeHash\", $split) { rt -> Prelude(rt) }\n")
    sb.append("    override val programs = listOf(\n")
    for (p in ps) {
        sb.append("        NativeProgramImage(\"${p.path}\", \"${p.variants.firstOrNull()?.className ?: p.className}.tosimg\", mapOf(")
        sb.append(p.closure.entries.joinToString(", ") { "\"${it.key}\" to \"${it.value}\"" })
        sb.append("), ${p.requiresTerry?.let { "\"$it\"" } ?: "null"}")
        if (p.variants.isNotEmpty()) {
            // completed at run time: the specializations, chosen by the macros the program defines (NativeBinding)
            sb.append(", ${p.common}, listOf(\n")
            for (v in p.variants) sb.append("            NativeVariant(\"${v.className}.tosimg\", mapOf(" + v.defines.entries.joinToString(", ") { "${jstr(it.key)} to ${jstr(it.value)}" } +
                ")) { rt, pre -> ${v.className}(rt, pre as Prelude) },\n")
            sb.append("        )")
        }
        val create = p.variants.firstOrNull()?.className ?: p.className
        sb.append(") { rt, pre -> $create(rt, pre as Prelude) },\n")
    }
    sb.append("    )\n}\n")
    return sb.toString()
}

private fun catalogSwift(ps: List<ProgramResult>, runtimeHash: String, split: Int): String {
    val sb = StringBuilder()
    sb.append("// GENERATED by the TempleOS HolyC-to-native translator. Do not edit.\n")
    sb.append("import TempleCore\n\n")
    sb.append("/// Every program translated to Swift, with the source hashes it was translated from.\n")
    sb.append("public enum NativeCatalog {\n")
    sb.append("    public static let source = NativeCatalogSource(generator: \"$GENERATOR_VERSION\",\n")
    sb.append("        prelude: NativePreludeImage(image: \"Prelude.tosimg\", sourceHash: \"$runtimeHash\", split: $split) { rt in Prelude(rt) },\n")
    sb.append("        programs: [\n")
    for (p in ps) {
        sb.append("            NativeProgramImage(path: \"${p.path}\", image: \"${p.variants.firstOrNull()?.className ?: p.className}.tosimg\", closure: [")
        sb.append(if (p.closure.isEmpty()) ":" else p.closure.entries.joinToString(", ") { "\"${it.key}\": \"${it.value}\"" })
        sb.append("], requiresTerry: ${p.requiresTerry?.let { "\"$it\"" } ?: "nil"}")
        if (p.variants.isNotEmpty()) {
            sb.append(", common: ${p.common}, variants: [\n")
            for (v in p.variants) sb.append("                NativeVariant(image: \"${v.className}.tosimg\", defines: [" + v.defines.entries.joinToString(", ") { "${jstr(it.key)}: ${jstr(it.value)}" } +
                "]) { rt, pre in ${v.className}(rt, pre as! Prelude) },\n")
            sb.append("            ]")
        }
        val create = p.variants.firstOrNull()?.className ?: p.className
        sb.append(") { rt, pre in $create(rt, pre as! Prelude) },\n")
    }
    sb.append("        ])\n}\n")
    return sb.toString()
}

private fun jstr(s: String): String {
    val sb = StringBuilder("\"")
    for (c in s) when {
        c == '"' -> sb.append("\\\"")
        c == '\\' -> sb.append("\\\\")
        c.code < 32 || c.code > 126 -> sb.append("\\u%04x".format(c.code))
        else -> sb.append(c)
    }
    return sb.append('"').toString()
}

private fun writeManifest(out: Outputs, results: List<ProgramResult>, pre: ModuleModel, runtimeHash: String, split: Int, fingerprint: String) {
    val sb = StringBuilder()
    sb.append("{\n  \"generator\": \"$fingerprint\",\n  \"runtime\": \"$runtimeHash\",\n  \"source_version\": \"TempleOS V5.03\",\n")
    sb.append("  \"prelude\": {\"sha256\": \"$runtimeHash\", \"functions\": ${pre.functions.size}, \"machine_functions\": ${pre.functions.count { it.machine }}, \"split\": $split},\n")
    sb.append("  \"sources\": [\n")
    sb.append(results.joinToString(",\n") { r ->
        "    {\"path\": ${jstr(r.path)}, \"status\": ${jstr(r.status)}, \"module\": ${r.className?.let { jstr(it) } ?: "null"}, " +
            "\"functions\": ${r.functions}, \"machine_functions\": ${r.machineFunctions}, \"chunks\": ${r.chunks}, " +
            "\"requires_terry\": ${r.requiresTerry?.let { jstr(it) } ?: "null"}, " +
            (if (r.variants.isEmpty()) "" else "\"common\": ${r.common}, \"variants\": [${r.variants.joinToString(", ") { jstr(it.encode()) }}], ") +
            "\"detail\": ${jstr(r.detail)}, \"closure\": {${r.closure.entries.joinToString(", ") { "${jstr(it.key)}: ${jstr(it.value)}" }}}}"
    })
    sb.append("\n  ]\n}\n")
    write(out.manifest, sb.toString())
}

/** Results of the previous run, from the manifest (for partial runs). */
private fun readManifest(out: Outputs): List<ProgramResult> {
    if (!out.manifest.exists()) return emptyList()
    val res = ArrayList<ProgramResult>()
    val text = out.manifest.readText()
    val rx = Regex("""\{"path": "([^"]*)", "status": "([^"]*)", "module": (null|"[^"]*"), "functions": (\d+), "machine_functions": (\d+), "chunks": (\d+), "requires_terry": (null|"[^"]*"), (?:"common": (\d+), "variants": \[([^\]]*)\], )?"detail": "((?:[^"\\]|\\.)*)", "closure": \{([^}]*)\}\}""")
    for (m in rx.findAll(text)) {
        val closure = Regex(""""([^"]*)": "([^"]*)"""").findAll(m.groupValues[11]).associate { it.groupValues[1] to it.groupValues[2] }.toSortedMap()
        val variants = Regex(""""([^"]*)"""").findAll(m.groupValues[9]).map { VariantInfo.decode(it.groupValues[1]) }.toList()
        res.add(ProgramResult(m.groupValues[1], m.groupValues[3].removeSurrounding("\"").takeIf { it != "null" }, m.groupValues[2],
            m.groupValues[10].replace("\\\"", "\"").replace("\\\\", "\\"), closure, m.groupValues[4].toInt(), m.groupValues[5].toInt(), m.groupValues[6].toInt(),
            m.groupValues[7].removeSurrounding("\"").takeIf { it != "null" }, variants, m.groupValues[8].toIntOrNull() ?: 0))
    }
    return res
}

/**
 * Identifies the translation itself: the translator's sources and the compiler front end it reuses.
 * Any change regenerates everything (a changed rule may change any program's code).
 */
fun generatorFingerprint(repo: Repo): String {
    val dirs = listOf("temple_os_kotlin/translator/src/main/kotlin", "temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/holyc")
    val files = dirs.flatMap { d -> File(repo.root, d).walkTopDown().filter { it.isFile && it.name.endsWith(".kt") }.toList() }.sortedBy { it.path }
    val md = MessageDigest.getInstance("SHA-256")
    for (f in files) { md.update(f.relativeTo(repo.root).path.toByteArray()); md.update(f.readBytes()) }
    return md.digest().joinToString("") { "%02x".format(it) }.take(32)
}

private fun manifestHeader(out: Outputs): Map<String, String> {
    if (!out.manifest.exists()) return emptyMap()
    val t = out.manifest.readText().take(400)
    return listOf("generator", "runtime").mapNotNull { k -> Regex("\"$k\": \"([0-9a-f]+)\"").find(t)?.let { k to it.groupValues[1] } }.toMap()
}

private fun closureCurrent(fs: VirtualFs, closure: Map<String, String>): Boolean =
    closure.isNotEmpty() && closure.all { (f, h) -> fs.readFile(f)?.let { sha256(it) == h } ?: false }

private fun outputsExist(out: Outputs, r: ProgramResult, swift: Boolean): Boolean {
    val m = r.className ?: return r.status != "translated"
    val names = if (r.variants.isEmpty()) listOf(m) else r.variants.map { it.className }
    return names.all { n -> File(out.kotlinDir, "$n.kt").exists() && File(out.imageDir, "$n.tosimg").exists() && (!swift || File(out.swiftDir, "$n.swift").exists()) }
}
