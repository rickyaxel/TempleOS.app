package io.github.templeosmobile.core

import io.github.templeosmobile.core.ui.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class AboutPrivacyTest {
    @Test fun privacyIsAnAccessibleActionThatStaysVisibleAfterScrollingAndResizing() {
        val dir = Files.createTempDirectory("about-privacy").toFile()
        try {
            val base = HeadlessEnv(dir)
            var opened = 0
            val env = object : ShellEnv by base {
                override fun openPrivacyPolicy() { opened++ }
            }
            val sh = Shell(env)
            sh.resize(320, 480); sh.restoreSession()
            Launch.about(sh); sh.tick()
            val app = sh.focused!!.app
            val rect = Rect(0, 0, 640, 480)
            app.tap(-1, -1, rect)
            assertEquals("unrelated taps never open the browser", 0, opened)
            for ((w, h) in listOf(320 to 480, 640 to 360)) {
                sh.resize(w, h); app.scroll(0, -10000, rect); sh.tick()
                val button = sh.accessibilityNodes().single { it.button && it.label.contains(Brand.PRIVACY_URL) }
                assertTrue(button.label, button.label.contains(tr("about.privacy.title")))
                assertTrue(button.rect.w > 0 && button.rect.h > 0)
                app.tap(button.rect.x + button.rect.w / 2, button.rect.y + button.rect.h / 2, rect)
            }
            assertEquals("each explicit activation invokes the fixed platform action once", 2, opened)
        } finally {
            L10n.use("en-US")
            dir.deleteRecursively()
        }
    }
}
