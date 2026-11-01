package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * The TempleOS sound path above the renderer: Snd/Mute/SndRst semantics (Kernel/KMisc.HC), the Sound
 * example's trace against TempleOS's (shared/test-vectors/audio/sound-example.json), the timing of
 * speaker changes, and which program window owns the device speaker. Port: SoundTests.swift.
 */
class SoundTest {
    private class RefEvent(val tMs: Long, val ona: Int, val hz: Double)

    private fun reference(): List<RefEvent> {
        @Suppress("UNCHECKED_CAST")
        val doc = Json.parse(File(SHARED, "test-vectors/audio/sound-example.json").readText()) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        // t_ms: the reference's jiffies in ms (a jiffy is 0.999009 ms; AudioFidelityTest compares jiffies exactly)
        return (doc["events"] as List<Map<String, Any?>>).map { RefEvent(Math.round((it["t_ms"] as Number).toDouble()), (it["ona"] as Number).toInt(), (it["hz"] as Number).toDouble()) }
    }

    /** The program's speaker changes: without the boot's SndRst and the silence posted when it ends. */
    private fun speakerChanges(env: TestEnv): List<Pair<Long, Double>> {
        val l = env.soundLog.dropWhile { it.second == 0.0 }
        var n = l.size
        while (n >= 2 && l[n - 1].second == 0.0 && l[n - 2].second == 0.0) n--
        return l.take(n)
    }

    @Test fun soundExamplePlaysTempleOsTrace() {
        val path = "C:/Home/Examples/Sound.HC"
        val env = TestEnv()
        val k = runHolyC(File(SHARED, "bundled-fs/Home/Examples/Sound.HC").readBytes(), path, env)
        assertTrue("program finished", k.finished)
        val text = k.console.plainText()
        assertTrue(text, text.contains("60 62 64 66 68 70 72") && text.contains("Done."))
        val got = speakerChanges(env)
        val ref = reference()
        assertEquals("speaker changes: $got", ref.size, got.size)
        val t0 = got[0].first
        for ((i, r) in ref.withIndex()) {
            val (t, hz) = got[i]
            assertEquals("change $i (ona ${r.ona}) Hz", r.hz, hz, 1e-3)
            assertTrue("change $i at ${t - t0} ms, TempleOS ${r.tMs} ms", Math.abs(t - t0 - r.tMs) <= 2)
        }
    }

    @Test fun soundExampleRendersTheTraceSampleExactly() {
        // kernel -> speaker -> PCM, all deterministic: every note's pitch and every rest's edges in the samples
        val env = TestEnv()
        runHolyC(File(SHARED, "bundled-fs/Home/Examples/Sound.HC").readBytes(), "C:/Home/Examples/Sound.HC", env)
        val rate = 48000
        val sp = PcSpeaker(rate, 20_000_000L)
        val got = speakerChanges(env)
        val base = 5_000_000_000L
        for ((ms, hz) in got) sp.post(base + (ms - got[0].first) * 1_000_000L, hz)
        val x = FloatArray(rate * 3)
        var i = 0
        while (i < x.size) { val m = minOf(512, x.size - i); sp.render(x, i, m, base + i * 1_000_000_000L / rate); i += m }
        // -Dtempleos.audio.wav=path: the samples as a WAV, to check tools/audio/analyze_capture.py itself
        System.getProperty("templeos.audio.wav")?.let { path ->
            val bb = java.nio.ByteBuffer.allocate(44 + x.size * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            bb.put("RIFF".toByteArray()).putInt(36 + x.size * 2).put("WAVE".toByteArray()).put("fmt ".toByteArray()).putInt(16)
                .putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16).put("data".toByteArray()).putInt(x.size * 2)
            for (v in x) bb.putShort(Math.round(v * 32767f).toShort())
            File(path).writeBytes(bb.array())
        }
        // against what the kernel posted (its own timing is checked against TempleOS above)
        val posted = got.map { RefEvent(it.first - got[0].first, if (it.second > 0) 1 else 0, it.second) }
        val r = checkAgainstReference(x, rate, posted)
        assertTrue(r.joinToString("\n"), r.isEmpty())
    }

