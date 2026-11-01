package io.github.templeosmobile.core.bench

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.purenative.NativeBinding
import io.github.templeosmobile.core.purenative.NativePrograms

/**
 * Deterministic program scenarios (docs/native-validation): a program, scripted input and a span of
 * virtual time, run on Pure Terry or on the program's native translation and hashed at checkpoints.
 *
 * The same code runs in the host differential tests (purekotlin) and on devices (the app's benchmark
 * mode), so a phone's checkpoint hashes can be compared with the host's: the virtual clock advances by
 * budget ticks, which makes the work and its scheduling identical on every engine and machine.
 *
 * Time models kept apart in [ScenarioStats]: simulated time (virtual ms of program time), wall time
 * (host monotonic clock), CPU time (supplied by the platform), and the wall time the kernel spent
 * running tasks versus composing frames (draw_it callbacks, ODEs, blits).
 */
sealed class ScenarioEvent(val ms: Long) {
    class Key(ms: Long, val ch: Int, val sc: Long, val down: Boolean) : ScenarioEvent(ms)
    class Mouse(ms: Long, val x: Int, val y: Int, val lb: Boolean, val rb: Boolean) : ScenarioEvent(ms)
    class Break(ms: Long) : ScenarioEvent(ms)
}

/** Input script and duration. Built from integers only, so the Swift runner replays it exactly. */
class ScenarioScript(val name: String, val durationMs: Long, val events: List<ScenarioEvent>, val stepMs: Long = 20) {
    companion object {
        /** The sweep tests' synthetic input: mouse circling, a click every 2 s, SPACE and LEFT alternating. */
        fun sweep(durationMs: Long): ScenarioScript {
            val ev = ArrayList<ScenarioEvent>()
            var lastKey = 0L
            var ms = 0L
            while (ms < durationMs) {
                val ph = ((ms / 10) % 400).toInt()
                val mx = 170 + (if (ph < 200) ph else 400 - ph) * 3 / 2
                val my = 120 + ((ms / 7) % 240).toInt()
                ev.add(ScenarioEvent.Mouse(ms, mx, my, (ms / 500) % 4 == 1L, false))
                if (ms - lastKey > 700) {
                    lastKey = ms
                    val (ch, sc) = if ((ms / 700) % 3 == 0L) Keys.special(Keys.SC_CURSOR_LEFT) else Keys.forChar(' '.code)
                    ev.add(ScenarioEvent.Key(ms, ch, sc, true)); ev.add(ScenarioEvent.Key(ms, ch, sc or Keys.SCF_KEY_UP, false))
                }
                ms += 20
            }
            return ScenarioScript("sweep", durationMs, ev)
        }

        /**
         * Cartesian's formula entry (docs/native-validation): each formula typed and entered, the graph drawn, any
         * key for the next prompt; an invalid formula last, then ESC. 11 s of virtual time.
         */
        fun cartesian(): ScenarioScript {
            val ev = ArrayList<ScenarioEvent>()
            var ms = 300L
            for (f in listOf("2*x", "Sin(x/20)*100", "x*x/100", "2*")) {
                ev += typing(ms, f + "\n"); ms += 2200
                ev += typing(ms, " "); ms += 300
            }
            val (ch, sc) = Keys.forChar(27)
            ev.add(ScenarioEvent.Key(ms, ch, sc, true)); ev.add(ScenarioEvent.Key(ms + 20, ch, sc or Keys.SCF_KEY_UP, false))
            return ScenarioScript("cartesian", 11_000, ev)
        }

        /** A scenario by name: "cartesian", or the sweep for [durationMs]. */
        fun named(name: String, durationMs: Long): ScenarioScript = if (name == "cartesian") cartesian() else sweep(durationMs)

        /** Typing [text] from [startMs] on, one key every [gapMs] (down, then up 20 ms later). */
        fun typing(startMs: Long, text: String, gapMs: Long = 60): List<ScenarioEvent> {
            val ev = ArrayList<ScenarioEvent>()
            var ms = startMs
            for (c in text) {
                val (ch, sc) = Keys.forChar(c.code)
                ev.add(ScenarioEvent.Key(ms, ch, sc, true)); ev.add(ScenarioEvent.Key(ms + 20, ch, sc or Keys.SCF_KEY_UP, false))
                ms += gapMs
            }
            return ev
        }
    }
}

