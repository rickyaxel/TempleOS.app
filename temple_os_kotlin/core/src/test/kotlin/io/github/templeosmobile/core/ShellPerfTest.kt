package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Test
import java.io.File
import java.lang.management.ManagementFactory

/**
 * Desktop and runtime timing scenarios (opt-in): -Dtempleos.shellperf=<samples, e.g. 20>
 * [-Dtempleos.shellperfonly=<scenario name prefixes, comma separated>] [-Dtempleos.shellperfout=build/shellperf-kotlin.json].
 *
 * Each scenario repeats one user-level operation on a headless [Shell] (real bundled drive, temp overlay)
 * and records the calling thread's CPU time and the wall time per operation; short operations are timed in
 * batches and divided. The thread CPU time is the figure to compare between builds on a busy machine; wall
 * time includes waiting for other processes. `game.*` runs a program on its own kernel thread, as the app
 * does, and measures only the UI thread: shell ticks at 60 Hz plus the platform's per-frame conversion of
 * changed pixels (the work TempleView.onDraw / TempleView.render do: surface and program frame to 32-bit
 * colour), and counts how often each was needed. Same scenarios as Swift ShellPerfTests
 * (docs/performance-2026-11-08/BASELINE.md).
 */
class ShellPerfTest {
    private val bean = ManagementFactory.getThreadMXBean()
    private val rows = ArrayList<String>()
    private val json = ArrayList<String>()
    private var only: List<String> = emptyList()
    private var t = 1000L

    private fun wanted(name: String) = only.isEmpty() || only.any { name.startsWith(it) }
    /** Whether a group's setup is needed: one of its scenario names (or name prefixes) is selected. */
    private fun section(vararg names: String) = only.isEmpty() || names.any { n -> only.any { n.startsWith(it) || it.startsWith(n) } }

    private class Stat(val n: Int, val p50: Double, val p95: Double?, val min: Double, val max: Double, val mean: Double)

    private fun stat(v: List<Double>): Stat {
        val s = v.sorted()
        val p95 = if (s.size >= 20) s[Math.ceil(0.95 * s.size).toInt() - 1] else null
        return Stat(s.size, s[s.size / 2], p95, s.first(), s.last(), s.average())
    }

    private fun f(v: Double?) = if (v == null) "null" else "%.2f".format(java.util.Locale.ROOT, v)

    /** Times [samples] runs of [op] ([batch] calls each, [setup] untimed before each run); µs per call. */
    private fun scenario(name: String, samples: Int, batch: Int = 1, setup: () -> Unit = {}, op: (Int) -> Unit) {
        if (!wanted(name)) return
        val cpu = ArrayList<Double>(); val wall = ArrayList<Double>()
        for (i in 0 until samples) {
            setup()
            val c0 = bean.currentThreadCpuTime; val w0 = System.nanoTime()
            for (j in 0 until batch) op(i * batch + j)
            val w = System.nanoTime() - w0; val c = bean.currentThreadCpuTime - c0
            cpu.add(c / 1e3 / batch); wall.add(w / 1e3 / batch)
        }
        report(name, "us/op", cpu, wall, "")
    }

    private fun report(name: String, unit: String, cpu: List<Double>, wall: List<Double>, extra: String) {
        val c = stat(cpu); val w = stat(wall)
        rows.add("%-28s n=%-3d cpu p50=%9s p95=%9s min=%9s max=%9s | wall p50=%9s p95=%9s  %s %s".format(
            name, c.n, f(c.p50), f(c.p95), f(c.min), f(c.max), f(w.p50), f(w.p95), unit, extra))
        json.add("{\"name\":\"$name\",\"unit\":\"$unit\",\"n\":${c.n},\"cpuP50\":${f(c.p50)},\"cpuP95\":${f(c.p95)},\"cpuMin\":${f(c.min)}," +
            "\"cpuMax\":${f(c.max)},\"cpuMean\":${f(c.mean)},\"wallP50\":${f(w.p50)},\"wallP95\":${f(w.p95)},\"wallMin\":${f(w.min)},\"wallMax\":${f(w.max)}" +
            (if (extra.isNotEmpty()) ",$extra" else "") + "}")
    }

