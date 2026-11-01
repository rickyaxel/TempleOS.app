import Foundation

// Port of ui/GodApp.kt.

/**
 * God Words: a native port of TempleOS Adam/God/HolySpirit.HC. As in TempleOS,
 * random bits come from a FIFO filled by latching a timer when the user acts
 * (timer >> GOD_BAD_BITS, GOD_GOOD_BITS bits per latch); words come from
 * Adam/God/Vocab.DD split as GodInit splits it, and passages from Misc/Bible.TXT with the book
 * table of Adam/God/GodBible.HC. WORD and PASSAGE are TempleOS's F7 and SHIFT-F7
 * (Adam/DolDoc/DocPutKey.HC): flush the FIFO, latch the key's time, GodWord / GodBiblePassage.
 * Adaptations: the latch is the tap's nanosecond timestamp `clock` instead of the time of a
 * keyboard or mouse event; "10 WORDS" is a mobile button (TempleOS has no such command) that
 * makes ten GodWord calls after one latch, and when GodBits runs dry it latches the timer at once
 * where TempleOS's GodPick would pop up an OKAY button and latch the time of that press.
 *
 * The output is a log of what was picked (entry indices, not text), rendered in the current UI
 * language each time it is drawn: a language change shows the same picks in the new language and
 * never draws random bits (docs/localization-vocabulary.md).
 */
public final class GodApp: App {
    public override var kind: String { "god" }
    public override var title: String { tr("app.god.title") }
    private let clock: () -> Int64

    private lazy var vocab: Vocabulary = {
        let d = shell.fs.readFile("C:/Adam/God/Vocab.DD")
        let env = shell.env
        return Vocabulary(d.map { GodVocab.tokenize($0) } ?? [], { env.runtimeFile($0) })
    }()
    private lazy var bible: [String] = {
        guard let d = shell.fs.readFile("C:/Misc/Bible.TXT") else { return [] }
        return textPart(d).scSplit("\n")
    }()
    private lazy var books: [(String, Int)] = {
        guard let data = shell.fs.readFile("C:/Adam/God/GodBible.HC") else { return [] }
        let src = textPart(data) as NSString
        let re = try! NSRegularExpression(pattern: "\"([^\"]*)\"")
        func lst(_ name: String) -> [String] {
            let i = src.range(of: "\"\(name)\"").location
            if i == NSNotFound { return [] }
            let start = i + (name as NSString).length + 2
            let end = src.range(of: ");", options: [], range: NSRange(location: i, length: src.length - i)).location
            if end == NSNotFound || end < start { return [] } // Kotlin would throw here
            let sub = src.substring(with: NSRange(location: start, length: end - start))
            let ns = sub as NSString
            return re.matches(in: sub, range: NSRange(location: 0, length: ns.length)).map { m in
                let g = ns.substring(with: m.range(at: 1))
                return g.hasSuffix("\\0") ? String(g.dropLast(2)) : g
            }
        }
        let names = lst("ST_BIBLE_BOOKS"), lines = lst("ST_BIBLE_BOOK_LINES").compactMap { Int($0) }
        return Array(zip(names, lines))
    }()

    /** One piece of output. Words keep entry indices; everything else is rendered from l10n keys. */
    private enum Out {
        case intro
        case words(Int)  // index into `wordRuns`
        case notice(() -> String, Int)  // text evaluated when drawn, in the language of the moment
        case passage(String, Int, [String])
    }

    private var log: [Out] = [.intro]
    private var wordRuns: [[Int]] = []
    private var fifo: [Int] = []
    private var buttons: [(Rect, () -> Void)] = []
    private var scrollBack = 0
    /** Every entry index picked so far, in order (tests compare picks across languages). */
    private(set) var picks: [Int] = []

    // wrapped lines, rebuilt when the log, the width or the language changes
    private var lines: [(String, Int)] = []
    private var linesKey = ""
    private var logVersion = 0

    public init(_ shell: Shell, clock: @escaping () -> Int64 = monoNanos) {
        self.clock = clock
        super.init(shell)
    }

