import Foundation

// Port of ui/DocViewerApp.kt (strings indexed by Unicode scalar; text is Latin-1).

/**
 * DolDoc document viewer. Supports the subset used by the bundled
 * documentation: $FG/$BG colors and color names, $TX (+CX centering), $LK links
 * (FI/FF/FL/FA file targets), $MA/$BT macros (run their HolyC in a terminal),
 * $TR trees (shown expanded), $ID indentation, $UL/$IV/$BK, $CL, $WW, $$.
 * Embedded sprites ($SP) are shown as placeholders.
 */
public final class DocViewerApp: App {
    public override var kind: String { "doc" }
    public private(set) var path: String
    public override var title: String { tr("app.doc.title") + " " + InputCharacterPolicy.display(path.substringAfterLast("/")) }
    private var historyStack: [String] = []
    private var raw: String = ""
    private var laidOutCols = -1
    private var vlines: [[Int]] = []
    private final class Link {
        let line: Int, c0: Int, c1: Int, target: String, macro: Bool, label: String
        init(_ line: Int, _ c0: Int, _ c1: Int, _ target: String, _ macro: Bool, _ label: String) {
            self.line = line; self.c0 = c0; self.c1 = c1; self.target = target; self.macro = macro; self.label=label
        }
    }
    private var links: [Link] = []
    /** In 8 px rows, counting the notice's rows before the document's first line. */
    private var top = 0
    private var scrollAcc = 0
    public private(set) var provenance: DocProvenance? = nil
    private var notice: [(String, Int)] = []
    private var noticeKey = ""
    private var noticeRows = 0
    private var collapsed: [String:Set<Int>] = [:]

    /** Underline attribute bit (Kotlin 0x80000000.toInt()); bit 31 of the cell. */
    private static let ATTR_UL = 0x80000000
    private static let ATTR_IV = 0x20000000
    private static let ATTR_BK = 0x10000000

    public init(_ shell: Shell, _ startPath: String) {
        path = startPath
        super.init(shell)
        load(startPath)
    }

    public func load(_ p: String) {
        path = p
        let data = shell.fs.readFile(p)
        raw = data == nil ? "$RED$" + L10n.tr8("doc.not_found") + "$FG$ \(p)" : textPart(data!)
        provenance = data == nil ? nil : DocProvenance.of(shell.fs, p)
        laidOutCols = -1; top = 0; noticeKey = ""
        invalidate()
    }

    // ------------------------------------------------------------ layout

