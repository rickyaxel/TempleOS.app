package io.github.templeosmobile.core.ui

/**
 * UI-thread frame pacing while the display loop runs continuously (a program on screen): the
 * platform reports each display callback. A long gap means the UI thread was blocked (input and
 * drawing waited). Read once per second by the perf log ([ProgramApp]); UI thread only.
 */
class UiFrameStats {
    private var last = 0L
    var frames = 0; private set
    var maxGapNs = 0L; private set
    /** Gaps longer than [JANK_NS] (two 60 Hz frames and a bit). */
    var janks = 0; private set

    /**
     * A display callback at [nowNs]. [restarted]: the loop was idle before (its gap is not a stall).
     */
    fun frame(nowNs: Long, restarted: Boolean = false) {
        if (last != 0L && !restarted) {
            val gap = nowNs - last
            if (gap > maxGapNs) maxGapNs = gap
            if (gap > JANK_NS) janks++
        }
        last = nowNs
        frames++
    }

    /** Returns "frames maxGapMs janks" since the last call, and starts a new interval. */
    fun take(): Triple<Int, Double, Int> {
        val r = Triple(frames, maxGapNs / 1e6, janks)
        frames = 0; maxGapNs = 0; janks = 0
        return r
    }

    companion object { const val JANK_NS = 40_000_000L }
}
