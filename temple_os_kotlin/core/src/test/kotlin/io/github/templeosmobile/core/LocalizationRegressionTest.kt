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
