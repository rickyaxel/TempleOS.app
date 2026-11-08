import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of ShellPerfTest.kt: desktop and runtime timing scenarios (opt-in). TEMPLEOS_SHELLPERF=<samples, e.g. 20>,
 * TEMPLEOS_SHELLPERFONLY=<scenario name prefixes, comma separated>, TEMPLEOS_SHELLPERFOUT (default .build/shellperf-swift.json).
 * Each scenario repeats one user-level operation on a headless Shell and records the thread's CPU time and the wall
 * time per operation (short operations in batches, divided). `game.*` measures only the UI thread while a program runs
 * on its own kernel thread: shell ticks at 60 Hz plus the per-frame conversion TempleView.render does for changed
 * pixels (surface and program frame to 32-bit colour). Run it in Release (`swift test -c release`) for app-like numbers.
 */
final class ShellPerfTests: XCTestCase {
    private var rows: [String] = []
    private var json: [String] = []
    private var only: [String] = []
    private var t: Int64 = 1000

    private func threadCpuNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    private func wanted(_ name: String) -> Bool { only.isEmpty || only.contains { name.hasPrefix($0) } }
    /** Whether a group's setup is needed: one of its scenario names (or name prefixes) is selected. */
    private func section(_ names: String...) -> Bool { only.isEmpty || names.contains { n in only.contains { n.hasPrefix($0) || $0.hasPrefix(n) } } }

    private struct Stat { let n: Int; let p50: Double; let p95: Double?; let min: Double; let max: Double; let mean: Double }

    private func stat(_ v: [Double]) -> Stat {
        let s = v.sorted()
        let p95: Double? = s.count >= 20 ? s[Int((0.95 * Double(s.count)).rounded(.up)) - 1] : nil
        return Stat(n: s.count, p50: s[s.count / 2], p95: p95, min: s.first!, max: s.last!, mean: s.reduce(0, +) / Double(s.count))
    }

