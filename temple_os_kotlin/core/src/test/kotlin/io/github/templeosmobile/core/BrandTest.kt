package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.latin1
import io.github.templeosmobile.core.ui.*
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * The apps' name (README, "Names"): TempleOS.app wherever the apps name themselves, in every
 * language, never translated; "TempleOS" alone (Terry A. Davis' operating system) untouched.
 */
class BrandTest {
    private val repo = SHARED.parentFile
    private val old = Regex("TempleOS[ -]?Mobile", RegexOption.IGNORE_CASE)

    @Suppress("UNCHECKED_CAST")
    private fun manifest() = Json.parse(File(SHARED, "runtime/l10n/locales.json").readText()) as Map<String, Any?>

    @After fun english() { L10n.use("en-US") }

    @Test fun oneNameEverywhereItIsConfigured() {
        assertEquals("TempleOS.app", Brand.APP_NAME)
        assertEquals("manifest app_name", Brand.APP_NAME, manifest()["app_name"])
        val strings = File(repo, "temple_os_kotlin/app/src/main/res/values/strings.xml").readText()
        assertTrue(strings, strings.contains("<string name=\"app_name\" translatable=\"false\">${Brand.APP_NAME}</string>"))
        assertTrue("launcher label uses the resource", File(repo, "temple_os_kotlin/app/src/main/AndroidManifest.xml").readText().contains("android:label=\"@string/app_name\""))
        assertFalse("no translated copies of the label", File(repo, "temple_os_kotlin/app/src/main/res").listFiles()!!.any { it.name.startsWith("values-") })
        val plist = File(repo, "temple_os_swift/App/TempleOSMobile/Info.plist").readText()
        assertTrue(plist, Regex("<key>CFBundleDisplayName</key>\\s*<string>${Regex.escape(Brand.APP_NAME)}</string>").containsMatchIn(plist))
        // the application id is the Google Play listing's package name
        assertTrue(File(repo, "temple_os_kotlin/app/build.gradle.kts").readText().contains("applicationId = \"com.digitalcircuitstudios.templeosapp\""))
    }

    @Test fun everyLanguageShowsTheNameUntranslated() {
        val env = LangEnv(HeadlessEnv(Files.createTempDirectory("brand").toFile()), listOf("en-US"))
        val sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); sh.tick()
        val keys = listOf("fs.error.storage_full", "about.additions.words", "about.credits.native", "catalog.license.project",
            "doc.link_symbol_unsupported", "doc.notice.mobile.title", "doc.notice.mobile.body")
        for (l in L10n.resolver!!.locales) {
            L10n.use(l.id)
            for (k in keys) {
                val t = tr(k, "mib" to 64, "target" to "x")
                assertTrue("${l.id} $k: $t", t.contains(Brand.APP_NAME))
                assertFalse("${l.id} $k: $t", t.contains("{app}") || old.containsMatchIn(t))
            }
            // the original system keeps its name
            assertTrue(l.id, tr("about.credits.templeos").contains("TempleOS"))
        }
        L10n.use("ja-JP")
        assertEquals("console text falls back to English with the same name", "Storage full: ${Brand.APP_NAME} keeps at most 64 MiB of your files",
            L10n.tr8("fs.error.storage_full", "mib" to 64))
    }

    @Test fun theAppsNameThemselves() {
        val env = LangEnv(HeadlessEnv(Files.createTempDirectory("brand").toFile()), listOf("en-US"))
        val sh = Shell(env); sh.resize(320, 480); sh.restoreSession(); sh.tick()
        // About: the heading
        Launch.about(sh); sh.invalidate(); sh.tick()
        val about = sh.accessibilityNodes().filter { !it.button }.joinToString("\n") { it.label }
        assertTrue(about, about.trimStart().startsWith(Brand.APP_NAME))
        assertTrue(about, about.contains("Terry A. Davis"))
        assertFalse(about, old.containsMatchIn(about))
        assertTrue("About links the privacy policy (App Store 5.1.1(i), Play User Data): $about", about.contains(Brand.PRIVACY_URL))
        // Terminal banner
        Launch.terminal(sh)
        val term = sh.focused!!.app as TerminalApp
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline && !term.kernel.console.plainText().contains("Terminal")) { sh.tick(); Thread.sleep(20) }
        val banner = term.kernel.console.plainText()
        assertTrue(banner, banner.contains("${Brand.APP_NAME} Terminal"))
        assertFalse(banner, old.containsMatchIn(banner))
    }

    @Test fun programsSeeTheName() {
        val k = runHolyC(latin1("\"[%s]\\n\",SysPlatformName;\"[%s]\\n\",sys_mobile_platform;MemBIOSRep;\n"))
        val out = k.console.plainText()
        assertTrue(out, out.contains("[${Brand.APP_NAME}]\n[${Brand.APP_NAME}]"))
        assertTrue(out, out.contains("BIOS memory map: not available in ${Brand.APP_NAME}."))
        val asm = runHolyC(latin1("asm {NOP}\n")).console.plainText()
        assertTrue(asm, asm.contains("not supported by ${Brand.APP_NAME}"))
    }
}
