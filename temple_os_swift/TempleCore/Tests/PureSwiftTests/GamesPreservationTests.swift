import Foundation
import XCTest
import TempleCore
import PureSwift

final class GamesPreservationTests: XCTestCase {
    private let out = REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/games-preservation")
    private func frame(_ k: Kernel) -> [UInt8] { Array(UnsafeBufferPointer(start: k.published,count: 640 * 480)) }
    private func saveFrame(_ k: Kernel, _ name: String) throws { try Data(frame(k)).write(to: out.appendingPathComponent(name + ".idx")) }
    func testWaterFowlBothModesAndReopening() throws {
        try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: SHARED.appendingPathComponent("test-vectors/audio/waterfowl.json"))) as! [String:Any]
        let expected = (fixture["frequencies"] as! [NSNumber]).map { $0.doubleValue }
        let events = (fixture["events"] as! [[NSNumber]]).map { $0[0].int64Value }
        var runs: [String] = []
        for engine in [Engine.terry,.native,.terry,.native] {
            let (k,env) = try bootProgram("C:/Demo/Snd/WaterFowl.HC",engine)
            defer { k.terminate("test cleanup") }
            var frames: [Int64] = []
            for ms: Int64 in stride(from: 0,through: 19000,by: 20) {
                _ = try advanceTo(k,ms)
                XCTAssertFalse(k.finished,"\(engine) at \(ms): \(k.exitMessage ?? "") \(k.console.plainText())")
                if [1000,4000,10000,19000].contains(ms) { frames.append(fnv(frame(k))); try saveFrame(k,"waterfowl-\(engine)-\(ms)") }
            }
            XCTAssertTrue(k.graphicsUsed)
            XCTAssertGreaterThanOrEqual(Set(frame(k)).count,7)
            XCTAssertEqual(Set(frames).count,4)
            let sounds = Array(env.sound.drop(while: { $0.1 == 0 }).prefix(expected.count))
            XCTAssertEqual(sounds.count,expected.count,"two complete melodies")
            guard sounds.count == expected.count else { return }
            for i in expected.indices {
                XCTAssertEqual(sounds[i].1,expected[i],accuracy: 1e-9,"tone \(i)")
                let ns = Int64(Double(events[i]) * 1192 * 1e9 / 1193182)
                XCTAssertLessThan(abs(sounds[i].0 - sounds[0].0 - ns),5_000_000,"note timing \(i)")
            }
            if engine == .native { XCTAssertEqual(k.vm.instructionsExecuted,0) }
            runs.append(frames.map(String.init).joined(separator: ",") + ":" + sounds.map { "\($0.0):\(bits($0.1))" }.joined(separator: ","))
            let json: [String:Any] = ["frames":frames,"sounds":env.sound.map { [$0.0 as Any,$0.1 as Any] },"instructions":k.vm.instructionsExecuted]
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: out.appendingPathComponent("waterfowl-\(engine).json"))
            let sp = PcSpeaker(48000,0), base = sounds[0].0
            for (at,hz) in sounds where at - base < 2_000_000_000 { sp.post(1_000_000_000 + at - base,hz) }
            sp.post(3_100_000_000,0)
            var pcm = [Float](repeating: 0,count: 48000 * 23 / 10)
            var at = 0
            while at < pcm.count { let n = min(256,pcm.count - at); sp.render(&pcm,at,n,nowNs: 1_000_000_000 + Int64(at) * 1_000_000_000 / 48000); at += n }
            XCTAssertTrue(pcm.contains { abs($0) > 0.05 })
            XCTAssertTrue(pcm.suffix(4800).allSatisfy { $0 == 0 },"PCM silent after stop")
            try pcm.withUnsafeBytes { try Data($0).write(to: out.appendingPathComponent("waterfowl-\(engine).pcm")) }
            let (ch,sc) = Keys.forChar(Int(UInt8(ascii:"x")))
            k.post(.key(ch: ch,sc: sc,down: true)); k.post(.key(ch: ch,sc: sc | Keys.SCF_KEY_UP,down: false))
            _ = try advanceTo(k,19500)
            XCTAssertTrue(k.finished,"GetChar exits")
            XCTAssertTrue(k.tasks.isEmpty,"SongTask cleaned up")
            XCTAssertEqual(env.sound.last?.1,0)
        }
        for run in runs.dropFirst() { XCTAssertEqual(runs.first,run,"modes and reopening") }
    }
    func testWaterFowlFullScrollCycle() throws {
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var signatures: [[Int64]] = []
        for engine in [Engine.terry,.native] {
            let (k,env)=try bootProgram("C:/Demo/Snd/WaterFowl.HC",engine)
            defer {k.terminate("test cleanup")}
            var frames: [Int64] = []
            for ms: Int64 in [64000,66000] {
                _ = try advanceTo(k,ms);XCTAssertFalse(k.finished,k.exitMessage ?? "")
                frames.append(fnv(frame(k)));try saveFrame(k,"waterfowl-full-\(engine)-\(ms)")
            }
            XCTAssertNotEqual(frames[0],frames[1],"poem scroll wraps")
            XCTAssertGreaterThan(env.sound.filter { $0.1>0 }.count,200)
            if engine == .native {XCTAssertEqual(k.vm.instructionsExecuted,0)}
            signatures.append(frames)
            let json: [String:Any] = ["frames":frames,"soundEvents":env.sound.count,"instructions":k.vm.instructionsExecuted]
            try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]).write(to:out.appendingPathComponent("waterfowl-full-\(engine).json"))
            let (ch,sc)=Keys.forChar(120);k.post(.key(ch:ch,sc:sc,down:true));_ = try advanceTo(k,66500)
            XCTAssertTrue(k.finished);XCTAssertEqual(env.sound.last?.1,0)
        }
        XCTAssertEqual(signatures[0],signatures[1])
    }
    func testAdditionalSoundAndSpritePrograms() throws {
        try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
        for path in ["C:/Demo/Snd/ASCIIOrgan.HC","C:/Demo/Snd/OhGreat.HC","C:/Demo/Graphics/SpritePlot.HC","C:/Demo/Graphics/SpritePutExt.HC","C:/Demo/Graphics/Blot.HC","C:/Demo/Graphics/SpritePut.HC","C:/Demo/Graphics/SpriteRaw.HC","C:/Demo/Graphics/EdSprite.HC"] {
            var signatures: [String] = []
            for engine in [Engine.terry,.native] {
                let (k,env) = try bootProgram(path,engine)
                defer { k.terminate("test cleanup") }
                _ = try advanceTo(k,1000)
                XCTAssertNil(k.exitMessage,"\(path) \(engine): \(k.console.plainText())")
                let waitsForKey = path.contains("SpritePlot.HC") || path.contains("Blot.HC")
                if waitsForKey {
                    try saveFrame(k,path.substringAfterLast("/").substringBefore(".") + "-\(engine)")
                    _ = try advanceTo(k,4000)
                    let (ch,sc)=Keys.forChar(120);k.post(.key(ch:ch,sc:sc,down:true));_ = try advanceTo(k,4500)
                    XCTAssertTrue(k.finished,"original PressAKey exits: \(path)")
                }
                if path.contains("ASCIIOrgan") {
                    for c: Int in [65,122] { let (ch,sc)=Keys.forChar(c); k.post(.key(ch:ch,sc:sc,down:true)); k.post(.key(ch:ch,sc:sc | Keys.SCF_KEY_UP,down:false)); _ = try advanceTo(k,k.now() / 1_000_000 + 100) }
                    XCTAssertGreaterThanOrEqual(env.sound.filter { $0.1 > 0 }.count,2)
                    let (ch,sc) = Keys.special(Keys.SC_ESC); k.post(.key(ch:ch,sc:sc,down:true)); _ = try advanceTo(k,1600)
                    XCTAssertTrue(k.finished); XCTAssertEqual(env.sound.last?.1,0)
                    let link=try XCTUnwrap(k.console.spriteLinks(80).first)
                    let action=try XCTUnwrap(OriginalProgramLink.parse(link.format,"C:/Demo/Snd"))
                    XCTAssertEqual(action.path,"C:/Apps/Psalmody/Run.HC");XCTAssertEqual(action.label,"Click for better organ")
                }
                if path.contains("OhGreat") { XCTAssertTrue(env.sound.contains { $0.1 > 0 }) }
                if engine == .native { XCTAssertEqual(k.vm.instructionsExecuted,0) }
                if !waitsForKey { try saveFrame(k,path.substringAfterLast("/").substringBefore(".") + "-\(engine)") }
                signatures.append("\(fnv(frame(k))):\(k.console.plainText()):" + env.sound.map { "\($0.0):\(bits($0.1))" }.joined(separator:","))
            }
            XCTAssertEqual(signatures[0],signatures[1],path)
        }
    }
}