    private func layout(_ cols: Int) {
        vlines.removeAll(); links.removeAll()
        var fg = Palette.BLUE, bg = Palette.WHITE
        var flags = 0
        var indent = 0
        var cur: [Int] = []
        var wrap = true
        var hiddenIndent: Int?
        func flush() {
            vlines.append(cur); cur = []
            for _ in 0..<max(0, indent) { cur.append(32 | (bg << 12) | (fg << 8)) }
        }
        func put(_ c: Int) {
            if cur.count >= cols {
                if wrap {
                    // move the current word to the next line
                    var i = cur.count - 1
                    while i > indent && (cur[i] & 0xFF) != 32 { i -= 1 }
                    if i > indent && cur.count - i < cols / 2 {
                        let tail = Array(cur[(i + 1)...])
                        while cur.count > i { cur.removeLast() }
                        flush(); cur.append(contentsOf: tail)
                    } else { flush() }
                } else { return }
            }
            cur.append((c & 0xFF) | (fg << 8) | (bg << 12) | flags)
        }
        func text(_ t: String) {
            for ch in t.unicodeScalars {
                switch ch {
                case "\n": flush()
                case "\t": let n = 8 - (cur.count % 8); for _ in 0..<n { put(32) }
                case "\r": break
                default: put(Int(ch.value))
                }
            }
        }
        var i = 0
        let s = raw.scArr
        while i < s.count {
            let tagStart=i
            let c = s[i]
            if c != "$" {
                if hiddenIndent != nil {i+=1;continue}
                switch c {
                case "\n": flush()
                case "\t": let n = 8 - (cur.count % 8); for _ in 0..<n { put(32) }
                case "\r": break
                default: put(Int(c.value))
                }
                i += 1; continue
            }
            var end = -1
            var k = i + 1
            var quoted=false
            while k < s.count {
                if s[k] == "\\" && quoted {k+=2;continue}
                if s[k] == "\"" {quoted.toggle()}
                if s[k] == "$" && !quoted {end=k;break};k+=1
            }
            if end < 0 { put(36); i += 1; continue }
            if end == i + 1 { put(36); i += 2; continue }
            let cmd = scString(s[(i + 1)..<end])
            i = end + 1
            let code = scString(cmd.unicodeScalars.prefix(2))
            if hiddenIndent != nil && code != "ID" {continue}
            let args = parseArgs(cmd)
            let tag = args.first { $0.hasPrefix("\"") }.map { unquote($0) }
            func attr(_ k: String) -> String? {
                guard let a = args.first(where: { $0.hasPrefix("\(k)=") }) else { return nil }
                let v = a.substringAfter("=")
                return v.hasPrefix("\"") ? unquote(v) : v
            }
            if let v = Console.COLOR_NAMES[cmd] { fg = v; continue }
            switch code {
            case "FG": fg = args.dropFirst().first.flatMap { color($0) } ?? Palette.BLUE
            case "BG": bg = args.dropFirst().first.flatMap { color($0) } ?? Palette.WHITE
            case "FD", "BD": break
            case "CL": vlines.removeAll(); links.removeAll(); cur = []
            case "WW": wrap = !cmd.hasSuffix(",0")
            case "ID":
                let n = Int(args.dropFirst().first?.trimmed() ?? "") ?? 0
                indent = coerceInUI(indent + n, 0, cols / 2)
                if let limit=hiddenIndent,indent<=limit {hiddenIndent=nil}
                if cur.allSatisfy({ ($0 & 0xFF) == 32 }) { cur = []; for _ in 0..<max(0, indent) { cur.append(32 | (bg << 12) | (fg << 8)) } }
            case "UL": flags = cmd.hasSuffix(",0") ? flags & ~DocViewerApp.ATTR_UL : flags | DocViewerApp.ATTR_UL
            case "IV": flags = cmd.hasSuffix(",0") ? flags & ~DocViewerApp.ATTR_IV : flags | DocViewerApp.ATTR_IV
            case "BK": flags = cmd.hasSuffix(",0") ? flags & ~DocViewerApp.ATTR_BK : flags | DocViewerApp.ATTR_BK
            case "TX":
                let t = tag ?? ""
                if cmd.contains("+CX") { let pad = max(0, (cols - t.scLen) / 2 - cur.count); for _ in 0..<pad { put(32) } }
                text(t)
            case "TR":
                let save=fg,line=vlines.count,c0=cur.count,label=tag ?? ""
                let shut=collapsed[path]?.contains(tagStart) == true
                fg=Palette.PURPLE;text((shut ? "\u{10}" : "\u{1f}")+label);fg=save
                links.append(Link(line,c0,cur.count,"TREE:"+String(tagStart),false,label))
                if shut {hiddenIndent=indent}
            case "LK", "MA", "BT", "MU":
                let label = tag ?? ""
                let positional = args.filter {$0.hasPrefix("\"")}.dropFirst().first.map {unquote($0)}
                let target = attr("A") ?? attr("LM") ?? attr("LE") ?? (code == "LK" ? positional : nil) ?? label
                let isMacro = code != "LK"
                let line = vlines.count, c0 = cur.count
                let save = fg, saveFlags = flags
                fg = isMacro ? Palette.LTBLUE : Palette.RED
                flags = flags | DocViewerApp.ATTR_UL
                text(code == "BT" ? "[\(label)]" : label)
                flags = saveFlags; fg = save
                for row in line...vlines.count {
                    let first=row == line ? c0 : 0,last=row == vlines.count ? cur.count : vlines[row].count
                    if last>first {links.append(Link(row,first,last,target,isMacro,label))}
                }
            case "SP", "IB", "IS": if code == "SP" { let save = fg; fg = Palette.DKGRAY; text("[" + L10n.tr8("doc.picture") + "]"); fg = save }
            case "HL", "CM", "SY", "PT", "LM", "RM", "HC", "ER", "CH": break
            default: if let t = tag { text(t) }
            }
        }
        if !cur.isEmpty { flush() }
        laidOutCols = cols
    }

    private func color(_ a: String) -> Int? {
        Console.COLOR_NAMES[a.trimmed()] ?? Int(a.trimmed()).map { coerceInUI($0, 0, 15) }
    }

    private func parseArgs(_ cmd: String) -> [String] {
        var res: [String] = []
        var sb = String.UnicodeScalarView()
        var q = false
        var i = 0
        let a = cmd.scArr
        while i < a.count {
            let c = a[i]
            if c == "\\" && q && i + 1 < a.count { sb.append(c); sb.append(a[i + 1]); i += 2; continue }
            if c == "\"" { q = !q }
            if c == "," && !q { res.append(String(sb).trimmed()); sb = String.UnicodeScalarView() } else { sb.append(c) }
            i += 1
        }
        res.append(String(sb).trimmed())
        return res
    }

    private func unquote(_ t: String) -> String {
        var a = t.trimmed().scArr
        if a.first == "\"" { a.removeFirst() }
        if let j = a.lastIndex(of: "\"") { a = Array(a[0..<j]) }
        let s = scString(a)
        return s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\d", with: "$")
    }

