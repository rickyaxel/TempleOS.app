import Foundation

// Port of ui/SmallApps.kt.

/**
 * Mobile-authored Paint wrapper, not Terry's DolDoc SpriteMainEd/SpriteBitMapEd.
 * This app does not use the execution engine selector. Pictures are saved as uncompressed
 * TempleOS .GR files, compatible with the original Adam/Gr/GrDC.HC
 * DCSave/DCLoad and GRRead format.
 */
public final class PaintApp: App, FrameSource {
    public override var kind: String { "paint" }
    public override var title: String { tr("app.paint.title") + (path.map { " " + InputCharacterPolicy.display($0.substringAfterLast("/")) } ?? "") + (modified ? "*" : "") }
    public var path: String?
    private var image = GRImage()
    public var w: Int { image.width }
    public var h: Int { image.height }
    public var pix: [UInt8]
    private var color = Palette.BLACK
    private var tool = 0 // 0 pen, 1 line, 2 rect, 3 fill, 4 eraser
    private var thick = 1
    private var modified = false
    private var canvas = Rect(0, 0, 0, 0)
    private var startX = -1, startY = -1, lastX = -1, lastY = -1
    private var pointerOwner: Int?
    private var strokeBase: [UInt8]?
    private var strokeModified = false
    private var preview: [UInt8]? = nil
    private var undo: [[UInt8]] = []
    private var buttons: [(Rect, () -> Void)] = []

    /// Bounded semantic state for deterministic diagnostics; no second copy of drawing state.
    var replayState: [String: String] {
        ["tool": String(tool), "color": String(color), "thickness": String(thick),
         "owner": pointerOwner.map(String.init) ?? "none", "preview": preview == nil ? "false" : "true"]
    }

    public init(_ shell: Shell, _ path: String? = nil) {
        self.path = path
        pix = [UInt8](repeating: UInt8(Palette.WHITE), count: 320 * 240)
        super.init(shell)
        if let p = path { load(p) }
    }

    private func load(_ p: String) {
        do {
            guard let bytes = shell.fs.readFile(p) else { throw FsError("Could not read \(p)", "fs.error.could_not_read", ["path": p]) }
            let decoded = try GRImage.decodeFile(bytes, outerArchive: p.uppercased().hasSuffix(".Z"))
            image = decoded; pix = decoded.pixels
        } catch {
            // A failed open must not make Save overwrite the unreadable original with a blank canvas.
            path = nil
            if let error = error as? FsError, error.key != nil { shell.showToast(error.localized()) }
            else { shell.showToast(tr("paint.invalid_picture", ("detail", errorMessage(error)))) }
        }
    }

    private func save(_ target: String) {
        releaseInput()
        var saved = image; saved.pixels = pix
        var output = saved.encode()
        // .Z is an outer TempleOS archive, distinct from DCF_COMPRESSED inside GR.
        // CT_NONE is an original archive type; keep the extension truthful without lossy conversion.
        if target.uppercased().hasSuffix(".Z") { output = TempleArc.store(output) }
        do {
            try shell.fs.writeFile(target, output)
            image = saved; path = target; modified = false
            shell.showToast(tr("toast.saved", ("path", InputCharacterPolicy.display(target)))); invalidate()
        } catch { shell.showToast(localizedError(error)) }
    }

    public var frameW: Int { w }
    public var frameH: Int { h }
    public private(set) var frameVersion: Int64 = 0
    public var palette: [Int32] {
        guard let p = image.palette else { return Array(Palette.STD.prefix(16)) }
        return (0..<16).map { i -> Int32 in
            let red = UInt32(p[i * 8 + 5]) << 16
            let green = UInt32(p[i * 8 + 3]) << 8
            let blue = UInt32(p[i * 8 + 1])
            return Int32(bitPattern: 0xFF000000 | red | green | blue)
        }
    }
    public func copyFrame(_ dst: UnsafeMutablePointer<UInt8>) -> Int64 {
        let pixels = preview ?? pix
        pixels.withUnsafeBufferPointer { if let p = $0.baseAddress { dst.update(from: p, count: pixels.count) } }
        return frameVersion
    }
    public override func overlays(_ r: Rect) -> [Overlay] {
        canvas.w > 0 && canvas.h > 0 ? [Overlay(canvas, self)] : []
    }

