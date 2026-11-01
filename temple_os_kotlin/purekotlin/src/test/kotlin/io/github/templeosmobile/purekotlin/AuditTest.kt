package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.core.ui.Json
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The translation's two standing audits:
 *
 * - **purity**: generated Kotlin and Swift reach the HolyC runtime only through the native-module API
 *   (memory, natives, scheduling, exceptions); nothing in them can parse, compile or interpret HolyC.
 *   At run time Vm.exec refuses to run in a native kernel, and the parity runs check that a native
 *   kernel executed zero bytecode instructions.
 * - **coverage**: every bundled .HC file is classified in shared/native-translation/manifest.json; the
 *   translated ones have their Kotlin, Swift and image files; no source changed since translation.
 */
class AuditTest {
    private val repo = SHARED.parentFile
    private val kotlinGen = File(repo, "temple_os_kotlin/purekotlin/src/main/kotlin/io/github/templeosmobile/purekotlin/gen")
    private val swiftGen = File(repo, "temple_os_swift/TempleCore/Sources/PureSwift/Generated")

    /** Interpreter, compiler and kernel-scheduler entry points generated code must never name. */
    private val forbidden = listOf(
        "Vm.run", ".exec(", "vm.run", "Program.compile", ".compile(", ".session(", "Session(", "Parser(", "Lexer(", "CodeGen",
        // (the ExePrint natives may be called: in a native kernel they never compile, Program.nativeMode refuses it)
        "Quicken", "compileExprFunc", "pushCall", "callFunction", "runNested", "evalAtCompileTime", "Kernel(", "step(",
        "Op.", "Quick.",
    )

    @Test
    fun generatedCodeIsPure() {
        val files = (kotlinGen.listFiles()?.toList() ?: emptyList()) + (swiftGen.listFiles()?.toList() ?: emptyList())
        assertTrue("generated sources exist", files.size > 2)
        val hits = ArrayList<String>()
        for (f in files) {
            for ((n, line) in f.readLines().withIndex()) {
                val code = line.substringBefore("//").let { if (it.trimStart().startsWith("/**") || it.trimStart().startsWith("*")) "" else it }
                // natives are called by index (n_Name fields); a native's name only appears in quotes when resolved
                val stripped = code.replace(Regex("\"(?:[^\"\\\\]|\\\\.)*\""), "\"\"")
                for (w in forbidden) if (stripped.contains(w)) hits.add("${f.name}:${n + 1}: $w")
            }
        }
        assertTrue("generated code names interpreter/compiler entry points:\n" + hits.take(30).joinToString("\n"), hits.isEmpty())
    }

    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    @Test
    fun everySourceIsClassifiedAndCurrent() {
        @Suppress("UNCHECKED_CAST")
        val manifest = Json.parse(File(SHARED, "native-translation/manifest.json").readText()) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val sources = (manifest["sources"] as List<Map<String, Any?>>).associateBy { it["path"] as String }
        val bundled = File(SHARED, "bundled-fs.index").readLines().map { it.split('\t') }
            .filter { it.size > 2 && it[0] == "F" && it[1].uppercase().endsWith(".HC") }.map { "C:/" + it[1] }
        val problems = ArrayList<String>()
        for (p in bundled) if (p !in sources) problems.add("$p is not in the manifest (run the translator)")
        for ((p, s) in sources) {
            if (p !in bundled) problems.add("$p is in the manifest but not bundled")
            val status = s["status"] as String
            if (status !in setOf("translated", "not-compilable", "translation-blocked")) problems.add("$p: unknown status $status")
            @Suppress("UNCHECKED_CAST")
            for ((file, hash) in (s["closure"] as Map<String, Any?>)) {
                val f = File(SHARED, "bundled-fs/" + file.removePrefix("C:/"))
                if (!f.exists()) problems.add("$p: $file is missing")
                else if (sha256(f.readBytes()) != hash) problems.add("$p: $file changed since translation (stale)")
            }
            if (status == "translated") {
                // programs completed at run time have one module per specialization ("Class:MACRO=text,...")
                @Suppress("UNCHECKED_CAST")
                val variants = (s["variants"] as List<String>?)?.map { it.substringBefore(':') } ?: emptyList()
                for (m in variants.ifEmpty { listOf(s["module"] as String) }) {
                    if (!File(kotlinGen, "$m.kt").exists()) problems.add("$p: $m.kt missing")
                    if (!File(swiftGen, "$m.swift").exists()) problems.add("$p: $m.swift missing")
                    if (!File(SHARED, "runtime/native/$m.tosimg").exists()) problems.add("$p: $m.tosimg missing")
                }
            }
        }
        // the translator itself: generated code is stale when the translator or the compiler front end changed
        val md = MessageDigest.getInstance("SHA-256")
        val dirs = listOf("temple_os_kotlin/translator/src/main/kotlin", "temple_os_kotlin/core/src/main/kotlin/io/github/templeosmobile/core/holyc")
        for (f in dirs.flatMap { d -> File(repo, d).walkTopDown().filter { it.isFile && it.name.endsWith(".kt") }.toList() }.sortedBy { it.path }) {
            md.update(f.relativeTo(repo).path.toByteArray()); md.update(f.readBytes())
        }
        val fp = md.digest().joinToString("") { "%02x".format(it) }.take(32)
        if (manifest["generator"] != fp) problems.add("the translator or compiler front end changed since the code was generated (run the translator)")
        // the prelude's own sources
        @Suppress("UNCHECKED_CAST")
        val pre = manifest["prelude"] as Map<String, Any?>
        val rt = listOf("Prelude.HC", "PreludeDefines.HC", "GrLib.HC", "KernelClasses.HC", "DocLib.HC", "TaskLib.HC", "GraphicsCompat.HC").map { File(SHARED, "runtime/$it").readBytes() }.fold(ByteArray(0)) { a, b -> a + b }
        if (sha256(rt) != pre["sha256"]) problems.add("the runtime HolyC changed since translation (stale prelude)")
        // the compiled catalog agrees with the manifest
        NativePrograms.catalog = NativeCatalog
        val translated = sources.values.filter { it["status"] == "translated" }.map { it["path"] as String }.toSet()
        val catalog = NativeCatalog.programs.map { it.path }.toSet()
        if (translated != catalog) problems.add("catalog and manifest differ: ${(translated - catalog).take(5)} / ${(catalog - translated).take(5)}")
        assertTrue(problems.take(40).joinToString("\n"), problems.isEmpty())
        println("sources: ${sources.size}, translated: ${translated.size}, not compilable: ${sources.values.count { it["status"] == "not-compilable" }}, blocked: ${sources.values.count { it["status"] == "translation-blocked" }}")
    }
}
