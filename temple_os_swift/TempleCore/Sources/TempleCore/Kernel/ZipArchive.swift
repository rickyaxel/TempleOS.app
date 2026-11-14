import Compression
import Foundation

// Port of kernel/ZipArchive.kt.

/**
 * The container of a ZIP archive the user imports (ui/FileImport), read as untrusted input. The end record and
 * the whole central directory are parsed, and every entry's local header is checked (signature, the same name,
 * data inside the file and before the central directory, no overlap with the previous entry) before anything
 * is extracted. Every offset and length is checked against the file before it is read. An entry inflates into
 * a buffer of exactly its declared size and must match its CRC-32. Policy (names, encryption, methods, sizes,
 * links) is FileImport's; nothing here creates files.
 *
 * Single-disk archives only: ZIP64 and split archives are [ZipError.unsupported]. Deflate is the platform's
 * (Compression's COMPRESSION_ZLIB is raw RFC 1951 Deflate; Kotlin: java.util.zip.Inflater), CRC-32 is [Crc32].
 * Apple platforms have no public API that reads ZIP archives, so the container format (a few records with
 * fixed fields) is parsed here, the same way on both platforms.
 */
public final class ZipArchive {
    public struct Entry {
        /** The stored name bytes (UTF-8 when [utf8], else usually CP437). */
        public let rawName: [UInt8]
        /** General purpose flag bit 11: the name is UTF-8. */
        public let utf8: Bool
        public let flags: Int
        public let method: Int
        /** A folder: the name ends with "/" (or "\"), or the attributes say so. */
        public let isDir: Bool
        /** A symbolic link, device, FIFO or socket (the Unix file type in the external attributes). */
        public let isSpecial: Bool
        public let crc: UInt32
        public let compressedSize: Int
        public let size: Int
        let localOffset: Int
        /** Where the data starts (after the local header); set when the local header was checked. */
        var dataStart = 0
    }

    public private(set) var entries: [Entry] = []
    private var fd: Int32
    private let fileSize: Int

    /** Opens [path] and checks its structure; more than [maxEntries] entries is [ZipError.tooManyEntries]. */
    public init(_ path: String, maxEntries: Int) throws {
        fd = Foundation.open(path, O_RDONLY)
        var st = stat()
        fileSize = fd >= 0 && fstat(fd, &st) == 0 ? Int(st.st_size) : -1
        if fd < 0 || fileSize < 0 { close(); throw ZipError.read }
        do { try parse(maxEntries) } catch { close(); throw error }
    }

    deinit { close() }