    private func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "null" }

    /** Times [samples] runs of [op] ([batch] calls each, [setup] untimed before each run); µs per call. */
    private func scenario(_ name: String, _ samples: Int, batch: Int = 1, setup: () -> Void = {}, _ op: (Int) throws -> Void) rethrows {
        guard wanted(name) else { return }
        var cpu: [Double] = [], wall: [Double] = []
        for i in 0..<samples {
            setup()
            let c0 = threadCpuNs(), w0 = monoNanos()
            for j in 0..<batch { try op(i * batch + j) }
            let w = monoNanos() - w0, c = threadCpuNs() - c0
            cpu.append(Double(c) / 1e3 / Double(batch)); wall.append(Double(w) / 1e3 / Double(batch))
        }
        report(name, "us/op", cpu, wall, "")
    }

    private func report(_ name: String, _ unit: String, _ cpu: [Double], _ wall: [Double], _ extra: String) {
        let c = stat(cpu), w = stat(wall)
        rows.append("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) n=\(c.n) cpu p50=\(f(c.p50)) p95=\(f(c.p95)) min=\(f(c.min)) max=\(f(c.max)) | wall p50=\(f(w.p50)) p95=\(f(w.p95))  \(unit) \(extra)")
        json.append("{\"name\":\"\(name)\",\"unit\":\"\(unit)\",\"n\":\(c.n),\"cpuP50\":\(f(c.p50)),\"cpuP95\":\(f(c.p95)),\"cpuMin\":\(f(c.min))," +
            "\"cpuMax\":\(f(c.max)),\"cpuMean\":\(f(c.mean)),\"wallP50\":\(f(w.p50)),\"wallP95\":\(f(w.p95)),\"wallMin\":\(f(w.min)),\"wallMax\":\(f(w.max))" +
            (extra.isEmpty ? "" : ",\(extra)") + "}")
    }

    private func newShell(_ env: HeadlessEnv, _ w: Int = 360, _ h: Int = 800) -> Shell {
        let sh = Shell(env)
        sh.resize(w, h, 24, 16, 0, 0, 0)
        sh.restoreSession()
        _ = sh.tick()
        return sh
    }

    @discardableResult private func waitFor(_ sh: Shell, _ ms: Int, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end { _ = sh.tick(); if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    private func closeAll(_ sh: Shell) { for w in sh.windows { sh.close(w, force: true) }; _ = sh.tick() }
    private func redraw(_ sh: Shell) { sh.invalidate(); _ = sh.tick() }

    private func typeKey(_ sh: Shell, _ c: Character) {
        let (ch, sc) = Keys.forChar(Int(c.asciiValue!))
        sh.key(ch, sc, true); sh.key(ch, sc | Keys.SCF_KEY_UP, false); _ = sh.tick()
    }

    private func special(_ sh: Shell, _ code: Int) {
        let (ch, sc) = Keys.special(code)
        sh.key(ch, sc, true); sh.key(ch, sc | Keys.SCF_KEY_UP, false); _ = sh.tick()
    }

    func testShellPerf() throws {
        let envv = ProcessInfo.processInfo.environment
        guard let samples = Int(envv["TEMPLEOS_SHELLPERF"] ?? "") else { return }
        only = (envv["TEMPLEOS_SHELLPERFONLY"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tosm-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try run(samples, dir)
        let out = URL(fileURLWithPath: envv["TEMPLEOS_SHELLPERFOUT"] ?? FileManager.default.currentDirectoryPath + "/.build/shellperf-swift.json")
        try ("{\"platform\":\"swift\",\"samples\":\(samples),\"scenarios\":[\n  " + json.joined(separator: ",\n  ") + "\n]}\n").write(to: out, atomically: true, encoding: .utf8)
        print("SHELLPERF swift (\(samples) samples):\n" + rows.joined(separator: "\n"))
    }

    private func run(_ samples: Int, _ dir: URL) throws {
        let env = HeadlessEnv(dir)
        // ---- kernel boot (prelude, graphics library, kernel classes compiled for every program)
        try scenario("boot.kernel", max(5, samples / 2)) { _ in let k = Kernel(TestEnv(env.fs), "perf"); try k.boot() }
        // ---- shell start to the first frame (catalog, languages, session, first render)
        scenario("shell.start", samples) { _ in let sh = newShell(env); closeAll(sh) }
        let sh = newShell(env)
        // ---- idle desktop
        scenario("idle.tick.desktop", samples, batch: 200) { _ in _ = sh.tick() }
        scenario("render.desktop", samples, batch: 20) { _ in redraw(sh) }

        // ---- terminal
        let letters = Array("abcdefghijklmnop")
        if section("render.terminal", "idle.tick.terminal", "terminal.key") {
            Launch.terminal(sh, "C:/Home", "Dir;")
            let term = sh.focused!.app as! TerminalApp
            waitFor(sh, 30000) { term.kernel.console.plainText().contains("Home") && !term.busy }
            scenario("render.terminal", samples, batch: 20) { _ in redraw(sh) }
            scenario("idle.tick.terminal", samples, batch: 200) { _ in _ = sh.tick() }
            scenario("terminal.key", samples, batch: 16, setup: { for _ in 0..<16 { special(sh, Keys.SC_BACKSPACE) } }) { i in typeKey(sh, letters[i % 16]) }
            closeAll(sh)
        }

        // ---- editor: the largest bundled HolyC source
        let root = SHARED.appendingPathComponent("bundled-fs")
        if section("editor.", "render.editor", "idle.tick.editor") {
            var biggest = (path: "", size: 0)
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
            for case let u as URL in walker where u.pathExtension == "HC" {
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > biggest.size { biggest = (String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)), size) }
            }
            let bigPath = "C:/" + biggest.path
            scenario("editor.open.large", samples, setup: { closeAll(sh) }) { _ in Launch.editor(sh, bigPath); _ = sh.tick() }
            if !(sh.focused?.app is EditorApp) { Launch.editor(sh, bigPath); _ = sh.tick() }
            let ed = sh.focused!.app as! EditorApp
            for _ in 0..<400 { special(sh, Keys.SC_CURSOR_DOWN) }
            scenario("render.editor", samples, batch: 20) { _ in redraw(sh) }
            scenario("idle.tick.editor", samples, batch: 200) { _ in _ = sh.tick() }
            scenario("editor.key", samples, batch: 16, setup: { for _ in 0..<16 { special(sh, Keys.SC_BACKSPACE) } }) { i in typeKey(sh, letters[i % 16]) }
            scenario("editor.cursor", samples, batch: 20) { i in special(sh, (i / 20) % 2 == 0 ? Keys.SC_CURSOR_DOWN : Keys.SC_CURSOR_UP) }
            let er = sh.clientRect(sh.focused!)
            scenario("editor.scroll", samples, batch: 20) { i in ed.scroll(0, (i / 20) % 2 == 0 ? 64 : -64, er); _ = sh.tick() }
            closeAll(sh)
        }

        // ---- opening and closing windows (portrait deck)
        scenario("window.open-close", samples, batch: 4) { i in
            switch i % 4 {
            case 0: Launch.files(sh, "C:/Home/Examples")
            case 1: Launch.doc(sh, "C:/Doc/HelpIndex.DD")
            case 2: Launch.settings(sh)
            default: Launch.about(sh)
            }
            _ = sh.tick(); sh.close(sh.focused!, force: true); _ = sh.tick()
        }
        // ---- landscape desktop with four windows
        if section("render.landscape4", "window.focus.landscape4", "window.drag.landscape4") {
            let land = newShell(env, 800, 360)
            Launch.files(land, "C:/Home"); Launch.doc(land, "C:/Doc/HelpIndex.DD"); Launch.editor(land, "C:/Home/Examples/Hello.HC"); Launch.about(land)
            land.tile(); _ = land.tick()
            scenario("render.landscape4", samples, batch: 20) { _ in redraw(land) }
            scenario("window.focus.landscape4", samples, batch: 20) { i in land.focus(land.windows[i % land.windows.count]); _ = land.tick() }
            let top = land.windows.last!
            scenario("window.drag.landscape4", samples, batch: 20) { i in
                let x = top.x + top.w / 2, y = top.y + 12, d = (i / 20) % 2 == 0 ? 3 : -3
                land.pointer(PointerEvent(Ptr.DOWN, x, y, timeMs: t)); t += 16
                land.pointer(PointerEvent(Ptr.MOVE, x + d, y, timeMs: t)); t += 16
                land.pointer(PointerEvent(Ptr.UP, x + d, y, timeMs: t)); t += 400
                _ = land.tick()
            }
            closeAll(land)
        }

        // ---- virtual filesystem
        if section("fs.") {
            var files: [String] = [], dirs: [String] = []
            func walk(_ d: String) {
                dirs.append(d)
                for e in env.fs.list(d) ?? [] { let p = d.hasSuffix("/") ? d + e.name : d + "/" + e.name; if e.isDir { walk(p) } else { files.append(p) } }
            }
            walk("C:/")
            scenario("fs.list.all-dirs", samples) { _ in for d in dirs { _ = env.fs.list(d) } }
            scenario("fs.read.all-files", samples) { _ in for p in files { _ = env.fs.readFile(p) } }
            scenario("fs.stat.all-files", samples) { _ in for p in files { _ = env.fs.stat(p) } }
            rows.append("  (fs: \(dirs.count) directories, \(files.count) files)")
        }

        // ---- languages
        if section("l10n.") {
            let en = try String(contentsOf: SHARED.appendingPathComponent("runtime/l10n/en.json"), encoding: .utf8)
            let re = try NSRegularExpression(pattern: "^\\s*\"([a-z][^\"]*)\"\\s*:", options: .anchorsMatchLines)
            let keys = re.matches(in: en, range: NSRange(en.startIndex..., in: en)).map { String(en[Range($0.range(at: 1), in: en)!]) }
            scenario("l10n.tr.all-keys", samples, batch: 10) { _ in for k in keys { _ = tr(k) } }
            Launch.files(sh, "C:/Home"); _ = sh.tick()
            let locales = ["ja-JP", "ar-SA", "de-DE", "hi-IN", "en-US"]
            scenario("l10n.switch+render", samples, batch: 5) { i in L10n.use(locales[i % locales.count]); sh.applyLanguage(); _ = sh.tick() }
            L10n.use("en-US"); sh.applyLanguage(); closeAll(sh)
        }

        // ---- a game: UI-thread work per second of play (portrait, controls shown)
        for id in ["game.bombergolf", "game.varoom"] {
            let name = "game.ui." + id.dropFirst("game.".count)
            guard wanted(name) else { continue }
            let info = sh.catalog.programs.first { $0.id == id }!
            Launch.program(sh, info.path, info); _ = sh.tick()
            let prog = sh.focused!.app as! ProgramApp
            // a start PopUp (BattleLines' instructions) is answered as a player would
            waitFor(sh, 60000) { if sh.dialogOpen { typeKey(sh, "\n") }; return prog.kernel.frameCount > 30 && !sh.overlays().isEmpty }
            gameUi(name, sh, samples)
            closeAll(sh)
        }
    }

    /** One-second windows of a running program (see ShellPerfTest.gameUi). */
    private func gameUi(_ name: String, _ sh: Shell, _ samples: Int) {
        var rgba: [UInt32] = [], drawn: Int64 = -1
        var frames: [ObjectIdentifier: (UnsafeMutablePointer<UInt8>, [UInt32])] = [:], versions: [ObjectIdentifier: Int64] = [:]
        defer { for (_, f) in frames { f.0.deallocate() } }
        var cpu: [Double] = [], wall: [Double] = []
        var surfaceUploads = 0, frameUploads = 0, ticks = 0
        let tickNs: Int64 = 1_000_000_000 / 60
        let std = Palette.STD.map { UInt32(bitPattern: $0) }
        let sp = Keys.forChar(32), left = Keys.special(Keys.SC_CURSOR_LEFT), enter = Keys.forChar(10)
        for _ in 0..<samples {
            let c0 = threadCpuNs(), w0 = monoNanos()
            var next = w0
            for _ in 0..<60 {
                ticks += 1
                if ticks % 42 == 0 {
                    switch (ticks / 42) % 4 {
                    case 0, 2: sh.key(sp.0, sp.1, true); sh.key(sp.0, sp.1 | Keys.SCF_KEY_UP, false)
                    case 1: sh.key(left.0, left.1, true)
                    default: sh.key(left.0, left.1 | Keys.SCF_KEY_UP, false)
                    }
                    if sh.dialogOpen { sh.key(enter.0, enter.1, true); sh.key(enter.0, enter.1 | Keys.SCF_KEY_UP, false) }
                }
                _ = sh.tick()
                let s = sh.surface
                if s.version != drawn {
                    let n = s.width * s.height
                    if rgba.count != n { rgba = [UInt32](repeating: 0, count: n) }
                    let px = s.px
                    rgba.withUnsafeMutableBufferPointer { out in for j in 0..<n { out[j] = std[Int(px[j] & 15)] } }
                    drawn = s.version; surfaceUploads += 1
                }
                for o in sh.overlays() {
                    let src = o.source, id = ObjectIdentifier(src)
                    if versions[id] != src.frameVersion {
                        let n = src.frameW * src.frameH
                        if frames[id] == nil { frames[id] = (.allocate(capacity: n), [UInt32](repeating: 0, count: n)) }
                        var (idx, out) = frames[id]!
                        versions[id] = src.copyFrame(idx)
                        let pal = src.palette.map { UInt32(bitPattern: $0) }
                        out.withUnsafeMutableBufferPointer { o in for j in 0..<n { o[j] = pal[Int(idx[j] & 15)] } }
                        frames[id] = (idx, out)
                        frameUploads += 1
                    }
                }
                next += tickNs
                let wait = next - monoNanos()
                if wait > 0 { Thread.sleep(forTimeInterval: Double(wait) / 1e9) }
            }
            let w = monoNanos() - w0, c = threadCpuNs() - c0
            cpu.append(Double(c) / 1e6 / (Double(w) / 1e9)); wall.append(Double(w) / 1e6)
        }
        let secs = wall.reduce(0, +) / 1e3
        report(name, "uiCpuMs/s", cpu, wall, "\"surfaceUploadsPerSec\":\(f(Double(surfaceUploads) / secs)),\"frameUploadsPerSec\":\(f(Double(frameUploads) / secs)),\"ticksPerSec\":\(f(Double(ticks) / secs))")
        rows[rows.count - 1] += "  surfaceUploads/s=\(f(Double(surfaceUploads) / secs)) frameUploads/s=\(f(Double(frameUploads) / secs))"
    }
}
