import Foundation
import XCTest
@testable import TempleCore

/**
 * Differential test (port of RasterDiffTest.kt): native raster primitives (Raster.swift) must
 * match the original TempleOS HolyC (*_HC) exactly - pixels, depth buffer, collision count,
 * extents, return value and random-number consumption. Inputs come from a seeded SplitMix64
 * instead of java.util.Random; both runs of each case see the same inputs.
 */
final class RasterDiffTests: XCTestCase {
    private var k: Kernel!
    private var m: Arena { k.mem }
    private var rng: UInt64 = 1234
    private var tracked: [Int64] = []
    /** Extra scratch memory compared (DCReflect writes through pointers). */
    private var extraAddr = 0
    private var extraLen = 24

    override func setUpWithError() throws {
        k = Kernel(TestEnv(), "diff")
        try k.boot()
        rng = 1234; tracked = []; extraAddr = 0; extraLen = 24
    }

    private func next() -> UInt64 {
        rng &+= 0x9E37_79B9_7F4A_7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    private func nextInt(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    private func nextBool() -> Bool { next() & 1 == 1 }
    private func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }

    private func dcField(_ dc: Int64, _ f: String) -> Int { Int(dc) + k.o.dc(f) }

    private func newDc(_ w: Int64, _ h: Int64, _ screen: Bool, _ depth: Bool) throws -> Int64 {
        let dc = screen ? try k.callHolyC("DCAlias", k.gfx.grDc, Int64(k.adamTask!.fsAddr)) : try k.callHolyC("DCNew", w, h, 0, 0)
        if depth { _ = try k.callHolyC("DCDepthBufAlloc", dc) }
        tracked.append(dc)
        return dc
    }

    private func randomize(_ dc: Int64) {
        let body = Int(m.ld8(dcField(dc, "body")))
        let wi = Int(m.ld4(dcField(dc, "width_internal"))), h = Int(m.ld4(dcField(dc, "height")))
        for i in 0..<(wi * h) { m.st1(body + i, nextInt(4) == 0 ? 0xFF : Int64(nextInt(16))) }
        let db = m.ld8(dcField(dc, "depth_buf"))
        if db != 0 { for i in 0..<(wi * h) { m.st4(Int(db) + i * 4, Int64(nextInt(2000))) } }
        let rops = [0, 0, 0, 1, 2, 3]
        let c0 = Int64(nextInt(16)) | (Int64(rops[nextInt(rops.count)]) << 8)
        var color = c0 | (Int64(nextInt(16)) << 16)
        switch nextInt(4) { case 0: color |= 0x4000_0000; case 1: color |= 0x8000_0000; default: break }
        m.st4(dcField(dc, "color"), color)
        m.st4(dcField(dc, "bkcolor"), Int64(nextInt(16)))
        m.st8(dcField(dc, "dither_probability_u16"), Int64(nextInt(65536)))
        m.st8(dcField(dc, "collision_cnt"), 0)
        var flags = m.ld4(dcField(dc, "flags"))
        if nextInt(5) == 0 {
            flags |= 0x10000
            m.st8(dcField(dc, "min_x"), Int64.max); m.st8(dcField(dc, "max_x"), Int64.min)
            m.st8(dcField(dc, "min_y"), Int64.max); m.st8(dcField(dc, "max_y"), Int64.min)
        } else { flags &= ~0x10000 }
        m.st4(dcField(dc, "flags"), flags)
        m.st8(dcField(dc, "db_z"), Int64(nextInt(2500) - 200))
    }

    /** Bytes of every tracked DC: struct, body and depth buffer, plus the extra scratch bytes. */
    private func state() -> [UInt8] {
        var out: [UInt8] = []
        let sz = k.o.cls("CDC").size
        for dc in tracked {
            out += m.readBytes(Int(dc), sz)
            let wi = Int(m.ld4(dcField(dc, "width_internal"))), h = Int(m.ld4(dcField(dc, "height")))
            out += m.readBytes(Int(m.ld8(dcField(dc, "body"))), wi * h)
            let db = m.ld8(dcField(dc, "depth_buf"))
            if db != 0 { out += m.readBytes(Int(db), wi * h * 4) }
        }
        if extraAddr != 0 { out += m.readBytes(extraAddr, extraLen) }
        return out
    }

    // The arena bytes and the allocator (Arena.allocatorState): natives that MAlloc and Free (Gr3Mesh, Sprite3) must
    // leave the heap as the original does, and the second run must start from the same heap.
    private func snapshot() -> (Int, [UInt8], Arena.AllocatorState) { (m.size, m.readBytes(0, m.size), m.allocatorState) }
    private func restore(_ s: (Int, [UInt8], Arena.AllocatorState)) { m.writeBytes(0, s.1); m.allocatorState = s.2 }

    /** The generator's state: the current task's rand_seed, in the arena (restored with it). */
    private func seedNow() -> Int64 { k.current.map { m.ld8($0.fsAddr + k.o.task("rand_seed")) } ?? 0 }

    private func check(_ name: String, _ iters: Int, _ args: () throws -> [Int64]) throws {
        var fails = 0
        for iter in 0..<iters {
            let a = try args()
            // a fixed seed (TASKf_NONTIMER_RAND): unseeded, TempleOS's generator XORs in the time stamp counter, so the
            // fast path and the HolyC original would dither differently only because they run at different times (RasterDiffTest.kt)
            if let cur = k.current { _ = try k.seed(cur, 0x5EED + Int64(iter), 0) }
            let snap = snapshot()
            // a fault is a result too: both versions must fault, at the same address (a fault inside a native that the
            // HolyC original calls reaches here as an uncaught HolyC exception)
            func call(_ f: String) throws -> Int64 {
                do { return try k.callHolyC(f, a) } catch let e as VmFault { return faultCode(e.message) } catch let e as VmUncaught { return faultCode(e.message) }
            }
            let r1 = try call(name)
            let after1 = state(), rs1 = seedNow(), heap1 = m.allocatorState
            restore(snap)
            let r2 = try call(name + "_HC")
            let after2 = state(), rs2 = seedNow(), heap2 = m.allocatorState
            let same = after1.count == after2.count && after1.withUnsafeBytes { x in
                after2.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 } }
            if heap1 != heap2 && fails < 3 { print("\(name) #\(iter): the heap differs after the native and the HolyC") }
            if r1 != r2 || rs1 != rs2 || !same || heap1 != heap2 {
                let diffAt = same ? nil : after1.indices.first { $0 >= after2.count || after1[$0] != after2[$0] }
                if fails < 3 { print("\(name) mismatch #\(iter) args=\(a) ret native=\(r1) hc=\(r2) rng=\(rs1 == rs2) diffAt=\(String(describing: diffAt))") }
                fails += 1
            }
            restore(snap)
        }
        XCTAssertEqual(fails, 0, "\(name) mismatches")
    }