    private fun newShell(env: HeadlessEnv, w: Int = 360, h: Int = 800): Shell {
        val sh = Shell(env)
        sh.resize(w, h, 24, 16, 0, 0, 0)
        sh.restoreSession()
        sh.tick()
        return sh
    }

    private fun waitFor(sh: Shell, ms: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { sh.tick(); if (cond()) return true; Thread.sleep(10) }
        return cond()
    }

    private fun closeAll(sh: Shell) { sh.windows.toList().forEach { sh.close(it, force = true) }; sh.tick() }

    private fun redraw(sh: Shell) { sh.invalidate(); sh.tick() }

    private fun typeKey(sh: Shell, c: Char) {
        val (ch, sc) = Keys.forChar(c.code)
        sh.key(ch, sc, true); sh.key(ch, sc or Keys.SCF_KEY_UP, false); sh.tick()
    }

    private fun special(sh: Shell, code: Int) {
        val (ch, sc) = Keys.special(code)
        sh.key(ch, sc, true); sh.key(ch, sc or Keys.SCF_KEY_UP, false); sh.tick()
    }

    @Test
    fun shellPerf() {
        val samples = System.getProperty("templeos.shellperf")?.toIntOrNull() ?: return
        only = System.getProperty("templeos.shellperfonly")?.split(",")?.filter { it.isNotBlank() } ?: emptyList()
        val dir = kotlin.io.path.createTempDirectory("tosm-perf").toFile()
        try {
            run(samples, dir)
        } finally { dir.deleteRecursively() }
        val out = File(System.getProperty("templeos.shellperfout") ?: "build/shellperf-kotlin.json")
        out.parentFile?.mkdirs()
        out.writeText("{\"platform\":\"kotlin-jvm\",\"jvm\":\"${System.getProperty("java.version")}\",\"samples\":$samples,\"scenarios\":[\n  " + json.joinToString(",\n  ") + "\n]}\n")
        println("SHELLPERF kotlin (JVM ${System.getProperty("java.version")}, $samples samples):\n" + rows.joinToString("\n"))
    }

