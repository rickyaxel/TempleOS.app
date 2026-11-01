import Foundation

/// TempleOS V5.03 Adam/Gr/GrDC.HC DCSave/DCLoad layout. No color conversion occurs here.
/// The limits are mobile allocation guards, separate from the historical file format.
public struct GRImage {
    public static let maxBody = 16 * 1024 * 1024
    public let width: Int, height: Int, stride: Int
    public var header: [UInt8]
    public var palette: [UInt8]?
    public var body: [UInt8]

    public init(width: Int = 320, height: Int = 240) {
        precondition(width > 0 && height > 0 && width <= 16384 && height <= 16384)
        self.width = width; self.height = height; stride = (width + 7) & ~7
        precondition(stride * height <= Self.maxBody)
        header = [UInt8](repeating: 0, count: 32); palette = nil
        body = [UInt8](repeating: UInt8(Palette.WHITE), count: stride * height)
    }

    public static func decode(_ bytes: [UInt8]) throws -> GRImage {
        guard bytes.count >= 32 else { throw FsError("Truncated GR header") }
        func word(_ o: Int) -> Int {
            Int(Int32(bitPattern: UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 |
                UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24))
        }
        let w = word(16), s = word(20), h = word(24), flags = word(28)
        guard w > 0, h > 0, w <= 16384, h <= 16384, s >= w,
              s <= maxBody / h, s & 7 == 0, flags & ~7 == 0 else { throw FsError("Invalid GR geometry or flags") }
        let off = 32 + (flags & 2 != 0 ? 128 : 0), size = s * h
        guard bytes.count >= off else { throw FsError("Truncated GR palette") }
        let body: [UInt8]
        if flags & 1 != 0 {
            body = try TempleArc.expand(Array(bytes[off...]), expected: size)
        } else {
            guard size <= bytes.count - off else { throw FsError("Truncated GR body") }
            body = Array(bytes[off..<(off + size)])
        }
        // Preserve nonstandard but valid strides, padding, origin, date, palette and transparency.
        return GRImage(width: w, height: h, stride: s, header: Array(bytes[..<32]),
                         palette: flags & 2 != 0 ? Array(bytes[32..<off]) : nil, body: body)
    }

    public static func decodeFile(_ bytes: [UInt8], outerArchive: Bool) throws -> GRImage {
        guard outerArchive else { return try decode(bytes) }
        // Earlier mobile saves wrote raw GR even with a .Z suffix. Accept only a fully
        // validated GR image as that legacy representation; otherwise require a valid archive.
        if let raw = try? decode(bytes) { return raw }
        return try decode(TempleArc.expand(bytes))
    }

    private init(width: Int, height: Int, stride: Int, header: [UInt8], palette: [UInt8]?, body: [UInt8]) {
        self.width = width; self.height = height; self.stride = stride
        self.header = header; self.palette = palette; self.body = body
    }

    public var pixels: [UInt8] {
        get { (0..<height).flatMap { Array(body[($0 * stride)..<($0 * stride + width)]) } }
        set {
            precondition(newValue.count == width * height)
            for y in 0..<height { body.replaceSubrange((y * stride)..<(y * stride + width), with: newValue[(y * width)..<((y + 1) * width)]) }
        }
    }

    /// Uncompressed DCSave encoding. Compression is optional in the original GR format.
    public func encode() -> [UInt8] {
        var out = header
        func put(_ o: Int, _ n: Int) { for i in 0..<4 { out[o+i] = UInt8(truncatingIfNeeded: n >> (8*i)) } }
        put(16, width); put(20, stride); put(24, height)
        put(28, palette == nil ? 0 : 2) // DCSave clears runtime optimization flags.
        if let palette = palette { out += palette }
        return out + body
    }
}

