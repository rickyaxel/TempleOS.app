package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LayeredFsTest {
    private val bundle = DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index"))
    private fun tmp(): File = Files.createTempDirectory("tosfs").toFile()

    @Test fun pathNormalization() {
        assertEquals("C:/Home/A.HC", Paths.normalize("C:/Home", "A.HC"))
        assertEquals("C:/Demo", Paths.normalize("C:/Home", "::/Demo"))
        assertEquals("C:/", Paths.normalize("C:/Home", "../../../.."))
        assertEquals("C:/etc/passwd", Paths.normalize("C:/Home", "../../etc/passwd"))
        assertNull(Paths.normalize("C:/Home", "D:/x"))
        assertNull(Paths.normalize("C:/Home", "a:b"))
        assertNull(Paths.normalize("C:/Home", "bad\u0000name"))
        assertEquals("C:/Home/x", Paths.normalize("C:/", "~/x"))
    }

    @Test fun bundledFilesCarryTheIsoDate() {
        // V-04: RedSea CDate of Doc/Welcome.DD on the V5.03 ISO = 2017-10-19 04:06:39 (wall clock)
        val fs = LayeredFs(bundle, tmp())
        val e = fs.stat("C:/Doc/Welcome.DD")!!
        assertEquals(1508385999999L, e.modified)
        assertEquals("10/19 04:06", FsCommands.dirDate(e))
        assertEquals(e.modified, fs.list("C:/Doc")!!.first { it.name == "Welcome.DD" }.modified)
        assertTrue("directories are dated too", fs.stat("C:/Doc")!!.modified > 0)
        // TempleOS Mobile's own files have no ISO date
        assertEquals("--/-- --:--", FsCommands.dirDate(fs.stat("C:/Home/Examples/Hello.HC")!!))
        // a user file gets its real modification time
        fs.writeFile("C:/Home/New.HC", "1;".toByteArray())
        assertTrue(Math.abs(fs.stat("C:/Home/New.HC")!!.modified - System.currentTimeMillis()) < 60_000)
    }

    @Test fun bundledReadOnlyLayerAndOverlay() {
        val dir = tmp()
        val fs = LayeredFs(bundle, dir)
        assertTrue(fs.isDir("C:/Demo/Games"))
        val maze = fs.readFile("C:/Demo/Games/Maze.HC")!!
        assertTrue(String(maze, Charsets.ISO_8859_1).contains("SolveMaze"))
        assertNotNull("case-insensitive lookup", fs.readFile("c:/demo/games/maze.hc"))
        // copy-on-write
        fs.writeFile("C:/Demo/Games/Maze.HC", "changed".toByteArray())
        assertEquals("changed", String(fs.readFile("C:/Demo/Games/Maze.HC")!!))
        assertFalse(fs.isOriginal("C:/Demo/Games/Maze.HC"))
        fs.restoreOriginal("C:/Demo/Games/Maze.HC")
        assertArrayEquals(maze, fs.readFile("C:/Demo/Games/Maze.HC"))
        // whiteout of bundled file
        fs.delete("C:/Demo/Games/Maze.HC")
        assertNull(fs.readFile("C:/Demo/Games/Maze.HC"))
        assertTrue(fs.list("C:/Demo/Games")!!.none { it.name == "Maze.HC" })
        // persists across instances
        val fs2 = LayeredFs(bundle, dir)
        assertNull(fs2.readFile("C:/Demo/Games/Maze.HC"))
        fs2.writeFile("C:/Demo/Games/Maze.HC", maze)
        assertNotNull(LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"))
    }

    /** Storage full / I/O error while recording a deleted original: an FsError, and nothing is deleted. */
    @Test fun failedWhiteoutWriteIsAnFsErrorAndKeepsTheFile() {
        val dir = tmp()
        val fs = LayeredFs(bundle, dir)
        File(dir, "deleted.txt.tmp").mkdirs() // the list's temp file cannot be written
        val e = try { fs.delete("C:/Demo/Games/Maze.HC"); null } catch (e: FsError) { e }
        assertEquals("fs.error.could_not_delete", e?.key)
        assertNotNull("the original is still there", fs.readFile("C:/Demo/Games/Maze.HC"))
        assertNotNull("and after a relaunch", LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"))
        File(dir, "deleted.txt.tmp").delete()
        fs.delete("C:/Demo/Games/Maze.HC") // works once there is room again
        assertNull(LayeredFs(bundle, dir).readFile("C:/Demo/Games/Maze.HC"))
    }

    @Test fun userFilesDirsMoveDelete() {
        val dir = tmp()
        val fs = LayeredFs(bundle, dir)
        fs.mkdir("C:/Home/Proj")
        fs.writeFile("C:/Home/Proj/A.HC", "\"hi\\n\";".toByteArray())
        assertTrue(fs.list("C:/Home/Proj")!!.any { it.name == "A.HC" && !it.readOnly })
        try { fs.writeFile("C:/Home/Missing/B.HC", ByteArray(1)); fail() } catch (e: FsError) {}
        try { fs.delete("C:/Home/Proj"); fail("non-empty dir") } catch (e: FsError) {}
        fs.move("C:/Home/Proj/A.HC", "C:/Home/Proj/B.HC")
        assertNull(fs.readFile("C:/Home/Proj/A.HC"))
        assertNotNull(fs.readFile("C:/Home/Proj/B.HC"))
        try { fs.move("C:/Home/Proj", "C:/Home/Proj/Sub"); fail() } catch (e: FsError) {}
        fs.delete("C:/Home/Proj", recursive = true)
        assertFalse(fs.exists("C:/Home/Proj"))
        assertEquals(0L, fs.usedBytes())
        assertTrue("no temp files left", dir.walkTopDown().none { it.name.startsWith(".tmp-") })
    }

    @Test fun traversalCannotEscapeSandbox() {
        val dir = tmp()
        val fs = LayeredFs(bundle, dir)
        fs.writeFile("C:/../../../outside.txt", "x".toByteArray())
        assertTrue(File(dir, "files/outside.txt").exists())
        assertFalse(File(dir.parentFile, "outside.txt").exists())
        assertNull(fs.readFile("C:/../../etc/passwd"))
    }

    @Test fun quotaEnforced() {
        val fs = LayeredFs(bundle, tmp(), quotaBytes = 1000)
        fs.writeFile("C:/Home/a.bin", ByteArray(800))
        try { fs.writeFile("C:/Home/b.bin", ByteArray(300)); fail("quota") } catch (e: FsError) {}
        fs.writeFile("C:/Home/a.bin", ByteArray(900)) // replacing is fine
        assertEquals(900L, fs.usedBytes())
    }

    @Test fun examplesRunFromVirtualFs() {
        val fs = LayeredFs(bundle, tmp())
        val env = TestEnv(fs)
        val hello = runHolyC(fs.readFile("C:/Home/Examples/Hello.HC")!!, "C:/Home/Examples/Hello.HC", env)
        assertEquals("Hello World!\nIn HolyC, strings can use DolDoc colors.\n*", hello.console.plainText().trimEnd())
        val fn = runHolyC(fs.readFile("C:/Home/Examples/Functions.HC")!!, "C:/Home/Examples/Functions.HC", env)
        assertTrue(fn.console.plainText().contains("Area(,4) = 40"))
        assertTrue(fn.console.plainText().contains("Fib(20) = 6765"))
        val loops = runHolyC(fs.readFile("C:/Home/Examples/Loops.HC")!!, "C:/Home/Examples/Loops.HC", env)
        assertTrue(loops.console.plainText().contains("Sum of 1..10 is 55"))
        assertTrue(loops.console.plainText().contains("zero small small small big big"))
        // #include from the virtual drive
        val inc = runHolyC("#include \"::/Home/Examples/Arithmetic.HC\"\n".toByteArray(), "C:/Home/Inc.HC", env)
        assertTrue(inc.console.plainText(), inc.console.plainText().contains("1<<4+1 = 17"))
        // file I/O from HolyC
        val io = runHolyC("FileWrite(\"~/T.TXT\",\"abc\",3); U8 *b=FileRead(\"~/T.TXT\"); \"%s %d\\n\",b,FileFind(\"~/T.TXT\");".toByteArray(), "C:/Home/Io.HC", env)
        assertEquals("abc 1", io.console.plainText().trim())
    }
}
