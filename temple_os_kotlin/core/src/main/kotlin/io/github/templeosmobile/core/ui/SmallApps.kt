package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.Brand
import io.github.templeosmobile.core.kernel.*

/**
 * Mobile-authored Paint wrapper, not Terry's DolDoc SpriteMainEd/SpriteBitMapEd.
 * This app does not use the execution engine selector. Pictures are saved as uncompressed
 * TempleOS .GR files, compatible with the original Adam/Gr/GrDC.HC
 * DCSave/DCLoad and GRRead format.
 */
class PaintApp(shell: Shell, var path: String? = null) : App(shell), FrameSource {
    override val kind = "paint"
    override val title get() = tr("app.paint.title") + (path?.let { " " + InputCharacterPolicy.display(it.substringAfterLast('/')) } ?: "") + if (modified) "*" else ""
    private var image = GRImage()
    val w get() = image.width
    val h get() = image.height
    var pix = image.pixels
        private set
    private var color = Palette.BLACK
    private var tool = 0 // 0 pen, 1 line, 2 rect, 3 fill, 4 eraser
    private var thick = 1
    private var modified = false
    private var canvas = Rect(0, 0, 0, 0)
    private var startX = -1; private var startY = -1; private var lastX = -1; private var lastY = -1
    private var pointerOwner: Int? = null
    private var strokeBase: ByteArray? = null
    private var strokeModified = false
    private var preview: ByteArray? = null
    private val undo = ArrayList<ByteArray>()
    private val buttons = ArrayList<Pair<Rect, () -> Unit>>()

    /** Bounded diagnostic snapshot, computed from the sole drawing state. */
    internal val replayState get() = mapOf("tool" to "$tool", "color" to "$color", "thickness" to "$thick",
        "owner" to (pointerOwner?.toString() ?: "none"), "preview" to "${preview != null}")

    init { path?.let { load(it) } }

    private fun load(p: String) {
        try {
            val bytes = shell.fs.readFile(p) ?: throw FsError("Could not read $p", "fs.error.could_not_read", mapOf("path" to p))
            val decoded = GRImage.decodeFile(bytes, p.uppercase().endsWith(".Z"))
            image = decoded; pix = decoded.pixels
        } catch (e: FsError) {
            // Never let Save overwrite an unreadable original with a blank image.
            path = null
            shell.showToast( { if (e.key != null) e.localized() else tr("paint.invalid_picture", "detail" to (e.message ?: "GR")) })
        }
    }

    private fun save(target: String) {
        releaseInput()
        image.pixels = pix
        var output = image.encode()
        // CT_NONE is an original outer TempleOS archive type, separate from DCF_COMPRESSED.
        if (target.uppercase().endsWith(".Z")) output = TempleArc.store(output)
        try {
            shell.fs.writeFile(target, output); path = target; modified = false
            shell.showToast( { tr("toast.saved", "path" to InputCharacterPolicy.display(target)) }); invalidate()
        } catch (e: FsError) { shell.showToast( { e.localized() }) }
    }

    override val frameW get() = w
    override val frameH get() = h
    override var frameVersion = 0L
        private set
    override val palette: IntArray get() {
        val p = image.palette ?: return Palette.STD.copyOf()
        return IntArray(16) { i -> 0xFF000000.toInt() or ((p[i*8+5].toInt() and 255) shl 16) or
            ((p[i*8+3].toInt() and 255) shl 8) or (p[i*8+1].toInt() and 255) }
    }
    override fun copyFrame(dst: ByteArray): Long { (preview ?: pix).copyInto(dst); return frameVersion }
    override fun overlays(r: Rect) = if (canvas.w > 0 && canvas.h > 0) listOf(Overlay(canvas, this)) else emptyList()