    private func faultCode(_ message: String) -> Int64 {
        let msg = message.components(separatedBy: "): ").last ?? message
        var h: Int64 = 0
        for b in msg.utf8 { h = h &* 31 &+ Int64(b) }
        return h | (1 << 62)
    }

    private func coord(_ n: Int) -> Int64 { Int64(nextInt(n + 80) - 40) }

    func testRect() throws {
        let dcs = [try newDc(37, 29, false, false), try newDc(64, 48, false, true), try newDc(640, 480, true, false)]
        try check("GrRect", 600) { let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(50), Int64(nextInt(40) - 3), Int64(nextInt(40) - 3)] }
    }

    func testHVLine() throws {
        let dcs = [try newDc(37, 29, false, true), try newDc(64, 48, false, false), try newDc(640, 480, true, true)]
        try check("GrHLine", 600) { let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(60), coord(50), Int64(nextInt(3000) - 500), Int64(nextInt(3000) - 500)] }
        try check("GrVLine", 600) { let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(50), coord(50), Int64(nextInt(3000) - 500), Int64(nextInt(3000) - 500)] }
    }

    func testPlotPeek() throws {
        let dcs = [try newDc(37, 29, false, true), try newDc(640, 480, true, false)]
        for f in ["GrPlot", "GrPlot1", "GrPeek"] {
            try check(f, 400) { let dc = dcs[nextInt(dcs.count)]; randomize(dc); return [dc, coord(50), coord(40)] }
        }
    }

    func testBlot() throws {
        let dcs = [try newDc(37, 29, false, false), try newDc(640, 480, true, false)]
        let imgs = [try newDc(9, 7, false, false), try newDc(16, 16, false, false), try newDc(3, 20, false, false)]
        try check("GrBlot", 600) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            let img = imgs[nextInt(imgs.count)]; randomize(img)
            let f = dcField(img, "flags")
            m.st4(f, nextBool() ? m.ld4(f) | 0x100000 : m.ld4(f) & ~0x100000)
            return [dc, coord(50), coord(40), img]
        }
    }

    func testFillTri() throws {
        let dcs = [try newDc(37, 29, false, true), try newDc(64, 48, false, false), try newDc(640, 480, true, true)]
        let pts = try (0..<3).map { _ in Int64(try m.calloc(12)) }
        try check("GrFillTri0", 1500) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            for q in pts {
                m.st4(Int(q), Int64(nextInt(120) - 30)); m.st4(Int(q) + 4, Int64(nextInt(100) - 25))
                m.st4(Int(q) + 8, Int64(nextInt(2400) - 200))
            }
            if nextInt(6) == 0 { m.st4(Int(pts[1]) + 4, m.ld4(Int(pts[0]) + 4)) }
            return [dc, pts[0], pts[1], pts[2]]
        }
    }

    func testBlot3() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, true), try newDc(640, 480, true, false)]
        let imgs = [try newDc(9, 7, false, false), try newDc(16, 12, false, false)]
        try check("GrBlot3", 500) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            let img = imgs[nextInt(imgs.count)]; randomize(img)
            let f = dcField(dc, "flags")
            if nextBool() {
                m.st4(f, m.ld4(f) | 0x100)
                let r = m.ld8(dcField(dc, "r"))
                _ = try k.callHolyC("Mat4x4IdentEqu", r)
                _ = try k.callHolyC("Mat4x4RotZ", r, Int64(bitPattern: (nextDouble() * 6).bitPattern))
                _ = try k.callHolyC("Mat4x4Scale", r, Int64(bitPattern: (0.5 + nextDouble() * 2).bitPattern))
                m.st4(dcField(dc, "x"), coord(40)); m.st4(dcField(dc, "y"), coord(40))
            } else { m.st4(f, m.ld4(f) & ~0x100) }
            // symmetry (mirrored copy first, then the normal one unless DCF_JUST_MIRROR)
            if nextInt(3) == 0 {
                _ = try k.callHolyC("DCSymmetrySet", dc, coord(50), coord(40), coord(50), coord(40))
                let fl = m.ld4(f) | 0x200
                m.st4(f, nextBool() ? fl | 0x400 : fl & ~0x400)
            } else { m.st4(f, m.ld4(f) & ~0x600) }
            return [dc, coord(50), coord(40), Int64(nextInt(1500)), img]
        }
    }

    func testReflect() throws {
        let dc = try newDc(64, 48, false, false)
        let px = Int64(try m.calloc(24))
        extraAddr = Int(px)
        try check("DCReflect", 400) {
            _ = try k.callHolyC("DCSymmetrySet", dc, coord(50), coord(40), coord(50), coord(40))
            m.st8(Int(px), coord(60)); m.st8(Int(px) + 8, coord(60)); m.st8(Int(px) + 16, coord(60))
            return [dc, px, px + 8, px + 16]
        }
    }

    func testFat() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, false)]
        try check("GrLineFat3", 800) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(50), Int64(nextInt(1000)), coord(60), coord(50), Int64(nextInt(1000)),
                    Int64(nextInt(80) - 3), Int64(nextInt(4))]
        }
        try check("GrFillCircle", 300) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(50), Int64(nextInt(1000)), Int64(nextInt(90) - 3)]
        }
        try check("GrFillSemiCircle", 500) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            return [dc, coord(60), coord(50), Int64(nextInt(1000)), Int64(nextInt(90) - 3), Int64(nextInt(8))]
        }
    }

    /**
     * Native Mat4x4MulMat4x4Equ (Sprite3 with DCF_TRANSFORMATION) vs Adam/Gr/GrMath.HC: rotation and
     * scale matrices as programs build them, raw random words (F64 rounding, overflow to I64_MIN), and
     * every aliasing of dst, m1 and m2 (the original stores each element while it still reads).
     */
    func testMat4x4() throws {
        let base = Int64(try m.calloc(3 * 128))
        extraAddr = Int(base); extraLen = 3 * 128
        func fill(_ p: Int64) throws {
            switch nextInt(3) {
            case 0: // what Sprite3/BomberGolf build: identity, rotations, scale, translation
                _ = try k.callHolyC("Mat4x4IdentEqu", p)
                _ = try k.callHolyC("Mat4x4RotZ", p, Int64(bitPattern: (nextDouble() * 7 - 3.5).bitPattern))
                if nextBool() { _ = try k.callHolyC("Mat4x4RotX", p, Int64(bitPattern: (nextDouble() * 7 - 3.5).bitPattern)) }
                _ = try k.callHolyC("Mat4x4Scale", p, Int64(bitPattern: (0.25 + nextDouble() * 3).bitPattern))
                _ = try k.callHolyC("Mat4x4TranslationEqu", p, Int64(nextInt(2000) - 1000), Int64(nextInt(2000) - 1000), Int64(nextInt(200) - 100))
            case 1: for i in 0..<16 { m.st8(Int(p) + 8 * i, Int64(bitPattern: next()) >> Int64(nextInt(40))) }
            default: for i in 0..<16 { m.st8(Int(p) + 8 * i, Int64(bitPattern: next())) }
            }
        }
        try check("Mat4x4MulMat4x4Equ", 3000) {
            for j in 0..<3 { try fill(base + 128 * Int64(j)) }
            let pick = { base + 128 * Int64(self.nextInt(3)) }
            switch nextInt(4) {
            case 0: return [base, base + 128, base + 256]          // distinct
            case 1: let a = pick(); return [a, a, base + 256]       // dst == m1
            case 2: let a = pick(); return [a, base + 128, a]       // dst == m2
            default: return [pick(), pick(), pick()]
            }
        }
        extraAddr = 0; extraLen = 24
    }

    /**
     * Native DCLighting (Gr3Mesh's per-triangle shading) vs Adam/Gr/GrDC.HC: random triangles (small,
     * degenerate, and coordinates whose differences overflow I32), light vectors, and colors with every
     * combination of ROPBF_TWO_SIDED / ROPBF_HALF_RANGE_COLOR and stray high bits.
     */
    func testLighting() throws {
        let dc = try newDc(64, 48, false, false)
        let pts = try (0..<3).map { _ in Int64(try m.calloc(12)) }
        func c() -> Int64 {
            switch nextInt(4) {
            case 0: return Int64(nextInt(400) - 200)
            case 1: return Int64(nextInt(60000) - 30000)
            case 2: return Int64(Int32(truncatingIfNeeded: next()))
            default: return 0
            }
        }
        try check("DCLighting", 4000) {
            for q in pts { m.st4(Int(q), c()); m.st4(Int(q) + 4, c()); m.st4(Int(q) + 8, c()) }
            if nextInt(8) == 0 { for o in [0, 4, 8] { m.st4(Int(pts[2]) + o, m.ld4(Int(pts[0]) + o)) } }
            let ls = dcField(dc, "ls")
            if nextBool() { m.st4(ls, 37837); m.st4(ls + 4, 37837); m.st4(ls + 8, 37837) } // DCRst's light
            else { m.st4(ls, Int64(nextInt(131072) - 65536)); m.st4(ls + 4, Int64(nextInt(131072) - 65536)); m.st4(ls + 8, Int64(Int32(truncatingIfNeeded: next()))) }
            m.st4(dcField(dc, "color"), Int64(Int32(truncatingIfNeeded: next()))); m.st8(dcField(dc, "dither_probability_u16"), Int64(bitPattern: next()))
            let rops: [Int64] = [0, 0x10, 0x20, 0x30, Int64(nextInt(256))]
            let rop = rops[nextInt(5)]
            let color = (Int64(nextInt(16)) | (rop << 8)) | (nextInt(5) == 0 ? Int64(nextInt(65536)) << 16 : 0)
            return [dc, pts[0], pts[1], pts[2], color]
        }
    }

    /**
     * Native GrPutChar vs Adam/Gr/GrBitMap.HC: every character code, positions clipped on all sides, plain
     * and screen DCs (window scroll and pixel offsets), EQU/XOR/MONO/COLLISION and an unknown ROP, and the
     * NEAREST / EXTENTS / DONT_DRAW flags.
     */
    func testPutChar() throws {
        let dcs = [try newDc(37, 29, false, false), try newDc(64, 48, false, true), try newDc(640, 480, true, false)]
        let task = Int(k.adamTask!.fsAddr)
        try check("GrPutChar", 3000) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            let f = dcField(dc, "flags")
            var fl = m.ld4(f) & ~Int64(0x800 | 0x1000)
            if nextInt(6) == 0 { fl |= 0x800; m.st4(dcField(dc, "cur_x"), coord(50)); m.st4(dcField(dc, "cur_y"), coord(40)); m.st8(dcField(dc, "nearest_dist"), Int64(nextInt(3000))) }
            if nextInt(12) == 0 { fl |= 0x1000 }
            m.st4(f, fl)
            if nextInt(10) == 0 { m.st4(dcField(dc, "color"), (m.ld4(dcField(dc, "color")) & 0xFFFF00FF) | (5 << 8)) }
            let screen = fl & 0x4000 != 0
            if screen {
                m.st8(task + k.o.task("scroll_x"), Int64(nextInt(17) - 8)); m.st8(task + k.o.task("scroll_y"), Int64(nextInt(17) - 8))
                m.st8(task + k.o.task("pix_left"), Int64(nextInt(20))); m.st8(task + k.o.task("pix_top"), Int64(nextInt(20)))
                m.st8(task + k.o.task("pix_right"), Int64(300 + nextInt(340))); m.st8(task + k.o.task("pix_bottom"), Int64(200 + nextInt(280)))
            }
            return [dc, coord(screen ? 640 : 50), coord(screen ? 480 : 40), Int64(nextInt(256))]
        }
    }

    /** Native Circle (8.24 rotation, callback per point) vs Adam/Gr/GrMath.HC, with GrPlot3 as the callback. */
    func testCircle() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, false)]
        let plot3 = k.prog.funcPtr(k.prog.globals["GrPlot3"] as! FuncSym)
        try check("Circle", 700) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            let step: Int64
            switch nextInt(5) {
            case 0: step = -Int64(1 + nextInt(3))
            case 1: step = Int64(2 + nextInt(3))
            case 2: step = nextInt(4) == 0 ? 0 : 1
            default: step = 1
            }
            let start: Double
            switch nextInt(4) { case 0: start = 0.0; case 1: start = -0.0; default: start = nextDouble() * 7 - 3.5 }
            let len: Double
            switch nextInt(3) { case 0: len = 2 * Double.pi; case 1: len = nextDouble() * 7; default: len = -nextDouble() }
            return [dc, coord(60), coord(50), Int64(nextInt(1000)), Int64(nextInt(70) - 5), plot3, step,
                    Int64(bitPattern: start.bitPattern), Int64(bitPattern: len.bitPattern)]
        }
    }

    func testLine() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, false)]
        let plot3 = k.prog.funcPtr(k.prog.globals["GrPlot3"] as! FuncSym)
        try check("Line", 600) {
            let dc = dcs[nextInt(dcs.count)]; randomize(dc)
            let step: Int64 = nextInt(3) == 0 ? Int64(nextInt(5)) : 1
            return [dc, coord(60), coord(50), Int64(nextInt(1000)), coord(60), coord(50), Int64(nextInt(1000)),
                    plot3, step, nextInt(4) == 0 ? Int64(nextInt(3)) : 0]
        }
    }

    /** Native SpriteSize/SpriteElemSize vs the original HolyC on every sprite embedded in the bundled programs. */
    func testSpriteSize() throws {
        let root = SHARED.appendingPathComponent("bundled-fs")
        var sprites = 0, fails = 0
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in en where url.lastPathComponent.hasSuffix(".HC") || url.lastPathComponent.hasSuffix(".DD") {
            guard let raw = readFileBytes(url) else { continue }
            let src = SourceFile.parse(url.lastPathComponent, raw)
            for (_, bin) in src.bins where !bin.isEmpty {
                let a = try m.malloc(Int64(bin.count + 64))
                m.fill(a, 0, bin.count + 64)
                m.writeBytes(a, bin)
                // compare only data the native code accepts as a sprite (other binaries can make
                // the HolyC walk spin until its budget runs out)
                guard let n1 = try? k.callHolyC("SpriteSize", Int64(a)) else { try m.free(Int64(a)); continue }
                let h1 = try k.callHolyC("SpriteSize_HC", Int64(a))
                if n1 != h1 { if fails < 3 { print("SpriteSize \(url.lastPathComponent): native=\(n1) hc=\(h1)") }; fails += 1 }
                let g = Int64(a - k.o.member("CSprite", "start"))
                let n2 = try k.callHolyC("SpriteElemSize", g), h2 = try k.callHolyC("SpriteElemSize_HC", g)
                if n2 != h2 { if fails < 3 { print("SpriteElemSize \(url.lastPathComponent): native=\(n2) hc=\(h2)") }; fails += 1 }
                sprites += 1
                try m.free(Int64(a))
            }
        }
        print("spriteSize: \(sprites) sprites compared, \(fails) mismatches")
        XCTAssertGreaterThan(sprites, 100, "sprites found")
        XCTAssertEqual(fails, 0)
    }

    // MARK: GrLine3, GrFillPoly3, Gr3Mesh, Sprite3, Mat4x4Scale (port of RasterDiffTest.kt)

    private var customTransformPtr: Int64 = 0
    /** HolyC callbacks a program can install: a Varoom-style perspective transform (dc->transform), its divisor kept >= 200 so random points stay near the screen (a far point makes GrLineFat3 walk for minutes on both sides). */
    private func customTransform() throws -> Int64 {
        if customTransformPtr != 0 { return customTransformPtr }
        let src = "U0 DiffTransform(CDC *dc,I64 *x,I64 *y,I64 *z)\n{\n  I64 zz;\n  Mat4x4MulXYZ(dc->r,x,y,z);\n  zz=400+*z;\n" +
            "  if (zz<200) zz=200;\n  *x=400* *x/zz;\n  *y=400* *y/zz;\n  *x+=dc->x;\n  *y+=dc->y;\n  *z+=dc->z;\n}\n"
        try k.runProgram("C:/Home/DiffTransform.HC", Array(src.utf8))
        customTransformPtr = k.prog.funcPtr(k.prog.globals["DiffTransform"] as! FuncSym)
        // Raster.transform allocates its callback scratch block on first use and keeps it: allocate it now, before
        // any snapshot, or restoring the heap would hand that block to the HolyC run
        let dc = try k.callHolyC("DCNew", 8, 8, 0, 0)
        m.st4(dcField(dc, "flags"), m.ld4(dcField(dc, "flags")) | 0x100); m.st8(dcField(dc, "transform"), customTransformPtr)
        _ = try k.callHolyC("GrLine3", dc, 0, 0, 0, 1, 1, 0, 1, 0)
        return customTransformPtr
    }

    /** Random 3D state: transformation (default or HolyC transform), symmetry, just-mirror, thick, brush. */
    private func randomize3(_ dc: Int64, _ brushes: [Int64] = []) throws {
        randomize(dc)
        let f = dcField(dc, "flags")
        if nextInt(3) != 0 {
            m.st4(f, m.ld4(f) | 0x100)
            let r = m.ld8(dcField(dc, "r"))
            _ = try k.callHolyC("Mat4x4IdentEqu", r)
            _ = try k.callHolyC("Mat4x4RotZ", r, Int64(bitPattern: (nextDouble() * 7 - 3.5).bitPattern))
            if nextBool() { _ = try k.callHolyC("Mat4x4RotX", r, Int64(bitPattern: (nextDouble() * 7 - 3.5).bitPattern)) }
            if nextBool() { _ = try k.callHolyC("Mat4x4RotY", r, Int64(bitPattern: (nextDouble() * 7 - 3.5).bitPattern)) }
            _ = try k.callHolyC("Mat4x4Scale", r, Int64(bitPattern: (0.3 + nextDouble() * 2.5).bitPattern))
            _ = try k.callHolyC("DCMat4x4Set", dc, r)
            m.st4(dcField(dc, "x"), coord(40)); m.st4(dcField(dc, "y"), coord(40)); m.st4(dcField(dc, "z"), Int64(nextInt(600)))
            m.st8(dcField(dc, "transform"), nextInt(3) == 0 ? try customTransform() : k.raster.dcTransformPtr)
        } else { m.st4(f, m.ld4(f) & ~0x100) }
        if nextInt(3) == 0 {
            _ = try k.callHolyC("DCSymmetrySet", dc, coord(50), coord(40), coord(50), coord(40))
            let v = m.ld4(f) | 0x200
            m.st4(f, nextInt(3) == 0 ? v | 0x400 : v & ~0x400)
        } else { m.st4(f, m.ld4(f) & ~0x600) }
        m.st4(dcField(dc, "thick"), nextBool() ? 1 : Int64(nextInt(7) - 1))
        m.st8(dcField(dc, "brush"), !brushes.isEmpty && nextInt(8) == 0 ? brushes[nextInt(brushes.count)] : 0)
    }

    func testLine3() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(64, 48, false, false), try newDc(640, 480, true, false), try newDc(640, 480, true, true)]
        let brushes = [try newDc(3, 3, false, false)]
        _ = try customTransform()
        try check("GrLine3", 2500) {
            let dc = dcs[nextInt(dcs.count)]; try randomize3(dc, brushes)
            let step: Int64 = { switch nextInt(6) { case 0: return 2; case 1: return 3; default: return 1 } }()
            let start: Int64 = nextInt(5) == 0 ? Int64(nextInt(3)) : 0
            return [dc, coord(70), coord(60), Int64(nextInt(1200) - 100), coord(70), coord(60), Int64(nextInt(1200) - 100), step, start]
        }
    }

    func testFillPoly3() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(64, 48, false, false), try newDc(640, 480, true, true)]
        let poly = try m.calloc(12 * 8)
        _ = try customTransform()
        try check("GrFillPoly3", 2000) {
            let dc = dcs[nextInt(dcs.count)]; try randomize3(dc)
            let n = Int64(nextInt(8))
            for i in 0..<8 {
                m.st4(poly + 12 * i, coord(80)); m.st4(poly + 12 * i + 4, coord(70)); m.st4(poly + 12 * i + 8, Int64(nextInt(1500) - 100))
            }
            return [dc, n, Int64(poly)]
        }
    }

    func testMesh3() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, true), try newDc(64, 48, false, false)]
        let pts = try m.calloc(12 * 12), tris = try m.calloc(16 * 16)
        _ = try customTransform()
        try check("Gr3Mesh", 1500) {
            let dc = dcs[nextInt(dcs.count)]; try randomize3(dc)
            let vc = 3 + nextInt(10), tc = nextInt(16)
            for i in 0..<vc { m.st4(pts + 12 * i, coord(60)); m.st4(pts + 12 * i + 4, coord(50)); m.st4(pts + 12 * i + 8, coord(80)) }
            for i in 0..<tc {
                let c = Int64(nextInt(16)) | (nextInt(4) == 0 ? 0x2000 : 0) | (nextInt(4) == 0 ? 0x1000 : 0)
                m.st4(tris + 16 * i, c)
                for j in 0..<3 { m.st4(tris + 16 * i + 4 + 4 * j, Int64(nextInt(vc))) }
            }
            return [dc, Int64(vc), Int64(pts), Int64(tc), Int64(tris)]
        }
    }

    func testMat4x4Scale() throws {
        let base = try m.calloc(128)
        extraAddr = base; extraLen = 128
        try check("Mat4x4Scale", 2000) {
            for i in 0..<16 {
                let v: Int64 = { switch nextInt(3) { case 0: return Int64(bitPattern: next()); case 1: return Int64(bitPattern: next()) >> Int64(nextInt(50)); default: return Int64(nextInt(200) - 100) << 32 } }()
                m.st8(base + 8 * i, v)
            }
            let sc: Double = { switch nextInt(5) { case 0: return Double.nan; case 1: return 1e30; case 2: return -nextDouble() * 4; default: return nextDouble() * 4 } }()
            return [Int64(base), Int64(bitPattern: sc.bitPattern)]
        }
        extraAddr = 0; extraLen = 24
    }

    /** A synthetic sprite with the element types the bundled sprites rarely use (symmetry, transform on/off, shift, ...). */
    private func syntheticSprite() -> [UInt8] {
        var out: [UInt8] = []
        func i32(_ v: Int) { for b in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * b))) } }
        func c() -> Int { nextInt(60) - 30 }
        for _ in 0..<(1 + nextInt(10)) {
            switch nextInt(13) {
            case 0: out.append(1); out.append(UInt8(nextInt(16)))                                      // COLOR
            case 1: out.append(2); out.append(UInt8(nextInt(16))); out.append(UInt8(nextInt(16)))      // DITHER_COLOR
            case 2: out.append(3); i32(nextInt(6))                                                     // THICK
            case 3: out.append(4); for _ in 0..<4 { i32(c()) }                                         // PLANAR_SYMMETRY
            case 4: out.append(5)                                                                      // TRANSFORM_ON
            case 5: out.append(6)                                                                      // TRANSFORM_OFF
            case 6: out.append(7); i32(c()); i32(c())                                                  // SHIFT
            case 7, 8: out.append(10); for _ in 0..<4 { i32(c()) }                                     // LINE
            case 9: let n = nextInt(5); out.append(11); i32(n); for _ in 0..<(2 * n) { i32(c()) }       // POLYLINE
            case 10: out.append(12); for _ in 0..<4 { i32(c()) }                                       // RECT (original)
            case 11: out.append(8); i32(c()); i32(c())                                                 // PT (original)
            default: out.append(14); i32(c()); i32(c()); i32(nextInt(12))                              // CIRCLE (original)
            }
        }
        out.append(0)
        return out
    }

    func testSprite3() throws {
        let dcs = [try newDc(64, 48, false, true), try newDc(640, 480, true, true), try newDc(640, 480, true, false), try newDc(96, 64, false, false)]
        _ = try customTransform()
        var sprites: [[UInt8]] = []
        let root = SHARED.appendingPathComponent("bundled-fs")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "HC" || $0.pathExtension == "DD" }.sorted { $0.path < $1.path }
        for url in files {
            guard let raw = try? [UInt8](Data(contentsOf: url)) else { continue }
            for (_, bin) in SourceFile.parse(url.lastPathComponent, raw).bins where !bin.isEmpty && bin.count <= 40000 {
                let a = try m.malloc(Int64(bin.count + 64)); m.fill(a, 0, bin.count + 64); m.writeBytes(a, bin)
                let ok = (try? k.callHolyC("SpriteSize", Int64(a))) != nil // only real sprites
                try m.free(Int64(a))
                if ok { sprites.append(bin) }
            }
        }
        for _ in 0..<150 { sprites.append(syntheticSprite()) }
        XCTAssertGreaterThan(sprites.count, 300, "sprites found")
        let buf = try m.malloc(40000 + 64)
        var i = 0
        try check("Sprite3", sprites.count * 3) {
            let bin = sprites[i % sprites.count]; i += 1
            // all of it: a sprite whose data ends early (one bundled mesh) must read zeros past its end, not the last sprite
            m.fill(buf, 0, 40000 + 64); m.writeBytes(buf, bin)
            let dc = dcs[nextInt(dcs.count)]; try randomize3(dc)
            let f = dcField(dc, "flags")
            m.st4(f, nextInt(10) == 0 ? m.ld4(f) | 0x800 : m.ld4(f) & ~0x800) // DCF_LOCATE_NEAREST
            return [dc, coord(80), coord(60), Int64(nextInt(800)), Int64(buf), nextInt(8) == 0 ? 1 : 0]
        }
        print("sprite3: \(sprites.count) sprites")
    }
}
