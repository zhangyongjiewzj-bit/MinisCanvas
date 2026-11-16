import Foundation

/// N14's explicit display-control boundary, not a blanket Unicode Cf filter.
/// Join controls, variation selectors, combining marks and ordinary whitespace
/// remain intact. Structurally valid flag tags follow UTS #51 Annex C (without a CLDR registry).
/// https://www.unicode.org/reports/tr51/#Valid_Emoji_Tag_Sequences
/// The Claude interactive-mode documentation specifies categories, not a full
/// scalar list; this is the product's bounded policy, not its claimed internals.
public enum InvisibleCharacterPolicy {
    public static func count(in text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        let preservedTags = emojiTagIndices(scalars)
        return scalars.enumerated().filter { index, scalar in
            isControl(scalar.value) && !preservedTags.contains(index)
        }.count
    }

    public static func notice(in texts: [String]) -> String? {
        let count = texts.reduce(0) { $0 + self.count(in: $1) }
        guard count > 0 else { return nil }
        let values = Set(texts.flatMap { markerCodePoints(in: $0) }).sorted()
        return "含 \(count) 个不可见字符：" + values.map(marker).joined(separator: " ")
    }

    /// Display only: callers retain canonical/copy/model text separately.
    public static func visible(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let preservedTags = emojiTagIndices(scalars)
        return scalars.enumerated().map { index, scalar in
            isControl(scalar.value) && !preservedTags.contains(index)
                ? marker(scalar.value) : String(scalar)
        }.joined()
    }

    /// Large outputs already hidden by O13 expose only distinct code points,
    /// never their surrounding untrusted text or a new raw prefix.
    public static func markerInventory(_ text: String) -> String {
        markerCodePoints(in: text).map(marker).joined(separator: " ")
    }

    public static func markerCodePoints(in text: String) -> [UInt32] {
        let scalars = Array(text.unicodeScalars)
        let preservedTags = emojiTagIndices(scalars)
        return Set(scalars.enumerated().compactMap { index, scalar in
            isControl(scalar.value) && !preservedTags.contains(index) ? scalar.value : nil
        }).sorted()
    }

    public static func marker(_ value: UInt32) -> String {
        "⟦U+" + String(format: "%04X", value) + "⟧"
    }

    private static func isControl(_ value: UInt32) -> Bool {
        switch value {
        case 0x061C, 0x200B, 0x200E, 0x200F, 0x202A...0x202E,
             0x2060, 0x2066...0x2069, 0xFEFF, 0xE0000...0xE007F:
            return true
        default: return false
        }
    }

    private static func emojiTagIndices(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        // UTS #51 C.1 / UTS #35 syntax: black flag + 3-digit region or
        // 2-letter region + 1–3 lowercase letters/digits + CANCEL TAG. Hidden tag prose
        // (including standalone TAG LATIN CAPITAL LETTER A) is never exempt.
        var preserved = Set<Int>()
        for start in scalars.indices where scalars[start].value == 0x1F3F4 {
            var end = start + 1
            while end < scalars.count, (0xE0020...0xE007E).contains(scalars[end].value) {
                end += 1
            }
            let length = end - start - 1
            guard (3...5).contains(length), end < scalars.count,
                  scalars[end].value == 0xE007F else { continue }
            let values = scalars[(start + 1)..<end].map(\.value)
            let numericRegion = length == 3 && values.allSatisfy { (0xE0030...0xE0039).contains($0) }
            let subdivision = values.prefix(2).allSatisfy { (0xE0061...0xE007A).contains($0) }
                && values.dropFirst(2).allSatisfy { (0xE0061...0xE007A).contains($0) || (0xE0030...0xE0039).contains($0) }
            guard numericRegion || subdivision else { continue }
            preserved.formUnion((start + 1)...end)
        }
        return preserved
    }
}