    public override func draw(_ s: Surface, _ r: Rect) {
        s.fill(r, Palette.LTGRAY)
        buttons.removeAll()
        // All 16 indices remain reachable even in a narrow window.
        for c in 0..<16 {
            let x0 = r.x + c * r.w / 16, x1 = r.x + (c + 1) * r.w / 16
            let br = Rect(x0, r.y, x1 - x0, Touch.toolRow)
            s.fill(br, c); if c == color { s.frame(br, c == Palette.YELLOW ? Palette.BLACK : Palette.YELLOW) }
            a11yButton(br, tr("paint.a11y.color", ("color", colorName(c))), selected: c == color)
            buttons.append((br, { [self] in color = c; invalidate() }))
        }
        let tools = [tr("paint.tool.pen"), tr("paint.tool.line"), tr("paint.tool.rect"), tr("paint.tool.fill"), tr("paint.tool.erase")]
        var bx = r.x, by = r.y + Touch.toolRow + 2
        for i in 0...tools.count {
            let t = i < tools.count ? tools[i] : "─\(thick)"
            let bw = min(max(1, r.w), max(40, s.measureUi(t) + 8))
            if bx > r.x && bx + bw > r.right { bx = r.x; by += Touch.toolRow + 2 }
            let br = Rect(bx, by, bw, Touch.toolRow)
            s.withClip(br) { s.templeButton(br, t, i < tools.count && tool == i ? ButtonFace.SELECTED : ButtonFace.NORMAL) }
            if i < tools.count {
                a11yButton(br, tr("paint.a11y.tool", ("tool", t)), selected: tool == i)
                buttons.append((br, { [self] in tool = i; invalidate() }))
            } else {
                a11yButton(br, tr("paint.a11y.thickness", ("n", thick)))
                buttons.append((br, { [self] in thick = thick >= 8 ? 1 : thick * 2; invalidate() }))
            }
            bx += bw + 2
        }
        let top = by + Touch.toolRow + 2
        let area = Rect(r.x, top, max(0, r.w), max(0, r.bottom - top))
        var cw = area.w, ch = cw * h / w
        if ch > area.h { ch = area.h; cw = ch * w / h }
        let nextCanvas = Rect(area.x + (area.w - cw) / 2, area.y + (area.h - ch) / 2, cw, ch)
        if canvas.x != nextCanvas.x || canvas.y != nextCanvas.y || canvas.w != cw || canvas.h != ch { releaseInput() }
        canvas = nextCanvas
        frameVersion &+= 1
        s.blitScaled(preview ?? pix, w, h, canvas)
        s.frame(Rect(canvas.x - 1, canvas.y - 1, canvas.w + 2, canvas.h + 2), Palette.BLACK)
        a11yText(canvas, tr("program.a11y.picture", ("title", tr("app.paint.title"))))
    }

    private func toImg(_ x: Int, _ y: Int) -> (Int, Int) {
        // Captured events may land outside the image; clamp before multiplying coordinates.
        let cx = min(canvas.right - 1, max(canvas.x, x))
        let cy = min(canvas.bottom - 1, max(canvas.y, y))
        return ((cx - canvas.x) * w / max(1, canvas.w), (cy - canvas.y) * h / max(1, canvas.h))
    }

    private func dot(_ img: inout [UInt8], _ x: Int, _ y: Int, _ c: Int) {
        let r = thick / 2
        for dy in -r...r {
            for dx in -r...r {
                let xx = x + dx, yy = y + dy
                if xx >= 0 && xx < w && yy >= 0 && yy < h && (thick < 3 || dx * dx + dy * dy <= r * r + 1) { img[yy * w + xx] = UInt8(truncatingIfNeeded: c) }
            }
        }
    }

    private func line(_ img: inout [UInt8], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Int) {
        let n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in 0...n { dot(&img, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, c) }
    }

    private func flood(_ x: Int, _ y: Int, _ c: Int) {
        if !(x >= 0 && x < w) || !(y >= 0 && y < h) { return }
        let target = pix[y * w + x], nc = UInt8(truncatingIfNeeded: c)
        if target == nc { return }
        var stack: [Int] = [y * w + x]
        while let p = stack.popLast() {
            if pix[p] != target { continue }
            pix[p] = nc
            let px = p % w, py = p / w
            if px > 0 { stack.append(p - 1) }; if px < w - 1 { stack.append(p + 1) }
            if py > 0 { stack.append(p - w) }; if py < h - 1 { stack.append(p + w) }
        }
    }

