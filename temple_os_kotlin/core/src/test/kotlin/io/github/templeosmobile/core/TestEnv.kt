package io.github.templeosmobile.core

import io.github.templeosmobile.core.kernel.*
import java.io.File

val SHARED: File = File(System.getProperty("templeos.shared") ?: "../../shared")
val REFERENCE: File = File(System.getProperty("templeos.reference") ?: "../../reference")

/** Kernel environment for unit tests: runtime files from shared/, optional fs. */
open class TestEnv(override val fs: VirtualFs? = null) : KernelEnv {
    val sounds = ArrayList<Double>()
    /** (kernel time in ms, frequency) of every tone change, for timing checks. */
    val soundLog = ArrayList<Pair<Long, Double>>()
    override fun runtimeFile(name: String): ByteArray? {
        val f = File(SHARED, "runtime/$name")
        return if (f.exists()) f.readBytes() else null
    }
    /** The atNs of every tone change (KernelEnv.sound), in order. */
    val soundStamps = ArrayList<Long>()
    /** Kernel time (Kernel.now, ns; virtual in virtual-time tests) of every tone change. */
    val soundNowNs = ArrayList<Long>()
    override fun sound(kernel: Kernel, freq: Double, atNs: Long) { sounds.add(freq); soundLog.add(kernel.now() / 1_000_000 to freq); soundStamps.add(atNs); soundNowNs.add(kernel.now()) }
    override fun entropy(): Long = 12345
    override val memoryLimit: Int get() = (System.getProperty("templeos.memmb")?.toIntOrNull() ?: 32) shl 20
    /** Headless popups pick the first (non-cancel) item. */
    override fun popupRequested(kernel: Kernel, req: PopupRequest) { req.result = req.items.firstOrNull { it.value != -1L }?.value ?: -1 }
}

/** Boots a kernel, runs [src] to completion in virtual time, returns the kernel. */
fun runHolyC(src: ByteArray, name: String = "C:/Home/Test.HC", env: TestEnv = TestEnv(), maxSteps: Int = 100000, setup: (Kernel) -> Unit = {}): Kernel {
    val k = Kernel(env, "test")
    k.virtualTime = true
    k.boot()
    setup(k)
    k.runProgram(name, src)
    var steps = 0
    val deadline = System.nanoTime() + 20_000_000_000L
    while (steps++ < maxSteps && System.nanoTime() < deadline) {
        val r = k.step(50_000_000)
        if (r < 0) break
    }
    if (!k.finished) println("runHolyC: not finished after $steps steps; tasks=${k.tasks.map { "${it.name}:${it.state}" }} vtime=${k.now() / 1000000}ms")
    return k
}
