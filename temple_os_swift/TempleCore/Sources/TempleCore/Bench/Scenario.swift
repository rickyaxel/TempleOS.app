import Foundation

// Port of temple_os_kotlin/core/.../bench/Scenario.kt: deterministic program scenarios (docs/native-validation)
// run in virtual time on Pure Terry or on the program's native translation, hashed at checkpoints. The same
// code runs in the host differential tests (PureSwiftTests) and in the app's benchmark mode, so a phone's
// checkpoint hashes compare with the host's (and with the Kotlin runner's: same scripts, same hashes).

public enum ScenarioEvent {
    case key(Int64, Int, Int64, Bool)
    case mouse(Int64, Int, Int, Bool, Bool)
    case brk(Int64)
    public var ms: Int64 {
        switch self { case .key(let m, _, _, _): return m; case .mouse(let m, _, _, _, _): return m; case .brk(let m): return m }
    }
}

public struct ScenarioScript {
    public let name: String
    public let durationMs: Int64
    public let events: [ScenarioEvent]
    public let stepMs: Int64
    public init(name: String, durationMs: Int64, events: [ScenarioEvent], stepMs: Int64 = 20) {
        self.name = name; self.durationMs = durationMs; self.events = events; self.stepMs = stepMs
    }

    /** The sweep tests' synthetic input: mouse circling, a click every 2 s, SPACE and LEFT alternating. */
    public static func sweep(_ durationMs: Int64) -> ScenarioScript {
        var ev: [ScenarioEvent] = []
        var lastKey: Int64 = 0
        var ms: Int64 = 0
        while ms < durationMs {
            let ph = Int((ms / 10) % 400)
            let mx = 170 + (ph < 200 ? ph : 400 - ph) * 3 / 2
            let my = 120 + Int((ms / 7) % 240)
            ev.append(.mouse(ms, mx, my, (ms / 500) % 4 == 1, false))
            if ms - lastKey > 700 {
                lastKey = ms
                let (ch, sc) = (ms / 700) % 3 == 0 ? Keys.special(Keys.SC_CURSOR_LEFT) : Keys.forChar(Int(UInt8(ascii: " ")))
                ev.append(.key(ms, ch, sc, true)); ev.append(.key(ms, ch, sc | Keys.SCF_KEY_UP, false))
            }
            ms += 20
        }
        return ScenarioScript(name: "sweep", durationMs: durationMs, events: ev)
    }

    /** Cartesian's formula entry (Scenario.kt cartesian()): formulas typed and entered, any key between, ESC; 11 s. */
    public static func cartesian() -> ScenarioScript {
        var ev: [ScenarioEvent] = []
        var ms: Int64 = 300
        for f in ["2*x", "Sin(x/20)*100", "x*x/100", "2*"] {
            ev += typing(ms, f + "\n"); ms += 2200
            ev += typing(ms, " "); ms += 300
        }
        let (ch, sc) = Keys.forChar(27)
        ev.append(.key(ms, ch, sc, true)); ev.append(.key(ms + 20, ch, sc | Keys.SCF_KEY_UP, false))
        return ScenarioScript(name: "cartesian", durationMs: 11_000, events: ev)
    }

    /** A scenario by name: "cartesian", or the sweep for [durationMs]. */
    public static func named(_ name: String, _ durationMs: Int64) -> ScenarioScript { name == "cartesian" ? cartesian() : sweep(durationMs) }

    /** Typing [text] from [startMs] on, one key every [gapMs] (down, then up 20 ms later). */
    public static func typing(_ startMs: Int64, _ text: String, gapMs: Int64 = 60) -> [ScenarioEvent] {
        var ev: [ScenarioEvent] = []
        var ms = startMs
        for c in text.unicodeScalars {
            let (ch, sc) = Keys.forChar(Int(c.value))
            ev.append(.key(ms, ch, sc, true)); ev.append(.key(ms + 20, ch, sc | Keys.SCF_KEY_UP, false))
            ms += gapMs
        }
        return ev
    }
}

public enum ScenarioEngine: String { case terry, native }

