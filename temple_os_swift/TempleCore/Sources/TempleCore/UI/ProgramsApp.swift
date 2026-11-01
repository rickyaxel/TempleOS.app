import Foundation

/** Historical expressions are evidence only. Typed destinations alone dispatch. */
public final class HistoricalMenus {
    public struct Entry {
        public let label: String, group: String, kind: String, target: String, programId: String
        public let expression: String, context: String, availability: String
        public var localizedContext: String {
            switch context {
            case "editor": return tr("menu.start.editor")
            case "file-manager": return tr("app.files.title")
            default: return tr("catalog.context.owner")
            }
        }
        public var localizedAvailability: String {
            switch availability {
            case "supported": return tr("catalog.availability.supported")
            case "source-only": return tr("games.source_only")
            case "runtime-context", "document-context", "context-only": return tr("catalog.context.owner")
            default: return tr("catalog.availability.unsupported")
            }
        }
    }
    public struct Menu {
        public let id: String, title: String, source: String, type: String
        public let dynamic: Bool, owners: [String], entries: [Entry]
        public var localizedType: String { tr("catalog.group.menus.\(type)") }
    }
    public let menus: [Menu]
    public let symbols: [String:[String]]
    public init(_ menus: [Menu], _ symbols:[String:[String]] = [:]) { self.menus = menus;self.symbols=symbols }
    public func byId(_ id: String) -> Menu? { menus.first { $0.id == id } }
    public static func parse(_ text: String) throws -> HistoricalMenus {
        guard let root = try Json.parse(text) as? [String: Any?], let list = root["menus"] as? [[String: Any?]] else { throw JsonError("invalid historical menus") }
        let menus = list.map { m -> Menu in
            func s(_ k: String) -> String { (m[k] ?? nil) as? String ?? "" }
            let entries = ((m["entries"] ?? nil) as? [[String: Any?]] ?? []).map { e -> Entry in
                func t(_ k: String) -> String { (e[k] ?? nil) as? String ?? "" }
                return Entry(label: t("label"), group: t("group"), kind: t("actionKind"), target: t("target"), programId: t("programId"), expression: t("originalAction"), context: t("requiredContext"), availability: t("availability"))
            }
            return Menu(id: s("id"), title: s("title"), source: s("source"), type: s("menuType"), dynamic: (m["dynamic"] ?? nil) as? Bool ?? false, owners: (m["ownerProgramIds"] ?? nil) as? [String] ?? [], entries: entries)
        }
        if Set(menus.map { $0.id }).count != menus.count { throw JsonError("duplicate historical menu ID") }
        return HistoricalMenus(menus,(root["symbols"] ?? nil) as? [String:[String]] ?? [:])
    }
    public static func load(_ shell: Shell) -> HistoricalMenus {
        guard let data = shell.env.runtimeFile("original-menus.json") else { return HistoricalMenus([]) }
        return (try? parse(String(decoding: data, as: UTF8.self))) ?? HistoricalMenus([])
    }
}

/** Resolve original references within C:, never through host paths or macro evaluation. */
public enum OriginalNavigation {
    public static func resolve(_ shell:Shell,_ base:String,_ target:String)->String? {
        let logical=target.hasSuffix(".Z") ? String(target.dropLast(2)) : target
        guard let path=Paths.normalize(base,logical) else {return nil}
        var candidates=[path,path+".DD",path+".HC",path+".HH",path+".IN"]
        if path.hasPrefix("C:/Home/") {candidates += candidates.map {"C:/"+Paths.name($0)}}
        return candidates.first {shell.fs.exists($0)}
    }
    @discardableResult public static func dispatch(_ shell:Shell,_ e:HistoricalMenus.Entry)->Bool {
        guard e.availability == "supported" else {return false}
        switch e.kind {
        case "launchProgram":
            guard let p=shell.catalog.byId(e.programId),!p.unsupported else {return false}
            Launch.program(shell,p.path,p)
        case "openSource":guard shell.fs.exists(e.target) else {return false};Launch.editor(shell,e.target)
        case "openDocument":guard shell.fs.exists(e.target) else {return false};Launch.doc(shell,e.target)
        case "openDirectory":guard shell.fs.isDir(e.target) else {return false};Launch.files(shell,e.target)
        default:return false
        };return true
    }
    public static func macro(_ shell:Shell,_ source:String,_ expression:String)->Bool {
        for m in shell.historicalMenus.menus where m.source.equalsIgnoreCase(source) && m.type == "document" {
            if let i=m.entries.firstIndex(where:{$0.expression.trimmed() == expression.trimmed()}) {
                if !dispatch(shell,m.entries[i]) {Launch.programs(shell);(shell.focused?.app as? ProgramsApp)?.showHistoricalEntry(m.id,i)}
                return true
            }
        };return false
    }
}