    public override func releaseInput() {
        // Keep completed freehand segments; discard an uncommitted shape preview.
        if let base = strokeBase, pix != base { remember(base) }
        pointerOwner = nil; startX = -1; preview = nil; strokeBase = nil
        invalidate()
    }
    public override func close() { releaseInput() }
    public override func onBackground() { releaseInput() }

    public override func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if e.action == Ptr.CANCEL {
            guard pointerOwner == e.id else { return false }
            releaseInput(); return true
        }
        if e.action == Ptr.DOWN {
            guard pointerOwner == nil else { return true }
            if let b = buttons.first(where: { $0.0.contains(e.x, e.y) }) { b.1(); return true }
            if !canvas.contains(e.x, e.y) { return false }
            pointerOwner = e.id; strokeBase = pix; strokeModified = modified
            let (x, y) = toImg(e.x, e.y)
            startX = x; startY = y; lastX = x; lastY = y
            let c = tool == 4 ? Palette.WHITE : color
            switch tool { case 0, 4: dot(&pix, x, y, c); case 3: flood(x, y, color); default: break }
            if pix != strokeBase! { modified = true }
            invalidate(); return true
        }
        guard pointerOwner == e.id && startX >= 0 else { return false }
        let (x, y) = toImg(e.x, e.y)
        let c = tool == 4 ? Palette.WHITE : color
        switch tool {
        case 0, 4: line(&pix, lastX, lastY, x, y, c); lastX = x; lastY = y
        case 1, 2:
            var p = pix
            if tool == 1 { line(&p, startX, startY, x, y, color) }
            else { line(&p, startX, startY, x, startY, color); line(&p, x, startY, x, y, color); line(&p, x, y, startX, y, color); line(&p, startX, y, startX, startY, color) }
            if e.action == Ptr.MOVE { preview = p } else if e.action == Ptr.UP { pix = p; preview = nil }
        default: break
        }
        if let base = strokeBase, pix != base { modified = true }
        if e.action == Ptr.UP { finishStroke() }
        invalidate(); return true
    }

    private func finishStroke() {
        if let base = strokeBase {
            if pix != base { remember(base) } else { modified = strokeModified }
        }
        pointerOwner = nil; startX = -1; preview = nil; strokeBase = nil
    }
    private func remember(_ pixels: [UInt8]) {
        // Bound undo by bytes as well as count for larger loaded resources.
        while !undo.isEmpty && (undo.count >= 20 || undo.count * pixels.count >= 16 * 1024 * 1024) { undo.removeFirst() }
        undo.append(pixels)
    }

    public override func menu() -> [MenuItem] {
        [
            MenuItem(tr("editor.menu.open_file")) { [self] in
                shell.showDialog(Dialog.input(tr("editor.menu.open_file"), "C:/Home/Picture.GR") { [self] p in
                    if let p = p, let n = Paths.normalize("C:/Home", p) { Launch.paint(shell, n) }
                })
            },
            MenuItem(tr("menu.save")) { [self] in if let p = path { save(p) } else { saveAs() } },
            MenuItem(tr("menu.save_as")) { [self] in saveAs() },
            MenuItem(tr("menu.undo")) { [self] in releaseInput(); if let u = undo.removeLastOrNil() { pix = u; modified = true; invalidate() } },
            MenuItem(tr("paint.menu.clear")) { [self] in releaseInput(); remember(pix); pix = [UInt8](repeating: UInt8(Palette.WHITE), count: pix.count); modified = true; invalidate() },
        ]
    }

    private func saveAs() {
        shell.showDialog(Dialog.input(tr("paint.dialog.save_as"), path ?? "C:/Home/Picture.GR") { [self] p in
            guard let p = p else { return }
            guard let n = Paths.normalize("C:/Home", p) else { return }
            save(Paths.name(n).contains(".") ? n : "\(n).GR")
        })
    }

    public override var unsaved: Bool { modified }
    public override func saveState() -> [String: String] { path.map { ["path": $0] } ?? [:] }
}

/** The localized name of a TempleOS palette color. */
public func colorName(_ c: Int) -> String {
    tr("color." + (Console.COLOR_NAMES.first { $0.value == c }?.key ?? "BLACK").lowercased())
}

