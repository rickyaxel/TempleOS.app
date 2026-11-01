package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Json
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

/**
 * Opt-in: replays the reference-VM capture plans (tools/reference-vm/catalog-scenarios.json) on the
 * Kotlin kernel in virtual time and saves a frame at every "shot", so the original TempleOS
 * screendumps (tools/reference-vm/capture_catalog.py) can be compared with the app's picture
 * (tools/fidelity/compare_vm_frames.py). The plan's waits are wall time on the VM and virtual time
 * here; random sequences differ, so the comparison is of layout, geometry, colours and text.
 *
 *   ./gradlew :core:test --tests '*VmPlanFramesTest*' -Dtempleos.vmplan=all|id1,id2
 * Frames: build/vm-plan-frames/<id>/<shot>.png
 */
class VmPlanFramesTest {
    private fun qcode(name: String): Pair<Int, Long> = when (name) {
        "spc" -> Keys.forChar(' '.code)
        "ret" -> Keys.forChar('\n'.code)
        "esc" -> Keys.forChar(Keys.CH_ESC)
        "tab" -> Keys.forChar('\t'.code)
        "backspace" -> Keys.forChar(Keys.CH_BACKSPACE)
        "up" -> Keys.special(Keys.SC_CURSOR_UP)
        "down" -> Keys.special(Keys.SC_CURSOR_DOWN)
        "left" -> Keys.special(Keys.SC_CURSOR_LEFT)
        "right" -> Keys.special(Keys.SC_CURSOR_RIGHT)
        "ctrl" -> Keys.special(Keys.SC_CTRL, ctrl = true)
        "shift" -> Keys.special(Keys.SC_SHIFT, shift = true)
        "alt" -> Keys.special(Keys.SC_ALT, alt = true)
        else -> if (name.length == 1) Keys.forChar(name[0].code)
            else if (name.startsWith("f") && name.substring(1).toIntOrNull() != null) Keys.special(Keys.SC_F1 + name.substring(1).toInt() - 1)
            else error("key $name")
    }

    private fun save(k: Kernel, f: File) {
        f.parentFile.mkdirs()
        val img = BufferedImage(640, 480, BufferedImage.TYPE_INT_RGB)
        synchronized(k.publishLock) {
            for (y in 0 until 480) for (x in 0 until 640) img.setRGB(x, y, k.palette[k.published[y * 640 + x].toInt() and 15])
        }
        ImageIO.write(img, "png", f)
        File(f.path.removeSuffix(".png") + ".win").writeText(k.publishedWindow.joinToString(","))
    }

    @Test fun frames() {
        val sel = System.getProperty("templeos.vmplan") ?: return
        @Suppress("UNCHECKED_CAST")
        val plans = Json.parse(File(SHARED, "../tools/reference-vm/catalog-scenarios.json").readText()) as Map<String, List<List<Any?>>>
        @Suppress("UNCHECKED_CAST")
        val cat = ((Json.parse(File(SHARED, "program-manifests/catalog.json").readText()) as Map<String, Any?>)["programs"] as List<Map<String, Any?>>)
            .associateBy { it["id"] as String }
        val ids = if (sel == "all") plans.keys.sorted() else sel.split(",")
        for (id in ids) {
            val plan = plans[id] ?: continue
            val prog = cat[id]?.get("path") as? String ?: continue
            val dir = kotlin.io.path.createTempDirectory("vmplan").toFile()
            try {
                val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), dir)
                val env = object : TestEnv(fs) { override val memoryLimit: Int get() = 96 shl 20 }
                val k = Kernel(env, prog.substringAfterLast('/'))
                k.virtualTime = true
                k.boot()
                k.runProgram(prog, fs.readFile(prog)!!)
                val wallEnd = System.nanoTime() + 240_000_000_000L
                fun advance(ms: Long) {
                    val stop = k.now() + ms * 1_000_000
                    k.virtualStopAt = stop
                    while (k.now() < stop && !k.finished && System.nanoTime() < wallEnd) if (k.step(50_000_000) < 0) break
                }
                var px = 320; var py = 240
                fun mouse(l: Boolean, r: Boolean) = k.post(KInput.Mouse(px, py, l, r))
                advance(1)
                for (st in plan) {
                    when (st[0]) {
                        "wait" -> advance(((st[1] as Number).toDouble() * 1000).toLong())
                        "shot" -> save(k, File("build/vm-plan-frames/$id/${st[1]}.png"))
                        "key" -> {
                            val names = st.drop(1).map { it as String }
                            val mods = names.dropLast(1).map { qcode(it) }
                            for ((c, s) in mods) k.post(KInput.Key(c, s, true))
                            var (c, s) = qcode(names.last())
                            if ("ctrl" in names.dropLast(1)) s = s or Keys.SCF_CTRL
                            if ("shift" in names.dropLast(1)) s = s or Keys.SCF_SHIFT
                            k.post(KInput.Key(c, s, true)); advance(60); k.post(KInput.Key(c, s or Keys.SCF_KEY_UP, false))
                            for ((mc, ms) in mods.reversed()) k.post(KInput.Key(mc, ms or Keys.SCF_KEY_UP, false))
                            advance(40)
                        }
                        "hold" -> {
                            val (c, s) = qcode(st[1] as String)
                            k.post(KInput.Key(c, s, true))
                            // the VM's PS/2 keyboard repeats at TempleOS's rate (250 ms, then 30/s)
                            val ms = ((st[2] as Number).toDouble() * 1000).toLong()
                            var t = 0L
                            if (ms > 250) { advance(250); t = 250; while (t + 33 <= ms) { k.post(KInput.Key(c, s, true)); advance(33); t += 33 } }
                            advance(ms - t)
                            k.post(KInput.Key(c, s or Keys.SCF_KEY_UP, false)); advance(40)
                        }
                        "type" -> for (ch in (st[1] as String)) { val (c, s) = Keys.forChar(ch.code); k.post(KInput.Key(c, s, true)); k.post(KInput.Key(c, s or Keys.SCF_KEY_UP, false)); advance(40) }
                        "click", "rclick" -> {
                            px = (st[1] as Number).toInt(); py = (st[2] as Number).toInt(); val r = st[0] == "rclick"
                            mouse(!r, r); advance(70); mouse(false, false); advance(70)
                        }
                        "move" -> { px = (st[1] as Number).toInt(); py = (st[2] as Number).toInt(); mouse(false, false); advance(40) }
                        "drag" -> {
                            px = (st[1] as Number).toInt(); py = (st[2] as Number).toInt(); mouse(true, false); advance(50)
                            val x1 = (st[3] as Number).toInt(); val y1 = (st[4] as Number).toInt()
                            val x0 = px; val y0 = py
                            for (j in 1..5) { px = x0 + (x1 - x0) * j / 5; py = y0 + (y1 - y0) * j / 5; mouse(true, false); advance(40) }
                            mouse(false, false); advance(50)
                        }
                    }
                }
                println("VMPLAN $id done finished=${k.finished} ${k.exitMessage ?: ""}")
                k.terminate("done")
            } catch (e: Throwable) {
                println("VMPLAN $id error ${e.toString().take(200)}")
            } finally { dir.deleteRecursively() }
        }
    }
}
