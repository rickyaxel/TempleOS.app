package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.kernel.*

/**
 * God Words: a native port of TempleOS Adam/God/HolySpirit.HC. As in TempleOS,
 * random bits come from a FIFO filled by latching a timer when the user acts
 * (timer >> GOD_BAD_BITS, GOD_GOOD_BITS bits per latch); words come from
 * Adam/God/Vocab.DD split as GodInit splits it, and passages from Misc/Bible.TXT with the book
 * table of Adam/God/GodBible.HC. WORD and PASSAGE are TempleOS's F7 and SHIFT-F7
 * (Adam/DolDoc/DocPutKey.HC): flush the FIFO, latch the key's time, GodWord / GodBiblePassage.
 * Adaptations: the latch is the tap's nanosecond timestamp [clock] instead of the time of a
 * keyboard or mouse event; "10 WORDS" is a mobile button (TempleOS has no such command) that
 * makes ten GodWord calls after one latch, and when GodBits runs dry it latches the timer at once
 * where TempleOS's GodPick would pop up an OKAY button and latch the time of that press.
 *
 * The output is a log of what was picked (entry indices, not text), rendered in the current UI
 * language each time it is drawn: a language change shows the same picks in the new language and
 * never draws random bits (docs/localization-vocabulary.md).
 */
class GodApp(shell: Shell, private val clock: () -> Long = System::nanoTime) : App(shell) {
    override val kind = "god"
    override val title get() = tr("app.god.title")

    private val vocab: Vocabulary by lazy {
        val d = shell.fs.readFile("C:/Adam/God/Vocab.DD")
        Vocabulary(if (d == null) emptyList() else GodVocab.tokenize(d), shell.env::runtimeFile)
    }
    private val bible: List<String> by lazy {
        val d = shell.fs.readFile("C:/Misc/Bible.TXT") ?: return@lazy emptyList()
        textPart(d).split('\n')
    }
    private val books: List<Pair<String, Int>> by lazy {
        val src = shell.fs.readFile("C:/Adam/God/GodBible.HC")?.let { textPart(it) } ?: return@lazy emptyList()
        fun lst(name: String): List<String> {
            val i = src.indexOf("\"$name\""); if (i < 0) return emptyList()
            val end = src.indexOf(");", i)
            return Regex("\"([^\"]*)\"").findAll(src.substring(i + name.length + 2, end)).map { it.groupValues[1].removeSuffix("\\0") }.toList()
        }
        val names = lst("ST_BIBLE_BOOKS"); val lines = lst("ST_BIBLE_BOOK_LINES").mapNotNull { it.toIntOrNull() }
        names.zip(lines)
    }

    /** One piece of output. Words keep entry indices; everything else is rendered from l10n keys. */
    private sealed class Out {
        object Intro : Out()
        class Words : Out() { val ids = ArrayList<Int>() }
        /** [text] is evaluated when drawn, in the language of the moment. */
        class Notice(val text: () -> String, val color: Int) : Out()
        class Passage(val book: String, val start: Int, val text: List<String>) : Out()
    }

    private val log = ArrayList<Out>()
    private val fifo = ArrayDeque<Int>()
    private val buttons = ArrayList<Pair<Rect, () -> Unit>>()
    private var scrollBack = 0
    /** Every entry index picked so far, in order (tests compare picks across languages). */
    internal val picks = ArrayList<Int>()

    // wrapped lines, rebuilt when the log, the width or the language changes
    private var lines: List<Pair<String, Int>> = emptyList()
    private var linesKey = ""
    private var logVersion = 0

    init { log.add(Out.Intro) }

    /** GodBitsIns(GOD_GOOD_BITS, time >> GOD_BAD_BITS): the timer's bits, least significant first. */
    private fun latch() {
        val n = clock() ushr GOD_BAD_BITS
        for (i in 0 until GOD_GOOD_BITS) fifo.addLast(((n ushr i) and 1).toInt())
    }

    /** GodBits: takes num_bits bits from the FIFO, latching the timer whenever it runs dry (GodPick). */
    private fun godBits(num: Int): Long {
        var res = 0L
        var n = num
        while (n > 0) {
            val b = fifo.removeFirstOrNull()
            if (b != null) { res = (res shl 1) + b; n-- } else latch()
        }
        return res
    }

    /** The F7 key: FifoU8Flush(god.fifo); GodBitsIns(GOD_GOOD_BITS, KbdMsEvtTime >> GOD_BAD_BITS). */
    private fun press() { fifo.clear(); latch() }

    private fun add(o: Out) { log.add(o); logVersion++ }

    /** GodWord: god.words[GodBits(17) % god.num_words]. */
    private fun word() {
        if (vocab.size == 0) return
        val id = (godBits(17) % vocab.size).toInt()
        picks.add(id)
        val w = log.lastOrNull() as? Out.Words ?: Out.Words().also { log.add(it) }
        w.ids.add(id); logVersion++
    }

    /** GodBiblePassage: GodBits(21) % (ST_BIBLE_LINES - (num_lines - 1)) + 1. */
    private fun passage(num: Int = 20) {
        if (bible.size < num + 2) { add(Out.Notice({ tr("god.bible_missing") }, Palette.RED)); return }
        val total = (books.lastOrNull()?.second ?: bible.size) - 1
        val start = (godBits(21) % (total - (num - 1)) + 1).toInt()
        val book = books.lastOrNull { it.second <= start }
        add(Out.Passage(book?.first ?: "Bible", start, (start until minOf(bible.size, start + num)).map { Cp437.decode(bible[it]) }))
    }

