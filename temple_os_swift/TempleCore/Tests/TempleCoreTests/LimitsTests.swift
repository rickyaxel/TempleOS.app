import Foundation
import XCTest
@testable import TempleCore

/**
 * Resource-limit / sandbox tests (independent verification; port of LimitsTest.kt).
 * Every test runs on a watchdog thread with a bounded wall clock, in real time,
 * against the APIs the UI uses (Kernel.step, Kernel.post(.breakKey),
 * KernelRunner.stop). Run also under `swift test --sanitize=address`.
 */
final class LimitsTests: XCTestCase {
    /**
     * Wall-clock slack factor for slow builds: set LIMITS_TIMEOUT_SCALE=20 in the
     * environment when running under --sanitize=address.
     * All deadlines and timing thresholds are multiplied by it; default 1.
     */
    private static let slack: Int64 = {
        if let v = ProcessInfo.processInfo.environment["LIMITS_TIMEOUT_SCALE"], let n = Int64(v), n > 0 { return n }
        return 1
    }()
    private var slack: Int64 { LimitsTests.slack }

    private final class LimitEnv: KernelEnv {
        let limit: Int
        init(_ limit: Int = 32 << 20) { self.limit = limit }
        func runtimeFile(_ name: String) -> [UInt8]? { readFileBytes(SHARED.appendingPathComponent("runtime/\(name)")) }
        var fs: VirtualFs? { nil }
        var memoryLimit: Int { limit }
        func entropy() -> Int64 { 1 }
        func popupRequested(_ kernel: Kernel, _ req: PopupRequest) { req.result = -1 }
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    /** Runs [block] on its own thread (64 MiB stack); fails if it does not finish within [ms]. */
    private func bounded(_ ms: Int, _ block: @escaping () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let done = DispatchSemaphore(value: 0)
        var err: Error?
        let th = Thread {
            do { try block() } catch { err = error }
            done.signal()
        }
        th.stackSize = 64 << 20
        th.start()
        if done.wait(timeout: .now() + .milliseconds(ms * Int(LimitsTests.slack))) == .timedOut {
            XCTFail("did not complete within \(ms) ms (host thread still busy)", file: file, line: line)
            return
        }
        if let e = err {
            if e is XCTSkip { return }
            XCTFail("\(e)", file: file, line: line)
        }
    }

    private func check(_ cond: Bool, _ msg: @autoclosure () -> String) throws {
        if !cond { throw Failure(description: msg()) }
    }

    private func boot(_ limit: Int = 32 << 20, shell: Bool = false) throws -> Kernel {
        let k = Kernel(LimitEnv(limit), shell ? "Terminal" : "Limits", shellMode: shell)
        try k.boot()
        return k
    }

    private func start(_ src: String, _ limit: Int = 32 << 20) throws -> Kernel {
        let k = try boot(limit)
        try k.runProgram("C:/Home/Limits.HC", latin1(src))
        return k
    }

    private func runToEnd(_ k: Kernel, _ wallMs: Int64) throws -> Bool {
        let deadline = monoNanos() + wallMs * 1_000_000 * slack
        while monoNanos() < deadline {
            if try k.step(20_000_000) < 0 { return true }
        }
        return k.finished
    }

    private func stepUntil(_ k: Kernel, _ wallMs: Int64, _ cond: () -> Bool) throws -> Bool {
        let deadline = monoNanos() + wallMs * 1_000_000 * slack
        while monoNanos() < deadline {
            if cond() { return true }
            _ = try k.step(5_000_000)
        }
        return cond()
    }

    private func noHostError(_ out: String) throws {
        try check(!out.lowercased().contains("internal error"), "host-level error leaked into the program:\n\(out)")
        try check(!out.contains("host stack overflow"), "host stack overflow:\n\(out)")
    }

