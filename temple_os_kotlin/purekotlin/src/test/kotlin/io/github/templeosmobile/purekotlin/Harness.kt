package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.purenative.*
import io.github.templeosmobile.core.bench.*
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import java.io.File

val SHARED: File = File(System.getProperty("templeos.shared") ?: "../../shared")

/** Kernel environment for differential tests: same runtime files, fixed entropy, logged sound (core [ScenarioEnv]). */
class ParityEnv(fs: VirtualFs) : ScenarioEnv(fs, System.getProperty("templeos.memmb")?.toIntOrNull() ?: 32, ::sharedRuntimeFile)

fun sharedRuntimeFile(name: String): ByteArray? = File(SHARED, "runtime/$name").takeIf { it.exists() }?.readBytes()

fun bundledFs(): VirtualFs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")),
    java.nio.file.Files.createTempDirectory("purekotlin").toFile().also { it.deleteOnExit() })

enum class Engine { TERRY, NATIVE; val core get() = if (this == TERRY) ScenarioEngine.TERRY else ScenarioEngine.NATIVE }

/** The core scenario runner over the repository's runtime and bundled drive (the app's benchmark mode runs the same code). */
val runner: ScenarioRunner by lazy { NativePrograms.catalog = NativeCatalog; ScenarioRunner(::bundledFs, ::sharedRuntimeFile) }

/** Boots [path] on [engine] in virtual time with tick-based time cost (identical for both engines). */
fun bootProgram(path: String, engine: Engine, fs: VirtualFs = bundledFs(), env: ParityEnv = ParityEnv(fs)): Pair<Kernel, ParityEnv> {
    NativePrograms.catalog = NativeCatalog
    return runner.boot(path, engine.core, env) to env
}

/** Advances [k] to virtual time [ms] (ms), stepping as the sweep tests do. Returns false once the program ended. */
fun advanceTo(k: Kernel, ms: Long): Boolean = ScenarioRunner.advanceTo(k, ms)