enum class ScenarioEngine { TERRY, NATIVE }

/**
 * Kernel environment for scenarios: the given runtime files and drive, fixed entropy (12345, so the
 * random sequence is the same everywhere), logged sound, popups answered from a list.
 */
open class ScenarioEnv(override val fs: VirtualFs, val memMb: Int, private val runtime: (String) -> ByteArray?) : KernelEnv {
    val sound = ArrayList<Pair<Long, Double>>()
    var popupAnswers = ArrayDeque<Long>()
    override fun runtimeFile(name: String): ByteArray? = runtime(name)
    override fun entropy(): Long = 12345
    override val memoryLimit: Int get() = memMb shl 20
    var kernel: Kernel? = null
    override fun sound(kernel: Kernel, freq: Double, atNs: Long) { sound.add(kernel.now() to freq) }
    override fun popupRequested(kernel: Kernel, req: PopupRequest) {
        req.result = popupAnswers.removeFirstOrNull() ?: req.items.firstOrNull { it.value != -1L }?.value ?: -1
    }
}

/** What engines are compared on at each checkpoint (the same fields and hashes as the Swift runner). */
class ScenarioCheckpoint(val ms: Long, val frameCount: Long, val frameHash: Long, val palette: List<Int>, val window: List<Int>,
                         val sounds: Int, val soundHash: Long, val console: String, val ticks: Long, val finished: Boolean, val globalsHash: Long) {
    fun json(): String = "{\"ms\":$ms,\"frames\":$frameCount,\"frame\":$frameHash,\"sounds\":$sounds,\"sound\":$soundHash,\"console\":${ScenarioHash.fnv(latin1(console))},\"ticks\":$ticks,\"finished\":$finished,\"globals\":$globalsHash}"
}

/** Wall-clock and memory measurements of one run (simulated time is the script's duration). */
class ScenarioStats(
    val bootWallNs: Long, val runWallNs: Long, val taskWallNs: Long, val frameWallNs: Long, val ticks: Long, val frames: Long,
    val arenaBytes: Int, val arenaHighWater: Int, val arenaPeakAllocated: Long, val arenaLimit: Int,
)

class ScenarioRun(val kernel: Kernel, val env: ScenarioEnv, val checkpoints: List<ScenarioCheckpoint>, val frames: List<ByteArray>,
                  val stats: ScenarioStats, val completedMs: Long, val failure: ScenarioFailure?)

/**
 * Why a run did not reach its end. A slow run is not a failure: [STALLED] means no budget tick and no
 * virtual time advanced for the stall allowance (a hang), [WALL_LIMIT] that a hard wall allowance ran
 * out while the program was still progressing.
 */
class ScenarioFailure(val kind: String, val atMs: Long, val detail: String) {
    companion object { const val STALLED = "STALLED"; const val WALL_LIMIT = "WALL_LIMIT"; const val HOST_EXCEPTION = "HOST_EXCEPTION" }
}

/** Progress of a running scenario, reported from a monitor thread every heartbeat. */
class ScenarioProgress(val virtualMs: Long, val wallMs: Long, val ticks: Long, val frames: Long, val ticksPerSecond: Long)

object ScenarioHash {
    fun fnv(b: ByteArray, h0: Long = -0x340d631b7bdddcdbL): Long { var h = h0; for (x in b) { h = (h xor (x.toLong() and 0xFF)) * 0x100000001b3L }; return h }

    /**
     * Globals whose values legitimately differ between engines: the host's task bookkeeping (Fs points at
     * the current CTask, whose stack differs).
     */
    val HOST_GLOBALS = setOf("Fs", "adam_task", "sys_task_being_screen_updated")

    /** Names compared as Latin-1 bytes (the same order in the Swift runner). */
    fun latin1Cmp(a: String, b: String): Int {
        val n = minOf(a.length, b.length)
        for (i in 0 until n) { val d = (a[i].code and 0xFF) - (b[i].code and 0xFF); if (d != 0) return d }
        return a.length - b.length
    }

    /** Hash of every global variable's storage, by name (the program state engines must agree on). */
    fun globals(k: Kernel, skip: Set<String> = HOST_GLOBALS): Long {
        var h = -0x340d631b7bdddcdbL
        for ((name, s) in k.prog.globals.entries.sortedWith { x, y -> latin1Cmp(x.key, y.key) }) {
            if (s !is GlobalSym || name in skip) continue
            val size = maxOf(s.type.size, 1).coerceAtMost(1 shl 20)
            if (s.addr + size > k.mem.size) continue
            h = fnv(latin1(name), h)
            h = fnv(k.mem.readBytes(s.addr, size), h)
        }
        return h
    }

