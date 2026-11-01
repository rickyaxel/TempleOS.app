import Foundation
import XCTest
@testable import TempleCore

fileprivate func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: max(0, n)) }

/**
 * Bounded, fixed-seed fuzz/property tests (Swift port of FuzzTest.kt).
 *
 * Host-level failures in Swift are mostly traps (array index, integer overflow,
 * force unwrap, stack overflow) and AddressSanitizer reports, which kill the
 * test process. Therefore every case first writes its input to
 * shared/test-vectors/fuzz-repro/swift-<target>-INFLIGHT.* (plus a .txt with the
 * seed); the file is removed when the case completes. A crashed run leaves the
 * in-flight reproducer behind. Recoverable host failures (thrown errors other
 * than CompileError/HolyC exceptions escaping the API, kernel "internal error",
 * hangs) are minimized in-process, saved, and fail the test.
 *
 * Iterations: env TEMPLEOS_FUZZ_ITERS overrides each target's default.
 * Replay one input: TEMPLEOS_FUZZ_REPLAY=<file> TEMPLEOS_FUZZ_REPLAY_TARGET=<target> (testReplay).
 */
final class FuzzTests: XCTestCase {
    static let env = ProcessInfo.processInfo.environment
    static let ITERS: Int? = env["TEMPLEOS_FUZZ_ITERS"].flatMap { Int($0) }
    static let SEED: UInt64 = env["TEMPLEOS_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x7E3B_1E05
    static let REPRO = SHARED.appendingPathComponent("test-vectors/fuzz-repro")
    static func iters(_ d: Int) -> Int { ITERS ?? d }
    /** TEMPLEOS_FUZZ_SKIP_KNOWN=1 skips inputs hitting the known #if-nesting stack overflow (a process crash) to search further. */
    static let SKIP_KNOWN = env["TEMPLEOS_FUZZ_SKIP_KNOWN"] == "1"
    static func knownCrash(_ b: [UInt8]) -> Bool {
        guard SKIP_KNOWN else { return false }
        var run = 0, best = 0
        for x in b { run = x == 0x28 ? run + 1 : 0; best = max(best, run) }
        return best >= 1000 && String(decoding: b, as: UTF8.self).contains("#if")
    }
    static func caseSeed(_ target: String, _ i: Int) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in target.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return SEED &* 1_000_003 &+ h &* 7919 &+ UInt64(i)
    }

    /** Hung threads that ignored the interrupt (they cannot be killed and keep burning CPU). */
    var leakedThreads = 0

    // MARK: deterministic RNG (SplitMix64)

    struct Rng {
        var s: UInt64
        init(_ seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
        mutating func bool() -> Bool { next() & 1 == 1 }
        mutating func i64() -> Int64 { Int64(bitPattern: next()) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    // MARK: corpora

    static func files(_ dir: String, _ ext: String, maxSize: Int = Int.max) -> [(String, [UInt8])] {
        let u = SHARED.appendingPathComponent(dir)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(ext) }.sorted()
        return names.compactMap { n in
            guard let b = readFileBytes(u.appendingPathComponent(n)), b.count < maxSize else { return nil }
            return ("\(dir)/\(n)", b)
        }
    }
    static let corpusHC: [(String, [UInt8])] = {
        var r: [(String, [UInt8])] = files("test-vectors/holyc", ".HC")
        for d in ["bundled-fs/Demo", "bundled-fs/Demo/Games", "bundled-fs/Home/Examples", "bundled-fs/Demo/Graphics"] { r += files(d, ".HC", maxSize: 40_000) }
        return r.sorted { $0.0 < $1.0 }
    }()
    static let corpusDD: [(String, [UInt8])] = files("bundled-fs/Doc", ".DD")

    // MARK: harness

    final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

    /** Runs [block] on a thread with the production kernel stack (16 MiB) and a wall-clock limit. */
    func isolated(_ timeoutMs: Int, stack: Int = 16 << 20, onTimeout: @escaping () -> Void = {}, _ block: @escaping () -> String?) -> String? {
        let sem = DispatchSemaphore(value: 0)
        let res = Box<String?>(nil)
        let t = Thread { res.v = block(); sem.signal() }
        t.stackSize = stack
        t.start()
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            onTimeout()
            if sem.wait(timeout: .now() + .seconds(3)) == .timedOut { leakedThreads += 1; return "HANG(unresponsive)" }
            // Stoppable but slower than the wall limit: the documented limitation V-17 (natives
            // that call HolyC per point). Logged, not a defect; unresponsive hangs still are.
            print("[fuzz] slow but stopped by interrupt")
            return nil
        }
        return res.v
    }

    func sigOf(_ e: Error) -> String {
        if e is CompileError || e is VmFault || e is VmUncaught || e is VmKill { return "\(type(of: e))" }
        let m = errorMessage(e)
        return "\(type(of: e)):" + String(m.prefix(60)).replacingOccurrences(of: "\n", with: " ")
    }

    func printable(_ b: [UInt8], _ max: Int = 600) -> String {
        var s = ""
        for x in b.prefix(max) { if (x >= 32 && x <= 126) || x == 10 { s.append(Character(Unicode.Scalar(x))) } else { s += String(format: "\\x%02x", x) } }
        if b.count > max { s += "...(\(b.count) bytes)" }
        return s
    }

    func splitLines(_ b: [UInt8]) -> [[UInt8]] {
        var r: [[UInt8]] = []; var s = 0
        for i in 0..<b.count where b[i] == 10 { r.append(Array(b[s...i])); s = i + 1 }
        if s < b.count { r.append(Array(b[s...])) }
        return r
    }

    func minimize(_ input: [UInt8], _ sig: String, budgetMs: Int, _ exec: ([UInt8]) -> String?) -> [UInt8] {
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000)
        func same(_ b: [UInt8]) -> Bool { Date() < deadline && exec(b) == sig }
        var units = splitLines(input)
        var n = 2
        while units.count >= 2 && Date() < deadline {
            let chunk = (units.count + n - 1) / n
            var reduced = false
            var i = 0
            while i < units.count {
                let cand = Array(units[0..<i]) + Array(units[min(units.count, i + chunk)...])
                if !cand.isEmpty && same(cand.flatMap { $0 }) { units = cand; n = max(n - 1, 2); reduced = true; break }
                i += chunk
            }
            if !reduced { if n >= units.count { break }; n = min(units.count, n * 2) }
        }
        var b = units.flatMap { $0 }
        n = 2
        while b.count >= 2 && Date() < deadline {
            let chunk = (b.count + n - 1) / n
            var reduced = false
            var i = 0
            while i < b.count {
                let cand = Array(b[0..<i]) + Array(b[min(b.count, i + chunk)...])
                if !cand.isEmpty && same(cand) { b = cand; n = max(n - 1, 2); reduced = true; break }
                i += chunk
            }
            if !reduced { if n >= b.count { break }; n = min(b.count, n * 2) }
        }
        return b
    }

    final class Defect { let seed: UInt64; let sig: String; var input: [UInt8]; init(_ s: UInt64, _ g: String, _ i: [UInt8]) { seed = s; sig = g; input = i } }

