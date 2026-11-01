package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.sqrt

/** Memory-safe host boundary for the shared DolDoc library and original GR files. */
class DocumentRuntime(private val k: Kernel) {
    private val m get() = k.mem
    var capture = true
    private var capturing = false
    private val origins=HashMap<Long,Pair<Int,Int>>()
    private var nextDynamic=0L
    private data class MeshSprite(val id:Int,val elems:Long,val dc:Long,val side:Int,val body:Int,val stride:Int)
    private val meshSprites=HashMap<Int,MeshSprite>()
    private var drawingSprite=false
    private var spriteDoc=0L
    private var lastSpriteId = -1
    /** Original DocRecalc rotations. Reuse the DC, depth buffer and console pixels. */
    fun trackSprite(elems:Long,id:Int,minX:Long,maxX:Long,minY:Long,maxY:Long) {
        pruneSprites()
        k.current?.let {spriteDoc=m.ld8(it.fsAddr+k.o.task("put_doc"));lastSpriteId=id}
        val mask=k.callHolyC("SpriteTypeMask",elems)
        if(mask and ((1L shl 24) or (1L shl 25))==0L)return
        val size=k.raster.spriteSize(elems)
        if(size !in 1..4L*1024*1024)throw VmKill("document mesh size")
        val mx=max(kotlin.math.abs(minX.toDouble()),kotlin.math.abs(maxX.toDouble()))
        val my=max(kotlin.math.abs(minY.toDouble()),kotlin.math.abs(maxY.toDouble()))
        var radius=max(1.0,sqrt(mx*mx+my*my));var at=elems;var steps=0
        while(steps++<4096) {
            val type=m.ld1(m.check(at,1)).toInt() and 127
            if(type==0 || type>=30)break
            if(type==24 || type==25) {
                val cls=if(type==24)"CSpriteMeshU8s" else "CSpritePtMeshU8s"
                val count=m.ld4(m.check(at+k.o.member(cls,"vertex_cnt"),4)).toInt()
                if(count !in 0..100000)throw VmKill("document mesh vertices")
                val start=at+k.o.member(cls,"u");val stride=k.o.cls("CD3I32").size
                m.check(start,count*stride)
                fun coord(p:Long,offset:Int)=m.ld4(p.toInt()+offset).toInt().toDouble()
                val shift=if(type==25)doubleArrayOf(coord(at,k.o.member(cls,"x")),coord(at,k.o.member(cls,"y")),coord(at,k.o.member(cls,"z"))) else doubleArrayOf(0.0,0.0,0.0)
                for(i in 0 until count) {
                    val p=start+i.toLong()*stride
                    val x=coord(p,0)+shift[0];val y=coord(p,4)+shift[1];val z=coord(p,8)+shift[2]
                    radius=max(radius,sqrt(x*x+y*y+z*z))
                }
            }
            val length=k.raster.spriteElemSize(at)
            if(length<=0)throw VmKill("document mesh element")
            at+=length
        }
        if(steps>=4096 || !radius.isFinite() || radius>500)throw VmKill("document mesh bounds")
        val side=(ceil(radius).toInt()*2+10) and -8
        k.console.resizeSprite(id,side)
        val copy=m.malloc(size);m.writeBytes(copy,m.readBytes(m.check(elems,size.toInt()),size.toInt()))
        var dc=0L
        try {
            dc=k.callHolyC("DCNew",side.toLong(),side.toLong(),0,0);k.callHolyC("DCDepthBufAlloc",dc)
            val stride=m.ld4(dc.toInt()+k.o.dc("width_internal")).toInt()
            val body=m.check(m.ld8(dc.toInt()+k.o.dc("body")),stride*side)
            val sp=MeshSprite(id,copy.toLong(),dc,side,body,stride)
            meshSprites[id]=sp;draw(sp)
        } catch(e:Throwable) {
            if(dc!=0L)k.callHolyC("DCDel",dc)
            m.free(copy.toLong());meshSprites.remove(id);throw e
        }
    }
    private fun draw(sp:MeshSprite) {
        if(drawingSprite)return
        drawingSprite=true
        try {
        val seconds=k.now()/1e9;val r=m.ld8(sp.dc.toInt()+k.o.dc("r"))
        m.fill(sp.body,255,sp.stride*sp.side);k.callHolyC("DCDepthBufRst",sp.dc)
        k.callHolyC("Mat4x4IdentEqu",r)
        k.callHolyC("Mat4x4RotZ",r,(seconds*3.1).toRawBits());k.callHolyC("Mat4x4RotY",r,(seconds*1.9).toRawBits());k.callHolyC("Mat4x4RotX",r,seconds.toRawBits())
        m.st8(sp.dc.toInt()+k.o.dc("flags"),m.ld8(sp.dc.toInt()+k.o.dc("flags")) or 0x100)
        m.st4(sp.dc.toInt()+k.o.dc("x"),(sp.side/2).toLong());m.st4(sp.dc.toInt()+k.o.dc("y"),(sp.side/2).toLong());m.st4(sp.dc.toInt()+k.o.dc("z"),0x3fffffff)
        k.callHolyC("Sprite3",sp.dc,0,0,0,sp.elems,0)
        k.console.updateSprite(sp.id) {pixels->for(y in 0 until sp.side)for(x in 0 until sp.side)pixels[y*sp.side+x]=m.ld1(sp.body+y*sp.stride+x).toByte()}
        } finally {drawingSprite=false}
    }
    private fun pruneSprites() {
        for(sp in meshSprites.values.filter {!k.console.hasSprite(it.id)}) {
            k.callHolyC("DCDel",sp.dc);m.free(sp.elems);meshSprites.remove(sp.id)
        }
    }
    private fun refreshSprites() {
        if(meshSprites.isEmpty())return
        pruneSprites()
        val saved=k.current;k.mainTask?.let {k.setCurrent(it)}
        try {for(sp in meshSprites.values)draw(sp)} finally {saved?.let {k.setCurrent(it)}}
    }
    fun refreshDynamic() {
        if(k.now()<nextDynamic) return
        nextDynamic=k.now()+33_000_000
        val task=k.mainTask ?: return
        if(task.state==Kernel.DEAD) return
        refreshSprites()
        val doc=m.ld8(task.fsAddr+k.o.task("put_doc"));val origin=origins[doc] ?: return
        var e=m.ld8(m.check(doc,k.prog.classes["CDoc"]!!.size));var steps=0
        while(e!=doc && e!=0L && steps++<2000) {
            val ptr=m.check(e,k.prog.classes["CDocEntry"]!!.size)
            val callback=m.ld8(ptr+k.o.member("CDocEntry","tag_cb"))
            if(callback!=0L) {
                val saved=k.current;k.setCurrent(task)
                val text=try {k.vm.callFunction(task,callback,doc,e,task.fsAddr.toLong())} finally {saved?.let {k.setCurrent(it)}}
                if(text!=0L) {
                    try {k.console.updateField(origin.first+m.ld4(ptr+k.o.member("CDocEntry","y")).toInt(),origin.second+m.ld4(ptr+k.o.member("CDocEntry","x")).toInt(),m.readStrBytes(text),2)} finally {m.free(text)}
                }
            }
            e=m.ld8(ptr)
        }
    }
    fun canExport():Boolean {
        val task=k.mainTask ?: return false
        return k.finished && m.ld8(task.fsAddr+k.o.task("put_doc"))!=0L
    }
    /** An ended program's original DolDoc, including generated binary sprite records. */
    fun export(path:String) {
        if(!canExport()) throw FsError("Program document is still running")
        val target=Paths.normalize("C:/Home",path) ?: throw FsError("Invalid path")
        val task=k.mainTask!!;val doc=m.check(m.ld8(task.fsAddr+k.o.task("put_doc")),k.prog.classes["CDoc"]!!.size)
        val name=doc+k.o.member("CDoc","filename")+k.o.member("CEdFileName","name")
        val capacity=k.prog.classes["CEdFileName"]!!.members["name"]!!.type.size
        val bytes=latin1(target);if(bytes.size>=capacity) throw FsError("Path is too long")
        val saved=m.readBytes(name,capacity)
        try {m.writeBytes(name,bytes);m.st1(name+bytes.size,0);k.callHolyC("DocWrite",doc.toLong(),0,task=k.adamTask)}
        finally {m.writeBytes(name,saved)}
    }
    private fun str(bytes: ByteArray): Long {
        val p=m.malloc(bytes.size+1L);m.writeBytes(p,bytes);m.st1(p+bytes.size,0);return p.toLong()
    }
    fun output(bytes: ByteArray) {
        if (!capture || capturing || bytes.isEmpty()) return
        val fs=k.current?.fsAddr?.toLong() ?: return
        val base=m.check(fs,k.prog.classes["CTask"]!!.size)
        val doc=m.ld8(base+k.o.task("put_doc"));if(doc==0L) return
        capturing=true;var st=0L
        fun detach() {m.st8(base+k.o.task("put_doc"),0);if(m.ld8(base+k.o.task("display_doc"))==doc) m.st8(base+k.o.task("display_doc"),0);origins.remove(doc)}
        try {
            m.check(doc,k.prog.classes["CDoc"]!!.size)
            st=str(bytes);k.callHolyC("MobileDocAppend",doc,st)
        } catch(_:VmFault) {detach()} catch(_:VmUncaught) {detach()}
        finally {if(st!=0L) try {m.free(st)} catch(_:VmFault) {};capturing=false}
    }
    fun register(table: NativeTable) {
        fun reg(name:String, fn:NativeFn) {table.add(object: Native(name) {override fun call(t:Task,base:Int,argc:Int)=fn.call(t,base,argc)})}
        reg("MobileVgaPort") {t,a,_->k.vga.port(t.st[a],t.st[a+1]);0}
        reg("MobileVgaSync") {_,_,_->k.vga.sync();0}
        reg("MobileDocEmit") {t,a,_->
            val data=m.readStrBytes(t.st[a]);val clear=latin1(data).contains("${'$'}CL${'$'}")
            val fs=m.ld8(k.o.fsGlobal);val doc=if(fs==0L)0L else m.ld8(fs.toInt()+k.o.task("put_doc"))
            if(clear && doc==spriteDoc && k.console.hasSprite(lastSpriteId))k.console.writeKeepingSprites(data) else k.console.write(data)
            if(clear && fs!=0L) origins[doc]=0 to 0
            0
        }
        reg("MobileDocOrigin") {t,a,_->if(origins.size>=64) origins.clear();origins[t.st[a]]=k.console.cursorCell();0}
        reg("MobileDocForget") {t,a,_->origins.remove(t.st[a]);0}
        reg("MobileDocCapture") {t,a,_->val old=capture;capture=t.st[a]!=0L;if(old) 1 else 0}
        reg("MobileDocFields") {t,a,_->
            val c=k.prog.classes[m.readStr(t.st[a])] ?: return@reg str(byteArrayOf(0))
            val out=java.io.ByteArrayOutputStream()
            fun text(s:String) {out.write(latin1(s));out.write(0)}
            for (f in c.members.values) {
                val fmt=f.format ?: continue
                val type=f.type
                val kind=when {type is ArrType && type.elem.size==1->2;type is F64Type->1;type is IntType->0;else->continue}
                text("${f.offset},$kind,${type.size}")
                val format=latin1(fmt)
                val label=Regex("A=\"([^%\"]*)").find(format)?.groupValues?.get(1)?.replace('\u001f',' ')?.trim()?.trimEnd(':')
                text(label?.takeIf {it.isNotBlank()} ?: f.name);out.write(fmt);out.write(0)
            }
            out.write(0);str(out.toByteArray())
        }
        reg("MobileDocValue") {t,a,_->
            if(t.st[a]==0L) t.st[a+1] else {
                val expr=m.readStr(t.st[a]).trim()
                expr.toLongOrNull() ?: if(expr.startsWith("0x")) expr.drop(2).toLongOrNull(16) ?: t.st[a+1]
                else k.prog.uiConstants[expr] ?: k.defines[expr]?.let {raw ->
                    val ts=raw.filter {it.text!="(" && it.text!=")"}
                    if(ts.size==1 && ts[0].kind in listOf(T.INT,T.CHAR)) ts[0].ival
                    else if(ts.size==2 && ts[0].text=="-" && ts[1].kind==T.INT) -ts[1].ival else null
                } ?: (k.prog.globals[expr] as? GlobalSym)?.let {g ->m.ld8(g.addr)} ?: t.st[a+1]
            }
        }
        reg("MobileGRRead") {t,a,_->
            val path=grPath(t,m.readStr(t.st[a])) ?: return@reg 0
            val bytes=k.env.fs?.readFile(path) ?: k.env.fs?.readFile(path.removeSuffix(".Z")) ?: return@reg 0
            install(GRImage.decodeFile(bytes,path.endsWith(".Z")))
        }
        reg("MobileGRWrite") {t,a,_->
            val path=grPath(t,m.readStr(t.st[a])) ?: return@reg 0
            val data=image(t.st[a+1]).encode()
            val bytes=if(path.endsWith(".Z")) TempleArc.store(data) else data
            (k.env.fs ?: throw FsError("No file system")).writeFile(path,bytes);bytes.size.toLong()
        }
        reg("DCScrnCapture") {_,_,_->
            val dc=k.callHolyC("DCNew",640,480,0,0)
            val ptr=m.ld8(dc.toInt()+k.o.dc("body"));m.writeBytes(m.check(ptr,640*480),k.captureScreen())
            dc
        }
        reg("ACDDefGet") {t,a,_-> k.dictionary.get(m.readStr(t.st[a]),t.st[a+1].toInt())?.let {str(it)} ?: 0}
        reg("ACDDefsGet") {t,a,_-> k.dictionary.get(m.readStr(t.st[a]),all=true)?.let {str(it)} ?: 0}
        reg("ACAlloc") {t,a,_->m.calloc(t.st[a]).toLong()}
    }
    private fun grPath(t:Task,name:String)=Paths.normalize(k.curDir(t),if(Paths.name(name).contains('.')) name else "$name.GR.Z")
    private fun install(im:GRImage):Long {
        val dc=k.callHolyC("DCNew",im.width.toLong(),im.height.toLong(),0,0).toInt()
        val stride=m.ld4(dc+k.o.dc("width_internal")).toInt();val body=m.check(m.ld8(dc+k.o.dc("body")),stride*im.height)
        for(y in 0 until im.height) m.writeBytes(body+y*stride,im.body.copyOfRange(y*im.stride,y*im.stride+im.width))
        if(im.palette!=null) m.writeBytes(dc+k.o.dc("palette"),im.palette)
        return dc.toLong()
    }
    private fun image(addr:Long):GRImage {
        val dc=m.check(addr,k.prog.classes["CDC"]!!.size)
        val w=m.ld4(dc+k.o.dc("width")).toInt();val h=m.ld4(dc+k.o.dc("height")).toInt();val s=m.ld4(dc+k.o.dc("width_internal")).toInt()
        if(w !in 1..16384 || h !in 1..16384 || s<w || s>GRImage.MAX_BODY/h) throw VmKill("GR geometry limit")
        val raw=ByteArray(32+128+s*h)
        m.readBytes(dc,32).copyInto(raw)
        raw[28]=2;raw[29]=0;raw[30]=0;raw[31]=0
        m.readBytes(dc+k.o.dc("palette"),128).copyInto(raw,32)
        m.readBytes(m.check(m.ld8(dc+k.o.dc("body")),s*h),s*h).copyInto(raw,160)
        return GRImage.decode(raw)
    }
}
