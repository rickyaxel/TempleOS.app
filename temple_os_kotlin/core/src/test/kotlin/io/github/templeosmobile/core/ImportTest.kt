package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.CRC32
import java.util.zip.Deflater

/**
 * Start menu > Import... (docs/file-import.md): type detection, TempleOS compression against TempleOS's own
 * TOSZ output, the ZIP reader and the archive policy on adversarial input, the drive's staging and recovery,
 * the flow through the real shell (first-time explanation, picker, collisions, summary), and genuine external
 * programs (shared/test-vectors/import) found in Files and run on the HolyC interpreter. Swift: ImportTests.swift.
 */
class ImportTest {
    private val fix = File(SHARED, "test-vectors/import")
    private val dirs = ArrayList<File>()

    @After fun cleanup() { dirs.forEach { it.deleteRecursively() }; dirs.clear() }

    private fun tmp(): File = Files.createTempDirectory("tosm-import-").toFile().also { dirs.add(it) }

    private fun drive(dir: File, quota: Long = 64L shl 20) =
        LayeredFs(DirBundle(File(SHARED, "bundled-fs"), File(SHARED, "bundled-fs.index")), File(dir, "drive"), quota)

    private fun fixture(name: String) = File(fix, name).readBytes()

    /** A private copy of [bytes], as a platform picker hands a document over. */
    private fun picked(name: String, bytes: ByteArray): PickedFile {
        val f = File(tmp(), "copy"); f.writeBytes(bytes)
        return PickedFile(name, f.path)
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Staging folders left in the overlay (must be none after every import, failed or not). */
    private fun leftovers(dir: File, files: String = "drive/files") = File(dir, files).list()?.filter { it.startsWith(".tmp-") } ?: emptyList()

    private fun key(p: FileImport.Prepared): String? = (p.error as? ImportError)?.key ?: (p.error as? FsError)?.key

    /** Prepares and publishes [p] like the flow does with a free name; returns the published path. */
    private fun importNow(fs: LayeredFs, p: PickedFile): String {
        val r = FileImport.prepare(fs, p)
        r.error?.let { throw it }
        try { return FileImport.publish(fs, r, r.name, false) } finally { FileImport.discard(fs, r) }
    }

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    // ------------------------------------------------------------ ZIP writer for adversarial archives

    private class ZEntry(name: String, var data: ByteArray = ByteArray(0), var method: Int = 0) {
        var name: ByteArray = name.toByteArray(Charsets.UTF_8)
        var flags = 0
        var madeBy = 0x031E          // Unix, ZIP 3.0
        var external = 0b1000000110100100 shl 16 // 0o100644
        var crc: Long? = null
        var size: Int? = null
        var csize: Int? = null
        var localName: ByteArray? = null
        var raw: ByteArray? = null   // compressed bytes as stored, instead of compressing [data]
    }

    private fun deflate(src: ByteArray): ByteArray {
        val d = Deflater(9, true)
        d.setInput(src); d.finish()
        val out = ByteArray(src.size + 4096)
        var n = 0
        while (!d.finished()) n += d.deflate(out, n, out.size - n)
        d.end()
        return out.copyOf(n)
    }

    private fun zip(entries: List<ZEntry>, eocdCount: Int? = null, disk: Int = 0): ByteArray {
        val out = java.io.ByteArrayOutputStream(); val cd = java.io.ByteArrayOutputStream()
        fun le(v: Long, n: Int, b: java.io.ByteArrayOutputStream) { for (i in 0 until n) b.write((v shr (8 * i)).toInt() and 255) }
        fun le(v: Int, n: Int, b: java.io.ByteArrayOutputStream) = le(v.toLong(), n, b)
        for (e in entries) {
            val comp = e.raw ?: if (e.method == 8) deflate(e.data) else e.data
            val crc = e.crc ?: CRC32().apply { update(e.data) }.value
            val size = e.size ?: e.data.size; val csize = e.csize ?: comp.size
            val off = out.size(); val ln = e.localName ?: e.name
            le(0x0403_4B50, 4, out); le(20, 2, out); le(e.flags, 2, out); le(e.method, 2, out); le(0, 4, out)
            le(crc, 4, out); le(csize, 4, out); le(size, 4, out); le(ln.size, 2, out); le(0, 2, out); out.write(ln); out.write(comp)
            le(0x0201_4B50, 4, cd); le(e.madeBy, 2, cd); le(20, 2, cd); le(e.flags, 2, cd); le(e.method, 2, cd); le(0, 4, cd)
            le(crc, 4, cd); le(csize, 4, cd); le(size, 4, cd); le(e.name.size, 2, cd); le(0, 2, cd); le(0, 2, cd)
            le(0, 2, cd); le(0, 2, cd); le(e.external, 4, cd); le(off, 4, cd); cd.write(e.name)
        }
        val cdOff = out.size()
        out.write(cd.toByteArray())
        le(0x0605_4B50, 4, out); le(disk, 2, out); le(disk, 2, out)
        le(eocdCount ?: entries.size, 2, out); le(eocdCount ?: entries.size, 2, out); le(cd.size(), 4, out); le(cdOff, 4, out); le(0, 2, out)
        return out.toByteArray()
    }

    /** Imports [entries] as an archive into a fresh drive; returns the refusal key (null when it was imported). */
    private fun archiveKey(entries: List<ZEntry>, file: String = "Test.zip", bytes: ByteArray? = null): String? {
        val dir = tmp(); val fs = drive(dir)
        val used = fs.usedBytes()
        val r = FileImport.prepare(fs, picked(file, bytes ?: zip(entries)))
        if (r.error != null) {
            assertEquals("a refused archive leaves no staging folder", emptyList<String>(), leftovers(dir))
            assertEquals("a refused archive gives its bytes back", used, fs.usedBytes())
            assertFalse("nothing of a refused archive is visible", fs.exists(FileImport.DESTINATION))
        }
        FileImport.discard(fs, r)
        return key(r)
    }

    // ------------------------------------------------------------ detection

    @Test fun kindIsDecidedByNameNotByMimeOrContent() {
        val cases = listOf("Hello.HC" to FileImport.Kind.SOURCE, "hello.hc" to FileImport.Kind.SOURCE, "Hello.Hc" to FileImport.Kind.SOURCE,
            "  Spaced.HC  " to FileImport.Kind.SOURCE, "Song.HC.Z" to FileImport.Kind.COMPRESSED, "song.hc.z" to FileImport.Kind.COMPRESSED,
            "Game.zip" to FileImport.Kind.ARCHIVE, "GAME.ZIP" to FileImport.Kind.ARCHIVE, "Archive.HC.zip" to FileImport.Kind.ARCHIVE,
            "Notes.TXT" to null, "Doc.DD.Z" to null, "x.Z" to null, "Hello" to null, "" to null, ".HC" to null, ".zip" to null,
            "Hello.HC.txt" to null, "Hello.HC.Z.zip" to FileImport.Kind.ARCHIVE, "Hello.HCZ" to null)
        for ((name, kind) in cases) assertEquals(name, kind, FileImport.kind(name))
    }

    // ------------------------------------------------------------ TempleOS compression (genuine files)

    @Test fun genuineCompressedFilesExpandExactlyAsTempleOSOwnToolDoes() {
        // expansions recorded with TOSZ.CPP (TempleOS V5.03 ISO, Downloads/Linux); see shared/test-vectors/import/README.md
        val expected = mapOf("o.HC.Z" to Triple("e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", 437, 2),
            "B17.HC.Z" to Triple("7b50f52794de6026f2ab9406bfaaf052d62402bbbc31aaeb206e7145879a65b6", 2775, 3),
            "NewOS.HC.Z" to Triple("49c4b33abba7851d929bdf99b25d5faed38bc4d7fd73509559a61f3c9103d9dc", 1437, 2))
        for ((name, v) in expected) {
            val raw = fixture(name)
            val h = TempleArc.header(raw)!!
            assertEquals(name, raw.size, h.first); assertEquals(name, v.second, h.second); assertEquals(name, v.third, h.third)
            assertEquals(name, v.first, sha(TempleArc.expand(raw, limit = FileImport.MAX_FILE_BYTES)))
        }
    }

    @Test fun malformedCompressedDataIsRefusedWithoutUnboundedWork() {
        val raw = fixture("B17.HC.Z")
        for (n in raw.indices) assertThrows("truncated to $n", FsError::class.java) { TempleArc.expand(raw.copyOf(n), limit = 1 shl 20) }
        for (t in listOf(0, 4, 9, 255)) { val b = raw.copyOf(); b[16] = t.toByte(); assertThrows("type $t", FsError::class.java) { TempleArc.expand(b, limit = 1 shl 20) } }
        val small = raw.copyOf(); small[0] = 16; small[1] = 0
        assertThrows("compressed size below the header", FsError::class.java) { TempleArc.expand(small, limit = 1 shl 20) }
        val huge = raw.copyOf(); huge[8] = 0; huge[9] = 0; huge[10] = 0; huge[11] = 0x40 // declares 1 GiB
        assertNull(TempleArc.header(huge)?.takeIf { it.second <= FileImport.MAX_FILE_BYTES })
        assertThrows("oversized output is refused before allocation", FsError::class.java) { TempleArc.expand(huge, limit = FileImport.MAX_FILE_BYTES) }
        // random corruption: refused, or exactly the declared size (never more, never a crash or hang)
        var seed = 0x5EEDL
        repeat(300) {
            val b = raw.copyOf()
            repeat(3) {
                seed = seed * 6364136223846793005L + 1442695040888963407L
                b[17 + ((seed ushr 33) % (b.size - 17)).toInt()] = (b[17 + ((seed ushr 33) % (b.size - 17)).toInt()].toInt() xor (((seed ushr 7).toInt() and 255) or 1)).toByte()
            }
            runCatching { TempleArc.expand(b, limit = 1 shl 20) }.getOrNull()?.let { assertEquals(2775, it.size) }
        }
    }

    // ------------------------------------------------------------ the ZIP reader

    @Test fun realArchivesReadEntryForEntry() {
        val dir = tmp()
        for ((name, files) in listOf("Sup1Snd.zip" to listOf("Sup1Snd/", "Sup1Snd/SndFile.HC.Z", "Sup1Snd/MakeSnd.HC.Z", "Sup1Snd/SndMath.HC.Z", "Sup1Snd/SndMusic.HC.Z", "Sup1Snd/SndEffects.HC.Z"),
                "SndSource.zip" to listOf("SndSource/", "SndSource/SndFile.HC", "SndSource/SndMath.HC", "SndSource/SndMusic.HC", "SndSource/MakeSnd.HC", "SndSource/SndEffects.HC"))) {
            val f = File(dir, name); f.writeBytes(fixture(name))
            val z = ZipArchive(f.path, 100)
            assertEquals(files, z.entries.map { String(it.rawName, Charsets.UTF_8) })
            for (e in z.entries) if (!e.isDir) assertEquals(e.size, z.data(e).size)
            z.close()
        }
    }

    @Test fun malformedContainersAreRefused() {
        val good = zip(listOf(ZEntry("A/One.HC", bytes("\"one\\n\";\n"), 8), ZEntry("A/Two.HC", ByteArray(5000) { 65 }, 8)))
        assertNull("the reference archive imports", archiveKey(emptyList(), bytes = good))
        assertEquals("import.error.invalid_zip", archiveKey(emptyList(), bytes = bytes("not a zip at all, just text")))
        assertEquals("import.error.empty", archiveKey(emptyList(), bytes = ByteArray(0)))
        for (n in listOf(10, 21, good.size / 2, good.size - 1)) assertEquals("truncated to $n", "import.error.invalid_zip", archiveKey(emptyList(), bytes = good.copyOf(n)) ?: "null")
        assertEquals("import.error.damaged", archiveKey(listOf(ZEntry("A/One.HC", ByteArray(300) { 66 }, 8).apply { crc = 0x1234_5678L })))
        assertEquals("inflates beyond its declared size", "import.error.damaged", archiveKey(listOf(ZEntry("A/One.HC", ByteArray(300) { 67 }, 8).apply { size = 200 })))
        assertEquals("inflates to less than its declared size", "import.error.damaged", archiveKey(listOf(ZEntry("A/One.HC", ByteArray(300) { 67 }, 8).apply { size = 400 })))
        assertEquals("stored sizes disagree", "import.error.damaged", archiveKey(listOf(ZEntry("A/One.HC", ByteArray(50) { 1 }).apply { csize = 40 })))
        assertEquals("not a Deflate stream", "import.error.damaged", archiveKey(listOf(ZEntry("A/One.HC", ByteArray(50) { 1 }, 8).apply { raw = byteArrayOf(-1, -2, -3, 0, 0x13) })))
        assertEquals("local header names another file", "import.error.invalid_zip", archiveKey(listOf(ZEntry("A/One.HC", byteArrayOf(1, 2, 3)).apply { localName = bytes("A/Evil.HC") })))
        assertEquals("import.error.zip_unsupported", archiveKey(emptyList(), bytes = zip(listOf(ZEntry("A.HC", byteArrayOf(1))), eocdCount = 0xFFFF)))
        assertEquals("import.error.zip_unsupported", archiveKey(emptyList(), bytes = zip(listOf(ZEntry("A.HC", byteArrayOf(1))), disk = 1)))
        // two central entries pointing at the same data (an overlapping-file bomb)
        val twice = zip(listOf(ZEntry("A.HC", ByteArray(100) { 9 }), ZEntry("B.HC", ByteArray(100) { 9 })))
        val cd = twice.size - 22 - 2 * (46 + 4)
        twice[cd + 46 + 4 + 42] = 0; twice[cd + 46 + 4 + 43] = 0 // B's local offset := A's
        assertEquals("import.error.invalid_zip", archiveKey(emptyList(), bytes = twice))
    }

    // ------------------------------------------------------------ archive policy (untrusted names and sizes)

    @Test fun traversalLinksAndUnsafeEntriesAreRefusedBeforeAnythingIsWritten() {
        for (evil in listOf("../Evil.HC", "A/../../Evil.HC", "/Abs.HC", "C:/Kernel/Evil.HC", "A\\..\\..\\Evil.HC", "..\\Evil.HC", "A/./B.HC", "::/Evil.HC"))
            assertEquals(evil, "import.error.unsafe_path", archiveKey(listOf(ZEntry("Good.HC", byteArrayOf(1)), ZEntry(evil, byteArrayOf(2)))))
        assertEquals("import.error.link", archiveKey(listOf(ZEntry("A/Ok.HC", byteArrayOf(1)), ZEntry("A/Link.HC", bytes("/etc/passwd")).apply { external = 0xA1FF shl 16 })))
        assertEquals("import.error.link", archiveKey(listOf(ZEntry("A/Pipe").apply { external = 0x11A4 shl 16 })))
        assertEquals("import.error.encrypted", archiveKey(listOf(ZEntry("A/Secret.HC", byteArrayOf(1, 2, 3)).apply { flags = 1 })))
        assertEquals("import.error.method", archiveKey(listOf(ZEntry("A/X.HC", byteArrayOf(1, 2, 3)).apply { method = 14; raw = byteArrayOf(1, 2, 3) })))
        assertEquals("names differ only in case", "import.error.duplicate", archiveKey(listOf(ZEntry("A/Game.HC", byteArrayOf(1)), ZEntry("A/GAME.hc", byteArrayOf(2)))))
        assertEquals("X.HC and X.HC.Z are one file on C:", "import.error.duplicate", archiveKey(listOf(ZEntry("A/Song.HC", byteArrayOf(1)), ZEntry("A/Song.HC.Z", TempleArc.store(byteArrayOf(2))))))
        assertEquals("import.error.file_and_folder", archiveKey(listOf(ZEntry("A/B", byteArrayOf(1)), ZEntry("A/B/C.HC", byteArrayOf(2)))))
        assertEquals("import.error.file_and_folder", archiveKey(listOf(ZEntry("A/B/C.HC", byteArrayOf(2)), ZEntry("A/B", byteArrayOf(1)))))
        assertEquals("not in the TempleOS character set", "import.error.bad_name", archiveKey(listOf(ZEntry("A/\u0416\u0416.HC", byteArrayOf(1)))))
        assertEquals("longer than 38", "import.error.bad_name", archiveKey(listOf(ZEntry("A/" + "N".repeat(36) + ".HC", byteArrayOf(1)))))
        assertEquals("import.error.bad_name", archiveKey(listOf(ZEntry("A/Bad*.HC", byteArrayOf(1)))))
        assertEquals("import.error.bad_name", archiveKey(listOf(ZEntry("A/.tmp-hidden.HC", byteArrayOf(1)))))
        assertEquals("import.error.bad_name", archiveKey(listOf(ZEntry("A//B.HC", byteArrayOf(1)))))
        val deep = (1..9).joinToString("/") { "D$it" } + "/X.HC"
        assertEquals("import.error.too_deep", archiveKey(listOf(ZEntry(deep, byteArrayOf(1)))))
        assertNull("eight folders are allowed", archiveKey(listOf(ZEntry((1..8).joinToString("/") { "D$it" } + "/X.HC", byteArrayOf(1)))))
        assertEquals("import.error.corrupt_z_entry", archiveKey(listOf(ZEntry("A/Bad.HC.Z", bytes("plain text, not compressed")))))
        assertEquals("import.error.empty_archive", archiveKey(listOf(ZEntry("A/"), ZEntry("__MACOSX/A/._X.HC", byteArrayOf(0, 5, 22)))))
    }

    @Test fun resourceLimitsStopZipBombsBeforeExtraction() {
        // a declared size over the per-file limit is refused from the central directory alone
        assertEquals("import.error.entry_too_large", archiveKey(listOf(ZEntry("A/Big.BIN", byteArrayOf(0)).apply { size = FileImport.MAX_FILE_BYTES + 1; crc = 0 })))
        // 2 MiB of zeros deflate to about 2 KiB: a ratio no TempleOS program has
        assertEquals("import.error.ratio", archiveKey(listOf(ZEntry("A/Bomb.BIN", ByteArray(2 shl 20), 8))))
        // forged sizes: four entries declaring 13 MiB each at an ordinary ratio
        assertEquals("import.error.expands_too_large", archiveKey((0 until 4).map { i -> ZEntry("A/Part$i.BIN", ByteArray(100_000) { i.toByte() }).apply { size = 13 shl 20 } }))
        assertEquals("import.error.too_many_entries", archiveKey((0..FileImport.MAX_ENTRIES).map { ZEntry("A/F$it.HC", byteArrayOf(1)) }))
        // TempleOS compression inside an archive is bounded by its declared size too
        val hc = TempleArc.store(bytes("Hi")); hc[8] = 0; hc[9] = 0; hc[10] = 0; hc[11] = 0x10 // declares 256 MiB
        assertEquals("import.error.entry_too_large", archiveKey(listOf(ZEntry("A/Huge.HC.Z", hc))))
        val dir = tmp(); val fs = drive(dir)
        assertEquals("import.error.archive_too_large", key(FileImport.prepare(fs, picked("Big.zip", ByteArray(FileImport.MAX_ARCHIVE_BYTES + 1)))))
    }

    // ------------------------------------------------------------ single files

    @Test fun sourceAndCompressedSourceLandOnTheDriveByteForByte() {
        val dir = tmp(); val fs = drive(dir)
        val copy = picked("DiningStars.HC", fixture("DiningStars.HC"))
        assertEquals("C:/Home/Imports/DiningStars.HC", importNow(fs, copy))
        assertFalse("the platform's copy is deleted", File(copy.hostPath!!).exists())
        assertEquals("559504014bb2fb4b6a0554f376bedb1640c254981eb4a1dfa07d180f8b70a8a7", sha(fs.readFile("C:/Home/Imports/DiningStars.HC")!!))
        // .HC.Z is expanded and stored under its name without .Z, as the bundled drive stores the ISO's files
        assertEquals("C:/Home/Imports/o.HC", importNow(fs, picked("o.HC.Z", fixture("o.HC.Z"))))
        assertEquals("e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", sha(fs.readFile("C:/Home/Imports/o.HC")!!))
        assertArrayEquals("the .Z name resolves to it", fs.readFile("C:/Home/Imports/o.HC"), fs.readFile("C:/Home/Imports/o.HC.Z"))
        assertEquals(listOf("DiningStars.HC", "o.HC"), fs.list("C:/Home/Imports")!!.map { it.name }.sorted())
        assertTrue("Files shows the folder in the home folder", fs.list("C:/Home")!!.any { it.name == "Imports" && it.isDir })
        assertEquals(emptyList<String>(), leftovers(dir))
        // persistent: a new drive over the same storage (the next launch) sees the same files
        assertArrayEquals(fs.readFile("C:/Home/Imports/o.HC"), drive(dir).readFile("C:/Home/Imports/o.HC"))
    }

    @Test fun mislabelledEmptyAndUnrepresentableFilesAreRefused() {
        val dir = tmp(); val fs = drive(dir)
        fun k(name: String, b: ByteArray): String? { val r = FileImport.prepare(fs, picked(name, b)); FileImport.discard(fs, r); return key(r) }
        assertEquals("import.error.is_zip", k("Game.HC", fixture("Sup1Snd.zip")))
        assertEquals("a renamed .HC.Z", "import.error.is_compressed", k("o.HC", fixture("o.HC.Z")))
        assertEquals("a renamed .HC is not TempleOS-compressed", "import.error.corrupt_z", k("Fake.HC.Z", bytes("U0 Main() {}\n")))
        assertEquals("import.error.invalid_zip", k("Fake.zip", fixture("DiningStars.HC")))
        assertEquals("import.error.empty", k("Empty.HC", ByteArray(0)))
        assertEquals("import.error.unsupported_type", k("Notes.TXT", bytes("text")))
        assertEquals("Cyrillic is not in the TempleOS character set", "import.error.bad_name", k("\u041F\u0440\u0438\u0432\u0435\u0442.HC", bytes("1;")))
        assertEquals("import.error.bad_name", k("L".repeat(40) + ".HC", bytes("1;")))
        assertEquals("import.error.too_large", k("Huge.HC", ByteArray(FileImport.MAX_FILE_BYTES + 1) { 32 }))
        assertEquals("import.error.read", key(FileImport.prepare(fs, PickedFile("Gone.HC", "/nonexistent/x"))))
        assertEquals("import.error.device_storage", key(FileImport.prepare(fs, PickedFile("A.HC", null, ImportError("import.error.device_storage")))))
        // Latin-1 and CP437 names are fine, also in decomposed (NFD) form as some providers report them
        assertNull(k("Cafe\u0301.HC", bytes("1;")))
        assertNotNull(FileImport.driveName("\u00C9t\u00E9.HC"))
        assertEquals(emptyList<String>(), leftovers(dir))
        assertFalse("nothing was published", fs.exists("C:/Home/Imports"))
    }

    // ------------------------------------------------------------ archives

    @Test fun archivesKeepTheirFoldersAndExpandTempleOSCompressedFiles() {
        val dir = tmp(); val fs = drive(dir)
        assertEquals("C:/Home/Imports/Sup1Snd", importNow(fs, picked("Sup1Snd.zip", fixture("Sup1Snd.zip"))))
        val expected = mapOf("MakeSnd.HC" to "18950622af5eedf236666ddf4ad8d76f30ce49d8b5068dcacbdf1b26d40686de",
            "SndMath.HC" to "f0d7ba7625624b960e2d179ceee6e240a8b6455ac65aabd273c84b59f1fd53a3",
            "SndMusic.HC" to "b44d52a3e85e615a6b44a5d26adc4cd9325867e1ae8a164a4ad68942e6185166",
            "SndEffects.HC" to "21d771ef71014645afa97df850fc7b3417d0e982a6ceb96055eb7d802f27f09f",
            "SndFile.HC" to "d3efc36170b9e2a190eff94395e7e49d58fc8f6b436def2f14cb81b112d9940b")
        assertEquals(expected.keys.sorted(), fs.list("C:/Home/Imports/Sup1Snd")!!.map { it.name }.sorted())
        for ((n, d) in expected) assertEquals(n, d, sha(fs.readFile("C:/Home/Imports/Sup1Snd/$n")!!))
        // Finder's format (Deflate, data descriptors): the same sources, plain
        assertEquals("C:/Home/Imports/SndSource", importNow(fs, picked("SndSource.zip", fixture("SndSource.zip"))))
        for ((n, d) in expected) assertEquals(n, d, sha(fs.readFile("C:/Home/Imports/SndSource/$n")!!))
        // no single top folder: a folder named after the archive; binary files, empty folders and nesting kept;
        // Finder's metadata is not content
        val bin = ByteArray(4096) { (it * 7919).toByte() }
        val mixed = zip(listOf(ZEntry("Main.HC", bytes("#include \"Lib/Util\"\n"), 8), ZEntry("Lib/Util.HC", bytes("U0 Util() {}\n")),
            ZEntry("Assets/Sprite.BIN", bin, 8), ZEntry("Assets/Empty/"), ZEntry("Readme.TXT", bytes("hello")),
            ZEntry("__MACOSX/._Main.HC", byteArrayOf(0, 5, 22, 7)), ZEntry(".DS_Store", byteArrayOf(0, 0, 0, 1)),
            ZEntry("Caf\u00E9.HC", bytes("1;"))))
        assertEquals("C:/Home/Imports/MyGame", importNow(fs, picked("MyGame.zip", mixed)))
        assertArrayEquals(bin, fs.readFile("C:/Home/Imports/MyGame/Assets/Sprite.BIN"))
        assertTrue(fs.isDir("C:/Home/Imports/MyGame/Assets/Empty"))
        assertEquals("a UTF-8 name is stored as TempleOS (CP437) bytes; no metadata files",
            listOf("Assets", "Caf\u0082.HC", "Lib", "Main.HC", "Readme.TXT"), fs.list("C:/Home/Imports/MyGame")!!.map { it.name }.sorted())
        assertEquals(emptyList<String>(), leftovers(dir))
    }

    // ------------------------------------------------------------ the drive: collisions, quota, recovery

    @Test fun collisionsNeverOverwriteSilentlyAndBundledFilesAreProtected() {
        val dir = tmp(); val fs = drive(dir)
        importNow(fs, picked("o.HC.Z", fixture("o.HC.Z")))
        val again = FileImport.prepare(fs, picked("o.HC", bytes("\"mine\\n\";\n")))
        assertThrows("a taken name is an error unless replacing", FsError::class.java) { FileImport.publish(fs, again, again.name, false) }
        assertEquals("o_2.HC", FileImport.freeName(fs, again.name))
        FileImport.publish(fs, again, "o_2.HC", false)
        FileImport.discard(fs, again)
        assertEquals("o_3.HC", FileImport.freeName(fs, "o.HC"))
        // Replace: the new content, atomically, and the replaced bytes are given back
        val before = fs.usedBytes()
        val rep = FileImport.prepare(fs, picked("o.HC", bytes("\"replaced\\n\";\n")))
        FileImport.publish(fs, rep, "o.HC", true)
        FileImport.discard(fs, rep)
        assertArrayEquals(bytes("\"replaced\\n\";\n"), fs.readFile("C:/Home/Imports/o.HC"))
        assertEquals(before - 437 + 14, fs.usedBytes())
        // folders replace as a whole
        importNow(fs, picked("Sup1Snd.zip", fixture("Sup1Snd.zip")))
        val folder = FileImport.prepare(fs, picked("Sup1Snd.zip", zip(listOf(ZEntry("Sup1Snd/Only.HC", byteArrayOf(65))))))
        FileImport.publish(fs, folder, folder.name, true)
        FileImport.discard(fs, folder)
        assertEquals(listOf("Only.HC"), fs.list("C:/Home/Imports/Sup1Snd")!!.map { it.name })
        // a bundled original is never replaced, whatever is asked
        val stage = fs.beginStage()
        fs.stageFile(stage, "Maze.HC", byteArrayOf(1, 2, 3))
        assertThrows(FsError::class.java) { fs.publishStaged(stage, "Maze.HC", "C:/Demo/Games/Maze.HC", true) }
        fs.discardStage(stage)
        assertFalse(byteArrayOf(1, 2, 3).contentEquals(fs.readFile("C:/Demo/Games/Maze.HC")))
        assertEquals("long names are shortened to fit", 38, FileImport.freeName(fs, "N".repeat(35) + ".HC")!!.length)
        assertEquals(emptyList<String>(), leftovers(dir))
    }

    @Test fun theQuotaAppliesAndAFailedImportGivesEverythingBack() {
        val dir = tmp(); val fs = drive(dir, quota = 1L shl 20)
        val used = fs.usedBytes()
        val r = FileImport.prepare(fs, picked("Big.zip", zip(listOf(ZEntry("Big/A.BIN", ByteArray(700_000) { 1 }), ZEntry("Big/B.BIN", ByteArray(700_000) { 2 })))))
        assertEquals("fs.error.storage_full", key(r))
        assertEquals(used, fs.usedBytes())
        assertEquals(emptyList<String>(), leftovers(dir))
        assertFalse(fs.exists("C:/Home/Imports/Big"))
    }

    @Test fun anInterruptedImportIsUndoneOnTheNextStart() {
        val dir = tmp(); val fs = drive(dir)
        importNow(fs, picked("o.HC.Z", fixture("o.HC.Z")))
        // killed while staging: the staging folder is removed at the next start
        val s = fs.beginStage()
        fs.stageFile(s, "Half/One.HC", byteArrayOf(1))
        assertEquals(1, leftovers(dir).size)
        drive(dir)
        assertEquals(emptyList<String>(), leftovers(dir))
        // killed between moving the replaced file aside and renaming the new one into place
        val files = File(dir, "drive/files")
        val stage = File(files, ".tmp-import-crash").apply { mkdirs() }
        assertTrue(File(files, "Home/Imports/o.HC").renameTo(File(stage, ".replaced-1")))
        File(dir, "drive/import-journal.txt").writeText(".tmp-import-crash/.replaced-1\tHome/Imports/o.HC")
        val after = drive(dir)
        assertEquals("the earlier file is back", "e2725f17ac75e7b06e611cf0577331145568872a3d142f6a4e2f574cd6dd39ea", sha(after.readFile("C:/Home/Imports/o.HC") ?: ByteArray(0)))
        assertEquals(emptyList<String>(), leftovers(dir))
        assertFalse(File(dir, "drive/import-journal.txt").exists())
        assertEquals(437L, after.usedBytes())
    }

    // ------------------------------------------------------------ the flow, through the real shell

    private class Run(dir: File) {
        val env = HeadlessEnv(dir)
        val sh = Shell(env).also { it.resize(402, 874, 62, 34, 0, 0, 0); it.tick() }
        var t = 1000L
        var picks = 0
        init { env.picker = { picks++; true } }
        fun waitFor(s: Double, c: () -> Boolean): Boolean {
            val end = System.currentTimeMillis() + (s * 1000).toLong()
            while (System.currentTimeMillis() < end) { sh.tick(); if (c()) return true; Thread.sleep(16) }
            sh.tick(); return c()
        }
        fun labels(): List<String> { sh.tick(); return sh.accessibilityNodes().map { it.label } }
        fun tap(label: String) {
            sh.tick()
            val r = sh.accessibilityNodes().firstOrNull { it.label == label }?.rect ?: run { fail("no '$label' in ${labels()}"); return }
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, 1, t)); t += 50
            sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, 1, t)); t += 50
            sh.tick()
        }
        fun importFiles(files: List<PickedFile>) {
            sh.importFlow.receive(files)
            assertTrue("the summary appears", waitFor(20.0) { !sh.importFlow.busy && sh.dialogOpen })
        }
        fun close() { sh.windows.toList().forEach { sh.close(it, force = true) } }
    }

    @Test fun importFromTheStartMenuWithTheFirstTimeExplanation() {
        val dir = tmp(); val r = Run(dir)
        try {
            r.tap(tr("topbar.menu"))
            assertTrue("the start menu has Import...", r.labels().contains(tr("menu.start.import")))
            r.tap(tr("menu.start.import"))
            assertTrue("the explanation comes first", r.sh.dialogOpen)
            assertTrue(r.labels().contains(tr("import.intro.title")))
            assertEquals("no picker before the explanation", 0, r.picks)
            r.tap(tr("button.cancel"))
            assertFalse(r.sh.dialogOpen); assertFalse("Cancel does not count as seen", r.sh.settings.importIntroSeen)
            assertEquals(0, r.picks)
            r.tap(tr("topbar.menu")); r.tap(tr("menu.start.import"))
            assertTrue("shown again after Cancel", r.labels().contains(tr("import.intro.title")))
            r.tap(tr("button.choose_files"))
            assertTrue("the picker opens", r.waitFor(2.0) { r.picks == 1 })
            assertTrue(r.sh.settings.importIntroSeen)
            assertTrue("persisted with the session", r.env.session?.contains(";i=1") == true)
            // repeated taps while the picker is open never open a second one
            r.sh.importFlow.start(); r.sh.importFlow.start()
            assertEquals(1, r.picks)
            // the picker returns a genuine external .HC.Z
            r.importFiles(listOf(picked("o.HC.Z", fixture("o.HC.Z"))))
            assertTrue(r.labels().contains(tr("import.done.title")))
            assertTrue("Run is offered for one program, never automatic", r.labels().contains(tr("button.run")))
            assertFalse("nothing ran by itself", r.sh.windows.any { it.app.kind == "program" })
            r.tap(tr("button.open_folder"))
            assertTrue("Open Folder shows the import in Files", r.waitFor(2.0) { (r.sh.focused?.app as? FilesApp)?.dir == "C:/Home/Imports" })
            // in Files, like any file: tap, Run (the normal launcher, the HolyC interpreter)
            r.tap(tr("files.a11y.file_item", "name" to "o.HC", "size" to 437))
            r.tap(tr("files.menu.run"))
            val p = r.sh.focused?.app as ProgramApp
            assertEquals("C:/Home/Imports/o.HC", p.path)
            assertTrue("the hymn plays: ${p.kernel.speakerChanges} speaker changes", r.waitFor(30.0) { p.kernel.speakerChanges >= 20 })
            assertFalse(p.isFinished)
            val (ch, sc) = Keys.forChar(32)
            r.sh.key(ch, sc, true); r.sh.key(ch, sc or Keys.SCF_KEY_UP, false)
            assertTrue("a key ends it (ScanKey, checked after each pass of the song)", r.waitFor(60.0) { p.kernel.finished })
            assertEquals(ExitCategory.NORMAL, p.kernel.exitCategory)
            // later imports skip the explanation
            r.tap(tr("topbar.menu")); r.tap(tr("menu.start.import"))
            assertEquals(2, r.picks); assertFalse(r.labels().contains(tr("import.intro.title")))
            r.sh.importFlow.receive(emptyList())
            assertTrue("a cancelled picker ends the import", r.waitFor(2.0) { !r.sh.importFlow.busy })
            // the same name again: Keep Both, then Replace, then Cancel
            r.sh.importFlow.receive(listOf(picked("o.HC.Z", fixture("o.HC.Z"))))
            assertTrue("asked, not overwritten", r.waitFor(20.0) { r.labels().contains(tr("button.keep_both")) })
            r.tap(tr("button.keep_both"))
            assertTrue(r.waitFor(10.0) { r.labels().contains(tr("import.done.title")) })
            assertTrue(r.sh.fs.exists("C:/Home/Imports/o_2.HC"))
            r.tap(tr("button.close"))
            r.sh.importFlow.receive(listOf(picked("o.HC", bytes("\"new\\n\";\n"))))
            assertTrue(r.waitFor(20.0) { r.labels().contains(tr("button.replace")) })
            r.tap(tr("button.replace"))
            assertTrue(r.waitFor(10.0) { r.labels().contains(tr("import.done.title")) })
            assertArrayEquals(bytes("\"new\\n\";\n"), r.sh.fs.readFile("C:/Home/Imports/o.HC"))
            r.tap(tr("button.close"))
            r.sh.importFlow.receive(listOf(picked("o.HC", bytes("\"other\\n\";\n"))))
            assertTrue(r.waitFor(20.0) { r.labels().contains(tr("button.replace")) })
            r.tap(tr("button.cancel"))
            assertTrue(r.waitFor(5.0) { !r.sh.importFlow.busy })
            assertArrayEquals("Cancel keeps the earlier file", bytes("\"new\\n\";\n"), r.sh.fs.readFile("C:/Home/Imports/o.HC"))
            assertTrue("staging folders are deleted", r.waitFor(2.0) { leftovers(dir, "files").isEmpty() })
        } finally { r.close() }
    }

    @Test fun failuresAreReportedAndTheAppStaysUsable() {
        val dir = tmp(); val r = Run(dir)
        try {
            r.importFiles(listOf(picked("Bad.zip", zip(listOf(ZEntry("../Evil.HC", byteArrayOf(1))))), picked("Notes.TXT", byteArrayOf(1)), picked("o.HC.Z", fixture("o.HC.Z"))))
            val text = r.labels().joinToString("\n")
            assertTrue(text, text.contains(tr("import.partial.title")))
            assertTrue(text, text.contains(tr("import.result.failed", "name" to "Bad.zip", "reason" to tr("import.error.unsafe_path", "entry" to "../Evil.HC"))))
            assertTrue(text, text.contains(tr("import.error.unsupported_type")))
            assertTrue("one program was imported: Run is offered", r.labels().contains(tr("button.run")))
            assertFalse("and nothing ran by itself", r.sh.windows.any { it.app.kind == "program" })
            r.tap(tr("button.close"))
            r.importFiles(listOf(picked("Only.TXT", byteArrayOf(1))))
            assertTrue(r.labels().contains(tr("import.failed.title")))
            assertFalse(r.labels().contains(tr("button.open_folder")))
            r.tap(tr("button.close"))
            assertTrue(r.waitFor(2.0) { leftovers(dir, "files").isEmpty() })
            // a program dialog open when the result arrives: the summary waits, the program's dialog is left alone
            r.sh.showDialog(Dialog.confirm("Program", "A program's question", "OK") {})
            r.sh.importFlow.receive(listOf(picked("B17.HC.Z", fixture("B17.HC.Z"))))
            Thread.sleep(1000); r.sh.tick()
            assertTrue("not replaced by the import's summary", r.labels().contains("A program's question"))
            r.sh.back()
            assertTrue("the summary follows", r.waitFor(5.0) { r.labels().contains(tr("import.done.title")) })
        } finally { r.close() }
    }

    // ------------------------------------------------------------ genuine external programs on the interpreter

    private fun closeApp(r: Run, app: App) { r.sh.windows.firstOrNull { it.app === app }?.let { r.sh.close(it, force = true) } }

    /** Opens [path] from Files (tap, Run), the way a user runs any file. */
    private fun runFromFiles(r: Run, path: String): ProgramApp {
        Launch.files(r.sh, Paths.parent(path))
        val entry = r.sh.fs.stat(path)!!
        r.tap(tr("files.a11y.file_item", "name" to Paths.name(path), "size" to entry.size))
        r.tap(tr("files.menu.run"))
        return r.sh.focused?.app as ProgramApp
    }

    @Test fun genuineExternalProgramsRunFromFilesAndAfterARestart() {
        val dir = tmp()
        var r = Run(dir)
        try {
            r.importFiles(listOf(picked("DiningStars.HC", fixture("DiningStars.HC")), picked("B17.HC.Z", fixture("B17.HC.Z")),
                picked("Span.zip", fixture("Span.zip")), picked("Sup1Snd.zip", fixture("Sup1Snd.zip")), picked("NewOS.HC.Z", fixture("NewOS.HC.Z"))))
            assertTrue(r.labels().joinToString(" | "), r.labels().contains(tr("import.done.title")))
            r.tap(tr("button.close"))
            // Test A: a plain external .HC prints its instructions and draws
            val dining = runFromFiles(r, "C:/Home/Imports/DiningStars.HC")
            assertTrue(dining.kernel.console.plainText(), r.waitFor(30.0) { dining.kernel.console.plainText().contains("Draw Floor Plan") && dining.kernel.graphicsUsed })
            assertNull(dining.kernel.exitCategory)
            closeApp(r, dining)
            // Test B: an 8-bit-LZW .HC.Z with DolDoc sprites runs its animation
            val b17 = runFromFiles(r, "C:/Home/Imports/B17.HC")
            assertTrue("B17 draws", r.waitFor(30.0) { b17.kernel.graphicsUsed && b17.kernel.frameCount >= 10 })
            closeApp(r, b17)
            // Test C: a program in folders from an archive of TempleOS-compressed files: Run.HC includes Load.HC, which
            // includes Span.HH and four .HC siblings (Cd(__DIR__) and relative #include), all from C:/Home/Imports/Span
            assertEquals(listOf("Install.HC", "Load.HC", "Run.HC", "Span.HH", "SpanBridge.HC", "SpanDerive.HC", "SpanMain.HC", "SpanNew.HC"),
                r.sh.fs.list("C:/Home/Imports/Span")!!.map { it.name }.sorted())
            val span = runFromFiles(r, "C:/Home/Imports/Span/Run.HC")
            assertTrue(span.kernel.console.plainText(), r.waitFor(30.0) { span.kernel.graphicsUsed && span.kernel.frameCount >= 10 })
            assertNull(span.kernel.console.plainText(), span.kernel.exitCategory)
            for (sym in listOf("Span", "SpanBridge1Init", "MyDerivative", "SpanDel")) assertNotNull("$sym not compiled from a sibling", span.kernel.prog.globals[sym])
            closeApp(r, span)
            // Test D: genuine programs that need what the interpreter does not have: imported fine, a clear message, app usable.
            // MakeSnd.HC's siblings resolve (three compile) until SndFile.HC uses HD Audio's `snd`
            val snd = runFromFiles(r, "C:/Home/Imports/Sup1Snd/MakeSnd.HC")
            assertTrue(snd.kernel.console.plainText(), r.waitFor(30.0) { snd.kernel.finished })
            assertEquals(ExitCategory.COMPILE_ERROR, snd.kernel.exitCategory)
            assertTrue(snd.kernel.console.plainText(), snd.kernel.console.plainText().contains("C:/Home/Imports/Sup1Snd/SndFile.HC:33: undefined identifier 'snd'"))
            closeApp(r, snd)
            val newOS = runFromFiles(r, "C:/Home/Imports/NewOS.HC")
            assertTrue(r.waitFor(30.0) { newOS.kernel.finished })
            assertEquals(ExitCategory.COMPILE_ERROR, newOS.kernel.exitCategory)
            assertTrue(newOS.kernel.console.plainText(), newOS.kernel.console.plainText().contains("inline x86 assembly"))
            r.close()
            // restart: a new shell over the same storage finds and runs them again
            r = Run(dir)
            assertEquals(listOf("B17.HC", "DiningStars.HC", "NewOS.HC", "Span", "Sup1Snd"), r.sh.fs.list("C:/Home/Imports")!!.map { it.name }.sorted())
            val again = runFromFiles(r, "C:/Home/Imports/B17.HC")
            assertTrue("B17 after a restart", r.waitFor(30.0) { again.kernel.graphicsUsed && again.kernel.frameCount >= 10 })
        } finally { r.close() }
    }

    @Test fun anEndlessImportedProgramCanBeStopped() {
        val dir = tmp(); val r = Run(dir)
        try {
            r.importFiles(listOf(picked("Spin.HC", bytes("I64 i=0;\nwhile (TRUE) i++;\n"))))
            r.tap(tr("button.run"))
            val p = r.sh.focused?.app as ProgramApp
            Thread.sleep(1000); r.sh.tick()
            assertFalse("still spinning", p.isFinished)
            val w = r.sh.windows.first { it.app === p }
            r.sh.close(w, force = true)
            assertTrue("closing the window stops the interpreter", r.waitFor(5.0) { p.isFinished })
            Launch.terminal(r.sh); assertEquals("the app is usable afterwards", "terminal", r.sh.focused?.app?.kind)
        } finally { r.close() }
    }
}
