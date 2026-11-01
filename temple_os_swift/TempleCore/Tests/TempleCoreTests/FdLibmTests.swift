import Foundation
import XCTest
@testable import TempleCore

/// Checks FdLibm (the Swift fdlibm port) bit for bit against java.lang.StrictMath
/// results recorded by fdlibm-vectors/GenVectors.java in fdlibm-vectors/vectors.txt.
/// NaN results only have to be NaN on both sides (payloads are not compared).
final class FdLibmTests: XCTestCase {

    private static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("fdlibm-vectors")
        .appendingPathComponent("vectors.txt")

    private static let unary: [String: (Double) -> Double] = [
        "sin": FdLibm.sin, "cos": FdLibm.cos, "tan": FdLibm.tan,
        "asin": FdLibm.asin, "acos": FdLibm.acos, "atan": FdLibm.atan,
        "sinh": FdLibm.sinh, "cosh": FdLibm.cosh, "tanh": FdLibm.tanh,
        "exp": FdLibm.exp, "expm1": FdLibm.expm1,
        "log": FdLibm.log, "log10": FdLibm.log10, "log1p": FdLibm.log1p,
    ]

    private static let binary: [String: (Double, Double) -> Double] = [
        "atan2": FdLibm.atan2, "pow": FdLibm.pow,
    ]

    private static func hex(_ d: Double) -> String {
        let s = String(d.bitPattern, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }

    private static func parse(_ s: Substring) -> Double? {
        UInt64(s, radix: 16).map { Double(bitPattern: $0) }
    }

    func testMatchesStrictMathBitForBit() throws {
        let text = try String(contentsOf: Self.vectorsURL, encoding: .utf8)
        var checked: [String: Int] = [:]
        var failed: [String: Int] = [:]
        var report: [String] = []
        let maxReported = 40

        for (lineNo, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(separator: " ")
            let name = String(f[0])
            let inputs: [Double]
            let expected: Double
            let actual: Double
            if let fn = Self.unary[name], f.count == 3,
               let x = Self.parse(f[1]), let e = Self.parse(f[2]) {
                inputs = [x]
                expected = e
                actual = fn(x)
            } else if let fn = Self.binary[name], f.count == 4,
                      let a = Self.parse(f[1]), let b = Self.parse(f[2]), let e = Self.parse(f[3]) {
                inputs = [a, b]
                expected = e
                actual = fn(a, b)
            } else {
                XCTFail("vectors.txt:\(lineNo + 1): malformed line: \(line)")
                continue
            }
            checked[name, default: 0] += 1
            let ok = (expected.isNaN && actual.isNaN) || expected.bitPattern == actual.bitPattern
            if !ok {
                failed[name, default: 0] += 1
                if report.count < maxReported {
                    let args = inputs.map { "0x" + Self.hex($0) + " (\($0))" }.joined(separator: ", ")
                    report.append("\(name)(\(args)) = 0x\(Self.hex(actual)) (\(actual)), "
                                  + "StrictMath 0x\(Self.hex(expected)) (\(expected))")
                }
            }
        }

        let summary = checked.keys.sorted().map { "\($0)=\(checked[$0]!)" }.joined(separator: " ")
        print("[FdLibmTests] vectors checked: \(summary)")
        XCTAssertEqual(Set(checked.keys), Set(Self.unary.keys).union(Self.binary.keys),
                       "every FdLibm function must have vectors")
        let total = failed.values.reduce(0, +)
        XCTAssertEqual(total, 0, "FdLibm mismatches vs StrictMath: \(failed.keys.sorted().map { "\($0)=\(failed[$0]!)" })\n"
                       + report.joined(separator: "\n"))
    }

    /// A few hand-checked anchors that hold for fdlibm regardless of the vector file.
    func testSpecialValues() {
        XCTAssertEqual(FdLibm.sin(0.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(FdLibm.sin(-0.0).bitPattern, (-0.0).bitPattern)
        XCTAssertTrue(FdLibm.cos(.infinity).isNaN)
        XCTAssertEqual(FdLibm.exp(0.0), 1.0)
        XCTAssertEqual(FdLibm.log(1.0).bitPattern, (0.0).bitPattern)
        XCTAssertEqual(FdLibm.log10(1000.0), 3.0)
        XCTAssertEqual(FdLibm.pow(2.0, 10.0), 1024.0)
        XCTAssertEqual(FdLibm.pow(-8.0, 3.0), -512.0)
        XCTAssertTrue(FdLibm.pow(-8.0, 1.0 / 3.0).isNaN)
        XCTAssertEqual(FdLibm.atan2(0.0, -1.0), Double.pi)
        XCTAssertEqual(FdLibm.tanh(.infinity), 1.0)
        XCTAssertEqual(FdLibm.cosh(-.infinity), .infinity)
    }
}
