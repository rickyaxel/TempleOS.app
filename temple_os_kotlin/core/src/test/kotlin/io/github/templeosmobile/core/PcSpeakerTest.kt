package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.PcSpeaker
import io.github.templeosmobile.core.kernel.TempleClock
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * The PC speaker renderer (kernel/PcSpeaker.kt) without any audio device: pitch, silence, sample-exact
 * timing, monophony, the 8254's period restart, band-limiting and its edge cases. The same cases run in
 * Swift (PcSpeakerTests.swift) against shared/test-vectors/audio/pcspeaker-vectors.json.
 */
class PcSpeakerTest {
    private val rate = 48000
    private val lat = 20_000_000L
    private val t0 = 1_000_000_000L

    /** Renders [seconds] in blocks of [block] frames, the clock advancing with the samples. */
    private fun render(sp: PcSpeaker, seconds: Double, block: Int = 256, start: Long = t0): FloatArray {
        val n = (seconds * rate).toInt()
        val out = FloatArray(n)
        var i = 0
        while (i < n) {
            val m = minOf(block, n - i)
            sp.render(out, i, m, start + i * 1_000_000_000L / rate)
            i += m
        }
        return out
    }

    /** Frequency from the rising crossings of the mean between sample [a] and [b] (interpolated). */
    private fun pitch(x: FloatArray, a: Int, b: Int): Double {
        val cr = ArrayList<Double>()
        for (j in a + 1 until b) if (x[j - 1] < 0f && x[j] >= 0f) cr.add(j - 1 + (0 - x[j - 1]) / (x[j] - x[j - 1]).toDouble())
        return if (cr.size < 3) 0.0 else (cr.size - 1) / ((cr.last() - cr.first()) / rate)
    }

    /** First sample at or after [from] whose magnitude is at least half the amplitude. */
    private fun onset(x: FloatArray, from: Int = 0): Int = (from until x.size).first { Math.abs(x[it]) >= PcSpeaker.AMPLITUDE / 2 }

    private fun silentFrom(x: FloatArray, from: Int): Int {
        var last = -1
        for (j in from until x.size) if (x[j] != 0f) last = j
        return last + 1
    }

    @Test fun silentUntilSet() {
        val x = render(PcSpeaker(rate, lat), 0.2)
        assertTrue(x.all { it == 0f })
    }

    @Test fun a4IsTheFlatPitTone() {
        val sp = PcSpeaker(rate, lat)
        val hz = 1193182.0 / 2730 // Snd(60): SYS_TIMER_FREQ/440 = 2730.6 -> 2730
        sp.post(t0, hz)
        val x = render(sp, 1.1)
        val f = pitch(x, rate / 20, x.size)
        assertEquals("fundamental", hz, f, 0.02)
        assertEquals(437.063, f, 0.02)
    }

    @Test fun eventsLandOnTheirSampleAfterTheLatency() {
        val sp = PcSpeaker(rate, lat)
        sp.post(t0 + 50_000_000L, 1000.0)       // on at 50 ms
        sp.post(t0 + 200_000_000L, 0.0)         // off at 200 ms
        val x = render(sp, 0.4)
        val on = onset(x)
        val expectOn = (50 + 20) * rate / 1000  // + latency
        assertTrue("onset $on, expected $expectOn", Math.abs(on - expectOn) <= 1)
        val off = silentFrom(x, on)
        val expectOff = (200 + 20) * rate / 1000
        assertTrue("silent from $off, expected $expectOff", Math.abs(off - expectOff) <= 2)
        assertEquals("note length in samples", 150 * rate / 1000.0, (off - on).toDouble(), 2.0)
    }

    @Test fun blockSizeDoesNotChangeTheOutput() {
        fun run(block: Int): FloatArray {
            val sp = PcSpeaker(rate, lat)
            var t = t0
            for (k in 0 until 40) { sp.post(t, if (k % 3 == 2) 0.0 else 200.0 + 97.0 * k); t += 7_300_000L + k * 113_000L }
            return render(sp, 0.5, block)
        }
        val ref = run(1)
        for (b in listOf(7, 37, 256, 1024, 4096)) assertArrayEquals("block $b", ref, run(b), 0f)
    }

