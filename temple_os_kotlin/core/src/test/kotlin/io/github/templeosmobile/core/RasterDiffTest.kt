package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Random

/**
 * Differential test: native raster primitives (Raster.kt) must match the
 * original TempleOS HolyC (*_HC) exactly - pixels, depth buffer, collision
 * count, extents, return value and random-number consumption.
 */
class RasterDiffTest {
    private val k = Kernel(TestEnv(), "diff").also { it.boot() }
    private val m get() = k.mem
    private val rnd = Random(1234)

    private fun dcField(dc: Long, f: String) = dc.toInt() + k.o.dc(f)

    private fun newDc(w: Long, h: Long, screen: Boolean, depth: Boolean): Long {
        val dc = if (screen) k.callHolyC("DCAlias", k.gfx.grDc, k.adamTask!!.fsAddr.toLong()) else k.callHolyC("DCNew", w, h, 0, 0)
        if (depth) k.callHolyC("DCDepthBufAlloc", dc)
        tracked.add(dc)
        return dc
    }

    private fun randomize(dc: Long) {
        val body = m.ld8(dcField(dc, "body")).toInt()
        val wi = m.ld4(dcField(dc, "width_internal")).toInt(); val h = m.ld4(dcField(dc, "height")).toInt()
        for (i in 0 until wi * h) m.st1(body + i, (if (rnd.nextInt(4) == 0) 0xFF else rnd.nextInt(16)).toLong())
        val db = m.ld8(dcField(dc, "depth_buf"))
        if (db != 0L) for (i in 0 until wi * h) m.st4(db.toInt() + i * 4, rnd.nextInt(2000).toLong())
        val rops = intArrayOf(0, 0, 0, 1, 2, 3)
        val c0 = rnd.nextInt(16).toLong() or (rops[rnd.nextInt(rops.size)].toLong() shl 8)
        var color = c0 or (rnd.nextInt(16).toLong() shl 16)
        when (rnd.nextInt(4)) { 0 -> color = color or 0x40000000L; 1 -> color = color or 0x80000000L }
        m.st4(dcField(dc, "color"), color)
        m.st4(dcField(dc, "bkcolor"), rnd.nextInt(16).toLong())
        m.st8(dcField(dc, "dither_probability_u16"), rnd.nextInt(65536).toLong())
        m.st8(dcField(dc, "collision_cnt"), 0)
        var flags = m.ld4(dcField(dc, "flags"))
        if (rnd.nextInt(5) == 0) {
            flags = flags or 0x10000L
            m.st8(dcField(dc, "min_x"), Long.MAX_VALUE); m.st8(dcField(dc, "max_x"), Long.MIN_VALUE)
            m.st8(dcField(dc, "min_y"), Long.MAX_VALUE); m.st8(dcField(dc, "max_y"), Long.MIN_VALUE)
        } else flags = flags and 0x10000L.inv()
        m.st4(dcField(dc, "flags"), flags)
        m.st8(dcField(dc, "db_z"), rnd.nextInt(2500).toLong() - 200)
    }

    private val tracked = ArrayList<Long>()