    /** Collects defects for one target and manages the in-flight crash reproducer. */
    final class Collector {
        let t: FuzzTests; let target: String; let ext: String
        var defects: [String: Defect] = [:]; var order: [String] = []
        var ran = 0
        var minimizeLeftMs = 40_000
        var tooManyLeaks: Bool { t.leakedThreads >= 2 }
        init(_ t: FuzzTests, _ target: String, _ ext: String) {
            self.t = t; self.target = target; self.ext = ext
            try? FileManager.default.createDirectory(at: FuzzTests.REPRO, withIntermediateDirectories: true)
        }
        var inflight: URL { FuzzTests.REPRO.appendingPathComponent("swift-\(target)-INFLIGHT.\(ext)") }
        var inflightTxt: URL { FuzzTests.REPRO.appendingPathComponent("swift-\(target)-INFLIGHT.txt") }
        func begin(_ seed: UInt64, _ input: [UInt8], _ note: String = "") {
            try? Data(input).write(to: inflight)
            try? "runtime: swift\ntarget: \(target)\nseed: \(seed)\nIf this file exists after a run, the process crashed (trap/ASan) on this input.\n\(note)\n".write(to: inflightTxt, atomically: false, encoding: .utf8)
        }
        func end() { try? FileManager.default.removeItem(at: inflight); try? FileManager.default.removeItem(at: inflightTxt) }
        func found(_ seed: UInt64, _ sig: String, _ input: [UInt8], _ exec: (([UInt8]) -> String?)?, budgetMs: Int = 20_000, detail: String = "") {
            if sig.hasPrefix("HANG(slow") { print("[fuzz:\(target)] note seed=\(seed) \(sig) (interrupt worked; not counted as a defect)"); end(); return }
            if defects[sig] != nil { return }
            let d = Defect(seed, sig, input); defects[sig] = d; order.append(sig)
            print("[fuzz:\(target)] DEFECT seed=\(seed) sig=\(sig) \(detail)")
            end()
            if let ex = exec, !sig.hasPrefix("HANG"), minimizeLeftMs > 0 {
                let t0 = Date()
                let m = t.minimize(input, sig, budgetMs: min(budgetMs, minimizeLeftMs), ex)
                minimizeLeftMs -= Int(Date().timeIntervalSince(t0) * 1000)
                if ex(m) == sig { d.input = m }
            }
            let base = "swift-\(target)-" + String(sig.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.prefix(80))
            try? Data(d.input).write(to: FuzzTests.REPRO.appendingPathComponent("\(base).\(ext)"))
            try? "runtime: swift\ntarget: \(target)\nseed: \(seed)\nsignature: \(sig)\n\(detail)\nminimized input (\(d.input.count) bytes): \(t.printable(d.input, 2000))\n"
                .write(to: FuzzTests.REPRO.appendingPathComponent("\(base).txt"), atomically: false, encoding: .utf8)
            print("[fuzz:\(target)] minimized (\(d.input.count) bytes): \(t.printable(d.input))")
        }
        func finish(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
            end()
            print("[fuzz:\(target)] \(ran > 0 ? ran : n) iterations run, \(defects.count) distinct defect(s)")
            if !defects.isEmpty {
                XCTFail("[fuzz:\(target)] \(defects.count) defect(s):\n" + order.map { s in let d = defects[s]!; return "seed=\(d.seed) \(s) input=\(t.printable(d.input, 200))" }.joined(separator: "\n"), file: file, line: line)
            }
        }
    }

    // MARK: HolyC execution

    func runProgramCase(_ src: [UInt8], maxSteps: Int = 60, wallMs: Int = 15_000, flagStkOver: Bool = false, fs: VirtualFs? = nil,
                        setup: @escaping (Kernel) throws -> Void = { _ in }) -> String? {
        let kref = Box<Kernel?>(nil)
        return isolated(wallMs, onTimeout: { kref.v?.stopRequested = true; kref.v?.vm.interrupt = true }) {
            let k = Kernel(TestEnv(fs), "fuzz")
            k.virtualTime = true
            do { try k.boot(); try setup(k) } catch { return "boot:" + self.sigOf(error) }
            kref.v = k
            do { try k.runProgram("C:/Home/Fuzz.HC", src) } catch { return "runProgram:" + self.sigOf(error) }
            var steps = 0
            while steps < maxSteps {
                steps += 1
                do { if try k.step(20_000_000) < 0 { break } } catch { return "step:" + self.sigOf(error) }
            }
            let txt = k.console.plainText()
            if let r = txt.range(of: "internal error: ") { return "kernel-internal-error:" + String(txt[r.upperBound...].prefix(30)).replacingOccurrences(of: "\n", with: " ") }
            if txt.contains("host stack overflow") { return "kernel-host-stack-overflow" }
            if flagStkOver && txt.contains("operand stack overflow") { return "masked(operand stack overflow)" }
            return nil
        }
    }

    // MARK: 1. lexer/preprocessor/parser/codegen

    static func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

    let specials: [(inout Rng) -> String] = [
        { r in rep("(", r.int(20000) + 100) }, { r in rep("{", r.int(20000) + 100) }, { r in rep("[", r.int(5000) + 100) },
        { r in rep("-", r.int(20000) + 100) + "1" }, { r in rep("!", r.int(20000) + 100) + "1" }, { r in rep("*", r.int(20000) + 100) + "p" },
        { r in rep("if(1)", r.int(10000) + 100) + ";" }, { r in rep("x=", r.int(10000) + 100) + "1;" }, { r in "1" + rep("+1", r.int(30000) + 100) + ";" },
        { r in rep("(I64)", r.int(10000) + 100) + "1;" }, { r in "class A\(r.int(99)){" + rep("union{", r.int(3000) + 10) },
        { r in rep("9", r.int(400) + 20) }, { r in "0x" + rep("F", r.int(100) + 17) }, { r in "1e\(r.int(1000000))" },
        { r in "1." + rep("9", r.int(400)) + "e-99999" },
        { _ in "\"unterminated string" }, { _ in "/* unterminated comment" }, { _ in "/*/*/*" },
        { r in "'" + String("abcdefghijk".prefix(r.int(11))) }, { r in "'" + String("abcdefghijklmnop".prefix(r.int(16) + 1)) + "'" },
        { _ in "\"\\" }, { _ in "\"\\x" }, { _ in "'\\" },
        { _ in "\n#define A A\nA;\n" }, { _ in "\n#define A B\n#define B A\nA;\n" },
        { r in let n = r.int(24) + 4; return "\n" + (0..<n).map { "#define M\($0) M\($0 + 1) M\($0 + 1)\n" }.joined() + "M0;\n" },
        { _ in "\n#include \"Fuzz.HC\"\n" }, { _ in "\n#include \"C:/Home/Fuzz.HC\"\n" }, { _ in "\n#include \"::/Home/Fuzz\"\n" },
        { _ in "\n#include \"/etc/passwd\"\n" }, { _ in "\n#include \"../../../../../../etc/passwd\"\n" },
        { r in "\n#if " + rep("(", r.int(20000) + 10) + "1\n#endif\n" }, { r in "\n" + rep("#if 1\n", r.int(5000) + 10) },
        { _ in "\n#else\n" }, { _ in "\n#endif\n" }, { _ in "\n#\n" }, { _ in "\n#define\n" }, { _ in "\n#exe {}\n" },
        { r in String((0..<(r.int(6) + 1)).map { _ in Character(Unicode.Scalar(UInt8(5 + r.int(27)))) }) },
        { r in String((0..<(r.int(6) + 1)).map { _ in Character(Unicode.Scalar(UInt8(0x80 + r.int(128)))) }) },
        { _ in "\u{0}" }, { r in "\u{0}" + String((0..<16).map { _ in Character(Unicode.Scalar(UInt8(r.int(256)))) }) },
        { _ in "$$" }, { _ in "$SP,\"\",BI=1$" }, { _ in "$IB,\"\",BI=99$" }, { _ in "$" },
        { _ in "goto L;" }, { _ in "L:" }, { _ in "case 1:" }, { _ in "break;" }, { _ in "return;" },
        { _ in "sizeof(" }, { _ in "offset(" }, { _ in "lastclass" }, { _ in "->" }, { _ in "::" },
        { _ in "switch(1){start:end:}" }, { _ in "try{throw;}catch{}" }, { _ in "asm{" }, { _ in "_extern" }, { _ in "#exe{" },
        { _ in "U0 F(...){F(1,2,3);}F;" }, { _ in "I64 a[0x7FFFFFFF];" }, { _ in "I64 a[-1];" }, { _ in "U8 a[1<<40];" },
        { _ in "class C{C c;};" }, { _ in "class D{I64 x;} d; d.y;" }, { _ in "U0 (*fp)()=0x1234; fp();" },
    ]