    @Test fun aNewSettingReplacesTheToneAndRestartsItsPeriodHigh() {
        val sp = PcSpeaker(rate, lat)
        sp.post(t0, 300.0)
        sp.post(t0, 900.0) // same instant: the speaker only has the latest setting
        val x = render(sp, 0.3)
        assertEquals(900.0, pitch(x, onset(x), x.size), 0.5)
        // 8254 mode 3: a control word sets OUT high, so a change starts with the high half
        val sp2 = PcSpeaker(rate, lat)
        sp2.post(t0, 100.0)
        sp2.post(t0 + 7_500_000L, 250.0) // 0.75 of a 100 Hz period: OUT is low there
        val y = render(sp2, 0.1)
        val change = (7.5 + 20) * rate / 1000
        assertTrue("low before the change", y[change.toInt() - 3] < 0f)
        assertTrue("high right after the change", y[change.toInt() + 2] > 0f)
    }

    @Test fun outputIsBoundedAndHasNoDc() {
        val sp = PcSpeaker(rate, lat)
        sp.post(t0, 437.063)
        val x = render(sp, 1.0)
        assertTrue(x.all { Math.abs(it) <= PcSpeaker.AMPLITUDE + 1e-6 })
        val a = onset(x)
        val period = rate / 437.063
        val n = (((x.size - a) / period).toInt() * period).toInt()
        val mean = (a until a + n).sumOf { x[it].toDouble() } / n
        assertEquals("mean over whole periods", 0.0, mean, 2e-4)
    }

    /** Magnitude of the DFT of x[a until a+n] at [hz] (Hann window). */
    private fun dft(x: FloatArray, a: Int, n: Int, hz: Double): Double {
        var re = 0.0; var im = 0.0
        for (j in 0 until n) {
            val w = 0.5 - 0.5 * Math.cos(2 * Math.PI * j / (n - 1))
            val ph = 2 * Math.PI * hz * j / rate
            re += w * x[a + j] * Math.cos(ph); im -= w * x[a + j] * Math.sin(ph)
        }
        return Math.hypot(re, im)
    }

    @Test fun highNotesAreBandLimited() {
        // 3 kHz at 48 kHz: the 9th harmonic (27 kHz) of a naive square folds back to 21 kHz, the 11th to 15 kHz
        val f = 1193182.0 / 398
        val sp = PcSpeaker(rate, lat)
        sp.post(t0, f)
        val x = render(sp, 0.5)
        val a = onset(x) + 100
        val n = 8192
        val fund = dft(x, a, n, f)
        for (h in listOf(9, 11, 13, 15, 17, 19, 21, 23, 25)) {
            val alias = Math.abs(rate * Math.round(h * f / rate) - h * f)
            val db = 20 * Math.log10(dft(x, a, n, alias) / fund)
            val naive = 20 * Math.log10(1.0 / h)
            println("3 kHz: harmonic $h -> ${alias.toInt()} Hz: ${"%.1f".format(db)} dB (naive ${"%.1f".format(naive)} dB)")
            assertTrue("harmonic $h: alias at ${alias.toInt()} Hz is ${"%.1f".format(db)} dB", db < naive - 9 && (alias > 16000 || db < -35))
        }
        // still a square wave: odd harmonics at 1/3, 1/5, 1/7 of the fundamental (1 kHz, far below Nyquist)
        val sp1 = PcSpeaker(rate, lat)
        sp1.post(t0, 1193182.0 / 1193)
        val y = render(sp1, 0.5)
        val f1 = 1193182.0 / 1193
        val fund1 = dft(y, a, n, f1)
        for (h in listOf(3, 5, 7)) assertEquals("harmonic $h", 1.0 / h, dft(y, a, n, h * f1) / fund1, 0.08 / h)
        assertTrue("no even harmonics", dft(y, a, n, 2 * f1) / fund1 < 0.01)
    }

    @Test fun lateSettingsPlayAtOnceAndAColdStartKeepsTheRunsTiming() {
        // the output started 100 ms after the first note (e.g. an audio engine starting): the run is
        // delayed as a whole, so the first note keeps its length
        val sp = PcSpeaker(rate, lat)
        sp.post(t0, 440.0)
        sp.post(t0 + 150_000_000L, 0.0)
        val x = render(sp, 0.4, start = t0 + 100_000_000L)
        val on = onset(x)
        assertTrue("starts at once, at $on", on <= 2)
        assertEquals("first note keeps 150 ms", 150.0 * rate / 1000, (silentFrom(x, on) - on).toDouble(), 2.0)
        // beyond MAX_START_DELAY_NS the stale settings collapse to the latest one
        val sp2 = PcSpeaker(rate, lat)
        sp2.post(t0, 440.0); sp2.post(t0 + 10_000_000L, 0.0)
        val y = render(sp2, 0.2, start = t0 + 2_000_000_000L)
        assertTrue("stale note never sounds", y.all { Math.abs(it) < PcSpeaker.AMPLITUDE / 2 })
    }

