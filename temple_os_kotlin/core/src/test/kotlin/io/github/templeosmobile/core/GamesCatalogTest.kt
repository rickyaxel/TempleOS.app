package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import io.github.templeosmobile.core.kernel.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO
import java.awt.image.BufferedImage

class GamesCatalogTest {
    private fun menu() = OriginalGamesMenu.parse(File(SHARED,"runtime/games-menu/menu.json").readText())
    @Test fun exactHistoricalMembershipAndOrdering() {
        val es=menu().entries
        assertEquals(28,es.size)
        assertEquals(listOf("Fun Games","Unfun Games","Code Scraps","Nongames"),es.map { it.category }.distinct())
        assertEquals(listOf(11,7,5,5),es.groupBy { it.category }.values.map { it.size })
        assertEquals(listOf("Titanium","Diamond","Bat","Varoom","FlatTops","Golf","KeepAway","RawHide","X-Caliber","Wenceslas","Lines"),es.take(11).map { it.title })
        assertFalse(es.any { it.programId == "sound.waterfowl" })
    }
    @Test fun everyIconHasExactIndexedDimensionsAndPalette() {
        for (e in menu().entries) {
            val b=File(SHARED,"runtime/${e.asset}").readBytes()
            assertEquals("TOSI",String(b,0,4));assertEquals(8+e.width*e.height,b.size)
            assertEquals(e.width,(b[4].toInt() and 255) or ((b[5].toInt() and 255) shl 8))
            assertEquals(e.height,(b[6].toInt() and 255) or ((b[7].toInt() and 255) shl 8))
            assertTrue(e.asset,b.drop(8).all { it.toInt()==-1 || it.toInt() in 0..15 })
        }
    }
    @Test fun catalogSourcesAndDependenciesAreBundled() {
        val cat=Catalog.parse(File(SHARED,"program-manifests/catalog.json").readText())
        assertEquals(cat.programs.size,cat.programs.map { it.id }.distinct().size)
        assertEquals(cat.programs.size,cat.programs.map { it.path.lowercase() }.distinct().size)
        for (p in cat.programs) assertTrue(p.path,File(SHARED,"bundled-fs/"+p.path.removePrefix("C:/")).isFile)
        val water=cat.byId("sound.waterfowl")!!
        assertEquals("C:/Demo/Snd/WaterFowl.HC",water.path);assertTrue(water.usesGraphics);assertTrue("sound" in water.capabilities)
        assertEquals("sound",water.category)
        assertFalse(cat.byId("sound.morsecode")!!.unsupported)
    }
    @Test fun soundDirectoryIsCompleteAndInstrumentsRequestOurKeyboard() {
        val cat=Catalog.parse(File(SHARED,"program-manifests/catalog.json").readText())
        val sources=File(SHARED,"bundled-fs/Demo/Snd").listFiles()!!.filter {it.extension=="HC"}.map {"C:/Demo/Snd/"+it.name}.toSet()
        assertEquals(sources,cat.programs.filter {it.path.startsWith("C:/Demo/Snd/")}.map {it.path}.toSet())
        assertEquals(setOf("sound.asciiorgan","sound.morsecode","app.psalmody","original.jukebox","source.demo.keybitmap"),cat.programs.filter {it.prefersFullKeyboard}.map {it.id}.toSet())
    }
    @Test fun responsivePageAndRealLaunchRestoration() {
        val dir=kotlin.io.path.createTempDirectory("games-catalog").toFile()
        val sh=Shell(HeadlessEnv(dir))
        try {
            sh.resize(402,874,62,34);Launch.games(sh);sh.tick()
            for ((w,h) in listOf(402 to 874,874 to 402,360 to 800,800 to 360,640 to 400,300 to 760,160 to 240)) {
                sh.resize(w,h,0,0);sh.tick()
                for (n in sh.accessibilityNodes().filter { it.button && it.label in listOf(tr("games.original"),tr("games.catalog"),"BlackDiamond","WaterFowl") })
                    assertTrue("${n.label} $w x $h ${n.rect}",n.rect.x>=0 && n.rect.y>=0 && n.rect.right<=w && n.rect.bottom<=h)
            }
            sh.resize(402,874,62,34);sh.tick()
            val tab=sh.accessibilityNodes().first { it.label==tr("games.catalog") }.rect
            sh.focused!!.app.tap(tab.x+tab.w/2,tab.y+tab.h/2,tab);sh.tick()
            val water=sh.accessibilityNodes().first { it.label=="WaterFowl" }.rect
            sh.focused!!.app.tap(water.x+water.w/2,water.y+water.h/2,water);sh.tick()
            assertEquals("program",sh.focused!!.app.kind)
            assertEquals("C:/Demo/Snd/WaterFowl.HC",sh.focused!!.app.saveState()["path"])
            val state=sh.windows.first { it.app.kind=="games" }.app.saveState()
            val restored=Launch.restore(sh,"games",state)!!
            assertEquals("true",restored.saveState()["catalog"])
        } finally { sh.windows.toList().forEach { it.app.close() };dir.deleteRecursively() }
    }
    @Test fun documentSpriteTransparencyScrollingAndClear() {
        val c=Console();c.insertSprite(byteArrayOf(255.toByte(),4),2,1,0,0)
        c.insertSprite(byteArrayOf(4,4),2,1,Int.MAX_VALUE,Int.MAX_VALUE)
        c.insertSprite(byteArrayOf(4,4),2,1,Int.MIN_VALUE,Int.MIN_VALUE)
        val cells=IntArray(80*60);c.renderCells(cells,80,60,0xf1)
        val frame=ByteArray(640*480) {15};c.renderSprites(frame,640,0,0,80,60)
        assertEquals(15,frame[0].toInt());assertEquals(4,frame[1].toInt())
        c.clear();frame.fill(15);c.renderSprites(frame,640,0,0,80,60);assertTrue(frame.all { it.toInt()==15 })
    }
    @Test fun corruptedGsCannotCrashTheWindowManager() {
        val k=runHolyC(File(SHARED,"test-vectors/holyc/236_GsCorruption.HC").readBytes())
        assertTrue(k.finished);assertTrue(k.console.plainText().contains("done"))
    }
    @Test fun nativeRestoreCannotSubstituteTheInterpreter() {
        val dir=kotlin.io.path.createTempDirectory("games-mode").toFile();val sh=Shell(HeadlessEnv(dir))
        try { assertNull(Launch.restore(sh,"program",mapOf("path" to "C:/Home/Untranslated.HC", "engine" to "native"))) }
        finally { dir.deleteRecursively() }
    }
    @Test fun duplicateCatalogIdsAreRejected() {
        try { Catalog.parse("""{"programs":[{"id":"x","path":"C:/a.HC"},{"id":"x","path":"C:/b.HC"}]}"""); fail("duplicate accepted") }
        catch (_: IllegalArgumentException) {}
    }
    @Test fun capturePageLayouts() {
        val out=File("build/games-preservation").also { it.mkdirs() }
        val dir=kotlin.io.path.createTempDirectory("games-shots").toFile();val sh=Shell(HeadlessEnv(dir))
        try {
            Launch.games(sh)
            for ((w,h) in listOf(402 to 874,874 to 402,360 to 800,640 to 400,300 to 760)) {
                sh.resize(w,h);sh.tick()
                val im=BufferedImage(w,h,BufferedImage.TYPE_INT_RGB)
                for (y in 0 until h) for (x in 0 until w) im.setRGB(x,y,Palette.STD[sh.surface.px[y*w+x].toInt() and 15])
                ImageIO.write(im,"png",File(out,"games-${w}x$h.png"))
            }
        } finally {sh.windows.forEach { it.app.close() };dir.deleteRecursively()}
    }
}