/** Fixed entropy (12345), logged sound, popups answered from a list (ScenarioEnv in Kotlin). */
open class ScenarioEnv: KernelEnv {
    public let fs: VirtualFs?
    public let memMb: Int
    private let runtime: (String) -> [UInt8]?
    public var sound: [(Int64, Double)] = []
    public var popupAnswers: [Int64] = []
    public init(_ fs: VirtualFs, memMb: Int, runtime: @escaping (String) -> [UInt8]?) { self.fs = fs; self.memMb = memMb; self.runtime = runtime }
    public func runtimeFile(_ name: String) -> [UInt8]? { runtime(name) }
    public func entropy() -> Int64 { 12345 }
    public var memoryLimit: Int { memMb << 20 }
    public func sound(_ kernel: Kernel, _ freq: Double, _ atNs: Int64) { sound.append((kernel.now(), freq)) }
    public func popupRequested(_ kernel: Kernel, _ req: PopupRequest) {
        if !popupAnswers.isEmpty { req.result = popupAnswers.removeFirst(); return }
        req.result = req.items.first(where: { $0.value != -1 })?.value ?? -1
    }
}

public struct ScenarioCheckpoint: Equatable {
    public var ms: Int64, frames: Int64, frame: Int64, sounds: Int, sound: Int64, console: Int64, ticks: Int64, finished: Bool, globals: Int64
    public init(ms: Int64, frames: Int64, frame: Int64, sounds: Int, sound: Int64, console: Int64, ticks: Int64, finished: Bool, globals: Int64) {
        self.ms = ms; self.frames = frames; self.frame = frame; self.sounds = sounds; self.sound = sound
        self.console = console; self.ticks = ticks; self.finished = finished; self.globals = globals
    }
    public var json: String {
        "{\"ms\":\(ms),\"frames\":\(frames),\"frame\":\(frame),\"sounds\":\(sounds),\"sound\":\(sound),\"console\":\(console),\"ticks\":\(ticks),\"finished\":\(finished),\"globals\":\(globals)}"
    }
}

public struct ScenarioStats {
    public let bootWallNs: Int64, runWallNs: Int64, taskWallNs: Int64, frameWallNs: Int64, ticks: Int64, frames: Int64
    public let arenaBytes: Int, arenaHighWater: Int, arenaPeakAllocated: Int64, arenaLimit: Int
}

/** Why a run did not reach its end (a slow run is not a failure; see Scenario.kt). */
public struct ScenarioFailure {
    public static let STALLED = "STALLED", WALL_LIMIT = "WALL_LIMIT", HOST_EXCEPTION = "HOST_EXCEPTION"
    public let kind: String, atMs: Int64, detail: String
}

public struct ScenarioProgress { public let virtualMs: Int64, wallMs: Int64, ticks: Int64, frames: Int64, ticksPerSecond: Int64 }

public final class ScenarioRun {
    public let kernel: Kernel, env: ScenarioEnv, checkpoints: [ScenarioCheckpoint], stats: ScenarioStats, completedMs: Int64, failure: ScenarioFailure?
    init(kernel: Kernel, env: ScenarioEnv, checkpoints: [ScenarioCheckpoint], stats: ScenarioStats, completedMs: Int64, failure: ScenarioFailure?) {
        self.kernel = kernel; self.env = env; self.checkpoints = checkpoints; self.stats = stats; self.completedMs = completedMs; self.failure = failure
    }
}

public enum ScenarioHash {
    public static func fnv(_ b: UnsafeBufferPointer<UInt8>, _ h0: Int64 = -0x340d631b7bdddcdb) -> Int64 {
        var h = h0
        for x in b { h = (h ^ Int64(x)) &* 0x100000001b3 }
        return h
    }
    public static func fnv(_ b: [UInt8], _ h0: Int64 = -0x340d631b7bdddcdb) -> Int64 { b.withUnsafeBufferPointer { fnv($0, h0) } }

    public static let HOST_GLOBALS: Set<String> = ["Fs", "adam_task", "sys_task_being_screen_updated"]

    public static func latin1Less(_ a: String, _ b: String) -> Bool { latin1(a).lexicographicallyPrecedes(latin1(b)) }

    public static func globals(_ k: Kernel, skip: Set<String> = HOST_GLOBALS) -> Int64 {
        var h: Int64 = -0x340d631b7bdddcdb
        for name in k.prog.globals.keys.sorted(by: latin1Less) {
            guard let s = k.prog.globals[name] as? GlobalSym, !skip.contains(name) else { continue }
            let size = min(max(s.type.size, 1), 1 << 20)
            if s.addr + size > k.mem.size { continue }
            h = fnv(latin1(name), h)
            h = fnv(k.mem.readBytes(s.addr, size), h)
        }
        return h
    }

