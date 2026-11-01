import Foundation

/**
 * A program window's text document (the TempleOS "put_doc"). Output bytes are
 * interpreted for control characters and DolDoc inline commands ($FG,n$, color
 * names, $BG$, $CL$, $IV$, $UL$, $BK$, links...). Lines are stored unwrapped as
 * cells: bits 0-7 char, 8-11 fg, 12-15 bg, plus ATTRF_* flags (TempleOS layout).
 * Cells are Kotlin Ints: Swift `Int` holding the sign-extended 32-bit value.
 *
 * Thread-safe: written by the kernel thread, read by the UI thread
 * (Kotlin @Synchronized methods lock an NSRecursiveLock).
 * Port of kernel/Console.kt.
 */
public final class Console {
    public static let ATTRF_BLINK = 0x10000000
    public static let ATTRF_INVERT = 0x20000000
    public static let MAX_COLS = 1024
    public static let ATTRF_UNDERLINE = Int(Int32.min) // 0x80000000.toInt()
    public static let DFT_FG = 1   // BLUE
    public static let DFT_BG = 15  // WHITE
    public static let COLOR_NAMES: [String: Int] = [
        "BLACK": 0, "BLUE": 1, "GREEN": 2, "CYAN": 3, "RED": 4, "PURPLE": 5,
        "BROWN": 6, "LTGRAY": 7, "DKGRAY": 8, "LTBLUE": 9, "LTGREEN": 10,
        "LTCYAN": 11, "LTRED": 12, "LTPURPLE": 13, "YELLOW": 14, "WHITE": 15,
    ]
    /** Iteration order of the Kotlin `mapOf` (Swift dictionaries are unordered). */
    public static let COLOR_NAME_ORDER: [String] = [
        "BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
        "DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE",
    ]

    public final class Line {
        public var cells = [Int](repeating: 0, count: 16)
        public var len = 0
        public var cellAttrBlank = (Console.DFT_BG << 4) | Console.DFT_FG
        /**
         * Color attribute the rest of the line takes at its newline (-1: none). TempleOS's DolDoc fills
         * the rest of the row with the current colors at every newline (Adam/DolDoc/DocRecalc.HC:724
         * TextLenAttr), so a $BG$ color reaches the window edge (ZoneOut's sky, CastleFrankenstein).
         */
        public var fill = -1
        public init() {}
        public func put(_ col: Int, _ cell: Int) {
            if col >= cells.count {
                let n = max(col + 1, cells.count * 2)
                cells.append(contentsOf: [Int](repeating: 0, count: n - cells.count))
            }
            while len < col { cells[len] = 32 | (cellAttrBlank << 8); len += 1 }
            cells[col] = cell
            if col >= len { len = col + 1 }
        }
        public func copy() -> Line {
            let l = Line()
            let n = max(len, 1)
            if n <= cells.count { l.cells = Array(cells[0..<n]) }
            else { l.cells = cells + [Int](repeating: 0, count: n - cells.count) }
            l.len = len
            l.fill = fill
            return l
        }
    }

