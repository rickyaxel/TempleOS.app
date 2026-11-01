package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.holyc.*
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.bench.*
import java.io.File

/** One deterministic input event at a virtual time (ms). */
sealed class Ev(val ms: Long) {
    class Key(ms: Long, val ch: Int, val sc: Long, val down: Boolean) : Ev(ms)
    class Mouse(ms: Long, val x: Int, val y: Int, val lb: Boolean, val rb: Boolean) : Ev(ms)
    class Break(ms: Long) : Ev(ms)
}

/** A scenario: input script and duration. Built from integers only, so the Swift harness can replay it. */
class Script(val name: String, val durationMs: Long, val events: List<Ev>, val stepMs: Long = 20) {
    companion object {
        fun tap(ms: Long, ch: Char): List<Ev> { val (c, sc) = Keys.forChar(ch.code); return listOf(Ev.Key(ms, c, sc, true), Ev.Key(ms + 40, c, sc or Keys.SCF_KEY_UP, false)) }
        fun special(ms: Long, sc0: Int, holdMs: Long = 40): List<Ev> { val (c, sc) = Keys.special(sc0); return listOf(Ev.Key(ms, c, sc, true), Ev.Key(ms + holdMs, c, sc or Keys.SCF_KEY_UP, false)) }

        /** The sweep tests' synthetic input: mouse circling, a click every 2 s, SPACE and LEFT alternating. */
        fun sweep(durationMs: Long): Script {
            val ev = ArrayList<Ev>()
            var lastKey = 0L
            var ms = 0L
            while (ms < durationMs) {
                val ph = ((ms / 10) % 400).toInt()
                val mx = 170 + (if (ph < 200) ph else 400 - ph) * 3 / 2
                val my = 120 + ((ms / 7) % 240).toInt()
                ev.add(Ev.Mouse(ms, mx, my, (ms / 500) % 4 == 1L, false))
                if (ms - lastKey > 700) {
                    lastKey = ms
                    val (ch, sc) = if ((ms / 700) % 3 == 0L) Keys.special(Keys.SC_CURSOR_LEFT) else Keys.forChar(' '.code)
                    ev.add(Ev.Key(ms, ch, sc, true)); ev.add(Ev.Key(ms, ch, sc or Keys.SCF_KEY_UP, false))
                }
                ms += 20
            }
            return Script("sweep", durationMs, ev)
        }
    }
}

/** What both engines are compared on at each checkpoint (core [ScenarioCheckpoint]). */
typealias Checkpoint = ScenarioCheckpoint

class Run(val kernel: Kernel, val env: ScenarioEnv, val checkpoints: List<Checkpoint>, val frames: List<ByteArray>, val scenario: ScenarioRun? = null)

fun fnv(b: ByteArray, h0: Long = -0x340d631b7bdddcdbL): Long = ScenarioHash.fnv(b, h0)

/** Hash of every global variable's storage, by name (the program state both engines must agree on). */
fun globalsHash(k: Kernel, skip: Set<String> = emptySet()): Long = ScenarioHash.globals(k, skip)

/**
 * Globals whose values legitimately differ between the engines: the host's task bookkeeping (Fs points at
 * the current CTask, whose stack differs), timers and counters derived from the host clock.
 */
val HOST_GLOBALS = ScenarioHash.HOST_GLOBALS

/** Thrown when a run exceeds its wall-clock allowance or stalls (reported as a timeout, never as parity). */
class RunTimeout(val engine: Engine, val atMs: Long, detail: String = "") : RuntimeException("$engine run timed out at $atMs ms virtual time $detail")

fun Ev.toCore(): ScenarioEvent = when (this) {
    is Ev.Key -> ScenarioEvent.Key(ms, ch, sc, down)
    is Ev.Mouse -> ScenarioEvent.Mouse(ms, x, y, lb, rb)
    is Ev.Break -> ScenarioEvent.Break(ms)
}

fun Script.toCore() = ScenarioScript(name, durationMs, events.map { it.toCore() }, stepMs)

/**
 * Runs [script] on [engine] with the core scenario runner. [wallLimitMs] is a hard allowance; slow but
 * progressing runs can instead set -Dtempleos.paritystall=<ms> (stop only when nothing moves) and
 * -Dtempleos.heartbeat=<ms> (progress lines on stdout and build/parity-heartbeat.txt).
 */
