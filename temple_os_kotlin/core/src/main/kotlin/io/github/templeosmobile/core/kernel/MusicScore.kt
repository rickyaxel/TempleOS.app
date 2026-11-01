package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*

/** Data reader for the exact song format emitted by the original Psalmody editor.
 * Arbitrary HolyC, additional statements and changed program templates are rejected. */
class MusicScore(private val k:Kernel) {
    private val allocations=HashMap<Int,MutableList<Long>>()
    fun open(task:Task,path:String):Long {
        if(!k.isNative || k.native!!.fileCurrent(k,path)) return 0
        val raw=k.env.fs?.readFile(path) ?: throw CompileError("Song not found: $path")
        if(raw.size>1_048_576) throw CompileError("Song size limit")
        val source=SourceFile.parse(path,raw)
        if(source.bins.isNotEmpty()) throw CompileError("Native score data cannot contain source attachments")
        val tokens=Lexer(null).tokenize(source,Paths.parent(path));var at=0
        fun expect(text:String) {if(tokens.getOrNull(at)?.text!=text) throw CompileError("Native score requires the original Psalmody song template",path,tokens.getOrNull(at)?.line ?: 1);at++}
        fun words(text:String) {for(s in text.split(' ')) expect(s)}
        fun number():Double {val t=tokens.getOrNull(at++) ?: throw CompileError("Missing score setting");val v=when(t.kind){T.FLOAT->t.fval;T.INT->t.ival.toDouble();else->throw CompileError("Invalid score setting")};if(!v.isFinite() || v<=0 || v>100) throw CompileError("Score setting out of range");return v}
        fun string():ByteArray {val out=java.io.ByteArrayOutputStream();if(tokens.getOrNull(at)?.kind!=T.STR) throw CompileError("Expected score text");while(tokens.getOrNull(at)?.kind==T.STR) out.write(tokens[at++].bytes!!);return out.toByteArray()}
        words("U0 Song ( ) { Fs -> task_end_cb = & SndTaskEndCB ; MusicSettingsRst ; music . tempo =")
        val tempo=number();words("; music . stacatto_factor =");val staccato=number()
        words("; try { while ( ! ScanKey ) {")
        val events=ArrayList<Pair<ByteArray,ByteArray?>>()
        while(tokens.getOrNull(at)?.text=="Play") {
            if(events.size>=2048) throw CompileError("Score event limit")
            words("Play (");val notes=string();var lyrics:ByteArray?=null
            if(tokens.getOrNull(at)?.text==",") {at++;lyrics=string()}
            words(") ;");events.add(notes to lyrics)
        }
        words("} } catch PutExcept ; Snd ; } Song ;")
        if(tokens.getOrNull(at)?.kind!=T.EOF || events.isEmpty()) throw CompileError("Unsupported score source")
        val owned=allocations.getOrPut(task.id){ArrayList()}
        fun alloc(n:Long):Int {val p=k.mem.calloc(n);owned.add(p.toLong());return p}
        fun text(bytes:ByteArray?):Long {if(bytes==null)return 0;val p=alloc(bytes.size+1L);k.mem.writeBytes(p,bytes);return p.toLong()}
        val ptr=alloc(24L+16*events.size);k.mem.st8(ptr,tempo.toRawBits());k.mem.st8(ptr+8,staccato.toRawBits());k.mem.st8(ptr+16,events.size.toLong())
        for((i,e) in events.withIndex()){k.mem.st8(ptr+24+16*i,text(e.first));k.mem.st8(ptr+32+16*i,text(e.second))}
        return ptr.toLong()
    }
    fun close(task:Task) {allocations.remove(task.id)?.asReversed()?.forEach {runCatching{k.mem.free(it)}}}
}
