package io.github.templeosmobile.core.holyc

/** A HolyC exception raised by the runtime (catchable by try/catch). */
class VmFault(val ch: Long, message: String) : RuntimeException(message, null, false, false) {
    /** Where it happened, "Function (file:line)", when the thrower knows it (natively translated code). */
    @JvmField var where: String? = null
}

/** Uncatchable termination (stop request, resource limit). */
class VmKill(message: String) : RuntimeException(message, null, false, false)

fun chCode(s: String): Long {
    var v = 0L
    for (i in s.indices.reversed()) v = (v shl 8) or (s[i].code.toLong() and 0xFF)
    return v
}

/**
 * The program's isolated memory: a little-endian byte address space backed by a
 * LongArray (fast aligned 64-bit access). The heap starts at [GUARD]; the low 64 KiB
 * below it are ordinary zero-filled memory, because TempleOS identity-maps low memory
 * (Doc/MemOverview.DD) and a NULL+offset access reads or writes it without a fault
 * (VM-verified: *NULL reads the BIOS interrupt vectors there). Outside the arena faults.
 */
class Arena(initialBytes: Int, val maxBytes: Int) {
    var words = LongArray(initialBytes ushr 3)
        private set
    var size = initialBytes
        private set

    companion object {
        const val GUARD = 0x10000
        const val HDR = 16
        /**
         * Block header: [p-16] the block size, [p-8] a tag in the high half and, in the low half, the
         * size/8 for a used block (a forged size is caught) or the next free block of the same size.
         * The link lives in the header, not in the block, because TempleOS's Free leaves a freed block's
         * bytes as they were (Kernel/Mem/MAllocFree.HC links CMemUnused.next through the header), and
         * programs rely on that: Talons' AnimateTask walks panels the restart has just freed.
         */
        const val USED_TAG = 0x55534544L  // "DESU"
        const val FREE_TAG = 0x45455246L  // "FREE"
        const val STACK_TAG = 0x4B415453L // "STAK"
        fun headerWord(tag: Long, low: Long): Long = (tag shl 32) or (low and 0xFFFFFFFFL)
        fun freeWord(next: Int): Long = headerWord(FREE_TAG, next.toLong())
        /**
         * Sizes as TempleOS rounds them (Kernel/Mem/MAllocFree.HC _MALLOC): requests are rounded up to
         * 8 bytes and, below MEM_HEAP_HASH_SIZE (1024), reused by exact size (heap_hash); bigger ones
         * take MEM_PAG_SIZE (512-byte) pages, and a free one up to twice the size is reused here.
         */
        const val SMALL_MAX = 1024
        const val PAGE = 512
        val BAD_MEM = chCode("BadMem")
        val BAD_FREE = chCode("BadFree")
        val OUT_MEM = chCode("OutMem")
    }

    // ---------------------------------------------------------------- checks

    fun check(a: Long, n: Int): Int {
        if (n < 0 || a < 0 || a > (size - n).toLong()) fault(a)
        return a.toInt()
    }

    /**
     * Checks a [rows] x [n] byte rectangle whose rows are [stride] bytes apart
     * (a device context's program-writable width_internal): the whole span
     * a .. a+(rows-1)*stride+n must be inside the arena. Returns a.
     */
    fun checkRows(a: Long, stride: Long, rows: Long, n: Long): Int {
        if (rows <= 0 || n <= 0) return check(a, 0)
        if (stride < 0 || stride > Int.MAX_VALUE || rows > Int.MAX_VALUE || n > Int.MAX_VALUE) fault(a)
        val len = (rows - 1) * stride + n
        if (len > Int.MAX_VALUE) fault(a)
        return check(a, len.toInt())
    }

    fun fault(a: Long): Nothing = throw VmFault(BAD_MEM, "invalid memory access at 0x${java.lang.Long.toHexString(a)}")

    /**
     * Checked 8-byte load and store in one call (= ld8(check(a, 8)) / st8(check(a, 8), v), with the same
     * faults): an aligned in-bounds access touches [words] directly. The interpreter's hot opcodes use these
     * because HotSpot and ART do not inline the two separate calls into the very large Vm.exec.
     */
    fun ld8c(a: Long): Long = if ((a and 7L) == 0L && a >= 0L && a <= size - 8L) words[(a ushr 3).toInt()] else ld8(check(a, 8))
    fun st8c(a: Long, v: Long) { if ((a and 7L) == 0L && a >= 0L && a <= size - 8L) words[(a ushr 3).toInt()] = v else st8(check(a, 8), v) }

    // ---------------------------------------------------------------- raw access (address already checked)

    fun ld8(a: Int): Long {
        val s = a and 7
        val w = a ushr 3
        if (s == 0) return words[w]
        val sh = s shl 3
        return (words[w] ushr sh) or (words[w + 1] shl (64 - sh))
    }

    fun ld1(a: Int): Long = (words[a ushr 3] ushr ((a and 7) shl 3)) and 0xFF

