import Foundation
import TempleCore
import PureSwift

// Port of temple_os_kotlin/purekotlin/src/test/.../Harness.kt and Differential.kt: the same scripts and
// the same checkpoint hashes, so Swift runs compare with each other and with the Kotlin runs.

let REPO: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let SHARED: URL = REPO.appendingPathComponent("shared")

func readFileBytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map { [UInt8]($0) } }

/** Kernel environment for differential tests (core ScenarioEnv with the repository's runtime files). */
final class ParityEnv: ScenarioEnv {
    init(_ fs: VirtualFs) {
        super.init(fs, memMb: Int(ProcessInfo.processInfo.environment["TEMPLEOS_MEMMB"] ?? "") ?? 32, runtime: sharedRuntimeFile)
    }
}

func sharedRuntimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent("runtime/\(name)")) }

func bundledFs() -> VirtualFs {
    let dir = NSTemporaryDirectory() + "pureswift-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")), dir)
}

enum Engine { case terry, native; var core: ScenarioEngine { self == .terry ? .terry : .native } }

/** The core scenario runner over the repository's runtime and bundled drive (the app's benchmark mode runs the same code). */
let runner: ScenarioRunner = { NativePrograms.catalog = NativeCatalog.source; return ScenarioRunner(fsFactory: bundledFs, runtime: sharedRuntimeFile) }()

func bootProgram(_ path: String, _ engine: Engine, popups: [Int64] = []) throws -> (Kernel, ParityEnv) {
    NativePrograms.catalog = NativeCatalog.source
    let env = ParityEnv(bundledFs())
    env.popupAnswers = popups
    return (try runner.boot(path, engine.core, env), env)
}

func advanceTo(_ k: Kernel, _ ms: Int64) throws -> Bool { try ScenarioRunner.advanceTo(k, ms) }

enum Ev {
    case key(Int64, Int, Int64, Bool)
    case mouse(Int64, Int, Int, Bool, Bool)
    var ms: Int64 { switch self { case .key(let m, _, _, _): return m; case .mouse(let m, _, _, _, _): return m } }
}

/** Script.sweep in Differential.kt (integers only). */
func sweepScript(_ durationMs: Int64) -> [Ev] {
    var ev: [Ev] = []
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
    return ev
}

typealias Checkpoint = ScenarioCheckpoint

func fnv(_ b: UnsafeBufferPointer<UInt8>, _ h0: Int64 = -0x340d631b7bdddcdb) -> Int64 { ScenarioHash.fnv(b, h0) }
func fnv(_ b: [UInt8], _ h0: Int64 = -0x340d631b7bdddcdb) -> Int64 { ScenarioHash.fnv(b, h0) }

let HOST_GLOBALS: Set<String> = ScenarioHash.HOST_GLOBALS

func latin1Less(_ a: String, _ b: String) -> Bool { ScenarioHash.latin1Less(a, b) }

func globalsHash(_ k: Kernel) -> Int64 { ScenarioHash.globals(k) }

func soundHash(_ env: ScenarioEnv) -> Int64 { ScenarioHash.sound(env) }

extension Ev {
    var core: ScenarioEvent {
        switch self {
        case .key(let m, let ch, let sc, let d): return .key(m, ch, sc, d)
        case .mouse(let m, let x, let y, let lb, let rb): return .mouse(m, x, y, lb, rb)
        }
    }
}

/**
 * Runs the events on [engine] with the core scenario runner. Slow but progressing runs: TEMPLEOS_PARITYSTALL=<ms>
 * (stop only when nothing moves), TEMPLEOS_HEARTBEAT=<ms> (progress lines on stdout).
 */
