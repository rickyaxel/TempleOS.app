import Foundation

/**
 * The program's isolated memory: a little-endian byte address space. The heap starts at
 * [GUARD]; the low 64 KiB below it are ordinary zero-filled memory, because TempleOS
 * identity-maps low memory (Doc/MemOverview.DD) and a NULL+offset access reads or writes it
 * without a fault (VM-verified). Outside the arena faults.
 *
 * Unlike the Kotlin version (a growable LongArray), the Swift arena reserves
 * [maxBytes] once with calloc: untouched pages are never made resident, and
 * the base pointer never moves, so the interpreter can cache it. [size] is the
 * logical size that grows exactly like the Kotlin arena (same faults, same
 * addresses, same OutMem behaviour).
 */
public final class Arena {
    public let maxBytes: Int
    public private(set) var size: Int
    public let base: UnsafeMutableRawPointer

    public static let GUARD = 0x10000
    public static let HDR = 16
    /**
     * Block header: [p-16] the block size, [p-8] a tag in the high half and, in the low half, the
     * size/8 for a used block (a forged size is caught) or the next free block of the same size.
     * The link lives in the header, not in the block, because TempleOS's Free leaves a freed block's
     * bytes as they were (Kernel/Mem/MAllocFree.HC links CMemUnused.next through the header), and
     * programs rely on that: Talons' AnimateTask walks panels the restart has just freed.
     */
    public static let USED_TAG: Int64 = 0x55534544  // "DESU"
    public static let FREE_TAG: Int64 = 0x45455246  // "FREE"
    public static let STACK_TAG: Int64 = 0x4B415453 // "STAK"
    static func headerWord(_ tag: Int64, _ low: Int64) -> Int64 { (tag << 32) | (low & 0xFFFFFFFF) }
    static func freeWord(_ next: Int) -> Int64 { headerWord(FREE_TAG, Int64(next)) }
    /**
     * Sizes as TempleOS rounds them (Kernel/Mem/MAllocFree.HC _MALLOC): requests are rounded up to
     * 8 bytes and, below MEM_HEAP_HASH_SIZE (1024), reused by exact size (heap_hash); bigger ones
     * take MEM_PAG_SIZE (512-byte) pages, and a free one up to twice the size is reused here.
     */
    public static let SMALL_MAX: Int64 = 1024
    public static let PAGE: Int64 = 512
    public static let BAD_MEM = chCode("BadMem")
    public static let BAD_FREE = chCode("BadFree")
    public static let OUT_MEM = chCode("OutMem")

    public init(_ initialBytes: Int, _ maxBytes: Int) {
        self.maxBytes = maxBytes
        self.size = initialBytes
        // +16: unaligned 8-byte accesses near the end stay inside the allocation
        guard let p = Darwin.calloc(maxBytes + 16, 1) else { fatalError("arena reservation failed") }
        base = p
        top = Arena.GUARD
    }

    deinit { Darwin.free(base) }

    // MARK: checks

    @inlinable @inline(__always) public func check(_ a: Int64, _ n: Int) throws -> Int {
        if n < 0 || a < 0 || a > Int64(size - n) { try fault(a) }
        return Int(a)
    }

    /**
     * Checks a [rows] x [n] byte rectangle whose rows are [stride] bytes apart
     * (a device context's program-writable width_internal): the whole span
     * a .. a+(rows-1)*stride+n must be inside the arena. Returns a.
     */
    public func checkRows(_ a: Int64, _ stride: Int64, _ rows: Int64, _ n: Int64) throws -> Int {
        if rows <= 0 || n <= 0 { return try check(a, 0) }
        if stride < 0 || stride > Int64(Int32.max) || rows > Int64(Int32.max) || n > Int64(Int32.max) { try fault(a) }
        let len = (rows - 1) * stride + n
        if len > Int64(Int32.max) { try fault(a) }
        return try check(a, Int(len))
    }

    public func fault(_ a: Int64) throws -> Never {
        throw VmFault(Arena.BAD_MEM, "invalid memory access at 0x\(hex(a))")
    }

    // MARK: raw access (address already checked)

    @inlinable @inline(__always) public func ld8(_ a: Int) -> Int64 { base.loadUnaligned(fromByteOffset: a, as: Int64.self) }
    @inlinable @inline(__always) public func ld1(_ a: Int) -> Int64 { Int64(base.load(fromByteOffset: a, as: UInt8.self)) }
    @inlinable @inline(__always) public func ld2(_ a: Int) -> Int64 { Int64(base.loadUnaligned(fromByteOffset: a, as: UInt16.self)) }
    @inlinable @inline(__always) public func ld4(_ a: Int) -> Int64 { Int64(base.loadUnaligned(fromByteOffset: a, as: UInt32.self)) }

