import Foundation
import os
import PureSwift
import TempleCore
import UIKit

#if TEMPLEOS_BENCH
/**
 * Headless benchmark mode (docs/native-validation), compiled only into bench builds
 * (SWIFT_ACTIVE_COMPILATION_CONDITIONS += TEMPLEOS_BENCH, bundle id io.github.templeosmobile.bench):
 *
 *   xcrun devicectl device process launch --device <udid> --console --terminate-existing io.github.templeosmobile.bench \
 *       -bench "programs=C:/Apps/X-Caliber/Run.HC;engines=terry,native;secs=4;memmb=128;runs=7;warmup=1;mode=light;tag=xc"
 *
 * Runs TempleCore's ScenarioRunner (the same deterministic virtual-time scenarios as the host differential tests, so
 * mode=parity checkpoint hashes compare with the host's) and prints one JSON line per run to stdout (prefix
 * TOSBENCH) and to Documents/bench/<tag>.jsonl; mode=parity also writes every checkpoint to <tag>.<program>.<engine>.json.
 * The app exits when done, so each launch starts cold. Instruments sees os_signpost intervals "boot"/"run"
 * (subsystem io.github.templeosmobile.bench, category Bench). Port of BenchMode.kt.
 */
enum BenchMode {
    private static let signposter = OSSignposter(subsystem: "io.github.templeosmobile.bench", category: "Bench")

    static func spec() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-bench"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func start(_ spec: String, status: @escaping (String) -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on for this app only while it runs
        let t = Thread {
            let tag = kv(spec)["tag"] ?? "bench"
            do { try run(spec, status: status) } catch { emit(tag, "{\"event\":\"error\",\"detail\":\(q("\(error)"))}") }
            print("TOSBENCH DONE \(tag)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.3)
            exit(0)
        }
        t.stackSize = 16 << 20
        t.name = "TempleOS-Bench"
        t.start()
    }

