// Pure Kotlin/JVM module: HolyC runtime, virtual filesystem, TempleOS window
// system and applications. No Android dependencies, so it is unit-tested on the JVM.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

// Shared, platform-neutral resources (prelude, font, bundled filesystem).
sourceSets["test"].resources.srcDir("../../shared")

dependencies {
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    systemProperty("templeos.shared", rootProject.projectDir.resolve("../shared").absolutePath)
    systemProperty("templeos.reference", rootProject.projectDir.resolve("../reference").absolutePath)
    System.getProperties().filter { it.key.toString().startsWith("templeos.") && it.key != "templeos.shared" && it.key != "templeos.reference" }
        .forEach { systemProperty(it.key.toString(), it.value) }
    maxHeapSize = "2g"
    // profiling (PerfTest): -Dtempleos.jfr=/path/out.jfr records a JFR method-sampling profile
    System.getProperty("templeos.jfr")?.let { jvmArgs("-XX:StartFlightRecording=filename=$it,settings=profile") }
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