/** Settings: sound, desktop color, display scale, touch size, keyboard, language, storage. */
public final class SettingsApp: App {
    public override var kind: String { "settings" }
    public override var title: String { tr("app.settings.title") }
    private var rows: [(Rect, () -> Void)] = []
    private var offset = 0
    private var contentHeight = 0

    public override init(_ shell: Shell) { super.init(shell) }

    private func onOff(_ b: Bool) -> String { tr(b ? "value.on" : "value.off") }

    public override func draw(_ s: Surface, _ r: Rect) {
        s.fill(r, Palette.WHITE)
        rows.removeAll()
        let st = shell.settings
        let rtl = L10n.rtl
        let lang = st.language.isEmpty ? tr("settings.language.automatic_now", ("language", shell.uiLocale?.nativeName ?? "English"))
            : shell.uiLocale?.nativeName ?? st.language
        let items: [(String, () -> Void)] = [
            (tr("settings.language", ("value", lang)), { [self] in Launch.language(shell) }),
            (tr("settings.sound", ("value", onOff(st.sound))), { [self] in st.sound = !st.sound; if !st.sound { shell.env.tone(0.0) } }),
            (tr("settings.desktop_color", ("value", colorName(st.desktopColor))), { st.desktopColor = (st.desktopColor + 1) % 16 }),
            (tr("settings.display_scale", ("value", st.uiScale == 0 ? tr("value.auto") : "\(st.uiScale)x")), { st.uiScale = (st.uiScale + 1) % 6 }),
            (tr("settings.crisp_scaling", ("value", onOff(st.crispScaling))), { st.crispScaling = !st.crispScaling }),
            (tr("settings.touch_targets", ("value", tr(st.largeTouch ? "value.large" : "value.standard"))), { [self] in st.largeTouch = !st.largeTouch; Touch.large = st.largeTouch; shell.relayout() }),
            (tr("settings.engine", ("value", st.engine == Settings.ENGINE_NATIVE ? Engines.NATIVE_NAME : Engines.TERRY_NAME)), {
                if Engines.nativeAvailable { st.engine = st.engine == Settings.ENGINE_NATIVE ? Settings.ENGINE_TERRY : Settings.ENGINE_NATIVE } }),
            (tr("settings.storage", ("used", shell.fs.usedBytes() / 1024), ("total", shell.fs.quota >> 20)), {}),
            (tr("settings.close_all"), { [self] in for w in shell.windows { if w.app !== self { shell.close(w) } } }),
        ]
        var y = r.y + 4 - offset
        s.withClip(r) {
            for item in items {
                let lines = s.wrapUi(item.0, max(8, r.w - 20))
                let h = max(ROW_H, lines.count * 12 + 8)
                let br = Rect(r.x + 4, y, r.w - 8, h)
                s.fill(br, Palette.LTCYAN)
                for (i, line) in lines.enumerated() {
                    s.uiText(br.x + 6, br.y + (h - lines.count * 12) / 2 + 2 + i * 12,
                             line, Palette.BLUE, br.w - 12, alignEnd: rtl)
                }
                let hit = br.intersect(r)
                if hit.h >= min(16, h) { a11yButton(hit, item.0); rows.append((hit, item.1)) }
                y += h + 4
            }
            y += 4
            for line in s.wrapUi(tr("settings.display_scale_note") + "\n" + tr("input.cp437_policy"), max(8, r.w - 12)) {
                s.uiText(r.x + 6, y, line, Palette.DKGRAY, r.w - 12, alignEnd: rtl)
                let hit = Rect(r.x, y, r.w, 12).intersect(r)
                if hit.h >= 10 { a11yText(hit, line) }
                y += 12
            }
        }
        contentHeight = y + offset - r.y + 4
        let limit = max(0, contentHeight - r.h)
        if offset > limit { offset = limit; invalidate() }
        if limit > 0 {
            let h = max(8, r.h * r.h / contentHeight)
            s.fillRect(r.right - 3, r.y + (r.h - h) * offset / limit, 3, h, Palette.BLUE)
        }
    }

    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        offset = min(max(0, offset - dy), max(0, contentHeight - r.h)); invalidate()
    }

    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        rows.first { $0.0.contains(x, y) }?.1()
        shell.saveSession(); shell.invalidate(); invalidate()
    }
}

