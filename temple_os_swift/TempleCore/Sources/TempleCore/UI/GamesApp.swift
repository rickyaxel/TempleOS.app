import Foundation

/** Generated historical metadata, shared with Android; source is V5.03 PersonalMenu.DD. */
public final class OriginalGamesMenu {
    public struct Entry {
        public let programId: String, title: String, label: String, category: String
        public let row: Int, asset: String, width: Int, height: Int, minX: Int, minY: Int
        public let sourcePath: String
        public let documentLine: Int, documentColumn: Int, headingLine: Int, headingColumn: Int
        public let animationAsset:String, animationWidth:Int, animationHeight:Int, animationMinX:Int, animationMinY:Int
    }
    public let entries: [Entry]
    public init(_ entries: [Entry]) { self.entries = entries }
    public static func parse(_ text: String) throws -> OriginalGamesMenu {
        guard let root = try Json.parse(text) as? [String: Any?], let list = root["entries"] as? [[String: Any?]] else { throw JsonError("invalid original menu") }
        let entries = list.map { m -> Entry in
            func s(_ k: String) -> String { (m[k] ?? nil) as? String ?? "" }
            func n(_ k: String) -> Int { ((m[k] ?? nil) as? NSNumber)?.intValue ?? 0 }
            return Entry(programId: s("programId"), title: s("title"), label: s("originalLabel"), category: s("category"), row: n("row"), asset: s("asset"), width: n("width"), height: n("height"), minX: n("minX"), minY: n("minY"), sourcePath: s("sourcePath"), documentLine: n("documentLine"), documentColumn: n("documentColumn"), headingLine: n("headingLine"), headingColumn: n("headingColumn"),animationAsset:s("animationAsset"),animationWidth:n("animationWidth"),animationHeight:n("animationHeight"),animationMinX:n("animationMinX"),animationMinY:n("animationMinY"))
        }
        if Set(entries.map { $0.programId }).count != entries.count { throw JsonError("duplicate original menu ID") }
        return OriginalGamesMenu(entries)
    }
}