    public func close() { if fd >= 0 { _ = Foundation.close(fd); fd = -1 } }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }

    /** [n] bytes at [off], which must lie inside the file. */
    private func read(_ off: Int, _ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        if n > 0 { try buf.withUnsafeMutableBytes { try readInto($0.baseAddress!, off, n) } }
        else if off < 0 || off > fileSize { throw ZipError.invalid }
        return buf
    }

    private func readInto(_ p: UnsafeMutableRawPointer, _ off: Int, _ n: Int) throws {
        guard off >= 0, n >= 0, off <= fileSize, n <= fileSize - off else { throw ZipError.invalid }
        var got = 0
        while got < n {
            let r = pread(fd, p + got, n - got, off_t(off + got))
            if r <= 0 { throw ZipError.read }
            got += r
        }
    }

    private func parse(_ maxEntries: Int) throws {
        guard fileSize >= 22 else { throw ZipError.invalid }
        // the end record: the last signature whose comment ends exactly at the end of the file
        let tailLen = min(fileSize, 22 + 0xFFFF)
        let tail = try read(fileSize - tailLen, tailLen)
        var at = tailLen - 22, eocd = -1
        while at >= 0 {
            if tail[at] == 0x50 && tail[at + 1] == 0x4B && tail[at + 2] == 5 && tail[at + 3] == 6 && at + 22 + ZipArchive.u16(tail, at + 20) == tailLen { eocd = at; break }
            at -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid }
        let eocdPos = fileSize - tailLen + eocd
        let disk = ZipArchive.u16(tail, eocd + 4), cdDisk = ZipArchive.u16(tail, eocd + 6)
        let onDisk = ZipArchive.u16(tail, eocd + 8), total = ZipArchive.u16(tail, eocd + 10)
        let cdSize = ZipArchive.u32(tail, eocd + 12), cdOffset = ZipArchive.u32(tail, eocd + 16)
        // ZIP64: values that do not fit, or its locator right before the end record; split: more than one disk
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported }
        if eocdPos >= 20, try read(eocdPos - 20, 4) == [0x50, 0x4B, 6, 7] { throw ZipError.unsupported }
        if disk != 0 || cdDisk != 0 || onDisk != total { throw ZipError.unsupported }
        if total > maxEntries { throw ZipError.tooManyEntries }
        guard cdOffset + cdSize <= eocdPos else { throw ZipError.invalid }
        let cd = try read(cdOffset, cdSize)
        var p = 0
        var list: [Entry] = []
        for _ in 0..<total {
            guard p + 46 <= cd.count, ZipArchive.u32(cd, p) == 0x0201_4B50 else { throw ZipError.invalid }
            let madeBy = ZipArchive.u16(cd, p + 4), flags = ZipArchive.u16(cd, p + 8), method = ZipArchive.u16(cd, p + 10)
            let crc = UInt32(ZipArchive.u32(cd, p + 16)), csize = ZipArchive.u32(cd, p + 20), usize = ZipArchive.u32(cd, p + 24)
            let nameLen = ZipArchive.u16(cd, p + 28), extraLen = ZipArchive.u16(cd, p + 30), commentLen = ZipArchive.u16(cd, p + 32)
            let external = ZipArchive.u32(cd, p + 38), local = ZipArchive.u32(cd, p + 42)
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw ZipError.invalid }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || local == 0xFFFF_FFFF { throw ZipError.unsupported }
            let raw = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            p += 46 + nameLen + extraLen + commentLen
            // Unix (3) and OS X (19) keep the file type in the high half of the external attributes; DOS has a folder bit
            let host = madeBy >> 8, type = (external >> 16) & 0xF000
            let unix = host == 3 || host == 19
            let isDir = raw.last == 0x2F || raw.last == 0x5C || (unix && type == 0x4000) || (!unix && external & 0x10 != 0)
            list.append(Entry(rawName: raw, utf8: flags & 0x800 != 0, flags: flags, method: method, isDir: isDir,
                              isSpecial: unix && type != 0 && type != 0x8000 && type != 0x4000,
                              crc: crc, compressedSize: csize, size: usize, localOffset: local))
        }
        // local headers in file order: the same name, data inside the file before the central directory, no overlap
        var end = 0
        for i in list.indices.sorted(by: { list[$0].localOffset < list[$1].localOffset }) {
            var e = list[i]
            guard e.localOffset >= end else { throw ZipError.invalid }
            let h = try read(e.localOffset, 30)
            guard ZipArchive.u32(h, 0) == 0x0403_4B50 else { throw ZipError.invalid }
            let n = ZipArchive.u16(h, 26), x = ZipArchive.u16(h, 28)
            guard n == e.rawName.count, try read(e.localOffset + 30, n) == e.rawName else { throw ZipError.invalid }
            e.dataStart = e.localOffset + 30 + n + x
            guard e.dataStart <= cdOffset, e.compressedSize <= cdOffset - e.dataStart else { throw ZipError.invalid }
            end = e.dataStart + e.compressedSize
            list[i] = e
        }
        entries = list
    }

    /**
     * The entry's bytes: exactly [Entry.size] of them, checked against its CRC-32. The data is read in 64 KiB
     * chunks; Deflate output beyond the declared size, a stream that ends early or never ends, and a CRC
     * mismatch are all [ZipError.damaged]. The caller has limited [Entry.size].
     */
    public func data(_ e: Entry) throws -> [UInt8] {
        if e.isDir { return [] }
        var out: [UInt8]
        switch e.method {
        case 0:
            guard e.compressedSize == e.size else { throw ZipError.damaged }
            out = try read(e.dataStart, e.size)
        case 8:
            out = try inflate(e)
        default:
            throw ZipError.damaged
        }
        guard Crc32.of(out) == e.crc else { throw ZipError.damaged }
        return out
    }

    private func inflate(_ e: Entry) throws -> [UInt8] {
        // one spare byte: a stream that fills it is longer than declared
        var out = [UInt8](repeating: 0, count: e.size + 1)
        let chunk = 1 << 16
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { input.deallocate(); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.damaged }
        defer { compression_stream_destroy(stream) }
        var pos = e.dataStart, left = e.compressedSize
        let produced: Int = try out.withUnsafeMutableBufferPointer { dst in
            stream.pointee.dst_ptr = dst.baseAddress!
            stream.pointee.dst_size = dst.count
            stream.pointee.src_ptr = UnsafePointer(input)
            stream.pointee.src_size = 0
            var stalls = 0
            while true {
                if stream.pointee.src_size == 0 && left > 0 {
                    let n = min(left, chunk)
                    try readInto(input, pos, n)
                    pos += n; left -= n
                    stream.pointee.src_ptr = UnsafePointer(input)
                    stream.pointee.src_size = n
                }
                let before = (stream.pointee.src_size, stream.pointee.dst_size)
                let status = compression_stream_process(stream, left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                if status == COMPRESSION_STATUS_END { break }
                // an error, or output beyond the spare byte
                guard status == COMPRESSION_STATUS_OK, stream.pointee.dst_size > 0 else { throw ZipError.damaged }
                // all input given and the stream neither moves nor ends: truncated
                if before == (stream.pointee.src_size, stream.pointee.dst_size) { stalls += 1; if stalls > 1 { throw ZipError.damaged } } else { stalls = 0 }
            }
            return dst.count - stream.pointee.dst_size
        }
        guard produced == e.size else { throw ZipError.damaged }
        out.removeLast()
        return out
    }
}

/** Why an archive could not be read; ui/FileImport turns these into messages. */
public enum ZipError: Error {
    /** Not a ZIP archive, or its structure is inconsistent (truncated, overlapping, offsets outside the file). */
    case invalid
    /** ZIP64 or a split archive. */
    case unsupported
    case tooManyEntries
    /** An entry's data does not inflate to its declared size or does not match its CRC-32. */
    case damaged
    /** The file could not be read. */
    case read
}

/** CRC-32 (ISO-HDLC, the ZIP and PNG checksum); Kotlin uses java.util.zip.CRC32. */
public enum Crc32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func of(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