    private func worstStepNs(_ k: Kernel, _ calls: Int, _ budget: Int64) throws -> Int64 {
        var worst: Int64 = 0
        for _ in 0..<calls {
            let t0 = monoNanos()
            try check(try k.step(budget) >= 0, "busy program must not finish")
            worst = max(worst, monoNanos() - t0)
        }
        return worst
    }

    // ------------------------------------------------------------ 1. infinite loops

    func testInfiniteLoopHonoursStepBudgetAndBreakStopsIt() {
        bounded(10_000) { [self] in
            let k = try start("\"spin\\n\";\nwhile (TRUE) {}\n\"never\\n\";\n")
            _ = try k.step(5_000_000)
            let worst = try worstStepNs(k, 40, 5_000_000)
            try check(!k.finished, "finished early")
            try check(worst < 100_000_000 * slack, "step(5 ms) took \(worst / 1_000_000) ms")
            k.post(.breakKey)
            try check(try runToEnd(k, 2000), "Break must end the program")
            let out = k.console.plainText()
            try check(out.contains("spin") && !out.contains("never") && out.contains("Break"), out)
            try check(k.tasks.isEmpty, "tasks left")
            try check(try k.step(5_000_000) == -1, "finished kernel must report -1")
        }
    }

    /** Posts Break from another thread after [delayMs] (the kernel thread is stuck inside the callback). */
    private func breakLater(_ k: Kernel, _ delayMs: Int) {
        Thread { Thread.sleep(forTimeInterval: Double(delayMs) / 1000); k.post(.breakKey) }.start()
    }

    func testBreakStopsInfiniteLoopInsideNativeCallback() {
        bounded(10_000) { [self] in
            let k = try start("I64 Cmp(I64 a,I64 b) {while (TRUE) {} return a-b;}\nI64 arr[2]={2,1};\n\"sorting\\n\";\nQSortI64(arr,2,&Cmp);\n\"never\\n\";\n")
            breakLater(k, 100)
            let t0 = monoNanos()
            try check(try runToEnd(k, 5000), "Break must end the program")
            let ms = (monoNanos() - t0) / 1_000_000
            let out = k.console.plainText()
            try noHostError(out)
            try check(out.contains("sorting") && !out.contains("never") && out.contains("Break"), out)
            try check(!out.contains("too long"), "ended by the instruction guard, not Break:\n\(out)")
            try check(ms < 1000 * slack, "Break inside a callback took \(ms) ms")
        }
    }

    func testBreakInsideNativeCallbackReachesTheCallbacksHandler() {
        bounded(10_000) { [self] in
            let k = try start("I64 Cmp(I64 a,I64 b) {\n  try { while (TRUE) {} } catch { \"caught\\n\"; Fs->catch_except=TRUE; }\n  return a-b;\n}\n" +
                "I64 arr[2]={2,1};\nQSortI64(arr,2,&Cmp);\n\"sorted %d %d\\n\",arr[0],arr[1];\n")
            breakLater(k, 100)
            try check(try runToEnd(k, 5000), "program must finish")
            let out = k.console.plainText()
            try noHostError(out)
            try check(out.contains("caught") && out.contains("sorted 1 2"), out)
        }
    }

    /** V-17: the comparator never returns; the spawned ticker and the frame clock must keep going. */
    func testOtherTasksAndFramesRunWhileANativeCallbackSpins() {
        bounded(10_000) { [self] in
            let k = try start("I64 ticks=0;\nU0 Ticker(U8 *) { while (TRUE) { ticks++; if (ticks%10==0) \"tick %d\\n\",ticks; Sleep(1); } }\n" +
                "Spawn(&Ticker);\nI64 Cmp(I64 a,I64 b) {while (TRUE) {} return a-b;}\nI64 arr[2]={2,1};\n\"sorting\\n\";\n" +
                "QSortI64(arr,2,&Cmp);\n\"never\\n\";\n")
            breakLater(k, 700)
            let f0 = k.frameCount
            try check(try runToEnd(k, 5000), "Break must end the program")
            let out = k.console.plainText()
            try noHostError(out)
            try check(out.contains("sorting") && !out.contains("never") && out.contains("Break"), out)
            let re = try NSRegularExpression(pattern: "tick (\\d+)")
            let ticks = re.matches(in: out, range: NSRange(out.startIndex..., in: out))
                .compactMap { Range($0.range(at: 1), in: out).flatMap { Int(out[$0]) } }.max() ?? 0
            try check(ticks >= 20, "the spawned task ran only \(ticks) ticks while the comparator spun:\n\(out)")
            try check(k.frameCount - f0 >= 8, "only \(k.frameCount - f0) frames in ~0.7 s")
        }
    }

