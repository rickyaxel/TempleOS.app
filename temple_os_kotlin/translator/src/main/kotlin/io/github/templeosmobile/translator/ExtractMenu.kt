package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.SourceFile
import io.github.templeosmobile.core.kernel.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.Deflater
import java.io.ByteArrayOutputStream

/** Build-time rasterization of Terry's DolDoc attachments with the shipped original Sprite3 code. */
fun extractMenu(repo: Repo) {
    val original = File(repo.root, "reference/templeos-iso/PersonalMenu.DD")
    val bundled = File(repo.root, "shared/bundled-fs/PersonalMenu.DD")
    require(original.readBytes().contentEquals(bundled.readBytes())) { "menu differs from ISO extraction" }
    val source = SourceFile.parse(original.name, original.readBytes())
    val env = object : KernelEnv {
        override val fs: VirtualFs? = null
        override fun runtimeFile(name: String) = File(repo.runtime, name).takeIf { it.exists() }?.readBytes()
        override fun entropy() = 12345L
    }
    val k = Kernel(env, "menu-extract"); k.virtualTime = true; k.boot()
    val out = File(repo.runtime, "games-menu").also { it.mkdirs() }
    val rows = ArrayList<String>()
    for ((num, bytes) in source.bins.toSortedMap()) {
        val ptr = k.mem.malloc(bytes.size.toLong()); k.mem.writeBytes(ptr, bytes)
        val typeMask = k.callHolyC("SpriteTypeMask", ptr.toLong())
        val animated = typeMask and ((1L shl 24) or (1L shl 25)) != 0L
        val bounds = k.mem.malloc(32)
        k.callHolyC("SpriteExtents", ptr.toLong(), bounds.toLong(), bounds + 8L, bounds + 16L, bounds + 24L)
        val width = k.mem.ld8(bounds + 8) - k.mem.ld8(bounds) + 1
        val height = k.mem.ld8(bounds + 24) - k.mem.ld8(bounds + 16) + 1
        require(width in 1..1024 && height in 1..1024)
        val dc = k.callHolyC("DCNew", width, height, 0, 0).toInt()
        val blankBody = k.mem.ld8(dc + k.o.dc("body")).toInt()
        k.mem.fill(blankBody, 255, k.mem.ld4(dc + k.o.dc("width_internal")).toInt() * height.toInt())
        k.callHolyC("Sprite3", dc.toLong(), -k.mem.ld8(bounds), -k.mem.ld8(bounds + 16), 0, ptr.toLong(), 0)
        val w = k.mem.ld4(dc + k.o.dc("width")).toInt()
        val h = k.mem.ld4(dc + k.o.dc("height")).toInt()
        val stride = k.mem.ld4(dc + k.o.dc("width_internal")).toInt()
        val body = k.mem.ld8(dc + k.o.dc("body")).toInt()
        require(w in 1..1024 && h in 1..1024)
        val pixel = ByteArray(w * h) { i -> k.mem.ld1(body + (i / w) * stride + i % w).toByte() }
        require(pixel.all { it.toInt() == -1 || it.toInt() in 0..15 })
        val asset = "sprite-%02d.idx".format(num)
        val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put(byteArrayOf(84,79,83,73)).putShort(w.toShort()).putShort(h.toShort()).array()
        File(out, asset).writeBytes(header + pixel)
        val animation=if(animated) extractAnimation(k,ptr.toLong(),num,out) else ""
        rows.add("{\"sprite\":$num,\"typeMask\":$typeMask,\"animatedOriginal\":$animated,\"width\":$w,\"height\":$h,\"minX\":${k.mem.ld8(bounds)},\"minY\":${k.mem.ld8(bounds+16)},\"asset\":\"games-menu/$asset\",\"spriteSHA256\":\"${sha256(bytes)}\",\"assetSHA256\":\"${sha256(header+pixel)}\"$animation}")
        println("sprite $num: ${w}x$h")
        k.callHolyC("DCDel", dc.toLong()); k.mem.free(bounds.toLong()); k.mem.free(ptr.toLong())
    }
    File(out, "rasters.json").writeText("[\n" + rows.joinToString(",\n") + "\n]\n")
    k.terminate("extracted")
}