    /**
     * Problems found comparing PCM [x] with the reference trace (empty = matches): the first onset is the
     * trace's t=0; each note's pitch is measured inside its window; each rest must be digital silence and
     * start and end within 0.1 ms of the trace. Same rules as tools/audio/analyze_capture.py.
     */
    private fun checkAgainstReference(x: FloatArray, rate: Int, ref: List<RefEvent>): List<String> {
        val bad = ArrayList<String>()
        val thr = PcSpeaker.AMPLITUDE / 2
        val s0 = x.indexOfFirst { Math.abs(it) >= thr }
        if (s0 < 0) return listOf("no sound")
        fun at(ms: Long) = s0 + (ms * rate / 1000).toInt()
        val lastMs = ref.last().tMs
        for ((j, e) in ref.withIndex()) {
            val end = ref.getOrNull(j + 1)?.tMs ?: (e.tMs + 100)
            if (end - e.tMs < 5) continue
            if (e.ona != 0) {
                val a = at(e.tMs) + rate / 500
                val b = at(end) - rate / 500
                val cr = (a + 1 until b).filter { x[it - 1] < 0f && x[it] >= 0f }.map { it - 1 + (0 - x[it - 1]) / (x[it] - x[it - 1]).toDouble() }
                val hz = if (cr.size > 2) (cr.size - 1) / ((cr.last() - cr.first()) / rate) else 0.0
                if (Math.abs(hz - e.hz) > e.hz * 0.002) bad.add("note $j (ona ${e.ona}) at ${e.tMs} ms: ${"%.2f".format(hz)} Hz, TempleOS ${e.hz}")
            } else {
                // the rest: last sounding sample before it and first after it
                var off = at(e.tMs) + rate / 200
                while (off > 0 && x[off - 1] == 0f) off--
                var on = off
                while (on < x.size && x[on] == 0f) on++
                val offMs = (off - s0) * 1000.0 / rate
                val onMs = (on - s0) * 1000.0 / rate
                if (Math.abs(offMs - e.tMs) > 0.1) bad.add("rest $j starts at ${"%.3f".format(offMs)} ms, TempleOS ${e.tMs}")
                if (e.tMs < lastMs && Math.abs(onMs - end) > 0.1) bad.add("rest $j ends at ${"%.3f".format(onMs)} ms, TempleOS $end")
            }
        }
        return bad
    }

    @Test fun mutedSndIsIgnoredAsInTempleOs() {
        val env = TestEnv()
        // Kernel/KMisc.HC: Mute(ON) turns the speaker off and then sets the flag; muted, Snd does nothing,
        // not even remember the ona, so after Mute(OFF) Snd(60) plays again
        val k = runHolyC(latin1("Snd(60);Mute(ON);Snd(62);Snd(60);\"%d\\n\",IsMute;Mute(OFF);Snd(60);Snd(62);Snd;\n"), env = env)
        val hz = speakerChanges(env).map { Math.round(it.second * 100) / 100.0 }
        assertEquals(listOf(437.06, 0.0, 437.06, 490.62, 0.0), hz)
        assertTrue(k.console.plainText().contains("1"))
    }

    @Test fun sndRstAndRepeatedOnas() {
        val env = TestEnv()
        runHolyC(latin1("Snd(60);Snd(60);Snd(60);SndRst;Snd(60);Snd;Snd;\n"), env = env)
        // the ona already playing leaves the PIT alone; SndRst turns it off and forgets it
        assertEquals(listOf(437.06, 0.0, 437.06, 0.0), speakerChanges(env).map { Math.round(it.second * 100) / 100.0 })
    }

    @Test fun onaEdgesFollowThePit() {
        val env = TestEnv()
        // I8 ona: 200 is -56; negative onas and 1 clamp to the PIT's longest count (18.2 Hz); 127 is the
        // highest. Snd compares onas, not counts (ona!=scrncast.ona), so -128 and -56 reprogram the PIT again.
        runHolyC(latin1("Snd(1);Snd(-128);Snd(200);Snd(127);Snd(0);SndFreq(1000.0);SndFreq(0);\n"), env = env)
        val hz = speakerChanges(env).map { it.second }
        assertEquals(7, hz.size)
        for (j in 0..2) assertEquals(1193182.0 / 65535, hz[j], 1e-9)
        assertEquals(1193182.0 / 56, hz[3], 1e-6) // Snd(127): 1201471/21096.4 = 56.95 -> 56
        assertEquals(0.0, hz[4], 0.0)
        assertEquals("SndFreq: nearest PIT count", 1193182.0 / 1193, hz[5], 1e-9)
        assertEquals(0.0, hz[6], 0.0)
    }