    func testUiRunnerHardStopKillsProgramThatSwallowsBreak() {
        bounded(10_000) { [self] in
            let k = Kernel(LimitEnv(), "Swallow")
            let runner = KernelRunner(k)
            runner.start { try $0.runProgram("C:/Home/Swallow.HC", latin1(
                "I64 breaks=0;\nwhile (TRUE) {\n  try { while (TRUE) {} } catch { breaks++; Fs->catch_except=TRUE; }\n}\n")) }
            let bootDeadline = monoNanos() + 5_000_000_000 * slack
            while !runner.booted && monoNanos() < bootDeadline { Thread.sleep(forTimeInterval: 0.01) }
            try check(runner.booted, "boot")
            Thread.sleep(forTimeInterval: 0.3)
            runner.stop(hard: false)
            Thread.sleep(forTimeInterval: 0.5 * Double(slack))
            if k.finished { throw XCTSkip("runtime made Break uncatchable; hard-stop path not exercised") }
            runner.stop(hard: true)
            try check(!runner.alive, "runner still alive")
            let n1 = k.vm.instructionsExecuted
            Thread.sleep(forTimeInterval: 0.3)
            let n2 = k.vm.instructionsExecuted
            try check(n1 == n2, "VM must stop executing after hard stop (\(n1) -> \(n2))")
        }
    }

    func testShellKernelRunsAnotherCommandAfterBreak() {
        bounded(10_000) { [self] in
            let k = try boot(shell: true)
            try check(try k.execLine("while (TRUE) {}"), "execLine")
            for _ in 0..<10 { _ = try k.step(5_000_000) }
            try check(k.busy, "command must be running")
            try check(!(try k.execLine("\"x\\n\";")), "a running command must block a new one")
            k.post(.breakKey)
            try check(try stepUntil(k, 3000) { !k.busy }, "Break must end the command")
            try check(try k.execLine("\"after %d\\n\",6*7;"), "execLine after Break")
            try check(try stepUntil(k, 3000) { !k.busy }, "second command must end")
            let out = k.console.plainText()
            try check(out.contains("after 42"), out)
            try noHostError(out)
        }
    }

    // ------------------------------------------------------------ 2. recursion

    func testUnboundedRecursionIsStkOver() {
        bounded(10_000) { [self] in
            let k = try start("""
                I64 R(I64 n) {return R(n+1)+1;}
                try { R(0); } catch { "caught %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                U0 Big() {U8 buf[100000]; buf[0]=1; Big;}
                try { Big; } catch { "caught2 %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                "alive\\n";
                R(0);
                "never\\n";
                """)
            try check(try runToEnd(k, 8000), "did not end")
            let out = k.console.plainText()
            try noHostError(out)
            try check(out.contains("caught StkOver") && out.contains("caught2 StkOver") && out.contains("alive") && !out.contains("never"), out)
            try check(k.exitMessage?.contains("StkOver") == true, "exit: \(k.exitMessage ?? "-")")
        }
    }

