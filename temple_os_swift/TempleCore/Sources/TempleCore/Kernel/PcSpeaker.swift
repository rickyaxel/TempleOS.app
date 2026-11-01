import Foundation
import os

// Port of kernel/PcSpeaker.kt.

/**
 * The PC speaker that TempleOS's Snd() drives (Kernel/KMisc.HC), as a sample renderer for the platform
 * audio output (iOS AVAudioEngine, Android AudioTrack). It is the one place that turns speaker settings
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
 * only tries the lock, so it never waits for a producer (events it cannot take yet wait for the next call),
 * and it never allocates. Everything other threads read goes through the lock.
 */
public final class PcSpeaker {
    /** Peak level of the square wave: -18 dBFS (a square's RMS level equals its peak). */
    public static let AMPLITUDE = 0.125
    /** The most a slow output start may delay a run of notes to keep their timing (iOS engine start: ~100 ms on the speaker, ~270 ms on Bluetooth). */
    public static let MAX_START_DELAY_NS: Int64 = 500_000_000
    /** How far the audio clock may fall behind real time (underrun, stall) before the timeline skips ahead. */
    public static let MAX_BEHIND_NS: Int64 = 60_000_000
    /**
     * Smaller differences between the audio clock and [post]'s clock are followed slowly (1/[SERVO_DIV] per
     * call, ignored below [SERVO_DEADBAND_NS]): an output whose device consumes samples a little faster or
     * slower than real time keeps settings at their real-time distances instead of playing them late, while
     * jitter in the device's timestamps (the Android emulator's can jump by ~10 ms) is not followed.
     */
    public static let SERVO_DIV: Int64 = 64
    public static let SERVO_DEADBAND_NS: Int64 = 2_000_000

    public let sampleRate: Int
    private let capacity: Int
    private let lock = OSAllocatedUnfairLock()

    // ---- guarded by lock
    private var latencyShared: Int64
    private let pAt: UnsafeMutablePointer<Int64>
    private let pHz: UnsafeMutablePointer<Double>
    private var pHead = 0
    private var pCount = 0
    private var pendingShared = false
    private var silentShared: Int64 = 0

    // ---- consumer state (audio thread only)
    private let cAt: UnsafeMutablePointer<Int64>
    private let cHz: UnsafeMutablePointer<Double>
    private var cHead = 0
    private var cCount = 0
    private var lat: Int64
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
    private var anchorNs: Int64 = 0
    private var delayNs: Int64 = 0
    private var frames: Int64 = 0
    /** Consecutive frames rendered with the speaker off and nothing queued (render thread). */
    public private(set) var silentFrames: Int64 = 0
    /** Frames rendered with the speaker on, since creation (render thread; diagnostics). */
    public private(set) var soundingFrames: Int64 = 0
    /** The current setting in Hz (0 = off), as rendered (render thread). */
    public var currentHz: Double { hz }

    public init(_ sampleRate: Int, _ latencyNs: Int64, capacity: Int = 1024) {
        self.sampleRate = sampleRate; self.capacity = capacity
        latencyShared = latencyNs; lat = latencyNs
        pAt = .allocate(capacity: capacity); pHz = .allocate(capacity: capacity)
        cAt = .allocate(capacity: capacity); cHz = .allocate(capacity: capacity)
    }

    deinit { pAt.deallocate(); pHz.deallocate(); cAt.deallocate(); cHz.deallocate() }

