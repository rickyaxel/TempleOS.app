import Foundation

// Port of Brand.kt.

/**
 * The apps' name (README, "Names"). Wherever the apps name themselves (under the icon, the
 * desktop, About, the Terminal banner, messages, `{app}` in every catalog) they say `appName`.
 * It is a proper name and is never translated. "TempleOS" alone always means Terry A. Davis'
 * operating system and is never replaced. The website uses its own name ("TempleOS Mobile App")
 * on purpose; the domain is templeos.app.
 *
 * Source of truth: `app_name` in `shared/runtime/l10n/locales.json` (tests compare).
 */
public enum Brand {
    public static let appName = "TempleOS.app"
    /** Product-required startup copy. Deliberately independent of localization. */
    public static let introLines = ["TempleOS.app", "Tap MENU to begin.", "TempleOS by Terry A. Davis", "Mobile adaptation by Ricky Axel"]
    /** The privacy policy (website /privacy), shown in About: both stores require it inside the app. */
    public static let privacyURL = "https://templeos.app/privacy"
}
