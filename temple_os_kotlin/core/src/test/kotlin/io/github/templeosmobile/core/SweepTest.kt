package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

/**
 * Runs every original Demo/Graphics and Demo/Games program for a few seconds of
 * virtual time with light synthetic input; records status and saves frames.
 * Informational. Enable with -Dtempleos.sweep=Games|Graphics|... (directory under Demo).
 */
class SweepTest {
    @Test
    fun sweep() {
        val which = System.getProperty("templeos.sweep") ?: return
        val iso = File(REFERENCE, "templeos-iso")
        val only = System.getProperty("templeos.only")
        // "Catalog": every program the apps ship (shared/program-manifests/catalog.json), run from the bundled drive
        val root = if (which == "Catalog") File(SHARED, "bundled-fs") else iso
        val fs: VirtualFs = if (which == "Catalog") LayeredFs(DirBundle(root, File(SHARED, "bundled-fs.index")), java.nio.file.Files.createTempDirectory("sweep").toFile()) else HostDirFs(root)
        val ids = HashMap<File, String>()
        val files = (when (which) {
            "Apps" -> File(iso, "Apps").listFiles()!!.mapNotNull { d -> File(d, "Run.HC").takeIf { it.exists() } }
            "Catalog" -> {
                val cat = io.github.templeosmobile.core.ui.Catalog.parse(File(SHARED, "program-manifests/catalog.json").readText())
                cat.programs.map { p -> File(root, p.path.removePrefix("C:/")).also { ids[it] = p.id } }
            }
            else -> File(iso, "Demo/$which").listFiles { f -> f.name.endsWith(".HC") }!!.toList()
        }).sortedBy { it.path }
            .filter { only == null || only.split(",").any { o -> it.path.contains(o) } }
        val report = StringBuilder()
        File("build/frames/$which").mkdirs()
        for (f in files) {
            val path = "C:/" + f.relativeTo(root).path
            val k = Kernel(TestEnv(fs), f.name)
            k.virtualTime = true
            k.boot()
            if (System.getProperty("templeos.profile") == "true") k.vm.profile = HashMap()
            val t0 = System.nanoTime()
            try { k.runProgram(path, f.readBytes()) } catch (e: Exception) {
                report.append("%-28s CRASH %s\n".format(ids[f] ?: f.name, e.toString().take(150))); continue
            }
            var steps = 0
            val limitNs = 3_000_000_000L
            var lastKey = 0L
            while (k.now() < limitNs && System.nanoTime() - t0 < 15_000_000_000L) {
                val ms = k.now() / 1_000_000
                // synthetic input: move mouse in a circle, click occasionally, press space/arrows
                // integer-only path so the Swift sweep can reproduce it exactly (parity checks)
                val ph = ((ms / 10) % 400).toInt()
                val mx = 170 + (if (ph < 200) ph else 400 - ph) * 3 / 2
                val my = 120 + ((ms / 7) % 240).toInt()
                k.post(KInput.Mouse(mx, my, (ms / 500) % 4 == 1L, false))
                if (ms - lastKey > 700) {
                    lastKey = ms
                    val (ch, sc) = if ((ms / 700) % 3 == 0L) Keys.special(Keys.SC_CURSOR_LEFT) else Keys.forChar(' '.code)
                    k.post(KInput.Key(ch, sc, true)); k.post(KInput.Key(ch, sc or Keys.SCF_KEY_UP, false))
                }
                // advance exactly 20 ms of virtual time per input tick (independent of host speed)
                k.virtualStopAt = (ms + 20) * 1_000_000
                var done = false
                try { while (k.now() < k.virtualStopAt) { if (k.step(1_000_000_000) < 0) { done = true; break } } } catch (e: Exception) {
                    k.console.write("rror: host exception $e\n"); break
                }
                if (done) break
                steps++
            }
            val realMs = (System.nanoTime() - t0) / 1_000_000
            val out = k.console.plainText()
            val err = out.lines().firstOrNull { it.contains("Compile error") || it.contains("Unhandled") || it.contains("rror:") || it.contains("draw_it") }
            val status = when {
                err != null -> "ERR  ${err.take(160)}"
                k.finished -> "EXIT ${k.exitMessage ?: ""}"
                else -> "RUN  frames=${k.frameCount} gfx=${k.graphicsUsed} instr=${k.vm.instructionsExecuted / 1_000_000}M real=${realMs}ms vt=${k.now() / 1_000_000}ms"
            }
            report.append("%-28s %s\n".format(ids[f] ?: if (which == "Apps") f.parentFile.name else f.name, status))
            k.vm.profile?.let { p ->
                val tot = p.values.sum().coerceAtLeast(1)
                p.entries.sortedByDescending { it.value }.take(12).forEach { report.append("      %5.1f%% %s\n".format(100.0 * it.value / tot, it.key)) }
            }
            if (k.graphicsUsed || k.frameCount > 0) {
                val img = BufferedImage(640, 480, BufferedImage.TYPE_INT_RGB)
                for (y in 0 until 480) for (x in 0 until 640) img.setRGB(x, y, k.palette[k.published[y * 640 + x].toInt() and 15])
                val base = ids[f] ?: if (which == "Apps") f.parentFile.name else f.nameWithoutExtension
                ImageIO.write(img, "png", File("build/frames/$which/$base.png"))
                // raw indexed frame for cross-platform parity checks (tools/parity/compare_frames.py)
                File("build/frames/$which/$base.idx").writeBytes(k.published)
            }
            k.terminate("done")
        }
        File("build/sweep-$which.txt").writeText(report.toString())
        println(report)
    }
}