    override fun draw(s: Surface, r: Rect) {
        s.fill(r, Palette.LTGRAY)
        buttons.clear()
        // Keep all indices reachable on narrow screens.
        for (c in 0 until 16) {
            val x0 = r.x + c * r.w / 16; val x1 = r.x + (c + 1) * r.w / 16
            val br = Rect(x0, r.y, x1 - x0, Touch.toolRow)
            s.fill(br, c); if (c == color) s.frame(br, if (c == Palette.YELLOW) Palette.BLACK else Palette.YELLOW)
            a11yButton(br, tr("paint.a11y.color", "color" to colorName(c)), c == color)
            buttons.add(br to { color = c; invalidate() })
        }
        val tools = listOf(tr("paint.tool.pen"), tr("paint.tool.line"), tr("paint.tool.rect"), tr("paint.tool.fill"), tr("paint.tool.erase"))
        var bx = r.x; var by = r.y + Touch.toolRow + 2
        for (i in 0..tools.size) {
            val t = if (i < tools.size) tools[i] else "─$thick"
            val bw = minOf(maxOf(1, r.w), maxOf(40, s.measureUi(t) + 8))
            if (bx > r.x && bx + bw > r.right) { bx = r.x; by += Touch.toolRow + 2 }
            val br = Rect(bx, by, bw, Touch.toolRow)
            s.withClip(br) { s.templeButton(br, t, if (i < tools.size && tool == i) ButtonFace.SELECTED else ButtonFace.NORMAL) }
            if (i < tools.size) {
                a11yButton(br, tr("paint.a11y.tool", "tool" to t), tool == i)
                buttons.add(br to { tool = i; invalidate() })
            } else {
                a11yButton(br, tr("paint.a11y.thickness", "n" to thick))
                buttons.add(br to { thick = if (thick >= 8) 1 else thick * 2; invalidate() })
            }
            bx += bw + 2
        }
        val top = by + Touch.toolRow + 2
        val area = Rect(r.x, top, maxOf(0, r.w), maxOf(0, r.bottom - top))
        var cw = area.w; var ch = cw * h / w
        if (ch > area.h) { ch = area.h; cw = ch * w / h }
        val nextCanvas = Rect(area.x + (area.w - cw) / 2, area.y + (area.h - ch) / 2, cw, ch)
        if (canvas.x != nextCanvas.x || canvas.y != nextCanvas.y || canvas.w != cw || canvas.h != ch) releaseInput()
        canvas = nextCanvas
        frameVersion++
        s.blitScaled(preview ?: pix, w, h, canvas)
        s.frame(Rect(canvas.x - 1, canvas.y - 1, canvas.w + 2, canvas.h + 2), Palette.BLACK)
        a11yText(canvas, tr("program.a11y.picture", "title" to tr("app.paint.title")))
    }

    private fun toImg(x: Int, y: Int): Pair<Int, Int> {
        // Clamp captured events before multiplying coordinates.
        val cx = minOf(canvas.right - 1, maxOf(canvas.x, x))
        val cy = minOf(canvas.bottom - 1, maxOf(canvas.y, y))
        return ((cx - canvas.x) * w / maxOf(1, canvas.w)) to ((cy - canvas.y) * h / maxOf(1, canvas.h))
    }

    private fun dot(img: ByteArray, x: Int, y: Int, c: Int) {
        val r = thick / 2
        for (dy in -r..r) for (dx in -r..r) {
            val xx = x + dx; val yy = y + dy
            if (xx in 0 until w && yy in 0 until h && (thick < 3 || dx * dx + dy * dy <= r * r + 1)) img[yy * w + xx] = c.toByte()
        }
    }

    private fun line(img: ByteArray, x0: Int, y0: Int, x1: Int, y1: Int, c: Int) {
        val n = maxOf(Math.abs(x1 - x0), Math.abs(y1 - y0), 1)
        for (i in 0..n) dot(img, x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, c)
    }

    private fun flood(x: Int, y: Int, c: Int) {
        if (x !in 0 until w || y !in 0 until h) return
        val target = pix[y * w + x]; val nc = c.toByte()
        if (target == nc) return
        val stack = ArrayDeque<Int>(); stack.add(y * w + x)
        while (stack.isNotEmpty()) {
            val p = stack.removeLast()
            if (pix[p] != target) continue
            pix[p] = nc
            val px = p % w; val py = p / w
            if (px > 0) stack.add(p - 1); if (px < w - 1) stack.add(p + 1)
            if (py > 0) stack.add(p - w); if (py < h - 1) stack.add(p + w)
        }
    }