    func testRecursionThroughNativeCallbackIsStkOver() {
        bounded(10_000) { [self] in
            let k = try start("""
                I64 depth=0;
                I64 Cmp(I64 a,I64 b) {I64 x[2]; x[0]=2; x[1]=1; depth++; QSortI64(x,2,&Cmp); return a-b;}
                I64 arr[2]={2,1};
                try { QSortI64(arr,2,&Cmp); } catch { "caught %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                "alive %d\\n",depth>100;
                """)
            try check(try runToEnd(k, 8000), "did not end")
            let out = k.console.plainText()
            try noHostError(out)
            try check(out.contains("StkOver"), out)
        }
    }

    // ------------------------------------------------------------ 3. memory limit

    func testAllocationBeyondLimitIsOutMemAndProgramContinues() {
        bounded(10_000) { [self] in
            let limit = 16 << 20
            let k = try start("""
                I64 n=0;
                try { while (TRUE) { MAlloc(1<<20); n++; } } catch { "loop %c %d\\n",Fs->except_ch,n; Fs->catch_except=TRUE; }
                try { MAlloc(1<<40); "huge-ok\\n"; } catch { "huge %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                try { CAlloc(1<<40); "chuge-ok\\n"; } catch { "chuge %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                try { MAlloc(-1); "neg-ok\\n"; } catch { "neg %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                try { StrNew(NULL); I64 *big=MAlloc(I64_MAX); "max-ok\\n"; } catch { "max %c\\n",Fs->except_ch; Fs->catch_except=TRUE; }
                U8 *p=MAlloc(100);
                p[99]=7;
                "still %d\\n",p[99];
                """, limit)
            try check(try runToEnd(k, 8000), "did not end")
            let out = k.console.plainText()
            try noHostError(out)
            let re = try NSRegularExpression(pattern: "loop OutMem (\\d+)")
            guard let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let r = Range(m.range(at: 1), in: out), let n = Int(out[r]) else { throw Failure(description: "MAlloc loop must end with OutMem:\n\(out)") }
            try check((1...16).contains(n), out)
            for s in ["huge OutMem", "chuge OutMem", "neg OutMem", "max OutMem", "still 7"] { try check(out.contains(s), "missing '\(s)':\n\(out)") }
            try check(k.mem.size <= limit, "arena (\(k.mem.size)) must stay within the limit (\(limit))")
        }
    }

    // ------------------------------------------------------------ 4. output volume

    func testMillionsOfLinesKeepScrollbackBounded() {
        bounded(10_000) { [self] in
            let k = try start("I64 i;\nfor (i=0;i<1000000;i++) \"line %d\\n\",i;\n\"last\\n\";\n")
            try check(try runToEnd(k, 9000), "printing 1M lines must finish in time")
            let lines = k.console.lineCount()
            try check(lines <= 2001, "scrollback has \(lines) lines")
            let out = k.console.plainText()
            try check(out.hasSuffix("last\n") || out.hasSuffix("last"), "tail")
            try check(out.contains("line 999999"), "last line")
            try check(out.count < 100_000, "console holds \(out.count) chars")
        }
    }

    func testOneHugeLineIsBounded() {
        bounded(10_000) { [self] in
            let k = try start("U8 *s=MAlloc(1001);\nMemSet(s,'x',1000);\ns[1000]=0;\nI64 i;\nfor (i=0;i<8000;i++) \"%s\",s;\n\"END\";\n")
            try check(try runToEnd(k, 9000), "did not end")
            let len = k.console.plainText().utf8.count
            // bound: long lines wrap at Console.MAX_COLS, scrollback keeps 2000 lines
            let bound = Console.MAX_COLS * 2000 + 2000
            try check(len <= bound, "console holds \(len) chars after an 8M-char line (bound \(bound))")
        }
    }

    // ------------------------------------------------------------ 5. invalid memory

