/**
 * TempleOS's time base. Port of kernel/TempleClock.kt (same integer arithmetic, same results).
 *
 * The PC's 8254 PIT counts a 1193182 Hz oscillator. TempleOS programs channel 0 in mode 2 with
 * SYS_TIMER0_PERIOD = 65536*182/10/JIFFY_FREQ = 1192 (Kernel/KernelA.HH, Kernel/KMain.HC TimersInit), and every
 * interrupt adds one to cnts.jiffies: a jiffy is 1192/1193182 s = 0.999009 ms, not the nominal 1 ms of
 * JIFFY_FREQ = 1000. Sleep, SleepUntil, Play and everything else that counts jiffies runs 0.099 % faster than
 * nominal (the reference VM counts 20019 jiffies in 20 RTC seconds; docs/audio/TEMPLEOS_AUDIO_FIDELITY.md).
 * Channel 2, the speaker, counts the same oscillator, so Snd's pitches are PIT_HZ/count.
 */
public enum TempleClock {
    public static let PIT_HZ: Int64 = 1193182
    /** Kernel/KernelA.HH SYS_TIMER0_PERIOD: PIT clocks per jiffy. */
    public static let JIFFY_PIT_CLOCKS: Int64 = 1192
    /** Kernel/KernelA.HH JIFFY_FREQ: what TempleOS calls the jiffy rate (Sleep(mS) waits mS*JIFFY_FREQ/1000 jiffies). */
    public static let JIFFY_FREQ: Int64 = 1000
    private static let NS: Int64 = 1_000_000_000
    /** Jiffies beyond ~244 years: treated as "never" by [jiffyStartNs]. */
    private static let MAX_JIFFY: Int64 = 7_700_000_000_000

    /** cnts.jiffies at [ns] nanoseconds after jiffy 0 (floor; exact integer arithmetic). */
    public static func jiffyAt(_ ns: Int64) -> Int64 {
        if ns < 0 { return -1 - jiffyAt(-1 - ns) }
        let ticks = (ns / NS) * PIT_HZ + (ns % NS) * PIT_HZ / NS
        return ticks / JIFFY_PIT_CLOCKS
    }

    /** The first nanosecond of jiffy [j] (the smallest ns with jiffyAt(ns) == j); saturates far in the future. */
    public static func jiffyStartNs(_ j: Int64) -> Int64 {
        if j >= MAX_JIFFY { return Int64.max / 2 }
        if j <= -MAX_JIFFY { return Int64.min / 2 }
        if j < 0 { return -jiffyStartNs(-j) } // only ever a deadline already past (the clock starts at 0)
        let t = j * JIFFY_PIT_CLOCKS
        return (t / PIT_HZ) * NS + ((t % PIT_HZ) * NS + PIT_HZ - 1) / PIT_HZ
    }
}