    @Test fun lateWakeUpsDoNotMoveSpeakerChanges() {
        // a real-clock kernel whose clock the test moves: the task wakes 7 ms after its SleepUntil time
        class Clock : TestEnv() { var ns = 50_000_000_000L; override fun nanoTime() = ns }
        val env = Clock()
        val k = Kernel(env, "late")
        k.boot()
        k.runProgram("C:/Home/Late.HC", latin1("Snd(60);Sleep(100);Snd(62);Sleep(100);Snd;\n"))
        repeat(50) { if (env.sounds.none { it > 0 }) k.step(10_000_000) }
        val i0 = env.sounds.indexOfFirst { it > 0 } // after the boot's SndRst
        assertEquals("first change at once", env.sounds.size - 1, i0)
        val first = env.soundStamps[i0]
        env.ns += 107_000_000L; k.step(10_000_000)
        env.ns += 109_000_000L; k.step(10_000_000)
        assertTrue("three changes", env.soundStamps.size >= i0 + 3)
        // Sleep(100) is SleepUntil(cnts.jiffies+100): it ends on a jiffy (0.999009 ms each), up to one jiffy
        // sooner than 100 jiffies from a call made inside a jiffy
        val d1 = env.soundStamps[i0 + 1] - first
        assertTrue("Snd(62) dated at its Sleep's end, not 7 ms later: $d1", d1 in 98_900_000L..99_901_000L)
        // the task resumed as if on its jiffy (Kernel.taskNow), so its next Sleep(100) ends 100 jiffies later, not 107 ms
        assertEquals(99_900_937.0, (env.soundStamps[i0 + 2] - env.soundStamps[i0 + 1]).toDouble(), 1.0)
    }

    @Test fun aSleepUntilCalledLateDatesTheNextChangeAtItsTime() {
        // Play's pattern after a stall: SleepUntil(t) is called when t has already passed
        class Clock : TestEnv() { var ns = 50_000_000_000L; override fun nanoTime() = ns }
        val env = Clock()
        val k = Kernel(env, "late2")
        k.boot()
        k.runProgram("C:/Home/Late2.HC", latin1("I64 j0=cnts.jiffies;Sleep(100);Snd(60);Sleep(50);Snd;SleepUntil(j0+160);Snd(62);\n"))
        repeat(50) { k.step(10_000_000) }
        env.ns += 108_000_000L; k.step(10_000_000)  // Sleep(100) wakes 8 ms late
        env.ns += 60_000_000L; k.step(10_000_000)   // Sleep(50) ends at 150 on the task's clock; woken at 168, SleepUntil(160) has passed
        val i0 = env.sounds.indexOfFirst { it > 0 }
        val s = env.soundStamps.drop(i0).map { (it - env.soundStamps[i0]).toDouble() }
        // Snd(60) is on a jiffy (Sleep's end); Snd 50 jiffies and Snd(62) 60 jiffies later (0.999009 ms each)
        assertEquals("Snd(60), Snd, Snd(62) from Snd(60), ns", 3, s.take(3).size)
        assertEquals(49_950_468.6, s[1], 1.0)
        assertEquals(59_940_562.3, s[2], 1.0)
    }

    private class Tones(private val rec: MutableList<Double>) : ShellEnv {
        override val fs: LayeredFs get() = error("unused")
        override val stateStore: StateStore get() = error("unused")
        override fun runtimeFile(name: String): ByteArray? = null
        override fun tone(freq: Double, atNs: Long) { rec.add(freq) }
    }

    @Test fun theFocusedProgramOwnsTheSpeaker() {
        val rec = ArrayList<Double>()
        val mux = SpeakerMux(Tones(rec))
        val a = Any(); val b = Any()
        mux.set(a, 440.0, 1)              // not the owner yet: not heard
        mux.claim(a, 440.0)               // gets the focus: its held note sounds
        mux.set(b, 0.0, 2)                // another window's Snd(0) does not silence it
        mux.set(a, 500.0, 3)
        mux.claim(b, 300.0)               // focus moves to b
        mux.release(a)                    // a's late release must not silence b
        mux.set(a, 0.0, 4)
        mux.release(b)
        assertEquals(listOf(440.0, 500.0, 300.0, 0.0), rec)
    }

