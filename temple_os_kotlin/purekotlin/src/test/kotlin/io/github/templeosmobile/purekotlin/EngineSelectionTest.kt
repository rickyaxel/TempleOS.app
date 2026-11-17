package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** The rules behind Settings > Engine: what may run natively, and when the app must say no. */
class EngineSelectionTest {
    @Test
    fun settingRoundTripsAndDefaultsToNoChoice() {
        // a fresh install, and a session saved without the setting: no engine chosen (Pure Kotlin where it can run)
        assertEquals(Settings.ENGINE_DEFAULT, Settings().engine)
        assertEquals(Settings.ENGINE_DEFAULT, Settings.decode("d=8;s=1").engine)
        assertEquals(Settings.ENGINE_DEFAULT, Settings.decode(Settings().encode()).engine)
        // a saved choice is kept: sessions saved while Pure Terry was the default say e=0
        assertEquals(Settings.ENGINE_TERRY, Settings.decode("d=8;s=1;e=0").engine)
        assertEquals(Settings.ENGINE_NATIVE, Settings.decode("d=8;s=1;e=1").engine)
        for (e in listOf(Settings.ENGINE_TERRY, Settings.ENGINE_NATIVE)) assertEquals(e, Settings.decode(Settings(engine = e).encode()).engine)
    }