    private let maxLines: Int
    private let lock = NSRecursiveLock()
    private var lines: [Line] = [Line()]
    private struct DocSprite {
        let id: Int
        var pixels: [UInt8], width: Int, height: Int, x: Int, y: Int
        let col: Int
        var row: Int
        let format:String
    }
    private var sprites: [DocSprite] = []
    private var nextSpriteId = 0
    public func hasSprite(_ id:Int)->Bool {lock.lock();defer {lock.unlock()};return sprites.contains {$0.id==id}}
    public func writeKeepingSprites(_ bytes:[UInt8]) {
        lock.lock();defer {lock.unlock()};let saved=sprites;write(bytes);sprites=saved
    }
    public func resizeSprite(_ id:Int,_ side:Int) throws {
        lock.lock();defer {lock.unlock()};guard let i=sprites.firstIndex(where:{$0.id==id}) else {return}
        guard side>0,side<=1024,sprites.reduce(0,{$0+$1.pixels.count})-sprites[i].pixels.count+side*side<=4*1024*1024 else {throw VmKill("document sprite size")}
        sprites[i].width=side;sprites[i].height=side;sprites[i].x = -side/2;sprites[i].y = -side/2
        sprites[i].pixels=[UInt8](repeating:255,count:side*side)
    }
    public func updateSprite(_ id:Int,_ fill:(UnsafeMutableBufferPointer<UInt8>)->Void) {
        lock.lock();defer {lock.unlock()};guard let i=sprites.firstIndex(where:{$0.id==id}) else {return}
        sprites[i].pixels.withUnsafeMutableBufferPointer {fill($0)};version+=1
    }
    public func cursorCell() -> (Int,Int) {lock.lock();defer {lock.unlock()};return (row,col)}
    public func updateField(_ atRow:Int,_ atCol:Int,_ bytes:[UInt8],_ color:Int) {
        lock.lock();defer {lock.unlock()}
        guard lines.indices.contains(atRow), atCol >= 0, atCol < Console.MAX_COLS else {return}
        for i in 0..<min(bytes.count,Console.MAX_COLS-atCol) {lines[atRow].put(atCol+i,Int(bytes[i]) | (((bg << 4) | color) << 8))}
        version += 1
    }
    private var firstVisualRow = 0
    @discardableResult public func insertSprite(_ pixels: [UInt8], _ width: Int, _ height: Int, _ x: Int, _ y: Int, _ format:String="") throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if sprites.count >= 64 || sprites.reduce(0, { $0 + $1.pixels.count }) + pixels.count > 4 * 1024 * 1024 {
            throw VmKill("document sprite limit")
        }
        nextSpriteId+=1
        sprites.append(DocSprite(id:nextSpriteId,pixels: pixels, width: width, height: height, x: x, y: y, col: col, row: row,format:format))
        version += 1
        return nextSpriteId
    }
    public struct SpriteLink {public let x:Int,y:Int,width:Int,height:Int,format:String}
    public func spriteLinks(_ cols:Int)->[SpriteLink] {
        lock.lock();defer {lock.unlock()};if cols<=0 {return []}
        return sprites.filter {$0.format.contains(",LM=")}.compactMap {sp in
            var vr=0;for i in 0..<min(sp.row,lines.count) {vr+=max(1,(lines[i].len+cols-1)/cols)}
            let (x,ox)=((sp.col%cols)*8).addingReportingOverflow(sp.x)
            let (y,oy)=((vr+sp.col/cols-firstVisualRow)*8).addingReportingOverflow(sp.y)
            if ox || oy {return nil};return SpriteLink(x:x,y:y,width:sp.width,height:sp.height,format:sp.format)
        }
    }
    public func renderSprites(_ dst: UnsafeMutablePointer<UInt8>, _ stride: Int, _ left: Int, _ top: Int, _ cols: Int, _ rows: Int) {
        lock.lock(); defer { lock.unlock() }
        for sp in sprites {
            var vr = 0
            for i in 0..<min(sp.row,lines.count) { vr += max(1, (lines[i].len + cols - 1) / cols) }
            let (x0, ox) = (left + (sp.col % cols) * 8).addingReportingOverflow(sp.x)
            let (y0, oy) = (top + (vr + sp.col / cols - firstVisualRow) * 8).addingReportingOverflow(sp.y)
            if ox || oy { continue }
            let (xe, ow) = x0.addingReportingOverflow(sp.width)
            let (ye, oh) = y0.addingReportingOverflow(sp.height)
            let x1 = max(left, x0), x2 = min(left + cols * 8, ow ? Int.max : xe)
            let y1 = max(top, y0), y2 = min(top + rows * 8, oh ? Int.max : ye)
            if x1 >= x2 || y1 >= y2 { continue }
            for y in y1..<y2 { for x in x1..<x2 {
                let c = sp.pixels[(y - y0) * sp.width + x - x0]
                if c != 255 { dst[y * stride + x] = c }
            } }
        }
    }
    private var row = 0
    private var col = 0
    public private(set) var fg = Console.DFT_FG
    public private(set) var bg = Console.DFT_BG
    private var flags = 0
    private var fgStack: [Int] = []
    /** Incremented on every change; the UI re-renders when it differs. (Kotlin @Volatile) */
    public private(set) var version: Int64 = 0
    public var cursorVisible = true
    /** Line being edited by GetStr (shown after the output), or nil. */
    public private(set) var inputLine: String?
    public private(set) var inputCursor = 0
    public var defaultFg = Console.DFT_FG
    public var defaultBg = Console.DFT_BG

    // pending partial DolDoc command spanning writes
    private var pending: [UInt8] = []
    private var inCmd = false

    public init(_ maxLines: Int = 2000) { self.maxLines = maxLines }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll(); lines.append(Line())
        row = 0; col = 0; sprites.removeAll(); firstVisualRow = 0
        version += 1
    }

    public func setColors(_ fgc: Int, _ bgc: Int) {
        lock.lock(); defer { lock.unlock() }
        defaultFg = fgc; defaultBg = bgc; fg = fgc; bg = bgc
        version += 1
    }

    public func setInput(_ s: String?, _ cursor: Int) {
        lock.lock(); defer { lock.unlock() }
        // The terminal re-asserts its input line every UI tick: only a real change is a new version
        // (otherwise the window redraws at the display rate and starves the interpreter threads).
        if s == inputLine && cursor == inputCursor { return }
        inputLine = s; inputCursor = cursor; version += 1
    }

    /** Writes raw TempleOS text (bytes 0..255). */
    public func write(_ bytes: [UInt8], _ off: Int = 0, _ len: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        let n = len ?? bytes.count
        var i = off
        while i < off + n { put(Int(bytes[i])); i += 1 }
        version += 1
    }

    /** Kotlin `s[it].code.toByte()`: one byte per UTF-16 unit. */
    public func write(_ s: String) { write(s.utf16.map { UInt8(truncatingIfNeeded: $0) }) }

    private func put(_ c: Int) {
        if inCmd {
            if c == 0x24 { // '$'
                inCmd = false
                if pending.isEmpty { emit(0x24) } else { command(pending) }
                pending.removeAll(keepingCapacity: true)
            } else if c == 10 || pending.count > 512 {
                // unterminated: print literally
                inCmd = false
                emit(0x24)
                let s = pending; pending.removeAll(keepingCapacity: true)
                for ch in s { emit(Int(ch)) }
                emit(c)
            } else { pending.append(UInt8(truncatingIfNeeded: c)) }
            return
        }
        if c == 0x24 { inCmd = true } else { emit(c) }
    }

    private func emit(_ c: Int) {
        switch c {
        case 10: if col >= lines[row].len { lines[row].fill = attr() }; newLine()
        case 13: col = 0
        case 9: let n = 8 - (col & 7); for _ in 0..<n { cell(32) }
        case 8: if col > 0 { col -= 1; lines[row].put(col, 32 | (attr() << 8)) }
        case 12: clearLocked()
        case 0: break
        default: cell(c)
        }
    }

    private func clearLocked() { lines.removeAll(); lines.append(Line()); row = 0; col = 0; sprites.removeAll(); firstVisualRow = 0 }

    private func attr() -> Int { (bg << 4) | fg }

    private func cell(_ c: Int) {
        // bounded memory: very long lines wrap (MAX_COLS x maxLines cells at most)
        if col >= Console.MAX_COLS { newLine() }
        lines[row].put(col, (c & 0xFF) | (attr() << 8) | flags)
        col += 1
    }

    private func newLine() {
        row += 1
        col = 0
        if row >= lines.count { lines.append(Line()) }
        while lines.count > maxLines { lines.removeFirst(); row -= 1; for i in sprites.indices { sprites[i].row -= 1 }; sprites.removeAll { $0.row < 0 } }
    }

    // ---- Latin-1 byte-string helpers (Kotlin String semantics on 8-bit text)

    /** Kotlin Char.isWhitespace() for Latin-1 codes. */
    private static func isWs(_ c: UInt8) -> Bool { (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0xA0 }

    private static func trim(_ s: [UInt8]) -> [UInt8] {
        var a = 0, b = s.count
        while a < b && isWs(s[a]) { a += 1 }
        while b > a && isWs(s[b - 1]) { b -= 1 }
        return Array(s[a..<b])
    }

    private static func endsWith(_ s: [UInt8], _ suf: String) -> Bool {
        let t = latin1(suf)
        return s.count >= t.count && Array(s[(s.count - t.count)...]) == t
    }

    private static func contains(_ s: [UInt8], _ sub: String) -> Bool {
        let t = latin1(sub)
        if t.isEmpty { return true }
        if s.count < t.count { return false }
        for i in 0...(s.count - t.count) where Array(s[i..<(i + t.count)]) == t { return true }
        return false
    }

    private func colorArg(_ s: [UInt8]) -> Int? {
        let v = Console.trim(s)
        if let c = Console.COLOR_NAMES[latin1(v)] { return c }
        // Kotlin toIntOrNull: optional sign, decimal digits, Int range
        return Int32(latin1(v)).map { Int($0) }
    }

    private static let HIDDEN_TAG_CODES: Set<String> = ["IB", "IS", "ID", "WW", "HL", "LM", "RM", "SY", "BP", "CM"]

    private func command(_ cmd: [UInt8]) {
        let code = latin1(cmd.prefix(2))
        let rest: [UInt8] = cmd.count > 2 ? Array(cmd[2...]) : []
        let args = splitArgs(rest)
        if let c = Console.COLOR_NAMES[latin1(cmd)] { fg = c; return }
        switch code {
        case "FG": fg = args.isEmpty ? defaultFg : (colorArg(args[0]) ?? fg)
        case "BG": bg = args.isEmpty ? defaultBg : (colorArg(args[0]) ?? bg)
        case "FD": defaultFg = colorArg(args.getOrNil(0) ?? []) ?? defaultFg
        case "BD": defaultBg = colorArg(args.getOrNil(0) ?? []) ?? defaultBg
        case "CL": clearLocked()
        case "PT": fg = 2 // prompt color
        case "IV": flags = setFlag(flags, Console.ATTRF_INVERT, cmd)
        case "UL": flags = setFlag(flags, Console.ATTRF_UNDERLINE, cmd)
        case "BK": flags = setFlag(flags, Console.ATTRF_BLINK, cmd)
        case "CM", "CH", "ID", "WW", "HL", "LM", "RM", "SY", "SP", "IB", "IS", "BP", "MA", "BT", "CB",
             "DA", "HC", "ER", "PI", "AN", "HI", "LS", "TR", "MU", "CU", "HX", "SO", "SU", "SX", "WR":
            // tags with visible text: show it
            let tag = args.first { $0.first == 0x22 }
            if let tag = tag, !Console.HIDDEN_TAG_CODES.contains(code) {
                for ch in unquote(tag) { cell(Int(ch)) }
            }
        case "TX", "LK", "TI":
            guard let tag = args.first(where: { $0.first == 0x22 }) else { return }
            let save = flags
            if code == "LK" { flags = flags | Console.ATTRF_UNDERLINE }
            for ch in unquote(tag) { cell(Int(ch)) }
            flags = save
        default:
            // unknown command: if it looks like plain text with $ (e.g. "$5"), print verbatim
            if !cmd.isEmpty && !Unicode.Scalar(cmd[0]).properties.isUppercase {
                emit(0x24); for ch in cmd { emit(Int(ch)) }; emit(0x24)
            }
        }
    }

    private func setFlag(_ f: Int, _ bit: Int, _ cmd: [UInt8]) -> Int {
        let on = !Console.endsWith(cmd, ",0") && !Console.endsWith(cmd, "-0")
        if on && cmd.count > 2 && Console.contains(cmd, ",1") { return f | bit }
        else if cmd.count == 2 { return f | bit }
        else if on { return f | bit } else { return f & ~bit }
    }

    private func splitArgs(_ s: [UInt8]) -> [[UInt8]] {
        var res: [[UInt8]] = []
        var sb: [UInt8] = []
        var q = false
        var i = 0
        // trimStart(',', '+', '-')
        var st = 0
        while st < s.count && (s[st] == 0x2C || s[st] == 0x2B || s[st] == 0x2D) { st += 1 }
        let t = Array(s[st...])
        while i < t.count {
            let c = t[i]
            if c == 0x22 { q = !q }
            if c == 0x5C && q && i + 1 < t.count { sb.append(c); sb.append(t[i + 1]); i += 2; continue }
            if c == 0x2C && !q { res.append(sb); sb.removeAll() } else { sb.append(c) }
            i += 1
        }
        if !sb.isEmpty { res.append(sb) }
        return res
    }

    private func unquote(_ s: [UInt8]) -> [UInt8] {
        let t = Console.trim(s)
        if t.count < 2 || t[0] != 0x22 { return t }
        let lastQ = t.lastIndex(of: 0x22) ?? -1
        let body = Array(t[1..<max(lastQ, 1)])
        var sb: [UInt8] = []
        var i = 0
        while i < body.count {
            if body[i] == 0x5C && i + 1 < body.count {
                switch body[i + 1] {
                case 0x6E: sb.append(10)   // \n
                case 0x74: sb.append(9)    // \t
                case 0x64: sb.append(0x24) // \d -> $
                default: sb.append(body[i + 1])
                }
                i += 2
            } else { sb.append(body[i]); i += 1 }
        }
        return sb
    }

    // ------------------------------------------------------------ readers

    /** Plain text of the whole document (DolDoc removed), newline separated. */
    public func plainText() -> String {
        lock.lock(); defer { lock.unlock() }
        var sb: [UInt8] = []
        for (i, l) in lines.enumerated() {
            for c in 0..<l.len { sb.append(UInt8(truncatingIfNeeded: l.cells[c] & 0xFF)) }
            if i < lines.count - 1 { sb.append(10) }
        }
        return latin1(sb)
    }

    /** The last [n] non-blank lines as plain text (for screen readers; no full copy). */
    public func tailText(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        var i = lines.count - 1
        while i >= 0 && out.count < n {
            let l = lines[i]; i -= 1
            var sb: [UInt8] = []
            for c in 0..<l.len { sb.append(UInt8(truncatingIfNeeded: l.cells[c] & 0xFF)) }
            let t = latin1(sb)
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append(String(t.reversed().drop(while: { $0 == " " }).reversed())) }
        }
        return out.reversed().joined(separator: "\n")
    }

    /** Snapshot of all lines (copies). */
    public func snapshot() -> [Line] {
        lock.lock(); defer { lock.unlock() }
        return lines.map { $0.copy() }
    }

    public func lineCount() -> Int { lock.lock(); defer { lock.unlock() }; return lines.count }
    public func cursorRow() -> Int { lock.lock(); defer { lock.unlock() }; return row }
    public func cursorCol() -> Int { lock.lock(); defer { lock.unlock() }; return col }

    /** Visual rows of the document at [cols] columns (for scroll bars). */
    public func visualRows(_ cols: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for l in lines { n += max(1, (l.len + cols - 1) / cols) }
        return n + (inputLine != nil ? 1 : 0)
    }

    /**
     * Renders the document into a TempleOS text_base style cell grid ([cols] x
     * [rows]), wrapping lines and scrolling so the cursor row is visible.
     */
    public func renderCells(_ dst: inout [Int], _ cols: Int, _ rows: Int, _ blankAttr: Int, _ scrollBack: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        let blank = 32 | (blankAttr << 8)
        for i in 0..<(cols * rows) { dst[i] = blank }
        // wrap into visual rows
        var vis: [ArraySlice<Int>] = []
        var cursorVis = 0
        for (i, l) in lines.enumerated() {
            var c = 0
            if i == row { cursorVis = vis.count + col / cols }
            let fillCell = l.fill >= 0 ? 32 | (l.fill << 8) : -1
            if l.len == 0 { vis.append(fillCell >= 0 ? ArraySlice([Int](repeating: fillCell, count: cols)) : []) }
            while c < l.len {
                let n = min(cols, l.len - c)
                let v = l.cells[c..<(c + n)]
                c += n
                // the row's rest takes the newline's colors
                if c >= l.len && fillCell >= 0 && n < cols { vis.append(ArraySlice(Array(v) + [Int](repeating: fillCell, count: cols - n))) }
                else { vis.append(v) }
            }
        }
        if let il = inputLine, !vis.isEmpty {
            let last = vis.removeLast()
            let units = Array(il.utf16)
            var merged = [Int](last)
            merged.reserveCapacity(last.count + units.count)
            let a = ((defaultBg << 4) | defaultFg) << 8
            for u in units { merged.append((Int(u) & 0xFF) | a) }
            var c = 0
            repeat {
                let n = min(cols, merged.count - c)
                vis.append(merged[c..<(c + max(n, 0))])
                c += cols
            } while c < merged.count
            cursorVis = vis.count - 1
        }
        let first = max(0, max(cursorVis, vis.count - 1) - rows + 1 - scrollBack)
        firstVisualRow = first
        for r in 0..<rows {
            guard let v = vis.getOrNil(first + r) else { break }
            let n = min(v.count, cols)
            var k = 0
            var si = v.startIndex
            while k < n { dst[r * cols + k] = v[si]; k += 1; si += 1 }
        }
    }
}