fun runScript(path: String, engine: Engine, script: Script, keepFrames: Boolean = false, wallLimitMs: Long = Long.MAX_VALUE,
              /** Benchmarks: only the final checkpoint is hashed (per-step hashing would be measured too). */
              light: Boolean = false, popups: List<Long> = emptyList()): Run {
    val heartbeat = System.getProperty("templeos.heartbeat")?.toLongOrNull() ?: 0L
    val stall = System.getProperty("templeos.paritystall")?.toLongOrNull() ?: 0L
    val o = ScenarioRunner.Options(light = light, keepFrames = keepFrames, popups = popups, wallLimitMs = wallLimitMs, stallMs = stall,
        env = { ParityEnv(it) }, heartbeatMs = heartbeat,
        onProgress = { p ->
            val line = "heartbeat ${path.substringAfterLast('/')} $engine: ${p.virtualMs} ms virtual of ${script.durationMs}, wall ${p.wallMs / 1000} s, ticks ${p.ticks} (${p.ticksPerSecond}/s), frames ${p.frames}"
            println(line); File("build").mkdirs(); File("build/parity-heartbeat.txt").appendText(line + "\n")
        },
        onCheckpoint = { k, ms, f ->
            System.getProperty("templeos.dumpglobals")?.toLongOrNull()?.let { if (it == ms) dumpGlobals(k, File("build/globals-${engine.name.lowercase()}.txt")) }
            // cross-platform debugging (-Dtempleos.dumpframe=<ms>): the frame, the main task, the first 4 MiB of the
            // arena and the global/CTask layouts, to diff with the Swift harness's TEMPLEOS_DUMPFRAME files (F-11)
            System.getProperty("templeos.dumpframe")?.toLongOrNull()?.let { if (it == ms) {
                File("build/frame-${engine.name.lowercase()}.bin").writeBytes(f)
                k.mainTask?.let { m -> File("build/task-${engine.name.lowercase()}.bin").writeBytes(k.mem.readBytes(m.fsAddr, 8192)) }
                File("build/arena-${engine.name.lowercase()}.bin").writeBytes(k.mem.readBytes(0, minOf(4 shl 20, k.mem.size)))
                File("build/global-addrs.txt").writeText(k.prog.globals.values.filterIsInstance<GlobalSym>().sortedBy { it.addr }.joinToString("\n") { "${it.addr} ${it.type.size} ${it.name}" })
                k.prog.classes["CTask"]?.let { c -> File("build/ctask-layout.txt").writeText(c.members.values.joinToString("\n") { "${it.offset} ${it.type.size} ${it.name}" }) }
            } }
        })
    val r = runner.run(path, engine.core, script.toCore(), o)
    r.failure?.let { if (it.kind != ScenarioFailure.HOST_EXCEPTION) throw RunTimeout(engine, it.atMs, "(${it.kind}: ${it.detail})") }
    return Run(r.kernel, r.env, r.checkpoints, r.frames, r)
}

/** First difference between two runs, described, or null when they agree everywhere. */
fun compareRuns(a: Run, b: Run): String? {
    // purity: the native kernel never ran the bytecode interpreter
    if (b.kernel.isNative && b.kernel.vm.instructionsExecuted != 0L) return "native kernel executed ${b.kernel.vm.instructionsExecuted} bytecode instructions"
    for (i in 0 until minOf(a.checkpoints.size, b.checkpoints.size)) {
        val x = a.checkpoints[i]; val y = b.checkpoints[i]
        val diffs = ArrayList<String>()
        if (x.ticks != y.ticks) diffs.add("ticks ${x.ticks} vs ${y.ticks}")
        if (x.frameCount != y.frameCount) diffs.add("frames ${x.frameCount} vs ${y.frameCount}")
        if (x.frameHash != y.frameHash) diffs.add("frame pixels differ")
        if (x.palette != y.palette) diffs.add("palette differs")
        if (x.window != y.window) diffs.add("window ${x.window} vs ${y.window}")
        if (x.sounds != y.sounds || x.soundHash != y.soundHash) diffs.add("sound events ${x.sounds} vs ${y.sounds}")
        if (x.console != y.console) diffs.add("console differs:\n--- terry\n${x.console.takeLast(600)}\n--- native\n${y.console.takeLast(600)}")
        if (x.finished != y.finished) diffs.add("finished ${x.finished} vs ${y.finished}")
        if (x.globalsHash != y.globalsHash) diffs.add("globals differ: ${globalDiff(a.kernel, b.kernel)}")
        if (diffs.isNotEmpty()) return "at ${x.ms} ms: " + diffs.joinToString("; ")
    }
    return null
}

/** Names of globals whose storage differs (final state). */
fun globalDiff(a: Kernel, b: Kernel): String {
    val out = ArrayList<String>()
    for ((name, s) in a.prog.globals.entries.sortedBy { it.key }) {
        if (s !is GlobalSym || name in HOST_GLOBALS) continue
        val t = b.prog.globals[name] as? GlobalSym ?: run { out.add("$name(missing)"); continue }
        val size = maxOf(s.type.size, 1).coerceAtMost(1 shl 20)
        if (s.addr + size > a.mem.size || t.addr + size > b.mem.size) continue
        if (!a.mem.readBytes(s.addr, size).contentEquals(b.mem.readBytes(t.addr, size))) out.add(name + (if (s.addr != t.addr) "@moved" else ""))
    }
    return out.take(12).joinToString(",") + if (out.size > 12) " +${out.size - 12}" else ""
}

/** Names compared as Latin-1 bytes (the same order in the Swift harness). */
fun latin1Cmp(a: String, b: String): Int = ScenarioHash.latin1Cmp(a, b)

/** Checkpoints as JSON (shared with the Swift harness, which compares its runs with these). */
fun checkpointsJson(cps: List<Checkpoint>): String = ScenarioRunner.checkpointsJson(cps)

/** Debugging aid: one line per global with the hash of its storage. */
fun dumpGlobals(k: Kernel, f: File) {
    val sb = StringBuilder()
    for ((name, s) in k.prog.globals.entries.sortedWith { x, y -> latin1Cmp(x.key, y.key) }) {
        if (s !is GlobalSym || name in HOST_GLOBALS) continue
        val size = maxOf(s.type.size, 1).coerceAtMost(1 shl 20)
        if (s.addr + size > k.mem.size) continue
        sb.append(name).append(' ').append(size).append(' ').append(fnv(k.mem.readBytes(s.addr, size))).append('\n')
    }
    f.writeText(sb.toString())
}