    /** Bytes of every tracked DC: struct, body and depth buffer. */
    private fun state(): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (dc in tracked) {
            val sz = k.o.cls("CDC").size
            out.write(m.readBytes(dc.toInt(), sz))
            val wi = m.ld4(dcField(dc, "width_internal")).toInt(); val h = m.ld4(dcField(dc, "height")).toInt()
            out.write(m.readBytes(m.ld8(dcField(dc, "body")).toInt(), wi * h))
            val db = m.ld8(dcField(dc, "depth_buf"))
            if (db != 0L) out.write(m.readBytes(db.toInt(), wi * h * 4))
        }
        return out.toByteArray()
    }

    /** Extra scratch memory compared (DCReflect writes through pointers). */
    private var extraAddr = 0
    private var extraLen = 24
    private fun extra(): ByteArray = if (extraAddr == 0) ByteArray(0) else m.readBytes(extraAddr, extraLen)

    private fun snapshot(): LongArray = m.words.copyOf()
    private fun restore(s: LongArray) = System.arraycopy(s, 0, m.words, 0, s.size)

    private fun seedNow(): Long = k.current?.let { m.ld8(it.fsAddr + k.o.task("rand_seed")) } ?: 0L

    private fun check(name: String, iters: Int, args: () -> LongArray) {
        var fails = 0
        repeat(iters) { iter ->
            val a = args()
            // a fixed seed (TASKf_NONTIMER_RAND): unseeded, TempleOS's generator XORs in the time stamp counter, so
            // the fast path and the HolyC original would dither differently only because they run at different times
            k.current?.let { k.seed(it, 0x5EEDL + iter, 0) }
            val snap = snapshot()
            // the generator's state is the current task's rand_seed, in the arena (restored with it)
            val r1 = k.callHolyC(name, *a)
            val after1 = state() + extra(); val rs1 = seedNow()
            restore(snap)
            val r2 = k.callHolyC(name + "_HC", *a)
            val after2 = state() + extra(); val rs2 = seedNow()
            val diffAt = (after1.indices).firstOrNull { after1[it] != after2[it] }
            if (r1 != r2 || rs1 != rs2 || diffAt != null) {
                if (fails < 3 && diffAt != null) {
                    var off = diffAt
                    for (dc in tracked) {
                        val sz = k.o.cls("CDC").size
                        val wi = m.ld4(dcField(dc, "width_internal")).toInt(); val h = m.ld4(dcField(dc, "height")).toInt()
                        val db = m.ld8(dcField(dc, "depth_buf")) != 0L
                        val tot = sz + wi * h + (if (db) wi * h * 4 else 0)
                        if (off < tot) {
                            val where = if (off < sz) "struct+$off" else if (off < sz + wi * h) "body x=${(off - sz) % wi} y=${(off - sz) / wi}" else "db"
                            println("   dc=$dc ${m.ld4(dcField(dc, "width"))}x$h flags=0x${m.ld4(dcField(dc, "flags")).toString(16)} color=0x${m.ld4(dcField(dc, "color")).toString(16)} bk=${m.ld4(dcField(dc, "bkcolor"))} at $where native=${after1[diffAt]} hc=${after2[diffAt]}")
                            break
                        }
                        off -= tot
                    }
                }
                if (fails++ < 3) println("$name mismatch #$iter args=${a.joinToString()} ret native=$r1 hc=$r2 rng=${rs1 == rs2} diffAt=$diffAt")
            }
            restore(snap)
        }
        assertEquals("$name mismatches", 0, fails)
    }

    private fun coord(n: Int) = (rnd.nextInt(n + 80) - 40).toLong()

    @Test fun rect() {
        val dcs = listOf(newDc(37, 29, false, false), newDc(64, 48, false, true), newDc(640, 480, true, false))
        check("GrRect", 600) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(40).toLong() - 3, rnd.nextInt(40).toLong() - 3) }
    }

    @Test fun hvline() {
        val dcs = listOf(newDc(37, 29, false, true), newDc(64, 48, false, false), newDc(640, 480, true, true))
        check("GrHLine", 600) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(60), coord(50), rnd.nextInt(3000).toLong() - 500, rnd.nextInt(3000).toLong() - 500) }
        check("GrVLine", 600) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(50), coord(50), rnd.nextInt(3000).toLong() - 500, rnd.nextInt(3000).toLong() - 500) }
    }

    @Test fun plotPeek() {
        val dcs = listOf(newDc(37, 29, false, true), newDc(640, 480, true, false))
        check("GrPlot", 400) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc); longArrayOf(dc, coord(50), coord(40)) }
        check("GrPlot1", 400) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc); longArrayOf(dc, coord(50), coord(40)) }
        check("GrPeek", 400) { val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc); longArrayOf(dc, coord(50), coord(40)) }
    }

    @Test fun blot() {
        val dcs = listOf(newDc(37, 29, false, false), newDc(640, 480, true, false))
        val imgs = listOf(newDc(9, 7, false, false), newDc(16, 16, false, false), newDc(3, 20, false, false))
        check("GrBlot", 600) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            val img = imgs[rnd.nextInt(imgs.size)]; randomize(img)
            val f = dcField(img, "flags")
            m.st4(f, if (rnd.nextBoolean()) m.ld4(f) or 0x100000L else m.ld4(f) and 0x100000L.inv())
            longArrayOf(dc, coord(50), coord(40), img)
        }
    }

    @Test fun fillTri() {
        val dcs = listOf(newDc(37, 29, false, true), newDc(64, 48, false, false), newDc(640, 480, true, true))
        val pts = LongArray(3) { m.calloc(12).toLong() }
        check("GrFillTri0", 1500) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            for (q in pts) {
                m.st4(q.toInt(), (rnd.nextInt(120) - 30).toLong()); m.st4(q.toInt() + 4, (rnd.nextInt(100) - 25).toLong())
                m.st4(q.toInt() + 8, (rnd.nextInt(2400) - 200).toLong())
            }
            if (rnd.nextInt(6) == 0) m.st4(pts[1].toInt() + 4, m.ld4(pts[0].toInt() + 4))
            longArrayOf(dc, pts[0], pts[1], pts[2])
        }
    }

    @Test fun blot3() {
        val dcs = listOf(newDc(64, 48, false, true), newDc(640, 480, true, true), newDc(640, 480, true, false))
        val imgs = listOf(newDc(9, 7, false, false), newDc(16, 12, false, false))
        check("GrBlot3", 500) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            val img = imgs[rnd.nextInt(imgs.size)]; randomize(img)
            val f = dcField(dc, "flags")
            if (rnd.nextBoolean()) {
                m.st4(f, m.ld4(f) or 0x100L)
                k.callHolyC("Mat4x4IdentEqu", m.ld8(dcField(dc, "r")))
                k.callHolyC("Mat4x4RotZ", m.ld8(dcField(dc, "r")), (rnd.nextDouble() * 6).toRawBits())
                k.callHolyC("Mat4x4Scale", m.ld8(dcField(dc, "r")), (0.5 + rnd.nextDouble() * 2).toRawBits())
                m.st4(dcField(dc, "x"), coord(40)); m.st4(dcField(dc, "y"), coord(40))
            } else m.st4(f, m.ld4(f) and 0x100L.inv())
            // symmetry (mirrored copy first, then the normal one unless DCF_JUST_MIRROR)
            when (rnd.nextInt(3)) {
                0 -> {
                    k.callHolyC("DCSymmetrySet", dc, coord(50), coord(40), coord(50), coord(40))
                    m.st4(f, (m.ld4(f) or 0x200L).let { if (rnd.nextBoolean()) it or 0x400L else it and 0x400L.inv() })
                }
                else -> m.st4(f, m.ld4(f) and 0x600L.inv())
            }
            longArrayOf(dc, coord(50), coord(40), rnd.nextInt(1500).toLong(), img)
        }
    }

    @Test fun reflect() {
        val dc = newDc(64, 48, false, false)
        val px = m.calloc(24).toLong()
        extraAddr = px.toInt()
        check("DCReflect", 400) {
            k.callHolyC("DCSymmetrySet", dc, coord(50), coord(40), coord(50), coord(40))
            m.st8(px.toInt(), coord(60)); m.st8(px.toInt() + 8, coord(60)); m.st8(px.toInt() + 16, coord(60))
            longArrayOf(dc, px, px + 8, px + 16)
        }
    }

    @Test fun fat() {
        val dcs = listOf(newDc(64, 48, false, true), newDc(640, 480, true, false))
        check("GrLineFat3", 800) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(1000).toLong(), coord(60), coord(50), rnd.nextInt(1000).toLong(),
                (rnd.nextInt(80) - 3).toLong(), rnd.nextInt(4).toLong())
        }
        check("GrFillCircle", 300) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(1000).toLong(), (rnd.nextInt(90) - 3).toLong())
        }
        check("GrFillSemiCircle", 500) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(1000).toLong(), (rnd.nextInt(90) - 3).toLong(), rnd.nextInt(8).toLong())
        }
    }

    /**
     * Native Mat4x4MulMat4x4Equ (Sprite3 with DCF_TRANSFORMATION) vs Adam/Gr/GrMath.HC: rotation and
     * scale matrices as programs build them, raw random words (F64 rounding, overflow to I64_MIN), and
     * every aliasing of dst, m1 and m2 (the original stores each element while it still reads).
     */
    @Test fun mat4x4() {
        val base = m.calloc(3 * 128).toLong()
        extraAddr = base.toInt(); extraLen = 3 * 128
        fun fill(p: Long) {
            when (rnd.nextInt(3)) {
                0 -> { // what Sprite3/BomberGolf build: identity, rotations, scale, translation
                    k.callHolyC("Mat4x4IdentEqu", p)
                    k.callHolyC("Mat4x4RotZ", p, (rnd.nextDouble() * 7 - 3.5).toRawBits())
                    if (rnd.nextBoolean()) k.callHolyC("Mat4x4RotX", p, (rnd.nextDouble() * 7 - 3.5).toRawBits())
                    k.callHolyC("Mat4x4Scale", p, (0.25 + rnd.nextDouble() * 3).toRawBits())
                    k.callHolyC("Mat4x4TranslationEqu", p, (rnd.nextInt(2000) - 1000).toLong(), (rnd.nextInt(2000) - 1000).toLong(), (rnd.nextInt(200) - 100).toLong())
                }
                1 -> for (i in 0 until 16) m.st8(p.toInt() + 8 * i, rnd.nextLong() shr rnd.nextInt(40))
                else -> for (i in 0 until 16) m.st8(p.toInt() + 8 * i, rnd.nextLong())
            }
        }
        check("Mat4x4MulMat4x4Equ", 3000) {
            for (j in 0 until 3) fill(base + 128 * j)
            val pick = { base + 128L * rnd.nextInt(3) }
            when (rnd.nextInt(4)) {
                0 -> longArrayOf(base, base + 128, base + 256)          // distinct
                1 -> { val a = pick(); longArrayOf(a, a, base + 256) }   // dst == m1
                2 -> { val a = pick(); longArrayOf(a, base + 128, a) }   // dst == m2
                else -> longArrayOf(pick(), pick(), pick())
            }
        }
        extraAddr = 0; extraLen = 24
    }

    /**
     * Native DCLighting (Gr3Mesh's per-triangle shading) vs Adam/Gr/GrDC.HC: random triangles (small,
     * degenerate, and coordinates whose differences overflow I32), light vectors, and colors with every
     * combination of ROPBF_TWO_SIDED / ROPBF_HALF_RANGE_COLOR and stray high bits.
     */
    @Test fun lighting() {
        val dc = newDc(64, 48, false, false)
        val pts = LongArray(3) { m.calloc(12).toLong() }
        fun c(): Long = when (rnd.nextInt(4)) { 0 -> rnd.nextInt(400).toLong() - 200; 1 -> rnd.nextInt(60000).toLong() - 30000; 2 -> rnd.nextInt().toLong(); else -> 0L }
        check("DCLighting", 4000) {
            for (q in pts) { m.st4(q.toInt(), c()); m.st4(q.toInt() + 4, c()); m.st4(q.toInt() + 8, c()) }
            if (rnd.nextInt(8) == 0) { m.st4(pts[2].toInt(), m.ld4(pts[0].toInt())); m.st4(pts[2].toInt() + 4, m.ld4(pts[0].toInt() + 4)); m.st4(pts[2].toInt() + 8, m.ld4(pts[0].toInt() + 8)) }
            val ls = dcField(dc, "ls")
            if (rnd.nextBoolean()) { m.st4(ls, 37837); m.st4(ls + 4, 37837); m.st4(ls + 8, 37837) } // DCRst's light
            else { m.st4(ls, (rnd.nextInt(131072) - 65536).toLong()); m.st4(ls + 4, (rnd.nextInt(131072) - 65536).toLong()); m.st4(ls + 8, rnd.nextInt().toLong()) }
            m.st4(dcField(dc, "color"), rnd.nextInt().toLong()); m.st8(dcField(dc, "dither_probability_u16"), rnd.nextLong())
            val rop = intArrayOf(0, 0x10, 0x20, 0x30, rnd.nextInt(256))[rnd.nextInt(5)].toLong()
            val color = (rnd.nextInt(16).toLong() or (rop shl 8)) or (if (rnd.nextInt(5) == 0) rnd.nextInt(65536).toLong() shl 16 else 0L)
            longArrayOf(dc, pts[0], pts[1], pts[2], color)
        }
    }

    /**
     * Native GrPutChar vs Adam/Gr/GrBitMap.HC: every character code, positions clipped on all sides, plain
     * and screen DCs (window scroll and pixel offsets), EQU/XOR/MONO/COLLISION and an unknown ROP, and the
     * NEAREST / EXTENTS / DONT_DRAW flags.
     */
    @Test fun putChar() {
        val dcs = listOf(newDc(37, 29, false, false), newDc(64, 48, false, true), newDc(640, 480, true, false))
        val task = k.adamTask!!.fsAddr
        check("GrPutChar", 3000) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            val f = dcField(dc, "flags")
            var fl = m.ld4(f) and (0x800L or 0x1000L).inv()
            if (rnd.nextInt(6) == 0) { fl = fl or 0x800L; m.st4(dcField(dc, "cur_x"), coord(50)); m.st4(dcField(dc, "cur_y"), coord(40)); m.st8(dcField(dc, "nearest_dist"), rnd.nextInt(3000).toLong()) }
            if (rnd.nextInt(12) == 0) fl = fl or 0x1000L
            m.st4(f, fl)
            if (rnd.nextInt(10) == 0) m.st4(dcField(dc, "color"), (m.ld4(dcField(dc, "color")) and 0xFFFF00FFL) or (5L shl 8))
            if (fl and 0x4000L != 0L) {
                m.st8(task + k.o.task("scroll_x"), (rnd.nextInt(17) - 8).toLong()); m.st8(task + k.o.task("scroll_y"), (rnd.nextInt(17) - 8).toLong())
                m.st8(task + k.o.task("pix_left"), rnd.nextInt(20).toLong()); m.st8(task + k.o.task("pix_top"), rnd.nextInt(20).toLong())
                m.st8(task + k.o.task("pix_right"), (300 + rnd.nextInt(340)).toLong()); m.st8(task + k.o.task("pix_bottom"), (200 + rnd.nextInt(280)).toLong())
            }
            longArrayOf(dc, coord(if (fl and 0x4000L != 0L) 640 else 50), coord(if (fl and 0x4000L != 0L) 480 else 40), rnd.nextInt(256).toLong())
        }
    }

    /** Native Circle (8.24 rotation, callback per point) vs Adam/Gr/GrMath.HC, with GrPlot3 as the callback. */
    @Test fun circle() {
        val dcs = listOf(newDc(64, 48, false, true), newDc(640, 480, true, false))
        val plot3 = k.prog.funcPtr(k.prog.globals["GrPlot3"] as io.github.templeosmobile.core.holyc.FuncSym)
        check("Circle", 700) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            val step = when (rnd.nextInt(5)) { 0 -> -(1 + rnd.nextInt(3)).toLong(); 1 -> (2 + rnd.nextInt(3)).toLong(); 2 -> if (rnd.nextInt(4) == 0) 0L else 1L; else -> 1L }
            val start = when (rnd.nextInt(4)) { 0 -> 0.0; 1 -> -0.0; else -> rnd.nextDouble() * 7 - 3.5 }
            val len = when (rnd.nextInt(3)) { 0 -> 2 * Math.PI; 1 -> rnd.nextDouble() * 7; else -> -rnd.nextDouble() }
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(1000).toLong(), (rnd.nextInt(70) - 5).toLong(), plot3, step, start.toRawBits(), len.toRawBits())
        }
    }

    @Test fun line() {
        val dcs = listOf(newDc(64, 48, false, true), newDc(640, 480, true, false))
        val plot3 = k.prog.funcPtr(k.prog.globals["GrPlot3"] as io.github.templeosmobile.core.holyc.FuncSym)
        check("Line", 600) {
            val dc = dcs[rnd.nextInt(dcs.size)]; randomize(dc)
            val step = if (rnd.nextInt(3) == 0) rnd.nextInt(5).toLong() else 1L
            longArrayOf(dc, coord(60), coord(50), rnd.nextInt(1000).toLong(), coord(60), coord(50), rnd.nextInt(1000).toLong(),
                plot3, step, if (rnd.nextInt(4) == 0) rnd.nextInt(3).toLong() else 0L)
        }
    }

    /** Native SpriteSize/SpriteElemSize vs the original HolyC on every sprite embedded in the bundled programs. */
    @Test fun spriteSize() {
        val root = java.io.File(SHARED, "bundled-fs")
        var sprites = 0; var fails = 0
        root.walkTopDown().filter { it.isFile && (it.name.endsWith(".HC") || it.name.endsWith(".DD")) }.forEach { f ->
            val src = io.github.templeosmobile.core.holyc.SourceFile.parse(f.name, f.readBytes())
            for ((_, bin) in src.bins) {
                if (bin.isEmpty()) continue
                val a = m.malloc(bin.size + 64L)
                m.fill(a, 0, bin.size + 64)
                m.writeBytes(a, bin)
                // compare only data the native code accepts as a sprite (other binaries can make
                // the HolyC walk spin until its budget runs out)
                val n1 = try { k.callHolyC("SpriteSize", a.toLong()) } catch (e: Exception) { null }
                if (n1 == null) { m.free(a.toLong()); continue }
                val h1 = k.callHolyC("SpriteSize_HC", a.toLong())
                if (n1 != h1) { if (fails++ < 3) println("SpriteSize ${f.name}: native=$n1 hc=$h1") }
                val g = a.toLong() - k.o.member("CSprite", "start")
                val n2 = k.callHolyC("SpriteElemSize", g); val h2 = k.callHolyC("SpriteElemSize_HC", g)
                if (n2 != h2) { if (fails++ < 3) println("SpriteElemSize ${f.name}: native=$n2 hc=$h2") }
                sprites++
                m.free(a.toLong())
            }
        }
        println("spriteSize: $sprites sprites compared, $fails mismatches")
        assertTrue("sprites found", sprites > 100)
        assertEquals(0, fails)
    }
}