/**
 * Language: Automatic (the device's language), then the 89 UI locales in alphabetical order
 * (LanguageList), each shown by its own name and its English name. Typing filters the list (by
 * either name or the locale id). Choosing applies at once, keeps every window, and is saved with
 * the session; the chosen row stays where it was tapped although the new language may reorder
 * the list.
 */
public final class LanguageApp: App {
    public override var kind: String { "language" }
    public override var title: String { tr("app.language.title") }
    public override var wantsKeyboard: Bool { true }
    private var filter = ""
    private var scroll = 0
    private var scrollAcc = 0
    private var rows: [(Rect, String)] = []

    public override init(_ shell: Shell) { super.init(shell) }

    private func entries() -> [(String, String)] { // (locale id or "", label)
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if L10n.resolver == nil { return [] }
        let all: [(String, String)] = [("", tr("settings.language.automatic"))] + LanguageList.current().map { ($0.id, $0.label) }
        return q.isEmpty ? all : all.filter { (id, label) in !id.isEmpty && (label.lowercased().contains(q) || id.lowercased().hasPrefix(q)) }
    }

    public override func draw(_ s: Surface, _ r: Rect) {
        s.fill(r, Palette.WHITE)
        rows.removeAll()
        let rtl = L10n.rtl
        // filter field (typed on the keyboard; locale ids and English names are ASCII)
        let fr = Rect(r.x + 4, r.y + 4, r.w - 8, ROW_H)
        s.fill(fr, Palette.LTGRAY)
        let hint = filter.isEmpty ? tr("language.filter_hint") : filter
        let ex = s.uiText(fr.x + 6, fr.y + ROW_TEXT, hint, filter.isEmpty ? Palette.DKGRAY : Palette.BLACK, fr.w - 12)
        if !filter.isEmpty { s.fillRect(ex, fr.y + ROW_TEXT - 2, 2, 10, Palette.BLUE) }
        a11yText(fr, tr("a11y.text_field", ("text", filter)))
        let list = entries()
        let top = fr.bottom + 4
        scroll = coerceInUI(scroll, 0, max(0, list.count - 1))
        let current = shell.settings.language
        let viewport = Rect(r.x, top, r.w, max(0, r.bottom - top))
        var y = top
        s.withClip(viewport) {
            for i in scroll..<list.count {
                if y >= r.bottom { break }
                let (id, label) = list[i]
                let lines = s.wrapUi(label, max(8, r.w - 20))
                let h = max(ROW_H, lines.count * 12 + 8)
                let selected = id == current
                let br = Rect(r.x + 4, y, r.w - 8, h - 2)
                s.fill(br, selected ? Palette.YELLOW : (i - scroll) % 2 == 0 ? Palette.LTCYAN : Palette.WHITE)
                for (line, text) in lines.enumerated() {
                    s.uiText(br.x + 6, br.y + (br.h - lines.count * 12) / 2 + 2 + line * 12,
                             text, Palette.BLUE, br.w - 12, alignEnd: rtl)
                }
                let hit = br.intersect(viewport)
                if hit.h >= 16 { rows.append((hit, id)); a11yButton(hit, label, selected: selected) }
                y += h
            }
        }
        let visible = rows.count
        if list.count > visible {
            let h = max(8, viewport.h * max(1, visible) / list.count)
            s.fillRect(r.right - 3, top + (viewport.h - h) * scroll / max(1, list.count - 1), 3, h, Palette.BLUE)
        }
    }

    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        guard let row = rows.firstIndex(where: { $0.0.contains(x, y) }) else { return }
        let id = rows[row].1
        shell.settings.language = id
        shell.applyLanguage()
        shell.saveSession()
        // the new UI language collates the list differently: keep the chosen row under the finger
        if let at = entries().firstIndex(where: { $0.0 == id }) { scroll = max(0, at - row) }
        scrollAcc = 0
        invalidate()
    }

    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) {
        let list = entries()
        guard !list.isEmpty else { scroll = 0; scrollAcc = 0; return }
        scroll = min(max(0, scroll), list.count - 1)
        func height(_ i: Int) -> Int {
            max(ROW_H, shell.surface.wrapUi(list[i].1, max(8, r.w - 20)).count * 12 + 8)
        }
        // Rows wrap to different heights: convert drag pixels using those actual rows.
        // Dividing by ROW_H can jump over an unobserved language during a long drag.
        scrollAcc -= dy
        while scroll < list.count - 1 && scrollAcc >= height(scroll) { scrollAcc -= height(scroll); scroll += 1 }
        while scroll > 0 && -scrollAcc >= height(scroll - 1) { scrollAcc += height(scroll - 1); scroll -= 1 }
        if (scroll == 0 && scrollAcc < 0) || (scroll == list.count - 1 && scrollAcc > 0) { scrollAcc = 0 }
        invalidate()
    }

    public override func key(_ ch: Int, _ sc: Int64, _ down: Bool) -> Bool {
        if !down { return true }
        if ch == Keys.CH_BACKSPACE { if !filter.isEmpty { filter = filter.scSub(0, filter.scLen - 1) } }
        else if ch == Keys.CH_ESC { filter = "" }
        else if ch >= 0x20 && ch <= 0x7E && filter.scLen < 24 { filter.unicodeScalars.append(Unicode.Scalar(UInt8(ch))) }
        else { return false }
        scroll = 0; scrollAcc = 0; invalidate(); return true
    }
}