    override fun releaseInput() {
        // Keep completed freehand segments; discard uncommitted shape previews.
        strokeBase?.let { if (!pix.contentEquals(it)) remember(it) }
        pointerOwner = null; startX = -1; preview = null; strokeBase = null
        invalidate()
    }
    override fun close() = releaseInput()
    override fun onBackground() = releaseInput()

    override fun pointer(e: PointerEvent, r: Rect): Boolean {
        if (e.action == Ptr.CANCEL) {
            if (pointerOwner != e.id) return false
            releaseInput(); return true
        }
        if (e.action == Ptr.DOWN) {
            if (pointerOwner != null) return true
            buttons.firstOrNull { it.first.contains(e.x, e.y) }?.let { it.second(); return true }
            if (!canvas.contains(e.x, e.y)) return false
            pointerOwner = e.id; strokeBase = pix.copyOf(); strokeModified = modified
            val (x, y) = toImg(e.x, e.y)
            startX = x; startY = y; lastX = x; lastY = y
            val c = if (tool == 4) Palette.WHITE else color
            when (tool) { 0, 4 -> dot(pix, x, y, c); 3 -> flood(x, y, color) }
            if (!pix.contentEquals(strokeBase!!)) modified = true
            invalidate(); return true
        }
        if (pointerOwner != e.id || startX < 0) return false
        val (x, y) = toImg(e.x, e.y)
        val c = if (tool == 4) Palette.WHITE else color
        when (tool) {
            0, 4 -> { line(pix, lastX, lastY, x, y, c); lastX = x; lastY = y }
            1, 2 -> {
                val p = pix.copyOf()
                if (tool == 1) line(p, startX, startY, x, y, color)
                else { line(p, startX, startY, x, startY, color); line(p, x, startY, x, y, color); line(p, x, y, startX, y, color); line(p, startX, y, startX, startY, color) }
                if (e.action == Ptr.MOVE) preview = p else if (e.action == Ptr.UP) { pix = p; preview = null }
            }
        }
        strokeBase?.let { if (!pix.contentEquals(it)) modified = true }
        if (e.action == Ptr.UP) finishStroke()
        invalidate(); return true
    }
    private fun finishStroke() {
        strokeBase?.let { if (!pix.contentEquals(it)) remember(it) else modified = strokeModified }
        pointerOwner = null; startX = -1; preview = null; strokeBase = null
    }
    private fun remember(pixels: ByteArray) {
        // Bound undo by bytes as well as count for larger loaded resources.
        while (undo.isNotEmpty() && (undo.size >= 20 || undo.size.toLong() * pixels.size >= 16 * 1024 * 1024)) undo.removeAt(0)
        undo.add(pixels)
    }

    override fun menu() = listOf(
        MenuItem( { tr("editor.menu.open_file") }) {
            shell.showDialog(Dialog.input( { tr("editor.menu.open_file") }, "C:/Home/Picture.GR") { p ->
                val n = p?.let { Paths.normalize("C:/Home", it) }
                if (n != null) Launch.paint(shell, n)
            })
        },
        MenuItem( { tr("menu.save") }) { path?.let { save(it) } ?: saveAs() },
        MenuItem( { tr("menu.save_as") }) { saveAs() },
        MenuItem( { tr("menu.undo") }) { releaseInput(); undo.removeLastOrNull()?.let { pix = it; modified = true; invalidate() } },
        MenuItem( { tr("paint.menu.clear") }) { releaseInput(); remember(pix.copyOf()); java.util.Arrays.fill(pix, Palette.WHITE.toByte()); modified = true; invalidate() },
    )

    private fun saveAs() = shell.showDialog(Dialog.input( { tr("paint.dialog.save_as") }, path ?: "C:/Home/Picture.GR") { p ->
        if (p == null) return@input
        val n = Paths.normalize("C:/Home", p) ?: return@input
        save(if (Paths.name(n).contains('.')) n else "$n.GR")
    })

