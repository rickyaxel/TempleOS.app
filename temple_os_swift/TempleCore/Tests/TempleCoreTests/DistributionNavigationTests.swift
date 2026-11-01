import Foundation
import XCTest
@testable import TempleCore

final class DistributionNavigationTests:XCTestCase {
    func testCDateFractionSurvivesHolyCShiftPrecedence() throws {
        let k=try runHolyC(try XCTUnwrap(readFileBytes(SHARED.appendingPathComponent("test-vectors/holyc/237_DateClock.HC"))))
        XCTAssertTrue(k.finished);XCTAssertNil(k.exitMessage);XCTAssertTrue(k.console.plainText().contains("date-clock-ok"))
    }
    func testFocusedChildMenuAndParentRestoration() throws {
        let k=Kernel(TestEnv(),"focused menus");k.virtualTime=true;try k.boot()
        defer {k.terminate("test cleanup")}
        let source="""
        U0 Child(U8 *) { WinFocus; MenuPush("Child { Done(,CH_ESC); }"); GetChar; MenuPop; GetChar; }
        MenuPush("Parent { Done(,CH_ESC); }"); Spawn(&Child,NULL,"Child"); Sleep(1000); MenuPop;
        """
        try k.runProgram("C:/Home/FocusMenu.HC",latin1(source))
        func advance(_ ms:Int64) throws {
            let deadline=monoNanos()+5_000_000_000
            while !k.finished && k.now()<ms*1_000_000 && monoNanos()<deadline {
                k.virtualStopAt=ms*1_000_000;_ = try k.step(50_000_000)
            }
            XCTAssertNil(k.exitMessage)
        }
        try advance(100);XCTAssertEqual(k.menuSnapshot.filter {$0.isDir}.map {$0.label},["Child"])
        k.post(.key(ch:97,sc:Keys.forChar(97).1,down:true));try advance(200)
        XCTAssertEqual(k.menuSnapshot.filter {$0.isDir}.map {$0.label},["Parent"])
        k.post(.key(ch:98,sc:Keys.forChar(98).1,down:true));try advance(1200)
        XCTAssertTrue(k.finished);XCTAssertTrue(k.menuSnapshot.isEmpty)
    }
    private func withShell(_ body:(Shell,HeadlessEnv)throws->Void) throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let env=HeadlessEnv(dir),sh=Shell(env);sh.resize(402,874,62,34);_ = sh.tick()
        defer {sh.windows.forEach {$0.app.close()};L10n.use("en-US")}
        try body(sh,env)
    }
    private func tap(_ sh:Shell,_ label:String) throws {
        _ = sh.tick()
        let node=try XCTUnwrap(sh.accessibilityNodes().first {$0.button && $0.label==label},label)
        let x=node.rect.x+node.rect.w/2,y=node.rect.y+node.rect.h/2
        sh.pointer(PointerEvent(Ptr.DOWN,x,y));sh.pointer(PointerEvent(Ptr.UP,x,y));_ = sh.tick()
    }
    private func wait(_ sh:Shell,_ condition:()->Bool)->Bool {
        let end=Date().addingTimeInterval(10)
        while Date()<end {_ = sh.tick();if condition() {return true};Thread.sleep(forTimeInterval:0.01)}
        return condition()
    }
    func testExactIntroAcrossLocalesAndDisplays() throws {
        try withShell {sh,env in
            let expected=["TempleOS.app","Tap MENU to begin.","TempleOS by Terry A. Davis","Mobile adaptation by Ricky Axel"]
            XCTAssertEqual(Brand.introLines,expected)
            for locale in ["en-US","es-ES","ja-JP","ar-SA"] {
                L10n.use(locale)
                for (w,h) in [(300,568),(402,874),(874,402),(1024,1366),(1366,1024),(160,240)] {
                    sh.resize(w,h);sh.invalidate();_ = sh.tick()
                    let nodes=sh.accessibilityNodes().filter {expected.contains($0.label) && !$0.button}
                    XCTAssertEqual(nodes.map {$0.label},expected)
                    XCTAssertTrue(sh.accessibilityNodes().contains {$0.button && $0.label=="MENU"})
                    for node in nodes {XCTAssertTrue(node.rect.y>=0 && node.rect.bottom<=h,"\(w)x\(h) \(node.label)")}
                    for (a,b) in zip(nodes,nodes.dropFirst()) {XCTAssertLessThanOrEqual(a.rect.bottom,b.rect.y)}
                    XCTAssertFalse(env.systemKeyboard)
                }
            }
        }
    }
    func testTouchMenuGamesAndBack() throws {
        try withShell {sh,env in
            try tap(sh,"MENU");XCTAssertTrue(sh.openMenu!.items.contains {$0.label==tr("menu.start.games")})
            try tap(sh,tr("menu.start.games"));XCTAssertEqual(sh.focused?.app.kind,"games")
            XCTAssertTrue(sh.accessibilityNodes().contains {$0.label=="Titanium" && $0.button})
            XCTAssertTrue(sh.back());_ = sh.tick();XCTAssertNotNil(sh.openMenu);XCTAssertFalse(env.systemKeyboard)
        }
    }
    func testEveryRegisteredGroupHasRenderedDestinationAndNoDanglingMenus() throws {
        try withShell {sh,_ in
            Launch.programs(sh)
            for group in sh.catalog.groups where group.id != "games" {
                // Reopen root explicitly via back so the normal reopen behavior can retain context.
                let app=try XCTUnwrap(sh.focused?.app as? ProgramsApp)
                app.restore(["route":"g:"+group.id]);sh.invalidate();_ = sh.tick()
                XCTAssertEqual(app.title,group.title)
                XCTAssertTrue(sh.accessibilityNodes().contains {$0.label==group.source},group.id)
                for id in group.menuIds {XCTAssertNotNil(sh.historicalMenus.byId(id),id)}
                for id in group.programIds {XCTAssertNotNil(sh.catalog.byId(id),id)}
                XCTAssertEqual(sh.windows.count,1)
            }
        }
    }
    func testEveryHistoricalMenuReferenceRendersWithoutGlobalCommandExecution() throws {
        try withShell {sh,_ in
            Launch.programs(sh);let app=sh.focused!.app as! ProgramsApp
            for menu in sh.historicalMenus.menus {
                app.restore(["route":"m:"+menu.id]);sh.invalidate();_ = sh.tick()
                XCTAssertTrue(sh.accessibilityNodes().contains {$0.label==menu.source},menu.id)
                XCTAssertFalse(sh.accessibilityNodes().contains {$0.button && $0.label.hasPrefix("RUN IN")},menu.id)
                XCTAssertEqual(sh.windows.count,1)
            }
        }
    }
    func testSourceOnlyProgramsNeverOfferRun() throws {
        try withShell {sh,_ in
            Launch.programs(sh)
            let app=sh.focused!.app as! ProgramsApp
            for p in sh.catalog.programs where p.unsupported {
                app.restore(["route":"p:"+p.id]);sh.invalidate();_ = sh.tick()
                XCTAssertTrue(sh.accessibilityNodes().contains {$0.label==tr("games.source_only")},p.id)
                XCTAssertFalse(sh.accessibilityNodes().contains {$0.button && $0.label.hasPrefix("RUN IN")},p.id)
            }
        }
    }
    func testPlainAndCompressedSourceLinksUseEditorAndReturnToOrigin() throws {
        try withShell {sh,env in
            Launch.programs(sh);let parent=sh.focused!.id
            Launch.doc(sh,"C:/Doc/DemoIndex.DD");_ = sh.tick();let doc=sh.focused!.id
            try tap(sh,"::/Demo/Graphics/NetOfDots.HC")
            XCTAssertEqual(sh.focused?.app.kind,"editor")
            XCTAssertEqual((sh.focused?.app as? EditorApp)?.path,"C:/Demo/Graphics/NetOfDots.HC")
            sh.close(sh.focused!,force:true);XCTAssertEqual(sh.focused?.id,doc)
            XCTAssertTrue(sh.back());XCTAssertEqual(sh.focused?.id,parent)
            XCTAssertEqual(OriginalNavigation.resolve(sh,"C:/Home","::/Demo/Games/TreeCheckers.HC.Z"),"C:/Demo/Games/TreeCheckers.HC")
            XCTAssertNotNil(OriginalNavigation.resolve(sh,"C:/Home","c:/demo/games/maze.hc"))
            XCTAssertFalse(env.systemKeyboard)
        }
    }
    func testDolDocTreesCollapseAndExpandWithoutLosingOtherGroups() throws {
        try withShell {sh,_ in
            Launch.doc(sh,"C:/Doc/DemoIndex.DD");_ = sh.tick()
            let doc=sh.focused!.app as! DocViewerApp
            XCTAssertTrue(doc.documentText(50).contains("NetOfDots"))
            try tap(sh,"Games: Beginner")
            XCTAssertFalse(doc.documentText(50).contains("NetOfDots"))
            XCTAssertTrue(doc.documentText(50).contains("Games: Intermediate"))
            try tap(sh,"Games: Beginner");XCTAssertTrue(doc.documentText(50).contains("NetOfDots"))
        }
    }
    func testHistoricalMacrosUseTypedRoutesAndChosenEngine() throws {
        try withShell {sh,_ in
            Launch.programs(sh)
            let m=try XCTUnwrap(sh.historicalMenus.menus.first {$0.source=="C:/PersonalMenu.DD"})
            let directory=try XCTUnwrap(m.entries.first {$0.target=="C:/Demo/Snd"})
            XCTAssertTrue(OriginalNavigation.dispatch(sh,directory));XCTAssertEqual((sh.focused?.app as? FilesApp)?.dir,"C:/Demo/Snd")
            sh.close(sh.focused!,force:true)
            let unsupported=try XCTUnwrap(m.entries.first {$0.expression.contains("BootRAM")})
            XCTAssertFalse(OriginalNavigation.dispatch(sh,unsupported));XCTAssertEqual(sh.focused?.app.kind,"programs")
            let game=try XCTUnwrap(m.entries.first {$0.programId=="game.tictactoe"} ?? m.entries.first {$0.programId=="game.flapbat"})
            XCTAssertTrue(OriginalNavigation.dispatch(sh,game));XCTAssertEqual((sh.focused?.app as? ProgramApp)?.path,sh.catalog.byId(game.programId)?.path)
        }
    }
    func testEditorAndFileManagerOriginalGroupsAndUnsupportedDisks() throws {
        try withShell {sh,_ in
            Launch.editor(sh,"C:/Home/Examples/Hello.HC")
            let editor=sh.focused!.app as! EditorApp
            XCTAssertEqual(Array(editor.menu().prefix(6)).map {$0.label},["File","Edit","Insert","Program","View","Help"])
            editor.menu().first {$0.label=="Program"}!.action();_ = sh.tick()
            XCTAssertTrue(sh.openMenu!.items.contains {$0.label=="Include" && $0.enabled})
            XCTAssertTrue(sh.openMenu!.items.contains {$0.label.contains("AdamInclude") && !$0.enabled})
            _ = sh.back();Launch.files(sh,"C:/Demo/Games")
            sh.focused!.app.menu().first {$0.label=="File"}!.action();_ = sh.tick()
            XCTAssertTrue(sh.openMenu!.items.contains {$0.label.contains("FmtDrv") && !$0.enabled})
            XCTAssertTrue(sh.openMenu!.items.contains {$0.label=="DirMk" && $0.enabled})
        }
    }
    func testLiveProgramSubmenusDispatchAndReturnWithoutRestart() throws {
        try withShell {sh,_ in
            let p=ProgramApp(sh,"C:/Demo/PullDownMenu.HC",nil);sh.open(p)
            XCTAssertTrue(wait(sh) {!p.kernel.menuSnapshot.isEmpty})
            sh.showMenu(p.menu(),4,sh.insetTop+sh.barH,p.title);_ = sh.tick()
            try tap(sh,"Misc");XCTAssertNotNil(sh.openMenu?.parent)
            try tap(sh,"Opt1")
            XCTAssertTrue(wait(sh) {p.kernel.menuSnapshot.contains {$0.path=="Misc/Opt1" && $0.checked}})
            XCTAssertTrue(p.kernel.console.plainText().contains("Option # 1"));XCTAssertFalse(p.isFinished)
            sh.showMenu(p.menu(),4,sh.insetTop+sh.barH,p.title);_ = sh.tick();try tap(sh,"File");try tap(sh,"Exit")
            XCTAssertTrue(wait(sh) {p.isFinished});XCTAssertTrue(p.kernel.menuSnapshot.isEmpty)
        }
    }
    func testScrollRouteRestoreAndNavigationCyclesStayBounded() throws {
        try withShell {sh,_ in
            Launch.programs(sh,"tools");let app=sh.focused!.app as! ProgramsApp
            _ = sh.tick();app.scroll(0,-160,Rect(0,0,402,700));_ = sh.tick()
            let saved=app.saveState();let restored=try XCTUnwrap(Launch.restore(sh,"programs",saved) as? ProgramsApp)
            XCTAssertEqual(restored.saveState(),saved)
            for _ in 0..<40 {app.showGroup("demos");app.showProgram("game.maze");app.showGroup("applications")}
            XCTAssertLessThanOrEqual((app.saveState()["history"] ?? "").split(separator:"\t").count,32)
            XCTAssertEqual(sh.windows.filter {$0.app.kind=="programs"}.count,1)
        }
    }
    func testCtrlMUsesCentralMenu() throws {
        try withShell {sh,_ in
            let (_,sc)=Keys.forChar(109);sh.key(13,sc|Keys.SCF_CTRL,true);_ = sh.tick()
            XCTAssertNotNil(sh.openMenu);XCTAssertTrue(sh.openMenu!.items.contains {$0.label==tr("menu.start.games")})
        }
    }
    func testMenuProgramsAlwaysReturnsToHubWithoutDuplicatingWindow() throws {
        try withShell {sh,_ in
            Launch.programs(sh,"applications");let id=sh.focused!.id
            Launch.programs(sh);_ = sh.tick()
            XCTAssertEqual(sh.focused?.id,id)
            XCTAssertEqual(sh.focused?.app.saveState()["route"],"g:programs")
            XCTAssertTrue(sh.accessibilityNodes().contains {$0.label=="Original menus" && $0.button})
        }
    }
}