/// Bounded port of Kernel/Compress.HC ArcEntryGet/ArcExpandBuf (7/8-bit TempleOS LZW).
/// Invalid references, cycles and truncated streams fail before any image is replaced.
public enum TempleArc {
    public static func store(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 17)
        for i in 0..<8 {
            out[i] = UInt8(truncatingIfNeeded: (bytes.count + 17) >> (8*i))
            out[8+i] = UInt8(truncatingIfNeeded: bytes.count >> (8*i))
        }
        out[16] = 1 // CT_NONE (Kernel/Compress.HC CompressBuf)
        return out + bytes
    }
    public static func expand(_ src: [UInt8], expected: Int? = nil) throws -> [UInt8] {
        func bad() -> FsError { FsError("Invalid TempleOS compressed data") }
        guard src.count >= 17 else { throw bad() }
        func size(_ o: Int) throws -> Int {
            var n: UInt64 = 0
            for i in 0..<8 { n |= UInt64(src[o+i]) << (8*i) }
            guard n <= UInt64(Int.max) else { throw bad() }; return Int(n)
        }
        let compressed = try size(0), expanded = try size(8), type = Int(src[16])
        let maxExpanded = expected == nil ? GRImage.maxBody + 160 : GRImage.maxBody
        guard compressed >= 17, compressed <= src.count, expanded <= maxExpanded,
              expected == nil || expected == expanded else { throw bad() }
        if type == 1 {
            guard expanded <= compressed - 17 else { throw bad() }
            return Array(src[17..<(17 + expanded)])
        }
        guard type == 2 || type == 3 else { throw bad() }
        if expanded == 0 { return [] }
        let minimum = 1 << (type == 2 ? 7 : 8)
        var next = [Int](repeating: -1, count: 4096), base = [Int](repeating: 0, count: 4096)
        var char = [UInt8](repeating: 0, count: 4096), hash = [Int](repeating: -1, count: 4096)
        var valid = [Bool](repeating: false, count: 4096)
        var free = minimum, bits = type == 2 ? 8 : 9, limit = 1 << bits
        var current = -1, pending = -1, bit = 17 * 8
        func entry() throws {
            current = pending
            if bits < 12 {
                pending = free; free += 1
                if free == limit { bits += 1; limit = 1 << bits }
            } else {
                var tries = 0
                repeat {
                    free += 1; if free == limit { free = minimum }; tries += 1
                    if tries > 4096 { throw bad() }
                } while hash[free] != -1
                pending = free
                let head = base[free]
                if hash[head] == free { hash[head] = next[free] }
                else {
                    var p = hash[head], steps = 0
                    while p != -1 && next[p] != free {
                        p = next[p]; steps += 1; if steps > 4096 { throw bad() }
                    }
                    if p != -1 { next[p] = next[free] }
                }
                valid[free] = false
            }
        }
        func read() throws -> Int {
            guard bit + bits <= compressed * 8 else { throw bad() }
            var code = 0
            for i in 0..<bits { code |= (Int(src[(bit+i)/8]) >> ((bit+i)&7) & 1) << i }
            bit += bits; return code
        }
        try entry()
        var last = try read()
        guard last < minimum else { throw bad() }
        var out = [UInt8](); out.reserveCapacity(expanded); out.append(UInt8(last))
        var lastChar = UInt8(last)
        try entry()
        while out.count < expanded {
            let code = try read()
            var cursor = code, stack = [UInt8]()
            if code == current { stack.append(lastChar); cursor = last }
            var hops = 0
            while cursor >= minimum {
                guard cursor < 4096, valid[cursor], hops < 4096 else { throw bad() }
                stack.append(char[cursor]); cursor = base[cursor]; hops += 1
            }
            lastChar = UInt8(cursor); stack.append(lastChar)
            guard current >= minimum, last < 4096, stack.count <= expanded - out.count else { throw bad() }
            base[current] = last; char[current] = lastChar; next[current] = hash[last]
            hash[last] = current; valid[current] = true
            try entry()
            out.append(contentsOf: stack.reversed()); last = code
        }
        return out
    }
}
