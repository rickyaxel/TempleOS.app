import Foundation
import XCTest
import TempleCore
import PureSwift

/** Execute the untouched sources, including real event menus and chooser values. */
final class DiscoveredMenuProgramTests:XCTestCase {
    private func expectedPitch(_ hz:Double)->Double {
        let ona=Int(12*log2(32.0/440.0*hz)),note=440.0/32.0*pow(2,Double(ona)/12)
        let period=floor(Double(18333*65536/1000)/note)
        return 1193182/period
    }
    private func key(_ k:Kernel,_ ch:Int,_ down:Bool=true) {let (_,sc)=Keys.forChar(ch);k.post(.key(ch:ch,sc:sc,down:down))}
    private func tap(_ k:Kernel,_ ch:Int) {key(k,ch);key(k,ch,false)}
    private func advance(_ k:Kernel,_ ms:Int64) throws {_ = try advanceTo(k,ms);XCTAssertNil(k.exitMessage,k.console.plainText())}
    private func both(_ relative:String,_ answers:[Int64]=[],_ body:(Kernel,ParityEnv)throws->Void) throws {
        let out=REPO.appendingPathComponent("temple_os_swift/TempleCore/.build/distribution-support")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        for engine in [Engine.terry,.native] {
            let (k,env)=try bootProgram("C:/"+relative,engine,popups:answers)
            defer {k.terminate("test cleanup")}
            try body(k,env)
            if engine == .native {XCTAssertEqual(k.vm.instructionsExecuted,0)}
            let result:[String:Any] = ["path":"C:/"+relative,"engine":"\(engine)","instructions":k.vm.instructionsExecuted,"finished":k.finished,"frames":k.frameCount,"console":k.console.plainText(),"sounds":env.sound.map {[$0.0 as Any,$0.1 as Any]},"remainingPopupAnswers":env.popupAnswers]
            try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:out.appendingPathComponent(relative.replacingOccurrences(of:"/",with:"_")+"-\(engine).json"))
        }
    }
    func testDateTimeOutput() throws {
        try both("Demo/DateTime.HC") {k,_ in
            try advance(k,100);XCTAssertTrue(k.finished)
            for text in ["Hour:","Minute:","Second:","Day Name:","Month Name:"] {XCTAssertTrue(k.console.plainText().contains(text))}
            let text=k.console.plainText() as NSString
            let stamp=try NSRegularExpression(pattern:"[0-9]+/[0-9]+/[0-9]+ ([0-9]{2}):([0-9]{2}):([0-9]{2})").firstMatch(in:text as String,range:NSRange(location:0,length:text.length))
            let fields=try NSRegularExpression(pattern:"Hour:([0-9]{2}) Minute:([0-9]{2}) Second:([0-9]{2})").firstMatch(in:text as String,range:NSRange(location:0,length:text.length))
            let a=try XCTUnwrap(stamp),b=try XCTUnwrap(fields)
            func seconds(_ match:NSTextCheckingResult)->Int {(Int(text.substring(with:match.range(at:1)))!*60+Int(text.substring(with:match.range(at:2)))!)*60+Int(text.substring(with:match.range(at:3)))!}
            XCTAssertLessThanOrEqual(abs(seconds(a)-seconds(b)),1)
        }
    }
    func testRadixSortActuallySorts() throws {
        try both("Demo/RadixSort.HC") {k,_ in
            try advance(k,100);XCTAssertTrue(k.finished)
            let re=try NSRegularExpression(pattern:"(?m)^([0-9]+):([0-9]+)")
            let text=k.console.plainText() as NSString
            let values=re.matches(in:text as String,range:NSRange(location:0,length:text.length)).map {Int(text.substring(with:$0.range(at:2)))!}
            XCTAssertEqual(values.count,32);if values.count==32 {XCTAssertEqual(Array(values.prefix(16)).sorted(),Array(values.suffix(16)))}
        }
    }
    func testMessageLoopInputAndExit() throws {
        try both("Demo/MsgLoop.HC") {k,_ in
            try advance(k,100);XCTAssertFalse(k.finished);tap(k,97);try advance(k,200)
            XCTAssertTrue(k.console.plainText().contains("ARG1:00000061"),k.console.plainText())
            tap(k,Keys.CH_ESC);try advance(k,400);XCTAssertTrue(k.finished)
        }
    }
    func testHeldKeyAnimationAndRelease() throws {
        try both("Demo/KeyBitMap.HC") {k,_ in
            try advance(k,100);XCTAssertFalse(k.finished);key(k,105);try advance(k,200)
            let first=Array(UnsafeBufferPointer(start:k.published,count:640*480))
            try advance(k,350);let second=Array(UnsafeBufferPointer(start:k.published,count:640*480))
            XCTAssertNotEqual(first,second);XCTAssertGreaterThan(k.frameCount,5)
            key(k,105,false);try advance(k,500);XCTAssertTrue(k.finished)
        }
    }
    func testPullDownEventsCheckedStateAudioAndMenuPop() throws {
        try both("Demo/PullDownMenu.HC") {k,env in
            try advance(k,100)
            XCTAssertEqual(k.menuSnapshot.filter {$0.isDir}.map {$0.label},["File","Edit","Misc","Help"])
            func send(_ path:String,_ ms:Int64) throws {
                let m=try XCTUnwrap(k.menuSnapshot.first {$0.path==path})
                k.post(.raw(code:Int(m.msgCode),a1:m.a1,a2:m.a2));try advance(k,ms)
            }
            try send("Misc/Opt1",200);XCTAssertTrue(k.menuSnapshot.first {$0.path=="Misc/Opt1"}!.checked)
            try send("Misc/Opt2",300);XCTAssertTrue(k.console.plainText().contains("Option # 2"))
            try send("Misc/Opt1",400);XCTAssertFalse(k.menuSnapshot.first {$0.path=="Misc/Opt1"}!.checked)
            try send("Misc/Beep",1000);XCTAssertTrue(env.sound.contains {$0.1>0})
            try send("File/Exit",1200);XCTAssertTrue(k.finished);XCTAssertTrue(k.menuSnapshot.isEmpty)
        }
    }
    func testButtonMenuNestedFrequencyPopupAndCancel() throws {
        try both("Demo/DolDoc/MenuBttn.HC",[0,2,1,400,3,-1]) {k,env in
            try advance(k,1000);XCTAssertTrue(k.finished);XCTAssertTrue(env.popupAnswers.isEmpty)
            XCTAssertTrue(env.sound.contains {abs($0.1-expectedPitch(100))<1e-9});XCTAssertTrue(env.sound.contains {abs($0.1-expectedPitch(400))<1e-9});XCTAssertEqual(env.sound.last?.1,0)
        }
    }
    func testSpriteMenuValuesAndCancel() throws {
        try both("Demo/DolDoc/MenuSprite.HC",[50,100,200,-1]) {k,env in
            try advance(k,1000);XCTAssertTrue(k.finished);XCTAssertTrue(env.popupAnswers.isEmpty)
            for hz in [50.0,100,200] {XCTAssertTrue(env.sound.contains {abs($0.1-expectedPitch(hz))<1e-9})}
            XCTAssertEqual(env.sound.last?.1,0)
        }
    }
}
