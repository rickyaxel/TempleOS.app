import Foundation
import XCTest
@testable import TempleCore

/** Runs every shared/test-vectors/holyc/NAME.HC and compares console output (port of HolyCVectorTest.kt). */
final class HolyCVectorTests: XCTestCase {
    func testVectors() throws {
        let dir = SHARED.appendingPathComponent("test-vectors/holyc")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".HC") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var failures: [String] = []
        for name in files {
            let bytes = readFileBytes(dir.appendingPathComponent(name))!
            let text = latin1(bytes)
            var expected = ""
            if let r = text.range(of: "//EXPECT:") {
                expected = text[r.upperBound...].components(separatedBy: "\n").dropFirst()
                    .filter { $0.hasPrefix("//") }.map { String($0.dropFirst(2)) }.joined(separator: "\n")
            }
            var expErr: String?
            if let r = text.range(of: "//EXPECT-ERROR: ") {
                expErr = String(text[r.upperBound...].prefix { $0 != "\n" }).trimmed()
            }
            let k = try runHolyC(bytes, "C:/Home/\(name)")
            let out = k.console.plainText().trimEnd("\n")
            // a vector must run to completion (not merely print the expected text and hang)
            if !k.finished { failures.append("\(name): did not finish") }
            var got = out
            if let e = expErr {
                if !out.contains(e) { failures.append("\(name): expected error '\(e)' but output was:\n\(out)") }
                got = out.components(separatedBy: "\n").filter { !$0.contains(e) && !$0.trimmed().isEmpty }.joined(separator: "\n")
            }
            if got.trimmingCharacters(in: .whitespacesAndNewlines) != expected.trimmingCharacters(in: .whitespacesAndNewlines) {
                failures.append("\(name):\n--- expected\n\(expected)\n--- got\n\(got)")
            }
        }
        if !failures.isEmpty { XCTFail(failures.joined(separator: "\n\n")) }
    }
}