    /** One global's storage (whole, not capped), or null. */
    fun global(k: Kernel, name: String): Long? {
        val s = k.prog.globals[name] as? GlobalSym ?: return null
        val size = maxOf(s.type.size, 1)
        if (s.addr + size > k.mem.size) return null
        return fnv(k.mem.readBytes(s.addr, size))
    }
}

/** Runs scenarios. [fsFactory] makes a fresh drive per run (writes, e.g. the registry, must not leak between runs). */
class ScenarioRunner(private val fsFactory: () -> VirtualFs, private val runtime: (String) -> ByteArray?) {
    class Options(
        /** Benchmarks: only the final checkpoint is hashed (per-step hashing would be measured too). */
        val light: Boolean = false,
        val keepFrames: Boolean = false,
        val memMb: Int = 32,
        val popups: List<Long> = emptyList(),
        /** Wall time between progress reports (0 = none). */
        val heartbeatMs: Long = 0,
        val onProgress: ((ScenarioProgress) -> Unit)? = null,
        /** A run whose ticks and virtual time do not move for this long is stopped as STALLED (0 = never). */
        val stallMs: Long = 0,
        /** Hard wall allowance (Long.MAX_VALUE = none): stops a still-progressing run as WALL_LIMIT. */
        val wallLimitMs: Long = Long.MAX_VALUE,
        /** Called at every hashed checkpoint with the published frame (debugging hooks of the test harness). */
        val onCheckpoint: ((Kernel, Long, ByteArray) -> Unit)? = null,
        val env: ((VirtualFs) -> ScenarioEnv)? = null,
    )

    fun newEnv(fs: VirtualFs, o: Options): ScenarioEnv = (o.env?.invoke(fs) ?: ScenarioEnv(fs, o.memMb, runtime)).also { it.popupAnswers.addAll(o.popups) }

    /** Boots [path] on [engine] in virtual time with tick-based time cost (identical for both engines). */
    fun boot(path: String, engine: ScenarioEngine, env: ScenarioEnv): Kernel {
        val fs = env.fs
        val k = Kernel(env, path.substringAfterLast('/'))
        env.kernel = k
        k.virtualTime = true
        k.virtualCostTicks = true
        if (engine == ScenarioEngine.NATIVE) {
            val img = NativePrograms.find(path) ?: error("$path is not translated")
            NativePrograms.staleReason(img, fs)?.let { error("stale translation: $it") }
            val cat = NativePrograms.catalog ?: error("no native catalog installed")
            k.native = NativeBinding(cat.prelude, img)
        }
        k.boot()
        k.runProgram(path, fs.readFile(path) ?: error("no $path"))
        return k
    }

