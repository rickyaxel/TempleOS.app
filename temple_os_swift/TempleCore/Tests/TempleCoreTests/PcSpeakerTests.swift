import Foundation
import XCTest
@testable import TempleCore

/**
 * The PC speaker renderer (Kernel/PcSpeaker.swift) without any audio device: pitch, silence, sample-exact
 * timing, monophony, the 8254's period restart, band-limiting and its edge cases. Port of PcSpeakerTest.kt;
 * both check shared/test-vectors/audio/pcspeaker-vectors.json, so the platforms render identical samples.
 */
final class PcSpeakerTests: XCTestCase {
    private let rate = 48000
    private let lat: Int64 = 20_000_000
    private let t0: Int64 = 1_000_000_000

    /** Renders [seconds] in blocks of [block] frames, the clock advancing with the samples. */
    private func render(_ sp: PcSpeaker, _ seconds: Double, block: Int = 256, start: Int64? = nil) -> [Float] {
        let st = start ?? t0
        let n = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let m = min(block, n - i)
            sp.render(&out, i, m, nowNs: st + Int64(i) * 1_000_000_000 / Int64(rate))
            i += m
        }
        return out
    }

    /** Frequency from the rising crossings of zero between sample [a] and [b] (interpolated). */
    private func pitch(_ x: [Float], _ a: Int, _ b: Int) -> Double {
        var cr: [Double] = []
        for j in (a + 1)..<b where x[j - 1] < 0 && x[j] >= 0 { cr.append(Double(j - 1) + Double(0 - x[j - 1]) / Double(x[j] - x[j - 1])) }
        return cr.count < 3 ? 0 : Double(cr.count - 1) / ((cr.last! - cr.first!) / Double(rate))
    }

    private func onset(_ x: [Float], _ from: Int = 0) -> Int { (from..<x.count).first { abs(Double(x[$0])) >= PcSpeaker.AMPLITUDE / 2 } ?? -1 }

    private func silentFrom(_ x: [Float], _ from: Int) -> Int {
        var last = -1
        for j in from..<x.count where x[j] != 0 { last = j }
        return last + 1
    }

    func testSilentUntilSet() {
        XCTAssertTrue(render(PcSpeaker(rate, lat), 0.2).allSatisfy { $0 == 0 })
    }

    func testA4IsTheFlatPitTone() {
        let sp = PcSpeaker(rate, lat)
        let hz = 1193182.0 / 2730 // Snd(60): SYS_TIMER_FREQ/440 = 2730.6 -> 2730
        sp.post(t0, hz)
        let x = render(sp, 1.1)
        let f = pitch(x, rate / 20, x.count)
        XCTAssertEqual(f, hz, accuracy: 0.02)
        XCTAssertEqual(f, 437.063, accuracy: 0.02)
    }

    func testEventsLandOnTheirSampleAfterTheLatency() {
        let sp = PcSpeaker(rate, lat)
        sp.post(t0 + 50_000_000, 1000)
        sp.post(t0 + 200_000_000, 0)
        let x = render(sp, 0.4)
        let on = onset(x)
        XCTAssertLessThanOrEqual(abs(on - (50 + 20) * rate / 1000), 1, "onset \(on)")
        let off = silentFrom(x, on)
        XCTAssertLessThanOrEqual(abs(off - (200 + 20) * rate / 1000), 2, "silent from \(off)")
        XCTAssertEqual(Double(off - on), 150 * Double(rate) / 1000, accuracy: 2)
    }

    func testBlockSizeDoesNotChangeTheOutput() {
        func run(_ block: Int) -> [Float] {
            let sp = PcSpeaker(rate, lat)
            var t = t0
            for k in 0..<40 { sp.post(t, k % 3 == 2 ? 0 : 200 + 97 * Double(k)); t += 7_300_000 + Int64(k) * 113_000 }
            return render(sp, 0.5, block: block)
        }
        let ref = run(1)
        for b in [7, 37, 256, 1024, 4096] { XCTAssertEqual(run(b), ref, "block \(b)") }
    }

    func testANewSettingReplacesTheToneAndRestartsItsPeriodHigh() {
        let sp = PcSpeaker(rate, lat)
        sp.post(t0, 300); sp.post(t0, 900)
        let x = render(sp, 0.3)
        XCTAssertEqual(pitch(x, onset(x), x.count), 900, accuracy: 0.5)
        let sp2 = PcSpeaker(rate, lat)
        sp2.post(t0, 100)
        sp2.post(t0 + 7_500_000, 250) // 0.75 of a 100 Hz period: OUT is low there
        let y = render(sp2, 0.1)
        let change = Int((7.5 + 20) * Double(rate) / 1000)
        XCTAssertLessThan(y[change - 3], 0, "low before the change")
        XCTAssertGreaterThan(y[change + 2], 0, "high right after the change")
    }

    func testOutputIsBoundedAndHasNoDc() {
        let sp = PcSpeaker(rate, lat)
        sp.post(t0, 437.063)
        let x = render(sp, 1.0)
        XCTAssertTrue(x.allSatisfy { abs(Double($0)) <= PcSpeaker.AMPLITUDE + 1e-6 })
        let a = onset(x)
        let period = Double(rate) / 437.063
        let n = Int(Double(Int(Double(x.count - a) / period)) * period)
        let mean = (a..<(a + n)).reduce(0.0) { $0 + Double(x[$1]) } / Double(n)
        XCTAssertEqual(mean, 0, accuracy: 2e-4)
    }

    private func dft(_ x: [Float], _ a: Int, _ n: Int, _ hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for j in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / Double(n - 1))
            let ph = 2 * Double.pi * hz * Double(j) / Double(rate)
            re += w * Double(x[a + j]) * cos(ph); im -= w * Double(x[a + j]) * sin(ph)
        }
        return (re * re + im * im).squareRoot()
    }

    func testHighNotesAreBandLimited() {
        let f = 1193182.0 / 398
        let sp = PcSpeaker(rate, lat)
        sp.post(t0, f)
        let x = render(sp, 0.5)
        let a = onset(x) + 100, n = 8192
        let fund = dft(x, a, n, f)
        for h in [9, 11, 13, 15, 17, 19, 21, 23, 25] {
            let hf = Double(h) * f
            let alias = abs(Double(rate) * (hf / Double(rate)).rounded() - hf)
            let db = 20 * log10(dft(x, a, n, alias) / fund)
            let naive = 20 * log10(1.0 / Double(h))
            XCTAssertTrue(db < naive - 9 && (alias > 16000 || db < -35), "harmonic \(h): alias at \(Int(alias)) Hz is \(db) dB")
        }
        let f1 = 1193182.0 / 1193
        let sp1 = PcSpeaker(rate, lat)
        sp1.post(t0, f1)
        let y = render(sp1, 0.5)
        let fund1 = dft(y, a, n, f1)
        for h in [3, 5, 7] { XCTAssertEqual(dft(y, a, n, Double(h) * f1) / fund1, 1.0 / Double(h), accuracy: 0.08 / Double(h), "harmonic \(h)") }
        XCTAssertLessThan(dft(y, a, n, 2 * f1) / fund1, 0.01, "no even harmonics")
    }

    func testLateSettingsPlayAtOnceAndAColdStartKeepsTheRunsTiming() {
        let sp = PcSpeaker(rate, lat)
        sp.post(t0, 440); sp.post(t0 + 150_000_000, 0)
        let x = render(sp, 0.4, start: t0 + 100_000_000)
        let on = onset(x)
        XCTAssertLessThanOrEqual(on, 2)
        XCTAssertEqual(Double(silentFrom(x, on) - on), 150 * Double(rate) / 1000, accuracy: 2, "first note keeps 150 ms")
        let sp2 = PcSpeaker(rate, lat)
        sp2.post(t0, 440); sp2.post(t0 + 10_000_000, 0)
        let y = render(sp2, 0.2, start: t0 + 2_000_000_000)
        XCTAssertTrue(y.allSatisfy { abs(Double($0)) < PcSpeaker.AMPLITUDE / 2 }, "stale note never sounds")
    }

    func testAnUnderrunSkipsAheadInsteadOfDelayingEverything() {
        let sp = PcSpeaker(rate, lat)
        var out = [Float](repeating: 0, count: 480)
        sp.render(&out, 0, 480, nowNs: t0)
        sp.post(t0 + 490_000_000, 1000)
        var after = [Float](repeating: 0, count: 4800)
        sp.render(&after, 0, 4800, nowNs: t0 + 510_000_000)
        XCTAssertLessThanOrEqual(onset(after), Int(lat / 1_000_000 + 2) * rate / 1000)
    }

    func testADeviceClockOffByTwoPercentKeepsRealTimeDistances() {
        for k in [1.02, 0.98] {
            let sp = PcSpeaker(rate, lat)
            for j in 0..<30 { sp.post(t0 + Int64(j) * 200_000_000, 440); sp.post(t0 + Int64(j) * 200_000_000 + 180_000_000, 0) }
            let n = Int(6.2 * Double(rate) * k)
            var x = [Float](repeating: 0, count: n)
            var i = 0
            while i < n { let m = min(256, n - i); sp.render(&x, i, m, nowNs: t0 + Int64(Double(i) * 1e9 / (Double(rate) * k))); i += m }
            let ons = (20..<n).filter { i in x[i] != 0 && x[(i - 20)..<i].allSatisfy { $0 == 0 } } // after a rest (an edge on a sample can be one 0)
            let gaps = zip(ons, ons.dropFirst()).map { $1 - $0 }.dropFirst(10)
            let want = 0.2 * Double(rate) * k
            for g in gaps { XCTAssertEqual(Double(g), want, accuracy: want * 0.003, "device x\(k): onset spacing") }
        }
    }

    func testAnOutputStartUpDelayIsNotADrift() {
        let sp = PcSpeaker(rate, lat)
        for j in 0..<10 { sp.post(t0 + Int64(j) * 200_000_000, 440); sp.post(t0 + Int64(j) * 200_000_000 + 180_000_000, 0) }
        let n = 2 * rate
        var x = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let m = min(192, n - i)
            let valid = i >= rate * 3 / 10
            sp.render(&x, i, m, nowNs: t0 + Int64(i) * 1_000_000_000 / Int64(rate) + (valid ? 80_000_000 : 0), clockValid: valid)
            i += m
        }
        let ons = (20..<n).filter { i in x[i] != 0 && x[(i - 20)..<i].allSatisfy { $0 == 0 } } // after a rest (an edge on a sample can be one 0)
        XCTAssertEqual(ons.count, 10)
        for g in zip(ons, ons.dropFirst()).map({ $1 - $0 }) { XCTAssertEqual(Double(g), 0.2 * Double(rate), accuracy: 1) }
    }

    func testInvalidAndUnplayableSettingsAreSilent() {
        for bad in [Double.nan, Double.infinity, -440, 24000, 1e9] {
            let sp = PcSpeaker(rate, lat)
            sp.post(t0, bad)
            XCTAssertTrue(render(sp, 0.1).allSatisfy { $0 == 0 }, "\(bad)")
        }
        let sp = PcSpeaker(rate, lat)
        sp.post(t0, 1193182.0 / 65535)
        let x = render(sp, 0.5)
        XCTAssertEqual(pitch(x, 0, x.count), 18.207, accuracy: 0.01)
    }

    func testAFloodOfSettingsKeepsTheLatest() {
        let sp = PcSpeaker(rate, lat, capacity: 64)
        for k in 0..<10_000 { sp.post(t0 + Int64(k) * 1000, 100 + Double(k)) }
        let x = render(sp, 0.3)
        XCTAssertEqual(pitch(x, x.count / 2, x.count), 100 + 9999, accuracy: 1)
    }

    func testIdleBookkeeping() {
        let sp = PcSpeaker(rate, lat)
        XCTAssertFalse(sp.pendingSound)
        sp.post(t0, 0)
        XCTAssertFalse(sp.pendingSound, "silence does not need the output")
        sp.post(t0, 500)
        XCTAssertTrue(sp.pendingSound)
        _ = render(sp, 0.1)
        XCTAssertFalse(sp.pendingSound)
        XCTAssertEqual(sp.silentFrames, 0)
        XCTAssertFalse(sp.idle(after: 1))
        sp.post(t0 + 100_000_000, 0)
        _ = render(sp, 0.3, start: t0 + 100_000_000)
        XCTAssertGreaterThan(sp.silentFrames, Int64(rate / 10))
        XCTAssertTrue(sp.idle(after: Int64(rate / 10)))
    }

    func testRendersMuchFasterThanRealTime() {
        let sp = PcSpeaker(rate, lat)
        var t = t0
        for k in 0..<1000 { sp.post(t, 200 + Double((k * 37) % 3000)); t += 1_000_000 }
        _ = render(sp, 2.0)
        let n0 = monoNanos()
        _ = render(sp, 10.0, start: t0 + 2_000_000_000)
        let ms = Double(monoNanos() - n0) / 1e6
        print("PcSpeaker: 10 s of 48 kHz audio rendered in \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 1000)
    }

    /** The samples Kotlin's PcSpeakerTest wrote (shared/test-vectors/audio/pcspeaker-vectors.json). */
    func testAnOddPitCountIsHighOneClockLongerThanLow() {
        // 8254 mode 3: an odd count N is high for (N+1)/2 clocks and low for (N-1)/2 (see PcSpeakerTest.kt)
        for n: Int64 in [101, 102, 2731] {
            let r = 4_800_000
            let sp = PcSpeaker(r, 0)
            let hz = Double(TempleClock.PIT_HZ) / Double(n)
            sp.post(1_000_000_000, hz)
            var x = [Float](repeating: 0, count: r / 20)
            sp.render(&x, 0, x.count, nowNs: 1_000_000_000)
            let per = Double(r) / hz
            let periods = Int((Double(x.count) / per).rounded(.down)) - 1
            let b = Int((Double(periods) * per).rounded())
            let mean = x[0..<b].reduce(0.0) { $0 + Double($1) } / Double(b)
            let duty = n % 2 == 1 ? Double((n + 1) / 2) / Double(n) : 0.5
            XCTAssertEqual(mean, PcSpeaker.AMPLITUDE * (2 * duty - 1), accuracy: 2e-5, "count \(n)")
        }
    }

    func testSharedVectorsMatchKotlin() throws {
        let text = try String(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/pcspeaker-vectors.json"), encoding: .utf8)
        let doc = try XCTUnwrap(try Json.parse(text) as? [String: Any?])
        let cases = try XCTUnwrap(doc["cases"] as? [String: Any?])
        let posts: [(String, [(Int64, Double)])] = [
            ("scale", [(0, 437.063), (150, 490.6176), (300, 0), (300, 259.8393), (480, 0)]),
            ("noise", (0..<60).map { (k: Int) -> (Int64, Double) in (Int64(k), k % 7 == 6 ? 0.0 : 200.0 + Double((k * 131) % 4000)) }),
            ("edges", [(0, 18.2069), (40, 21307), (60, 23999), (70, 0)]),
            ("pitodd", [(0, 1193182.0 / 5785), (100, 1193182.0 / 723), (200, 1193182.0 / 255), (300, 0)]),
        ]
        for (name, ev) in posts {
            let sp = PcSpeaker(rate, lat)
            for (ms, hz) in ev { sp.post(t0 + ms * 1_000_000, hz) }
            let x = render(sp, 0.5, block: 100)
            let q = stride(from: 0, to: x.count, by: 7).map { Int64((Double(x[$0]) * 1e6 + 0.5).rounded(.down)) }
            let expected = try XCTUnwrap(cases[name] as? [Any?]).map { v -> Int64 in
                if let i = v as? Int64 { return i }; if let i = v as? Int { return Int64(i) }; return Int64((v as? Double) ?? .nan)
            }
            XCTAssertEqual(q.count, expected.count, name)
            let firstDiff = zip(q, expected).enumerated().first { $0.element.0 != $0.element.1 }
            XCTAssertNil(firstDiff.map { "sample \($0.offset * 7): swift \($0.element.0), kotlin \($0.element.1)" }, name)
        }
    }
}