    /** Runs [snippet] in try/catch in a fresh program; returns a problem description or nil. */
    private func faultCase(_ snippet: String, _ expect: String?, pre: String = "") -> String? {
        let src = "\(pre)\n\"start\\n\";\ntry {\n\(snippet)\n\"noexc\\n\";\n} catch {\n\"exc %c\\n\",Fs->except_ch;\nFs->catch_except=TRUE;\n}\n\"done\\n\";\n"
        let k: Kernel
        do { k = try start(src) } catch { return "\(snippet): host error at load: \(error)" }
        let ended: Bool
        do { ended = try runToEnd(k, 5000) } catch { return "\(snippet): host error escaped Kernel.step: \(error)" }
        let out = k.console.plainText().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | ")
        if !ended { return "\(snippet): did not end" }
        if out.lowercased().contains("internal error") || out.contains("host stack overflow") { return "\(snippet): host error: \(out)" }
        if !out.contains("done") { return "\(snippet): program died: \(out)" }
        if let e = expect, !out.contains("exc \(e)") { return "\(snippet): expected \(e), got: \(out)" }
        return nil
    }

    private func checkCases(_ r: [String?]) throws {
        let bad = r.compactMap { $0 }
        if !bad.isEmpty { throw Failure(description: bad.joined(separator: "\n")) }
    }

    func testNullAndWildPointers() {
        bounded(10_000) { [self] in
            try checkCases([
                faultCase("*(0x7FFFFFFFFFFF)(I64*)=1;", "BadMem"),
                faultCase("I64 v=*(0x7FFFFFFFFFF0)(I64*); \"%d\\n\",v;", "BadMem"),
                faultCase("*(-8)(I64*)=1;", "BadMem"),
                faultCase("I64 *q=MAlloc(16); q[-1000000]=1;", "BadMem"),
                faultCase("I64 *q=MAlloc(16); q[1<<40]=1;", "BadMem"),
                faultCase("\"%s\\n\",0x7FFFFFFF0000;", "BadMem"),
                faultCase("U0 (*fp)()=0x123456; fp();", nil),
            ])
        }
    }

    func testBadFrees() {
        bounded(10_000) { [self] in
            try checkCases([
                faultCase("Free(0x12345);", "BadFree"),
                faultCase("FreeLocal;", "BadFree", pre: "U0 FreeLocal() {I64 loc; Free(&loc);}"),
                faultCase("U8 *d=MAlloc(8); Free(d); Free(d);", "BadFree"),
                faultCase("U8 *d=MAlloc(64); Free(d+8);", "BadFree"),
            ])
        }
    }

    func testHugeAndNegativeMemOps() {
        bounded(10_000) { [self] in
            try checkCases([
                faultCase("U8 b[16]; MemCpy(b,b,1<<40);", "BadMem"),
                faultCase("U8 *m=MAlloc(16); MemSet(m,0,1<<40);", "BadMem"),
                faultCase("U8 *m=MAlloc(16); MemSet(m,0,0x7FFFFFFF);", "BadMem"),
                faultCase("U8 b[16]; MemCpy(b,0x7FFFFFFFFFF0,4);", "BadMem"),
                faultCase("U8 b[16]; MemCpy(b,\"abc\",-1);", nil),
                faultCase("U8 *m=MAlloc(16); MemSet(m,0,-5);", nil),
                faultCase("I64 *m=MAlloc(16); MemSetI64(m,0,1<<61);", "BadMem"),
                faultCase("I64 *m=MAlloc(16); MemSetI64(m,0,1<<29);", "BadMem"),
                faultCase("U32 *m=MAlloc(16); MemSetU32(m,0,1<<30);", "BadMem"),
                faultCase("U8 b[16]; MemCpy(b,\"abcdefghijklmnopqrstuvwxyz\",(1<<32)+20);", "BadMem"),
            ])
        }
    }

