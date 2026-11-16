import Foundation

/// Deterministic local replacement for token budgeting.
///
/// This intentionally does not load a vocabulary, inspect the development
/// filesystem, or claim provider-billing tokenization. The estimate is stable
/// across clean checkouts and is used for budgeting, truncation, and display.
public final class TokenCounter: @unchecked Sendable {

    public static let shared = TokenCounter()

    private init() {}

    // MARK: - Public API

    public func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
                continue
            }

            if isCJKIdeograph(scalar) {
                count += 1
                inWord = false
                continue
            }

            // Combining marks belong to the preceding grapheme and should not
            // create an extra budget unit.
            if isCombiningMark(scalar) {
                continue
            }

            if CharacterSet.letters.contains(scalar) ||
                CharacterSet.decimalDigits.contains(scalar) {
                if !inWord {
                    count += 1
                    inWord = true
                }
                continue
            }

            // Punctuation, symbols, and emoji are counted individually so
            // budget growth remains predictable for non-word content.
            count += 1
            inWord = false
        }

        return count
    }

    private func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F,
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x20D0...0x20FF,
             0xFE00...0xFE0F,
             0xFE20...0xFE2F,
             0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }
}
