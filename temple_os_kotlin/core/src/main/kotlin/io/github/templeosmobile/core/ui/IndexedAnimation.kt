package io.github.templeosmobile.core.ui

import java.util.zip.Inflater

/** Independently compressed original indexed frames; retains only one decoded frame per icon. */
class IndexedAnimation(private val data:ByteArray) {
    val width:Int;val height:Int;val count:Int;val period:Int
    private val offsets:IntArray
    private val base:Int
    private var frame = -1
    private var pixels=ByteArray(0)
    init {
        fun u16(p:Int)=(data[p].toInt() and 255) or ((data[p+1].toInt() and 255) shl 8)
        fun u32(p:Int)=u16(p) or (u16(p+2) shl 16)
        require(data.size>=20 && String(data,0,4)=="TOSA")
        width=u16(4);height=u16(6);count=u16(8);period=u32(12)
        require(width in 1..256 && height in 1..256 && count in 1..1000 && period in 1..1_000_000)
        base=16+4*(count+1);require(base<=data.size)
        offsets=IntArray(count+1){u32(16+4*it)}
        require(offsets[0]==0 && offsets.last()==data.size-base && offsets.asList().zipWithNext().all {it.first<it.second})
    }
    fun pixels(nowMs:Long):ByteArray {
        val index=((nowMs.coerceAtLeast(0)%period)*count/period).toInt()
        if(index==frame) return pixels
        val out=ByteArray(width*height);val inflater=Inflater()
        try {
            inflater.setInput(data,base+offsets[index],offsets[index+1]-offsets[index])
            require(inflater.inflate(out)==out.size && inflater.finished() && out.all {it.toInt()==-1 || it.toInt() in 0..15})
        } finally {inflater.end()}
        pixels=out;frame=index;return pixels
    }
}
