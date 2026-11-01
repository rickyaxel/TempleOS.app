package io.github.templeosmobile.core.kernel

import io.github.templeosmobile.core.holyc.*
import java.util.zip.Inflater

/** Original word bytes and independently compressed definition blocks. Only a requesting kernel loads them. */
class TempleDictionary(private val k:Kernel) {
    private var words:ByteArray?=null
    private var definitions:ByteArray?=null
    private val lookup=HashMap<String,Int>()
    fun initialize() {
        if(words!=null) return
        val data=k.env.runtimeFile("dictionary/words.bin") ?: throw VmFault(chCode("Dict"),"Original dictionary missing")
        var p=0;var count=0
        while(p<data.size && data[p].toInt()==1) {
            val start=++p;while(p<data.size && data[p].toInt()!=0) p++
            if(p+2>=data.size) throw VmFault(chCode("Dict"),"Truncated dictionary word")
            val name=String(data,start,p-start,Charsets.ISO_8859_1).uppercase()
            lookup[name]=(data[p+1].toInt() and 255) or ((data[p+2].toInt() and 255) shl 8)
            count++;p+=3
        }
        words=data
        val ptr=k.mem.malloc(data.size+1L);k.mem.writeBytes(ptr,data);k.mem.st1(ptr+data.size,0)
        val a=k.o.global("acd")
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","word_lst"),ptr.toLong())
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","word_lst_size"),data.size.toLong())
        k.mem.st8(a+k.o.member("CAutoCompleteDictGlbls","num_words"),count.toLong())
    }
    fun get(word:String,number:Int=1,all:Boolean=false):ByteArray? {
        initialize();val block=lookup[word.uppercase()] ?: return null
        val bytes=definitions ?: k.env.runtimeFile("dictionary/definitions.bin")?.also {definitions=it} ?: return null
        fun u32(o:Int):Int {if(o<0 || o+4>bytes.size) throw VmFault(chCode("Dict"),"Dictionary bounds");var n=0;for(i in 0..3) n=n or ((bytes[o+i].toInt() and 255) shl (8*i));return n}
        if(bytes.size<20 || String(bytes,0,4)!="TODI" || u32(8)!=16384) throw VmFault(chCode("Dict"),"Dictionary format")
        val count=u32(12);val base=16+(count+1)*4
        fun inflate(index:Int):ByteArray {
            if(index>=count) return byteArrayOf()
            val start=u32(16+index*4);val end=u32(20+index*4)
            if(start<0 || end<start || base+end>bytes.size) throw VmFault(chCode("Dict"),"Dictionary block bounds")
            val z=Inflater();try {z.setInput(bytes,base+start,end-start);val out=ByteArray(16384);val n=z.inflate(out);if(!z.finished()) throw VmFault(chCode("Dict"),"Dictionary block invalid");return out.copyOf(n)} finally {z.end()}
        }
        val data=inflate(block)+inflate(block+1);var p=0
        while(p<data.size) {
            if(data[p++].toInt()!=1) continue
            val s=p;while(p<data.size && data[p].toInt()!=0) p++
            if(String(data,s,p-s,Charsets.ISO_8859_1).equals(word,true)) {
                val begin=s-1;while(p<data.size && data[p].toInt()!=1) p++
                if(all) return data.copyOfRange(begin,p)+byteArrayOf(0)
                var n=number;var q=begin
                while(q<p) {
                    if(data[q++].toInt()==2 && --n==0) {val start=q;while(q<p && data[q].toInt()!=0) q++;return data.copyOfRange(start,q)}
                }
                return null
            }
        }
        return null
    }
}