/** White DolDoc page, original sprite/label anchors, purple headings and integer pixel scaling. */
public final class GamesApp: App {
    public override func navigateBack() -> Bool {
        if navigationParentId != nil { return super.navigateBack() }
        if let w=shell.windows.first(where:{$0.app === self}) {shell.close(w)}
        shell.showStartMenu();return true
    }
    public override var kind: String { "games" }
    public override var title: String { tr("menu.games.title") }
    private let original: OriginalGamesMenu
    private var icons: [String: [UInt8]] = [:]
    private var animations:[String:IndexedAnimation]=[:]
    private var animationMs:Int64=0
    private var visible=true
    public override func onVisibility(_ visible:Bool) {self.visible=visible}
    public override func tick(_ nowMs:Int64)->Bool {
        if visible && !catalogView && nowMs/100 != animationMs/100 {animationMs=nowMs;invalidate();return true};return false
    }
    private var catalogView = false, offset = 0, contentHeight = 0
    private var selected = -1
    private var viewport = Rect(0,0,0,0)
    private var tabs: [Rect] = []
    private var cells: [(Rect, OriginalGamesMenu.Entry)] = []
    private var programs: [(Rect, ProgramInfo)] = []
    private var up = Rect(0,0,0,0), down = Rect(0,0,0,0), indexRect = Rect(0,0,0,0)
    public override init(_ shell: Shell) {
        original = shell.env.runtimeFile("games-menu/menu.json").flatMap { try? OriginalGamesMenu.parse(String(decoding: $0, as: UTF8.self)) } ?? OriginalGamesMenu([])
        super.init(shell)
    }
    public override func draw(_ s: Surface, _ r: Rect) {
        let m = shell.metrics
        let naturalWidth = original.entries.map { ($0.documentColumn + $0.label.count) * 8 }.max() ?? 280
        let ts = catalogView ? min(m.textScale,max(1,(r.w - 8) / 192)) : min(m.textScale,max(1,(r.w - 16) / naturalWidth))
        let names = [tr("games.original"), tr("games.catalog")]
        let tabLines = names.map { s.wrapUi($0, max(8, r.w / 2 - 8), ts) }
        let header = max(m.rowH, max(24, ((tabLines.map { $0.count }.max() ?? 1) * 12 + 8) * ts))
        tabs = [Rect(r.x,r.y,r.w / 2,header), Rect(r.x + r.w / 2,r.y,r.w - r.w / 2,header)]
        s.fill(r, Palette.WHITE)
        for (i,t) in tabs.enumerated() {
            let active = (i == 1) == catalogView
            s.fill(t, active ? Palette.YELLOW : Palette.WHITE)
            let name = names[i], lines = tabLines[i]
            for (line, text) in lines.enumerated() {
                s.uiText(t.x + 4, t.y + (t.h - lines.count * 12 * ts) / 2 + 2 * ts + line * 12 * ts,
                         text, Palette.BLUE, t.w - 8, alignEnd:L10n.rtl, scale: ts)
            }
            a11yButton(t,name,selected: active)
        }
        viewport = Rect(r.x,r.y + header,r.w,max(0,r.h - header - m.rowH))
        up = Rect(r.x,viewport.bottom,r.w / 2,m.rowH)
        down = Rect(r.x + r.w / 2,viewport.bottom,r.w - r.w / 2,m.rowH)
        cells.removeAll(keepingCapacity: true); programs.removeAll(keepingCapacity: true)
        var y = viewport.y + 8 - offset
        s.withClip(viewport) {
            if !catalogView {
                let categories = original.entries.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
                for (groupIndex,category) in categories.enumerated() {
                    let es = original.entries.filter { $0.category == category }
                    s.uiText(r.x + min(es[0].headingColumn * 8 * ts + 8,r.w / 3),y,category,Palette.PURPLE,r.w - 16,scale: ts)
                    if y>=viewport.y && y+8*ts<=viewport.bottom {a11yText(Rect(r.x+8,y,r.w-16,8*ts),category)}
                    var previousLine = es[0].headingLine
                    let rows = es.reduce(into: [Int]()) { if !$0.contains($1.row) { $0.append($1.row) } }
                    for row in rows {
                        let members = es.filter { $0.row == row }
                        let exact = (members.map { ($0.documentColumn + $0.label.count) * 8 * ts }.max() ?? 0) <= r.w - 16
                        let columns = exact ? members.count : max(1,(r.w - 16) / (104 * ts))
                        var firstChunk = true
                        for start in stride(from: 0,to: members.count,by: columns) {
                            let chunk = Array(members[start..<min(start + columns,members.count)])
                            let gap = firstChunk ? (members[0].documentLine - previousLine) * 8 : max(64,chunk.map { -$0.minY }.max() ?? 0) + 24
                            let baseline = y + gap * ts, cellW = (r.w - 16) / chunk.count
                            for (i,e) in chunk.enumerated() {
                                let animated = !e.animationAsset.isEmpty
                                let iw=animated ? e.animationWidth : e.width,ih=animated ? e.animationHeight : e.height
                                let mx=animated ? e.animationMinX : e.minX,my=animated ? e.animationMinY : e.minY
                                let labelW = e.label.count * 8 * ts
                                let tx = exact ? r.x + 8 + e.documentColumn * 8 * ts : r.x + 8 + i * cellW + (cellW - labelW) / 2
                                let imageX = tx + labelW + mx * ts
                                let x = min(tx,imageX), right = max(tx + labelW + 8 * ts,imageX + iw * ts)
                                let cell = Rect(x,baseline + min(my,0) * ts,right - x,(max(8,my+ih)-min(my,0))*ts)
                                cells.append((cell,e))
                                let p = shell.catalog.byId(e.programId), disabled = p == nil || p!.unsupported
                                if cell.bottom > viewport.y && cell.y < viewport.bottom {
                                    var pixels:[UInt8]?
                                    if animated {
                                        if animations[e.animationAsset]==nil,let bytes=shell.env.runtimeFile(e.animationAsset) {animations[e.animationAsset]=try? IndexedAnimation(bytes)}
                                        pixels=try? animations[e.animationAsset]?.pixels(animationMs)
                                    } else {
                                        if icons[e.asset]==nil,let bytes=shell.env.runtimeFile(e.asset),bytes.count==8+iw*ih {icons[e.asset]=Array(bytes.dropFirst(8))}
                                        pixels=icons[e.asset]
                                    }
                                    if let pixels=pixels,pixels.count==iw*ih {
                                        let iy=baseline+my*ts
                                        for yy in 0..<ih {for xx in 0..<iw {let c=Int(pixels[yy*iw+xx]);if c<16 {s.fillRect(imageX+xx*ts,iy+yy*ts,ts,ts,c)}}}
                                    }
                                    s.uiText(tx,baseline,e.label,disabled ? Palette.DKGRAY : Palette.LTBLUE,labelW,scale: ts)
                                    if selected>=0 && selected<cells.count && cells[selected].1.programId == e.programId {s.hline(tx,tx+labelW-1,baseline+8*ts,Palette.PURPLE)}
                                    if disabled || p?.status == "partial" { s.text(tx + labelW,baseline,disabled ? "?" : "*",Palette.RED,scale: ts) }
                                    let hit = cell.intersect(viewport)
                                    if hit.h > 8 * ts { a11yButton(hit,disabled ? tr("a11y.unavailable",("label",e.title)) : p!.title) }
                                }
                            }
                            y = baseline; firstChunk = false
                        }
                        previousLine = members[0].documentLine
                    }
                    let nextLine = groupIndex + 1 < categories.count ? original.entries.first { $0.category == categories[groupIndex + 1] }!.headingLine : previousLine + 4
                    y += (nextLine - previousLine) * 8 * ts
                }
            } else {
                let shown = Set(original.entries.map { $0.programId })
                let extra0 = shell.catalog.programs.filter { $0.author == "Terry A. Davis" && !shown.contains($0.id) && !$0.unsupported }
                let extra = extra0.filter { $0.path.hasPrefix("C:/Demo/Snd/") } + extra0.filter { !$0.path.hasPrefix("C:/Demo/Snd/") }
                func group(_ p: ProgramInfo) -> String {
                    if p.path.hasPrefix("C:/Demo/Snd/") { return tr("games.sound") }
                    if p.path.hasPrefix("C:/Demo/Games/") { return "/Demo/Games" }
                    if p.path.hasPrefix("C:/Demo/Graphics/") { return "/Demo/Graphics" }
                    return String(Paths.parent(p.path).dropFirst(2))
                }
                let categories = extra.reduce(into: [String]()) { let g = group($1); if !$0.contains(g) { $0.append(g) } }
                for category in categories {
                    let headingLines = s.wrapUi(category, max(8, r.w - 16), ts)
                    let heading = Rect(r.x + 8, y, r.w - 16, max(24 * ts, (headingLines.count * 12 + 4) * ts))
                    for (i,line) in headingLines.enumerated() { s.uiText(heading.x,y+i*12*ts,line,Palette.PURPLE,heading.w,alignEnd:L10n.rtl,scale:ts) }
                    let hit = heading.intersect(viewport)
                    if hit.h >= 10 { a11yText(hit,category) }
                    y += heading.h
                    for p in extra.filter({ group($0) == category }) {
                        let lines = s.wrapUi(p.title,r.w - 24,ts)
                        let h = max(m.rowH,(lines.count * 10 + 8) * ts), cell = Rect(r.x + 4,y,r.w - 8,max(m.rowH,(lines.count * 10 + 8) * ts))
                        programs.append((cell,p))
                        if cell.bottom > viewport.y && y < viewport.bottom {
                            for (i,l) in lines.enumerated() { s.uiText(r.x + 12,y + 4 + i * 10 * ts,l,Palette.BLUE,r.w - 24,scale: ts) }
                            let hit = cell.intersect(viewport)
                            if hit.h >= 16 { a11yButton(hit,p.title) }
                        }
                        y += h
                    }
                    y += 8 * ts
                }
                let indexLines = s.wrapUi(tr("games.demo_index"), max(8, r.w - 24), ts)
                let doc = Rect(r.x + 4,y,r.w - 8,max(m.rowH,(indexLines.count * 12 + 8) * ts))
                for (i,line) in indexLines.enumerated() { s.uiText(doc.x+8,y+4+i*12*ts,line,Palette.BLUE,doc.w-16,alignEnd:L10n.rtl,scale:ts) }
                if doc.intersect(viewport).h >= 16 { a11yButton(doc.intersect(viewport),tr("games.demo_index")) }
                indexRect = doc; y += doc.h
            }
        }
        contentHeight = y + offset - viewport.y
        let maxOffset = max(0,contentHeight - viewport.h)
        if offset > maxOffset { offset = maxOffset; invalidate() }
        s.hline(r.x,r.right - 1,viewport.bottom,Palette.PURPLE)
        s.text(up.x + up.w / 2,up.y + (up.h - 8) / 2,"\u{18}",Palette.BLUE)
        s.text(down.x + down.w / 2,down.y + (down.h - 8) / 2,"\u{19}",Palette.BLUE)
        a11yButton(up,tr("a11y.scroll_menu_up")); a11yButton(down,tr("a11y.scroll_menu_down"))
    }
    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        if let tab = tabs.firstIndex(where: { $0.contains(x,y) }) { catalogView = tab == 1; offset = 0; selected = -1; invalidate(); return }
        if up.contains(x,y) { move(-max(48,viewport.h * 2 / 3)); return }
        if down.contains(x,y) { move(max(48,viewport.h * 2 / 3)); return }
        if !viewport.contains(x,y) { return }
        if catalogView {
            if let i=programs.firstIndex(where:{$0.0.contains(x,y)}) {selected=i;let p=programs[i].1;Launch.program(shell,p.path,p);return}
            if indexRect.contains(x,y) { Launch.doc(shell,"C:/Doc/DemoIndex.DD") }
        } else if let e = cells.first(where: { $0.0.contains(x,y) })?.1 {
            selected=cells.firstIndex(where:{$0.1.programId == e.programId}) ?? -1
            if let p = shell.catalog.byId(e.programId), !p.unsupported { Launch.program(shell,p.path,p) }
            else { shell.showToast(self.shell.catalog.byId(e.programId)?.localizedNote ?? tr("games.source_only")); Launch.editor(shell,e.sourcePath) }
        }
    }
    private func move(_ d: Int) { offset = min(max(0,offset + d),max(0,contentHeight - viewport.h)); invalidate() }
    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) { move(-dy) }
    public override func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if !down { return true }
        switch Int(sc & 127) {
        case Keys.SC_CURSOR_DOWN,Keys.SC_CURSOR_RIGHT:select(1)
        case Keys.SC_CURSOR_UP,Keys.SC_CURSOR_LEFT:select(-1)
        case Keys.SC_PAGE_DOWN: move(max(48,viewport.h / 2))
        case Keys.SC_PAGE_UP: move(-max(48,viewport.h / 2))
        case Keys.SC_HOME: move(-contentHeight)
        case Keys.SC_END: move(contentHeight)
        case Keys.SC_SPACE,Keys.SC_ENTER:
            let targets=catalogView ? programs.map {$0.0} : cells.map {$0.0}
            if !targets.isEmpty {let i=targets.indices.contains(selected) ? selected : targets.firstIndex(where:{$0.y>=viewport.y && $0.bottom<=viewport.bottom}) ?? 0;let cell=targets[i];tap(cell.x+cell.w/2,cell.y+cell.h/2,viewport)}
        case Keys.SC_ESC:_ = navigateBack()
        default: return false
        }
        return true
    }
    private func select(_ delta:Int) {
        let targets=catalogView ? programs.map {$0.0} : cells.map {$0.0}
        if targets.isEmpty {return};selected=min(max(selected<0 ? (delta>0 ? 0 : targets.count-1) : selected+delta,0),targets.count-1)
        let cell=targets[selected];if cell.y<viewport.y {move(cell.y-viewport.y)} else if cell.bottom>viewport.bottom {move(cell.bottom-viewport.bottom)};invalidate()
    }
    public override func saveState() -> [String:String] { ["catalog":String(catalogView),"offset":String(offset),"selection":String(selected)] }
    public func restore(_ catalog: Bool, _ scroll: Int, _ selection:Int = -1) { catalogView = catalog; offset = max(0,scroll);selected=selection }
}
