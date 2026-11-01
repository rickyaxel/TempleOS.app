import Foundation

/// Safe host boundary for the shared DolDoc library and original TempleOS GR files.
public final class DocumentRuntime {
    private unowned let k: Kernel
    private var m: Arena { k.mem }
    public var capture = true
    private var capturing = false
    private var origins: [Int64:(Int,Int)] = [:]
    private var nextDynamic: Int64 = 0
    private struct MeshSprite {
        let id:Int, elems:Int64, dc:Int64, side:Int, body:Int, stride:Int
    }
    private var meshSprites:[Int:MeshSprite]=[:]
    private var drawingSprite=false
    private var spriteDoc:Int64=0, lastSpriteId = -1
    /// Original DocRecalc's time-based mesh rotations; DCs and pixels are reused.
    public func trackSprite(_ elems:Int64,_ id:Int,_ minX:Int64,_ maxX:Int64,_ minY:Int64,_ maxY:Int64) throws {
        try pruneSprites()
        if let task=k.current {spriteDoc=m.ld8(task.fsAddr+k.o.task("put_doc"));lastSpriteId=id}
        let mask=try k.callHolyC("SpriteTypeMask",elems)
        if mask & ((1<<24)|(1<<25)) == 0 {return}
        let size=try k.raster.spriteSize(elems)
        guard size>0,size<=4*1024*1024 else {throw VmKill("document mesh size")}
        let mx=max(abs(Double(minX)),abs(Double(maxX))),my=max(abs(Double(minY)),abs(Double(maxY)))
        var radius=max(1.0,sqrt(mx*mx+my*my)),at=elems,steps=0
        while steps<4096 {
            steps+=1;let type=Int(m.ld1(try m.check(at,1)) & 127)
            if type==0 || type>=30 {break}
            if type==24 || type==25 {
                let cls=type==24 ? "CSpriteMeshU8s" : "CSpritePtMeshU8s"
                let count=Int(Int32(truncatingIfNeeded:m.ld4(try m.check(at+Int64(k.o.member(cls,"vertex_cnt")),4))))
                guard count>=0,count<=100000 else {throw VmKill("document mesh vertices")}
                let start=at+Int64(k.o.member(cls,"u")),stride=k.o.cls("CD3I32").size
                _ = try m.check(start,count*stride)
                func coord(_ p:Int64,_ offset:Int)->Double {Double(Int32(truncatingIfNeeded:m.ld4(Int(p)+offset)))}
                let shift=type==25 ? [coord(at,k.o.member(cls,"x")),coord(at,k.o.member(cls,"y")),coord(at,k.o.member(cls,"z"))] : [0,0,0]
                for i in 0..<count {
                    let p=start+Int64(i*stride),x=coord(p,0)+shift[0],y=coord(p,4)+shift[1],z=coord(p,8)+shift[2]
                    radius=max(radius,sqrt(x*x+y*y+z*z))
                }
            }
            let length=try k.raster.spriteElemSize(at);guard length>0 else {throw VmKill("document mesh element")};at+=length
        }
        guard steps<4096,radius.isFinite,radius<=500 else {throw VmKill("document mesh bounds")}
        let side=(Int(ceil(radius))*2+10) & ~7
        try k.console.resizeSprite(id,side)
        let copy=try m.malloc(size);m.writeBytes(copy,m.readBytes(try m.check(elems,Int(size)),Int(size)))
        var dc:Int64=0
        do {
            dc=try k.callHolyC("DCNew",Int64(side),Int64(side),0,0)
            _ = try k.callHolyC("DCDepthBufAlloc",dc)
            let stride=Int(m.ld4(Int(dc)+k.o.dc("width_internal")))
            let body=try m.check(m.ld8(Int(dc)+k.o.dc("body")),stride*side)
            let sprite=MeshSprite(id:id,elems:Int64(copy),dc:dc,side:side,body:body,stride:stride)
            meshSprites[id]=sprite;try draw(sprite)
        } catch {if dc != 0 {_ = try? k.callHolyC("DCDel",dc)};try? m.free(Int64(copy));meshSprites.removeValue(forKey:id);throw error}
    }
    private func draw(_ sp:MeshSprite) throws {
        if drawingSprite {return};drawingSprite=true;defer {drawingSprite=false}
        let seconds=Double(k.now())/1e9,r=m.ld8(Int(sp.dc)+k.o.dc("r"))
        m.fill(sp.body,255,sp.stride*sp.side)
        _ = try k.callHolyC("DCDepthBufRst",sp.dc)
        _ = try k.callHolyC("Mat4x4IdentEqu",r)
        _ = try k.callHolyC("Mat4x4RotZ",r,bits(seconds*3.1))
        _ = try k.callHolyC("Mat4x4RotY",r,bits(seconds*1.9))
        _ = try k.callHolyC("Mat4x4RotX",r,bits(seconds))
        m.st8(Int(sp.dc)+k.o.dc("flags"),m.ld8(Int(sp.dc)+k.o.dc("flags"))|0x100)
        m.st4(Int(sp.dc)+k.o.dc("x"),Int64(sp.side/2));m.st4(Int(sp.dc)+k.o.dc("y"),Int64(sp.side/2));m.st4(Int(sp.dc)+k.o.dc("z"),0x3fffffff)
        _ = try k.callHolyC("Sprite3",sp.dc,0,0,0,sp.elems,0)
        k.console.updateSprite(sp.id) {pixels in for y in 0..<sp.side {for x in 0..<sp.side {pixels[y*sp.side+x]=UInt8(truncatingIfNeeded:self.m.ld1(sp.body+y*sp.stride+x))}}}
    }
    private func pruneSprites() throws {
        for sp in meshSprites.values.filter({!k.console.hasSprite($0.id)}) {
            _ = try k.callHolyC("DCDel",sp.dc);try m.free(sp.elems);meshSprites.removeValue(forKey:sp.id)
        }
    }
    private func refreshSprites() throws {
        if meshSprites.isEmpty {return}
        try pruneSprites()
        let saved=k.current;if let task=k.mainTask {k.setCurrent(task)}
        defer {if let saved=saved {k.setCurrent(saved)}}
        for sp in meshSprites.values {try draw(sp)}
    }
    public func refreshDynamic() throws {
        if k.now() < nextDynamic {return};nextDynamic=k.now()+33_000_000
        guard let task=k.mainTask, task.state != Kernel.DEAD else {return}
        try refreshSprites()
        let doc=m.ld8(task.fsAddr+k.o.task("put_doc"))
        guard let origin=origins[doc] else {return}
        var entry=m.ld8(try m.check(doc,k.prog.classes["CDoc"]!.size)),steps=0
        while entry != doc && entry != 0 && steps<2000 {
            steps+=1;let ptr=try m.check(entry,k.prog.classes["CDocEntry"]!.size)
            let callback=m.ld8(ptr+k.o.member("CDocEntry","tag_cb"))
            if callback != 0 {
                let saved=k.current;k.setCurrent(task)
                let text:Int64
                do {defer {if let saved=saved {k.setCurrent(saved)}};text=try k.vm.callFunction(task,callback,[doc,entry,Int64(task.fsAddr)])}
                if text != 0 {defer {try? m.free(text)};k.console.updateField(origin.0+Int(m.ld4(ptr+k.o.member("CDocEntry","y"))),origin.1+Int(m.ld4(ptr+k.o.member("CDocEntry","x"))),try m.readStrBytes(text),2)}
            }
            entry=m.ld8(ptr)
        }
    }
    public func canExport()->Bool {
        guard let task=k.mainTask else {return false};return k.finished && m.ld8(task.fsAddr+k.o.task("put_doc")) != 0
    }
    /// Export an ended program's actual DolDoc, including original-format binary sprite attachments.
    public func export(_ path:String) throws {
        guard canExport(),let task=k.mainTask else {throw FsError("Program document is still running")}
        guard let target=Paths.normalize("C:/Home",path) else {throw FsError("Invalid path")}
        let doc=try m.check(m.ld8(task.fsAddr+k.o.task("put_doc")),k.prog.classes["CDoc"]!.size)
        let name=doc+k.o.member("CDoc","filename")+k.o.member("CEdFileName","name")
        let capacity=k.prog.classes["CEdFileName"]!.members["name"]!.type.size,bytes=latin1(target)
        if bytes.count>=capacity {throw FsError("Path is too long")}
        let saved=m.readBytes(name,capacity);defer {m.writeBytes(name,saved)}
        m.writeBytes(name,bytes);m.st1(name+bytes.count,0)
        try k.callHolyC("DocWrite",Int64(doc),0,task:k.adamTask)
    }
    public init(_ kernel: Kernel) { k = kernel }
    private func string(_ bytes: [UInt8]) throws -> Int64 {
        let p = try m.malloc(Int64(bytes.count + 1))
        m.writeBytes(p, bytes); m.st1(p + bytes.count, 0); return Int64(p)
    }
    public func output(_ bytes:[UInt8]) throws {
        if !capture || capturing || bytes.isEmpty {return}
        guard let task=k.current else {return}
        let base=try m.check(Int64(task.fsAddr),k.prog.classes["CTask"]!.size)
        let doc=m.ld8(base+k.o.task("put_doc"));if doc==0 {return}
        capturing=true;var st:Int64=0
        defer {if st != 0 {try? m.free(st)};capturing=false}
        func detach() {m.st8(base+k.o.task("put_doc"),0);if m.ld8(base+k.o.task("display_doc"))==doc {m.st8(base+k.o.task("display_doc"),0)};origins.removeValue(forKey:doc)}
        do {_ = try m.check(doc,k.prog.classes["CDoc"]!.size);st=try string(bytes);try k.callHolyC("MobileDocAppend",doc,st)}
        catch is VmFault {detach()} catch is VmUncaught {detach()}
    }
    public func register(_ table: NativeTable) {
        func reg(_ name: String, _ body: @escaping (HTask, Int, Int) throws -> Int64) {
            table.add(ClosureNative(name, body))
        }
        reg("MobileVgaPort") {t,a,_ in try self.k.vga.port(t.st[a],t.st[a+1]);return 0}
        reg("MobileVgaSync") {_,_,_ in try self.k.vga.sync();return 0}
        reg("MobileDocEmit") {t,a,_ in
            let data=try self.m.readStrBytes(t.st[a]),clear=latin1(data).contains("$CL$")
            let fs=self.m.ld8(self.k.o.fsGlobal),doc=fs == 0 ? 0 : self.m.ld8(Int(fs)+self.k.o.task("put_doc"))
            if clear && doc==self.spriteDoc && self.k.console.hasSprite(self.lastSpriteId) {self.k.console.writeKeepingSprites(data)}
            else {self.k.console.write(data)}
            if clear && fs != 0 {self.origins[doc]=(0,0)}
            return 0
        }
        reg("MobileDocOrigin") {t,a,_ in if self.origins.count>=64 {self.origins.removeAll()};self.origins[t.st[a]]=self.k.console.cursorCell();return 0}
        reg("MobileDocForget") {t,a,_ in self.origins.removeValue(forKey:t.st[a]);return 0}
        reg("MobileDocCapture") {t,a,_ in let old=self.capture;self.capture=t.st[a] != 0;return old ? 1 : 0}
        reg("MobileDocFields") {t,a,_ in
            guard let cls=self.k.prog.classes[try self.m.readStr(t.st[a])] else {return try self.string([0])}
            var out: [UInt8] = []
            func text(_ s: String) {out += latin1(s);out.append(0)}
            for field in cls.memberList {
                guard let fmt=field.format else {continue}
                let type=field.type, kind: Int
                if let array=type as? ArrType, array.elem.size == 1 {kind=2}
                else if type is F64Type {kind=1}
                else if type is IntType {kind=0}
                else {continue}
                text("\(field.offset),\(kind),\(type.size)")
                let format=latin1(fmt)
                var label=field.name
                if let begin=format.range(of:"A=\"") {
                    let suffix=format[begin.upperBound...]
                    let value=String(suffix.prefix { $0 != "%" && $0 != "\"" }).replacingOccurrences(of:"\u{1f}",with:" ").trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:":"))
                    if !value.isEmpty {label=value}
                }
                text(label);out += fmt;out.append(0)
            }
            out.append(0);return try self.string(out)
        }
        reg("MobileDocValue") {t,a,_ in
            if t.st[a] == 0 {return t.st[a+1]}
            let expr=try self.m.readStr(t.st[a]).trimmingCharacters(in:.whitespacesAndNewlines)
            if let value=Int64(expr) {return value}
            if expr.hasPrefix("0x"), let value=UInt64(expr.dropFirst(2),radix:16) {return Int64(bitPattern:value)}
            if let value=self.k.prog.uiConstants[expr] {return value}
            if let raw=self.k.defines.value[expr] {
                let ts=raw.filter {$0.text != "(" && $0.text != ")"}
                if ts.count == 1 && (ts[0].kind == .INT || ts[0].kind == .CHAR) {return ts[0].ival}
                if ts.count == 2 && ts[0].text == "-" && ts[1].kind == .INT {return 0 &- ts[1].ival}
            }
            if let g=self.k.prog.globals[expr] as? GlobalSym {return self.m.ld8(g.addr)}
            return t.st[a+1]
        }
        reg("MobileGRRead") {t,a,_ in
            guard let path=try self.grPath(t,self.m.readStr(t.st[a])),
                  let bytes=self.k.env.fs?.readFile(path) ?? self.k.env.fs?.readFile(path.hasSuffix(".Z") ? String(path.dropLast(2)) : path) else {return 0}
            return try self.install(GRImage.decodeFile(bytes,outerArchive:path.hasSuffix(".Z")))
        }
        reg("MobileGRWrite") {t,a,_ in
            guard let path=try self.grPath(t,self.m.readStr(t.st[a])), let fs=self.k.env.fs else {return 0}
            let data=try self.image(t.st[a+1]).encode()
            let bytes=path.hasSuffix(".Z") ? TempleArc.store(data) : data
            try fs.writeFile(path,bytes);return Int64(bytes.count)
        }
        reg("DCScrnCapture") {_,_,_ in
            let dc=try self.k.callHolyC("DCNew",640,480,0,0)
            let ptr=try self.m.check(self.m.ld8(Int(dc)+self.k.o.dc("body")),640*480)
            self.m.writeBytes(ptr,try self.k.captureScreen());return dc
        }
        reg("ACDDefGet") {t,a,_ in
            guard let data=try self.k.dictionary.get(self.m.readStr(t.st[a]),Int(t.st[a+1])) else {return 0};return try self.string(data)
        }
        reg("ACDDefsGet") {t,a,_ in
            guard let data=try self.k.dictionary.get(self.m.readStr(t.st[a]),all:true) else {return 0};return try self.string(data)
        }
        reg("ACAlloc") {t,a,_ in Int64(try self.m.calloc(t.st[a]))}
    }
    private func grPath(_ task: HTask,_ name: String) throws -> String? {
        Paths.normalize(try k.curDir(task), Paths.name(name).contains(".") ? name : name + ".GR.Z")
    }
    private func install(_ im: GRImage) throws -> Int64 {
        let dc=Int(try k.callHolyC("DCNew",Int64(im.width),Int64(im.height),0,0))
        let stride=Int(m.ld4(dc+k.o.dc("width_internal")))
        let body=try m.check(m.ld8(dc+k.o.dc("body")),stride*im.height)
        for y in 0..<im.height {m.writeBytes(body+y*stride,Array(im.body[(y*im.stride)..<(y*im.stride+im.width)]))}
        if let palette=im.palette {m.writeBytes(dc+k.o.dc("palette"),palette)}
        return Int64(dc)
    }
    private func image(_ addr: Int64) throws -> GRImage {
        let dc=try m.check(addr,k.prog.classes["CDC"]!.size)
        let w=Int(m.ld4(dc+k.o.dc("width"))), h=Int(m.ld4(dc+k.o.dc("height"))), s=Int(m.ld4(dc+k.o.dc("width_internal")))
        guard w > 0, h > 0, w <= 16384, h <= 16384, s >= w, s <= GRImage.maxBody/h else {throw VmKill("GR geometry limit")}
        var raw=m.readBytes(dc,32);raw[28]=2;raw[29]=0;raw[30]=0;raw[31]=0
        raw += m.readBytes(dc+k.o.dc("palette"),128)
        raw += m.readBytes(try m.check(m.ld8(dc+k.o.dc("body")),s*h),s*h)
        return try GRImage.decode(raw)
    }
}
