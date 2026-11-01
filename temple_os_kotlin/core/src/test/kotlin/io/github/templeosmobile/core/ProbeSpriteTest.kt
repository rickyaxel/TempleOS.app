package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import org.junit.Test

/** Diagnostic: SpriteSize on each embedded binary of one file (-Dtempleos.probe=Apps/Titanium/Titanium.HC). */
class ProbeSpriteTest {
    @Test fun probe() {
        val rel = System.getProperty("templeos.probe") ?: return
        val k = Kernel(TestEnv(), "probe").also { it.boot() }
        val f = java.io.File(SHARED, "bundled-fs/$rel")
        val src = io.github.templeosmobile.core.holyc.SourceFile.parse(f.name, f.readBytes())
        for ((num, bin) in src.bins.toSortedMap()) {
            val a = k.mem.malloc(bin.size + 64L); k.mem.fill(a, 0, bin.size + 64); k.mem.writeBytes(a, bin)
            val types = StringBuilder()
            val n = try { k.callHolyC("SpriteSize", a.toLong()).toString() } catch (e: Exception) { "ERR ${e.message}" }
            val h = try { k.callHolyC("SpriteSize_HC", a.toLong()).toString() } catch (e: Exception) { "ERR ${e.message}" }
            for (i in 0 until minOf(bin.size, 12)) types.append("%02x ".format(bin[i]))
            println("bin $num size=${bin.size} native=$n hc=$h first=$types")
        }
    }
}