/**
 * Scrollable localized text: paragraphs wrapped to the window width, drawn with the TempleOS
 * font where it has the characters and with the platform's text engine otherwise.
 */
public final class TextPage {
    public final class Para {
        public let text: String, color: Int, gapBefore: Int
        public init(_ text: String, _ color: Int, _ gapBefore: Int = 0) { self.text = text; self.color = color; self.gapBefore = gapBefore }
    }
    public var paras: [Para] = []
    private var top = 0

    public init() {}

    public func draw(_ s: Surface, _ r: Rect, _ app: App) {
        s.fill(r, Palette.WHITE)
        let rtl = L10n.rtl
        var lines: [(String, Int)] = []
        for p in paras {
            for _ in 0..<max(0, p.gapBefore) { lines.append(("", p.color)) }
            for l in s.wrapUi(p.text, r.w - 12) { lines.append((l, p.color)) }
        }
        let rows = max(1, r.h / 10)
        top = coerceInUI(top, 0, max(0, lines.count - rows))
        var y = r.y + 4
        if top < min(lines.count, top + rows) {
            for i in top..<min(lines.count, top + rows) {
                let (t, c) = lines[i]
                s.uiText(r.x + 6, y, t, c, r.w - 12, alignEnd: rtl)
                y += 10
            }
        }
        app.a11yPage(r, paras.map { $0.text }.joined(separator: "\n"))
        if lines.count > rows {
            let h = r.h * rows / lines.count
            s.fillRect(r.right - 3, r.y + (r.h - h) * top / max(1, lines.count - rows), 3, max(8, h), Palette.BLUE)
        }
    }

    public func scrollBy(_ rows: Int) { top = max(0, top + rows) }
}

/** About & Credits. */
public final class AboutApp: App {
    public override var kind: String { "about" }
    public override var title: String { tr("app.about.title") }
    private let page = TextPage()
    private var builtFor = -1
    private var privacyButton = Rect(0, 0, 0, 0)

    public override init(_ shell: Shell) { super.init(shell) }

    private func build() {
        if builtFor == L10n.version { return }
        builtFor = L10n.version
        func P(_ text: String, _ color: Int, _ gap: Int = 0) -> TextPage.Para { TextPage.Para(text, color, gap) }
        // the Kotlin page also credits "about.credits.kotlin" (Android app: Kotlin standard library); the iOS port has no Kotlin
        page.paras = [
            P(Brand.appName, Palette.PURPLE),
            P(tr("about.intro.creator"), Palette.BLACK, 1),
            P(tr("about.intro.independent"), Palette.BLACK, 1),
            P(tr("about.how.title"), Palette.GREEN, 1),
            P(tr("about.how.body"), Palette.BLACK),
            P(tr("about.additions.title"), Palette.GREEN, 1),
            P(tr("about.additions.words"), Palette.BLACK),
            P(tr("about.additions.modern"), Palette.BLACK, 1),
            P(tr("about.credits.title"), Palette.GREEN, 1),
            P(" - " + tr("about.credits.templeos"), Palette.BLACK),
            P(" - " + tr("about.credits.font"), Palette.BLACK),
            P(" - " + tr("about.credits.bible"), Palette.BLACK),
            P(" - " + tr("about.credits.templeos_web"), Palette.BLACK),
            P(" - " + tr("about.credits.native"), Palette.BLACK),
            P(" - " + tr("about.credits.translations"), Palette.BLACK),
            P(tr("about.privacy.title"), Palette.GREEN, 1),
            P(tr("about.privacy.body"), Palette.BLACK),
            P(Brand.privacyURL, Palette.BLUE),
        ]
    }

