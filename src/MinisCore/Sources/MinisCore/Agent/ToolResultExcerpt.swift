import Foundation

/// Head/tail excerpt of one tool-result text. Pure value function: no I/O, no
/// global state, never reads a key.
///
/// This is the single shared excerpt function. The request-copy reducer
/// (`RequestContextReducer`, C4) calls it with a larger window and no byte
/// ceiling; the cross-turn tool trace (D batch, D-05) calls it with the
/// defaults below. Both therefore produce the same omission marker line.
///
/// Order of operations: redact -> cut -> redact again. The second pass covers
/// a secret that only becomes recognisable after the cut. Masking keeps the
/// text length, so redaction never changes the cut positions.
public enum ToolResultExcerpt {
    /// Defaults for persisted excerpts (D batch). [assumption, no measurement]
    public static let defaultHeadCharacters = 400
    public static let defaultTailCharacters = 400
    /// Hard UTF-8 ceiling of one persisted excerpt, marker included.
    public static let maximumUTF8Bytes = 2_048

    public struct Result: Sendable, Equatable {
        public let text: String
        /// Characters (grapheme clusters) removed from the middle; 0 when the
        /// text is returned whole.
        public let omittedCharacters: Int
        public init(text: String, omittedCharacters: Int) {
            self.text = text
            self.omittedCharacters = omittedCharacters
        }
    }

    /// The only producer of the marker line.
    public static func omissionMarker(omittedCharacters: Int) -> String {
        "\n…[中间省略 \(omittedCharacters) 字]…\n"
    }

    /// - Parameters:
    ///   - head/tail: characters kept at each end (grapheme-cluster boundaries,
    ///     so an emoji or combining sequence is never cut).
    ///   - maxUTF8Bytes: ceiling for the whole result including the marker;
    ///     `nil` means no byte ceiling. A ceiling smaller than the marker line
    ///     itself is exceeded by the marker (the marker is never truncated).
    ///
    /// Text that already fits is returned (redacted) unchanged with
    /// `omittedCharacters == 0`. A cut that would not make the text shorter is
    /// not made, so calling this on its own output never grows it.
    public static func excerpt(
        _ text: String,
        head: Int = defaultHeadCharacters,
        tail: Int = defaultTailCharacters,
        maxUTF8Bytes: Int? = maximumUTF8Bytes
    ) -> Result {
        let redacted = ContentSecretRedactor.redact(text)
        let characters = Array(redacted)
        let total = characters.count
        let wantedHead = min(max(0, head), total)
        let wantedTail = min(max(0, tail), total - wantedHead)
        let bytesFit = maxUTF8Bytes.map { redacted.utf8.count <= $0 } ?? true
        if wantedHead + wantedTail >= total && bytesFit {
            return Result(text: redacted, omittedCharacters: 0)
        }

        var headCount = wantedHead
        var tailCount = wantedTail
        if let limit = maxUTF8Bytes {
            // Upper bound of the marker: it never has more digits than `total`.
            let markerBytes = omissionMarker(omittedCharacters: total).utf8.count
            let available = max(0, limit - markerBytes)
            let wanted = wantedHead + wantedTail
            let headShare = wanted == 0
                ? 0 : Int(Double(available) * Double(wantedHead) / Double(wanted))
            var headBytes = 0
            headCount = 0
            while headCount < wantedHead {
                let size = String(characters[headCount]).utf8.count
                guard headBytes + size <= headShare else { break }
                headBytes += size
                headCount += 1
            }
            // Bytes the head did not use go to the tail.
            let tailShare = available - headBytes
            var tailBytes = 0
            tailCount = 0
            while tailCount < wantedTail, total - tailCount - 1 >= headCount {
                let size = String(characters[total - tailCount - 1]).utf8.count
                guard tailBytes + size <= tailShare else { break }
                tailBytes += size
                tailCount += 1
            }
        }

        let omitted = total - headCount - tailCount
        guard omitted > 0 else { return Result(text: redacted, omittedCharacters: 0) }
        let cut = String(characters[0..<headCount])
            + omissionMarker(omittedCharacters: omitted)
            + String(characters[(total - tailCount)...])
        if bytesFit, cut.count >= total {
            return Result(text: redacted, omittedCharacters: 0)
        }
        return Result(text: ContentSecretRedactor.redact(cut), omittedCharacters: omitted)
    }
}