func runScript(_ path: String, _ engine: Engine, _ events: [Ev], _ durationMs: Int64, light: Bool = false, popups: [Int64] = [],
               wallLimitMs: Int64 = Int64.max) throws -> (Kernel, [Checkpoint]) {
    let env = ProcessInfo.processInfo.environment
    var o = ScenarioRunner.Options()
    o.light = light
    o.popups = popups
    o.env = { ParityEnv($0) }
    o.wallLimitMs = wallLimitMs
    o.stallMs = Int64(env["TEMPLEOS_PARITYSTALL"] ?? "") ?? 0
    o.heartbeatMs = Int64(env["TEMPLEOS_HEARTBEAT"] ?? "") ?? 0
    let name = String(path.split(separator: "/").last ?? "")
    o.onProgress = { p in print("heartbeat \(name) \(engine): \(p.virtualMs) ms virtual of \(durationMs), wall \(p.wallMs / 1000) s, ticks \(p.ticks) (\(p.ticksPerSecond)/s), frames \(p.frames)") }
    o.onCheckpoint = { k, ms in
        if let dm = env["TEMPLEOS_DUMPGLOBALS"], Int64(dm) == ms { dumpGlobals(k, "/tmp/claude-501/globals-swift-\(engine).txt") }
        // cross-platform debugging (TEMPLEOS_DUMPFRAME=<ms>): frame, main task and arena bytes in the temporary
        // directory, to diff with the Kotlin harness's -Dtempleos.dumpframe files (F-11)
        if let df = env["TEMPLEOS_DUMPFRAME"], Int64(df) == ms {
            let bytes = k.publishLock.sync { Data(bytes: k.published, count: Kernel.W * Kernel.H) }
            try? bytes.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("frame-swift-\(engine).bin"))
            let ab = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: k.mem.ld1($0)) })
            try? ab.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arena-swift-\(engine).bin"))
            if let m = k.mainTask {
                let tb = Data((0..<8192).map { UInt8(truncatingIfNeeded: k.mem.ld1(m.fsAddr + $0)) })
                try? tb.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("task-swift-\(engine).bin"))
            }
        }
    }
    let r = try runner.run(path, engine.core, ScenarioScript(name: "script", durationMs: durationMs, events: events.map { $0.core }), o)
    if let f = r.failure, f.kind != ScenarioFailure.HOST_EXCEPTION { throw VmKill("\(engine) run stopped at \(f.atMs) ms virtual time (\(f.kind): \(f.detail))") }
    return (r.kernel, r.checkpoints)
}

/** The Kotlin harness's checkpoints for the same program (purekotlin/build/parity/<id>.<engine>.json), if it ran. */
func kotlinCheckpoints(_ id: String, _ engine: String) -> [Checkpoint]? {
    let url = REPO.appendingPathComponent("temple_os_kotlin/purekotlin/build/parity/\(id).\(engine).json")
    guard let data = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    func i(_ o: [String: Any], _ k: String) -> Int64 { (o[k] as? NSNumber)?.int64Value ?? 0 }
    return arr.map { o in
        Checkpoint(ms: i(o, "ms"), frames: i(o, "frames"), frame: i(o, "frame"), sounds: Int(i(o, "sounds")), sound: i(o, "sound"),
                   console: i(o, "console"), ticks: i(o, "ticks"), finished: (o["finished"] as? Bool) ?? false, globals: i(o, "globals"))
    }
}

func firstDifference(_ a: [Checkpoint], _ b: [Checkpoint]) -> String? {
    for j in 0..<min(a.count, b.count) where a[j] != b[j] {
        let x = a[j], y = b[j]
        var d: [String] = []
        if x.ticks != y.ticks { d.append("ticks \(x.ticks) vs \(y.ticks)") }
        if x.frames != y.frames { d.append("frames \(x.frames) vs \(y.frames)") }
        if x.frame != y.frame { d.append("frame pixels differ") }
        if x.sounds != y.sounds || x.sound != y.sound { d.append("sound \(x.sounds) vs \(y.sounds)") }
        if x.console != y.console { d.append("console differs") }
        if x.finished != y.finished { d.append("finished \(x.finished) vs \(y.finished)") }
        if x.globals != y.globals { d.append("globals differ") }
        return "at \(x.ms) ms: " + d.joined(separator: "; ")
    }
    return a.count == b.count ? nil : "checkpoint counts \(a.count) vs \(b.count)"
}

func dumpGlobals(_ k: Kernel, _ path: String) {
    var out = ""
    for name in k.prog.globals.keys.sorted(by: latin1Less) {
        guard let s = k.prog.globals[name] as? GlobalSym, !HOST_GLOBALS.contains(name) else { continue }
        let size = min(max(s.type.size, 1), 1 << 20)
        if s.addr + size > k.mem.size { continue }
        out += "\(name) \(size) \(fnv(k.mem.readBytes(s.addr, size)))\n"
    }
    try? out.write(toFile: path, atomically: true, encoding: .isoLatin1)
}
