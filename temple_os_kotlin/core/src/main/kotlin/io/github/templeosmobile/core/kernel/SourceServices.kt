package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*

/** Sandboxed source tokens, file enumeration and task job wakeups. No bytecode fallback in native mode. */
class SourceServices(private val k:Kernel) {
    private val m get()=k.mem
    private val scores by lazy {MusicScore(k)}
    private class Scanner(val tokens:List<Token>,val owner:Int,var index:Int=-1,val owned:MutableList<Long> = ArrayList())
    private val scanners=HashMap<Long,Scanner>()
    private val sourceSessions=HashMap<Long,Pair<Int,ChunkSource>>()
    private val jobHeads=HashMap<Long,Long>()
    private fun str(data:ByteArray):Long {val p=m.malloc(data.size+1L);m.writeBytes(p,data);m.st1(p+data.size,0);return p.toLong()}
    fun register(nt:NativeTable) {
        fun reg(name:String,fn:NativeFn) {nt.add(object:Native(name){override fun call(t:Task,base:Int,argc:Int):Long=try {fn.call(t,base,argc)} catch(e:CompileError) {throw VmFault(COMPILER,e.message ?: "Compiler error")} catch(e:FsError) {throw VmFault(chCode("File"),e.message ?: "File error")}})}
        reg("MobileScoreOpen") {t,a,_->scores.open(t,Paths.normalize(k.curDir(t),m.readStr(t.st[a])) ?: throw CompileError("Invalid score path"))}
        reg("MobileScoreClose") {t,_,_->scores.close(t);0}
        reg("Call") {t,a,_->k.vm.callFunction(t,t.st[a])}
        reg("MobileJobRegister") {t,a,_->jobHeads[t.st[a]]=t.st[a+1];0}
        reg("MobileSourceOpen") {t,a,_->
            if(sourceSessions.size>=16) throw VmKill("source session limit")
            val path=Paths.normalize(k.curDir(t),m.readStr(t.st[a])) ?: throw VmFault(COMPILER,"Invalid source path")
            val data=k.env.fs?.readFile(path) ?: throw VmFault(COMPILER,"Source not found: $path")
            val session=if(k.isNative) k.native!!.fileSession(k,path) else k.prog.session(SourceFile.parse(path,data),Paths.parent(path),k.vfsProvider(),k.defines)
            val handle=m.calloc(8).toLong();sourceSessions[handle]=t.id to session;handle
        }
        reg("MobileSourceNext") {t,a,_->sourceSessions[t.st[a]]?.second?.next()?.let {k.prog.funcPtr(it)} ?: 0}
        reg("MobileSourceClose") {t,a,_->if(sourceSessions.remove(t.st[a])!=null) m.free(t.st[a]);0}
        reg("KbdMsEvtTime") {_,_,_->k.lastInteractionNanos}
        reg("PostMsg") {t,a,_->
            val target=k.taskByFs(t.st[a]) ?: return@reg 0
            val code=t.st[a+1].toInt()
            if(code == -2) {k.enqueueTo(target,Kernel.Msg(2,t.st[a+2],t.st[a+3]));k.enqueueTo(target,Kernel.Msg(3,t.st[a+2],t.st[a+3] or Keys.SCF_KEY_UP))}
            else k.enqueueTo(target,Kernel.Msg(code,t.st[a+2],t.st[a+3]));0
        }
        reg("MobileSymbol") {t,a,_->(k.prog.globals[m.readStr(t.st[a])] as? FuncSym)?.let {k.prog.funcPtr(it)} ?: 0}
        reg("MobileJobWait") {t,_,_->t.resumed=false;k.block(t,Kernel.SUSPENDED);0}
        reg("MobileJobWake") {t,a,_->k.taskByFs(t.st[a])?.let {if(it.state==Kernel.SUSPENDED) {it.state=Kernel.READY;it.resumed=false}};0}
        reg("MobileTaskState") {t,a,_->(k.taskByFs(t.st[a])?.state ?: Kernel.DEAD).toLong()}
        reg("CmpCtrlNew") {t,a,_->
            if(scanners.size>=64) throw VmKill("source scanner limit")
            val ptr=m.calloc(k.prog.classes["CCmpCtrl"]!!.size.toLong()).toLong()
            val tokens=Lexer(k.vfsProvider(),HashMap(k.defines)).tokenize(SourceFile.parse("C:/Home/Lex.HC",m.readStrBytes(t.st[a])),k.curDir(t))
            scanners[ptr]=Scanner(tokens,t.id);ptr
        }
        reg("CmpCtrlDel") {t,a,_->scanners.remove(t.st[a])?.owned?.forEach {m.free(it)};m.free(t.st[a]);0}
        reg("Lex") {t,a,_->val s=scanners[t.st[a]] ?: throw VmFault(chCode("Lex"),"Unknown scanner");s.index++;token(t.st[a],s)}
        reg("LexExtStr") {t,a,_->
            val s=scanners[t.st[a]] ?: throw VmFault(chCode("Lex"),"Unknown scanner")
            val out=java.io.ByteArrayOutputStream()
            while(s.tokens.getOrNull(s.index)?.kind==T.STR) {out.write(s.tokens[s.index].bytes!!);s.index++}
            val p=str(out.toByteArray());s.owned.add(p);token(t.st[a],s);p
        }
        reg("FilesFind") {t,a,_->files(t,m.readStr(t.st[a]),t.st[a+1])}
        reg("DirTreeDel") {t,a,_->var p=t.st[a];var n=0
            while(p!=0L && n++<4096) {val next=m.ld8(p.toInt()+k.o.member("CDirEntry","next"));m.free(m.ld8(p.toInt()+k.o.member("CDirEntry","full_name")));m.free(p);p=next};0}
        reg("FileOcc") {t,a,_->
            val path=Paths.normalize(k.curDir(t),m.readStr(t.st[a+1])) ?: return@reg 0
            val bytes=k.env.fs?.readFile(path) ?: return@reg 0
            val needle=m.readStr(t.st[a]);if(needle.isEmpty()) return@reg 0
            Regex(Regex.escape(needle)).findAll(latin1(bytes)).count().toLong()
        }
        reg("MobileTaskCaller") {t,a,_->
            val target=k.taskByFs(t.st[a]) ?: return@reg 0
            val n=t.st[a+1].toInt();if(n !in 0 until target.depth) 0 else target.fRet[target.depth-n-1].toLong()
        }
    }
    fun taskGone(t:Task) {
        scores.close(t)
        for((handle,entry) in sourceSessions.toList()) if(entry.first==t.id) {sourceSessions.remove(handle);runCatching {m.free(handle)}}
        for((handle,scanner) in scanners.toList()) if(scanner.owner==t.id) {scanners.remove(handle);scanner.owned.forEach {runCatching {m.free(it)}};runCatching {m.free(handle)}}
        val head=jobHeads.remove(t.fsAddr.toLong()) ?: return
        runCatching {
            val nodes=LinkedHashSet<Long>();var ptr=m.ld8(head.toInt());var count=0
            while(ptr!=head && ptr!=0L && count++<4096) {nodes.add(ptr);ptr=m.ld8(m.check(ptr,k.prog.classes["MobileJob"]!!.size))}
            val active=m.ld8(head.toInt()+k.o.member("MobileJob","fp"));if(active!=0L) nodes.add(active)
            for(job in nodes) {val base=m.check(job,k.prog.classes["MobileJob"]!!.size);for(i in 0..7) {val str=m.ld8(base+k.o.member("MobileJob","strings")+8*i);if(str!=0L) runCatching {m.free(str)}};m.free(job)}
            m.free(head)
        }
    }
    private fun token(ptr:Long,s:Scanner):Long {
        val tk=s.tokens.getOrNull(s.index);val base=m.check(ptr,k.prog.classes["CCmpCtrl"]!!.size)
        val code=when(tk?.kind) {T.IDENT->256L;T.STR->257L;T.INT->258L;T.CHAR->259L;T.FLOAT->260L;T.PUNCT->tk.text.firstOrNull()?.code?.toLong() ?: 0;else->0}
        m.st8(base+k.o.member("CCmpCtrl","token"),code)
        m.st8(base+k.o.member("CCmpCtrl","cur_i64"),tk?.ival ?: 0)
        m.st8(base+k.o.member("CCmpCtrl","cur_f64"),(tk?.fval ?: 0.0).toRawBits())
        val data=tk?.bytes ?: latin1(tk?.text ?: "")
        val text=str(data);s.owned.add(text);m.st8(base+k.o.member("CCmpCtrl","cur_str"),text)
        m.st8(base+k.o.member("CCmpCtrl","cur_str_len"),data.size.toLong());return code
    }
    private fun files(t:Task,mask:String,flags:Long):Long {
        val split=mask.lastIndexOf('/')
        val dir=Paths.normalize(k.curDir(t),if(split<0) "." else mask.substring(0,split)) ?: return 0
        val pattern=mask.substring(split+1).removeSuffix(".Z")
        val regex=Regex("^"+pattern.split('*').joinToString(".*") {part->part.split('?').joinToString("."){Regex.escape(it)}}+"$",RegexOption.IGNORE_CASE)
        val found=ArrayList<FsEntry>()
        fun walk(root:String,depth:Int) {if(depth>32 || found.size>=4096) return
            for(e in k.env.fs?.list(root).orEmpty()) {
                if(regex.matches(e.name.removeSuffix(".Z")) && (flags and 0x400==0L || e.isDir) && (flags and 0x800==0L || !e.isDir)) found.add(e)
                if(e.isDir && flags and 1!=0L) walk(e.path,depth+1)
            }
        }
        walk(dir,0);var head=0L;var last=0L
        for(e in found.sortedBy {it.path.lowercase()}) {
            val p=m.calloc(k.prog.classes["CDirEntry"]!!.size.toLong())
            m.writeBytes(p+k.o.member("CDirEntry","name"),latin1(e.name).take(37).toByteArray())
            m.st8(p+k.o.member("CDirEntry","full_name"),str(latin1(e.path)))
            m.st8(p+k.o.member("CDirEntry","size"),e.size)
            m.st2(p+k.o.member("CDirEntry","attr"),if(e.isDir) 16 else 0)
            if(last!=0L) m.st8(last.toInt()+k.o.member("CDirEntry","next"),p.toLong()) else head=p.toLong()
            last=p.toLong()
        }
        return head
    }
}