    // ------------------------------------------------------------ view

    /** The notice's lines (text, color) wrapped to `w`: a title, then its explanation. */
    private func layoutNotice(_ s: Surface, _ w: Int) {
        let key = "\(L10n.version)/\(w)/\(provenance.map { "\($0)" } ?? "-")"
        if key == noticeKey { return }
        noticeKey = key
        if let pv = provenance {
            notice = s.wrapUi(tr(pv.titleKey), w).map { ($0, Palette.PURPLE) } + s.wrapUi(tr(pv.bodyKey), w).map { ($0, Palette.DKGRAY) }
        } else { notice = [] }
        // 10 px per text line plus a 4 px margin above and a rule with 3 px below, in whole 8 px rows
        noticeRows = notice.isEmpty ? 0 : (notice.count * 10 + 4 + 4 + 7) / 8
    }

    public override func draw(_ s: Surface, _ r: Rect) {
        let cols = max(16, r.w / 8)
        if cols != laidOutCols { layout(cols) }
        layoutNotice(s, r.w - 12)
        s.fill(r, Palette.WHITE)
        let rows = r.h / 8
        let total = noticeRows + vlines.count
        top = coerceInUI(top, 0, max(0, total - rows))
        if top < noticeRows {
            // the notice: separate from the document (its own accessibility element), scrolled with it
            let y0 = r.y - top * 8
            var y = y0 + 4
            for (t, c) in notice {
                if y >= r.y && y + 8 <= r.bottom { _ = s.uiText(r.x + 6, y, t, c, r.w - 12, alignEnd: L10n.rtl) }
                y += 10
            }
            let rule = y0 + noticeRows * 8 - 4
            if rule >= r.y && rule < r.bottom { s.fillRect(r.x + 6, rule, r.w - 12, 1, Palette.LTGRAY) }
            let vy = max(r.y, y0)
            a11yText(Rect(r.x, vy, r.w, min(r.bottom, y0 + noticeRows * 8) - vy), notice.map { $0.0 }.joined(separator: " "))
        }
        let docTop = max(0, top - noticeRows)
        let skip = max(0, noticeRows - top)
        let docRect = Rect(r.x, r.y + skip * 8, r.w, r.h - skip * 8)
        var visible: [String] = []
        for i in 0..<max(0, rows - skip) {
            guard let l = vlines.getOrNil(docTop + i) else { break }
            for (c, cell) in l.enumerated() where c < cols { s.cell(r.x + c * 8, docRect.y + i * 8, cell) }
            let t = latin1(l.map { UInt8(truncatingIfNeeded: $0 & 0xFF) })
            let trimmed = String(t.reversed().drop(while: { $0 == " " }).reversed())
            if !trimmed.isEmpty { visible.append(trimmed) }
        }
        if docRect.h > 0 { a11yText(docRect, visible.joined(separator: "\n")) }
        for link in links {
            let y=r.y+(link.line+noticeRows-top)*8
            if y>=r.y && y+8<=r.bottom {a11yButton(Rect(r.x+link.c0*8,y,min(r.w-link.c0*8,(link.c1-link.c0)*8),8),link.label)}
        }
        if total > rows {
            let h = r.h * rows / total
            s.fillRect(r.right - 3, r.y + (r.h - h) * top / max(1, total - rows), 3, max(8, h), Palette.BLUE)
        }
    }

    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        scrollAcc -= dy; top += scrollAcc / 8; scrollAcc %= 8
        top = max(0, top); invalidate()
    }

    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        let line = top + (y - r.y) / 8 - noticeRows
        let col = (x - r.x) / 8
        guard let l = links.first(where: { $0.line == line && col >= $0.c0 - 1 && col <= $0.c1 + 1 }) else { return }
        follow(l.target, l.macro)
    }

    private func follow(_ target: String, _ macro: Bool) {
        if target.hasPrefix("TREE:"),let index=Int(target.dropFirst(5)) {
            var set=collapsed[path] ?? [];if set.contains(index) {set.remove(index)} else {set.insert(index)}
            collapsed[path]=set;laidOutCols = -1;invalidate();return
        }
        if macro {
            let expression=target.replacingOccurrences(of:"\\n",with:"\n")
            if !OriginalNavigation.macro(shell,path,expression) {Launch.terminal(shell,Paths.parent(path),expression)}
            return
        }
        let t = target.trimmed()
        let kind = t.substringBefore(":", "")
        let rest = t.substringAfter(":", t)
        switch kind {
        case "FI", "FA", "FF", "FL", "PI", "PF", "PL":
            let file = rest.substringBefore(",")
            guard let full=OriginalNavigation.resolve(shell,Paths.parent(path),file) else {shell.showToast(tr("doc.link_not_found",("file",file)));return}
            if shell.fs.isDir(full) {Launch.files(shell,full)}
            else if [".HC",".HH",".IN",".CPP"].contains(where:{full.uppercased().hasSuffix($0)}) { Launch.editor(shell, full) }
            else { historyStack.append(path); load(full) }
        case "HI":
            if let g=shell.catalog.groups.first(where:{$0.source == "#help_index "+rest}) {Launch.programs(shell,g.id)}
            else {shell.showToast(tr("doc.link_symbol_unsupported",("target",rest)))}
        case "MN":
            if let source=shell.historicalMenus.symbols[rest]?.first(where:{shell.fs.exists($0)}) {Launch.editor(shell,source)}
            else {shell.showToast(tr("doc.link_symbol_unsupported",("target",rest)))}
        case "BF", "DN":
            shell.showToast(tr("doc.link_symbol_unsupported", ("target", rest)))
        default:
            if let p=OriginalNavigation.resolve(shell,Paths.parent(path),t) {
                if shell.fs.isDir(p) {Launch.files(shell,p)}
                else if [".HC",".HH",".IN",".CPP"].contains(where:{p.uppercased().hasSuffix($0)}) {Launch.editor(shell,p)}
                else {historyStack.append(path);load(p)}
            }
            else { shell.showToast(tr("doc.link_unsupported", ("target", t.take(30)))) }
        }
    }

    public override func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if !down { return true }
        switch Int(sc & 0x7F) {
        case Keys.SC_CURSOR_DOWN: top += 1
        case Keys.SC_CURSOR_UP: top = max(0, top - 1)
        case Keys.SC_PAGE_DOWN, Keys.SC_SPACE: top += 20
        case Keys.SC_PAGE_UP: top = max(0, top - 20)
        case Keys.SC_BACKSPACE, Keys.SC_ESC: back()
        default: break
        }
        invalidate(); return true
    }

    public override func navigateBack()->Bool {
        if let p=historyStack.popLast() {load(p);return true}
        return super.navigateBack()
    }
    private func back() {_ = navigateBack()}

    public override func menu() -> [MenuItem] {
        [
            MenuItem(tr("doc.menu.back"), enabled: !historyStack.isEmpty || navigationParentId != nil) { [self] in back() },
            MenuItem(tr("doc.menu.help_index")) { [self] in historyStack.append(path); load("C:/Doc/HelpIndex.DD") },
            MenuItem(tr("menu.edit_source")) { [self] in Launch.editor(shell, path) },
        ]
    }

    /** The laid-out document text (CP437 bytes as chars), without the notice; tests compare it with the file. */
    func documentText(_ cols: Int = 80) -> String {
        if cols != laidOutCols { layout(cols) }
        return vlines.map { l in latin1(l.map { UInt8(truncatingIfNeeded: $0 & 0xFF) }) }.joined(separator: "\n")
    }

    public override func saveState() -> [String: String] { ["path": path, "top": String(top)] }
    public func restoreTop(_ t: Int) { top = t }
}

