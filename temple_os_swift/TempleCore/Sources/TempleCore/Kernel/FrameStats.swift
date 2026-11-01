import Foundation

// Port of kernel/FrameStats.kt.

/**
 * Timing of the frames a kernel composes (draw_it callbacks, ODEs, controls, publish), kept for
 * the frame-rate readout and the performance benchmarks (PerfTests). Written by the kernel thread
 * only; readers on other threads may see a frame's values a little late, which is harmless.
 */
public final class FrameStats {
    public static let CAP = 1024
    /** Composition time of the last [CAP] frames, ns (ring buffer). */
    private var compose = [Int64](repeating: 0, count: FrameStats.CAP)
    public private(set) var frames: Int64 = 0
    public private(set) var composeTotalNs: Int64 = 0
    public private(set) var composeMaxNs: Int64 = 0
    /** Time tasks (not frames) ran on the kernel thread, ns. */
    public private(set) var taskNs: Int64 = 0

    public init() {}

    func frame(_ ns: Int64) {
        compose[Int(frames % Int64(FrameStats.CAP))] = ns
        frames += 1
        composeTotalNs &+= ns
        if ns > composeMaxNs { composeMaxNs = ns }
    }

    func task(_ ns: Int64) { taskNs &+= ns }

    /** The [p]-th percentile (0..100) of the recorded composition times, ns. */
    public func composePercentile(_ p: Int) -> Int64 {
        let n = Int(min(frames, Int64(FrameStats.CAP)))
        if n == 0 { return 0 }
        let a = compose[0..<n].sorted()
        return a[((n - 1) * min(max(p, 0), 100)) / 100]
    }

    public func reset() { frames = 0; composeTotalNs = 0; composeMaxNs = 0; taskNs = 0 }
}