    /** WORD: F7, one GodWord. */
    internal fun wordButton() { press(); word(); invalidate() }

    /** 10 WORDS (mobile): one latch, then ten GodWord calls. */
    internal fun tenWordsButton() { press(); repeat(10) { word() }; invalidate() }

    /** PASSAGE: SHIFT-F7, one GodBiblePassage. */
    internal fun passageButton() { press(); passage(); invalidate() }

    internal fun clear() { log.clear(); logVersion++; scrollBack = 0 }

    /** The output as paragraphs (text, color) in the current language. */
    private fun paragraphs(): List<Pair<String, Int>> {
        val out = ArrayList<Pair<String, Int>>()
        for (o in log) when (o) {
            is Out.Intro -> {
                out.add("${tr("god.intro.title")} - ${tr("god.intro.oracle")} (Adam/God/HolySpirit.HC)." to Palette.PURPLE)
                out.add(tr("god.intro.entropy") to Palette.BLUE)
                out.add("" to Palette.BLUE)
            }
            is Out.Words -> out.add(o.ids.joinToString(" ") { vocab.display(it) } to Palette.BLUE)
            is Out.Notice -> out.add(o.text() to o.color)
            is Out.Passage -> {
                out.add("" to Palette.BLUE)
                out.add(tr("god.passage.header", "book" to o.book, "line" to o.start) to Palette.PURPLE)
                out.add("" to Palette.BLUE)
                for (l in o.text) out.add(l to Palette.BLUE)
                out.add("" to Palette.BLUE)
            }
        }
        return out
    }

    /** The output as the reader sees it (copy, accessibility, tests). */
    internal fun text() = paragraphs().joinToString("\n") { it.first }.trimEnd()

    private fun layout(s: Surface, w: Int) {
        val key = "${L10n.version}/$w/$logVersion"
        if (key == linesKey) return
        linesKey = key
        val out = ArrayList<Pair<String, Int>>()
        for ((p, color) in paragraphs()) {
            if (p.isEmpty()) { out.add("" to color); continue }
            // words are measured one by one (a long log stays cheap to wrap); each piece wider than the line breaks by characters
            var line = StringBuilder(); var lw = 0
            val space = s.measureUi(" ")
            for (word in p.split(' ')) {
                val ww = s.measureUi(word)
                if (line.isNotEmpty() && lw + space + ww <= w) { line.append(' ').append(word); lw += space + ww; continue }
                if (line.isNotEmpty()) { out.add(line.toString() to color); line = StringBuilder(); lw = 0 }
                if (ww <= w) { line.append(word); lw = ww; continue }
                val parts = s.wrapUi(word, w)
                for (piece in parts.dropLast(1)) out.add(piece to color)
                line.append(parts.last()); lw = s.measureUi(parts.last())
            }
            out.add(line.toString() to color)
        }
        lines = out
    }

    override fun draw(s: Surface, r: Rect) {
        buttons.clear()
        val bh = Touch.chromeBtn
        val labels = listOf<Pair<String, () -> Unit>>(tr("god.button.word") to { wordButton() }, tr("god.button.ten_words") to { tenWordsButton() },
            tr("god.button.passage") to { passageButton() }, tr("god.button.clear") to { clear() })
        val bw = r.w / labels.size
        for ((i, p) in labels.withIndex()) {
            val br = Rect(r.x + i * bw + 2, r.y + 2, bw - 4, bh - 4)
            s.templeButton(br, p.first, if (i == 2) ButtonFace.ACTION else ButtonFace.NORMAL)
            buttons.add(br to p.second)
            a11yButton(br, p.first)
        }
        val body = Rect(r.x, r.y + bh, r.w, r.h - bh)
        s.fill(body, Palette.WHITE)
        layout(s, body.w - 12)
        val rows = maxOf(1, (body.h - 4) / ROW)
        scrollBack = scrollBack.coerceIn(0, maxOf(0, lines.size - rows))
        val first = maxOf(0, lines.size - rows - scrollBack)
        val rtl = L10n.rtl
        var y = body.y + 2
        for (i in first until minOf(lines.size, first + rows)) {
            val (t, c) = lines[i]
            s.uiText(body.x + 6, y, t, c, body.w - 12, alignEnd = rtl)
            y += ROW
        }
        a11yText(body, lines.subList(first, minOf(lines.size, first + rows)).joinToString("\n") { it.first }.trim())
        if (lines.size > rows) {
            val h = body.h * rows / lines.size
            s.fillRect(body.right - 3, body.y + (body.h - h) * first / maxOf(1, lines.size - rows), 3, maxOf(8, h), Palette.BLUE)
        }
    }

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        if (e.action != Ptr.DOWN) return false
        val b = buttons.firstOrNull { it.first.contains(e.x, e.y) } ?: return false
        b.second(); scrollBack = 0; invalidate(); return true
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) { scrollBack = maxOf(0, scrollBack + dy / ROW); invalidate() }

    override fun menu() = listOf(
        MenuItem( { tr("god.menu.copy_text") }) { shell.env.clipboardSet(text()); shell.showToast( { tr("toast.copied") }) },
        MenuItem( { tr("god.menu.instructions") }) { Launch.doc(shell, "C:/Adam/God/HSNotes.DD") },
    )

    companion object { const val GOD_BAD_BITS = 4; const val GOD_GOOD_BITS = 24; private const val ROW = 10 }
}