    fun ld2(a: Int): Long {
        val s = a and 7
        if (s <= 6) return (words[a ushr 3] ushr (s shl 3)) and 0xFFFF
        return ld1(a) or (ld1(a + 1) shl 8)
    }

    fun ld4(a: Int): Long {
        val s = a and 7
        if (s <= 4) return (words[a ushr 3] ushr (s shl 3)) and 0xFFFFFFFFL
        return ld8(a) and 0xFFFFFFFFL
    }

    fun st8(a: Int, v: Long) {
        val s = a and 7
        val w = a ushr 3
        if (s == 0) { words[w] = v; return }
        val sh = s shl 3
        val lowMask = (1L shl sh) - 1
        words[w] = (words[w] and lowMask) or (v shl sh)
        words[w + 1] = (words[w + 1] and lowMask.inv()) or (v ushr (64 - sh))
    }

    fun st1(a: Int, v: Long) {
        val w = a ushr 3
        val sh = (a and 7) shl 3
        words[w] = (words[w] and (0xFFL shl sh).inv()) or ((v and 0xFF) shl sh)
    }

    fun st2(a: Int, v: Long) {
        val s = a and 7
        if (s <= 6) {
            val w = a ushr 3; val sh = s shl 3
            words[w] = (words[w] and (0xFFFFL shl sh).inv()) or ((v and 0xFFFF) shl sh)
        } else { st1(a, v); st1(a + 1, v ushr 8) }
    }

    fun st4(a: Int, v: Long) {
        val s = a and 7
        if (s <= 4) {
            val w = a ushr 3; val sh = s shl 3
            words[w] = (words[w] and (0xFFFFFFFFL shl sh).inv()) or ((v and 0xFFFFFFFFL) shl sh)
        } else { st2(a, v); st2(a + 2, v ushr 16) }
    }

    fun getByte(a: Int): Int = ld1(a).toInt()

    // ---------------------------------------------------------------- bulk

    fun copy(dst: Int, src: Int, n: Int) {
        if (n <= 0) return
        if ((dst and 7) == 0 && (src and 7) == 0 && (n and 7) == 0) {
            System.arraycopy(words, src ushr 3, words, dst ushr 3, n ushr 3)
            return
        }
        if (dst > src && dst < src + n) {
            for (i in n - 1 downTo 0) st1(dst + i, ld1(src + i))
        } else {
            var i = 0
            while (i + 8 <= n) { st8(dst + i, ld8(src + i)); i += 8 }
            while (i < n) { st1(dst + i, ld1(src + i)); i++ }
        }
    }

    fun fill(dst: Int, b: Int, n: Int) {
        if (n <= 0) return
        val v8 = (b.toLong() and 0xFF) * 0x0101010101010101L
        var i = 0
        while (i < n && ((dst + i) and 7) != 0) { st1(dst + i, b.toLong()); i++ }
        if (n - i >= 8) {
            val w0 = (dst + i) ushr 3
            val cnt = (n - i) ushr 3
            java.util.Arrays.fill(words, w0, w0 + cnt, v8)
            i += cnt shl 3
        }
        while (i < n) { st1(dst + i, b.toLong()); i++ }
    }

    fun readBytes(a: Int, n: Int): ByteArray = ByteArray(n) { ld1(a + it).toByte() }

    fun writeBytes(a: Int, b: ByteArray, off: Int = 0, len: Int = b.size) {
        for (i in 0 until len) st1(a + i, b[off + i].toLong())
    }

    /** Length of the NUL-terminated string at a (bounded by the arena). */
    fun strLen(a: Int): Int {
        var i = a
        val lim = size
        while (i < lim) {
            if (ld1(i) == 0L) return i - a
            i++
        }
        fault(lim.toLong())
    }

    fun readStr(a: Long): String {
        if (a == 0L) return ""
        val p = check(a, 1)
        val n = strLen(p)
        val ch = CharArray(n) { ld1(p + it).toInt().toChar() }
        return String(ch)
    }

    fun readStrBytes(a: Long): ByteArray {
        if (a == 0L) return ByteArray(0)
        val p = check(a, 1)
        return readBytes(p, strLen(p))
    }

    // ---------------------------------------------------------------- heap

    private var top = GUARD
    /** Free small blocks by size/8, linked through their headers. */
    private val smallFree = IntArray(SMALL_MAX / 8 + 1)
    /** Free large blocks: size -> first block of that size. */
    private val largeFree = java.util.TreeMap<Long, Int>()
    var allocated = 0L
        private set
    /** Most bytes ever allocated at once, and the bump pointer's high-water mark (memory reports). */
    var peakAllocated = 0L
        private set
    val highWater: Int get() = top

