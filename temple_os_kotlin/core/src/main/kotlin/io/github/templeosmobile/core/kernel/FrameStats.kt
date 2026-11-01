package io.github.templeosmobile.core.kernel

/**
 * Timing of the frames a kernel composes (draw_it callbacks, ODEs, controls, publish), kept for
 * the frame-rate readout and the performance benchmarks (PerfTest). Written by the kernel thread
 * only; readers on other threads may see a frame's values a little late, which is harmless.
 */
class FrameStats {
    /** Composition time of the last [CAP] frames, ns (ring buffer). */
    private val compose = LongArray(CAP)
    var frames = 0L; private set
    var composeTotalNs = 0L; private set
    var composeMaxNs = 0L; private set
    /** Time tasks (not frames) ran on the kernel thread, ns. */
    var taskNs = 0L; private set

    fun frame(ns: Long) {
        compose[(frames % CAP).toInt()] = ns
        frames++
        composeTotalNs += ns
        if (ns > composeMaxNs) composeMaxNs = ns
    }

    fun task(ns: Long) { taskNs += ns }

    /** The [p]-th percentile (0..100) of the recorded composition times, ns. */
    fun composePercentile(p: Int): Long {
        val n = minOf(frames, CAP.toLong()).toInt()
        if (n == 0) return 0
        val a = compose.copyOf(n); a.sort()
        return a[((n - 1) * p.coerceIn(0, 100)) / 100]
    }

    fun reset() { frames = 0; composeTotalNs = 0; composeMaxNs = 0; taskNs = 0 }

    companion object { const val CAP = 1024 }
}
