package io.github.templeosmobile.purekotlin

import io.github.templeosmobile.core.bench.ScenarioHash
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.awt.image.BufferedImage
import javax.imageio.ImageIO

/** Real source, scheduler, renderer and audio. Native runs must execute zero bytecode instructions. */
class GamesPreservationTest {
    private val out = File("build/games-preservation").also { it.mkdirs() }
    private fun shot(k: Kernel, name: String) {
        val img = BufferedImage(640,480,BufferedImage.TYPE_INT_RGB)
        for (y in 0 until 480) for (x in 0 until 640) img.setRGB(x,y,k.palette[k.published[y*640+x].toInt() and 15])
        ImageIO.write(img,"png",File(out,"$name.png"))
    }
    @Test fun waterFowlBothModesAndReopening() {
        val fixture = Json.parse(File(SHARED,"test-vectors/audio/waterfowl.json").readText()) as Map<*,*>
        val expected = (fixture["frequencies"] as List<*>).map { (it as Number).toDouble() }
        val events = (fixture["events"] as List<*>).map { (it as List<*>)[0] as Number }.map { it.toLong() }
        val runs = ArrayList<String>()
        for (engine in listOf(Engine.TERRY,Engine.NATIVE,Engine.TERRY,Engine.NATIVE)) {
            val (k, env) = bootProgram("C:/Demo/Snd/WaterFowl.HC",engine)
            try {
                val frames = ArrayList<Long>()
                for (ms in 0L..19000L step 20) {
                    advanceTo(k,ms)
                    assertFalse("$engine at $ms: ${k.exitMessage}; ${k.console.plainText()}",k.finished)
                    if (ms in listOf(1000L,4000L,10000L,19000L)) { frames.add(ScenarioHash.fnv(k.published)); shot(k,"waterfowl-${engine.name}-$ms") }
                }
                assertTrue(k.graphicsUsed)
                assertTrue("scenery rendered",k.published.toSet().size >= 7)
                assertEquals(4,frames.distinct().size)
                val sounds = env.sound.dropWhile { it.second == 0.0 }.take(expected.size)
                assertEquals("two complete melodies",expected.size,sounds.size)
                for (i in expected.indices) {
                    assertEquals("tone $i",expected[i],sounds[i].second,1e-9)
                    val expectedNs = ((events[i] * 1192.0 * 1e9) / 1193182).toLong()
                    assertTrue("note timing $i",kotlin.math.abs(sounds[i].first - sounds[0].first - expectedNs) < 5_000_000)
                }
                if (engine == Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted)
                val signature = frames.joinToString(",") + ":" + sounds.joinToString { "${it.first}:${it.second.toRawBits()}" }
                runs.add(signature)
                File(out,"waterfowl-${engine.name}.json").writeText("{\"frames\":[${frames.joinToString()}],\"sounds\":[${env.sound.joinToString { "[${it.first},${it.second}]" }}],\"instructions\":${k.vm.instructionsExecuted}}")
                // Use the real PC-speaker PCM renderer, not just sound-call mocks.
                val sp = PcSpeaker(48000,0)
                val base = sounds[0].first
                for ((at,hz) in sounds.filter { it.first - base < 2_000_000_000 }) sp.post(1_000_000_000 + at - base,hz)
                sp.post(3_100_000_000,0.0)
                val pcm = FloatArray(48000 * 23 / 10)
                var at = 0
                while (at < pcm.size) { val n=minOf(256,pcm.size-at); sp.render(pcm,at,n,1_000_000_000 + at*1_000_000_000L/48000);at+=n }
                assertTrue("audible PCM",pcm.any { kotlin.math.abs(it)>0.05 })
                assertTrue("PCM is silent after stop",pcm.takeLast(4800).all { it == 0f })
                File(out,"waterfowl-${engine.name}.pcm").outputStream().use { stream ->
                    val b=java.nio.ByteBuffer.allocate(pcm.size*4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    pcm.forEach { b.putFloat(it) };stream.write(b.array())
                }
                // Any character exits, kills SongTask through SettingsPop, restores draw_it, silences sound.
                val (ch,sc)=Keys.forChar('x'.code)
                k.post(KInput.Key(ch,sc,true));k.post(KInput.Key(ch,sc or Keys.SCF_KEY_UP,false))
                advanceTo(k,19500)
                assertTrue("GetChar exits",k.finished)
                assertTrue("song task cleaned up",k.tasks.isEmpty())
                assertEquals(0.0,env.sound.last().second,0.0)
            } finally { k.terminate("test cleanup") }
        }
        runs.drop(1).forEach { assertEquals("modes and reopening",runs.first(),it) }
    }
    @Test fun waterFowlFullScrollCycle() {
        val signatures=ArrayList<List<Long>>()
        for (engine in Engine.entries) {
            val (k,env)=bootProgram("C:/Demo/Snd/WaterFowl.HC",engine)
            try {
                val frames=ArrayList<Long>()
                for (ms in listOf(64000L,66000L)) {
                    advanceTo(k,ms);assertFalse(k.exitMessage,k.finished)
                    frames.add(ScenarioHash.fnv(k.published));shot(k,"waterfowl-full-${engine.name}-$ms")
                }
                assertNotEquals("poem scroll wraps",frames[0],frames[1]);assertTrue(env.sound.count { it.second>0 }>200)
                if (engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted)
                signatures.add(frames)
                File(out,"waterfowl-full-${engine.name}.json").writeText("{\"frames\":[${frames.joinToString()}],\"soundEvents\":${env.sound.size},\"instructions\":${k.vm.instructionsExecuted}}")
                val (ch,sc)=Keys.forChar('x'.code);k.post(KInput.Key(ch,sc,true));advanceTo(k,66500)
                assertTrue(k.finished);assertEquals(0.0,env.sound.last().second,0.0)
            } finally {k.terminate("test cleanup")}
        }
        assertEquals(signatures[0],signatures[1])
    }
    @Test fun additionalSoundAndSpritePrograms() {
        for (path in listOf("C:/Demo/Snd/ASCIIOrgan.HC","C:/Demo/Snd/OhGreat.HC","C:/Demo/Graphics/SpritePlot.HC","C:/Demo/Graphics/SpritePutExt.HC","C:/Demo/Graphics/Blot.HC","C:/Demo/Graphics/SpritePut.HC","C:/Demo/Graphics/SpriteRaw.HC","C:/Demo/Graphics/EdSprite.HC")) {
            val signatures=ArrayList<String>()
            for (engine in Engine.entries) {
                val (k,env)=bootProgram(path,engine)
                try {
                    advanceTo(k,1000)
                    assertNull("$path $engine: ${k.console.plainText()}",k.exitMessage)
                    val waitsForKey = path.endsWith("SpritePlot.HC") || path.endsWith("Blot.HC")
                    if (waitsForKey) {
                        shot(k,path.substringAfterLast('/').substringBefore('.')+"-"+engine.name)
                        advanceTo(k,4000)
                        val (ch,sc)=Keys.forChar('x'.code);k.post(KInput.Key(ch,sc,true));advanceTo(k,4500)
                        assertTrue("original PressAKey exits: $path",k.finished)
                    }
                    if (path.contains("ASCIIOrgan")) {
                        for (c in listOf('A','z')) { val (ch,sc)=Keys.forChar(c.code);k.post(KInput.Key(ch,sc,true));k.post(KInput.Key(ch,sc or Keys.SCF_KEY_UP,false));advanceTo(k,k.now()/1_000_000+100) }
                        assertTrue(env.sound.count { it.second>0 }>=2)
                        val (ch,sc)=Keys.special(Keys.SC_ESC);k.post(KInput.Key(ch,sc,true));advanceTo(k,1600)
                        assertTrue(k.finished);assertEquals(0.0,env.sound.last().second,0.0)
                        val link=k.console.spriteLinks(80).single()
                        val action=io.github.templeosmobile.core.ui.OriginalProgramLink.parse(link.format,"C:/Demo/Snd")!!
                        assertEquals("C:/Apps/Psalmody/Run.HC",action.path);assertEquals("Click for better organ",action.label)
                    }
                    if (path.contains("OhGreat")) assertTrue(env.sound.any { it.second>0 })
                    if (engine==Engine.NATIVE) assertEquals(0L,k.vm.instructionsExecuted)
                    if (!waitsForKey) shot(k,path.substringAfterLast('/').substringBefore('.')+"-"+engine.name)
                    signatures.add("${ScenarioHash.fnv(k.published)}:${k.console.plainText()}:${env.sound}")
                } finally { k.terminate("test cleanup") }
            }
            assertEquals(path,signatures[0],signatures[1])
        }
    }
}