    override val unsaved get() = modified
    override fun saveState() = path?.let { mapOf("path" to it) } ?: emptyMap()
}

/** The localized name of a TempleOS palette color. */
fun colorName(c: Int) = tr("color." + (Console.COLOR_NAMES.entries.firstOrNull { it.value == c }?.key ?: "BLACK").lowercase())

/** Settings: sound, desktop color, display scale, touch size, keyboard, language, storage. */
class SettingsApp(shell: Shell) : App(shell) {
    override val kind = "settings"
    override val title get() = tr("app.settings.title")
    private val rows = ArrayList<Pair<Rect, () -> Unit>>()
    private var offset = 0
    private var contentHeight = 0

    private fun onOff(b: Boolean) = tr(if (b) "value.on" else "value.off")

    override fun draw(s: Surface, r: Rect) {
        s.fill(r, Palette.WHITE)
        rows.clear()
        val st = shell.settings
        val rtl = L10n.rtl
        val lang = if (st.language.isEmpty()) tr("settings.language.automatic_now", "language" to (shell.uiLocale?.nativeName ?: "English"))
            else shell.uiLocale?.nativeName ?: st.language
        val items = listOf<Pair<String, () -> Unit>>(
            tr("settings.language", "value" to lang) to { Launch.language(shell) },
            tr("settings.sound", "value" to onOff(st.sound)) to { st.sound = !st.sound; if (!st.sound) shell.env.tone(0.0) },
            tr("settings.desktop_color", "value" to colorName(st.desktopColor)) to { st.desktopColor = (st.desktopColor + 1) % 16 },
            tr("settings.display_scale", "value" to (if (st.uiScale == 0) tr("value.auto") else "${st.uiScale}x")) to { st.uiScale = (st.uiScale + 1) % 6 },
            tr("settings.crisp_scaling", "value" to onOff(st.crispScaling)) to { st.crispScaling = !st.crispScaling },
            tr("settings.touch_targets", "value" to tr(if (st.largeTouch) "value.large" else "value.standard")) to { st.largeTouch = !st.largeTouch; Touch.large = st.largeTouch; shell.relayout() },
            tr("settings.engine", "value" to if (st.engine == Settings.ENGINE_NATIVE) Engines.NATIVE_NAME else Engines.TERRY_NAME) to {
                if (Engines.nativeAvailable) st.engine = if (st.engine == Settings.ENGINE_NATIVE) Settings.ENGINE_TERRY else Settings.ENGINE_NATIVE },
            tr("settings.storage", "used" to shell.fs.usedBytes() / 1024, "total" to (shell.fs.quota shr 20)) to {},
            tr("settings.close_all") to { shell.windows.toList().forEach { w -> if (w.app !== this) shell.close(w) } },
        )
        var y = r.y + 4 - offset
        s.withClip(r) {
            for (item in items) {
                val lines = s.wrapUi(item.first, maxOf(8, r.w - 20))
                val h = maxOf(ROW_H, lines.size * 12 + 8)
                val br = Rect(r.x + 4, y, r.w - 8, h)
                s.fill(br, Palette.LTCYAN)
                for ((i, line) in lines.withIndex())
                    s.uiText(br.x + 6, br.y + (h - lines.size * 12) / 2 + 2 + i * 12,
                        line, Palette.BLUE, br.w - 12, alignEnd = rtl)
                val hit = br.intersect(r)
                if (hit.h >= minOf(16, h)) { a11yButton(hit, item.first); rows.add(hit to item.second) }
                y += h + 4
            }
            y += 4
            for (line in s.wrapUi(tr("settings.display_scale_note") + "\n" + tr("input.cp437_policy"), maxOf(8, r.w - 12))) {
                s.uiText(r.x + 6, y, line, Palette.DKGRAY, r.w - 12, alignEnd = rtl)
                val hit = Rect(r.x, y, r.w, 12).intersect(r)
                if (hit.h >= 10) a11yText(hit, line)
                y += 12
            }
        }
        contentHeight = y + offset - r.y + 4
        val limit = maxOf(0, contentHeight - r.h)
        if (offset > limit) { offset = limit; invalidate() }
        if (limit > 0) {
            val h = maxOf(8, r.h * r.h / contentHeight)
            s.fillRect(r.right - 3, r.y + (r.h - h) * offset / limit, 3, h, Palette.BLUE)
        }
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        offset = (offset - dy).coerceIn(0, maxOf(0, contentHeight - r.h)); invalidate()
    }

