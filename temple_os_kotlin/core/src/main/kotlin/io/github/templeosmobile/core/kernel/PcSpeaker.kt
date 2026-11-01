package io.github.templeosmobile.core.kernel

import java.util.concurrent.locks.ReentrantLock

/**
 * The PC speaker that TempleOS's Snd() drives (Kernel/KMisc.HC), as a sample renderer for the platform
 * audio output (Android AudioTrack, iOS AVAudioEngine). It is the one place that turns speaker settings
 * into PCM: the platforms only move its samples to the device. Specification: docs/audio/TEMPLEOS_SOUND.md.
 *
 * TempleOS programs PIT channel 2 in mode 3 (square wave) and gates it onto the speaker (port 0x61). A
 * setting lasts until the next one (no duration of its own), there is one tone at a time, and every new
 * count is written after a control word, which restarts the period with OUT high (8254). In mode 3 an odd
 * count N is high for (N+1)/2 clocks and low for (N-1)/2. [post] queues the
 * settings with the time the program made them; [render] plays each one [latencyNs] later at its own
 * sample, so notes and rests keep the program's timing whatever the buffer size and thread wake-ups are.
 *
 * Output-adapter choices, not TempleOS behaviour: the wave is bipolar (±[AMPLITUDE]: the speaker's 0/5 V
 * signal without its DC), and every edge, including a tone starting or stopping, is band-limited with a
 * 2-sample PolyBLEP. High notes do not alias and starts and stops do not click, without fades that would
 * change a note's length. Frequencies at or above half the sample rate cannot be sampled and are silent.
 *
 * Threads: [post] from any thread (a lock held for a few stores). [render] from the one audio thread; it
 * only tries the lock, so it never waits for a producer (events it cannot take yet wait for the next call).
 */
class PcSpeaker(val sampleRate: Int, latencyNs: Long, private val capacity: Int = 1024) {
    companion object {
        /** Peak level of the square wave: -18 dBFS (a square's RMS level equals its peak). */
        const val AMPLITUDE = 0.125
        /** The most a slow output start may delay a run of notes to keep their timing (iOS engine start: ~100 ms on the speaker, ~270 ms on Bluetooth). */
        const val MAX_START_DELAY_NS = 500_000_000L
        /** How far the audio clock may fall behind real time (underrun, stall) before the timeline skips ahead. */
        const val MAX_BEHIND_NS = 60_000_000L
        /**
         * Smaller differences between the audio clock and [post]'s clock are followed slowly (1/[SERVO_DIV] per
         * call, ignored below [SERVO_DEADBAND_NS]): an output whose device consumes samples a little faster or
         * slower than real time (the Android emulator: ±2 %) keeps settings at their real-time distances, while
         * jitter in the device's timestamps (the emulator's can jump by ~10 ms) is not followed
         * instead of falling behind them and playing them late.
         */
        const val SERVO_DIV = 64
        const val SERVO_DEADBAND_NS = 2_000_000L
    }

    /**
     * Delay from a setting's time to its sample: at least the audio buffer that is rendered ahead plus the
     * kernel's wake-up jitter. Set by the platform when it knows its buffer size (read by [render]).
     */
    @Volatile var latencyNs = latencyNs

    // ---- producer queue (guarded by lock)
    private val lock = ReentrantLock()
    private val pAt = LongArray(capacity)
    private val pHz = DoubleArray(capacity)
    private var pHead = 0
    @Volatile private var pCount = 0
    /** A setting that sounds is queued: the platform starts or wakes its output for it. */
    @Volatile var pendingSound = false
        private set

    /**
     * The speaker is set to [hz] (0 = off) at [atNs] (the clock [render]'s nowNs uses). Non-finite and
     * negative values are off. A full queue (thousands of settings within [latencyNs]) keeps the newest:
     * it replaces the last queued one, as the speaker only ever has its latest setting.
     */
    fun post(atNs: Long, hz: Double) {
        val f = if (hz.isFinite() && hz > 0.0) hz else 0.0
        lock.lock()
        try {
            if (pCount == capacity) {
                val last = (pHead + pCount - 1) % capacity
                pAt[last] = atNs; pHz[last] = f
            } else {
                val i = (pHead + pCount) % capacity
                pAt[i] = atNs; pHz[i] = f
                pCount++
            }
            if (f > 0.0) pendingSound = true
        } finally { lock.unlock() }
    }

    /** Settings are queued that [render] has not taken yet (a racy hint for the platform's idle check). */
    val hasPending: Boolean get() = pCount > 0

    // ---- consumer state (audio thread only)
    private val cAt = LongArray(capacity)
    private val cHz = DoubleArray(capacity)
    private var cHead = 0
    private var cCount = 0
    private var hz = 0.0
    private var dt = 0.0
    /** Position in the period, 0 until 1; it is high until [high] (mode 3 starts with OUT high). */
    private var phase = 0.0
    /** The high part of the period: 1/2, or (N+1)/(2N) for an odd PIT count N. */
    private var high = 0.5
    /** PolyBLEP corrections of the sample being made (c0) and of the next one (c1). */
    private var c0 = 0.0
    private var c1 = 0.0
    private var carry = 0.0
    private var running = false
    private var anchorNs = 0L
    private var delayNs = 0L
    private var frames = 0L

    /** Consecutive frames rendered with the speaker off and nothing queued (the platform's idle timer). */
    var silentFrames = 0L
        private set
    /** Frames rendered with the speaker on, since creation (diagnostics). */
    var soundingFrames = 0L
        private set
    /** The current setting in Hz (0 = off), as rendered. */
    val currentHz: Double get() = hz

