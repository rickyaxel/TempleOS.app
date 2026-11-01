import Foundation

// Port of ui/App.kt: KernelRunner only (Ptr, PointerEvent, MenuItem, FrameSource,
// Overlay and App live in AppBase.swift).

/** Runs a kernel on its own thread (each program is isolated in its own VM). */
public final class KernelRunner {
    public let kernel: Kernel
    private let onFinished: () -> Void
    private let lock = Monitor()
    // Kotlin @Volatile fields: plain vars (single writer, benign races, as on the JVM).
    public private(set) var paused = false
    private var running = true
    public private(set) var booted = false
    public private(set) var bootError: String?
    private var thread: Thread?
    /** Set when the runner thread has exited (replaces Thread.join). Guarded by [lock]. */
    private var threadDone = false

    public init(_ kernel: Kernel, _ onFinished: @escaping () -> Void = {}) {
        self.kernel = kernel; self.onFinished = onFinished
    }

    public func start(_ beforeRun: @escaping (Kernel) throws -> Void) {
        kernel.wakeLock = lock
        let t = Thread { [self] in
            defer { lock.sync { threadDone = true; lock.notifyAll() } }
            do {
                let t0 = monoNanos()
                try kernel.boot()
                print("TempleOSMobile boot \(kernel.name) \((monoNanos() - t0) / 1_000_000) ms")
                booted = true
                try beforeRun(kernel)
            } catch {
                bootError = errorMessage(error)
                kernel.console.write("$RED$" + L10n.tr8("program.failed_to_start", ("reason", bootError ?? "")) + "$FG$\n")
                running = false
                onFinished()
                return
            }
            loop()
        }
        t.name = "HolyC:" + kernel.name
        t.stackSize = 16 << 20 // deep compiler/interpreter recursion
        t.threadPriority = 0.4 // Thread.NORM_PRIORITY - 1
        thread = t
        t.start()
    }

    private func loop() {
        var finishedNotified = false
        while running {
            if paused { lock.sync { if paused && running { lock.wait(ms: 200) } }; continue }
            let wait: Int64
            do { wait = try kernel.step(12_000_000) } catch {
                kernel.console.write("\n$RED$" + L10n.tr8("program.internal_error", ("error", error)) + "$FG$\n"); kernel.terminate("internal error"); wait = -1
            }
            if wait < 0 {
                if !finishedNotified { finishedNotified = true; onFinished() }
                if !kernel.shellMode {
                    lock.sync { if running { lock.wait(ms: 250) } }
                    continue
                }
            }
            // to the nanosecond: a whole-millisecond wait woke sleeping tasks up to 1 ms late, and Sleep loops
            // (scales, Beep, sound effects) drifted by that much per note
            if wait > 0 { lock.sync { if running { lock.wait(ns: min(wait, 50_000_000)) } } }
        }
    }

    public func post(_ e: KInput) { kernel.post(e) }

    public func setPaused(_ p: Bool) {
        if p != paused { kernel.clockPaused(p) }
        paused = p
        kernel.env.paused(kernel, p)
        lock.sync { lock.notifyAll() }
    }

    public func wake() { lock.sync { lock.notifyAll() } }

    /** Stops the program: Break first (lets it clean up), then terminates. */
    public func stop(hard: Bool = false) {
        if !hard {
            kernel.post(.breakKey)
            wake()
            return
        }
        running = false
        kernel.stopRequested = true
        kernel.vm.interrupt = true
        kernel.silence()
        wake()
        // thread?.join(1500)
        if thread != nil && Thread.current !== thread {
            let deadline = monoNanos() + 1_500_000_000
            lock.sync {
                while !threadDone {
                    let left = (deadline - monoNanos()) / 1_000_000
                    if left <= 0 { break }
                    lock.wait(ms: left)
                }
            }
        }
    }

    public var alive: Bool { running }
}
