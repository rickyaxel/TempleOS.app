import Foundation
import XCTest
@testable import TempleCore

final class GamesCatalogTests: XCTestCase {
    private func menu() throws -> OriginalGamesMenu { try OriginalGamesMenu.parse(String(contentsOf: SHARED.appendingPathComponent("runtime/games-menu/menu.json"),encoding:.utf8)) }
    func testHistoricalMembershipAndOrdering() throws {
        let es=try menu().entries
        XCTAssertEqual(es.count,28)
        XCTAssertEqual(["Fun Games","Unfun Games","Code Scraps","Nongames"].map { g in es.filter { $0.category==g }.count },[11,7,5,5])
        XCTAssertEqual(es.prefix(11).map { $0.title },["Titanium","Diamond","Bat","Varoom","FlatTops","Golf","KeepAway","RawHide","X-Caliber","Wenceslas","Lines"])
        XCTAssertFalse(es.contains { $0.programId=="sound.waterfowl" })
    }
    func testIndexedIconDimensionsAndPalette() throws {
        for e in try menu().entries {
            let b=try Data(contentsOf:SHARED.appendingPathComponent("runtime/"+e.asset))
            XCTAssertEqual(Array(b.prefix(4)),[84,79,83,73]);XCTAssertEqual(b.count,8+e.width*e.height)
            XCTAssertEqual(e.width,Int(b[4]) | Int(b[5])<<8);XCTAssertEqual(e.height,Int(b[6]) | Int(b[7])<<8)
            XCTAssertTrue(b.dropFirst(8).allSatisfy { $0==255 || $0<16 })
        }
    }
    func testCatalogSourcesAndSoundClassification() throws {
        let cat=try Catalog.parse(String(contentsOf:SHARED.appendingPathComponent("program-manifests/catalog.json"),encoding:.utf8))
        XCTAssertEqual(Set(cat.programs.map { $0.id }).count,cat.programs.count)
        XCTAssertEqual(Set(cat.programs.map { $0.path.lowercased() }).count,cat.programs.count)
        for p in cat.programs { XCTAssertTrue(FileManager.default.fileExists(atPath:SHARED.appendingPathComponent("bundled-fs/"+String(p.path.dropFirst(3))).path),p.path) }
        let water=try XCTUnwrap(cat.byId("sound.waterfowl"));XCTAssertEqual(water.path,"C:/Demo/Snd/WaterFowl.HC");XCTAssertTrue(water.usesGraphics);XCTAssertTrue(water.capabilities.contains("sound"));XCTAssertEqual(water.category,"sound")
        XCTAssertFalse(cat.byId("sound.morsecode")!.unsupported)
    }
    func testSoundDirectoryIsCompleteAndInstrumentsRequestOurKeyboard() throws {
        let cat=try Catalog.parse(String(contentsOf:SHARED.appendingPathComponent("program-manifests/catalog.json"),encoding:.utf8))
        let sources=try FileManager.default.contentsOfDirectory(atPath:SHARED.appendingPathComponent("bundled-fs/Demo/Snd").path).filter {$0.hasSuffix(".HC")}
        XCTAssertEqual(Set(sources.map {"C:/Demo/Snd/"+$0}),Set(cat.programs.filter {$0.path.hasPrefix("C:/Demo/Snd/")}.map {$0.path}))
        XCTAssertEqual(Set(cat.programs.filter {$0.prefersFullKeyboard}.map {$0.id}),Set(["sound.asciiorgan","sound.morsecode","app.psalmody","original.jukebox","source.demo.keybitmap"]))
    }
    func testResponsivePageAndLaunchRestoration() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let sh=Shell(HeadlessEnv(dir));sh.resize(402,874,62,34);Launch.games(sh);_ = sh.tick()
        defer { sh.windows.forEach { $0.app.close() } }
        for (w,h) in [(402,874),(874,402),(360,800),(800,360),(640,400),(300,760),(160,240)] {
            sh.resize(w,h);_ = sh.tick()
            for n in sh.accessibilityNodes() where n.button && [tr("games.original"),tr("games.catalog"),"BlackDiamond","WaterFowl"].contains(n.label) {
                XCTAssertTrue(n.rect.x>=0 && n.rect.y>=0 && n.rect.right<=w && n.rect.bottom<=h,"\(n.label) \(w)x\(h) \(n.rect)")
            }
        }
        sh.resize(402,874,62,34);_ = sh.tick()
        let tab=try XCTUnwrap(sh.accessibilityNodes().first { $0.label==tr("games.catalog") }?.rect)
        sh.focused!.app.tap(tab.x+tab.w/2,tab.y+tab.h/2,tab);_ = sh.tick()
        let water=try XCTUnwrap(sh.accessibilityNodes().first { $0.label=="WaterFowl" }?.rect)
        sh.focused!.app.tap(water.x+water.w/2,water.y+water.h/2,water);_ = sh.tick()
        XCTAssertEqual(sh.focused!.app.kind,"program");XCTAssertEqual(sh.focused!.app.saveState()["path"],"C:/Demo/Snd/WaterFowl.HC")
        let state=sh.windows.first { $0.app.kind=="games" }!.app.saveState()
        XCTAssertEqual(Launch.restore(sh,"games",state)?.saveState()["catalog"],"true")
    }
    func testCorruptedGsCannotCrashTheWindowManager() throws {
        let bytes=try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("test-vectors/holyc/236_GsCorruption.HC")))
        let k=try runHolyC(bytes)
        XCTAssertTrue(k.finished);XCTAssertTrue(k.console.plainText().contains("done"))
    }
    func testNativeRestoreCannotSubstituteTheInterpreter() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let sh=Shell(HeadlessEnv(dir))
        XCTAssertNil(Launch.restore(sh,"program",["path":"C:/Home/Untranslated.HC","engine":"native"]))
    }
    func testDuplicateCatalogIdsAreRejected() {
        XCTAssertThrowsError(try Catalog.parse(#"{"programs":[{"id":"x","path":"C:/a.HC"},{"id":"x","path":"C:/b.HC"}]}"#))
    }
    func testDocumentSpriteTransparencyAndClear() throws {
        let c=Console();try c.insertSprite([255,4],2,1,0,0)
        try c.insertSprite([4,4],2,1,Int.max,Int.max)
        try c.insertSprite([4,4],2,1,Int.min,Int.min)
        var cells=[Int](repeating:0,count:80*60);c.renderCells(&cells,80,60,0xf1)
        let frame=UnsafeMutablePointer<UInt8>.allocate(capacity:640*480);frame.initialize(repeating:15,count:640*480);defer {frame.deallocate()}
        c.renderSprites(frame,640,0,0,80,60);XCTAssertEqual(frame[0],15);XCTAssertEqual(frame[1],4)
        c.clear();frame.update(repeating:15,count:640*480);c.renderSprites(frame,640,0,0,80,60)
        XCTAssertTrue(UnsafeBufferPointer(start:frame,count:640*480).allSatisfy { $0==15 })
    }
}