    @Test fun anUnderrunSkipsAheadInsteadOfDelayingEverything() {
        val sp = PcSpeaker(rate, lat)
        val out = FloatArray(480)
        sp.render(out, 0, 480, t0) // 10 ms
        // the audio thread stalled for 500 ms; a note set during the stall is due now
        sp.post(t0 + 490_000_000L, 1000.0)
        val after = FloatArray(4800)
        sp.render(after, 0, 4800, t0 + 510_000_000L)
        val on = onset(after)
        assertTrue("plays within the latency, at sample $on", on <= (lat / 1_000_000 + 2) * rate / 1000)
    }

    @Test fun aDeviceClockOffByTwoPercentKeepsRealTimeDistances() {
        // the device plays 2 % more (or fewer) samples per second of the system clock (the Android emulator):
        // settings 200 ms apart in system time must be 200 ms of the device's playback apart
        for (k in listOf(1.02, 0.98)) {
            val sp = PcSpeaker(rate, lat)
            for (j in 0 until 30) { sp.post(t0 + j * 200_000_000L, 440.0); sp.post(t0 + j * 200_000_000L + 180_000_000L, 0.0) }
            val n = (6.2 * rate * k).toInt()
            val x = FloatArray(n)
            var i = 0
            while (i < n) { val m = minOf(256, n - i); sp.render(x, i, m, t0 + (i * 1e9 / (rate * k)).toLong()); i += m }
            val ons = (20 until n).filter { x[it] != 0f && (it - 20 until it).all { j -> x[j] == 0f } } // after a rest (an edge on a sample can be one 0)
            val gaps = ons.zipWithNext { a, b -> b - a }.drop(10)
            val want = 0.2 * rate * k
            for (g in gaps) assertEquals("device x$k: onset spacing", want, g.toDouble(), want * 0.003)
        }
    }

    @Test fun anOutputStartUpDelayIsNotADrift() {
        // Android: no presentation timestamp for the first 0.3 s, then one that is 80 ms behind the anchor (the
        // output's start-up): a constant, so the notes keep exactly 200 ms of samples between them
        val sp = PcSpeaker(rate, lat)
        for (j in 0 until 10) { sp.post(t0 + j * 200_000_000L, 440.0); sp.post(t0 + j * 200_000_000L + 180_000_000L, 0.0) }
        val n = 2 * rate
        val x = FloatArray(n)
        var i = 0
        while (i < n) {
            val m = minOf(192, n - i)
            val valid = i >= rate * 3 / 10
            sp.render(x, i, m, t0 + i * 1_000_000_000L / rate + (if (valid) 80_000_000L else 0L), valid)
            i += m
        }
        val ons = (20 until n).filter { x[it] != 0f && (it - 20 until it).all { j -> x[j] == 0f } } // after a rest (an edge on a sample can be one 0)
        assertEquals(10, ons.size)
        for (g in ons.zipWithNext { a, b -> b - a }) assertEquals(0.2 * rate, g.toDouble(), 1.0)
    }