    public convenience override init(_ shell: Shell) { self.init(shell, clock: monoNanos) }

    /** GodBitsIns(GOD_GOOD_BITS, time >> GOD_BAD_BITS): the timer's bits, least significant first. */
    private func latch() {
        let n = ushr(clock(), Int64(GodApp.GOD_BAD_BITS))
        for i in 0..<GodApp.GOD_GOOD_BITS { fifo.append(Int(ushr(n, Int64(i)) & 1)) }
    }

    /** GodBits: takes num_bits bits from the FIFO, latching the timer whenever it runs dry (GodPick). */
    private func godBits(_ num: Int) -> Int64 {
        var res: Int64 = 0
        var n = num
        while n > 0 {
            if !fifo.isEmpty { res = (res &<< 1) &+ Int64(fifo.removeFirst()); n -= 1 } else { latch() }
        }
        return res
    }

    /** The F7 key: FifoU8Flush(god.fifo); GodBitsIns(GOD_GOOD_BITS, KbdMsEvtTime >> GOD_BAD_BITS). */
    private func press() { fifo.removeAll(); latch() }

    private func add(_ o: Out) { log.append(o); logVersion += 1 }

    /** GodWord: god.words[GodBits(17) % god.num_words]. */
    private func word() {
        if vocab.size == 0 { return }
        let id = Int(godBits(17) % Int64(vocab.size))
        picks.append(id)
        if case .words(let k)? = log.last { wordRuns[k].append(id) }
        else { wordRuns.append([id]); log.append(.words(wordRuns.count - 1)) }
        logVersion += 1
    }

    /** GodBiblePassage: GodBits(21) % (ST_BIBLE_LINES - (num_lines - 1)) + 1. */
    private func passage(_ num: Int = 20) {
        if bible.count < num + 2 { add(.notice({ tr("god.bible_missing") }, Palette.RED)); return }
        let total = Int64((books.last?.1 ?? bible.count) - 1)
        let start = Int(godBits(21) % (total - Int64(num - 1)) + 1)
        let book = books.last { $0.1 <= start }
        let end = min(bible.count, start + num)
        add(.passage(book?.0 ?? "Bible", start, start < end ? (start..<end).map { Cp437.decode(bible[$0]) } : []))
    }

    /** WORD: F7, one GodWord. */
    func wordButton() { press(); word(); invalidate() }

    /** 10 WORDS (mobile): one latch, then ten GodWord calls. */
    func tenWordsButton() { press(); for _ in 0..<10 { word() }; invalidate() }

    /** PASSAGE: SHIFT-F7, one GodBiblePassage. */
    func passageButton() { press(); passage(); invalidate() }

    func clear() { log.removeAll(); wordRuns.removeAll(); logVersion += 1; scrollBack = 0 }

    /** The output as paragraphs (text, color) in the current language. */
    private func paragraphs() -> [(String, Int)] {
        var out: [(String, Int)] = []
        for o in log {
            switch o {
            case .intro:
                out.append(("\(tr("god.intro.title")) - \(tr("god.intro.oracle")) (Adam/God/HolySpirit.HC).", Palette.PURPLE))
                out.append((tr("god.intro.entropy"), Palette.BLUE))
                out.append(("", Palette.BLUE))
            case .words(let k):
                out.append((wordRuns[k].map { vocab.display($0) }.joined(separator: " "), Palette.BLUE))
            case .notice(let text, let color):
                out.append((text(), color))
            case .passage(let book, let start, let text):
                out.append(("", Palette.BLUE))
                out.append((tr("god.passage.header", ("book", book), ("line", start)), Palette.PURPLE))
                out.append(("", Palette.BLUE))
                for l in text { out.append((l, Palette.BLUE)) }
                out.append(("", Palette.BLUE))
            }
        }
        return out
    }

