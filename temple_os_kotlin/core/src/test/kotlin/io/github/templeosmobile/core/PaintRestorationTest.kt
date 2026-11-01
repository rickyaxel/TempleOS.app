package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class PaintRestorationTest {
    private fun withApp(body: (PaintApp, Shell, HeadlessEnv) -> Unit) {
        val dir = kotlin.io.path.createTempDirectory("paint-test").toFile()
        try {
            val env = HeadlessEnv(dir); val sh = Shell(env); sh.resize(640, 700)
            val app = PaintApp(sh); sh.open(app); sh.tick(); body(app, sh, env)
        } finally { dir.deleteRecursively() }
    }
    @Test fun originalCompressedGRIsNotCropped() = withApp { _, sh, env ->
        val p = "C:/Demo/Games/Stadium/StadiumBG.GR"
        val image = GRImage.decode(env.fs.readFile(p)!!)
        assertEquals(641, image.width); assertEquals(473, image.height)
        val golden = File(SHARED, "test-vectors/paint/gr-golden.json").readText()
        val hash = MessageDigest.getInstance("SHA-256").digest(image.body).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertTrue("independent Python decoder golden hash", golden.contains(hash))
        val app = PaintApp(sh, p)
        assertEquals(641, app.w); assertEquals(473, app.h)
        assertArrayEquals(image.pixels, app.pix)
    }
    @Test fun cancelDoesNotDrawToCancelPosition() = withApp { app, sh, _ ->
        val r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
        app.pointer(PointerEvent(Ptr.DOWN, 200, 280, 7), r)
        val before = app.pix.copyOf()
        app.pointer(PointerEvent(Ptr.CANCEL, 500, 400, 7), r)
        assertArrayEquals(before, app.pix)
        app.pointer(PointerEvent(Ptr.MOVE, 400, 380, 7), r)
        assertArrayEquals(before, app.pix)
    }
    @Test fun extraFingerCannotDrawOrChangeTool() = withApp { app, sh, _ ->
        val r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
        app.pointer(PointerEvent(Ptr.DOWN, 200, 280, 7), r)
        val before = app.pix.copyOf()
        app.pointer(PointerEvent(Ptr.DOWN, 500, 400, 8), r)
        app.pointer(PointerEvent(Ptr.UP, 520, 420, 8), r)
        assertArrayEquals(before, app.pix)
        app.pointer(PointerEvent(Ptr.MOVE, 220, 300, 7), r)
        assertFalse(before.contentEquals(app.pix))
    }
    @Test fun focusReleaseEndsStroke() = withApp { app, sh, _ ->
        val r = Rect(0, 0, 640, 600); app.draw(sh.surface, r)
        app.pointer(PointerEvent(Ptr.DOWN, 200, 280, 7), r)
        app.releaseInput(); val before = app.pix.copyOf()
        app.pointer(PointerEvent(Ptr.UP, 500, 400, 7), r)
        assertArrayEquals(before, app.pix)
    }
    @Test fun invalidFilesCannotBeSavedOver() = withApp { _, sh, env ->
        val p = "C:/Home/Bad.GR"; val bytes = byteArrayOf(1, 2, 3)
        env.fs.writeFile(p, bytes)
        val app = PaintApp(sh, p); app.menu().first { it.label == "Save" }.action()
        assertArrayEquals(bytes, env.fs.readFile(p))
    }
    @Test fun undoAfterSavingMarksDocumentModified() = withApp { app, _, _ ->
        app.path = "C:/Home/Undo.GR"; app.pix[0] = 4
        app.menu().first { it.label == "Save" }.action()
        app.menu().first { it.label == "Clear" }.action()
        app.menu().first { it.label == "Save" }.action()
        assertFalse(app.unsaved)
        app.menu().first { it.label == "Undo" }.action()
        assertTrue(app.unsaved); assertEquals(4.toByte(), app.pix[0])
    }
    @Test fun malformedGRAndRecordedFuzzCases() {
        val dir = File(SHARED, "test-vectors/fuzz-repro")
        for (name in listOf("kotlin-paint-ArrayIndexOutOfBoundsException_SmallApps.kt_36.GR", "kotlin-paint-ArrayIndexOutOfBoundsException__.GR"))
            assertThrows(FsError::class.java) { GRImage.decode(File(dir, name).readBytes()) }
        val good = GRImage(9, 3).encode()
        for (n in good.indices) assertThrows(FsError::class.java) { GRImage.decode(good.copyOf(n)) }
        var seed = 0x5041494e54L
        repeat(1000) {
            val bytes = good.copyOf()
            for (i in 16..31) { seed = seed * 6364136223846793005L + 1; bytes[i] = (seed ushr 32).toByte() }
            assertThrows(FsError::class.java) { GRImage.decode(bytes) }
        }
    }
    @Test fun metadataTransparencyAndPaddingRoundTrip() = withApp { _, sh, env ->
        val bytes = ByteArray(32 + 128 + 16 * 3)
        fun put(o: Int, v: Int) { for (i in 0..3) bytes[o+i] = (v shr (8*i)).toByte() }
        put(0, 123); put(8, -4); put(12, 9); put(16, 9); put(20, 16); put(24, 3); put(28, 2)
        for (i in 32 until bytes.size) bytes[i] = i.toByte()
        bytes[160] = 255.toByte()
        assertArrayEquals(File(SHARED, "test-vectors/paint/metadata.GR").readBytes(), bytes)
        val image = GRImage.decode(bytes)
        assertEquals(255.toByte(), image.pixels[0]); assertArrayEquals(bytes, image.encode())
        val p = "C:/Home/Metadata.GR"; env.fs.writeFile(p, bytes)
        val app = PaintApp(sh, p); app.menu().first { it.label == "Save" }.action()
        assertArrayEquals(bytes, env.fs.readFile(p))
    }
    @Test fun originalSevenBitArchiveAndCorruptDictionaries() {
        val bytes = File(SHARED, "test-vectors/paint/original-source.HC.Z").readBytes()
        val original = File(SHARED, "bundled-fs/Adam/Gr/SpriteBitMap.HC").readBytes()
        assertArrayEquals(original, TempleArc.expand(bytes))
        for (n in listOf(0, 16, 17, 20, bytes.size - 10))
            assertThrows(FsError::class.java) { TempleArc.expand(bytes.copyOf(n)) }
        var seed = 0x415243L
        repeat(250) {
            seed = seed * 6364136223846793005L + 1
            val corrupt = bytes.copyOf()
            val pos = 17 + java.lang.Long.remainderUnsigned(seed, (bytes.size - 17).toLong()).toInt()
            corrupt[pos] = (corrupt[pos].toInt() xor (seed ushr 32).toInt()).toByte()
            try { assertEquals(original.size, TempleArc.expand(corrupt).size) }
            catch (_: FsError) { /* expected invalid dictionary */ }
        }
    }
    @Test fun historicalEditorDependencyProbe() {
        val env = TestEnv(HostDirFs(File(SHARED, "bundled-fs")))
        try {
            val k = runHolyC("#include \"C:/Adam/Gr/SpriteBitMap.HC\"\n".toByteArray(), env = env)
            println("PAINT_HISTORICAL_PROBE Kotlin: ${k.exitMessage}; ${k.console.plainText().takeLast(700)}")
            assertNotNull("Remove this blocker assertion when the original editor is supported", k.exitMessage)
        } catch (e: Exception) { println("PAINT_HISTORICAL_PROBE Kotlin: $e") }
    }

    @Test fun fileBrowserReopensGRAndArchive() = withApp { _, sh, env ->
        val image = GRImage(9, 3)
        for (suffix in listOf("GR", "GR.Z")) {
            val p = "C:/Home/Reopen.$suffix"
            env.fs.writeFile(p, if (suffix == "GR.Z") TempleArc.store(image.encode()) else image.encode())
            val files = FilesApp(sh, "C:/Home"); files.open(env.fs.stat(p)!!)
            val app = sh.focused!!.app as PaintApp
            assertEquals(p, app.path); assertEquals(9, app.w); assertEquals(3, app.h)
            files.open(env.fs.stat(p)!!); assertSame(app, sh.focused!!.app)
            app.pix[0] = 4; app.menu().first { it.label == "Save" }.action()
            val saved = env.fs.readFile(p)!!
            val reloaded = GRImage.decode(if (suffix == "GR.Z") TempleArc.expand(saved) else saved)
            assertEquals(4.toByte(), reloaded.pixels[0])
        }
    }
    @Test fun legacyRawGRWithArchiveSuffixRemainsReadable() = withApp { _, sh, env ->
        val p = "C:/Home/Legacy.GR.Z"; val image = GRImage(9, 3)
        val pixels = image.pixels; pixels[0] = 4; image.pixels = pixels
        env.fs.writeFile(p, image.encode())
        val app = PaintApp(sh, p)
        assertEquals(p, app.path); assertEquals(9, app.w); assertEquals(4.toByte(), app.pix[0])
        app.menu().first { it.label == "Save" }.action()
        val saved = env.fs.readFile(p)!!
        assertEquals(4.toByte(), GRImage.decode(TempleArc.expand(saved)).pixels[0])
    }
    @Test fun narrowToolLayoutAndRotationCancellation() = withApp { app, sh, _ ->
        val r = Rect(0, 0, 160, 600); app.a11yItems.clear(); app.draw(sh.surface, r)
        assertEquals(22, app.a11yItems.count { it.button })
        for (b in app.a11yItems.filter { it.button }) assertTrue(b.rect.x >= r.x && b.rect.right <= r.right)
        val line = app.a11yItems.first { it.label == "Tool LINE" }
        app.pointer(PointerEvent(Ptr.DOWN, line.rect.x + 1, line.rect.y + 1), r)
        val before = app.pix.copyOf(); val canvas = app.overlays(r).first().rect
        app.pointer(PointerEvent(Ptr.DOWN, canvas.x + 10, canvas.y + 10, 7), r)
        app.pointer(PointerEvent(Ptr.MOVE, canvas.x + 50, canvas.y + 50, 7), r)
        app.draw(sh.surface, Rect(0, 0, 640, 300))
        app.pointer(PointerEvent(Ptr.UP, 200, 200, 7), r)
        assertArrayEquals(before, app.pix)
    }
    @Test fun customPaletteAndPreviewFrame() = withApp { _, sh, env ->
        val p = "C:/Home/Frame.GR"
        env.fs.writeFile(p, File(SHARED, "test-vectors/paint/metadata.GR").readBytes())
        val app = PaintApp(sh, p)
        assertEquals(0xFF252321.toInt(), app.palette[0])
        val r = Rect(0, 0, 640, 600)
        fun draw() { app.a11yItems.clear(); app.draw(sh.surface, r) }
        fun frame() = ByteArray(app.w * app.h).also { app.copyFrame(it) }
        draw(); assertArrayEquals(app.pix, frame())
        val tool = app.a11yItems.first { it.label == "Tool LINE" }
        app.pointer(PointerEvent(Ptr.DOWN, tool.rect.x + 1, tool.rect.y + 1), r)
        val c = app.overlays(r).first().rect; val original = app.pix.copyOf(); val version = app.frameVersion
        app.pointer(PointerEvent(Ptr.DOWN, c.x + 2, c.y + 2, 7), r)
        app.pointer(PointerEvent(Ptr.MOVE, c.right - 2, c.bottom - 2, 7), r)
        draw(); assertArrayEquals(original, app.pix)
        assertFalse("visible preview must change before commit", original.contentEquals(frame()))
        assertTrue(app.frameVersion > version)
        app.pointer(PointerEvent(Ptr.CANCEL, 0, 0, 7), r); draw(); assertArrayEquals(original, frame())
    }

    /** Same fixture as Swift; artifacts describe the mobile wrapper, not a historical engine. */
    @Test fun deterministicWrapperReplay() = withApp { initial, sh, env ->
        val fixture = Json.parse(File(SHARED, "test-vectors/paint/wrapper-replay.json").readText()) as Map<*, *>
        val steps = fixture["steps"] as List<*>
        val out = System.getenv("PAINT_TRACE_DIR")?.let { File(it, "kotlin").apply { mkdirs() } }
        var app = initial
        val r = Rect(0, 0, 640, 600)
        fun draw() { app.a11yItems.clear(); app.draw(sh.surface, r) }
        draw()
        for ((i, raw) in steps.withIndex()) {
            val step = raw as Map<*, *>; val op = step["op"] as String
            when (op) {
                "tool", "color" -> {
                    val label = (if (op == "tool") "Tool " else "Color ") + step["value"]
                    val b = app.a11yItems.first { it.label == label }
                    app.pointer(PointerEvent(Ptr.DOWN, b.rect.x + 1, b.rect.y + 1), r)
                }
                "pointer" -> {
                    val c = app.overlays(r).first().rect
                    val action = mapOf("down" to Ptr.DOWN, "move" to Ptr.MOVE, "up" to Ptr.UP, "cancel" to Ptr.CANCEL)[step["action"]]!!
                    val x = c.x + (step["x"] as Number).toInt() * c.w / app.w
                    val y = c.y + (step["y"] as Number).toInt() * c.h / app.h
                    app.pointer(PointerEvent(action, x, y, 7), r)
                }
                "release" -> app.releaseInput()
                "undo" -> app.menu().first { it.label == "Undo" }.action()
                "save" -> {
                    app.path = "C:/Home/Replay.GR"; app.menu().first { it.label == "Save" }.action()
                    assertFalse(app.unsaved)
                }
                "reload" -> {
                    val before = app.pix.copyOf(); app = PaintApp(sh, "C:/Home/Replay.GR")
                    assertArrayEquals(before, app.pix)
                }
                else -> error("unknown replay operation $op")
            }
            draw()
            out?.let {
                val pixels = ByteArray(app.w * app.h); app.copyFrame(pixels)
                File(it, "$i.idx").writeBytes(pixels)
                val selected = app.a11yItems.filter { it.selected }.map { it.label }.sorted().joinToString(",") { "\"$it\"" }
                val input = app.replayState.entries.joinToString(",") { "\"${it.key}\":\"${it.value}\"" }
                File(it, "$i.json").writeText("""{"scope":"mobile-wrapper","width":${app.w},"height":${app.h},"op":"$op","unsaved":${app.unsaved},"path":"${app.path ?: ""}","input":{$input},"selected":[$selected]}""")
            }
        }
        assertTrue(app.pix.count { it != 15.toByte() } > 100)
        out?.let { File(it, "saved.GR").writeBytes(env.fs.readFile("C:/Home/Replay.GR")!!) }
    }
}
