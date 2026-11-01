// Pure Kotlin mode: the bundled TempleOS HolyC programs translated ahead of time to Kotlin by
// :translator (sources in src/main/kotlin/.../gen are generated; do not edit them). Pure JVM, like
// :core, so the translations are tested on the JVM against the interpreter (differential tests).
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        // generated code: thousands of suppressed-by-design warnings (unused temporaries, unreachable epilogues)
        suppressWarnings.set(true)
    }
}

dependencies {
    implementation(project(":core"))
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    systemProperty("templeos.shared", rootProject.projectDir.resolve("../shared").absolutePath)
    systemProperty("templeos.reference", rootProject.projectDir.resolve("../reference").absolutePath)
    System.getProperties().filter { it.key.toString().startsWith("templeos.") && it.key != "templeos.shared" && it.key != "templeos.reference" }
        .forEach { systemProperty(it.key.toString(), it.value) }
    maxHeapSize = "3g"
    // HotSpot does not JIT methods over 8000 bytecodes by default, and the interpreter's Vm.exec is one:
    // without this flag the host benchmark would compare JIT-compiled native code with an unJITted VM
    jvmArgs("-Xss16m", "-XX:-DontCompileHugeMethods")
    // profiling: -Dtempleos.jfr=/path/out.jfr records a JFR method-sampling profile (as in :core)
    System.getProperty("templeos.jfr")?.let { jvmArgs("-XX:StartFlightRecording=filename=$it,settings=profile") }
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