    private fun run(samples: Int, dir: File) {
        val env = HeadlessEnv(dir)
        // ---- kernel boot (prelude, graphics library, kernel classes compiled for every program)
        scenario("boot.kernel", maxOf(5, samples / 2)) {
            val k = Kernel(TestEnv(env.fs), "perf"); k.boot()
        }
        // ---- shell start to the first frame (catalog, languages, session, first render)
        scenario("shell.start", samples) { val sh = newShell(env); closeAll(sh) }
        val sh = newShell(env)
        // ---- idle desktop: what the 10 Hz idle poll and each display frame cost when nothing changed
        scenario("idle.tick.desktop", samples, batch = 200) { sh.tick() }
        scenario("render.desktop", samples, batch = 20) { redraw(sh) }

        // ---- terminal
        if (section("render.terminal", "idle.tick.terminal", "terminal.key")) {
            Launch.terminal(sh, "C:/Home", "Dir;")
            val term = sh.focused!!.app as TerminalApp
            waitFor(sh, 30000) { term.kernel.console.plainText().contains("Home") && !term.busy }
            scenario("render.terminal", samples, batch = 20) { redraw(sh) }
            scenario("idle.tick.terminal", samples, batch = 200) { sh.tick() }
            scenario("terminal.key", samples, batch = 16, setup = { repeat(16) { special(sh, Keys.SC_BACKSPACE) } }) { i -> typeKey(sh, "abcdefghijklmnop"[i % 16]) }
            closeAll(sh)
        }

        // ---- editor: the largest bundled HolyC source
        if (section("editor.", "render.editor", "idle.tick.editor")) {
            val big = File(SHARED, "bundled-fs").walkTopDown().filter { it.isFile && it.name.endsWith(".HC") }.maxByOrNull { it.length() }!!
            val bigPath = "C:/" + big.relativeTo(File(SHARED, "bundled-fs")).path.replace(File.separatorChar, '/')
            scenario("editor.open.large", samples, setup = { closeAll(sh) }) { Launch.editor(sh, bigPath); sh.tick() }
            if (sh.focused?.app !is EditorApp) { Launch.editor(sh, bigPath); sh.tick() }
            val ed = sh.focused!!.app as EditorApp
            repeat(400) { special(sh, Keys.SC_CURSOR_DOWN) }
            scenario("render.editor", samples, batch = 20) { redraw(sh) }
            scenario("idle.tick.editor", samples, batch = 200) { sh.tick() }
            scenario("editor.key", samples, batch = 16, setup = { repeat(16) { special(sh, Keys.SC_BACKSPACE) } }) { i -> typeKey(sh, "abcdefghijklmnop"[i % 16]) }
            scenario("editor.cursor", samples, batch = 20) { i -> special(sh, if ((i / 20) % 2 == 0) Keys.SC_CURSOR_DOWN else Keys.SC_CURSOR_UP) }
            val er = sh.clientRect(sh.focused!!)
            scenario("editor.scroll", samples, batch = 20) { i -> ed.scroll(0, if ((i / 20) % 2 == 0) 64 else -64, er); sh.tick() }
            closeAll(sh)
        }

        // ---- opening and closing windows (portrait deck)
        scenario("window.open-close", samples, batch = 4) { i ->
            when (i % 4) {
                0 -> Launch.files(sh, "C:/Home/Examples")
                1 -> Launch.doc(sh, "C:/Doc/HelpIndex.DD")
                2 -> Launch.settings(sh)
                else -> Launch.about(sh)
            }
            sh.tick(); sh.close(sh.focused!!, force = true); sh.tick()
        }
        // ---- landscape desktop with four windows: render, focus switching, dragging a window
        if (section("render.landscape4", "window.focus.landscape4", "window.drag.landscape4")) {
            val land = newShell(env, 800, 360)
            Launch.files(land, "C:/Home"); Launch.doc(land, "C:/Doc/HelpIndex.DD"); Launch.editor(land, "C:/Home/Examples/Hello.HC"); Launch.about(land)
            land.tile(); land.tick()
            scenario("render.landscape4", samples, batch = 20) { redraw(land) }
            scenario("window.focus.landscape4", samples, batch = 20) { i -> land.focus(land.windows[i % land.windows.size]); land.tick() }
            val top = land.windows.last()
            scenario("window.drag.landscape4", samples, batch = 20) { i ->
                val x = top.x + top.w / 2; val y = top.y + 12; val d = if ((i / 20) % 2 == 0) 3 else -3
                land.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs = t)); t += 16
                land.pointer(PointerEvent(Ptr.MOVE, x + d, y, timeMs = t)); t += 16
                land.pointer(PointerEvent(Ptr.UP, x + d, y, timeMs = t)); t += 400
                land.tick()
            }
            closeAll(land)
        }

        // ---- virtual filesystem
        if (section("fs.")) {
            val files = ArrayList<String>(); val dirs = ArrayList<String>()
            fun walk(d: String) { dirs.add(d); for (e in env.fs.list(d) ?: emptyList()) { val p = if (d.endsWith("/")) d + e.name else "$d/${e.name}"; if (e.isDir) walk(p) else files.add(p) } }
            walk("C:/")
            scenario("fs.list.all-dirs", samples) { for (d in dirs) env.fs.list(d) }
            scenario("fs.read.all-files", samples) { for (p in files) env.fs.readFile(p) }
            scenario("fs.stat.all-files", samples) { for (p in files) env.fs.stat(p) }
            rows.add("  (fs: ${dirs.size} directories, ${files.size} files)")
        }

        // ---- languages: every key looked up; a language change with the full redraw it causes
        if (section("l10n.")) {
            val keys = Regex("^\\s*\"([a-z][^\"]*)\"\\s*:", RegexOption.MULTILINE).findAll(File(SHARED, "runtime/l10n/en.json").readText()).map { it.groupValues[1] }.toList()
            scenario("l10n.tr.all-keys", samples, batch = 10) { for (k in keys) tr(k) }
            Launch.files(sh, "C:/Home"); sh.tick()
            val locales = listOf("ja-JP", "ar-SA", "de-DE", "hi-IN", "en-US")
            scenario("l10n.switch+render", samples, batch = 5) { i -> L10n.use(locales[i % locales.size]); sh.applyLanguage(); sh.tick() }
            L10n.use("en-US"); sh.applyLanguage(); closeAll(sh)
        }

        // ---- a game: UI-thread work per second of play (portrait, controls shown)
        for (id in listOf("game.bombergolf", "game.varoom")) {
            val name = "game.ui.${id.removePrefix("game.")}"
            if (!wanted(name)) continue
            val info = sh.catalog.programs.first { it.id == id }
            Launch.program(sh, info.path, info); sh.tick()
            val prog = sh.focused!!.app as ProgramApp
            // a start PopUp (BattleLines' instructions) is answered as a player would
            waitFor(sh, 60000) { if (sh.dialogOpen) typeKey(sh, '\n'); prog.kernel.frameCount > 30 && sh.overlays().isNotEmpty() }
            gameUi(name, sh, samples)
            closeAll(sh)
        }
    }

    /**
     * [samples] one-second windows of a running program: ticks at 60 Hz; after each, the surface converted to
     * 32-bit colour when its version changed and each overlay's frame copied and converted when it changed.
     * Player input as in shared/benchmark-scenarios/player-input.json: every 700 ms SPACE, LEFT pressed, SPACE,
     * LEFT released (through the shell, as the key row and hardware keys send them).
     */
    private fun gameUi(name: String, sh: Shell, samples: Int) {
        var argb = IntArray(0); var drawn = -1L
        val frames = HashMap<FrameSource, Pair<ByteArray, IntArray>>(); val versions = HashMap<FrameSource, Long>()
        val cpu = ArrayList<Double>(); val wall = ArrayList<Double>()
        var surfaceUploads = 0; var frameUploads = 0; var ticks = 0
        val tickNs = 1_000_000_000L / 60
        repeat(samples) {
            val c0 = bean.currentThreadCpuTime; val w0 = System.nanoTime()
            var next = w0
            for (i in 0 until 60) {
                if (++ticks % 42 == 0) {
                    val sp = Keys.forChar(' '.code); val left = Keys.special(Keys.SC_CURSOR_LEFT)
                    when ((ticks / 42) % 4) {
                        0, 2 -> { sh.key(sp.first, sp.second, true); sh.key(sp.first, sp.second or Keys.SCF_KEY_UP, false) }
                        1 -> sh.key(left.first, left.second, true)
                        else -> sh.key(left.first, left.second or Keys.SCF_KEY_UP, false)
                    }
                    if (sh.dialogOpen) { val (ch, sc) = Keys.forChar('\n'.code); sh.key(ch, sc, true); sh.key(ch, sc or Keys.SCF_KEY_UP, false) }
                }
                sh.tick()
                val s = sh.surface
                if (s.version != drawn) {
                    if (argb.size != s.px.size) argb = IntArray(s.px.size)
                    val px = s.px; val pal = Palette.STD
                    for (j in px.indices) argb[j] = pal[px[j].toInt() and 15]
                    drawn = s.version; surfaceUploads++
                }
                for (o in sh.overlays()) {
                    val src = o.source
                    if (versions[src] != src.frameVersion) {
                        val (idx, out) = frames.getOrPut(src) { ByteArray(src.frameW * src.frameH) to IntArray(src.frameW * src.frameH) }
                        versions[src] = src.copyFrame(idx)
                        val pal = src.palette
                        for (j in idx.indices) out[j] = pal[idx[j].toInt() and 15]
                        frameUploads++
                    }
                }
                next += tickNs
                val wait = next - System.nanoTime()
                if (wait > 0) java.util.concurrent.locks.LockSupport.parkNanos(wait)
            }
            val w = System.nanoTime() - w0; val c = bean.currentThreadCpuTime - c0
            cpu.add(c / 1e6 / (w / 1e9)); wall.add(w / 1e6)
        }
        val secs = wall.sum() / 1e3
        report(name, "uiCpuMs/s", cpu, wall, "\"surfaceUploadsPerSec\":${f(surfaceUploads / secs)},\"frameUploadsPerSec\":${f(frameUploads / secs)},\"ticksPerSec\":${f(ticks / secs)}")
        rows[rows.size - 1] = rows.last() + "  surfaceUploads/s=${f(surfaceUploads / secs)} frameUploads/s=${f(frameUploads / secs)}"
    }
}