    fun run(path: String, engine: ScenarioEngine, script: ScenarioScript, o: Options = Options()): ScenarioRun {
        val env = newEnv(fsFactory(), o)
        val b0 = System.nanoTime()
        val k = boot(path, engine, env)
        val b1 = System.nanoTime()
        val w0 = k.wallTaskNs; val f0 = k.wallFrameNs
        val stop = java.util.concurrent.atomic.AtomicReference<ScenarioFailure?>(null)
        val curMs = java.util.concurrent.atomic.AtomicLong(0)
        val monitor = if (o.heartbeatMs <= 0 && o.stallMs <= 0 && o.wallLimitMs == Long.MAX_VALUE) null else Thread({
            val start = System.nanoTime()
            var lastTicks = -1L; var lastV = -1L; var lastMoveNs = start; var lastBeatNs = start; var beatTicks = 0L
            val period = listOf(o.heartbeatMs, o.stallMs / 4, 250L).filter { it > 0 }.min()
            try {
                while (true) {
                    Thread.sleep(period)
                    val now = System.nanoTime()
                    val ticks = k.vm.ticksExecuted; val v = k.now()
                    if (ticks != lastTicks || v != lastV) { lastTicks = ticks; lastV = v; lastMoveNs = now }
                    val fail = when {
                        o.stallMs > 0 && now - lastMoveNs > o.stallMs * 1_000_000 ->
                            ScenarioFailure(ScenarioFailure.STALLED, curMs.get(), "no budget tick and no virtual time for ${(now - lastMoveNs) / 1_000_000} ms at ${v / 1_000_000} ms virtual, ticks $ticks")
                        o.wallLimitMs != Long.MAX_VALUE && now - start > o.wallLimitMs * 1_000_000 ->
                            ScenarioFailure(ScenarioFailure.WALL_LIMIT, curMs.get(), "still progressing after ${o.wallLimitMs} ms wall (${v / 1_000_000} ms virtual, ticks $ticks)")
                        else -> null
                    }
                    if (fail != null) { stop.set(fail); k.stopRequested = true; k.vm.interrupt = true; return@Thread }
                    if (o.heartbeatMs > 0 && now - lastBeatNs >= o.heartbeatMs * 1_000_000) {
                        val rate = (ticks - beatTicks) * 1_000_000_000L / maxOf(1, now - lastBeatNs)
                        o.onProgress?.invoke(ScenarioProgress(v / 1_000_000, (now - start) / 1_000_000, ticks, k.frameCount, rate))
                        lastBeatNs = now; beatTicks = ticks
                    }
                }
            } catch (_: InterruptedException) {}
        }, "scenario-monitor").also { it.isDaemon = true; it.start() }
        val cps = ArrayList<ScenarioCheckpoint>()
        val frames = ArrayList<ByteArray>()
        var i = 0
        val evs = script.events.sortedBy { it.ms }
        var ms = 0L
        var alive = true
        var completed = 0L
        var failure: ScenarioFailure? = null
        val r0 = System.nanoTime()
        while (ms <= script.durationMs) {
            curMs.set(ms)
            while (i < evs.size && evs[i].ms <= ms) {
                when (val e = evs[i]) {
                    is ScenarioEvent.Key -> k.post(KInput.Key(e.ch, e.sc, e.down))
                    is ScenarioEvent.Mouse -> k.post(KInput.Mouse(e.x, e.y, e.lb, e.rb))
                    is ScenarioEvent.Break -> k.post(KInput.Break)
                }
                i++
            }
            if (alive) alive = try { advanceTo(k, ms) } catch (e: Exception) { k.console.write("rror: host exception $e\n"); failure = ScenarioFailure(ScenarioFailure.HOST_EXCEPTION, ms, e.toString()); false }
            stop.get()?.let { failure = it; k.terminate(it.kind.lowercase()); break }
            completed = ms
            if (o.light && ms + script.stepMs <= script.durationMs) { ms += script.stepMs; continue }
            val f = synchronized(k.publishLock) { k.published.copyOf() }
            if (o.keepFrames) frames.add(f)
            o.onCheckpoint?.invoke(k, ms, f)
            // platform-neutral (the Swift runner computes the same hashes): times and raw F64 bits
            val sb = env.sound.joinToString(";") { "${it.first}:${it.second.toRawBits()}" }.toByteArray()
            cps.add(ScenarioCheckpoint(ms, k.frameCount, ScenarioHash.fnv(f), k.palette.toList(), k.publishedWindow.toList(), env.sound.size, ScenarioHash.fnv(sb),
                k.console.plainText(), k.vm.ticksExecuted, k.finished, ScenarioHash.globals(k)))
            ms += script.stepMs
        }
        val r1 = System.nanoTime()
        monitor?.interrupt()
        val stats = ScenarioStats(b1 - b0, r1 - r0, k.wallTaskNs - w0, k.wallFrameNs - f0, k.vm.ticksExecuted, k.frameCount,
            k.mem.size, k.mem.highWater, k.mem.peakAllocated, k.mem.maxBytes)
        return ScenarioRun(k, env, cps, frames, stats, completed, failure)
    }

    companion object {
        /** Advances [k] to virtual time [ms] (ms), stepping as the sweep tests do. Returns false once the program ended. */
        fun advanceTo(k: Kernel, ms: Long): Boolean {
            k.virtualStopAt = ms * 1_000_000
            while (k.now() < k.virtualStopAt) { if (k.step(1_000_000_000) < 0) return false }
            return true
        }

        fun checkpointsJson(cps: List<ScenarioCheckpoint>): String = cps.joinToString(",\n", "[\n", "\n]\n") { it.json() }
    }
}
