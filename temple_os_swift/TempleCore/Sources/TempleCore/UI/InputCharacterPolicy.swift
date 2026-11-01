import Foundation

/** Boundary between external Unicode and TempleOS byte strings. Display localization is independent. */
public enum InputCharacterPolicy {
    /** Stored TempleOS source/documents may contain low-byte metadata and graphic controls. */
    public static func isByteBuffer(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { $0.value <= 255 } }
    /** Byte strings may include line feed and tab; command/control keys use key events instead. */
    public static func isByteText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || (32...255).contains($0.value) }
    }

    /** Atomic, lossless conversion. NFC and newline normalization are the only transformations. */
    public static func encode(_ text: String, singleLine: Bool = false) -> String? {
        let normalized = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var bytes = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                if singleLine { return nil }
                bytes.append(scalar); continue
            }
            let code = Cp437.code(scalar)
            guard code >= 32 && code <= 255 else { return nil }
            bytes.append(Unicode.Scalar(code)!)
        }
        return String(bytes)
    }

    /** Legacy Unicode drafts stay readable; byte-oriented buffers use the existing CP437 display bridge. */
    public static func display(_ text: String) -> String {
        text.unicodeScalars.contains { $0.value > 255 } ? text : Cp437.decode(text)
    }
}
