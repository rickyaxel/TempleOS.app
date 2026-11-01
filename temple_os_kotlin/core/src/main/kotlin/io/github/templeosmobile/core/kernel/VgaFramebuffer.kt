package io.github.templeosmobile.core.kernel

/** Bounded planar drawing adapter. Original demo writes stay in arena memory, never host VGA memory. */
class VgaFramebuffer(private val k:Kernel) {
    private var address=0
    private var register=0
    private var mask=15
    private var previous=ByteArray(0)
    private var planes:ByteArray?=null
    fun port(port:Long,value:Long) {
        if(port==0x3C4L) {register=value.toInt();return}
        if(port!=0x3C5L || register!=2) return
        if(address==0) {
            address=k.mem.calloc(38400).toInt();planes=ByteArray(4*38400);previous=ByteArray(38400)
            k.mem.st8(k.o.global("text")+k.o.member("CTextGlbls","vga_alias"),address.toLong())
            val body=k.mem.check(k.mem.ld8(k.gfx.grDc.toInt()+k.o.dc("body")),640*480)
            k.mem.fill(body,0,640*480);k.graphicsUsed=true
        }
        sync();mask=value.toInt() and 15
    }
    fun sync() {
        val data=planes ?: return
        val mem=k.mem
        val source=mem.check(address.toLong(),38400)
        val dst=mem.check(mem.ld8(k.gfx.grDc.toInt()+k.o.dc("body")),640*480)
        for(i in 0 until 38400) {
            val v=mem.ld1(source+i).toByte()
            if(v==previous[i]) continue
            previous[i]=v
            for(plane in 0..3) if(mask and (1 shl plane)!=0) data[plane*38400+i]=v
            for(bit in 0..7) {
                var color=0
                for(plane in 0..3) if(data[plane*38400+i].toInt() and (128 shr bit)!=0) color=color or (1 shl plane)
                mem.st1(dst+i*8+bit,color.toLong())
            }
        }
    }
}
