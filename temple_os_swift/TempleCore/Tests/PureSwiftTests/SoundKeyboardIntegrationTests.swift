import Foundation
import XCTest
import TempleCore
import PureSwift

/// Real shell/custom-keyboard -> original or compiled program -> sound, without device input.
final class SoundKeyboardIntegrationTests:XCTestCase {
    private final class Env:ShellEnv {
        let fs:LayeredFs
        let stateStore:StateStore=Store()
        private final class Store:StateStore {
            private var text:String?
            func load()->String? {text}
            func save(_ value:String) {text=value}
        }
        private let lock=NSLock()
        private var sounds:[Double]=[]
        var tones:[Double] {lock.lock();defer {lock.unlock()};return sounds}
        init(_ dir:URL) {fs=LayeredFs(DirBundle(SHARED.appendingPathComponent("bundled-fs"),SHARED.appendingPathComponent("bundled-fs.index")),dir)}
        func runtimeFile(_ name:String)->[UInt8]? {readFileBytes(SHARED.appendingPathComponent(name=="catalog.json" ? "program-manifests/catalog.json" : "runtime/"+name))}
        func tone(_ freq:Double,at atNs:Int64) {lock.lock();sounds.append(freq);lock.unlock()}
    }
    private func wait(_ sh:Shell,_ seconds:Double=10,_ condition:()->Bool)->Bool {
        let end=Date().addingTimeInterval(seconds)
        repeat {_ = sh.tick();if condition() {return true};Thread.sleep(forTimeInterval:0.01)} while Date()<end
        return condition()
    }
    func testOriginalInstrumentsUseTheCustomKeyboardInBothModes() throws {
        NativePrograms.catalog=NativeCatalog.source
        for native in [false,true] {
            for id in ["sound.asciiorgan","sound.morsecode","app.psalmody","original.jukebox"] {
                let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sound-keyboard-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let env=Env(dir),sh=Shell(env);sh.resize(402,874);_ = sh.tick()
                sh.settings.engine=native ? Settings.ENGINE_NATIVE : Settings.ENGINE_TERRY
                let info=try XCTUnwrap(sh.catalog.byId(id));Launch.program(sh,info.path,info)
                let app=try XCTUnwrap(sh.focused?.app as? ProgramApp),k=app.kernel!
                defer {sh.windows.forEach {sh.close($0,force:true)};try? FileManager.default.removeItem(at:dir)}
                XCTAssertEqual(app.native != nil,native)
                XCTAssertTrue(wait(sh) {sh.templeKeyboardShown && k.frameCount>4 && sh.accessibilityNodes().contains {$0.button && $0.label=="a"}},id)
                XCTAssertNil(k.exitMessage,k.console.plainText())
                func key(_ label:String,_ down:Bool) throws {
                    let r=try XCTUnwrap(sh.accessibilityNodes().last {$0.button && $0.label==label}?.rect)
                    sh.pointer(PointerEvent(down ? Ptr.DOWN : Ptr.UP,r.x+r.w/2,r.y+r.h/2,id:73,timeMs:sh.env.nowMs()));_ = sh.tick()
                }
                let label=id=="original.jukebox" ? "Space" : "a",before=env.tones.filter {$0>0}.count
                try key(label,true)
                XCTAssertTrue(wait(sh) {env.tones.filter {$0>0}.count>before},"\(id) \(native): custom key produces sound")
                try key(label,false)
                if id=="sound.morsecode" || id=="app.psalmody" {
                    XCTAssertTrue(wait(sh) {env.tones.last==0},"key release silences \(id)")
                }
                if id=="app.psalmody" {
                    try key("Symbols",true);try key("Symbols",false)
                    for note in ["left bracket","right bracket","apostrophe"] {
                        let count=env.tones.filter {$0>0}.count
                        try key(note,true);XCTAssertTrue(wait(sh) {env.tones.filter {$0>0}.count>count},note)
                        try key(note,false);XCTAssertTrue(wait(sh) {env.tones.last==0},note+" release")
                    }
                    try key("Letters",true);try key("Letters",false)
                }
                if id=="sound.asciiorgan" {
                    let lower=env.tones.last
                    try key("Shift",true);try key("Shift",false)
                    let count=env.tones.filter {$0>0}.count
                    try key("A",true);XCTAssertTrue(wait(sh) {env.tones.filter {$0>0}.count>count})
                    try key("A",false);XCTAssertNotEqual(env.tones.last,lower,"ASCII uppercase uses its original distinct pitch")
                }
                sh.resize(874,402);_ = sh.tick();XCTAssertTrue(sh.templeKeyboardShown)
                try XCTUnwrap(app.menu().first {$0.label==tr("program.menu.hide_keyboard")}).action();_ = sh.tick();XCTAssertFalse(sh.templeKeyboardShown)
                sh.resize(402,874);_ = sh.tick();XCTAssertFalse(sh.templeKeyboardShown,"rotation respects Hide")
                try XCTUnwrap(app.menu().first {$0.label==tr("program.menu.show_keyboard")}).action();_ = sh.tick();XCTAssertTrue(sh.templeKeyboardShown)
                if native {XCTAssertEqual(k.vm.instructionsExecuted,0)}
                sh.close(try XCTUnwrap(sh.focused),force:true)
                XCTAssertTrue(wait(sh,2) {env.tones.last==0},"closing silences \(id)")
            }
        }
    }
}
