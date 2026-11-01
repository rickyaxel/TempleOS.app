import Foundation
import XCTest
@testable import TempleCore

/**
 * Port of SweepTest.kt: runs original Demo/<dir> programs for 3 s of virtual
 * time with the same synthetic integer-only input as the Kotlin sweep and
 * writes the final frame (PNG + raw .idx) for cross-platform parity checks
 * (tools/parity/compare_frames.py). Enable with TEMPLEOS_SWEEP=Games|Graphics|Apps,
 * optionally TEMPLEOS_ONLY=Name1,Name2.
 */
final class SweepTests: XCTestCase {
    func testSweep() throws {
        let envv = ProcessInfo.processInfo.environment
        guard let which = envv["TEMPLEOS_SWEEP"] else { return }
        let only = envv["TEMPLEOS_ONLY"]
        let iso = REFERENCE.appendingPathComponent("templeos-iso")
        // "Catalog": every program the apps ship (shared/program-manifests/catalog.json), run from the bundled drive
        let root = which == "Catalog" ? SHARED.appendingPathComponent("bundled-fs") : iso
        let fm = FileManager.default
        let fs: VirtualFs
        if which == "Catalog" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            fs = LayeredFs(DirBundle(root, SHARED.appendingPathComponent("bundled-fs.index")), tmp)
        } else { fs = HostDirFs(root) }
        var ids: [String: String] = [:]
        var files: [URL] = []
        if which == "Apps" {
            for d in (try fm.contentsOfDirectory(atPath: iso.appendingPathComponent("Apps").path)).sorted() {
                let f = iso.appendingPathComponent("Apps/\(d)/Run.HC")
                if fm.fileExists(atPath: f.path) { files.append(f) }
            }
        } else if which == "Catalog" {
            let cat = try Catalog.parse(String(contentsOf: SHARED.appendingPathComponent("program-manifests/catalog.json"), encoding: .utf8))
            for p in cat.programs {
                let f = root.appendingPathComponent(String(p.path.dropFirst(3)))
                ids[f.path] = p.id
                files.append(f)
            }
            files.sort { $0.path < $1.path }
        } else {
            files = try fm.contentsOfDirectory(atPath: iso.appendingPathComponent("Demo/\(which)").path).filter { $0.hasSuffix(".HC") }.sorted()
                .map { iso.appendingPathComponent("Demo/\(which)/\($0)") }
        }
        if let o = only { files = files.filter { f in o.split(separator: ",").contains { f.path.contains($0) } } }
        let outDir = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/frames/\(which)")
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var report = ""
        for f in files {
            let rel = String(f.path.dropFirst(root.path.count + 1))
            let path = "C:/" + rel
            let base = ids[f.path] ?? (which == "Apps" ? f.deletingLastPathComponent().lastPathComponent : f.deletingPathExtension().lastPathComponent)
            let k = Kernel(TestEnv(fs), f.lastPathComponent)
            k.virtualTime = true
            try k.boot()
            let t0 = monoNanos()
            do { try k.runProgram(path, readFileBytes(f)!) } catch {
                report += "\(base.padEnd(28)) CRASH \(errorMessage(error).take(150))\n"; continue
            }
            let limitNs: Int64 = 3_000_000_000
            var lastKey: Int64 = 0
            while k.now() < limitNs && monoNanos() - t0 < 15_000_000_000 {
                let ms = k.now() / 1_000_000
                let ph = Int((ms / 10) % 400)
                let mx = 170 + (ph < 200 ? ph : 400 - ph) * 3 / 2
                let my = 120 + Int((ms / 7) % 240)
                k.post(.mouse(x: mx, y: my, lb: (ms / 500) % 4 == 1, rb: false))
                if ms - lastKey > 700 {
                    lastKey = ms
                    let (ch, sc) = (ms / 700) % 3 == 0 ? Keys.special(Keys.SC_CURSOR_LEFT) : Keys.forChar(32)
                    k.post(.key(ch: ch, sc: sc, down: true)); k.post(.key(ch: ch, sc: sc | Keys.SCF_KEY_UP, down: false))
                }
                // advance exactly 20 ms of virtual time per input tick (independent of host speed)
                k.virtualStopAt = (ms + 20) * 1_000_000
                var done = false
                do { while k.now() < k.virtualStopAt { if try k.step(1_000_000_000) < 0 { done = true; break } } } catch {
                    k.console.write("rror: host exception \(errorMessage(error))\n"); break
                }
                if done { break }
            }
            let realMs = (monoNanos() - t0) / 1_000_000
            let out = k.console.plainText()
            let err = out.components(separatedBy: "\n").first { $0.contains("Compile error") || $0.contains("Unhandled") || $0.contains("rror:") || $0.contains("draw_it") }
            let status: String
            if let e = err { status = "ERR  \(e.take(160))" }
            else if k.finished { status = "EXIT \(k.exitMessage ?? "")" }
            else { status = "RUN  frames=\(k.frameCount) gfx=\(k.graphicsUsed) instr=\(k.vm.instructionsExecuted / 1_000_000)M real=\(realMs)ms vt=\(k.now() / 1_000_000)ms" }
            report += "\(base.padEnd(28)) \(status)\n"
            if k.graphicsUsed || k.frameCount > 0 {
                writePNG(k.published, 640, 480, k.palette, to: outDir.appendingPathComponent("\(base).png"))
                try? Data(bytes: k.published, count: 640 * 480).write(to: outDir.appendingPathComponent("\(base).idx"))
            }
            k.terminate("done")
        }
        try report.write(to: outDir.appendingPathComponent("../sweep-\(which).txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
