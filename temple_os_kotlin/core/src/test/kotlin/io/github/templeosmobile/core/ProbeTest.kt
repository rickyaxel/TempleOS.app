package io.github.templeosmobile.core

import org.junit.Test

class ProbeTest {
    @Test
    fun probe() {
        if (System.getProperty("templeos.debug") != "true") return
        val src = System.getProperty("templeos.probe") ?: return
        val k = runHolyC(java.io.File(src).readBytes())
        println("OUT:\n" + k.console.plainText())
    }
}
