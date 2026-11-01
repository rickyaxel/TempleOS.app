package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import org.junit.Test
import java.io.File

/**
 * Compiles every original TempleOS Demo program and reports which ones the
 * runtime accepts. Informational (does not fail); output goes to
 * build/census.txt. Enable with -Dtempleos.census=true.
 */
class CensusTest {
    @Test
    fun census() {
        if (System.getProperty("templeos.census") != "true") return
        val root = File(REFERENCE, "original-templeos")
        val files = File(root, "Demo").walkTopDown().filter { it.isFile && it.name.endsWith(".HC") }.sortedBy { it.path }.toList()
        val fs = HostDirFs(root)
        val sb = StringBuilder()
        var ok = 0
        val reasons = HashMap<String, Int>()
        for (f in files) {
            val rel = "C:/" + f.relativeTo(root).path
            val k = Kernel(TestEnv(fs), "census")
            k.virtualTime = true
            k.boot()
            val msg = try {
                k.prog.compile(SourceFile.parse(rel, f.readBytes()), rel.substringBeforeLast('/'), k.vfsProvider(), k.defines)
                null
            } catch (e: CompileError) { e.message } catch (e: Exception) { "CRASH $e" }
            if (msg == null) { ok++; sb.append("OK   $rel\n") } else {
                sb.append("FAIL $rel: $msg\n")
                val key = (msg.substringAfter(": ", msg)).replace(Regex("'[^']*'"), "'X'").take(60)
                reasons[key] = (reasons[key] ?: 0) + 1
            }
        }
        sb.append("\n$ok/${files.size} compile\n\nTop reasons:\n")
        reasons.entries.sortedByDescending { it.value }.take(40).forEach { sb.append("${it.value}  ${it.key}\n") }
        File("build/census.txt").writeText(sb.toString())
        println("census: $ok/${files.size}")
    }
}

/** Read-only VirtualFs over a host directory (tests only). */
class HostDirFs(private val root: File) : VirtualFs {
    private fun f(p: String) = File(root, p.removePrefix("C:/").removePrefix("C:"))
    override fun readFile(path: String) = f(path).let { if (it.isFile) it.readBytes() else null }
    override fun writeFile(path: String, data: ByteArray) = throw FsError("read-only")
    override fun exists(path: String) = f(path).exists()
    override fun isDir(path: String) = f(path).isDirectory
    override fun list(dir: String) = f(dir).listFiles()?.map { FsEntry(it.name, "$dir/${it.name}".replace("//", "/"), it.isDirectory, it.length(), it.lastModified(), true) }
    override fun stat(path: String) = f(path).let { if (it.exists()) FsEntry(it.name, path, it.isDirectory, it.length(), it.lastModified(), true) else null }
    override fun mkdir(path: String) = throw FsError("read-only")
    override fun delete(path: String, recursive: Boolean) = throw FsError("read-only")
    override fun move(from: String, to: String) = throw FsError("read-only")
    override fun isReadOnly(path: String) = true
}