    /** Latin-1 bytes of a String (scalars > 0xFF are dropped to '?'). */
    static func l1(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 0x3F } }

    func mutateSource(_ r: inout Rng, _ src0: [UInt8]) -> [UInt8] {
        var b = src0
        for _ in 0..<(1 + r.int(4)) {
            switch r.int(8) {
            case 0: for _ in 0..<(1 + r.int(8)) where !b.isEmpty { b[r.int(b.count)] = UInt8(r.int(256)) }
            case 1: for _ in 0..<(1 + r.int(8)) where !b.isEmpty { let i = r.int(b.count); b[i] ^= UInt8(1 << r.int(8)) }
            case 2: if !b.isEmpty { b = Array(b[0..<r.int(b.count)]) }
            case 3, 4:
                var toks: [[UInt8]] = []
                var i = 0
                func isW(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
                func isS(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
                while i < b.count {
                    var j = i + 1
                    if isW(b[i]) { while j < b.count && isW(b[j]) { j += 1 } } else if isS(b[i]) { while j < b.count && isS(b[j]) { j += 1 } }
                    toks.append(Array(b[i..<j])); i = j
                }
                if !toks.isEmpty {
                    for _ in 0..<(1 + r.int(6)) {
                        let k = r.int(toks.count)
                        switch r.int(3) {
                        case 0: if toks.count > 1 { toks.remove(at: k) }
                        case 1: toks.insert(toks[r.int(toks.count)], at: k)
                        default: toks.swapAt(k, r.int(toks.count))
                        }
                    }
                }
                b = toks.flatMap { $0 }
            case 5, 6:
                let s = FuzzTests.l1(specials[r.int(specials.count)](&r))
                let i = b.isEmpty ? 0 : r.int(b.count + 1)
                b = Array(b[0..<i]) + s + Array(b[i...])
            default:
                let o = FuzzTests.corpusHC[r.int(FuzzTests.corpusHC.count)].1
                if !o.isEmpty { let a = r.int(o.count); let e = min(o.count, a + r.int(400)); let i = r.int(b.count + 1); b = Array(b[0..<i]) + Array(o[a..<e]) + Array(b[i...]) }
            }
        }
        return b
    }

    func compileOnly(_ k: Kernel, _ src: [UInt8], _ provider: SourceProvider?) -> String? {
        do {
            let s = k.prog.session(SourceFile.parse("C:/Home/Fuzz.HC", src), "C:/Home", provider, Ref(k.defines.value))
            var n = 0
            while try s.next() != nil && n < 100_000 { n += 1 }
            return nil
        } catch is CompileError { return nil } catch is VmFault { return nil } catch is VmUncaught { return nil } catch is VmKill { return nil }
        catch { return "compile:" + sigOf(error) }
    }

    func bootKernel() -> Kernel { let k = Kernel(TestEnv(), "fz"); k.virtualTime = true; try! k.boot(); return k }

    func testCompilerFuzz() {
        let n = FuzzTests.iters(400)
        let c = Collector(self, "compiler", "HC")
        let selfSrc = Box<[UInt8]>([])
        let provider = ClosureSourceProvider { p in
            let u = p.uppercased()
            return (u.hasSuffix("FUZZ.HC") || u.hasSuffix("FUZZ.HC.HC") || u.hasSuffix("/FUZZ")) ? selfSrc.v : nil
        }
        let fresh: ([UInt8]) -> String? = { b in selfSrc.v = b; return self.isolated(20_000) { self.compileOnly(self.bootKernel(), b, provider) } }
        var k: Kernel? = nil
        var used = 0
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("compiler", i)
            var r = Rng(seed)
            let base = FuzzTests.corpusHC[r.int(FuzzTests.corpusHC.count)].1
            let input = mutateSource(&r, base)
            if FuzzTests.knownCrash(input) { continue }
            selfSrc.v = input
            if k == nil || used > 40 { k = bootKernel(); used = 0 }
            used += 1
            let kk = k!
            c.begin(seed, input)
            let sig = isolated(20_000, onTimeout: { kk.vm.interrupt = true }) { self.compileOnly(kk, input, provider) }
            if sig != nil {
                k = nil
                if let conf = fresh(input) { c.found(seed, conf, input, conf.hasPrefix("HANG") ? nil : fresh, budgetMs: 25_000) }
                else { print("[fuzz:compiler] seed=\(seed) \(sig!) not reproducible on a fresh kernel") }
            }
            c.end()
        }
        c.finish(n)
    }

    func testCompileAndRunFuzz() {
        let n = FuzzTests.iters(30)
        let c = Collector(self, "compile-run", "HC")
        let exec: ([UInt8]) -> String? = { b in self.runProgramCase(b, maxSteps: 40) }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("compile-run", i)
            var r = Rng(seed)
            let base = FuzzTests.corpusHC[r.int(FuzzTests.corpusHC.count)].1
            let input = i % 5 == 0 ? base : mutateSource(&r, base)
            if FuzzTests.knownCrash(input) { continue }
            c.begin(seed, input)
            if let sig = exec(input) { c.found(seed, sig, input, sig.hasPrefix("HANG") ? nil : exec, budgetMs: 30_000) }
            c.end()
        }
        c.finish(n)
    }

    /** Depth ladder per construct; a crash leaves the in-flight file naming the probe and depth. */
    func testDeepNestingProbes() {
        let c = Collector(self, "nesting", "HC")
        let probes: [(String, (Int) -> String)] = [
            ("parens", { d in "I64 x=" + FuzzTests.rep("(", d) + "1" + FuzzTests.rep(")", d) + ";\n" }),
            ("braces", { d in FuzzTests.rep("{", d) + FuzzTests.rep("}", d) + "\n" }),
            ("unary-minus", { d in "I64 x=" + FuzzTests.rep("-", d) + "1;\n" }),
            ("if-chain", { d in FuzzTests.rep("if(1)", d) + ";\n" }),
            ("assign-chain", { d in "I64 x;" + FuzzTests.rep("x=", d) + "1;\n" }),
            ("binary-chain", { d in "I64 x=1" + FuzzTests.rep("+1", d) + ";\n" }),
            ("casts", { d in "I64 x=" + FuzzTests.rep("(I64)", d) + "1;\n" }),
            ("if-directive", { d in "#if " + FuzzTests.rep("(", d) + "1" + FuzzTests.rep(")", d) + "\n#endif\n" }),
            ("else-if", { d in "I64 x=0;" + FuzzTests.rep("if(x)x=1;else ", d) + "x=2;\n" }),
            ("nested-unions", { d in "class A{" + FuzzTests.rep("union{", d) + "I64 a;" + FuzzTests.rep("};", d) + "};\n" }),
            ("macro-doubling", { d in (0..<min(d, 40)).map { "#define M\($0) M\($0 + 1) M\($0 + 1)\n" }.joined() + "#define M\(min(d, 40)) 1\nI64 x=M0;\n" }),
            ("deref", { d in "I64 *p=0; I64 x=" + FuzzTests.rep("*", d) + "p;\n" }),
            ("index", { d in "I64 x=a" + FuzzTests.rep("[0]", d) + ";\n" }),
            ("call-args", { d in "I64 x=Abs(" + FuzzTests.rep("Abs(", d) + "1" + FuzzTests.rep(")", d + 1) + ";\n" }),
        ]
        let only = FuzzTests.env["TEMPLEOS_FUZZ_PROBE"]
        for (name, gen) in probes where only == nil || only == name {
            let depths = name == "macro-doubling" ? [10, 16, 20, 24] : [100, 1000, 3000, 10_000, 30_000, 100_000]
            for d in depths {
                let src = FuzzTests.l1(gen(d))
                c.begin(UInt64(d), src, "probe=\(name) depth=\(d)")
                let sig = runProgramCase(src, maxSteps: 20, wallMs: 30_000)
                print("[fuzz:nesting] \(name) depth=\(d) -> \(sig ?? "ok")")
                c.end()
                if let s = sig { c.found(UInt64(d), "\(name):\(s)", src, nil, detail: "probe=\(name) depth=\(d)"); break }
            }
        }
        c.finish(probes.count)
    }

    // MARK: 2. VM

    let interesting: [Int64] = [0, 1, -1, 2, 7, 8, 15, 16, 31, 63, 64, 255, 256, 4095, 4096, 65535, 0x10000, 0x7FFF, 0x8000,
        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1_0000_0000, 0x4000_0000, 0x4000_0001, 0x2000_0000, 0x2000_0001, 0x3FFF_FFFF, 0x1FFF_FFFF,
        0x1_0000_0010, 0x1_8000_0000, Int64.max, Int64.min, Int64.min + 1, -0x8000_0000, -2, -8, -16, -4096]

    func lit(_ v: Int64) -> String { v == Int64.min ? "(1<<63)" : v < 0 ? "(\(v))" : "0x" + String(v, radix: 16) }
    func randInt(_ r: inout Rng) -> String {
        switch r.int(5) {
        case 0, 1: return lit(r.pick(interesting))
        case 2: return lit(Int64(r.int(600)) - 50)
        case 3: return lit(r.i64())
        default: return lit(r.pick(interesting) &+ Int64(r.int(9) - 4))
        }
    }
    func randPtr(_ r: inout Rng) -> String {
        switch r.int(10) {
        case 0: return "b0"
        case 1: return "b1"
        case 2: return "b0+\(r.int(300))"
        case 3: return "b1+\(r.int(4200))"
        case 4: return "s0"
        case 5: return "NULL"
        case 6: return randInt(&r)
        case 7: return "Fs"
        case 8: return "b0+" + randInt(&r)
        default: return "(b1+4096-\(r.int(16)))"
        }
    }
    let fmtPieces = ["%d", "%s", "%c", "%X", "%p", "%f", "%e", "%g", "%n", "%z", "%Z", "%999999d",
        "%.999999f", "%,d", "%$", "%", "%t", "%P", "%q", "%Q", "%b", "%D", "%T", "%h25c", "%h-1c", "%07.3f", "%lld", "\\n", "$", "$$", "$FG,99$",
        "$RED$", "$$FG$$", "%10000000s", "%-10000000d", "%.-5f"]
    func randFmt(_ r: inout Rng) -> String {
        var s = "\""
        for _ in 0..<(r.int(5) + 1) { s += r.bool() ? r.pick(fmtPieces) : "ab" }
        return s + "\""
    }
    func randStmt(_ r: inout Rng) -> String {
        switch r.int(26) {
        case 0: return "MemCpy(\(randPtr(&r)),\(randPtr(&r)),\(randInt(&r)));"
        case 1: return "MemSet(\(randPtr(&r)),\(randInt(&r)),\(randInt(&r)));"
        case 2: return "MemSetU16(\(randPtr(&r)),\(randInt(&r)),\(randInt(&r)));"
        case 3: return "MemSetU32(\(randPtr(&r)),\(randInt(&r)),\(randInt(&r)));"
        case 4: return "MemSetI64(\(randPtr(&r)),\(randInt(&r)),\(randInt(&r)));"
        case 5: return "x=MemCmp(\(randPtr(&r)),\(randPtr(&r)),\(randInt(&r)));"
        case 6: return "x=b0[\(randInt(&r))];"
        case 7: return "b1[\(randInt(&r))]=\(randInt(&r));"
        case 8: return "q=b1(I64*); q[\(randInt(&r))]=\(randInt(&r));"
        case 9: return "x=*(\(randPtr(&r)))(I64*);"
        case 10: return "*(\(randPtr(&r)))(U16*)=\(randInt(&r));"
        case 11: return "d=\(randInt(&r))(F64); x=d; x=ToI64(d*\(randInt(&r)));"
        case 12: return "x=(\(randInt(&r)))(U8)+(\(randInt(&r)))(I32)+(\(randInt(&r)))(U16)/(\(randInt(&r))|1);"
        case 13: return "x=\(randInt(&r))%\(randInt(&r)); x=\(randInt(&r))/\(randInt(&r));"
        case 14: return "x=StrLen(\(randPtr(&r)));"
        case 15: return "StrCpy(\(randPtr(&r)),\(randPtr(&r)));"
        case 16: return "x=Str2I64(\(randPtr(&r)),\(randInt(&r)));"
        case 17: return "Print(\(randFmt(&r)),\(randInt(&r)),\(randPtr(&r)),\(randInt(&r)));"
        case 18: return "p=StrPrint(\(randPtr(&r)),\(randFmt(&r)),\(randInt(&r)),\(randPtr(&r)));"
        case 19: return "p=MStrPrint(\(randFmt(&r)),\(randInt(&r)),\(randPtr(&r)),\(randInt(&r)));"
        case 20: return "Free(\(randPtr(&r)));"
        case 21: return "x=MSize(\(randPtr(&r)));"
        case 22: return "p=MAlloc(\(randInt(&r)));"
        case 23: return "x=Bt(\(randPtr(&r)),\(randInt(&r))); Bts(\(randPtr(&r)),\(randInt(&r)));"
        case 24: return "x=BFieldExtU32(\(randPtr(&r)),\(randInt(&r)),\(randInt(&r)));"
        default: return "x=\(randInt(&r))<<\(randInt(&r)); x=\(randInt(&r))>>\(randInt(&r)); x=(\(randInt(&r)))(U64)>>\(randInt(&r));"
        }
    }
    func vmProgram(_ r: inout Rng, _ nStmts: Int, _ stmt: (inout Rng) -> String) -> String {
        var s = "U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0=\"hello world\",*p; I64 *q,x,i; F64 d;\n"
        s += "for(i=0;i<256;i++) b0[i]=(i*\(r.int(255) + 1)+\(r.int(256)))&255;\n"
        s += "for(i=0;i<4096;i++) b1[i]=(i*\(r.int(255) + 1))&127;\n"
        if r.bool() { s += "b0[\(r.int(256))]=0; b1[\(r.int(4096))]=0;\n" }
        for _ in 0..<nStmts { s += "try{" + stmt(&r) + "}catch{Fs->catch_except=TRUE;}\n" }
        return s + "\"FUZZDONE\\n\";\n"
    }

    func testVmRandomProgramsFuzz() {
        let n = FuzzTests.iters(30)
        let c = Collector(self, "vm", "HC")
        let exec: ([UInt8]) -> String? = { b in self.runProgramCase(b, maxSteps: 60, flagStkOver: true) }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("vm", i)
            var r = Rng(seed)
            let src = FuzzTests.l1(vmProgram(&r, 30) { self.randStmt(&$0) })
            c.begin(seed, src)
            if let sig = exec(src) { c.found(seed, sig, src, sig.hasPrefix("HANG") ? nil : exec, budgetMs: 40_000) }
            c.end()
        }
        c.finish(n)
    }

    lazy var natives: [(String, [String])] = {
        let txt = ["Prelude.HC", "GrLib.HC"].map { String(decoding: readFileBytes(SHARED.appendingPathComponent("runtime/\($0)"))!.map { $0 < 128 ? $0 : 0x3F }, as: UTF8.self) }.joined(separator: "\n")
        let skip: Set<String> = ["Exit", "Kill", "GetChar", "GetKey", "GetMsg", "GetStr", "GetS", "Busy", "Suspend", "Sleep", "SleepUntil",
            "Ed", "Man", "Help", "throw", "Break", "PutExceptMsg", "Raw", "Refresh", "Yield", "BreakLock", "BreakUnlock"]
        let re = try! NSRegularExpression(pattern: "(?m)^native\\s+(?:public\\s+)?[A-Za-z0-9_]+\\s*\\**\\s*([A-Za-z0-9_]+)\\(([^)]*(?:\\([^)]*\\)[^)]*)*)\\);")
        let ns = txt as NSString
        var res: [(String, [String])] = []
        for m in re.matches(in: txt, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)); let plist = ns.substring(with: m.range(at: 2))
            if skip.contains(name) || (FuzzTests.SKIP_KNOWN && name == "Spawn") { continue }
            var params: [String] = []; var depth = 0; var cur = ""
            for ch in plist {
                if ch == "(" { depth += 1 }; if ch == ")" { depth -= 1 }
                if ch == "," && depth == 0 { params.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
            }
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { params.append(cur.trimmingCharacters(in: .whitespaces)) }
            res.append((name, params))
        }
        return res
    }()

    func nativeCall(_ r: inout Rng) -> String {
        let (name, params) = r.pick(natives)
        // Raster natives loop over the requested area without interrupt checks: huge sizes are probed
        // separately (testGraphicsHugeArgProbe) so that one unkillable hang does not stall the whole run.
        let gfx = name.range(of: "^(Gr.*|Line|DC.*|Sprite.*|Text.*|Win.*|IsPixCovered0|Mat4x4MulXYZ)$", options: .regularExpression) != nil
        func randInt(_ r: inout Rng) -> String { gfx ? lit(Int64(r.int(1400) - 200)) : self.randInt(&r) }
        var args: [String] = []
        for p in params {
            if p == "..." { for _ in 0..<r.int(4) { args.append(r.bool() ? randInt(&r) : randPtr(&r)) }; continue }
            if p.contains("(*") { args.append(r.int(3) == 0 ? "&Cmp" : randInt(&r)) }
            else if p.contains("fmt") || p.contains("U8 *st") || p.contains("filename") || p.contains("mask") || p.contains("path") || p.contains("dname") {
                switch r.int(4) {
                case 0: args.append(randFmt(&r))
                case 1: args.append("\"" + r.pick(["~/F.TXT", "C:/Home", "::/../..", "C:/Demo/*", "*", "\\\\x", "", "~/../../etc/passwd", "D:/x", "C:/Home/" + FuzzTests.rep("a", 40)]) + "\"")
                default: args.append(randPtr(&r))
                }
            } else if p.contains("*") || p.contains("CTask") || p.contains("CDC") { args.append(p.contains("CDC") && r.bool() ? "gr.dc" : randPtr(&r)) }
            else if p.hasPrefix("F64") { args.append(r.pick(["1e308", "-1e308", "0.0", "-0.0", "1.5", "1e-320", "(0x7FF8000000000000)(F64)", randInt(&r) + "(F64)"])) }
            else { args.append(randInt(&r)) }
        }
        return "x=\(name)(\(args.joined(separator: ",")));"
    }

    func tmpDir(_ p: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(p)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func bundle() -> DirBundle { DirBundle(SHARED.appendingPathComponent("bundled-fs"), SHARED.appendingPathComponent("bundled-fs.index")) }

    func testNativeCallFuzz() {
        let n = FuzzTests.iters(40)
        let c = Collector(self, "natives", "HC")
        let dir = tmpDir("tosfuzz-nat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = LayeredFs(bundle(), dir)
        let exec: ([UInt8]) -> String? = { b in self.runProgramCase(b, maxSteps: 60, flagStkOver: true, fs: fs) }
        print("[fuzz:natives] \(natives.count) natives")
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("natives", i)
            var r = Rng(seed)
            let src = FuzzTests.l1("I64 Cmp(I64 a,I64 b){return a-b;}\n" + vmProgram(&r, 25) { rr in rr.int(4) == 0 ? self.randStmt(&rr) : self.nativeCall(&rr) })
            c.begin(seed, src)
            if let sig = exec(src) { c.found(seed, sig, src, sig.hasPrefix("HANG") ? nil : exec, budgetMs: 40_000) }
            c.end()
        }
        c.finish(n)
    }

    func testDrawItCallbackFuzz() {
        let n = FuzzTests.iters(25)
        let c = Collector(self, "draw-it", "HC")
        let exec: ([UInt8]) -> String? = { b in self.runProgramCase(b, maxSteps: 40, flagStkOver: true) }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("draw-it", i)
            var r = Rng(seed)
            var s = "I64 Cmp(I64 a,I64 b){return a-b;}\nU8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0=\"hello\",*p; I64 *q,x,i; F64 d;\nU0 DrawIt(CTask *task,CDC *dc){\n"
            for _ in 0..<6 { s += "  " + (r.bool() ? randStmt(&r) : nativeCall(&r)) + "\n" }
            s += "}\nFs->draw_it=&DrawIt; Sleep(200); \"FUZZDONE\\n\";\n"
            let src = FuzzTests.l1(s)
            c.begin(seed, src)
            if let sig = exec(src) { c.found(seed, sig, src, sig.hasPrefix("HANG") ? nil : exec, budgetMs: 30_000) }
            c.end()
        }
        c.finish(n)
    }


    func testGraphicsHugeArgProbe() {
        let c = Collector(self, "gfx-huge", "HC")
        let calls = [
            "GrRect(gr.dc,0,0,0x7FFFFFFF,0x7FFFFFFF);", "GrFillCircle(gr.dc,100,100,0,0x7FFFFFFF);", "GrFillSemiCircle(gr.dc,100,100,0,0x7FFFFFFF,1);",
            "GrLineFat3(gr.dc,0,0,0,100,100,0,0x7FFFFFFF);", "GrHLine(gr.dc,-0x7FFFFFFFFFFF,0x7FFFFFFFFFFF,10);", "GrVLine(gr.dc,10,-0x7FFFFFFFFFFF,0x7FFFFFFFFFFF);",
            "Line(NULL,0,0,0,0x7FFFFFFFFFFF,0x7FFFFFFFFFFF,0,&Plot);", "GrCircle(gr.dc,100,100,0x7FFFFFFF);", "GrEllipse(gr.dc,100,100,0x7FFFFFFF,0x7FFFFFFF);",
            "GrFloodFill(gr.dc,10,10);", "GrBorder(gr.dc,0,0,0x7FFFFFFF,0x7FFFFFFF);", "GrPrint(gr.dc,0,0,\"%*d\",0x7FFFFFF,1);"]
        let skip = Int(FuzzTests.env["TEMPLEOS_FUZZ_GFX_SKIP"] ?? "") ?? 0
        for (i, call) in calls.enumerated() where i >= skip {
            if leakedThreads >= 1 { print("[fuzz:gfx-huge] stopping: an unkillable hang is already running"); break }
            c.ran = i + 1
            let src = FuzzTests.l1("Bool Plot(U8 *a,I64 x,I64 y,I64 z){return TRUE;}\ntry{\(call)}catch{Fs->catch_except=TRUE;}\n\"FUZZDONE\\n\";\n")
            c.begin(UInt64(i), src)
            let sig = runProgramCase(src, maxSteps: 30, wallMs: 8_000)
            print("[fuzz:gfx-huge] \(call) -> \(sig ?? "ok")")
            c.end()
            if let s = sig { c.found(UInt64(i), s, src, nil, detail: call) }
        }
        c.finish(calls.count)
    }


    func testFormatHugeArgProbe() {
        let c = Collector(self, "fmt-huge", "HC")
        let calls = ["StrPrint(b,\"%h*c\",0x7FFFFFFFFFFF,'x');", "StrPrint(b,\"%h*c\",0x7FFFFFFFFFFF,0);", "Print(\"%*d\",0x7FFFFFFF,1);",
            "MStrPrint(\"%-*s\",0x7FFFFFFF,\"a\");", "MStrPrint(\"%.*f\",0x7FFFFFFF,1.5);", "Print(\"%h99999999999c\",'x');", "Print(\"%*d\",0x7FFFFFFFFFFFFFFF,1);"]
        let skip = Int(FuzzTests.env["TEMPLEOS_FUZZ_FMT_SKIP"] ?? "") ?? 0
        for (i, call) in calls.enumerated() where i >= skip {
            if leakedThreads >= 1 { print("[fuzz:fmt-huge] stopping: an unkillable hang is already running"); break }
            c.ran = i + 1
            let src = FuzzTests.l1("U8 b[64];\ntry{\(call)}catch{Fs->catch_except=TRUE;}\n\"FUZZDONE\\n\";\n")
            c.begin(UInt64(i), src)
            let sig = runProgramCase(src, maxSteps: 30, wallMs: 8_000)
            print("[fuzz:fmt-huge] \(call) -> \(sig ?? "ok")")
            c.end()
            if let s = sig { c.found(UInt64(i), s, src, nil, detail: call) }
        }
        c.finish(calls.count)
    }

    // MARK: 3. paths / LayeredFs

    let pathParts = ["..", ".", "", "C:", "c:", "D:", "::", "~", "/", "\\", "//", "\\\\", "etc", "passwd", "/etc/passwd",
        "/data/data/io.github.templeosmobile", "\u{0}", rep("a", 38), rep("b", 39), "Home", "Demo", "Games", "Maze.HC", "files", "deleted.txt",
        ".tmp-x", "..\\..", "C:/../..", "%2e%2e", "\u{2215}", "\u{FF0E}\u{FF0E}", " .. ", "...", "x/../../../../y", "\r\n", "\u{e9}", "\u{1F600}",
        "*", "?", "<", "|", "\"", ":", "con", "nul", "~/..", "::/..", "C:\\..\\..\\", "Doc", "HelpIndex.DD", "\u{7f}", "\t", " ", "e\u{301}", "../\u{301}", "\u{301}", "/\u{301}..", "..\u{301}"]

    func randPath(_ r: inout Rng) -> String {
        if r.int(20) == 0 { return (0..<(r.int(80) + 20)).map { _ in "d" + FuzzTests.rep("x", r.int(37)) }.joined(separator: "/") }
        var s = ""
        if r.bool() { s += r.pick(["C:/", "c:", "::/", "~/", "/", "", "D:/", "C:", "C:\\"]) }
        for _ in 0..<r.int(8) {
            if r.int(6) == 0 { s += String((0..<(r.int(5) + 1)).compactMap { _ in Unicode.Scalar(UInt32(r.int(0x3000))).map(Character.init) }) }
            else { s += r.pick(pathParts) }
            s += r.int(4) == 0 ? "\\" : "/"
        }
        return s
    }

    func esc(_ s: String) -> String { s.unicodeScalars.map { $0.value >= 32 && $0.value < 127 ? String($0) : String(format: "\\u%04x", $0.value) }.joined() }

    func testPathAndLayeredFsFuzz() {
        let n = FuzzTests.iters(3000)
        let c = Collector(self, "fs", "txt")
        let parent = tmpDir("tosfuzz-fs")
        defer { try? FileManager.default.removeItem(at: parent) }
        let overlay = parent.appendingPathComponent("overlay")
        try! FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        let secret = "SECRET-\(UUID().uuidString)"
        try! secret.write(to: parent.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try! secret.write(to: overlay.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let fs = LayeredFs(bundle(), overlay, quotaBytes: 4 << 20)
        let filesCanon = overlay.appendingPathComponent("files").resolvingSymlinksInPath().standardizedFileURL.path
        func violation() -> String? {
            let top = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
            if top != ["overlay", "secret.txt"] { return "escape:extra-file-in-parent:\(top)" }
            if (try? String(contentsOf: parent.appendingPathComponent("secret.txt"), encoding: .utf8)) != secret { return "escape:secret-modified" }
            let ov = ((try? FileManager.default.contentsOfDirectory(atPath: overlay.path)) ?? []).filter { !["files", "deleted.txt", "deleted.txt.tmp", "secret.txt"].contains($0) }
            if !ov.isEmpty { return "escape:extra-file-in-overlay-root:\(ov)" }
            return nil
        }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("fs", i)
            var r = Rng(seed)
            let p1 = randPath(&r), p2 = randPath(&r)
            let op = r.int(13)
            let desc = "op=\(op) p1=\(esc(p1)) p2=\(esc(p2))"
            c.begin(seed, Array(desc.utf8))
            var sig: String? = nil
            for cwd in ["C:/Home", "C:/", "C:/Demo/Games"] {
                guard let norm = Paths.normalize(cwd, p1) else { continue }
                if !norm.hasPrefix("C:/") { sig = "normalize:not-C-rooted" }
                else if norm.components(separatedBy: "/").contains(where: { $0 == ".." || $0 == "." }) || norm.dropFirst(3).contains("//") { sig = "normalize:dot-segment" }
                else if norm.unicodeScalars.contains(where: { $0.value < 32 }) { sig = "normalize:control-char" }
                else {
                    let host = URL(fileURLWithPath: filesCanon).appendingPathComponent(String(norm.dropFirst(3))).standardizedFileURL.resolvingSymlinksInPath().path
                    if !(host == filesCanon || host.hasPrefix(filesCanon + "/")) { sig = "normalize:host-escape" }
                }
            }
            if sig == nil {
                do {
                    switch op {
                    case 0: if let b = fs.readFile(p1), String(decoding: b, as: UTF8.self).contains(secret) { sig = "escape:read-secret" }
                    case 1: try fs.writeFile(p1, Array("data\(i)".utf8))
                    case 2: try fs.mkdir(p1)
                    case 3: try fs.delete(p1, recursive: r.bool())
                    case 4: try fs.move(p1, p2)
                    case 5: if fs.list(p1)?.contains(where: { $0.name == "secret.txt" }) == true { sig = "escape:listed-secret" }
                    case 6: _ = fs.stat(p1); _ = fs.exists(p1); _ = fs.isDir(p1)
                    case 7: try fs.restoreOriginal(p1)
                    case 8: _ = fs.isOriginal(p1); _ = fs.hasBundledOriginal(p1)
                    case 9:
                        if let d = Paths.normalize("C:/", p1) { try? fs.mkdir(Paths.parent(d)) }
                        try fs.writeFile(p1, [UInt8](repeating: 0, count: r.int(3000))); try fs.move(p1, p2)
                    case 10: _ = Paths.matches(p1, p2)
                    case 11: _ = Paths.parent(p1); _ = Paths.name(p1)
                    default: _ = fs.list("C:/")?.count; try fs.writeFile(p1, []); try fs.delete(p1, recursive: false)
                    }
                } catch is FsError {} catch { sig = "\(type(of: error)):" + errorMessage(error).prefix(60) }
            }
            let v = violation()
            if let s = v ?? sig { c.found(seed, String(s.prefix(40)), Array("\(desc)\n\(s)".utf8), nil, detail: desc); if v != nil { break } }
            c.end()
        }
        c.finish(n)
    }

    // MARK: 4. sprites

    lazy var spriteCorpus: [[UInt8]] = {
        var res: [[UInt8]] = []
        for d in ["bundled-fs/Demo/Games", "bundled-fs/Demo/Graphics", "bundled-fs/Apps", "bundled-fs/Demo"] {
            let root = SHARED.appendingPathComponent(d)
            guard let en = FileManager.default.enumerator(atPath: root.path) else { continue }
            var paths: [String] = []
            while let p = en.nextObject() as? String { if p.hasSuffix(".HC") { paths.append(p) } }
            for p in paths.sorted() {
                guard let b = readFileBytes(root.appendingPathComponent(p)) else { continue }
                let sf = SourceFile.parse(p, b)
                for k in sf.bins.keys.sorted() { let v = sf.bins[k]!; if v.count >= 1 && v.count <= 20000 { res.append(v) } }
            }
        }
        return res
    }()

    func mutateBlob(_ r: inout Rng, _ b0: [UInt8]) -> [UInt8] {
        var b = b0
        for _ in 0..<(1 + r.int(4)) {
            switch r.int(6) {
            case 0: for _ in 0..<(1 + r.int(6)) where !b.isEmpty { b[r.int(b.count)] = UInt8(r.int(256)) }
            case 1: if !b.isEmpty { b = Array(b[0..<r.int(b.count)]) }
            case 2: if b.count >= 5 { let o = r.int(b.count - 4); let v = UInt32(truncatingIfNeeded: r.pick(interesting)); for j in 0..<4 { b[o + j] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(j))) } }
            case 3: if !b.isEmpty { b[r.int(b.count)] = UInt8(r.int(32)) }
            case 4: b = (0..<r.int(64)).map { _ in UInt8(r.int(256)) }
            default: b += (0..<r.int(16)).map { _ in UInt8(r.int(256)) }
            }
        }
        return b
    }

    func nativeSprite(_ blob: [UInt8], _ k: Kernel) -> String? {
        do {
            let a = try k.mem.malloc(Int64(blob.count + 64))
            k.mem.fill(a, 0, blob.count + 64); k.mem.writeBytes(a, blob)
            do { _ = try k.callHolyC("SpriteSize", Int64(a)) } catch is VmFault {} catch is VmUncaught {}
            do { _ = try k.callHolyC("SpriteElemSize", Int64(a) - Int64(k.o.member("CSprite", "start"))) } catch is VmFault {} catch is VmUncaught {}
            try k.mem.free(Int64(a))
            return nil
        } catch is VmKill { return nil } catch { return sigOf(error) }
    }

    func testSpriteFuzz() {
        let n = FuzzTests.iters(60)
        let c = Collector(self, "sprite", "bin")
        print("[fuzz:sprite] corpus: \(spriteCorpus.count) sprite blobs")
        let freshNative: ([UInt8]) -> String? = { b in self.isolated(15_000) { self.nativeSprite(b, self.bootKernel()).map { "native:" + $0 } } }
        var k: Kernel? = nil
        let calls = ["Sprite3(dc,%d,%d,0,p);", "Sprite3B(dc,%d,%d,0,p);", "Sprite3ZB(dc,%d,%d,0,p,0.5);", "Sprite3(dc,%d,%d,0,p,TRUE);",
                     "SpriteExtents(p,&x0,&x1,&y0,&y1);", "q=DC2Sprite(dc);", "q=SpriteInterpolate(0.5,p,p);"]
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("sprite", i)
            var r = Rng(seed)
            let blob = (!spriteCorpus.isEmpty && r.int(8) != 0) ? mutateBlob(&r, r.pick(spriteCorpus)) : (0..<r.int(48)).map { _ in UInt8(r.int(256)) }
            if k == nil || i % 50 == 0 { k = bootKernel() }
            let kk = k!
            c.begin(seed, blob, "native SpriteSize/SpriteElemSize on the blob")
            if let sig = isolated(15_000, onTimeout: { kk.vm.interrupt = true }, { self.nativeSprite(blob, kk) }) {
                k = nil
                if let conf = freshNative(blob) { c.found(seed, conf, blob, freshNative, detail: "first: \(sig)") }
            }
            c.end()
            if i % 3 == 0 {
                var tmpl = "U8 *p=BLOB,*q; I64 x0,x1,y0,y1; CDC *dc=DCAlias;\n"
                for _ in 0..<4 { tmpl += "try{" + String(format: r.pick(calls), r.int(800) - 80, r.int(600) - 60) + "}catch{Fs->catch_except=TRUE;}\n" }
                tmpl += "DCDel(dc);\"FUZZDONE\\n\";\n"
                let probe = bootKernel()
                let addr = try! probe.mem.malloc(Int64(blob.count + 64))
                let t = tmpl
                let exec: ([UInt8]) -> String? = { b in
                    self.runProgramCase(FuzzTests.l1(t.replacingOccurrences(of: "BLOB", with: "0x" + String(addr, radix: 16))), maxSteps: 30) { k2 in
                        let a = try k2.mem.malloc(Int64(b.count + 64)); k2.mem.fill(a, 0, b.count + 64); k2.mem.writeBytes(a, b)
                    }.map { "sprite3:" + $0 }
                }
                c.begin(seed, blob, "Sprite3 template (blob malloc'd right after boot at 0x\(String(addr, radix: 16))):\n\(tmpl)")
                if let sig = exec(blob) { c.found(seed, sig, blob, exec, detail: "template:\n\(tmpl)") }
                c.end()
            }
        }
        c.finish(n)
    }

    // MARK: 5. DolDoc viewer

    func mutateDoc(_ r: inout Rng, _ b0: [UInt8]) -> [UInt8] {
        var b = mutateBlob(&r, b0)
        if r.int(3) == 0 {
            let ins = ["$", "$$", "$TX,\"", "$ID,99999$", "$ID,-99999$", "$TX+CX,\"" + FuzzTests.rep("x", r.int(500)) + "\"$", "$WW,0$", "$CL$",
                       "$FG,-5$", "$BG,999999999999$", "$LK,\"a\",A=\"FI:::/../../etc/passwd\"$", "$TR,\"\"$", "$SP,\"\",BI=1$", "$UL,1$", "$IV,1$",
                       FuzzTests.rep("\t", r.int(50)), "\u{0}", "$MA,\"x\",LM=\"Dir;\"$", "$TX,\"\\\"$", "$BT,\"\"$", "$ID,2147483647$"]
            let s = FuzzTests.l1(r.pick(ins)); let i = r.int(b.count + 1)
            b = Array(b[0..<i]) + s + Array(b[i...])
        }
        return b
    }

    func testDocViewerFuzz() {
        let n = FuzzTests.iters(400)
        let c = Collector(self, "docviewer", "DD")
        let dir = tmpDir("tosfuzz-ui")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(360, 640)
        let surf = Surface(1200, 900, sh.font)
        func exec(_ doc: [UInt8], _ seed: UInt64) -> String? {
            var r = Rng(seed &+ 1)
            do {
                try env.fs.writeFile("C:/Home/Fuzz.DD", doc)
                let app = DocViewerApp(sh, "C:/Home/Fuzz.DD")
                if r.bool() { app.restoreTop(r.pick([0, -1, 5, 100000, Int(Int32.max), Int(Int32.min), Int.max, Int.min, Int(r.i64())])) }
                for w in [8, 100, 360, 1200, 0] {
                    let rect = Rect(0, 0, w, 1 + r.int(899))
                    app.draw(surf, rect)
                    app.scroll(0, r.int(2000) - 1000, rect)
                    _ = app.key(0, Int64(r.pick([Keys.SC_CURSOR_DOWN, Keys.SC_PAGE_DOWN, Keys.SC_PAGE_UP, Keys.SC_CURSOR_UP])), true)
                    app.draw(surf, rect)
                }
                _ = app.saveState()
                return nil
            } catch is FsError { return nil } catch { return sigOf(error) }
        }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("docviewer", i)
            var r = Rng(seed)
            let doc = r.int(10) == 0 ? (0..<r.int(3000)).map { _ in UInt8(r.int(256)) } : mutateDoc(&r, r.pick(FuzzTests.corpusDD).1)
            c.begin(seed, doc)
            if let sig = exec(doc, seed) { c.found(seed, sig, doc, { exec($0, seed) }) }
            c.end()
        }
        c.finish(n)
    }

    // MARK: 6. JSON / catalog / settings / session

    func testJsonAndCatalogFuzz() {
        let n = FuzzTests.iters(3000)
        let c = Collector(self, "json", "json")
        let catalog = String(decoding: readFileBytes(SHARED.appendingPathComponent("program-manifests/catalog.json"))!, as: UTF8.self)
        func exec(_ s: String) -> String? { _ = try? Catalog.parse(s); _ = try? Json.parse(s); return nil }
        // Deep nesting runs on a thread with an 8 MiB stack (main-thread size; Catalog.load runs on the UI thread).
        let depth = Int(FuzzTests.env["TEMPLEOS_FUZZ_JSON_DEPTH"] ?? "") ?? 0
        if depth > 0 {
            let s = FuzzTests.rep("[", depth)
            c.begin(UInt64(depth), Array(s.utf8), "JSON nesting depth \(depth)")
            _ = isolated(60_000, stack: 8 << 20) { exec(s) }
            c.end()
        }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("json", i)
            var r = Rng(seed)
            let base = r.bool() ? String(catalog.prefix(3000)) + "]}" : catalog
            let m = String(decoding: mutateBlob(&r, Array(base.utf8)), as: UTF8.self)
            c.begin(seed, Array(m.utf8))
            if let sig = exec(m) { c.found(seed, sig, Array(m.utf8), nil) }
            _ = Settings.decode(String(m.prefix(200)))
            c.end()
        }
        c.finish(n)
    }

    func realSession(_ env: HeadlessEnv) -> String {
        let sh = Shell(env); sh.resize(800, 360)
        var gr = [UInt8](repeating: 0, count: 32 + 320 * 240); gr[16] = 64; gr[17] = 1; gr[20] = 64; gr[21] = 1; gr[24] = 240
        try! env.fs.writeFile("C:/Home/Pic.GR", gr)
        Launch.files(sh, "C:/Home/Examples"); Launch.doc(sh, "C:/Doc/HelpIndex.DD"); Launch.editor(sh, "C:/Home/Examples/Hello.HC")
        Launch.god(sh); Launch.about(sh); Launch.settings(sh); _ = sh.open(PaintApp(sh, "C:/Home/Pic.GR"))
        sh.saveSession()
        let s = env.session!
        for w in sh.windows { w.app.close() }
        return s + "win\tterminal\t0\t0\t300\t200\t0\t0\tdir=C:/Home\thist=Dir;\u{1}\"x\";\n"
    }

    func testSessionRestoreFuzz() {
        let n = FuzzTests.iters(200)
        let c = Collector(self, "session", "txt")
        let dir = tmpDir("tosfuzz-ui")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let base = realSession(env)
        let kinds = ["terminal", "editor", "files", "doc", "god", "paint", "settings", "about", "program", "bogus"]
        let keys = ["dir", "hist", "path", "draft", "row", "col", "top", "id"]
        let vals = ["-1", "2147483647", "-2147483648", "9223372036854775807", "-9223372036854775808", "99999999999999999999", "NaN", "",
                    "C:/../../etc/passwd", "/etc/passwd", "D:/x", "C:/Home/Pic.GR", "C:/Doc/HelpIndex.DD", "C:/Home", "\\t\\n\\e", FuzzTests.rep("x", 5000),
                    "\u{0}", "C:/Home/Examples/Hello.HC", "0", "1e9"]
        func exec(_ text: String) -> String? {
            env.session = text
            let sh = Shell(env)
            sh.resize(360, 640); sh.restoreSession(); _ = sh.tick()
            sh.resize(800, 360); _ = sh.tick()
            sh.saveSession()
            for w in sh.windows { w.app.close() }
            return nil
        }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("session", i)
            var r = Rng(seed)
            var text: String
            switch r.int(3) {
            case 0: text = String(decoding: mutateBlob(&r, Array(base.utf8)), as: UTF8.self)
            case 1:
                text = base.components(separatedBy: "\n").filter { !$0.hasPrefix("win\tterminal") || r.bool() }.map { l -> String in
                    if !l.hasPrefix("win") { return l }
                    return l.components(separatedBy: "\t").enumerated().map { (j, f) -> String in
                        if j >= 2 && r.int(3) == 0 { return j < 8 ? r.pick(vals) : r.pick(keys) + "=" + r.pick(vals) }
                        return f
                    }.joined(separator: "\t")
                }.joined(separator: "\n")
            default:
                text = "v1\nsettings\t" + (0..<r.int(6)).map { _ in r.pick(["d", "s", "o", "u", "c", ""]) + "=" + r.pick(vals) }.joined(separator: ";") + "\n"
                for _ in 0..<(r.int(4) + 1) {
                    var k = r.int(kinds.count); if kinds[k] == "program" || kinds[k] == "terminal" { k = (k + 1) % kinds.count }
                    text += "win\t" + kinds[k] + "\t" + (0..<6).map { _ in r.pick(vals) }.joined(separator: "\t")
                    for _ in 0..<r.int(4) { text += "\t" + r.pick(keys) + "=" + r.pick(vals) }
                    text += "\n"
                }
            }
            c.begin(seed, Array(text.utf8))
            if let sig = exec(text) { c.found(seed, sig, Array(text.utf8), nil) }
            c.end()
        }
        c.finish(n)
    }

    // MARK: 7. Paint .GR

    func testPaintGrFuzz() {
        let n = FuzzTests.iters(1000)
        let c = Collector(self, "paint", "GR")
        let dir = tmpDir("tosfuzz-ui")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = HeadlessEnv(dir)
        let sh = Shell(env); sh.resize(360, 640)
        let surf = Surface(400, 400, sh.font)
        let real = readFileBytes(SHARED.appendingPathComponent("bundled-fs/Demo/Games/Stadium/StadiumBG.GR"))!
        func exec(_ b: [UInt8]) -> String? {
            do { try env.fs.writeFile("C:/Home/Fuzz.GR", b) } catch { return nil }
            let p = PaintApp(sh, "C:/Home/Fuzz.GR"); p.draw(surf, Rect(0, 0, 400, 400)); return nil
        }
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("paint", i)
            var r = Rng(seed)
            func iv() -> Int32 { r.bool() ? Int32(truncatingIfNeeded: r.pick(interesting)) : Int32(r.int(700) - 100) }
            var b: [UInt8]
            switch r.int(3) {
            case 0: b = mutateBlob(&r, real)
            case 1:
                b = [UInt8](repeating: 0, count: max(32, r.int(4000)))
                for (o, v) in [(16, iv()), (20, iv()), (24, iv()), (28, Int32(r.int(4)))] { for j in 0..<4 { b[o + j] = UInt8(truncatingIfNeeded: v >> (8 * Int32(j))) } }
            default: b = (0..<r.int(80)).map { _ in UInt8(r.int(256)) }
            }
            c.begin(seed, b)
            if let sig = exec(b) { c.found(seed, sig, b, exec) }
            c.end()
        }
        c.finish(n)
    }

    // MARK: source container trailer

    func testSourceFileTrailerFuzz() {
        let n = FuzzTests.iters(3000)
        let c = Collector(self, "sourcefile", "HC")
        for i in 0..<n {
            if c.tooManyLeaks { print("[fuzz:\(c.target)] stopping after \(i) iterations: hung threads cannot be stopped"); break }
            c.ran = i + 1
            let seed = FuzzTests.caseSeed("sourcefile", i)
            var r = Rng(seed)
            var b = Array("\"hi\";".utf8) + [0]
            for _ in 0..<r.int(4) {
                func w32(_ v: Int64) { let u = UInt32(truncatingIfNeeded: v); for j in 0..<4 { b.append(UInt8(truncatingIfNeeded: u >> (8 * UInt32(j)))) } }
                w32(Int64(r.int(5))); w32(0); w32(r.bool() ? r.pick(interesting) : Int64(r.int(64))); w32(0)
                b += [UInt8](repeating: 0, count: r.int(64))
            }
            c.begin(seed, b)
            _ = SourceFile.parse("x", b); _ = textPart(b)
            c.end()
        }
        c.finish(n)
    }

    // MARK: replay

    /** Replays one saved input: TEMPLEOS_FUZZ_REPLAY=<file> TEMPLEOS_FUZZ_REPLAY_TARGET=run|compile|paint|doc|json|sprite3|native-sprite. */
    func testReplay() throws {
        guard let path = FuzzTests.env["TEMPLEOS_FUZZ_REPLAY"], let b = readFileBytes(URL(fileURLWithPath: path)) else { throw XCTSkip("no replay input") }
        let target = FuzzTests.env["TEMPLEOS_FUZZ_REPLAY_TARGET"] ?? "run"
        var res: String? = nil
        switch target {
        case "compile": res = isolated(60_000) { self.compileOnly(self.bootKernel(), b, nil) }
        case "native-sprite": res = isolated(60_000) { self.nativeSprite(b, self.bootKernel()) }
        case "paint":
            let dir = tmpDir("tosfuzz-ui"); let env = HeadlessEnv(dir); let sh = Shell(env); sh.resize(360, 640)
            try env.fs.writeFile("C:/Home/Fuzz.GR", b); PaintApp(sh, "C:/Home/Fuzz.GR").draw(Surface(400, 400, sh.font), Rect(0, 0, 400, 400))
        case "doc":
            let dir = tmpDir("tosfuzz-ui"); let env = HeadlessEnv(dir); let sh = Shell(env); sh.resize(360, 640)
            try env.fs.writeFile("C:/Home/Fuzz.DD", b); let a = DocViewerApp(sh, "C:/Home/Fuzz.DD")
            for w in [8, 100, 360, 1200, 0] { a.draw(Surface(1200, 900, sh.font), Rect(0, 0, w, 400)) }
        case "json": res = isolated(60_000, stack: 8 << 20) { _ = try? Json.parse(String(decoding: b, as: UTF8.self)); return nil }
        default: res = runProgramCase(b, maxSteps: 200, wallMs: 60_000, flagStkOver: true)
        }
        print("[fuzz:replay] \(target) \(path) -> \(res ?? "ok")")
        XCTAssertNil(res)
    }
}