    @inlinable @inline(__always) public func st8(_ a: Int, _ v: Int64) { base.storeBytes(of: v, toByteOffset: a, as: Int64.self) }
    @inlinable @inline(__always) public func st1(_ a: Int, _ v: Int64) { base.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: a, as: UInt8.self) }
    @inlinable @inline(__always) public func st2(_ a: Int, _ v: Int64) { base.storeBytes(of: UInt16(truncatingIfNeeded: v), toByteOffset: a, as: UInt16.self) }
    @inlinable @inline(__always) public func st4(_ a: Int, _ v: Int64) { base.storeBytes(of: UInt32(truncatingIfNeeded: v), toByteOffset: a, as: UInt32.self) }

    @inline(__always) public func getByte(_ a: Int) -> Int { Int(base.load(fromByteOffset: a, as: UInt8.self)) }

    /** Byte pointer at an (already checked) address. */
    @inline(__always) public func ptr(_ a: Int) -> UnsafeMutablePointer<UInt8> { (base + a).assumingMemoryBound(to: UInt8.self) }

    // MARK: bulk

    public func copy(_ dst: Int, _ src: Int, _ n: Int) {
        if n <= 0 { return }
        memmove(base + dst, base + src, n)
    }

    public func fill(_ dst: Int, _ b: Int, _ n: Int) {
        if n <= 0 { return }
        memset(base + dst, Int32(b & 0xFF), n)
    }

    public func readBytes(_ a: Int, _ n: Int) -> [UInt8] {
        if n <= 0 { return [] }
        return Array(UnsafeBufferPointer(start: ptr(a), count: n))
    }

    public func writeBytes(_ a: Int, _ b: [UInt8], _ off: Int = 0, _ len: Int? = nil) {
        let l = len ?? (b.count - off)
        if l <= 0 { return }
        b.withUnsafeBufferPointer { bp in _ = memcpy(base + a, bp.baseAddress! + off, l) }
    }

    /** Length of the NUL-terminated string at a (bounded by the arena). */
    public func strLen(_ a: Int) throws -> Int {
        let lim = size
        if a >= lim { try fault(Int64(lim)) }
        if let z = memchr(base + a, 0, lim - a) { return (z - (base + a)) }
        try fault(Int64(lim))
    }

    public func readStr(_ a: Int64) throws -> String {
        if a == 0 { return "" }
        let p = try check(a, 1)
        return latin1(UnsafeBufferPointer(start: ptr(p), count: try strLen(p)))
    }

    public func readStrBytes(_ a: Int64) throws -> [UInt8] {
        if a == 0 { return [] }
        let p = try check(a, 1)
        return readBytes(p, try strLen(p))
    }

    // MARK: heap

    private var top: Int
    /** Free small blocks by size/8, linked through their headers. */
    private var smallFree = [Int](repeating: 0, count: Int(Arena.SMALL_MAX / 8) + 1)
    /** Free large blocks: size -> first block of that size; [largeSizes] keeps the sizes sorted. */
    private var largeFree: [Int64: Int] = [:]
    private var largeSizes: [Int64] = []
    public private(set) var allocated: Int64 = 0
    /** Most bytes ever allocated at once, and the bump pointer's high-water mark (memory reports). */
    public private(set) var peakAllocated: Int64 = 0
    public var highWater: Int { top }

    private func ensure(_ bytes: Int64) throws {
        if bytes <= Int64(size) { return }
        if bytes > Int64(maxBytes) { throw VmFault(Arena.OUT_MEM, "out of memory: program limit is \(maxBytes / (1024 * 1024)) MiB") }
        var ns = Int64(size)
        while ns < bytes { ns *= 2 }
        ns = min(ns, Int64(maxBytes))
        size = Int(ns)
    }

    private func blockSizeFor(_ n: Int64) -> Int64 {
        n <= Arena.SMALL_MAX ? (max(n, 8) + 7) & -8 : (n + Arena.PAGE - 1) & -Arena.PAGE
    }

    private func freeHead(_ bsize: Int64) -> Int { bsize <= Arena.SMALL_MAX ? smallFree[Int(bsize >> 3)] : largeFree[bsize] ?? 0 }

    /** First index in [largeSizes] whose size is >= [n]. */
    private func largeIndex(_ n: Int64) -> Int {
        var lo = 0, hi = largeSizes.count
        while lo < hi { let m = (lo + hi) / 2; if largeSizes[m] < n { lo = m + 1 } else { hi = m } }
        return lo
    }

    private func setFreeHead(_ bsize: Int64, _ p: Int) {
        if bsize <= Arena.SMALL_MAX { smallFree[Int(bsize >> 3)] = p; return }
        if p == 0 {
            if largeFree.removeValue(forKey: bsize) != nil { largeSizes.remove(at: largeIndex(bsize)) }
        } else {
            if largeFree[bsize] == nil { largeSizes.insert(bsize, at: largeIndex(bsize)) }
            largeFree[bsize] = p
        }
    }

    public func malloc(_ n0: Int64) throws -> Int {
        if n0 < 0 || n0 > Int64(maxBytes) { throw VmFault(Arena.OUT_MEM, "out of memory: MAlloc(\(n0))") }
        var bsize = blockSizeFor(n0)
        var p = freeHead(bsize)
        if p == 0 && bsize > Arena.SMALL_MAX {
            // best fit among free large blocks, wasting at most as much as the request
            let i = largeIndex(bsize)
            if i < largeSizes.count && largeSizes[i] <= 2 * bsize { bsize = largeSizes[i]; p = largeFree[bsize] ?? 0 }
        }
        if p != 0 {
            // Headers and links live in program-writable memory: verify before trusting them.
            let next = ld8(p - 8) & 0xFFFFFFFF
            if !isFreeBlock(Int64(p), bsize) || (next != 0 && !isFreeBlock(next, bsize)) {
                throw VmFault(Arena.BAD_MEM, "heap corruption detected in MAlloc (block 0x\(hex(Int64(p))))")
            }
            setFreeHead(bsize, Int(next))
        } else {
            let need = Int64(top) + Int64(Arena.HDR) + bsize
            try ensure(need)
            p = top + Arena.HDR
            top = Int(need)
            st8(p - 16, bsize)
        }
        st8(p - 8, Arena.headerWord(Arena.USED_TAG, bsize >> 3))
        allocated += bsize
        if allocated > peakAllocated { peakAllocated = allocated }
        return p
    }

    public func calloc(_ n: Int64) throws -> Int {
        let p = try malloc(n)
        fill(p, 0, Int(ld8(p - 16)))
        return p
    }

    private func isFreeBlock(_ q: Int64, _ bsize: Int64) -> Swift.Bool {
        q >= Int64(Arena.GUARD + Arena.HDR) && q < Int64(top) && (q & 7) == 0 && q + bsize <= Int64(top) &&
            ld8(Int(q) - 16) == bsize && ld8(Int(q) - 8) >> 32 == Arena.FREE_TAG
    }

    /** Size from a used block's header, which the program could have overwritten. */
    private func blockSize(_ p: Int) throws -> Int64 {
        let bsize = ld8(p - 16)
        if bsize < 8 || bsize > Int64(maxBytes) || (bsize & 7) != 0 || Int64(p) + bsize > Int64(top) || (ld8(p - 8) & 0xFFFFFFFF) != bsize >> 3 {
            throw VmFault(Arena.BAD_FREE, "corrupted heap block at 0x\(hex(Int64(p)))")
        }
        return bsize
    }

    private func validBlock(_ a: Int64) throws -> Int {
        if a < Int64(Arena.GUARD + Arena.HDR) || a >= Int64(top) || (a & 7) != 0 { throw VmFault(Arena.BAD_FREE, "Free of invalid pointer 0x\(hex(a))") }
        let p = Int(a)
        let tag = ld8(p - 8) >> 32
        if tag == Arena.FREE_TAG { throw VmFault(Arena.BAD_FREE, "double Free of 0x\(hex(a))") }
        if tag != Arena.USED_TAG { throw VmFault(Arena.BAD_FREE, "Free of invalid pointer 0x\(hex(a))") }
        return p
    }

    public func free(_ a: Int64) throws {
        if a == 0 { return }
        let p = try validBlock(a)
        let bsize = try blockSize(p)
        st8(p - 8, Arena.freeWord(freeHead(bsize)))
        setFreeHead(bsize, p)
        allocated -= bsize
    }

    public func msize(_ a: Int64) throws -> Int64 {
        if a == 0 { return 0 }
        return try blockSize(try validBlock(a))
    }

    /**
     * A task stack: a heap block whose header is marked so that Free()/MSize() of a
     * local's address are rejected (BadFree) instead of freeing a live stack.
     */
    public func allocStack(_ n: Int64) throws -> Int { let p = try malloc(n); st8(p - 8, Arena.headerWord(Arena.STACK_TAG, ld8(p - 16) >> 3)); return p }

    /** Returns a dead task's stack to the heap (skipped if the program corrupted its header). */
    public func freeStack(_ p: Int) {
        if ld8(p - 8) >> 32 != Arena.STACK_TAG { return }
        st8(p - 8, Arena.headerWord(Arena.USED_TAG, ld8(p - 16) >> 3))
        try? free(Int64(p))
    }

    public var heapTop: Int { top }
}