    private fun ensure(bytes: Long) {
        if (bytes <= size) return
        if (bytes > maxBytes) throw VmFault(OUT_MEM, "out of memory: program limit is ${maxBytes / (1024 * 1024)} MiB")
        var ns = size.toLong()
        while (ns < bytes) ns *= 2
        ns = minOf(ns, maxBytes.toLong())
        words = words.copyOf((ns ushr 3).toInt())
        size = ns.toInt()
    }

    private fun blockSizeFor(n: Long): Long = if (n <= SMALL_MAX) (maxOf(n, 8) + 7) and -8L else (n + PAGE - 1) and -PAGE.toLong()

    private fun freeHead(bsize: Long): Int = if (bsize <= SMALL_MAX) smallFree[(bsize ushr 3).toInt()] else largeFree[bsize] ?: 0

    private fun setFreeHead(bsize: Long, p: Int) {
        if (bsize <= SMALL_MAX) smallFree[(bsize ushr 3).toInt()] = p
        else if (p == 0) largeFree.remove(bsize) else largeFree[bsize] = p
    }

    fun malloc(n0: Long): Int {
        if (n0 < 0 || n0 > maxBytes) throw VmFault(OUT_MEM, "out of memory: MAlloc($n0)")
        var bsize = blockSizeFor(n0)
        var p = freeHead(bsize)
        if (p == 0 && bsize > SMALL_MAX) {
            // best fit among free large blocks, wasting at most as much as the request
            val e = largeFree.ceilingEntry(bsize)
            if (e != null && e.key <= 2 * bsize) { bsize = e.key; p = e.value }
        }
        if (p != 0) {
            // Headers and links live in program-writable memory: verify before trusting them.
            val next = ld8(p - 8) and 0xFFFFFFFFL
            if (!isFreeBlock(p.toLong(), bsize) || (next != 0L && !isFreeBlock(next, bsize)))
                throw VmFault(BAD_MEM, "heap corruption detected in MAlloc (block 0x${java.lang.Integer.toHexString(p)})")
            setFreeHead(bsize, next.toInt())
        } else {
            val need = top.toLong() + HDR + bsize
            ensure(need)
            p = top + HDR
            top = need.toInt()
            st8(p - 16, bsize)
        }
        st8(p - 8, headerWord(USED_TAG, bsize ushr 3))
        allocated += bsize
        if (allocated > peakAllocated) peakAllocated = allocated
        return p
    }

    fun calloc(n: Long): Int {
        val p = malloc(n)
        fill(p, 0, ld8(p - 16).toInt())
        return p
    }

    private fun isFreeBlock(q: Long, bsize: Long): Boolean =
        q >= GUARD + HDR && q < top && (q and 7) == 0L && q + bsize <= top &&
            ld8(q.toInt() - 16) == bsize && ld8(q.toInt() - 8) ushr 32 == FREE_TAG

    /** Size from a used block's header, which the program could have overwritten. */
    private fun blockSize(p: Int): Long {
        val bsize = ld8(p - 16)
        if (bsize < 8 || bsize > maxBytes || (bsize and 7) != 0L || p + bsize > top || (ld8(p - 8) and 0xFFFFFFFFL) != bsize ushr 3)
            throw VmFault(BAD_FREE, "corrupted heap block at 0x${java.lang.Integer.toHexString(p)}")
        return bsize
    }

    private fun validBlock(a: Long): Int {
        if (a < GUARD + HDR || a >= top || (a and 7) != 0L) throw VmFault(BAD_FREE, "Free of invalid pointer 0x${java.lang.Long.toHexString(a)}")
        val p = a.toInt()
        val tag = ld8(p - 8) ushr 32
        if (tag == FREE_TAG) throw VmFault(BAD_FREE, "double Free of 0x${java.lang.Long.toHexString(a)}")
        if (tag != USED_TAG) throw VmFault(BAD_FREE, "Free of invalid pointer 0x${java.lang.Long.toHexString(a)}")
        return p
    }

    fun free(a: Long) {
        if (a == 0L) return
        val p = validBlock(a)
        val bsize = blockSize(p)
        st8(p - 8, freeWord(freeHead(bsize)))
        setFreeHead(bsize, p)
        allocated -= bsize
    }

    fun msize(a: Long): Long {
        if (a == 0L) return 0
        return blockSize(validBlock(a))
    }

    /**
     * A task stack: a heap block whose header is marked so that Free()/MSize() of a
     * local's address are rejected (BadFree) instead of freeing a live stack.
     */
    fun allocStack(n: Long): Int { val p = malloc(n); st8(p - 8, headerWord(STACK_TAG, ld8(p - 16) ushr 3)); return p }

    /** Returns a dead task's stack to the heap (skipped if the program corrupted its header). */
    fun freeStack(p: Int) {
        if (ld8(p - 8) ushr 32 != STACK_TAG) return
        st8(p - 8, headerWord(USED_TAG, ld8(p - 16) ushr 3))
        try { free(p.toLong()) } catch (_: VmFault) {}
    }

    val heapTop get() = top
}
