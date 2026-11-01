import Foundation

/// Reads the exact data template saved by Terry's Psalmody editor; never compiles arbitrary source.
public final class MusicScore {
    private unowned let k:Kernel
    private var allocations:[Int:[Int64]]=[:]
    public init(_ k:Kernel) {self.k=k}
    public func open(_ task:HTask,_ path:String) throws -> Int64 {
        guard let native=k.native,!native.fileCurrent(k,path) else {return 0}
        guard let raw=k.env.fs?.readFile(path) else {throw CompileError("Song not found: \(path)")}
        if raw.count>1_048_576 {throw CompileError("Song size limit")}
        let source=SourceFile.parse(path,raw)
        if !source.bins.isEmpty {throw CompileError("Native score data cannot contain source attachments")}
        let tokens=try Lexer(nil).tokenize(source,Paths.parent(path));var at=0
        func expect(_ text:String) throws {guard at<tokens.count,tokens[at].text==text else {throw CompileError("Native score requires the original Psalmody song template",path,at<tokens.count ? tokens[at].line : 1)};at+=1}
        func words(_ text:String) throws {for word in text.components(separatedBy:" ") {try expect(word)}}
        func number() throws -> Double {
            guard at<tokens.count else {throw CompileError("Missing score setting")};let token=tokens[at];at+=1
            let value:Double
            if token.kind == .FLOAT {value=token.fval} else if token.kind == .INT {value=Double(token.ival)} else {throw CompileError("Invalid score setting")}
            if !value.isFinite || value<=0 || value>100 {throw CompileError("Score setting out of range")};return value
        }
        func text() throws -> [UInt8] {
            guard at<tokens.count,tokens[at].kind == .STR else {throw CompileError("Expected score text")}
            var out:[UInt8]=[];while at<tokens.count && tokens[at].kind == .STR {out += tokens[at].bytes!;at+=1};return out
        }
        try words("U0 Song ( ) { Fs -> task_end_cb = & SndTaskEndCB ; MusicSettingsRst ; music . tempo =")
        let tempo=try number();try words("; music . stacatto_factor =");let staccato=try number()
        try words("; try { while ( ! ScanKey ) {")
        var events:[([UInt8],[UInt8]?)]=[]
        while at<tokens.count && tokens[at].text=="Play" {
            if events.count>=2048 {throw CompileError("Score event limit")}
            try words("Play (");let notes=try text();var lyrics:[UInt8]?
            if at<tokens.count && tokens[at].text=="," {at+=1;lyrics=try text()}
            try words(") ;");events.append((notes,lyrics))
        }
        try words("} } catch PutExcept ; Snd ; } Song ;")
        if at>=tokens.count || tokens[at].kind != .EOF || events.isEmpty {throw CompileError("Unsupported score source")}
        func alloc(_ size:Int64) throws -> Int {let p=try k.mem.calloc(size);allocations[task.id,default:[]].append(Int64(p));return p}
        func string(_ bytes:[UInt8]?) throws -> Int64 {guard let bytes=bytes else {return 0};let p=try alloc(Int64(bytes.count+1));k.mem.writeBytes(p,bytes);return Int64(p)}
        let ptr=try alloc(Int64(24+16*events.count));k.mem.st8(ptr,bits(tempo));k.mem.st8(ptr+8,bits(staccato));k.mem.st8(ptr+16,Int64(events.count))
        for (i,event) in events.enumerated() {k.mem.st8(ptr+24+16*i,try string(event.0));k.mem.st8(ptr+32+16*i,try string(event.1))}
        return Int64(ptr)
    }
    public func close(_ task:HTask) {for ptr in allocations.removeValue(forKey:task.id)?.reversed() ?? [] {try? k.mem.free(ptr)}}
}