    /** One global's storage (whole, not capped), or nil. */
    public static func global(_ k: Kernel, _ name: String) -> Int64? {
        guard let s = k.prog.globals[name] as? GlobalSym else { return nil }
        let size = max(s.type.size, 1)
        if s.addr + size > k.mem.size { return nil }
        return fnv(k.mem.readBytes(s.addr, size))
    }

    /** Kotlin Double.toRawBits().toString() of the sound log entries, joined as in Scenario.kt. */
    public static func sound(_ env: ScenarioEnv) -> Int64 {
        let s = env.sound.map { "\($0.0):\(Int64(bitPattern: $0.1.bitPattern))" }.joined(separator: ";")
        return fnv(Array(s.utf8))
    }
}

/** A flag shared with the monitor thread (Swift has no portable volatile; a lock keeps it simple). */
private final class Shared<T> {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

public final class ScenarioRunner {
    public struct Options {
        public var light = false
        public var memMb = 32
        public var popups: [Int64] = []
        public var heartbeatMs: Int64 = 0
        public var onProgress: ((ScenarioProgress) -> Void)? = nil
        public var stallMs: Int64 = 0
        public var wallLimitMs: Int64 = Int64.max
        public var onCheckpoint: ((Kernel, Int64) -> Void)? = nil
        public var env: ((VirtualFs) -> ScenarioEnv)? = nil
        public init() {}
    }

    private let fsFactory: () -> VirtualFs
    private let runtime: (String) -> [UInt8]?
    public init(fsFactory: @escaping () -> VirtualFs, runtime: @escaping (String) -> [UInt8]?) { self.fsFactory = fsFactory; self.runtime = runtime }

    public func newEnv(_ fs: VirtualFs, _ o: Options) -> ScenarioEnv {
        let e = o.env?(fs) ?? ScenarioEnv(fs, memMb: o.memMb, runtime: runtime)
        e.popupAnswers.append(contentsOf: o.popups)
        return e
    }

    public func boot(_ path: String, _ engine: ScenarioEngine, _ env: ScenarioEnv) throws -> Kernel {
        let k = Kernel(env, String(path.split(separator: "/").last ?? ""))
        k.virtualTime = true
        k.virtualCostTicks = true
        if engine == .native {
            guard let img = NativePrograms.find(path) else { throw VmKill("\(path) is not translated") }
            if let r = NativePrograms.staleReason(img, env.fs) { throw VmKill("stale translation: \(r)") }
            guard let cat = NativePrograms.catalog else { throw VmKill("no native catalog installed") }
            k.native = NativeBinding(cat.prelude, img)
        }
        try k.boot()
        guard let src = env.fs?.readFile(path) else { throw VmKill("no \(path)") }
        try k.runProgram(path, src)
        return k
    }

    public static func advanceTo(_ k: Kernel, _ ms: Int64) throws -> Bool {
        k.virtualStopAt = ms * 1_000_000
        while k.now() < k.virtualStopAt { if try k.step(1_000_000_000) < 0 { return false } }
        return true
    }

