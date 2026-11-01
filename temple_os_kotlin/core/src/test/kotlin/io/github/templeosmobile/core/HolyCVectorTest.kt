package io.github.templeosmobile.core

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Runs every shared/test-vectors/holyc/NAME.HC and compares console output. */
class HolyCVectorTest {
    @Test
    fun vectors() {
        val dir = File(SHARED, "test-vectors/holyc")
        val files = dir.listFiles { f -> f.name.endsWith(".HC") }!!.sortedBy { it.name }
        assertTrue(files.isNotEmpty())
        val failures = ArrayList<String>()
        for (f in files) {
            val text = f.readText(Charsets.ISO_8859_1)
            val expIdx = text.indexOf("//EXPECT:")
            val expected = if (expIdx < 0) "" else text.substring(expIdx + 9).lines().drop(1)
                .filter { it.startsWith("//") }.joinToString("\n") { it.removePrefix("//") }
            val expErr = Regex("//EXPECT-ERROR: (.*)").find(text)?.groupValues?.get(1)?.trim()
            val k = runHolyC(f.readBytes(), "C:/Home/${f.name}")
            val out = k.console.plainText().trimEnd('\n')
            // a vector must run to completion (not merely print the expected text and hang)
            if (!k.finished) failures.add("${f.name}: did not finish")
            var got = out
            if (expErr != null) {
                if (!out.contains(expErr)) failures.add("${f.name}: expected error '$expErr' but output was:\n$out")
                got = out.lines().filterNot { it.contains(expErr) || it.isBlank() }.joinToString("\n")
            }
            if (got.trimEnd() != expected.trimEnd()) {
                failures.add("${f.name}:\n--- expected\n$expected\n--- got\n$got")
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n\n"))
    }
}
