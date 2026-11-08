package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import java.io.File
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*

class LocalizationRegressionTest {
    private lateinit var directory: File
    private lateinit var shell: Shell

    @Before fun setup() {
        directory = kotlin.io.path.createTempDirectory("tos-l10n-regression").toFile()
        shell = Shell(HeadlessEnv(directory)); shell.resize(320, 480)
        L10n.use("en-US")
    }

    @After fun cleanup() {
        shell.windows.forEach { it.app.close() }
        L10n.use("en-US"); Touch.large = false
        directory.deleteRecursively()
    }

    @Test fun everyAppOwnedCatalogNoteAndHeadingHasALocalizedPresentation() {
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            for (program in shell.catalog.programs.filter { it.note.isNotEmpty() }) {
                assertNotNull("${locale.id}: ${program.id}", program.noteLocalizationKey)
                program.noteLocalizationKey?.let { assertTrue(it, L10n.has(it)) }
                if (program.note.startsWith("compile error: ")) assertTrue(program.localizedNote.contains(program.note.drop(15)))
            }
            for (group in shell.catalog.groups) {
                if (listOf("dir.", "help.", "index.").any { group.id.startsWith(it) }) assertEquals(group.title, group.localizedTitle)
                else {
                    assertTrue(group.id, L10n.has("catalog.group.${group.id}"))
                    assertEquals(tr("catalog.group.${group.id}"), group.localizedTitle)
                }
            }
        }
    }

    @Test fun openPresentationsRefreshWithoutDiscardingInputOrCallbacks() {
        val item = MenuItem({ tr("menu.save") }) {}
        val menu = PopupMenu(listOf(item), 4, 20, { tr("app.settings.title") })
        var result: String? = null
        val dialog = Dialog.input({ tr("editor.dialog.save_as") }, "caf\u0082.HC") { result = it }
        dialog.key(65, 0, shell)
        L10n.use("ja-JP")
        assertEquals(tr("menu.save"), item.label)
        assertEquals(tr("app.settings.title"), menu.title)
        assertEquals(tr("editor.dialog.save_as"), dialog.title)
        assertEquals(tr("button.cancel"), dialog.items[1].first)
        assertNull(result)
        dialog.key(10, 0, shell)
        assertEquals("caf\u0082.HCA", result)
        shell.open(FilesApp(shell, "C:/Home"))
        shell.showToast { tr("input.unsupported") }
        L10n.use("ar"); shell.invalidate(); shell.tick()
        assertTrue(shell.accessibilityNodes().any { it.label == tr("input.unsupported") })
    }

    @Test fun narrowLocalizedToolbarsKeepAllActionsInsideTheWindow() {
        for (editor in listOf(false, true)) {
            val app: App = if (editor) EditorApp(shell, null) else FilesApp(shell, "C:/Home")
            shell.open(app); shell.resize(240, 480)
            for (locale in L10n.resolver!!.locales) {
                L10n.use(locale.id); shell.invalidate(); shell.tick()
                val rect = shell.clientRect(shell.focused!!)
                val keys = if (editor) listOf("editor.button.run", "editor.button.save", "editor.button.undo", "editor.button.redo")
                           else listOf("files.a11y.up", "files.a11y.new", "files.a11y.new_folder", "files.a11y.home")
                for (key in keys) {
                    val node = shell.accessibilityNodes().firstOrNull { it.label == tr(key) }
                    assertNotNull("${locale.id}: $key", node)
                    if (node != null) assertTrue("${locale.id}: $key", node.rect.x >= rect.x && node.rect.right <= rect.right && node.rect.bottom <= rect.bottom)
                }
            }
            shell.focused?.let { shell.close(it, force = true) }
        }
    }

    @Test fun accentedFilenameDisplayPreservesTheStoredBytePath() {
        val path = "C:/Home/caf\u0082.HC"
        shell.fs.writeFile(path, "\"OK\\n\";".toByteArray())
        shell.open(FilesApp(shell, "C:/Home")); shell.tick()
        assertTrue(shell.accessibilityNodes().any { it.label.contains("café.HC") })
        val editor = EditorApp(shell, path); shell.open(editor); shell.tick()
        assertEquals("café.HC", editor.title)
        assertEquals(path, editor.path)
        assertNotNull(shell.fs.readFile(path))
        val error = io.github.templeosmobile.core.kernel.FsError("missing", "fs.error.not_found", mapOf("path" to path))
        assertTrue(error.localized().contains("café.HC"))
    }

    @Test fun filteredLanguageNamesWrapWithoutLosingTheirSelectionTarget() {
        val app = LanguageApp(shell); shell.open(app); shell.resize(240, 480)
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            app.key(io.github.templeosmobile.core.kernel.Keys.CH_ESC, 0, true)
            for (ch in locale.id) app.key(ch.code, 0, true)
            shell.invalidate(); shell.tick()
            val label = LanguageList.current().first { it.id == locale.id }.label
            val rect = shell.clientRect(shell.focused!!)
            val needed = maxOf(ROW_H, shell.surface.wrapUi(label, maxOf(8, rect.w - 20)).size * 12 + 8) - 2
            var node = shell.accessibilityNodes().firstOrNull { it.label == label }
            for (attempt in 0 until 90) {
                if (node != null && node.rect.h >= needed) break
                app.scroll(0, -ROW_H, rect); shell.tick()
                node = shell.accessibilityNodes().firstOrNull { it.label == label }
            }
            assertNotNull(locale.id, node)
            if (node != null) {
                val rect = shell.clientRect(shell.focused!!)
                assertTrue(locale.id, node.rect.x >= rect.x && node.rect.right <= rect.right && node.rect.bottom <= rect.bottom)
                assertTrue(locale.id, node.rect.h >= shell.surface.wrapUi(label, maxOf(8, rect.w - 20)).size * 12 + 6)
            }
        }
    }

    @Test fun fileSizesUseAUnitWithoutEnglishPluralAssumptions() {
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            for (size in listOf(0, 1, 2, 11, 1001)) {
                val label = tr("files.a11y.file_item", "name" to "Test.HC", "size" to size)
                assertTrue("${locale.id}: $label", label.contains("$size B"))
                assertTrue(label.contains("Test.HC"))
            }
        }
    }

    @Test fun draggingWrappedLanguageRowsDoesNotSkipAnyLocale() {
        shell.resize(240, 480)
        for (locale in listOf("en-US", "ru-RU", "ar", "ja-JP", "es-ES")) {
            L10n.use(locale)
            val app = LanguageApp(shell); shell.open(app)
            val labels = (LanguageList.current().map { it.label } + tr("settings.language.automatic")).toSet()
            for (direction in listOf(-1, 1)) {
                val seen = mutableSetOf<String>()
                for (i in 0 until 180) {
                    shell.invalidate(); shell.tick()
                    val visible = shell.accessibilityNodes().filter { it.label in labels }.sortedBy { it.rect.y }
                    seen.addAll(visible.map { it.label })
                    if (seen == labels) break
                    val first = visible.firstOrNull() ?: break
                    val last = visible.last()
                    val distance = maxOf(ROW_H, last.rect.y + last.rect.h / 2 - first.rect.y - first.rect.h / 2)
                    app.scroll(0, direction * distance, shell.clientRect(shell.focused!!))
                }
                assertEquals("$locale, direction $direction: skipped language row", labels, seen)
            }
            shell.focused?.let { shell.close(it, force = true) }
        }
    }

    @Test fun everyLocaleResolvesItsOwnCatalogWithoutHiddenEnglishFallback() {
        val root = File(SHARED, "runtime/l10n")
        for (locale in L10n.resolver!!.locales) {
            val catalog = Json.parse(File(root, "${locale.catalog}.json").readText()) as Map<*, *>
            L10n.use(locale.id)
            assertEquals(locale.id, L10n.locale?.id)
            for ((key, value) in catalog) if (!(key as String).startsWith("$")) {
                val expected = (value as String).replace("{app}", Brand.APP_NAME)
                assertEquals("${locale.id}: $key", expected, tr(key))
            }
        }
    }

    @Test fun argumentsAreLiteralEvenWhenTheyContainAnotherPlaceholder() {
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            val text = tr("engine.unavailable.message", "title" to "C:/Home/{engine}/{reason}.HC",
                "engine" to "Pure Terry", "reason" to "detail {title}")
            assertTrue(locale.id, text.contains("C:/Home/{engine}/{reason}.HC"))
            assertTrue(locale.id, text.contains("detail {title}"))
        }
    }

    @Test fun narrowWrappingKeepsGraphemesIntact() {
        val surface = shell.surface
        surface.measureNative = { it.codePointCount(0, it.length) * 10 }
        for (cluster in listOf("a\u0301", "कि", "ก้", "👩‍💻", "🇯🇵", "😊")) {
            assertEquals(cluster, listOf(cluster, cluster), surface.wrapUi(cluster + cluster, 8))
        }
        assertEquals(listOf("abc", "def", "", "xyz"), surface.wrapUi("abc def\n\nxyz", 24))
    }

    @Test fun inputDialogSpeaksDecodedCp437Characters() {
        val dialog = Dialog.input("File", "caf\u0082.HC") {}
        shell.showDialog(dialog); shell.tick()
        assertTrue(shell.accessibilityNodes().any { it.label == tr("a11y.text_field", "text" to "café.HC") })
    }

    @Test fun settingsCanScrollToLastActionInEveryLocale() {
        val app = SettingsApp(shell); shell.open(app)
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            shell.resize(480, 240); shell.invalidate(); shell.tick()
            val rect = shell.clientRect(shell.focused!!)
            app.scroll(0, -10000, rect); shell.tick()
            val last = shell.accessibilityNodes().firstOrNull { it.label == tr("settings.close_all") }
            assertNotNull(locale.id, last)
            if (last != null) assertTrue("${locale.id}: last Settings action is reachable",
                last.rect.y >= rect.y && last.rect.bottom <= rect.bottom)
        }
    }

    @Test fun longLocalizedDialogStaysWithinItsUsableArea() {
        shell.resize(320, 240)
        for (locale in L10n.resolver!!.locales) {
            L10n.use(locale.id)
            val message = tr("engine.unavailable.message", "title" to "filename".repeat(20),
                "engine" to "Pure Kotlin", "reason" to tr("engine.reason.runtime_compile"))
            val dialog = Dialog.confirm(tr("engine.unavailable.title", "engine" to "Pure Kotlin"), message, tr("button.ok")) {}
            shell.showDialog(dialog); shell.tick()
            val top = shell.insetTop + shell.barH
            val bottom = shell.height - shell.reservedBottom - 12
            assertTrue(dialog.bounds.h > 0)
            assertTrue("${locale.id}: dialog ${dialog.bounds}", dialog.bounds.y >= top && dialog.bounds.bottom <= bottom)
            assertTrue(shell.accessibilityNodes().any { it.label == message })
            assertTrue(shell.accessibilityNodes().any { it.label == tr("button.cancel") })
        }
    }

    /**
     * The game controls' own labels (touch mode, wheel) are translated and fit their buttons, the key caps stay as
     * they are, and every button sends exactly what it sends in English: the same key codes, wheel notches and touch
     * modes, in the same order. The labels never decide what a button does.
     */
    @Test fun gameControlsAreTranslatedWithoutChangingTheirInput() {
        shell.resize(720, 720)
        val info = ProgramInfo("test", "Test", "game", "C:/Test.HC", "interpreted_holyc", "Terry A. Davis", "Public domain (TempleOS)",
            "TempleOS V5.03 ISO", listOf("arrows", "ctrl", "shift", "wheel", "mouse"), listOf("graphics"), "any", "")
        val portrait = Rect(0, 300, 360, 360)
        val landscape = Rect(0, 0, 100, 360) to Rect(544, 0, 96, 360)
        class Result(val events: List<String>, val labels: List<List<String>>, val spoken: List<List<String>>, val rects: List<List<Rect>>, val modes: List<Int>)
        fun press(locale: String, landscapeGutter: Boolean): Result {
            L10n.use(locale)
            val sent = ArrayList<String>()
            val controls = GameControls { e -> if (e is io.github.templeosmobile.core.kernel.KInput.Key) sent.add("key ${e.ch} ${e.sc} ${e.down}") }
            controls.onWheel = { sent.add("wheel $it") }
            val labels = ArrayList<List<String>>(); val spoken = ArrayList<List<String>>(); val rects = ArrayList<List<Rect>>(); val modes = ArrayList<Int>()
            fun layout() {
                if (landscapeGutter) controls.draw(shell.surface, landscape.first, emptyList(), vertical = false, showDpad = true, actionArea = landscape.second, info = info)
                else controls.draw(shell.surface, portrait, emptyList(), vertical = true, showDpad = true, info = info)
                val s = ArrayList<String>(); val r = ArrayList<Rect>()
                controls.accessibility { rect, label, _ -> r.add(rect); s.add(label) }
                labels.add(controls.labels); spoken.add(s); rects.add(r); modes.add(controls.clickMode)
            }
            layout()
            val events = ArrayList<String>()
            // every button once, then the touch-mode toggle until it is back where it started
            for (i in rects[0].indices + List(2) { rects[0].lastIndex }) {
                val r = rects.last()[i]
                controls.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id = 1))
                controls.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id = 1))
                events.add("$i: $sent mode ${controls.clickMode}"); sent.clear()
                layout()
            }
            return Result(events, labels, spoken, rects, modes)
        }
        val modeKeys = listOf("left_click", "right_click", "hover")
        for (gutter in listOf(false, true)) {
            val english = press("en-US", gutter)
            val keyCaps = english.labels[0].dropLast(3) // arrows, SPACE ENTER ESC, CTRL SHIFT
            assertEquals(listOf("\u0018", "\u001B", "\u001A", "\u0019", "SPACE", "ENTER", "ESC", "CTRL", "SHIFT"), keyCaps)
            assertEquals("the toggle cycles through all three modes", listOf(1, 2, 0), english.modes.takeLast(3))
            for (locale in L10n.resolver!!.locales) {
                val result = press(locale.id, gutter)
                L10n.use(locale.id)
                assertEquals("${locale.id}: input", english.events, result.events)
                for ((step, labels) in result.labels.withIndex()) {
                    val mode = modeKeys[result.modes[step]]
                    assertEquals("${locale.id}: key caps", keyCaps, labels.dropLast(3))
                    assertEquals(listOf(tr("controls.button.wheel_up"), tr("controls.button.wheel_down"), tr("controls.button.$mode")), labels.takeLast(3))
                    assertEquals(listOf(tr("controls.a11y.wheel_up"), tr("controls.a11y.wheel_down"), tr("controls.a11y.$mode")), result.spoken[step].takeLast(3))
                    val rects = result.rects[step]
                    assertEquals("${locale.id}: the toggle keeps its place and size while it cycles", result.rects[0].last(), rects.last())
                    val area = if (gutter) landscape.second else portrait
                    for ((i, r) in rects.withIndex()) {
                        if (i >= 4) assertTrue("${locale.id}: ${labels[i]} $r inside $area", r.x >= area.x && r.right <= area.right && r.bottom <= area.bottom)
                        for (o in rects.drop(i + 1)) assertTrue("${locale.id}: $r overlaps $o", r.intersect(o).w <= 0 || r.intersect(o).h <= 0)
                        if (!gutter || Cp437.representable(labels[i]))
                            assertTrue("${locale.id}: \"${labels[i]}\" fits ${r.w}", shell.surface.measureUi(labels[i]) <= r.w - 4)
                    }
                }
            }
        }
    }

    /**
     * Stop is the app's command: the end line is the app's own, while the engine's message stays for the console.
     * The program catches nothing, so Break ends it with the engine's message (a game with its own catch ends normally).
     */
    @Test fun stoppingAProgramEndsWithALocalizedLine() {
        shell.resize(360, 640)
        val source = io.github.templeosmobile.core.holyc.latin1("U0 DrawIt(CTask *,CDC *dc) { dc->color=RED; GrRect(dc,10,10,50,50); }\nFs->draw_it=&DrawIt;\nwhile (TRUE) Sleep(20);\n")
        val app = ProgramApp(shell, "C:/Home/StopTest.HC", null, source)
        shell.open(app, maximized = true)
        val end = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < end && !(app.kernel.graphicsUsed && app.kernel.frameCount >= 5)) { shell.tick(); Thread.sleep(16) }
        assertTrue("the program draws", app.kernel.graphicsUsed)
        L10n.use("es-ES")
        app.stop()
        val stopped = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < stopped && !app.isFinished) { shell.tick(); Thread.sleep(16) }
        assertTrue(app.isFinished)
        shell.invalidate(); shell.tick()
        val labels = shell.accessibilityNodes().map { it.label }
        assertTrue(labels.toString(), tr("program.ended") in labels)
        assertFalse(labels.toString(), labels.any { it.startsWith(tr("program.ended_with", "reason" to "")) })
        val engine = app.kernel.exitMessage
        assertNotNull("the engine's own message is kept", engine)
        assertFalse(labels.toString(), labels.any { it.contains(engine!!.take(40)) })
        assertEquals(io.github.templeosmobile.core.kernel.ExitCategory.STOPPED, app.kernel.exitCategory)
    }

    @Test fun programAuthorsArePeopleOrTheProject() {
        for (locale in listOf("en-US", "es-ES", "ja-JP", "ar")) {
            L10n.use(locale)
            for (p in shell.catalog.programs) {
                assertTrue("${p.id}: ${p.author}", p.author == "Terry A. Davis" || p.author == ProgramInfo.PROJECT_AUTHOR)
                if (p.author == ProgramInfo.PROJECT_AUTHOR) assertEquals(tr("catalog.author.project"), p.localizedAuthor)
                else assertEquals("a person's name is never translated", p.author, p.localizedAuthor)
            }
        }
        L10n.use("es-ES")
        assertTrue(tr("catalog.author.project"), tr("catalog.author.project").contains(Brand.APP_NAME))
    }

    /** The Terminal banner is console text: translated where the TempleOS font can show it, otherwise English. */
    @Test fun terminalBannerNamesTheTerminalInTheUiLanguage() {
        for ((locale, expected) in listOf("it-IT" to "Terminale", "ja-JP" to "Terminal")) {
            L10n.use(locale)
            Launch.terminal(shell)
            val term = shell.focused!!.app as TerminalApp
            val end = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < end && !term.kernel.console.plainText().contains(Brand.APP_NAME)) { shell.tick(); Thread.sleep(20) }
            assertTrue(term.kernel.console.plainText(), term.kernel.console.plainText().contains("${Brand.APP_NAME} $expected - "))
            shell.close(shell.focused!!, force = true)
        }
    }

    @Test fun dialogTextScrollReachesTheEndWithoutActivatingAnAction() {
        shell.resize(320, 240)
        val message = "日本語の説明 ".repeat(80) + "終端"
        var confirmed = false
        val dialog = Dialog.confirm("Dialog", message, tr("button.ok")) { confirmed = true }
        shell.showDialog(dialog); shell.tick()
        val rect = shell.accessibilityNodes().first { it.label == message }.rect
        dialog.pointer(PointerEvent(Ptr.DOWN, rect.x + 8, rect.bottom - 4), shell)
        dialog.pointer(PointerEvent(Ptr.MOVE, rect.x + 8, rect.y + 4), shell)
        assertFalse(dialog.pointer(PointerEvent(Ptr.UP, rect.x + 8, rect.y + 4), shell))
        repeat(80) { dialog.key(0, io.github.templeosmobile.core.kernel.Keys.SC_PAGE_DOWN.toLong(), shell); shell.invalidate(); shell.tick() }
        assertFalse(confirmed)
        assertTrue("last line is reachable", shell.surface.runs.any { it.text.contains("終端") })
        assertTrue(shell.accessibilityNodes().any { it.label == tr("button.cancel") })
    }
}