    private class Env(overlay: File) : ShellEnv {
        override val fs = LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), overlay)
        override val stateStore = object : StateStore { var s: String? = null; override fun load() = s; override fun save(text: String) { s = text } }
        override fun runtimeFile(name: String): ByteArray? {
            val f = if (name == "catalog.json") File(SHARED, "program-manifests/catalog.json") else File(SHARED, "runtime/$name")
            return if (f.exists()) f.readBytes() else null
        }
    }

    private fun shell(test: (Shell) -> Unit) {
        NativePrograms.catalog = NativeCatalog
        val dir = kotlin.io.path.createTempDirectory("engine").toFile()
        val sh = Shell(Env(dir)); sh.resize(402, 874); sh.tick()
        try { test(sh) } finally { sh.windows.toList().forEach { sh.close(it, true) }; dir.deleteRecursively() }
    }

    private fun waitFor(sh: Shell, ms: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { sh.tick(); if (cond()) return true; Thread.sleep(20) }
        sh.tick(); return cond()
    }

    /** No engine chosen (a fresh install): a program runs natively where its translation can run, in Pure Terry otherwise, and nothing asks. */
    @Test
    fun defaultRunsTranslationsNativelyAndTheRestInPureTerryWithoutAsking() = shell { sh ->
        assertEquals(Settings.ENGINE_DEFAULT, sh.settings.engine)
        fun launch(path: String): ProgramApp {
            Launch.program(sh, path, null); sh.tick()
            assertFalse(path, sh.dialogOpen)
            return sh.focused!!.app as ProgramApp
        }
        val golf = "C:/Demo/Games/BomberGolf.HC"
        val native = launch(golf)
        assertNotNull(native.native)
        assertTrue("BomberGolf runs", waitFor(sh, 30_000) { native.kernel.frameCount > 10 })
        assertNull(native.kernel.console.plainText(), native.kernel.exitMessage)
        assertEquals(0L, native.kernel.vm.instructionsExecuted)
        sh.close(sh.focused!!, true)
        // the user's own HolyC has no translation
        sh.fs.writeFile("C:/Home/Mine.HC", latin1("\"mine\\n\";\n"))
        val mine = launch("C:/Home/Mine.HC")
        assertNull(mine.native)
        assertTrue("the user's program runs", waitFor(sh, 30_000) { mine.kernel.console.plainText().contains("mine") })
        sh.close(sh.focused!!, true)
        // an edited bundled file no longer matches its translation
        sh.fs.writeFile(golf, sh.fs.readFile(golf)!! + latin1("\n// edited\n"))
        assertNull(launch(golf).native)
    }

    /** A chosen Pure Kotlin is explicit: what it cannot run is offered in Pure Terry, never run there quietly. */
    @Test
    fun chosenPureKotlinAsksBeforeRunningInPureTerry() = shell { sh ->
        sh.settings.engine = Settings.ENGINE_NATIVE
        sh.fs.writeFile("C:/Home/Mine.HC", latin1("\"mine\\n\";\n"))
        Launch.program(sh, "C:/Home/Mine.HC", null); sh.tick()
        assertTrue(sh.dialogOpen)
        assertTrue(sh.windows.none { it.app is ProgramApp })
        sh.key('\n'.code, Keys.forChar('\n'.code).second, true); sh.tick()
        assertFalse(sh.dialogOpen)
        assertNull((sh.focused!!.app as ProgramApp).native)
    }

    /** Settings > Engine shows Pure Kotlin before any choice; a tap chooses Pure Terry, the next one Pure Kotlin. */
    @Test
    fun settingsRowShowsTheDefaultAndChooses() = shell { sh ->
        Launch.settings(sh); sh.tick()
        fun tapRow(name: String) {
            val r = sh.accessibilityNodes().first { it.label == tr("settings.engine", "value" to name) }.rect
            sh.focused!!.app.tap(r.x + r.w / 2, r.y + r.h / 2, r); sh.tick()
        }
        assertTrue(Engines.selectsNative(sh.settings))
        tapRow(Engines.NATIVE_NAME); assertEquals(Settings.ENGINE_TERRY, sh.settings.engine)
        tapRow(Engines.TERRY_NAME); assertEquals(Settings.ENGINE_NATIVE, sh.settings.engine)
        tapRow(Engines.NATIVE_NAME); assertEquals(Settings.ENGINE_TERRY, sh.settings.engine)
    }

    @Test
    fun editedSourceIsNotRunNatively() {
        NativePrograms.catalog = NativeCatalog
        val fs = bundledFs()
        val img = NativePrograms.find("C:/Demo/Games/BomberGolf.HC")!!
        assertNull(NativePrograms.staleReason(img, fs))
        // the user edits the bundled file (copy-on-write in the overlay): the translation no longer matches
        val src = fs.readFile("C:/Demo/Games/BomberGolf.HC")!!
        fs.writeFile("C:/Demo/Games/BomberGolf.HC", src + latin1("\n// edited\n"))
        assertNotNull(NativePrograms.staleReason(img, fs))
    }

    @Test
    fun programsThatCompileAtRunTimeAreMarked() {
        NativePrograms.catalog = NativeCatalog
        // Cartesian compiles the formula the user types with ExePrint: a native kernel evaluates it with the
        // dynamic expression engine (core/dynexpr), so only ExeFile users would need Pure Terry
        assertNotNull(NativePrograms.find("C:/Demo/Graphics/Cartesian.HC"))
        assertNull(NativePrograms.find("C:/Demo/Graphics/Cartesian.HC")?.requiresTerry)
        assertTrue(NativeCatalog.programs.all { it.requiresTerry == null || it.requiresTerry == "runtime_compile" })
        assertNull(NativePrograms.find("C:/Demo/Games/BomberGolf.HC")?.requiresTerry)
        // source completed at run time (DefinePrint from a PopUp answer): one translation per possible answer
        assertEquals(9, NativePrograms.find("C:/Demo/Games/TreeCheckers.HC")?.variants?.size)
    }

    @Test
    fun nativeKernelRefusesToCompile() {
        val (k, _) = bootProgram("C:/Demo/Games/BomberGolf.HC", Engine.NATIVE)
        assertTrue(k.prog.nativeMode)
        try {
            k.prog.compile(io.github.templeosmobile.core.holyc.SourceFile.ofString("C:/x.HC", "I64 x=1;"), "C:/", null, HashMap())
            fail("a native kernel compiled HolyC")
        } catch (e: io.github.templeosmobile.core.holyc.CompileError) { /* expected */ }
        k.terminate("done")
    }
}
