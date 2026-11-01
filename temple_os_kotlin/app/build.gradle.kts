import java.util.Properties

// TempleOS Mobile Classic for Android. Framework-only (no AndroidX, no network
// libraries); all logic lives in the pure-Kotlin :core module.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val shared = rootProject.projectDir.resolve("../shared")
val generatedAssets = layout.buildDirectory.dir("generated/templeAssets")
// recorded in BuildConfig.GIT_REV so device results name the source they were built from
val gitRev: String = try {
    val p = ProcessBuilder("git", "rev-parse", "--short", "HEAD").directory(rootProject.projectDir).start()
    val rev = p.inputStream.bufferedReader().readText().trim()
    val dirty = ProcessBuilder("git", "status", "--porcelain").directory(rootProject.projectDir).start().inputStream.bufferedReader().readText().isNotBlank()
    rev + if (dirty) "-dirty" else ""
} catch (e: Exception) { "unknown" }

// Copies the platform-neutral runtime into the APK asset layout:
//   runtime/*        Prelude, GrLib, KernelClasses, defines, font
//   fs/**            the bundled read-only C: drive
//   bundled-fs.index, catalog.json
val syncTempleAssets by tasks.registering(Sync::class) {
    into(generatedAssets)
    from(shared.resolve("runtime")) { into("runtime") }
    from(shared.resolve("bundled-fs")) { into("fs") }
    from(shared.resolve("bundled-fs.index"))
    from(shared.resolve("program-manifests/catalog.json"))
}

// Release signing uses the owner's upload key, which never enters the repository: Android Studio's
// Build > Generate Signed App Bundle wizard (it passes the key as android.injected.signing.* properties),
// keystore.properties next to settings.gradle.kts (gitignored; storeFile, storePassword, keyAlias,
// keyPassword) or the TEMPLEOS_UPLOAD_* environment variables. Without it, release builds are signed with the local debug
// key so they can be installed for testing, and bundleRelease refuses to build a store bundle
// (Google Play rejects debug-signed uploads) unless -PallowDebugSignedBundle is given for local analysis.
val uploadKey: Map<String, String>? = run {
    val f = rootProject.file("keystore.properties")
    val props = Properties()
    if (f.exists()) f.inputStream().use { props.load(it) }
    fun value(key: String, env: String) = props.getProperty(key) ?: System.getenv(env)
    val m = mapOf(
        "storeFile" to value("storeFile", "TEMPLEOS_UPLOAD_STORE_FILE"),
        "storePassword" to value("storePassword", "TEMPLEOS_UPLOAD_STORE_PASSWORD"),
        "keyAlias" to value("keyAlias", "TEMPLEOS_UPLOAD_KEY_ALIAS"),
        "keyPassword" to value("keyPassword", "TEMPLEOS_UPLOAD_KEY_PASSWORD"),
    )
    if (m.values.all { it != null }) m.mapValues { it.value!! } else null
}

android {
    namespace = "io.github.templeosmobile.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.digitalcircuitstudios.templeosapp"
        minSdk = 24
        targetSdk = 36
        versionCode = 2
        versionName = "1.0.0"
    }

    buildFeatures { buildConfig = true }

    signingConfigs {
        if (uploadKey != null) create("upload") {
            storeFile = rootProject.file(uploadKey.getValue("storeFile"))
            storePassword = uploadKey.getValue("storePassword")
            keyAlias = uploadKey.getValue("keyAlias")
            keyPassword = uploadKey.getValue("keyPassword")
        }
    }

    buildTypes {
        all { buildConfigField("String", "GIT_REV", "\"$gitRev\"") }
        debug { buildConfigField("boolean", "BENCH", "false") }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (uploadKey != null) "upload" else "debug")
            buildConfigField("boolean", "BENCH", "false")
        }
        // Device validation (docs/native-validation): the release build with R8, installed beside the user's
        // app under its own application id (its data is never touched), profileable for Perfetto/simpleperf,
        // with the headless benchmark mode (BenchMode, `--es bench ...`) enabled.
        create("bench") {
            initWith(getByName("release"))
            applicationIdSuffix = ".bench"
            versionNameSuffix = "-bench"
            matchingFallbacks += listOf("release")
            isProfileable = true
            buildConfigField("boolean", "BENCH", "true")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets["main"].assets.srcDir(generatedAssets)

    androidResources {
        // aapt's default pattern drops "_*" directories and dot files; keep every bundled TempleOS file.
        ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:!CVS:!thumbs.db:!picasa.ini:!*~"
        noCompress += listOf("HC", "HH", "DD", "TXT", "Z", "bin", "index", "json")
    }

    dependenciesInfo {
        // No dependency metadata blob in the APK (nothing to report to any service).
        includeInApk = false
        includeInBundle = false
    }

    packaging { resources.excludes += listOf("META-INF/*.kotlin_module", "kotlin/**", "DebugProbesKt.bin") }
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

tasks.named("preBuild") { dependsOn(syncTempleAssets) }

dependencies {
    implementation(project(":core"))
    implementation(project(":purekotlin"))
}

val checkInputArchitecture by tasks.registering(Exec::class) {
    description = "Reject native software IME clients and requests in application-owned source"
    commandLine("python3", rootProject.file("../tools/input-audit/check_input_architecture.py"), "--platform", "android")
}
tasks.named("preBuild") { dependsOn(checkInputArchitecture) }

// A store bundle must carry the upload key (see uploadKey above).
tasks.matching { it.name == "bundleRelease" }.configureEach {
    doFirst {
        if (uploadKey == null && !project.hasProperty("android.injected.signing.store.file") && !project.hasProperty("allowDebugSignedBundle"))
            throw GradleException("bundleRelease needs the upload key: Generate Signed App Bundle, keystore.properties or TEMPLEOS_UPLOAD_* (see app/build.gradle.kts); " +
                "pass -PallowDebugSignedBundle only to inspect a debug-signed bundle locally")
    }
}