    override fun tap(x: Int, y: Int, r: Rect) {
        rows.firstOrNull { it.first.contains(x, y) }?.second?.invoke()
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
class LanguageApp(shell: Shell) : App(shell) {
    override val kind = "language"
    override val title get() = tr("app.language.title")
    override val wantsKeyboard get() = true
    private val filter = StringBuilder()
    private var scroll = 0
    private var scrollAcc = 0
    private val rows = ArrayList<Pair<Rect, String>>()

    private fun entries(): List<Pair<String, String>> { // (locale id or "", label)
        val q = filter.toString().trim().lowercase()
        if (L10n.resolver == null) return emptyList()
        val all = listOf("" to tr("settings.language.automatic")) + LanguageList.current().map { it.id to it.label }
        return if (q.isEmpty()) all else all.filter { (id, label) -> id.isNotEmpty() && (label.lowercase().contains(q) || id.lowercase().startsWith(q)) }
    }

    override fun draw(s: Surface, r: Rect) {
        s.fill(r, Palette.WHITE)
        rows.clear()
        val rtl = L10n.rtl
        // filter field (typed on the keyboard; locale ids and English names are ASCII)
        val fr = Rect(r.x + 4, r.y + 4, r.w - 8, ROW_H)
        s.fill(fr, Palette.LTGRAY)
        val hint = if (filter.isEmpty()) tr("language.filter_hint") else filter.toString()
        val ex = s.uiText(fr.x + 6, fr.y + ROW_TEXT, hint, if (filter.isEmpty()) Palette.DKGRAY else Palette.BLACK, fr.w - 12)
        if (filter.isNotEmpty()) s.fillRect(ex, fr.y + ROW_TEXT - 2, 2, 10, Palette.BLUE)
        a11yText(fr, tr("a11y.text_field", "text" to filter.toString()))
        val list = entries()
        val top = fr.bottom + 4
        scroll = scroll.coerceIn(0, maxOf(0, list.size - 1))
        val current = shell.settings.language
        val viewport = Rect(r.x, top, r.w, maxOf(0, r.bottom - top))
        var y = top
        s.withClip(viewport) {
            for (i in scroll until list.size) {
                if (y >= r.bottom) break
                val (id, label) = list[i]
                val lines = s.wrapUi(label, maxOf(8, r.w - 20))
                val h = maxOf(ROW_H, lines.size * 12 + 8)
                val selected = id == current
                val br = Rect(r.x + 4, y, r.w - 8, h - 2)
                s.fill(br, if (selected) Palette.YELLOW else if ((i - scroll) % 2 == 0) Palette.LTCYAN else Palette.WHITE)
                for ((line, text) in lines.withIndex())
                    s.uiText(br.x + 6, br.y + (br.h - lines.size * 12) / 2 + 2 + line * 12,
                        text, Palette.BLUE, br.w - 12, alignEnd = rtl)
                val hit = br.intersect(viewport)
                if (hit.h >= 16) { rows.add(hit to id); a11yButton(hit, label, selected) }
                y += h
            }
        }
        val visible = rows.size
        if (list.size > visible) {
            val h = maxOf(8, viewport.h * maxOf(1, visible) / list.size)
            s.fillRect(r.right - 3, top + (viewport.h - h) * scroll / maxOf(1, list.size - 1), 3, h, Palette.BLUE)
        }
    }

    override fun tap(x: Int, y: Int, r: Rect) {
        val row = rows.indexOfFirst { it.first.contains(x, y) }.takeIf { it >= 0 } ?: return
        val id = rows[row].second
        shell.settings.language = id
        shell.applyLanguage()
        shell.saveSession()
        // the new UI language collates the list differently: keep the chosen row under the finger
        val at = entries().indexOfFirst { it.first == id }
        if (at >= 0) scroll = maxOf(0, at - row)
        scrollAcc = 0
        invalidate()
    }

    override fun scroll(dx: Int, dy: Int, r: Rect) {
        val list = entries()
        if (list.isEmpty()) { scroll = 0; scrollAcc = 0; return }
        scroll = scroll.coerceIn(0, list.size - 1)
        fun height(i: Int) = maxOf(ROW_H, shell.surface.wrapUi(list[i].second, maxOf(8, r.w - 20)).size * 12 + 8)
        // Wrapped rows have different heights; a fixed divisor can skip an unseen language.
        scrollAcc -= dy
        while (scroll < list.size - 1 && scrollAcc >= height(scroll)) { scrollAcc -= height(scroll); scroll++ }
        while (scroll > 0 && -scrollAcc >= height(scroll - 1)) { scrollAcc += height(scroll - 1); scroll-- }
        if ((scroll == 0 && scrollAcc < 0) || (scroll == list.size - 1 && scrollAcc > 0)) scrollAcc = 0
        invalidate()
    }

    override fun key(ch: Int, sc: Long, down: Boolean): Boolean {
        if (!down) return true
        when {
            ch == io.github.templeosmobile.core.kernel.Keys.CH_BACKSPACE -> if (filter.isNotEmpty()) filter.setLength(filter.length - 1)
            ch == io.github.templeosmobile.core.kernel.Keys.CH_ESC -> filter.setLength(0)
            ch in 0x20..0x7E && filter.length < 24 -> filter.append(ch.toChar())
            else -> return false
        }
        scroll = 0; scrollAcc = 0; invalidate(); return true
    }
}

/**
 * Scrollable localized text: paragraphs wrapped to the window width, drawn with the TempleOS
 * font where it has the characters and with the platform's text engine otherwise.
 */
class TextPage {
    class Para(val text: String, val color: Int, val gapBefore: Int = 0)
    var paras: List<Para> = emptyList()
    private var top = 0

    fun draw(s: Surface, r: Rect, app: App) {
        s.fill(r, Palette.WHITE)
        val rtl = L10n.rtl
        val lines = ArrayList<Pair<String, Int>>()
        for (p in paras) {
            repeat(p.gapBefore) { lines.add("" to p.color) }
            for (l in s.wrapUi(p.text, r.w - 12)) lines.add(l to p.color)
        }
        val rows = maxOf(1, r.h / 10)
        top = top.coerceIn(0, maxOf(0, lines.size - rows))
        var y = r.y + 4
        for (i in top until minOf(lines.size, top + rows)) {
            val (t, c) = lines[i]
            s.uiText(r.x + 6, y, t, c, r.w - 12, alignEnd = rtl)
            y += 10
        }
        app.a11yPage(r, paras.joinToString("\n") { it.text })
        if (lines.size > rows) {
            val h = r.h * rows / lines.size
            s.fillRect(r.right - 3, r.y + (r.h - h) * top / maxOf(1, lines.size - rows), 3, maxOf(8, h), Palette.BLUE)
        }
    }

    fun scrollBy(rows: Int) { top = maxOf(0, top + rows) }
}

/** About & Credits. */
class AboutApp(shell: Shell) : App(shell) {
    override val kind = "about"
    override val title get() = tr("app.about.title")
    private val page = TextPage()
    private var builtFor = -1
    private var privacyButton = Rect(0, 0, 0, 0)

    private fun build() {
        if (builtFor == L10n.version) return
        builtFor = L10n.version
        fun P(text: String, color: Int, gap: Int = 0) = TextPage.Para(text, color, gap)
        page.paras = listOf(
            P(Brand.APP_NAME, Palette.PURPLE),
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
            P(" - " + tr("about.credits.kotlin"), Palette.BLACK),
            P(" - " + tr("about.credits.bible"), Palette.BLACK),
            P(" - " + tr("about.credits.templeos_web"), Palette.BLACK),
            P(" - " + tr("about.credits.native"), Palette.BLACK),
            P(" - " + tr("about.credits.translations"), Palette.BLACK),
            P(tr("about.privacy.title"), Palette.GREEN, 1),
            P(tr("about.privacy.body"), Palette.BLACK),
            P(Brand.PRIVACY_URL, Palette.BLUE),
        )
    }

    override fun draw(s: Surface, r: Rect) {
        build()
        s.fill(r, Palette.WHITE)
        val header = minOf(r.h, ROW_H + 8)
        privacyButton = Rect(r.x + 4, r.y + 4, maxOf(0, r.w - 8), maxOf(0, header - 8))
        s.fill(privacyButton, Palette.LTCYAN)
        s.uiText(privacyButton.x + 6, privacyButton.y + ROW_TEXT, tr("about.privacy.title"), Palette.BLUE,
            maxOf(0, privacyButton.w - 12), alignEnd = L10n.rtl)
        a11yButton(privacyButton, tr("about.privacy.title") + ": " + Brand.PRIVACY_URL)
        page.draw(s, Rect(r.x, r.y + header, r.w, maxOf(0, r.h - header)), this)
    }
    override fun tap(x: Int, y: Int, r: Rect) {
        if (privacyButton.contains(x, y)) shell.env.openPrivacyPolicy()
    }
    override fun scroll(dx: Int, dy: Int, r: Rect) { page.scrollBy(-dy / 10); invalidate() }
}

/** Creates apps and restores them from a saved session. */
object Launch {
    private fun origin(shell: Shell): Int? = shell.focused?.takeIf {it.app.kind in listOf("games","programs","doc") || it.app.navigationParentId != null}?.id
    fun terminal(shell: Shell, dir: String = "C:/Home", command: String? = null) {
        val t = TerminalApp(shell, dir)
        shell.open(t)
        if (command != null) t.kernel.post(KInput.Exec(command))
    }

    fun editor(shell: Shell, path: String?) {
        val parent=origin(shell)
        path?.let { p -> shell.findWindow("editor") { (it as EditorApp).path.equals(p, true) }?.let { if(parent!=it.id)it.app.navigationParentId=parent;shell.focus(it); return } }
        shell.open(EditorApp(shell, path).also {it.navigationParentId=parent})
    }

    fun files(shell: Shell, dir: String) {
        val parent=origin(shell)
        shell.findWindow("files")?.let { if(parent!=it.id)it.app.navigationParentId=parent;(it.app as FilesApp).cd(dir); shell.focus(it); return }
        shell.open(FilesApp(shell, dir).also {it.navigationParentId=parent})
    }

    fun doc(shell: Shell, path: String) {
        val parent=origin(shell)
        shell.findWindow("doc")?.let { if(parent!=it.id)it.app.navigationParentId=parent;(it.app as DocViewerApp).load(path); shell.focus(it); return }
        shell.open(DocViewerApp(shell, path).also {it.navigationParentId=parent})
    }

    fun program(shell: Shell, path: String, info0: ProgramInfo?) {
        val info = info0 ?: shell.catalog.byPath(path)
        if (shell.settings.engine == Settings.ENGINE_NATIVE) {
            val reason = Engines.unavailableReason(shell, path)
            if (reason != null) {
                // never a silent fallback: say why, and let the user run it on the interpreter
                val title = info?.title ?: path.substringAfterLast('/').substringBefore('.')
                shell.showDialog(Dialog.confirm( { tr("engine.unavailable.title", "engine" to Engines.NATIVE_NAME) }, { tr("engine.unavailable.message", "title" to title, "engine" to Engines.NATIVE_NAME, "reason" to tr(reason)) }, { tr("button.run_in", "engine" to Engines.TERRY_NAME) }) { programOn(shell, path, info, null) })
                return
            }
            programOn(shell, path, info, Engines.binding(path))
            return
        }
        programOn(shell, path, info, null)
    }

    private fun programOn(shell: Shell, path: String, info: ProgramInfo?, native: io.github.templeosmobile.core.purenative.NativeBinding?) {
        val parent=origin(shell)
        shell.findWindow("program") {it is ProgramApp && it.path.equals(path,true) && (it.native!=null)==(native!=null)}?.let {if(parent!=it.id)it.app.navigationParentId=parent;shell.focus(it);return}
        val start = { shell.open(ProgramApp(shell, path, info, native = native).also {it.navigationParentId=parent}, maximized = info?.usesGraphics == true) }
        when (info?.status) {
            "unsupported" -> shell.showDialog(Dialog.confirm( { tr("program.unsupported.title", "title" to info.title) }, { tr("program.unsupported.message", "reason" to info.localizedNote) }, { tr("button.run_anyway") }) { start() })
            "partial" -> { start(); shell.showToast( { "${info.title}: ${info.localizedNote}" }) }
            else -> start()
        }
    }

    fun games(shell: Shell) { shell.findWindow("games")?.let { shell.focus(it); return }; shell.open(GamesApp(shell).also {it.navigationParentId=origin(shell)}, maximized = true) }
    fun programs(shell: Shell, group: String = "programs") {
        shell.findWindow("programs")?.let {(it.app as ProgramsApp).showGroup(group);shell.focus(it);return}
        shell.open(ProgramsApp(shell).also {it.navigationParentId=origin(shell);it.showGroup(group)},maximized=true)
    }

    fun god(shell: Shell) { shell.findWindow("god")?.let { shell.focus(it); return }; shell.open(GodApp(shell)) }
    fun paint(shell: Shell, path: String? = null): Shell.Window {
        if (path != null) shell.findWindow("paint") { (it as PaintApp).path?.equals(path, true) == true }?.let {
            shell.focus(it); return it
        }
        return shell.open(PaintApp(shell, path))
    }
    fun settings(shell: Shell) { shell.findWindow("settings")?.let { shell.focus(it); return }; shell.open(SettingsApp(shell)) }
    fun about(shell: Shell) { shell.findWindow("about")?.let { shell.focus(it); return }; shell.open(AboutApp(shell)) }
    fun language(shell: Shell) { shell.findWindow("language")?.let { shell.focus(it); return }; shell.open(LanguageApp(shell)) }

    /** Recreates an app from session state (programs restart from the beginning). */
    fun restore(shell: Shell, kind: String, st: Map<String, String>): App? = when (kind) {
        "terminal" -> TerminalApp(shell, st["dir"] ?: "C:/Home").also { it.restoreHistory(st["hist"] ?: "") }
        "editor" -> EditorApp(shell, st["path"], st["draft"]).also { it.restoreCursor(st["row"]?.toIntOrNull() ?: 0, st["col"]?.toIntOrNull() ?: 0) }
        "files" -> FilesApp(shell, st["dir"] ?: "C:/Home")
        "doc" -> DocViewerApp(shell, st["path"] ?: "C:/Doc/HelpIndex.DD").also { it.restoreTop(st["top"]?.toIntOrNull() ?: 0) }
        "program" -> st["path"]?.let { p ->
            val reason = if (st["engine"] == "native") Engines.unavailableReason(shell, p) else null
            if (reason != null) {
                shell.showToast( { tr("engine.unavailable.title", "engine" to Engines.NATIVE_NAME) + ": " + tr(reason) })
                null
            } else {
                val native = if (st["engine"] == "native") Engines.binding(p) else null
                ProgramApp(shell, p, shell.catalog.byId(st["id"] ?: "") ?: shell.catalog.byPath(p), native = native)
            }
        }
        "games" -> GamesApp(shell).also { it.restore(st["catalog"] == "true", st["offset"]?.toIntOrNull() ?: 0,st["selection"]?.toIntOrNull() ?: -1) }
        "programs" -> ProgramsApp(shell).also {it.restore(st)}
        "god" -> GodApp(shell)
        "paint" -> PaintApp(shell, st["path"])
        "settings" -> SettingsApp(shell)
        "about" -> AboutApp(shell)
        "language" -> LanguageApp(shell)
        else -> null
    }
}
