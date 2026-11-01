import Foundation
import XCTest
import TempleCore
import PureSwift

/// Real source/files/scheduler/audio on both engines. Native runs must execute zero bytecode.
final class SourceOnlyProgramParityTests:XCTestCase {
    private let out=REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/source-only")
    private func key(_ k:Kernel,_ ch:Int,_ down:Bool=true) {let (_,sc)=Keys.forChar(ch);k.post(.key(ch:ch,sc:sc,down:down))}
    private func tap(_ k:Kernel,_ ch:Int) {key(k,ch);key(k,ch,false)}
    private func type(_ k:Kernel,_ text:String) {for c in text.utf8 {key(k,Int(c))}}
    private func advance(_ k:Kernel,_ ms:Int64) throws {_ = try advanceTo(k,ms);XCTAssertNil(k.exitMessage,k.console.plainText())}
    private func pixels(_ k:Kernel)->[UInt8] {Array(UnsafeBufferPointer(start:k.published,count:640*480))}
    private func both(_ path:String,_ body:(Kernel,ParityEnv,Engine)throws->Void) throws {
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        for engine in [Engine.terry,.native] {
            let (k,env)=try bootProgram(path,engine)
            defer {k.terminate("test")}
            try body(k,env,engine)
            if engine == .native {XCTAssertEqual(k.vm.instructionsExecuted,0)}
            let stem=path.replacingOccurrences(of:"C:/",with:"").replacingOccurrences(of:"/",with:"_")+"-\(engine)"
            try Data(pixels(k)).write(to:out.appendingPathComponent(stem+".idx"))
            let report:[String:Any]=["path":path,"engine":"\(engine)","frames":k.frameCount,"instructions":k.vm.instructionsExecuted,"finished":k.finished,"exit":k.exitMessage ?? "","sounds":env.sound.map {[$0.0 as Any,$0.1 as Any]},"console":k.console.plainText()]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:out.appendingPathComponent(stem+".json"))
        }
    }
    func testVocabularyQuizAndDefinitions() throws {
        try both("C:/Apps/Vocabulary/Run.HC") {k,env,_ in
            try advance(k,3000);XCTAssertFalse(k.finished);XCTAssertTrue(k.console.plainText().contains("Answer:"))
            let definition=try XCTUnwrap(k.dictionary.get("WATERFOWL"));XCTAssertTrue(latin1(definition).lowercased().contains("water"))
            key(k,49);try advance(k,4000);XCTAssertTrue(k.console.plainText().contains("(1)"))
            key(k,Keys.CH_ESC);try advance(k,7000);key(k,Keys.CH_ESC);try advance(k,7500)
            XCTAssertTrue(k.finished);XCTAssertEqual(env.sound.last?.1,0)
        }
    }
    func testMorseDotDashAndSilence() throws {
        try both("C:/Demo/Snd/MorseCode.HC") {k,env,_ in
            try advance(k,100);key(k,120);try advance(k,200);key(k,120,false);try advance(k,250)
            key(k,120);try advance(k,450);key(k,120,false);try advance(k,800)
            XCTAssertTrue(k.console.plainText().contains(".-A "),k.console.plainText());XCTAssertTrue(env.sound.contains {$0.1>0});XCTAssertEqual(env.sound.last?.1,0)
            key(k,Keys.CH_ESC);try advance(k,1000);XCTAssertTrue(k.finished)
        }
    }
    func testStadiumThrowRestartAndExit() throws {
        try both("C:/Demo/Games/Stadium/Stadium.HC") {k,_,_ in
            try advance(k,1000);XCTAssertTrue(k.graphicsUsed);XCTAssertGreaterThan(Set(pixels(k)).count,6)
            let first=pixels(k);k.post(.mouse(x:300,y:60,lb:true,rb:false,wheel:0));try advance(k,1050);XCTAssertNotEqual(first,pixels(k))
            k.post(.mouse(x:300,y:60,lb:false,rb:false,wheel:0));key(k,10);try advance(k,1500)
            tap(k,Keys.CH_ESC);try advance(k,2000);XCTAssertTrue(k.finished)
        }
    }
    func testModelsFormAndManSprite() throws {
        try both("C:/Apps/GrModels/Run.HC") {k,env,engine in
            try advance(k,1000);XCTAssertTrue(k.console.plainText().contains("Head Radius"),k.console.plainText())
            key(k,Keys.CH_ESC);try advance(k,2000);key(k,110);try advance(k,2500)
            XCTAssertTrue(k.console.plainText().contains("Do another"));XCTAssertTrue(k.graphicsUsed)
            let doc=k.mem.ld8(k.mainTask!.fsAddr+k.o.task("put_doc"))
            let head=Int(doc)+k.o.member("CDoc","bin_head");XCTAssertNotEqual(k.mem.ld8(head),Int64(head),"generated mesh is an owned document attachment")
            XCTAssertFalse(k.finished,"PersonalMenu's trailing View keeps the generated model open")
            let first=pixels(k),allocated=k.mem.allocated
            try advance(k,3000)
            let changed=zip(first,pixels(k)).filter {$0.0 != $0.1}.count
            XCTAssertGreaterThan(changed,200,"the original mesh continues rotating in View")
            let afterAnimation=k.mem.allocated
            XCTAssertLessThanOrEqual(afterAnimation,allocated+4096,"live sprite redraw does not retain per-frame arena allocations")
            tap(k,Keys.CH_ESC);try advance(k,3300);XCTAssertTrue(k.finished)
            try k.documents.export("C:/Home/GeneratedModel.DD")
            let saved=try XCTUnwrap(env.fs?.readFile("C:/Home/GeneratedModel.DD"));XCTAssertEqual(SourceFile.parse("model",saved).bins.count,1);XCTAssertTrue(latin1(saved).contains("BI=1"))
            let dir=REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/distribution-support")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let record:[String:Any]=["path":"C:/Apps/GrModels/Run.HC","engine":"\(engine)","instructions":k.vm.instructionsExecuted,"changedPixels":changed,"arenaBefore":allocated,"arenaAfterAnimation":afterAnimation,"arenaAfterExit":k.mem.allocated,"viewExited":k.finished,"exportedBinaryRecords":1]
            try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]).write(to:dir.appendingPathComponent("Models-View-\(engine).json"))
        }
    }
    func testBudgetSaveAndReopen() throws {
        try both("C:/Apps/Budget/Run.HC") {k,env,engine in
            try advance(k,1000);key(k,110);try advance(k,1100);XCTAssertTrue(k.console.plainText().contains("Credit"))
            type(k,"10/24/2026\n12.5\nCASH\nBANK\nsimulator entry");key(k,Keys.CH_ESC);try advance(k,1500)
            XCTAssertTrue(k.console.plainText().contains("simulator entry"));key(k,Keys.CH_ESC);try advance(k,2000);XCTAssertTrue(k.finished)
            let fs=try XCTUnwrap(env.fs);XCTAssertTrue(fs.exists("C:/Home/Budget/Bgt.DATA.Z"))
            let reopenEnv=ParityEnv(fs);let again=try runner.boot("C:/Apps/Budget/Run.HC",engine.core,reopenEnv);defer {again.terminate("test")}
            try advance(again,1000);XCTAssertTrue(again.console.plainText().contains("simulator entry"));if engine == .native {XCTAssertEqual(again.vm.instructionsExecuted,0)}
        }
    }
    func testPsalmodyRecordingPlaybackAndSave() throws {
        try both("C:/Apps/Psalmody/Run.HC") {k,env,engine in
            try advance(k,1000);XCTAssertFalse(k.finished);XCTAssertTrue(k.graphicsUsed)
            tap(k,122);try advance(k,1100);key(k,97);try advance(k,1400);key(k,97,false);try advance(k,1500)
            key(k,115);try advance(k,1800);key(k,115,false);try advance(k,1900)
            XCTAssertTrue(env.sound.contains {$0.1>0});XCTAssertEqual(env.sound.last?.1,0)
            let head=k.o.global("psm");XCTAssertNotEqual(k.mem.ld8(head),Int64(head))
            k.post(.raw(code:2,a1:0,a2:0x4CB0000044B));try advance(k,2000);tap(k,120);try advance(k,3500)
            XCTAssertGreaterThanOrEqual(env.sound.filter {$0.1>0}.count,4)
            tap(k,Keys.CH_ESC);try advance(k,3700);XCTAssertTrue(k.console.plainText().contains("FileName"))
            tap(k,Keys.CH_ESC);try advance(k,4000);XCTAssertTrue(k.finished)
            let song=try XCTUnwrap(env.fs?.readFile("C:/Home/Psalmody/Tmp.HC.Z"));XCTAssertTrue(latin1(song).contains("Play(\""));XCTAssertEqual(env.sound.last?.1,0)
            let fs=try XCTUnwrap(env.fs);try fs.writeFile("C:/Apps/Psalmody/Examples/aaa_recorded.HC",song)
            let replayEnv=ParityEnv(fs),replay=try runner.boot("C:/Apps/Psalmody/Load.HC",engine.core,replayEnv);defer {replay.terminate("test")}
            try advance(replay,1000);XCTAssertTrue(replay.console.plainText().contains("aaa_reco"));key(replay,32);try advance(replay,2500)
            XCTAssertTrue(replayEnv.sound.contains {$0.1>0},replay.console.plainText());key(replay,Keys.CH_ESC);try advance(replay,3000)
            XCTAssertTrue(replay.finished);XCTAssertEqual(replayEnv.sound.last?.1,0);if engine == .native {XCTAssertEqual(replay.vm.instructionsExecuted,0)}

        }
    }
    func testToTheFrontTerrainAIAndPhase() throws {
        try both("C:/Apps/ToTheFront/Run.HC") {k,_,_ in
            try advance(k,500);key(k,10);try advance(k,5000);XCTAssertFalse(k.finished);XCTAssertTrue(k.graphicsUsed)
            let moves=try XCTUnwrap(k.prog.globals["player_move"] as? GlobalSym);XCTAssertNotEqual(k.mem.ld8(moves.addr),0);XCTAssertNotEqual(k.mem.ld8(moves.addr+8),0)
            XCTAssertGreaterThan(Set(pixels(k)).count,6);key(k,32);try advance(k,7000);tap(k,Keys.CH_ESC);try advance(k,7500);XCTAssertTrue(k.finished,k.console.plainText())
        }
    }
    func testJukeBoxRatePlayAndExit() throws {
        try both("C:/Apps/Psalmody/Load.HC") {k,env,_ in
            try advance(k,1000);XCTAssertFalse(k.finished);XCTAssertTrue(k.console.plainText().contains("to rate a song"))
            key(k,55);try advance(k,1100);key(k,32);try advance(k,2500);XCTAssertTrue(env.sound.contains {$0.1>0},k.console.plainText())
            key(k,Keys.CH_ESC);try advance(k,3000);XCTAssertTrue(k.finished);XCTAssertEqual(env.sound.last?.1,0)
        }
    }
    func testFontEditorModifyAndSave() throws {
        try both("C:/Demo/Graphics/FontEd.HC") {k,env,_ in
            try advance(k,1000);let font=k.gfx.fontAddr,old=k.mem.ld1(k.gfx.fontAddr)
            k.post(.mouse(x:145,y:41,lb:true,rb:false,wheel:0));try advance(k,1100);k.post(.mouse(x:145,y:41,lb:false,rb:false,wheel:0));try advance(k,1200);XCTAssertEqual(k.mem.ld1(font),old|1)
            tap(k,Keys.CH_ESC);try advance(k,1500);XCTAssertTrue(k.finished);XCTAssertNotNil(env.fs?.readFile("C:/Home/Tmp.DD.Z"))
        }
    }
    func testGridSnapAndRestore() throws {
        try both("C:/Demo/Graphics/Grid.HC") {k,_,_ in
            try advance(k,100);k.post(.mouse(x:113,y:117,lb:false,rb:false,wheel:0));try advance(k,200)
            XCTAssertEqual(k.mem.ld8(k.o.msAddr+k.o.msPos),110);XCTAssertEqual(k.mem.ld8(k.o.msAddr+k.o.msPos+8),115)
            let drawn=pixels(k);XCTAssertEqual(drawn[115*640+114],drawn[115*640+110],"original 5-pixel cursor fills its first row");XCTAssertNotEqual(drawn[115*640+114],drawn[115*640+115],"cursor ends at its source-defined width")
            k.post(.mouse(x:113,y:117,lb:true,rb:false,wheel:0));try advance(k,300);XCTAssertTrue(k.finished);XCTAssertEqual(k.mem.ld1(k.o.global("ms_grid")),0)
        }
    }
    func testBalloonPlanarPixelsAndTiming() throws {
        try both("C:/Demo/Graphics/Balloon.HC") {k,_,_ in
            try advance(k,100);XCTAssertFalse(k.finished);XCTAssertTrue(k.graphicsUsed);XCTAssertTrue(pixels(k).contains(14))
            let first=pixels(k);try advance(k,900);XCTAssertNotEqual(first,pixels(k));try advance(k,2200);XCTAssertTrue(k.finished)
        }
    }
    func testScreenshotSaveAndRead() throws {
        try both("C:/Demo/Graphics/ScrnCapture.HC") {k,env,_ in
            try advance(k,100);key(k,120);try advance(k,250)
            let raw=try XCTUnwrap(env.fs?.readFile("C:/Home/DemoScrnShot.GR.Z"));let im=try GRImage.decodeFile(raw,outerArchive:true)
            XCTAssertEqual(im.width,640);XCTAssertEqual(im.height,480);XCTAssertGreaterThan(Set(im.body).count,1)
            key(k,120);try advance(k,500);XCTAssertTrue(k.graphicsUsed);key(k,120);try advance(k,750);XCTAssertTrue(k.finished)
        }
    }
    func testWallpaperControlLifecycle() throws {
        try both("C:/Demo/Graphics/WallPaperCtrl.HC") {k,_,_ in
            try advance(k,1000);XCTAssertFalse(k.finished);XCTAssertTrue(k.graphicsUsed)
            let first=pixels(k);k.post(.mouse(x:300,y:240,lb:true,rb:false,wheel:0));try advance(k,1100)
            k.post(.mouse(x:300,y:240,lb:false,rb:false,wheel:0));try advance(k,1200);XCTAssertNotEqual(first,pixels(k))
            key(k,Keys.CH_ESC);try advance(k,1500);XCTAssertTrue(k.finished)
        }
    }
    func testOriginalSpriteSummaryAndSource() throws {
        try both("C:/Demo/Graphics/SpriteText.HC") {k,_,_ in
            try advance(k,1000);XCTAssertTrue(k.finished);XCTAssertTrue(k.console.plainText().contains("ENTIRE SPRITE CODE"));XCTAssertTrue(k.console.plainText().contains("Line{"))
        }
    }
    func testPoleZeroDragAndPhaseView() throws {
        try both("C:/Demo/Graphics/PoleZeros.HC") {k,_,_ in
            func step(_ ms:Int64=600) throws {try advance(k,k.now()/1_000_000+ms)}
            try step(2500);XCTAssertFalse(k.finished);XCTAssertTrue(k.graphicsUsed)
            let first=pixels(k);k.post(.mouse(x:330,y:240,lb:true,rb:false));try step()
            k.post(.mouse(x:350,y:260,lb:true,rb:false));try step();k.post(.mouse(x:350,y:260,lb:false,rb:false));try step()
            let zero=try XCTUnwrap(k.prog.globals["zeros"] as? GlobalSym);XCTAssertEqual(d(k.mem.ld8(zero.addr)),30)
            XCTAssertNotEqual(first,pixels(k));k.post(.mouse(x:350,y:260,lb:false,rb:true));try step()
            k.post(.mouse(x:350,y:260,lb:false,rb:false));try step();tap(k,Keys.CH_ESC);try step();XCTAssertTrue(k.finished)
        }
    }
    func testTimeClockPunchInOutAndReport() throws {
        for engine in [Engine.terry,.native] {
            let (k,env)=try bootProgram("C:/Apps/TimeClock/Load.HC",engine,popups:[0,1,2,-1]);defer {k.terminate("test")}
            try advance(k,500);XCTAssertTrue(k.console.plainText().contains("Enter Description"),k.console.plainText())
            type(k,"arrived");key(k,Keys.CH_ESC);try advance(k,1000);type(k,"left");key(k,Keys.CH_ESC);try advance(k,1500)
            XCTAssertTrue(k.finished);XCTAssertTrue(k.console.plainText().contains("arrived"));XCTAssertTrue(k.console.plainText().contains("left"))
            let data=try XCTUnwrap(env.fs?.readFile("C:/Home/TimeClock/TimeFile.DATA.Z"));XCTAssertEqual(data.first,1);XCTAssertTrue(data.contains(2))
            if engine == .native {XCTAssertEqual(k.vm.instructionsExecuted,0)}
        }
    }

}
