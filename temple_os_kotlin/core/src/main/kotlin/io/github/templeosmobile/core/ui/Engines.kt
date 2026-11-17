package io.github.templeosmobile.core.ui

import io.github.templeosmobile.core.purenative.NativeBinding
import io.github.templeosmobile.core.purenative.NativePrograms

/**
 * The two ways a bundled program can run on Android:
 *
 * - **Pure Terry**: Terry A. Davis' HolyC compiled and interpreted on the device (every program,
 *   including the user's own HolyC);
 * - **Pure Kotlin**: the program's ahead-of-time translation to Kotlin (purenative), for the bundled
 *   programs that have one, unchanged since translation.
 *
 * Pure Kotlin is the default ([Settings.ENGINE_DEFAULT]): until an engine is chosen in Settings, a
 * program the native engine cannot run (the user's own HolyC, an edited bundled file, a build
 * without translations) runs in Pure Terry without asking.
 *
 * A choice is explicit: a program the native engine cannot run is never quietly run on the
 * interpreter under the native name; the user is told why and can run it in Pure Terry.
 */
object Engines {
    /** Names of the engines (proper names: the same in every language). */
    const val TERRY_NAME = "Pure Terry"
    const val NATIVE_NAME = "Pure Kotlin"

    /** True when this build contains translated programs. */
    val nativeAvailable get() = NativePrograms.catalog != null

    /** True when [st] selects the native engine: chosen in Settings, or the default in a build that has it. */
    fun selectsNative(st: Settings) = st.engine == Settings.ENGINE_NATIVE || (st.engine == Settings.ENGINE_DEFAULT && nativeAvailable)

    /** Why [path] cannot run natively (a localization key), or null when its translation can run. */
    fun unavailableReason(shell: Shell, path: String): String? {
        val cat = NativePrograms.catalog ?: return "engine.reason.untranslated"
        val img = NativePrograms.find(path) ?: return "engine.reason.untranslated"
        if (img.requiresTerry != null) return "engine.reason.${img.requiresTerry}"
        if (NativePrograms.staleReason(img, shell.fs) != null) return "engine.reason.changed"
        if (cat.programs.isEmpty()) return "engine.reason.untranslated"
        return null
    }

    /** The binding that runs [path] natively, or null (check [unavailableReason] first). */
    fun binding(path: String): NativeBinding? {
        val cat = NativePrograms.catalog ?: return null
        val img = NativePrograms.find(path) ?: return null
        return NativeBinding(cat.prelude, img)
    }
}