    private static func kv(_ spec: String) -> [String: String] {
        var d: [String: String] = [:]
        for part in spec.split(separator: ";") where part.contains("=") {
            let p = part.split(separator: "=", maxSplits: 1)
            d[String(p[0]).trimmingCharacters(in: .whitespaces)] = String(p[1]).trimmingCharacters(in: .whitespaces)
        }
        return d
    }

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static var outDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func emit(_ tag: String, _ line: String) {
        print("TOSBENCH " + line)
        fflush(stdout)
        let url = outDir.appendingPathComponent("\(tag).jsonl")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close() }
        else { try? (line + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    /** (physical footprint now, its lifetime peak, resident size) in bytes (task_vm_info; the footprint is what jetsam counts). */
    private static func memory() -> (Int64, Int64, Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        if kr != KERN_SUCCESS { return (-1, -1, -1) }
        return (Int64(info.phys_footprint), Int64(info.ledger_phys_footprint_peak), Int64(info.resident_size))
    }

    private static func cpuNs() -> Int64 {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return (Int64(u.ru_utime.tv_sec) + Int64(u.ru_stime.tv_sec)) * 1_000_000_000 + (Int64(u.ru_utime.tv_usec) + Int64(u.ru_stime.tv_usec)) * 1_000
    }

    private static func conditions() -> String {
        let p = ProcessInfo.processInfo
        let thermal: String
        switch p.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "unknown" }
        var battery = -1.0, state = "unknown"
        DispatchQueue.main.sync {
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = Double(UIDevice.current.batteryLevel)
            switch UIDevice.current.batteryState { case .charging: state = "charging"; case .full: state = "full"; case .unplugged: state = "unplugged"; default: state = "unknown" }
        }
        return "\"thermal_state\":\(q(thermal)),\"low_power_mode\":\(p.isLowPowerModeEnabled),\"battery_level\":\(battery),\"battery_state\":\(q(state))"
    }

    private static func machine() -> String {
        var s = utsname(); uname(&s)
        return withUnsafePointer(to: &s.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    private static func run(_ spec: String, status: @escaping (String) -> Void) throws {
        let d = kv(spec)
        let tag = d["tag"] ?? "bench"
        let programs = (d["programs"] ?? "C:/Demo/Games/BomberGolf.HC").split(separator: ",").map(String.init)
        let engines: [ScenarioEngine] = (d["engines"] ?? "terry,native").split(separator: ",").map { $0 == "terry" ? .terry : .native }
        let secs = Int64(d["secs"] ?? "") ?? 4
        let memMb = Int(d["memmb"] ?? "") ?? 32
        let runs = Int(d["runs"] ?? "") ?? 1
        let warmup = Int(d["warmup"] ?? "") ?? 0
        let parity = d["mode"] == "parity"
        let p = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        emit(tag, "{\"event\":\"device\",\"tag\":\(q(tag)),\"spec\":\(q(spec)),\"machine\":\(q(machine())),\"os\":\(q(p.operatingSystemVersionString)),\"cores\":\(p.processorCount)," +
            "\"active_cores\":\(p.activeProcessorCount),\"ram_mb\":\(p.physicalMemory >> 20),\"bundle\":\(q(Bundle.main.bundleIdentifier ?? "")),\"version\":\(q(info["CFBundleShortVersionString"] as? String ?? ""))," +
            "\"config\":\(q(config)),\"git\":\(q(info["TOSGitRevision"] as? String ?? "unknown")),\"uptime_s\":\(Int(p.systemUptime)),\(conditions())}")

        NativePrograms.catalog = NativeCatalog.source
        let resources = Bundle.main.resourceURL!
        let runtime: (String) -> [UInt8]? = { name in (try? Data(contentsOf: resources.appendingPathComponent("runtime").appendingPathComponent(name))).map { [UInt8]($0) } }
        let tmp = FileManager.default.temporaryDirectory
        var drives = 0
        let runner = ScenarioRunner(fsFactory: {
            let dir = tmp.appendingPathComponent("bench-drive-\(drives)", isDirectory: true)
            drives += 1
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return LayeredFs(BundleFolder(root: resources.appendingPathComponent("bundled-fs"), index: resources.appendingPathComponent("bundled-fs.index")), dir)
        }, runtime: runtime)

        var sample = 0
        for path in programs {
            let name = String(path.split(separator: "/").last ?? "").split(separator: ".").first.map(String.init) ?? "program"
            var schedule: [(ScenarioEngine, Bool)] = []
            for _ in 0..<warmup { for e in engines { schedule.append((e, true)) } }
            for i in 0..<runs { for e in (i % 2 == 0 ? engines : engines.reversed()) { schedule.append((e, false)) } }
            for (engine, isWarmup) in schedule {
                status("\(name) \(engine.rawValue) \(isWarmup ? "warm-up" : "run \(sample + 1)")")
                let (fp0, _, _) = memory()
                let peak = Peak(fp0)
                let stopSampling = Peak(0)
                let sampler = Thread { while stopSampling.value == 0 { peak.raise(memory().0); Thread.sleep(forTimeInterval: 0.05) } }
                sampler.start()
                var o = ScenarioRunner.Options()
                o.light = !parity
                o.memMb = memMb
                o.heartbeatMs = 10_000
                o.stallMs = 600_000
                var beats: [String] = []
                o.onProgress = { pr in beats.append("[\(pr.virtualMs),\(pr.wallMs),\(pr.ticks)]"); status("\(name) \(engine.rawValue): \(pr.virtualMs) ms of \(secs * 1000), \(pr.wallMs / 1000) s") }
                let c0 = cpuNs(), t0 = monoNanos()
                let sp = signposter.beginInterval("run", "\(name, privacy: .public) \(engine.rawValue, privacy: .public)")
                let r: ScenarioRun
                do { r = try runner.run(path, engine, ScenarioScript.named(d["script"] ?? "sweep", secs * 1000), o) } catch {
                    signposter.endInterval("run", sp)
                    stopSampling.raise(1)
                    emit(tag, "{\"event\":\"run_failed\",\"program\":\(q(path)),\"engine\":\(q(engine.rawValue)),\"memmb\":\(memMb),\"detail\":\(q("\(error)")),\"footprint\":\(memory().0)}")
                    continue
                }
                signposter.endInterval("run", sp)
                let t1 = monoNanos(), c1 = cpuNs()
                stopSampling.raise(1)
                let (fp1, fpPeak, rss1) = memory()
                let k = r.kernel
                let st = r.stats
                let lastJson = r.checkpoints.last.map { "{\"frame\":\($0.frame),\"globals\":\($0.globals),\"sounds\":\($0.sounds),\"sound\":\($0.sound),\"ticks\":\($0.ticks)}" } ?? "null"
                let failure = r.failure.map { q($0.kind + ": " + $0.detail) } ?? "null"
                let requested: Int64 = d["script"] == "cartesian" ? 11_000 : secs * 1000
                let line = "{\"event\":\"run\",\"program\":\(q(path)),\"engine\":\(q(engine.rawValue)),\"warmup\":\(isWarmup),\"sample\":\(isWarmup ? -1 : sample)," +
                    "\"virtual_ms\":\(r.completedMs),\"requested_ms\":\(requested),\"script\":\(q(d["script"] ?? "sweep")),\"completed\":\(r.failure == nil && r.completedMs == requested),\"failure\":\(failure),\"exit_category\":\(q(k.exitCategory ?? "")),\"dyn_expr_evaluations\":\(k.dynExprEvaluations)," +
                    "\"memmb\":\(memMb),\"boot_ms\":\(Double(st.bootWallNs) / 1e6),\"wall_ms\":\(Double(t1 - t0) / 1e6),\"run_wall_ms\":\(Double(st.runWallNs) / 1e6)," +
                    "\"task_wall_ms\":\(Double(st.taskWallNs) / 1e6),\"frame_wall_ms\":\(Double(st.frameWallNs) / 1e6),\"cpu_ms\":\(Double(c1 - c0) / 1e6),\"ticks\":\(st.ticks),\"frames\":\(st.frames)," +
                    "\"final_hash\":\(lastJson),\"bytecode_instructions\":\(engine == .native ? k.vm.instructionsExecuted : -1),\"arena_bytes\":\(st.arenaBytes),\"arena_high_water\":\(st.arenaHighWater)," +
                    "\"arena_peak_allocated\":\(st.arenaPeakAllocated),\"arena_limit\":\(st.arenaLimit),\"footprint_before\":\(fp0),\"footprint_after\":\(fp1),\"footprint_peak_sampled\":\(peak.value)," +
                    "\"footprint_lifetime_peak\":\(fpPeak),\"resident_after\":\(rss1),\"heartbeats\":[\(beats.joined(separator: ","))],\(conditions())}"
                k.terminate("done")
                emit(tag, line)
                if parity { try? ScenarioRunner.checkpointsJson(r.checkpoints).write(to: outDir.appendingPathComponent("\(tag).\(name).\(engine.rawValue).json"), atomically: true, encoding: .utf8) }
                if !isWarmup && engine == engines.last! { sample += 1 }
                for i in 0..<drives { try? FileManager.default.removeItem(at: tmp.appendingPathComponent("bench-drive-\(i)")) }
            }
        }
    }

    /** A maximum shared with the sampling thread. */
    private final class Peak {
        private let lock = NSLock()
        private var v: Int64
        init(_ v: Int64) { self.v = v }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
        func raise(_ x: Int64) { lock.lock(); if x > v { v = x }; lock.unlock() }
    }
}

/** A plain status screen for the benchmark (no shell, no saved state is read or written). */
final class BenchViewController: UIViewController {
    private let label = UILabel()
    let spec: String
    init(spec: String) { self.spec = spec; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.textColor = .white
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.text = "TempleOS bench: \(spec)"
        label.frame = view.bounds.insetBy(dx: 16, dy: 80)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
        BenchMode.start(spec) { [weak self] s in DispatchQueue.main.async { self?.label.text = s } }
    }
}
#endif