    func testOverflowsInsideOwnHeapAndStack() {
        // Writes stay inside the program's own arena; they may corrupt its own heap
        // (as in TempleOS) but must surface as HolyC exceptions, never host errors.
        bounded(10_000) { [self] in
            try checkCases([
                faultCase("U8 *s=MAlloc(4); StrCpy(s,\"0123456789012345678901234567890123456789\"); Free(s);", nil),
                faultCase("U8 *a=MAlloc(16),*b=MAlloc(16); MemSet(a,0xFF,64); U8 *c=MAlloc(16); Free(b); Free(a); Free(c);", nil),
                faultCase("U8 *big=MAlloc(1<<20); MemSet(big,'y',(1<<20)-1); big[(1<<20)-1]=0; F(big);", nil,
                          pre: "U0 F(U8 *src) {U8 b[4]; StrCpy(b,src);}"),
                faultCase("I64 *q=MAlloc(16); q[-1]=0x7FFFFFFFFFFFFFFF; q[-2]=-1; Free(q); MAlloc(16);", nil),
            ])
        }
    }

    func testWildWritesDoNotTouchAnotherLoadedProgram() {
        bounded(10_000) { [self] in
            let b = try start("""
                U8 *buf=MAlloc(4096);
                MemSet(buf,0x5A,4096);
                "B addr %d\\n",buf;
                I64 spin,i,bad=0;
                for (spin=0;spin<2000000;spin++) {}
                for (i=0;i<4096;i++) if (buf[i]!=0x5A) bad++;
                "B bad %d\\n",bad;
                """)
            try check(try stepUntil(b, 3000) { b.console.plainText().contains("B addr") }, "B setup")
            let outB0 = b.console.plainText()
            let re = try NSRegularExpression(pattern: "B addr (\\d+)")
            let m = re.firstMatch(in: outB0, range: NSRange(outB0.startIndex..., in: outB0))!
            let addr = String(outB0[Range(m.range(at: 1), in: outB0)!])
            let a = try start("""
                try { MemSet(\(addr),0,4096); } catch { Fs->catch_except=TRUE; }
                try { Free(\(addr)); } catch { Fs->catch_except=TRUE; }
                I64 a;
                for (a=0x10000;;a+=8) *a(I64*)=-1;
                """)
            let deadline = monoNanos() + 8_000_000_000 * slack
            while (!a.finished || !b.finished) && monoNanos() < deadline {
                if !a.finished { _ = try a.step(2_000_000) }
                if !b.finished { _ = try b.step(2_000_000) }
            }
            try check(a.finished && b.finished, "did not end")
            let outA = a.console.plainText(), outB = b.console.plainText()
            try noHostError(outA); try noHostError(outB)
            try check(outA.contains("BadMem") || outA.contains("BadFree"), "A must die on its own arena boundary:\n\(outA)")
            try check(outB.contains("B bad 0"), "B's memory must be untouched:\n\(outB)")
        }
    }

    func testCorruptedTaskCallbackPointerStaysInsideTheProgram() {
        bounded(10_000) { [self] in
            let k = try start("Fs->draw_it=0x7979797979797979;\nI64 i;\nfor (i=0;i<20;i++) Sleep(20);\n\"end\\n\";\n")
            do { _ = try runToEnd(k, 5000) } catch { throw Failure(description: "host error escaped Kernel.step: \(error)") }
            try noHostError(k.console.plainText())
        }
    }

    func testHardStopInterruptsOneHugeGraphicsPrimitive() {
        bounded(10_000) { [self] in
            let k = try start("CDC *dc=DCNew(4096,4096);\ndc->color=RED;\n\"go\\n\";\nwhile (TRUE) GrRect(dc,0,0,4096,4096);\n")
            _ = try stepUntil(k, 3000) { k.console.plainText().contains("go") }
            let stopper = Thread { Thread.sleep(forTimeInterval: 0.3); k.stopRequested = true; k.vm.interrupt = true }
            stopper.start()
            let t0 = monoNanos()
            var r: Int64 = 0
            while r >= 0 && monoNanos() - t0 < 4_000_000_000 * slack { r = try k.step(5_000_000) }
            let ms = (monoNanos() - t0) / 1_000_000
            try check(r == -1, "hard stop must end the program (took \(ms) ms)")
            try check(ms < 1500 * slack, "hard stop took \(ms) ms")
            try check(k.finished, "finished")
        }
    }