    @Test fun invalidAndUnplayableSettingsAreSilent() {
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, -440.0, 24000.0, 1e9)) {
            val sp = PcSpeaker(rate, lat)
            sp.post(t0, bad)
            assertTrue("$bad", render(sp, 0.1).all { it == 0f })
        }
        // the lowest PIT tone (count 65535: 18.2 Hz) is a real square wave
        val sp = PcSpeaker(rate, lat)
        sp.post(t0, 1193182.0 / 65535)
        val x = render(sp, 0.5)
        assertEquals(18.207, pitch(x, 0, x.size), 0.01)
    }

    @Test fun aFloodOfSettingsKeepsTheLatest() {
        val sp = PcSpeaker(rate, lat, capacity = 64)
        for (k in 0 until 10_000) sp.post(t0 + k * 1000L, 100.0 + k)
        val x = render(sp, 0.3)
        assertEquals("the last setting wins", 100.0 + 9999, pitch(x, x.size / 2, x.size), 1.0)
    }

    @Test fun idleBookkeeping() {
        val sp = PcSpeaker(rate, lat)
        assertFalse(sp.pendingSound)
        sp.post(t0, 0.0)
        assertFalse("silence does not need the output", sp.pendingSound)
        sp.post(t0, 500.0)
        assertTrue(sp.pendingSound)
        render(sp, 0.1)
        assertFalse(sp.pendingSound)
        assertEquals(0L, sp.silentFrames)
        sp.post(t0 + 100_000_000L, 0.0)
        render(sp, 0.3, start = t0 + 100_000_000L)
        assertTrue("counts silent frames once off", sp.silentFrames > rate / 10)
    }

    @Test fun rendersMuchFasterThanRealTime() {
        val sp = PcSpeaker(rate, lat)
        var t = t0
        for (k in 0 until 1000) { sp.post(t, 200.0 + (k * 37) % 3000); t += 1_000_000L } // Noise-like: 1000 changes/s
        render(sp, 2.0) // warm-up
        val n0 = System.nanoTime()
        render(sp, 10.0, start = t0 + 2_000_000_000L)
        val ms = (System.nanoTime() - n0) / 1e6
        println("PcSpeaker: 10 s of 48 kHz audio rendered in ${"%.1f".format(ms)} ms")
        assertTrue("10 s of audio in $ms ms", ms < 1000)
    }

    @Test fun anOddPitCountIsHighOneClockLongerThanLow() {
        // 8254 mode 3: an odd count N is high for (N+1)/2 clocks and low for (N-1)/2 (an even one half and half).
        // Rendered at 4.8 MHz, the mean level over whole periods measures the duty: A*(2*duty-1).
        for (n in listOf(101L, 102L, 2731L)) {
            val r = 4_800_000
            val sp = PcSpeaker(r, 0)
            val hz = TempleClock.PIT_HZ.toDouble() / n
            sp.post(1_000_000_000L, hz)
            val x = FloatArray(r / 20)
            sp.render(x, 0, x.size, 1_000_000_000L)
            val per = r / hz
            val periods = Math.floor(x.size / per).toInt() - 1
            val a = 0; val b = Math.round(periods * per).toInt()
            val mean = (a until b).sumOf { x[it].toDouble() } / (b - a)
            val duty = if (n % 2 == 1L) (n + 1) / 2 / n.toDouble() else 0.5
            assertEquals("count $n", PcSpeaker.AMPLITUDE * (2 * duty - 1), mean, 2e-5)
        }
    }

    /**
     * Shared vectors: the same posts and render calls in Kotlin and Swift must give the same samples.
     * Missing expectations are written (run once, then commit); -Dtempleos.audio.regen=true rewrites them.
     */
    @Test fun sharedVectorsMatch() {
        val file = File(SHARED, "test-vectors/audio/pcspeaker-vectors.json")
        val cases = listOf(
            "scale" to listOf(0L to 437.063, 150L to 490.6176, 300L to 0.0, 300L to 259.8393, 480L to 0.0),
            "noise" to (0 until 60).map { it.toLong() to (if (it % 7 == 6) 0.0 else 200.0 + (it * 131) % 4000) },
            "edges" to listOf(0L to 18.2069, 40L to 21307.0, 60L to 23999.0, 70L to 0.0),
            // PIT tones with odd counts (high one clock longer): ona 47 (count 5785), 83 (723), 101 (255)
            "pitodd" to listOf(0L to 1193182.0 / 5785, 100L to 1193182.0 / 723, 200L to 1193182.0 / 255, 300L to 0.0),
        )
        val regen = System.getProperty("templeos.audio.regen") == "true" || !file.exists()
        val sb = StringBuilder("{\n \"note\": \"PcSpeaker(48000, latency 20 ms), posts (ms from t0, Hz), rendered in 100-frame blocks from t0; samples every 7th frame of the first 0.5 s, 1e-6 resolution. Generated by PcSpeakerTest.kt (templeos.audio.regen); checked by PcSpeakerTest.kt and PcSpeakerTests.swift.\",\n \"cases\": {")
        val expected = if (regen) null else Regex("\"(\\w+)\": \\[([^\\]]*)\\]").findAll(file.readText().substringAfter("\"cases\"")).associate { it.groupValues[1] to it.groupValues[2].split(",").map { s -> s.trim().toLong() } }
        for ((ci, c) in cases.withIndex()) {
            val sp = PcSpeaker(rate, lat)
            for ((ms, hz) in c.second) sp.post(t0 + ms * 1_000_000L, hz)
            val x = render(sp, 0.5, 100)
            val q = (x.indices step 7).map { Math.round(x[it] * 1e6) }
            if (expected != null) assertEquals("case ${c.first}", expected[c.first], q)
            sb.append(if (ci == 0) "\n" else ",\n").append("  \"${c.first}\": [").append(q.joinToString(",")).append("]")
        }
        if (regen) { file.parentFile.mkdirs(); file.writeText(sb.append("\n }\n}\n").toString()); println("wrote $file") }
    }
}