    public override func draw(_ s: Surface, _ r: Rect) {
        build()
        s.fill(r, Palette.WHITE)
        let header = min(r.h, ROW_H + 8)
        privacyButton = Rect(r.x + 4, r.y + 4, max(0, r.w - 8), max(0, header - 8))
        s.fill(privacyButton, Palette.LTCYAN)
        s.uiText(privacyButton.x + 6, privacyButton.y + ROW_TEXT, tr("about.privacy.title"), Palette.BLUE,
                 max(0, privacyButton.w - 12), alignEnd: L10n.rtl)
        a11yButton(privacyButton, tr("about.privacy.title") + ": " + Brand.privacyURL)
        page.draw(s, Rect(r.x, r.y + header, r.w, max(0, r.h - header)), self)
    }
    public override func tap(_ x: Int, _ y: Int, _ r: Rect) {
        if privacyButton.contains(x, y) { shell.env.openPrivacyPolicy() }
    }
    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) { page.scrollBy(-dy / 10); invalidate() }
}

/** Creates apps and restores them from a saved session. */
public enum Launch {
    private static func origin(_ shell: Shell) -> Int? {
        guard let w = shell.focused else { return nil }
        return ["games","programs","doc"].contains(w.app.kind) || w.app.navigationParentId != nil ? w.id : nil
    }
    public static func terminal(_ shell: Shell, _ dir: String = "C:/Home", _ command: String? = nil) {
        let t = TerminalApp(shell, dir)
        shell.open(t)
        if let command = command { t.kernel.post(.exec(command)) }
    }

    public static func editor(_ shell: Shell, _ path: String?) {
        let parent = origin(shell)
        if let p = path, let w = shell.findWindow("editor", { ($0 as! EditorApp).path?.equalsIgnoreCase(p) == true }) { if parent != w.id { w.app.navigationParentId=parent }; shell.focus(w); return }
        let app=EditorApp(shell,path);app.navigationParentId=parent;shell.open(app)
    }

    public static func files(_ shell: Shell, _ dir: String) {
        let parent=origin(shell)
        if let w = shell.findWindow("files") { if parent != w.id {w.app.navigationParentId=parent};(w.app as! FilesApp).cd(dir); shell.focus(w); return }
        let app=FilesApp(shell,dir);app.navigationParentId=parent;shell.open(app)
    }

    public static func doc(_ shell: Shell, _ path: String) {
        let parent=origin(shell)
        if let w = shell.findWindow("doc") {if parent != w.id {w.app.navigationParentId=parent};(w.app as! DocViewerApp).load(path); shell.focus(w); return }
        let app=DocViewerApp(shell,path);app.navigationParentId=parent;shell.open(app)
    }

    public static func program(_ shell: Shell, _ path: String, _ info0: ProgramInfo?) {
        let info = info0 ?? shell.catalog.byPath(path)
        if shell.settings.engine == Settings.ENGINE_NATIVE {
            if let reason = Engines.unavailableReason(shell, path) {
                // never a silent fallback: say why, and let the user run it on the interpreter
                let title = info?.title ?? path.substringAfterLast("/").substringBefore(".")
                shell.showDialog(Dialog.confirm(tr("engine.unavailable.title", ("engine", Engines.NATIVE_NAME)),
                    tr("engine.unavailable.message", ("title", title), ("engine", Engines.NATIVE_NAME), ("reason", tr(reason))),
                    tr("button.run_in", ("engine", Engines.TERRY_NAME))) { programOn(shell, path, info, nil) })
                return
            }
            programOn(shell, path, info, Engines.binding(path))
            return
        }
        programOn(shell, path, info, nil)
    }

