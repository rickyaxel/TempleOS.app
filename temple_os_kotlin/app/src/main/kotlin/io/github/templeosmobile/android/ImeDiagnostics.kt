package io.github.templeosmobile.android

import android.util.Log
import io.github.templeosmobile.core.ui.Shell

/** Diagnostic only. No InputMethodManager, editable bridge or software input session exists. */
class ImeDiagnostics(private val shell: Shell) {
    var violations = 0
        private set
    var connectionProbes = 0
        private set
    var lifecycle = "created"
    private var wasVisible = false

    fun connectionProbe() { connectionProbes++ }
    fun observe(visible: Boolean, hasWindowFocus: Boolean) {
        if (visible && !wasVisible && hasWindowFocus) {
            violations++
            Log.e("TempleOSInput", "IME invariant violation: target=${shell.inputTarget} generation=${shell.inputGeneration} lifecycle=$lifecycle focus=$hasWindowFocus")
        }
        wasVisible = visible && hasWindowFocus
    }
    val state get() = "nativeImeViolations=$violations;connectionProbes=$connectionProbes;inputTarget=${shell.inputTarget};inputGeneration=${shell.inputGeneration};templeKeyboard=${if (shell.templeKeyboardShown) 1 else 0}"
}