    public func run(_ path: String, _ engine: ScenarioEngine, _ script: ScenarioScript, _ o: Options = Options()) throws -> ScenarioRun {
        let env = newEnv(fsFactory(), o)
        let b0 = monoNanos()
        let k = try boot(path, engine, env)
        let b1 = monoNanos()
        let w0 = k.wallTaskNs, f0 = k.wallFrameNs
        let stop = Shared<ScenarioFailure?>(nil)
        let curMs = Shared<Int64>(0)
        let done = Shared(false)
        var monitor: Thread? = nil
        if o.heartbeatMs > 0 || o.stallMs > 0 || o.wallLimitMs != Int64.max {
            let period = [o.heartbeatMs, o.stallMs / 4, 250].filter { $0 > 0 }.min()!
            let t = Thread {
                let start = monoNanos()
                var lastTicks: Int64 = -1, lastV: Int64 = -1, lastMove = start, lastBeat = start, beatTicks: Int64 = 0
                while !done.value {
                    Thread.sleep(forTimeInterval: Double(period) / 1000)
                    if done.value { return }
                    let now = monoNanos()
                    let ticks = k.vm.ticksExecuted, v = k.now()
                    if ticks != lastTicks || v != lastV { lastTicks = ticks; lastV = v; lastMove = now }
                    var fail: ScenarioFailure? = nil
                    if o.stallMs > 0 && now - lastMove > o.stallMs * 1_000_000 {
                        fail = ScenarioFailure(kind: ScenarioFailure.STALLED, atMs: curMs.value, detail: "no budget tick and no virtual time for \((now - lastMove) / 1_000_000) ms at \(v / 1_000_000) ms virtual, ticks \(ticks)")
                    } else if o.wallLimitMs != Int64.max && now - start > o.wallLimitMs * 1_000_000 {
                        fail = ScenarioFailure(kind: ScenarioFailure.WALL_LIMIT, atMs: curMs.value, detail: "still progressing after \(o.wallLimitMs) ms wall (\(v / 1_000_000) ms virtual, ticks \(ticks))")
                    }
                    if let f = fail { stop.value = f; k.stopRequested = true; k.vm.interrupt = true; return }
                    if o.heartbeatMs > 0 && now - lastBeat >= o.heartbeatMs * 1_000_000 {
                        let rate = (ticks - beatTicks) * 1_000_000_000 / max(1, now - lastBeat)
                        o.onProgress?(ScenarioProgress(virtualMs: v / 1_000_000, wallMs: (now - start) / 1_000_000, ticks: ticks, frames: k.frameCount, ticksPerSecond: rate))
                        lastBeat = now; beatTicks = ticks
                    }
                }
            }
            t.name = "scenario-monitor"
            t.start()
            monitor = t
        }
        defer { done.value = true; _ = monitor }
        var cps: [ScenarioCheckpoint] = []
        let evs = script.events.sorted { $0.ms < $1.ms }
        var i = 0
        var ms: Int64 = 0
        var alive = true
        var completed: Int64 = 0
        var failure: ScenarioFailure? = nil
        let r0 = monoNanos()
        while ms <= script.durationMs {
            curMs.value = ms
            while i < evs.count && evs[i].ms <= ms {
                switch evs[i] {
                case .key(_, let ch, let sc, let down): k.post(.key(ch: ch, sc: sc, down: down))
                case .mouse(_, let x, let y, let lb, let rb): k.post(.mouse(x: x, y: y, lb: lb, rb: rb))
                case .brk: k.post(.breakKey)
                }
                i += 1
            }
            if alive {
                do { alive = try ScenarioRunner.advanceTo(k, ms) } catch {
                    k.console.write("rror: host exception \(error)\n")
                    failure = ScenarioFailure(kind: ScenarioFailure.HOST_EXCEPTION, atMs: ms, detail: "\(error)")
                    alive = false
                }
            }
            if let f = stop.value { failure = f; k.terminate(f.kind.lowercased()); break }
            completed = ms
            if o.light && ms + script.stepMs <= script.durationMs { ms += script.stepMs; continue }
            o.onCheckpoint?(k, ms)
            let frame = k.publishLock.sync { ScenarioHash.fnv(UnsafeBufferPointer(start: k.published, count: Kernel.W * Kernel.H)) }
            cps.append(ScenarioCheckpoint(ms: ms, frames: k.frameCount, frame: frame, sounds: env.sound.count, sound: ScenarioHash.sound(env),
                                          console: ScenarioHash.fnv(latin1(k.console.plainText())), ticks: k.vm.ticksExecuted, finished: k.finished,
                                          globals: ScenarioHash.globals(k)))
            ms += script.stepMs
        }
        let r1 = monoNanos()
        let stats = ScenarioStats(bootWallNs: b1 - b0, runWallNs: r1 - r0, taskWallNs: k.wallTaskNs - w0, frameWallNs: k.wallFrameNs - f0,
                                  ticks: k.vm.ticksExecuted, frames: k.frameCount, arenaBytes: k.mem.size, arenaHighWater: k.mem.highWater,
                                  arenaPeakAllocated: k.mem.peakAllocated, arenaLimit: k.mem.maxBytes)
        return ScenarioRun(kernel: k, env: env, checkpoints: cps, stats: stats, completedMs: completed, failure: failure)
    }

    public static func checkpointsJson(_ cps: [ScenarioCheckpoint]) -> String { "[\n" + cps.map { $0.json }.joined(separator: ",\n") + "\n]\n" }
}