    private static func programOn(_ shell: Shell, _ path: String, _ info: ProgramInfo?, _ native: NativeBinding?) {
        let parent=origin(shell)
        if let w=shell.findWindow("program",{ guard let p=$0 as? ProgramApp else {return false};return p.path.equalsIgnoreCase(path) && (p.native != nil) == (native != nil) }) {if parent != w.id {w.app.navigationParentId=parent};shell.focus(w);return}
        let start = { let app=ProgramApp(shell,path,info,nil,native:native);app.navigationParentId=parent;_ = shell.open(app,maximized:info?.usesGraphics == true) }
        switch info?.status {
        case "unsupported":
            shell.showDialog(Dialog.confirm(tr("program.unsupported.title", ("title", info!.title)),
                tr("program.unsupported.message", ("reason", info!.localizedNote)), tr("button.run_anyway")) { start() })
        case "partial":
            start(); shell.showToast("\(info!.title): \(info!.localizedNote)")
        default:
            start()
        }
    }

    public static func games(_ shell: Shell) { if let w = shell.findWindow("games") { shell.focus(w); return }; let app=GamesApp(shell);app.navigationParentId=origin(shell);shell.open(app,maximized:true) }
    public static func programs(_ shell: Shell, _ group: String = "programs") {
        if let w=shell.findWindow("programs"),let app=w.app as? ProgramsApp {app.showGroup(group);shell.focus(w);return}
        let app=ProgramsApp(shell);app.navigationParentId=origin(shell);app.showGroup(group);shell.open(app,maximized:true)
    }

    public static func god(_ shell: Shell) { if let w = shell.findWindow("god") { shell.focus(w); return }; shell.open(GodApp(shell)) }
    @discardableResult
    public static func paint(_ shell: Shell, _ path: String? = nil) -> Shell.Window {
        if let p = path, let w = shell.findWindow("paint", { ($0 as! PaintApp).path?.equalsIgnoreCase(p) == true }) {
            shell.focus(w); return w
        }
        return shell.open(PaintApp(shell, path))
    }
    public static func settings(_ shell: Shell) { if let w = shell.findWindow("settings") { shell.focus(w); return }; shell.open(SettingsApp(shell)) }
    public static func about(_ shell: Shell) { if let w = shell.findWindow("about") { shell.focus(w); return }; shell.open(AboutApp(shell)) }
    public static func language(_ shell: Shell) { if let w = shell.findWindow("language") { shell.focus(w); return }; shell.open(LanguageApp(shell)) }

    /** Recreates an app from session state (programs restart from the beginning). */
    public static func restore(_ shell: Shell, _ kind: String, _ st: [String: String]) -> App? {
        switch kind {
        case "terminal":
            let t = TerminalApp(shell, st["dir"] ?? "C:/Home"); t.restoreHistory(st["hist"] ?? ""); return t
        case "editor":
            let e = EditorApp(shell, st["path"], st["draft"])
            e.restoreCursor(Int(st["row"] ?? "") ?? 0, Int(st["col"] ?? "") ?? 0); return e
        case "files": return FilesApp(shell, st["dir"] ?? "C:/Home")
        case "doc":
            let d = DocViewerApp(shell, st["path"] ?? "C:/Doc/HelpIndex.DD"); d.restoreTop(Int(st["top"] ?? "") ?? 0); return d
        case "program":
            guard let p = st["path"] else { return nil }
            // A saved native session must never silently execute the interpreter.
            if st["engine"] == "native", let reason = Engines.unavailableReason(shell, p) {
                shell.showToast(tr("engine.unavailable.title", ("engine", Engines.NATIVE_NAME)) + ": " + tr(reason))
                return nil
            }
            let native = st["engine"] == "native" ? Engines.binding(p) : nil
            return ProgramApp(shell, p, shell.catalog.byId(st["id"] ?? "") ?? shell.catalog.byPath(p), nil, native: native)
        case "games": let g = GamesApp(shell); g.restore(st["catalog"] == "true", Int(st["offset"] ?? "") ?? 0,Int(st["selection"] ?? "") ?? -1); return g
        case "programs": let p=ProgramsApp(shell);p.restore(st);return p
        case "god": return GodApp(shell)
        case "paint": return PaintApp(shell, st["path"])
        case "settings": return SettingsApp(shell)
        case "about": return AboutApp(shell)
        case "language": return LanguageApp(shell)
        default: return nil
        }
    }
}