    /** The output as the reader sees it (copy, accessibility, tests). */
    func text() -> String {
        var t = paragraphs().map { $0.0 }.joined(separator: "\n")
        while let c = t.last, c.isWhitespace { t.removeLast() }
        return t
    }

    private func layout(_ s: Surface, _ w: Int) {
        let key = "\(L10n.version)/\(w)/\(logVersion)"
        if key == linesKey { return }
        linesKey = key
        var out: [(String, Int)] = []
        let space = s.measureUi(" ")
        for (p, color) in paragraphs() {
            if p.isEmpty { out.append(("", color)); continue }
            // words are measured one by one (a long log stays cheap to wrap); each piece wider than the line breaks by characters
            var line = "", lw = 0
            for word in p.components(separatedBy: " ") {
                let ww = s.measureUi(word)
                if !line.isEmpty && lw + space + ww <= w { line += " " + word; lw += space + ww; continue }
                if !line.isEmpty { out.append((line, color)); line = ""; lw = 0 }
                if ww <= w { line = word; lw = ww; continue }
                let parts = s.wrapUi(word, w)
                for piece in parts.dropLast() { out.append((piece, color)) }
                line = parts.last ?? ""; lw = s.measureUi(line)
            }
            out.append((line, color))
        }
        lines = out
    }

    public override func draw(_ s: Surface, _ r: Rect) {
        buttons.removeAll()
        let bh = Touch.chromeBtn
        let labels: [(String, () -> Void)] = [(tr("god.button.word"), { [self] in wordButton() }), (tr("god.button.ten_words"), { [self] in tenWordsButton() }),
            (tr("god.button.passage"), { [self] in passageButton() }), (tr("god.button.clear"), { [self] in clear() })]
        let bw = r.w / labels.count
        for (i, p) in labels.enumerated() {
            let br = Rect(r.x + i * bw + 2, r.y + 2, bw - 4, bh - 4)
            s.templeButton(br, p.0, i == 2 ? ButtonFace.ACTION : ButtonFace.NORMAL)
            buttons.append((br, p.1))
            a11yButton(br, p.0)
        }
        let body = Rect(r.x, r.y + bh, r.w, r.h - bh)
        s.fill(body, Palette.WHITE)
        layout(s, body.w - 12)
        let rows = max(1, (body.h - 4) / GodApp.ROW)
        scrollBack = min(max(0, scrollBack), max(0, lines.count - rows))
        let first = max(0, lines.count - rows - scrollBack)
        let last = min(lines.count, first + rows)
        let rtl = L10n.rtl
        var y = body.y + 2
        if first < last {
            for i in first..<last {
                let (t, c) = lines[i]
                _ = s.uiText(body.x + 6, y, t, c, body.w - 12, alignEnd: rtl)
                y += GodApp.ROW
            }
        }
        a11yText(body, (first < last ? lines[first..<last].map { $0.0 } : []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        if lines.count > rows {
            let h = body.h * rows / lines.count
            s.fillRect(body.right - 3, body.y + (body.h - h) * first / max(1, lines.count - rows), 3, max(8, h), Palette.BLUE)
        }
    }

    public override func pointer(_ e: PointerEvent, _ r: Rect) -> Bool {
        if e.action != Ptr.DOWN { return false }
        guard let b = buttons.first(where: { $0.0.contains(e.x, e.y) }) else { return false }
        b.1(); scrollBack = 0; invalidate(); return true
    }

    public override func scroll(_ dx: Int, _ dy: Int, _ r: Rect) { scrollBack = max(0, scrollBack + dy / GodApp.ROW); invalidate() }

    public override func menu() -> [MenuItem] {
        [
            MenuItem(tr("god.menu.copy_text")) { [self] in shell.env.clipboardSet(text()); shell.showToast(tr("toast.copied")) },
            MenuItem(tr("god.menu.instructions")) { [self] in Launch.doc(shell, "C:/Adam/God/HSNotes.DD") },
        ]
    }

    public static let GOD_BAD_BITS = 4
    public static let GOD_GOOD_BITS = 24
    private static let ROW = 10
}
