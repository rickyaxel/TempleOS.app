package io.github.templeosmobile.core

/**
 * The apps' name (README, "Names"). Wherever the apps name themselves (under the icon, the
 * desktop, About, the Terminal banner, messages, `{app}` in every catalog) they say
 * [APP_NAME]. It is a proper name and is never translated. "TempleOS" alone always means Terry
 * A. Davis' operating system and is never replaced. The website uses its own name ("TempleOS
 * Mobile App") on purpose; the domain is templeos.app.
 *
 * Source of truth: `app_name` in `shared/runtime/l10n/locales.json` (tests compare).
 */
object Brand {
    const val APP_NAME = "TempleOS.app"
    /** Product-required startup copy. Deliberately independent of localization. */
    val INTRO_LINES = listOf("TempleOS.app", "Tap MENU to begin.", "TempleOS by Terry A. Davis", "Mobile adaptation by Ricky Axel")
    /** The privacy policy (website /privacy), shown in About: both stores require it inside the app. */
    const val PRIVACY_URL = "https://templeos.app/privacy"
}
