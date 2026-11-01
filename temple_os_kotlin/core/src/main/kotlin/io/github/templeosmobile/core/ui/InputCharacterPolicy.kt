package io.github.templeosmobile.core.ui

import java.text.Normalizer

/** External Unicode and internal TempleOS byte strings are different boundaries. Display localization is independent. */
object InputCharacterPolicy {
    /** Stored source/documents can contain original low-byte controls and metadata. */
    fun isByteBuffer(text: String) = text.all { it.code <= 255 }
    fun isByteText(text: String) = text.all { it == '\n' || it == '\t' || it.code in 32..255 }

    /** Lossless, atomic conversion, with only NFC and CRLF/CR newline normalization. */
    fun encode(text: String, singleLine: Boolean = false): String? {
        val normalized = Normalizer.normalize(text, Normalizer.Form.NFC).replace("\r\n", "\n").replace('\r', '\n')
        val bytes = StringBuilder()
        for (c in normalized) {
            if (c == '\n' || c == '\t') {
                if (singleLine) return null
                bytes.append(c); continue
            }
            val code = Cp437.code(c)
            if (code !in 32..255) return null
            bytes.append(code.toChar())
        }
        return bytes.toString()
    }

    fun display(text: String) = if (text.any { it.code > 255 }) text else Cp437.decode(text)
}