/** Static editor/file menus retain original grouping; only explicit adapters enable commands. */
public enum OriginalContextMenu {
    public static func items(_ shell:Shell,_ source:String,_ actions:[String:()->Void])->[MenuItem] {
        guard let menu=shell.historicalMenus.menus.first(where:{$0.source == source && $0.type == "pulldown"}) else {return []}
        let groups=menu.entries.reduce(into:[String]()) {if !$0.contains($1.group) {$0.append($1.group)}}
        return groups.map {group in
            MenuItem(group) { [weak shell] in
                guard let shell else {return}
                let children=menu.entries.filter {$0.group == group}.map {entry->MenuItem in
                    let action=actions[group+"/"+entry.label]
                    return MenuItem(entry.label,enabled:action != nil) {action?()}
                }
                shell.showMenu(children,4,shell.insetTop+shell.barH,group)
            }
        }
    }
}

/** Native bitmap-document view, hosted by the existing window/deck and input system. */
public final class ProgramsApp: App {
    public override var kind: String { "programs" }
    private var history: [String] = [], offsets: [String:Int] = [:]
    private var route = "g:programs"
    private var menus: HistoricalMenus {shell.historicalMenus}
    public override var title: String {
        if route.hasPrefix("g:"), let g = shell.catalog.group(String(route.dropFirst(2))) { return g.localizedTitle }
        if route.hasPrefix("p:"), let p = shell.catalog.byId(String(route.dropFirst(2))) { return p.title }
        if route.hasPrefix("m:"), let m = menus.byId(String(route.dropFirst(2))) { return m.title }
        return shell.catalog.group("programs")?.localizedTitle ?? tr("catalog.group.programs")
    }
    private struct Row { let label: String, action: String, value: String
        init(_ label: String, _ action: String, _ value: String = "") { self.label=label;self.action=action;self.value=value }
    }
    private var hits: [(Rect,Row)] = []
    private var keyboardRows:[(Rect,Row)]=[],selection:[String:Int]=[:]
    private var renderedRoute=""
    private var viewport = Rect(0,0,0,0), backRect = Rect(0,0,0,0), up = Rect(0,0,0,0), down = Rect(0,0,0,0)
    private var contentHeight = 0
    public func showGroup(_ id: String) {
        guard shell.catalog.group(id) != nil else { return }
        history.removeAll()
        var parent = shell.catalog.group(id)?.parent ?? ""
        while !parent.isEmpty { history.insert("g:"+parent,at:0);parent=shell.catalog.group(parent)?.parent ?? "" }
        route="g:"+id;invalidate()
    }
    private func navigate(_ next: String) {
        if route == next { return }
        if let index=history.firstIndex(of:next) {history=Array(history.prefix(index))}
        else {history.append(route);if history.count>32 {history.removeFirst()}}
        route=next;invalidate()
    }
    public func showProgram(_ id:String) {if shell.catalog.byId(id) != nil {navigate("p:"+id)}}
    public func showHistoricalEntry(_ id:String,_ index:Int) {
        guard let m=menus.byId(id),m.entries.indices.contains(index) else {return}
        activate(Row("","entry",id+"\n"+String(index)))
    }
    public override func navigateBack() -> Bool {
        if let last=history.popLast() {route=last;invalidate()}
        else if navigationParentId != nil {return super.navigateBack()}
        else {if let w=shell.windows.first(where:{$0.app === self}) {shell.close(w)};shell.showStartMenu()}
        return true
    }
    private func rows() -> [Row] {
        var out: [Row] = []
        let id=String(route.dropFirst(2))
        if route.hasPrefix("g:"), let g=shell.catalog.group(id) {
            out.append(Row(g.source,"text"))
            for child in shell.catalog.children(g.id) {out.append(Row(child.localizedTitle,"navigate","g:"+child.id))}
            for pid in g.programIds {if let p=shell.catalog.byId(pid) {out.append(Row(p.unsupported ? tr("a11y.unavailable",("label",p.title)) : p.title,"navigate","p:"+pid))}}
            for mid in g.menuIds {if let m=menus.byId(mid) {out.append(Row(m.title+"  ["+m.source.replacingOccurrences(of:"C:/",with:"")+"]","navigate","m:"+mid))}}
            for ref in g.references where !ref.path.isEmpty {out.append(Row(ref.available ? ref.label : tr("a11y.unavailable",("label",ref.label)),!ref.available ? "text" : ref.directory ? "directory" : ref.path.hasSuffix(".DD") ? "document" : "source",ref.path))}
            if !g.document.isEmpty {out.append(Row(g.document,"document",g.document))}
            if !g.directory.isEmpty {out.append(Row(g.directory,"directory",g.directory))}
        } else if route.hasPrefix("p:"), let p=shell.catalog.byId(id) {
            out.append(Row(p.path,"text"));out.append(Row(p.source,"text"))
            if !p.localizedDescription.isEmpty {out.append(Row(p.localizedDescription,"text"))}
            if p.unsupported {out.append(Row(tr("games.source_only"),"text"))}
            if !p.localizedNote.isEmpty {out.append(Row(p.localizedNote,"text"))}
            if !p.unsupported {out.append(Row(tr("button.run_in",("engine",shell.settings.engine == Settings.ENGINE_NATIVE ? Engines.NATIVE_NAME : Engines.TERRY_NAME)),"run",p.id))}
            out.append(Row(tr("menu.edit_source"),"source",p.path))
            for m in menus.menus where m.owners.contains(p.id) {out.append(Row(m.title,"navigate","m:"+m.id))}
        } else if route.hasPrefix("m:"), let m=menus.byId(id) {
            out.append(Row(m.source,"text"));out.append(Row(m.localizedType,"text"))
            if m.source == "C:/PersonalMenu.DD" {out.append(Row(shell.catalog.group("games")?.localizedTitle ?? tr("menu.games.title"),"games"))}
            if m.type != "document" {out.append(Row(tr("games.source_only"),"text"))}
            for pid in m.owners {if let p=shell.catalog.byId(pid) {out.append(Row(p.title,"navigate","p:"+pid))}}
            var group=""
            for (i,e) in m.entries.enumerated() {
                if e.group != group && !e.group.isEmpty {group=e.group;out.append(Row(group,"text"))}
                let label = (e.label.isEmpty ? (e.target.isEmpty ? String(e.expression.prefix(100)) : e.target) : e.label).replacingOccurrences(of:"\u{1f}",with:" ")
                out.append(Row(label,"entry",m.id+"\n"+String(i)))
            }
            if shell.fs.exists(m.source) {out.append(Row(tr("menu.edit_source"),"source",m.source))}
            else {out.append(Row(tr("doc.link_not_found",("file",m.source)),"text"))}
        } else if route.hasPrefix("a:") {
            let parts=id.components(separatedBy:"\n")
            if parts.count==2,let m=menus.byId(parts[0]),let i=Int(parts[1]),m.entries.indices.contains(i) {
                let e=m.entries[i]
                out += [Row(e.label,"text"),Row(e.localizedContext,"text"),Row(e.localizedAvailability,"text"),Row(e.expression,"text")]
                if shell.fs.exists(m.source) {out += [Row(tr("games.source_only"),"text"),Row(tr("menu.edit_source"),"source",m.source)]}
                else {out.append(Row(tr("doc.link_not_found",("file",m.source)),"text"))}
            }
        }
        return out
    }
    private func activate(_ row: Row) {
        switch row.action {
        case "navigate":navigate(row.value)
        case "games":Launch.games(shell)
        case "run":if let p=shell.catalog.byId(row.value),!p.unsupported {Launch.program(shell,p.path,p)}
        case "source":if shell.fs.exists(row.value) {Launch.editor(shell,row.value)} else {shell.showToast(tr("games.source_only"))}
        case "document":if shell.fs.exists(row.value) {Launch.doc(shell,row.value)} else {shell.showToast(tr("games.source_only"))}
        case "directory":if shell.fs.isDir(row.value) {Launch.files(shell,row.value)} else {shell.showToast(tr("games.source_only"))}
        case "entry":
            let parts=row.value.components(separatedBy:"\n")
            guard parts.count==2,let m=menus.byId(parts[0]),let i=Int(parts[1]),m.entries.indices.contains(i) else {return}
            let e=m.entries[i]
            if m.type == "document" && e.availability == "supported" {
                switch e.kind {
                case "launchProgram":if let p=shell.catalog.byId(e.programId) {if p.unsupported {navigate("p:"+p.id)} else {Launch.program(shell,p.path,p)}}
                case "openSource":activate(Row("","source",e.target))
                case "openDocument":activate(Row("","document",e.target))
                case "openDirectory":activate(Row("","directory",e.target))
                default:navigate("a:"+row.value)
                }
            } else {navigate("a:"+row.value)}
        default:break
        }
    }
    public override func draw(_ s: Surface, _ r: Rect) {
        let m=shell.metrics,ts=min(m.textScale,max(1,(r.w-16)/240)),header=max(m.rowH,24)
        s.fill(r,Palette.WHITE);backRect=Rect(r.x,r.y,min(r.w/3,80),header)
        s.uiText(backRect.x+4,m.textTop(r.y,header),tr("doc.menu.back"),Palette.BLUE,backRect.w-8,scale:ts)
        a11yButton(backRect,tr("doc.menu.back"))
        s.uiText(backRect.right+4,m.textTop(r.y,header),title,Palette.PURPLE,r.w-backRect.w-8,scale:ts)
        a11yText(Rect(backRect.right,r.y,r.w-backRect.w,header),title)
        viewport=Rect(r.x,r.y+header,r.w,max(0,r.h-header-m.rowH))
        up=Rect(r.x,viewport.bottom,r.w/2,m.rowH);down=Rect(up.right,viewport.bottom,r.w-up.w,m.rowH)
        hits.removeAll(keepingCapacity:true)
        keyboardRows.removeAll(keepingCapacity:true)
        var y=viewport.y+8-(offsets[route] ?? 0)
        s.withClip(viewport) {
            for row in rows() {
                let lines=s.wrapUi(row.label,max(8,r.w-24),ts)
                let h=max(row.action == "text" ? 16*ts : m.rowH,(lines.count*10+8)*ts),cell=Rect(r.x+4,y,r.w-8,max(row.action == "text" ? 16*ts : m.rowH,(lines.count*10+8)*ts))
                let chosen=row.action != "text" && keyboardRows.count == (selection[route] ?? -1)
                if chosen {s.fill(cell,Palette.YELLOW)}
                if row.action != "text" {keyboardRows.append((cell,row))}
                for (i,line) in lines.enumerated() {s.uiText(r.x+12,y+4+i*10*ts,line,row.action == "text" ? Palette.PURPLE : Palette.BLUE,r.w-24,alignEnd:L10n.rtl,scale:ts)}
                let hit=cell.intersect(viewport)
                if hit.h>=min(16,h) {if row.action == "text" {a11yText(hit,row.label)} else {a11yButton(hit,row.label,selected:chosen);hits.append((hit,row))}}
                y+=h
            }
        }
        contentHeight=y+(offsets[route] ?? 0)-viewport.y
        renderedRoute=route
        let limit=max(0,contentHeight-viewport.h)
        if (offsets[route] ?? 0)>limit {offsets[route]=limit;invalidate()}
        s.hline(r.x,r.right-1,viewport.bottom,Palette.PURPLE)
        s.text(up.x+up.w/2,up.y+(up.h-8)/2,"\u{18}",Palette.BLUE);s.text(down.x+down.w/2,down.y+(down.h-8)/2,"\u{19}",Palette.BLUE)
        a11yButton(up,tr("a11y.scroll_menu_up"));a11yButton(down,tr("a11y.scroll_menu_down"))
    }
    public override func tap(_ x: Int,_ y: Int,_ r: Rect) {
        if backRect.contains(x,y) {_ = navigateBack()}
        else if up.contains(x,y) {move(-max(48,viewport.h*2/3))}
        else if down.contains(x,y) {move(max(48,viewport.h*2/3))}
        else if let hit=hits.first(where:{$0.0.contains(x,y)}) {activate(hit.1)}
    }
    private func move(_ delta: Int) {offsets[route]=min(max(0,(offsets[route] ?? 0)+delta),max(0,contentHeight-viewport.h));invalidate()}
    private func choose(_ delta:Int) {
        if keyboardRows.isEmpty {return}
        let old=selection[route] ?? -1
        let index=min(max(old<0 ? (delta>0 ? 0 : keyboardRows.count-1) : old+delta,0),keyboardRows.count-1)
        selection[route]=index;let rect=keyboardRows[index].0
        if rect.y<viewport.y {move(rect.y-viewport.y)} else if rect.bottom>viewport.bottom {move(rect.bottom-viewport.bottom)}
        invalidate()
    }
    public override func scroll(_ dx:Int,_ dy:Int,_ r:Rect) {move(-dy)}
    public override func key(_ ch:Int,_ sc:Int64,_ down:Bool)->Bool {
        if !down {return true}
        if renderedRoute != route {return true}
        switch Int(sc & 127) {
        case Keys.SC_CURSOR_DOWN,Keys.SC_CURSOR_RIGHT:choose(1)
        case Keys.SC_CURSOR_UP,Keys.SC_CURSOR_LEFT:choose(-1)
        case Keys.SC_PAGE_DOWN:move(max(48,viewport.h/2))
        case Keys.SC_PAGE_UP:move(-max(48,viewport.h/2))
        case Keys.SC_SPACE,Keys.SC_ENTER:
            let i=selection[route] ?? -1
            if keyboardRows.indices.contains(i) {activate(keyboardRows[i].1)} else if let first=hits.first {activate(first.1)}
        case Keys.SC_HOME:move(-contentHeight)
        case Keys.SC_END:move(contentHeight)
        default:if ch == Keys.CH_ESC {_ = navigateBack()} else {return false}
        };return true
    }
    public override func saveState()->[String:String] {
        var st=["route":route,"history":history.joined(separator:"\t")]
        for (k,v) in offsets {st["offset."+k]=String(v)}
        for (k,v) in selection {st["selection."+k]=String(v)}
        return st
    }
    public func restore(_ st:[String:String]) {
        func valid(_ r:String)->Bool {
            if r.hasPrefix("g:") {return shell.catalog.group(String(r.dropFirst(2))) != nil}
            if r.hasPrefix("p:") {return shell.catalog.byId(String(r.dropFirst(2))) != nil}
            if r.hasPrefix("m:") {return menus.byId(String(r.dropFirst(2))) != nil}
            return false
        }
        let candidate=st["route"] ?? "g:programs";route=valid(candidate) ? candidate : "g:programs"
        history=Array((st["history"] ?? "").components(separatedBy:"\t").filter {valid($0)}.prefix(32))
        offsets.removeAll();for (k,v) in st where k.hasPrefix("offset.") {offsets[String(k.dropFirst(7))]=max(0,Int(v) ?? 0)}
        selection.removeAll();for (k,v) in st where k.hasPrefix("selection.") {selection[String(k.dropFirst(10))]=max(-1,Int(v) ?? -1)}
    }
}