    /** The output stopped (paused, interrupted, reconfigured): the next [render] starts a new timeline. */
    fun restart() { running = false }

    /** Whether a clock reading of this run was used yet, and how far it was from the timeline then. */
    private var haveClock = false
    private var skew0 = 0L

    /**
     * Writes [n] samples to [out] from [off]. [nowNs], on [post]'s clock, is when these samples start to play
     * minus a constant (the call time for a pull callback like iOS's; the presentation timestamp for Android's
     * AudioTrack). The first call after a (re)start anchors the timeline there. Calls with [clockValid] then
     * measure the timeline against the clock: the first one sets the reference (an output's start-up delay
     * is a constant, not a drift), later ones follow slow drift and skip after underruns and stalls.
     */
    fun render(out: FloatArray, off: Int, n: Int, nowNs: Long, clockValid: Boolean = true) {
        drain()
        val nsPerFrame = 1e9 / sampleRate
        val lat = latencyNs
        if (!running) {
            running = true; anchorNs = nowNs; frames = 0; delayNs = 0; haveClock = false
            // the setting that started the output came before the output could run: delay the whole run
            // by that much (bounded) instead of cutting its first note short
            for (k in 0 until cCount) {
                val j = (cHead + k) % capacity
                if (cHz[j] > 0.0) { delayNs = (nowNs - (cAt[j] + lat)).coerceIn(0L, MAX_START_DELAY_NS); break }
            }
        }
        if (clockValid) {
            val behind = nowNs - (anchorNs + (frames * nsPerFrame).toLong())
            if (!haveClock) { haveClock = true; skew0 = behind }
            else {
                val d = behind - skew0
                if (d > MAX_BEHIND_NS || d < -(lat + MAX_BEHIND_NS)) anchorNs += d
                else if (d > SERVO_DEADBAND_NS || d < -SERVO_DEADBAND_NS) anchorNs += d / SERVO_DIV
            }
        }
        // settings are placed in frames since the anchor, so the samples do not depend on the block sizes
        val shift = lat + delayNs - anchorNs
        var sounding = 0
        for (i in 0 until n) {
            c0 = carry; c1 = 0.0
            val y = level()
            var t = 0.0
            val now = (frames + i).toDouble()
            while (cCount > 0) {
                val p = (cAt[cHead] + shift) / nsPerFrame - now
                if (p > 1.0) break
                // a late setting (p <= 0) happens right at this sample
                val te = maxOf(p, t).coerceAtMost(1.0)
                advance(t, te)
                apply(cHz[cHead], te)
                t = te
                cHead = (cHead + 1) % capacity; cCount--
            }
            advance(t, 1.0)
            out[off + i] = (y + c0).toFloat()
            carry = c1
            if (hz > 0.0) sounding++
        }
        frames += n
        soundingFrames += sounding
        if (hz == 0.0 && cCount == 0 && carry == 0.0) silentFrames += n else silentFrames = 0
    }

    private fun drain() {
        if (pCount == 0 || !lock.tryLock()) return
        try {
            while (pCount > 0) {
                if (cCount == capacity) {
                    val last = (cHead + cCount - 1) % capacity
                    cAt[last] = pAt[pHead]; cHz[last] = pHz[pHead]
                } else {
                    val j = (cHead + cCount) % capacity
                    cAt[j] = pAt[pHead]; cHz[j] = pHz[pHead]
                    cCount++
                }
                pHead = (pHead + 1) % capacity
                pCount--
            }
            pendingSound = false
        } finally { lock.unlock() }
    }

    private fun level(): Double = if (hz <= 0.0) 0.0 else if (phase < high) AMPLITUDE else -AMPLITUDE

    /** A step of [h] at [tau] (0 until 1) after the current sample: 2-sample PolyBLEP. */
    private fun step(h: Double, tau: Double) {
        if (h == 0.0) return
        val u = 1.0 - tau
        c0 += h * u * u * 0.5
        c1 -= h * tau * tau * 0.5
    }

    /** Runs the square wave from [ta] to [tb] within the current sample interval. */
    private fun advance(ta: Double, tb: Double) {
        if (hz <= 0.0) return
        var t = ta
        while (true) {
            val edge = if (phase < high) high else 1.0
            val need = (edge - phase) / dt
            if (t + need > tb) { phase += (tb - t) * dt; return }
            t += need
            if (edge >= 1.0) { phase = 0.0; step(2 * AMPLITUDE, t) } else { phase = high; step(-2 * AMPLITUDE, t) }
        }
    }

    /** A new setting at [tau]: a control word and count (OUT high, a new period) or the speaker gated off. */
    private fun apply(f: Double, tau: Double) {
        val before = level()
        if (f > 0.0 && f < sampleRate * 0.5) { hz = f; dt = f / sampleRate } else { hz = 0.0; dt = 0.0 }
        high = highPart(f)
        phase = 0.0
        step(level() - before, tau)
    }

    /** The high part of a mode-3 period at [f] Hz: settings are 1193182/N Hz for a PIT count N (Snd, SndFreq). */
    private fun highPart(f: Double): Double {
        if (f <= 0.0) return 0.5
        val n = Math.round(TempleClock.PIT_HZ / f)
        if (n < 3 || n > 65535 || n % 2 == 0L || Math.abs(TempleClock.PIT_HZ.toDouble() / n - f) > f * 1e-12) return 0.5
        return (n + 1) / 2 / n.toDouble()
    }
}
