package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

/** Runs original TempleOS graphics demos headlessly and saves frames as PNG. */
class GraphicsDemoTest {
    private val iso = File(REFERENCE, "templeos-iso")

    fun savePng(k: Kernel, name: String) {
        val img = BufferedImage(640, 480, BufferedImage.TYPE_INT_RGB)
        for (y in 0 until 480) for (x in 0 until 640) img.setRGB(x, y, k.palette[k.published[y * 640 + x].toInt() and 15])
        File("build/frames").mkdirs()
        ImageIO.write(img, "png", File("build/frames/$name.png"))
    }

    /** Boots, starts a program and runs it for [ms] of virtual time. */
    fun runFor(path: String, ms: Long, input: (Kernel, Long) -> Unit = { _, _ -> }): Kernel {
        val fs = HostDirFs(iso)
        val k = Kernel(TestEnv(fs), "demo")
        k.virtualTime = true
        k.boot()
        k.runProgram(path, fs.readFile(path)!!)
        var t = 0L
        while (k.now() < ms * 1_000_000L) {
            input(k, k.now() / 1_000_000)
            if (k.step(5_000_000) < 0) break
            if (++t > 2_000_000) break
        }
        return k
    }

    @Test
    fun bootTime() {
        val t0 = System.nanoTime()
        val k = Kernel(TestEnv(), "boot"); k.boot()
        val t1 = System.nanoTime()
        val k2 = Kernel(TestEnv(), "boot2"); k2.boot()
        val t2 = System.nanoTime()
        println("boot cold ${(t1 - t0) / 1_000_000} ms, warm ${(t2 - t1) / 1_000_000} ms, code ${k2.prog.code.size} ints, heap ${k2.mem.heapTop / 1024} KiB")
    }

    @Test
    fun lines() {
        assumeTrue("needs the gitignored ISO extraction in reference/templeos-iso", File(iso, "Demo/Graphics/Lines.HC").exists())
        val k = runFor("C:/Demo/Graphics/Lines.HC", 1500)
        assertNull(k.exitMessage)
        assertTrue(k.graphicsUsed)
        val distinct = k.published.toSet().size
        println("lines: frames=${k.frameCount} instr=${k.vm.instructionsExecuted} now=${k.now()/1000000}ms tasks=${k.tasks.map { it.state }} console=${k.console.plainText().take(200)}")
        val body = k.mem.ld8(k.gfx.grDc.toInt() + k.o.dc("body")).toInt()
        var drawn = 0
        for (i in 0 until 640 * 480) if (k.mem.ld1(body + i) != 0xFFL) drawn++
        println("grdc drawn=$drawn pubNonWhite=${k.published.count { it.toInt() != 15 }} pubVersion=${k.publishedVersion}")
        savePng(k, "Lines")
        assertTrue("expected colored lines, got $distinct colors", distinct >= 3)
    }
}