    @Test fun pausingSilencesAndResumingRestoresTheHeldNote() {
        val dir = kotlin.io.path.createTempDirectory("tosm-snd").toFile()
        try {
            val rec = ArrayList<Double>()
            val env = object : ShellEnv {
                override val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), dir)
                var session: String? = null
                override val stateStore = object : StateStore { override fun load() = session; override fun save(text: String) { session = text } }
                override fun runtimeFile(name: String): ByteArray? {
                    val f = if (name == "catalog.json") File(SHARED, "program-manifests/catalog.json") else File(SHARED, "runtime/$name")
                    return if (f.exists()) f.readBytes() else null
                }
                override fun tone(freq: Double, atNs: Long) { synchronized(rec) { rec.add(freq) } }
            }
            val sh = Shell(env)
            sh.resize(360, 640)
            sh.restoreSession()
            sh.fs.writeFile("C:/Home/Held.HC", latin1("Snd(60);Sleep(60000);\n"))
            Launch.program(sh, "C:/Home/Held.HC", null)
            val app = sh.windows.last().app as ProgramApp
            fun waitFor(ms: Long, cond: () -> Boolean): Boolean {
                val end = System.currentTimeMillis() + ms
                while (System.currentTimeMillis() < end) { sh.tick(); if (synchronized(rec) { cond() }) return true; Thread.sleep(10) }
                return false
            }
            assertTrue("held note sounds: $rec", waitFor(30_000) { rec.lastOrNull()?.let { Math.abs(it - 437.063) < 0.01 } == true })
            app.onBackground()   // the app goes to the background: the program pauses
            assertTrue("silent while paused: $rec", waitFor(2000) { rec.last() == 0.0 })
            app.onForeground()
            assertTrue("the held note again: $rec", waitFor(2000) { Math.abs(rec.last() - 437.063) < 0.01 })
            sh.settings.sound = false
            assertTrue("Sound OFF in Settings silences: $rec", waitFor(2000) { rec.last() == 0.0 })
            sh.settings.sound = true
            assertTrue("and ON restores: $rec", waitFor(2000) { Math.abs(rec.last() - 437.063) < 0.01 })
            app.close()
            assertTrue("closing silences: $rec", waitFor(5000) { rec.last() == 0.0 })
        } finally { dir.deleteRecursively() }
    }

    /** A sound loop typed in the Terminal stops with the app in the background and resumes with it. */
    @Test fun terminalCommandsPauseInTheBackground() {
        val dir = kotlin.io.path.createTempDirectory("tosm-snd").toFile()
        try {
            val rec = ArrayList<Double>()
            val env = object : ShellEnv {
                override val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), dir)
                var session: String? = null
                override val stateStore = object : StateStore { override fun load() = session; override fun save(text: String) { session = text } }
                override fun runtimeFile(name: String): ByteArray? {
                    val f = if (name == "catalog.json") File(SHARED, "program-manifests/catalog.json") else File(SHARED, "runtime/$name")
                    return if (f.exists()) f.readBytes() else null
                }
                override fun tone(freq: Double, atNs: Long) { synchronized(rec) { rec.add(freq) } }
            }
            val sh = Shell(env)
            sh.resize(360, 640)
            sh.restoreSession()
            val term = TerminalApp(sh)
            sh.open(term)
            fun waitFor(ms: Long, cond: () -> Boolean): Boolean {
                val end = System.currentTimeMillis() + ms
                while (System.currentTimeMillis() < end) { sh.tick(); if (synchronized(rec) { cond() }) return true; Thread.sleep(10) }
                return false
            }
            fun tones() = synchronized(rec) { rec.count { it != 0.0 } }
            term.kernel.post(KInput.Exec("while (TRUE) { Snd(60); Sleep(5); Snd(0); Sleep(5); }"))
            assertTrue("the loop plays: $rec", waitFor(30_000) { rec.count { it != 0.0 } >= 3 })
            sh.onBackground()
            Thread.sleep(100) // a note already handed to the speaker may still arrive
            val before = tones()
            Thread.sleep(500); sh.tick()
            assertEquals("no notes while the app is in the background", before, tones())
            assertEquals("and the speaker is silent", 0.0, synchronized(rec) { rec.last() }, 0.0)
            sh.onForeground()
            assertTrue("the loop plays again", waitFor(5000) { rec.count { it != 0.0 } > before })
            term.close()
        } finally { dir.deleteRecursively() }
    }
}