/**
 * Where a document shown by the viewer comes from, from the provenance the bundled drive records
 * for each file (bundled-fs.index, tools/resource-packaging/build_bundled_fs.py) and whether the
 * user changed it. docs/fidelity-audit/TEMPLEOS_DOCUMENTATION_ATTRIBUTION_AUDIT.md explains the
 * categories and how the bundled files were checked against the TempleOS V5.03 ISO.
 */
public enum DocProvenance: String {
    /** Category A: Terry A. Davis' file, byte for byte as on the ISO. */
    case ORIGINAL = "original"
    /** Category C: Terry's file with offensive content censored or redacted (docs/content-moderation). */
    case ADAPTED = "adapted"
    /** Distributed with TempleOS, but the text is someone else's (Doc/Credits.DD: the Bible, the PCI list). */
    case INCLUDED = "included"
    /** Written for TempleOS Mobile. */
    case MOBILE = "mobile"
    /** Category E: the user's copy over a bundled file. */
    case CHANGED = "changed"
    /** Category E: a file that is not part of the bundled drive. */
    case USER = "user"

    public var titleKey: String { "doc.notice.\(rawValue).title" }
    public var bodyKey: String { "doc.notice.\(rawValue).body" }

    public static let TERRY = "TempleOS V5.03 (public domain, Terry A. Davis)"

    public static func of(_ fs: LayeredFs, _ path: String) -> DocProvenance {
        guard let origin = fs.bundledOrigin(path) else { return .USER }
        if !fs.isOriginal(path) { return .CHANGED }
        if origin == TERRY { return .ORIGINAL }
        if origin.hasPrefix(TERRY + "; modified:") { return .ADAPTED }
        if origin == "TempleOS Mobile" { return .MOBILE }
        return .INCLUDED
    }
}
