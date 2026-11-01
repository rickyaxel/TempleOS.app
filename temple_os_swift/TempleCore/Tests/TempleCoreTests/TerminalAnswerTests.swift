import XCTest
@testable import TempleCore

/**
 * The command line prints each command's answer like TempleOS's CmdLinePmt
 * (Compiler/CMisc.HC): "%8.6fs ans=0x%08X=%d", "ansf=%15.7g" for F64, and just
 * the time for U0 results and non-expression statements. Port of TerminalAnswerTest.kt.
 */
final class TerminalAnswerTests: XCTestCase {
    func testCompileErrorDoesNotScheduleAStaleReturn() throws {
        let k = Kernel(TestEnv(), "Terminal", shellMode: true)
        k.virtualTime = true
        try k.boot()
        XCTAssertTrue(try run(k, "LocalizationAuditMissingSymbol;").contains("undefined identifier"))
        // The UI scheduler keeps stepping even when the terminal is waiting for input.
        for _ in 0..<3 { _ = try k.step(50_000_000) }
        XCTAssertFalse(k.console.plainText().contains("return with no active call"), k.console.plainText())
        XCTAssertTrue(try run(k, "9+9;").contains("ans=0x00000012=18"))
    }

    private func run(_ k: Kernel, _ line: String) throws -> String {
        let before = k.console.plainText().count
        try k.execLine(line)
        let deadline = Date().addingTimeInterval(20)
        while k.busy && Date() < deadline { _ = try k.step(50_000_000) }
        XCTAssertFalse(k.busy, "command finished: \(line)")
        return String(k.console.plainText().dropFirst(before))
    }

    private func has(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    func testAnswers() throws {
        let k = Kernel(TestEnv(), "Terminal", shellMode: true)
        k.virtualTime = true
        try k.boot()
        let time = #"\d+\.\d{6}s"#
        XCTAssertTrue(has(try run(k, "2+3*4;"), time + " ans=0x0000000E=14"))
        // HolyC precedence: << binds tighter than * (Doc/HolyC.DD)
        XCTAssertTrue(has(try run(k, "I64 x=6*7;"), time))
        let shifted = try run(k, "x<<2;")
        XCTAssertTrue(shifted.contains("ans=0x000000A8=168"), shifted)
        let neg = try run(k, "-1;")
        XCTAssertTrue(neg.contains("ans=0xFFFFFFFFFFFFFFFF=-1"), neg)
        let f = try run(k, "1.5*3;")
        XCTAssertTrue(f.contains(" ansf=") && f.contains("4.5"), f)
        let v = try run(k, "U0 Nothing(){}\nNothing;")
        XCTAssertTrue(has(v, time) && !v.contains("ans"), v)
        // only the last statement's answer is shown
        let two = try run(k, "1;2;")
        XCTAssertTrue(two.contains("=2\n") && !two.contains("=1\n"), two)
        // no answer after an exception or a compile error
        let ex = try run(k, "I64 *p=0x7FFFFFFFFFF0; *p;")
        XCTAssertFalse(ex.contains("ans="), ex)
        XCTAssertFalse(try run(k, "Bogus();").contains("ans="))
        // output printed by the command comes before the answer
        let p = try run(k, "\"hi\\n\"; 7;")
        let hi = p.range(of: "hi"), ans = p.range(of: "ans=0x00000007=7")
        XCTAssertTrue(hi != nil && ans != nil && hi!.lowerBound < ans!.lowerBound, p)
    }
}
