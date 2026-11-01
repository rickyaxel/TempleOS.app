package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.purenative.NativePrograms
import io.github.templeosmobile.core.ui.Settings
import io.github.templeosmobile.purekotlin.gen.NativeCatalog
import org.junit.Assert.*
import org.junit.Test

/** The rules behind Settings > Engine: what may run natively, and when the app must say no. */
class EngineSelectionTest {
    @Test
    fun settingRoundTripsAndDefaultsToTerry() {
        assertEquals(Settings.ENGINE_TERRY, Settings.decode("d=8;s=1").engine)
        val st = Settings(engine = Settings.ENGINE_NATIVE)
        assertEquals(Settings.ENGINE_NATIVE, Settings.decode(st.encode()).engine)
        assertEquals(Settings.ENGINE_TERRY, Settings.decode(Settings().encode()).engine)
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
