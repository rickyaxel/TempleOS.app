import Foundation

/// Sandboxed source tokenization/file enumeration and wakeups for compiled command-server jobs.
public final class SourceServices {
    private unowned let k:Kernel
    private var m:Arena {k.mem}
    private lazy var scores=MusicScore(k)
    private final class Scanner {let tokens:[Token];let owner:Int;var index = -1;var owned:[Int64]=[];init(_ tokens:[Token],_ owner:Int) {self.tokens=tokens;self.owner=owner}}
    private var scanners:[Int64:Scanner]=[:]
    private var sourceSessions:[Int64:(Int,ChunkSource)]=[:]
    private var jobHeads:[Int64:Int64]=[:]
    public init(_ kernel:Kernel) {k=kernel}
    private func string(_ data:[UInt8]) throws -> Int64 {
        let p=try m.malloc(Int64(data.count+1));m.writeBytes(p,data);m.st1(p+data.count,0);return Int64(p)
    }
    public func register(_ table:NativeTable) {
        func reg(_ name:String,_ body:@escaping(HTask,Int,Int)throws->Int64) {table.add(ClosureNative(name,compilerErrorsAsExceptions(body)))}
        reg("MobileScoreOpen") {t,a,_ in guard let path=try Paths.normalize(self.k.curDir(t),self.m.readStr(t.st[a])) else {throw CompileError("Invalid score path")};return try self.scores.open(t,path)}
        reg("MobileScoreClose") {t,_,_ in self.scores.close(t);return 0}
        reg("Call") {t,a,_ in try self.k.vm.callFunction(t,t.st[a],[])}
        reg("MobileJobRegister") {t,a,_ in self.jobHeads[t.st[a]]=t.st[a+1];return 0}
        reg("MobileSourceOpen") {t,a,_ in
            if self.sourceSessions.count>=16 {throw VmKill("source session limit")}
            guard let path=try Paths.normalize(self.k.curDir(t),self.m.readStr(t.st[a])),let data=self.k.env.fs?.readFile(path) else {throw VmFault(chCode("Compiler"),"Source not found")}
            let session:ChunkSource
            if let native=self.k.native {session=try native.fileSession(self.k,path)}
            else {session=try self.k.prog.session(SourceFile.parse(path,data),Paths.parent(path),self.k.vfsProvider(),self.k.defines)}
            let handle=Int64(try self.m.calloc(8));self.sourceSessions[handle]=(t.id,session);return handle
        }
        reg("MobileSourceNext") {t,a,_ in guard let source=self.sourceSessions[t.st[a]]?.1,let f=try source.next() else {return 0};return self.k.prog.funcPtr(f)}
        reg("MobileSourceClose") {t,a,_ in if self.sourceSessions.removeValue(forKey:t.st[a]) != nil {try self.m.free(t.st[a])};return 0}
        reg("KbdMsEvtTime") {_,_,_ in self.k.lastInteractionNanos}
        reg("PostMsg") {t,a,_ in
            guard let target=self.k.taskByFs(t.st[a]) else {return 0}
            let code=Int(t.st[a+1])
            if code == -2 {self.k.enqueueTo(target,Kernel.Msg(2,t.st[a+2],t.st[a+3]));self.k.enqueueTo(target,Kernel.Msg(3,t.st[a+2],t.st[a+3] | Keys.SCF_KEY_UP))}
            else {self.k.enqueueTo(target,Kernel.Msg(code,t.st[a+2],t.st[a+3]))};return 0
        }
        reg("MobileSymbol") {t,a,_ in guard let f=self.k.prog.globals[try self.m.readStr(t.st[a])] as? FuncSym else {return 0};return self.k.prog.funcPtr(f)}
        reg("MobileJobWait") {t,_,_ in t.resumed=false;self.k.block(t,Kernel.SUSPENDED);return 0}
        reg("MobileJobWake") {t,a,_ in if let target=self.k.taskByFs(t.st[a]),target.state==Kernel.SUSPENDED {target.state=Kernel.READY;target.resumed=false};return 0}
        reg("MobileTaskState") {t,a,_ in Int64(self.k.taskByFs(t.st[a])?.state ?? Kernel.DEAD)}
        reg("CmpCtrlNew") {t,a,_ in
            if self.scanners.count>=64 {throw VmKill("source scanner limit")}
            let ptr=Int64(try self.m.calloc(Int64(self.k.prog.classes["CCmpCtrl"]!.size)))
            let tokens=try Lexer(self.k.vfsProvider(),Ref(self.k.defines.value)).tokenize(SourceFile.parse("C:/Home/Lex.HC",self.m.readStrBytes(t.st[a])),self.k.curDir(t))
            self.scanners[ptr]=Scanner(tokens,t.id);return ptr
        }
        reg("CmpCtrlDel") {t,a,_ in if let s=self.scanners.removeValue(forKey:t.st[a]) {for p in s.owned {try self.m.free(p)}};try self.m.free(t.st[a]);return 0}
        reg("Lex") {t,a,_ in guard let s=self.scanners[t.st[a]] else {throw VmFault(chCode("Lex"),"Unknown scanner")};s.index+=1;return try self.token(t.st[a],s)}
        reg("LexExtStr") {t,a,_ in
            guard let s=self.scanners[t.st[a]] else {throw VmFault(chCode("Lex"),"Unknown scanner")}
            var out:[UInt8]=[]
            while s.index>=0 && s.index<s.tokens.count && s.tokens[s.index].kind == .STR {out += s.tokens[s.index].bytes!;s.index+=1}
            let ptr=try self.string(out);s.owned.append(ptr);_ = try self.token(t.st[a],s);return ptr
        }
        reg("FilesFind") {t,a,_ in try self.files(t,self.m.readStr(t.st[a]),t.st[a+1])}
        reg("DirTreeDel") {t,a,_ in
            var p=t.st[a],n=0
            while p != 0 && n<4096 {n+=1;let next=self.m.ld8(Int(p)+self.k.o.member("CDirEntry","next"));try self.m.free(self.m.ld8(Int(p)+self.k.o.member("CDirEntry","full_name")));try self.m.free(p);p=next};return 0
        }
        reg("FileOcc") {t,a,_ in
            guard let path=try Paths.normalize(self.k.curDir(t),self.m.readStr(t.st[a+1])), let data=self.k.env.fs?.readFile(path) else {return 0}
            let needle=try self.m.readStr(t.st[a]);if needle.isEmpty {return 0}
            return Int64(latin1(data).components(separatedBy:needle).count-1)
        }
        reg("MobileTaskCaller") {t,a,_ in
            guard let target=self.k.taskByFs(t.st[a]) else {return 0}
            let n=Int(t.st[a+1]);return n>=0 && n<target.depth ? Int64(target.fRet[target.depth-n-1]) : 0
        }
    }
    public func taskGone(_ task:HTask) {
        scores.close(task)
        for(handle,entry) in sourceSessions where entry.0==task.id {sourceSessions.removeValue(forKey:handle);try? m.free(handle)}
        for(handle,scanner) in scanners where scanner.owner==task.id {scanners.removeValue(forKey:handle);for p in scanner.owned {try? m.free(p)};try? m.free(handle)}
        guard let head=jobHeads.removeValue(forKey:Int64(task.fsAddr)) else {return}
        do {
            var nodes=Set<Int64>(),ptr=m.ld8(Int(head)),count=0
            while ptr != head && ptr != 0 && count<4096 {count+=1;nodes.insert(ptr);ptr=m.ld8(try m.check(ptr,k.prog.classes["MobileJob"]!.size))}
            let active=m.ld8(Int(head)+k.o.member("MobileJob","fp"));if active != 0 {nodes.insert(active)}
            for job in nodes {let base=try m.check(job,k.prog.classes["MobileJob"]!.size);for i in 0..<8 {let str=m.ld8(base+k.o.member("MobileJob","strings")+8*i);if str != 0 {try? m.free(str)}};try m.free(job)}
            try m.free(head)
        } catch {}
    }
    private func token(_ ptr:Int64,_ scanner:Scanner) throws -> Int64 {
        let tk=scanner.index>=0 && scanner.index<scanner.tokens.count ? scanner.tokens[scanner.index] : nil
        let base=try m.check(ptr,k.prog.classes["CCmpCtrl"]!.size),code:Int64
        switch tk?.kind {case .IDENT:code=256;case .STR:code=257;case .INT:code=258;case .CHAR:code=259;case .FLOAT:code=260;case .PUNCT:code=Int64(tk!.text.unicodeScalars.first?.value ?? 0);default:code=0}
        m.st8(base+k.o.member("CCmpCtrl","token"),code)
        m.st8(base+k.o.member("CCmpCtrl","cur_i64"),tk?.ival ?? 0)
        m.st8(base+k.o.member("CCmpCtrl","cur_f64"),bits(tk?.fval ?? 0))
        let data=tk?.bytes ?? latin1(tk?.text ?? ""),text=try string(data)
        scanner.owned.append(text);m.st8(base+k.o.member("CCmpCtrl","cur_str"),text)
        m.st8(base+k.o.member("CCmpCtrl","cur_str_len"),Int64(data.count));return code
    }
    private func files(_ task:HTask,_ mask:String,_ flags:Int64) throws -> Int64 {
        let split=mask.lastIndex(of:"/")
        let parent=split.map {String(mask[..<$0])} ?? "."
        guard let dir=try Paths.normalize(k.curDir(task),parent) else {return 0}
        let name=split.map {String(mask[mask.index(after:$0)...])} ?? mask
        let pattern=name.hasSuffix(".Z") ? String(name.dropLast(2)) : name
        let regex="^"+pattern.components(separatedBy:"*").map {$0.components(separatedBy:"?").map {NSRegularExpression.escapedPattern(for:$0)}.joined(separator:".")}.joined(separator:".*")+"$"
        var found:[FsEntry]=[]
        func walk(_ root:String,_ depth:Int) {
            if depth>32 || found.count>=4096 {return}
            for e in k.env.fs?.list(root) ?? [] {
                let name=e.name.hasSuffix(".Z") ? String(e.name.dropLast(2)) : e.name
                if name.range(of:regex,options:[.regularExpression,.caseInsensitive]) != nil && (flags&0x400==0 || e.isDir) && (flags&0x800==0 || !e.isDir) {found.append(e)}
                if e.isDir && flags&1 != 0 {walk(e.path,depth+1)}
            }
        }
        walk(dir,0);var head:Int64=0,last:Int64=0
        for e in found.sorted(by:{$0.path.lowercased()<$1.path.lowercased()}) {
            let p=try m.calloc(Int64(k.prog.classes["CDirEntry"]!.size))
            m.writeBytes(p+k.o.member("CDirEntry","name"),Array(latin1(e.name).prefix(37)))
            m.st8(p+k.o.member("CDirEntry","full_name"),try string(latin1(e.path)))
            m.st8(p+k.o.member("CDirEntry","size"),e.size);m.st2(p+k.o.member("CDirEntry","attr"),e.isDir ? 16 : 0)
            if last != 0 {m.st8(Int(last)+k.o.member("CDirEntry","next"),Int64(p))} else {head=Int64(p)}
            last=Int64(p)
        }
        return head
    }
}