    /**
     * Delay from a setting's time to its sample: at least the audio buffer that is rendered ahead plus the
     * kernel's wake-up jitter. Set by the platform when it knows its buffer size (taken by [render]).
     */
    public var latencyNs: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return latencyShared }
        set { lock.lock(); latencyShared = newValue; lock.unlock() }
    }

    /**
     * The speaker is set to [hz] (0 = off) at [atNs] (the clock [render]'s nowNs uses). Non-finite and
     * negative values are off. A full queue (thousands of settings within [latencyNs]) keeps the newest:
     * it replaces the last queued one, as the speaker only ever has its latest setting.
     */
    public func post(_ atNs: Int64, _ hz: Double) {
        let f = hz.isFinite && hz > 0 ? hz : 0.0
        lock.lock()
        if pCount == capacity {
            let last = (pHead + pCount - 1) % capacity
            pAt[last] = atNs; pHz[last] = f
        } else {
            let i = (pHead + pCount) % capacity
            pAt[i] = atNs; pHz[i] = f
            pCount += 1
        }
        if f > 0 { pendingShared = true }
        lock.unlock()
    }

    /** A setting that sounds is queued: the platform starts or wakes its output for it. */
    public var pendingSound: Bool { lock.lock(); defer { lock.unlock() }; return pendingShared }
    /** Settings are queued that [render] has not taken yet. */
    public var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pCount > 0 }

    /** Whether the output may stop (any thread): at least [minFrames] silent frames and nothing queued. */
    public func idle(after minFrames: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pCount == 0 && !pendingShared && silentShared >= minFrames
    }

    /** The output stopped (paused, interrupted, reconfigured): the next [render] starts a new timeline. */
    public func restart() { running = false }

    /**
     * Writes [n] samples to [out]. [nowNs], on [post]'s clock, is when these samples start to play minus a
     * constant (the call time for a pull callback like iOS's; the presentation timestamp for Android's
     * AudioTrack). The first call after a (re)start anchors the timeline there. Calls with [clockValid] then
     * measure the timeline against the clock: the first one sets the reference (an output's start-up delay is
     * a constant, not a drift), later ones follow slow drift and skip after underruns and stalls.
     */
    /** Whether a clock reading of this run was used yet, and how far it was from the timeline then. */
    private var haveClock = false
    private var skew0: Int64 = 0

    public func render(_ out: UnsafeMutablePointer<Float>, _ n: Int, nowNs: Int64, clockValid: Bool = true) {
        drain()
        let nsPerFrame = 1e9 / Double(sampleRate)
        if !running {
            running = true; anchorNs = nowNs; frames = 0; delayNs = 0; haveClock = false
            // the setting that started the output came before the output could run: delay the whole run
            // by that much (bounded) instead of cutting its first note short
            for k in 0..<cCount {
                let j = (cHead + k) % capacity
                if cHz[j] > 0 { delayNs = min(max(nowNs - (cAt[j] + lat), 0), PcSpeaker.MAX_START_DELAY_NS); break }
            }
        }
        if clockValid {
            let behind = nowNs - (anchorNs + Int64(Double(frames) * nsPerFrame))
            if !haveClock { haveClock = true; skew0 = behind } else {
                let dv = behind - skew0
                if dv > PcSpeaker.MAX_BEHIND_NS || dv < -(lat + PcSpeaker.MAX_BEHIND_NS) { anchorNs += dv }
                else if dv > PcSpeaker.SERVO_DEADBAND_NS || dv < -PcSpeaker.SERVO_DEADBAND_NS { anchorNs += dv / PcSpeaker.SERVO_DIV }
            }
        }
        // settings are placed in frames since the anchor, so the samples do not depend on the block sizes
        let shift = lat + delayNs - anchorNs
        var sounding: Int64 = 0
        for i in 0..<n {
            c0 = carry; c1 = 0
            let y = level()
            var t = 0.0
            let now = Double(frames + Int64(i))
            while cCount > 0 {
                let p = Double(cAt[cHead] + shift) / nsPerFrame - now
                if p > 1 { break }
                // a late setting (p <= 0) happens right at this sample
                let te = min(max(p, t), 1.0)
                advance(t, te)
                apply(cHz[cHead], te)
                t = te
                cHead = (cHead + 1) % capacity; cCount -= 1
            }
            advance(t, 1.0)
            out[i] = Float(y + c0)
            carry = c1
            if hz > 0 { sounding += 1 }
        }
        frames += Int64(n)
        soundingFrames += sounding
        if hz == 0 && cCount == 0 && carry == 0 { silentFrames += Int64(n) } else { silentFrames = 0 }
        if lock.lockIfAvailable() { silentShared = silentFrames; lock.unlock() }
    }

    /** Array convenience (tests, captures): renders into out[off..<off+n]. */
    public func render(_ out: inout [Float], _ off: Int, _ n: Int, nowNs: Int64, clockValid: Bool = true) {
        out.withUnsafeMutableBufferPointer { b in render(b.baseAddress! + off, n, nowNs: nowNs, clockValid: clockValid) }
    }

    private func drain() {
        guard lock.lockIfAvailable() else { return }
        lat = latencyShared
        while pCount > 0 {
            if cCount == capacity {
                let last = (cHead + cCount - 1) % capacity
                cAt[last] = pAt[pHead]; cHz[last] = pHz[pHead]
            } else {
                let j = (cHead + cCount) % capacity
                cAt[j] = pAt[pHead]; cHz[j] = pHz[pHead]
                cCount += 1
            }
            pHead = (pHead + 1) % capacity
            pCount -= 1
        }
        pendingShared = false
        lock.unlock()
    }

    @inline(__always) private func level() -> Double { hz <= 0 ? 0 : phase < high ? PcSpeaker.AMPLITUDE : -PcSpeaker.AMPLITUDE }

    /** A step of [h] at [tau] (0 until 1) after the current sample: 2-sample PolyBLEP. */
    @inline(__always) private func step(_ h: Double, _ tau: Double) {
        if h == 0 { return }
        let u = 1 - tau
        c0 += h * u * u * 0.5
        c1 -= h * tau * tau * 0.5
    }

    /** Runs the square wave from [ta] to [tb] within the current sample interval. */
    private func advance(_ ta: Double, _ tb: Double) {
        if hz <= 0 { return }
        var t = ta
        while true {
            let edge = phase < high ? high : 1.0
            let need = (edge - phase) / dt
            if t + need > tb { phase += (tb - t) * dt; return }
            t += need
            if edge >= 1 { phase = 0; step(2 * PcSpeaker.AMPLITUDE, t) } else { phase = high; step(-2 * PcSpeaker.AMPLITUDE, t) }
        }
    }

    /** A new setting at [tau]: a control word and count (OUT high, a new period) or the speaker gated off. */
    private func apply(_ f: Double, _ tau: Double) {
        let before = level()
        if f > 0 && f < Double(sampleRate) * 0.5 { hz = f; dt = f / Double(sampleRate) } else { hz = 0; dt = 0 }
        high = PcSpeaker.highPart(f)
        phase = 0
        step(level() - before, tau)
    }

    /** The high part of a mode-3 period at [f] Hz: settings are 1193182/N Hz for a PIT count N (Snd, SndFreq). */
    static func highPart(_ f: Double) -> Double {
        if !(f > 0) { return 0.5 }
        let pit = Double(TempleClock.PIT_HZ)
        let r = (pit / f).rounded()
        if !(r >= 3 && r <= 65535) { return 0.5 }
        let n = Int64(r)
        if n % 2 == 0 || abs(pit / Double(n) - f) > f * 1e-12 { return 0.5 }
        return Double((n + 1) / 2) / Double(n)
    }
}
