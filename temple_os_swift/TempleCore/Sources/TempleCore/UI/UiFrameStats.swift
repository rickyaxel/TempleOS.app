import Foundation

// Port of ui/UiFrameStats.kt.

/**
 * UI-thread frame pacing while the display loop runs continuously (a program on screen): the
 * platform reports each display callback. A long gap means the UI thread was blocked (input and
 * drawing waited). Read once per second by the perf log ([ProgramApp]); UI thread only.
 */
public final class UiFrameStats {
    public static let JANK_NS: Int64 = 40_000_000
    private var last: Int64 = 0
    public private(set) var frames = 0
    public private(set) var maxGapNs: Int64 = 0
    /** Gaps longer than [JANK_NS] (two 60 Hz frames and a bit). */
    public private(set) var janks = 0

    public init() {}

    /** A display callback at [nowNs]. [restarted]: the loop was idle before (its gap is not a stall). */
    public func frame(_ nowNs: Int64, restarted: Bool = false) {
        if last != 0 && !restarted {
            let gap = nowNs - last
            if gap > maxGapNs { maxGapNs = gap }
            if gap > UiFrameStats.JANK_NS { janks += 1 }
        }
        last = nowNs
        frames += 1
    }

    /** Returns (frames, maxGapMs, janks) since the last call, and starts a new interval. */
    public func take() -> (Int, Double, Int) {
        let r = (frames, Double(maxGapNs) / 1e6, janks)
        frames = 0; maxGapNs = 0; janks = 0
        return r
    }
}