    // ------------------------------------------------------------ 6. graphics loop

    /**
     * Frame fairness (docs/performance/TEMPLEOS_RUNTIME_OPTIMIZATIONS.md section 2): a draw_it slower than the
     * frame interval while every task sleeps must not keep step() composing frames forever. It once did, so the
     * kernel thread never got back to input, and Stop never reached the program.
     */
    func testSlowFramesWithSleepingTasksStillReturnFromStep() {
        bounded(10_000) { [self] in
            let k = try start("""
                I64 n=0;
                U0 DrawIt(CTask *,CDC *dc) { F64 t=tS; while (tS-t<0.05) n++; dc->color=n&15; GrRect(dc,0,0,64,64); } //50 ms frames
                Fs->draw_it=&DrawIt;
                Sleep(100000);
                """)
            _ = try k.step(20_000_000)
            // drive it as KernelRunner does, over 0.7 s of real time
            var worst: Int64 = 0
            let end = monoNanos() + 700_000_000
            while monoNanos() < end {
                let t0 = monoNanos()
                let w = try k.step(5_000_000)
                worst = max(worst, monoNanos() - t0)
                if w > 0 { usleep(useconds_t(max(1000, min(w / 1000, 10_000)))) }
            }
            print("LimitsTests: worst step(5 ms) with slow frames and sleeping tasks: \(worst / 1_000_000) ms, frames=\(k.frameCount)")
            try check(worst < 1_000_000_000 * slack, "step(5 ms) took \(worst / 1_000_000) ms")
            try check(k.frameCount >= 3, "frames still composed")
            k.post(.breakKey)
            try check(try runToEnd(k, 3000), "Break stops it")
        }
    }

    func testTightGraphicsLoopHonoursBudgetAndStops() {
        bounded(10_000) { [self] in
            let k = try start("""
                CDC *dc=DCAlias;
                CDC *off=DCNew(640,480);
                I64 i=0;
                while (TRUE) {
                  dc->color=i&15; off->color=(i+1)&15;
                  GrRect(dc,0,0,320,240); GrLine(dc,0,0,639,479);
                  GrRect(off,10,10,600,400); GrLine(off,639,0,0,479);
                  i++;
                }
                """)
            _ = try k.step(20_000_000)
            let worst = try worstStepNs(k, 5, 5_000_000)
            print("LimitsTests: worst step(5 ms) in a 640x480 graphics loop: \(worst / 1_000_000) ms")
            try check(worst < 1_000_000_000 * slack, "step(5 ms) took \(worst / 1_000_000) ms in a graphics loop")
            k.post(.breakKey)
            try check(try runToEnd(k, 3000), "Break must stop a graphics loop")
            try noHostError(k.console.plainText())
        }
    }

    func testTightGraphicsLoopStopsViaUiRunner() {
        bounded(10_000) { [self] in
            let k = Kernel(LimitEnv(), "Gfx")
            let runner = KernelRunner(k)
            runner.start { try $0.runProgram("C:/Home/Gfx.HC", latin1(
                "CDC *dc=DCAlias;\nI64 i=0;\nwhile (TRUE) {\n  dc->color=i&15;\n  GrRect(dc,0,0,640,480);\n  GrLine(dc,0,0,639,479);\n  i++;\n}\n")) }
            let bootDeadline = monoNanos() + 5_000_000_000 * slack
            while !runner.booted && monoNanos() < bootDeadline { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.3 * Double(slack))
            runner.stop(hard: false)
            let deadline = monoNanos() + 2_000_000_000 * slack
            while !k.finished && monoNanos() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            try check(k.finished, "Break (soft stop) must end the graphics loop")
            runner.stop(hard: true)
            try check(!runner.alive, "runner still alive")
        }
    }
}
