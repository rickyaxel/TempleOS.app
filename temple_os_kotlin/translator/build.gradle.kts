// Build-time HolyC -> Swift/Kotlin translator (docs/native-translation). Reuses the
// :core compiler front end (lexer, parser, typed AST) and never ships in the apps.
plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))
    testImplementation("junit:junit:4.13.2")
}

application {
    mainClass.set("io.github.templeosmobile.translator.MainKt")
    applicationDefaultJvmArgs = listOf("-Xss64m", "-Xmx2g")
}

tasks.named<JavaExec>("run") {
    workingDir = rootProject.projectDir.resolve("..")
    systemProperty("templeos.repo", rootProject.projectDir.resolve("..").absolutePath)
}

tasks.test {
    systemProperty("templeos.repo", rootProject.projectDir.resolve("..").absolutePath)
    maxHeapSize = "2g"
    jvmArgs("-Xss64m")
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