/** Original DocRecalc.HC rotations, rasterized by the original Sprite3 + depth-buffer implementation.
 * Independent zlib frames keep mobile decode work and retained pixels bounded. */
private fun extractAnimation(k:Kernel,elems:Long,num:Int,out:File):String {
    val side=256;val center=128;val count=630;val period=20*Math.PI
    val dc=k.callHolyC("DCNew",side.toLong(),side.toLong(),0,0).toInt()
    val body=k.mem.check(k.mem.ld8(dc+k.o.dc("body")),side*side)
    val matrix=k.mem.ld8(dc+k.o.dc("r"))
    k.callHolyC("DCDepthBufAlloc",dc.toLong())
    val frames=ArrayList<ByteArray>();var left=side;var top=side;var right=0;var bottom=0
    try {
        for(frame in 0 until count) {
            val time=period*frame/count
            k.mem.fill(body,255,side*side);k.callHolyC("DCDepthBufRst",dc.toLong())
            k.callHolyC("Mat4x4IdentEqu",matrix)
            k.callHolyC("Mat4x4RotZ",matrix,(time*3.1).toRawBits())
            k.callHolyC("Mat4x4RotY",matrix,(time*1.9).toRawBits())
            k.callHolyC("Mat4x4RotX",matrix,time.toRawBits())
            k.mem.st8(dc+k.o.dc("flags"),k.mem.ld8(dc+k.o.dc("flags")) or 0x100)
            k.mem.st4(dc+k.o.dc("x"),center.toLong());k.mem.st4(dc+k.o.dc("y"),center.toLong());k.mem.st4(dc+k.o.dc("z"),0x3fffffff)
            k.callHolyC("Sprite3",dc.toLong(),0,0,0,elems,0)
            val data=k.mem.readBytes(body,side*side);frames.add(data)
            for(i in data.indices) if(data[i].toInt()!=-1) {
                val x=i%side;val y=i/side
                require(x in 1 until side-1 && y in 1 until side-1) {"rotating original sprite $num exceeds export surface"}
                left=minOf(left,x);right=maxOf(right,x);top=minOf(top,y);bottom=maxOf(bottom,y)
            }
        }
        require(left<=right && top<=bottom)
        val width=right-left+1;val height=bottom-top+1
        val offsets=ArrayList<Int>();val packed=ByteArrayOutputStream()
        for(data in frames) {
            val image=ByteArray(width*height) {i->data[(top+i/width)*side+left+i%width]}
            offsets.add(packed.size());val deflater=Deflater(9);deflater.setInput(image);deflater.finish()
            val buf=ByteArray(65536)
            while(!deflater.finished()) {val n=deflater.deflate(buf);packed.write(buf,0,n)};deflater.end()
        }
        offsets.add(packed.size())
        val header=ByteBuffer.allocate(16+4*offsets.size).order(ByteOrder.LITTLE_ENDIAN)
        header.put(byteArrayOf(84,79,83,65));header.putShort(width.toShort());header.putShort(height.toShort());header.putShort(count.toShort());header.putShort(0);header.putInt(62832)
        offsets.forEach {header.putInt(it)}
        val bytes=header.array()+packed.toByteArray();val asset="games-menu/sprite-%02d.anim".format(num)
        File(out.parentFile,asset).writeBytes(bytes)
        println("animated sprite $num: ${width}x$height, $count source-rendered frames, ${bytes.size} bytes")
        return ",\"animationAsset\":\"$asset\",\"animationSHA256\":\"${sha256(bytes)}\",\"animationWidth\":$width,\"animationHeight\":$height,\"animationMinX\":${left-center},\"animationMinY\":${top-center},\"animationFrames\":$count,\"animationPeriodMs\":62832"
    } finally {k.callHolyC("DCDel",dc.toLong())}
}
