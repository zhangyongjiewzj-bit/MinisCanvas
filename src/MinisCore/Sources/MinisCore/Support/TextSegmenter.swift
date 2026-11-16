import Foundation

/// Splits long text into chunks of bounded length, preferring sentence
/// boundaries (via `SentenceSplitter`) and hard-cutting sentences that alone
/// exceed `maxLength`. Useful for context-window packing and chunked
/// summarization.
public enum TextSegmenter {

    /// Segment `text` into chunks of at most `maxLength` characters.
    ///
    /// - Sentences shorter than `maxLength` are greedily packed, preserving
    ///   sentence order and trailing punctuation; chunks are joined with a
    ///   single space.
    /// - A sentence longer than `maxLength` is hard-cut on character
    ///   boundaries into pieces of at most `maxLength`.
    /// - Empty / whitespace-only text yields `[]`.
    public static func segment(_ text: String, maxLength: Int) -> [String] {
        guard maxLength > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        for sentence in SentenceSplitter.split(trimmed) {
            if sentence.count > maxLength {
                // Flush the pending chunk, then hard-cut the long sentence.
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                hardCut(sentence, maxLength: maxLength, into: &chunks)
                continue
            }

            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count <= maxLength {
                current = candidate
            } else {
                chunks.append(current)
                current = sentence
            }
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Cut a single over-long sentence on character boundaries.
    private static func hardCut(_ sentence: String, maxLength: Int, into chunks: inout [String]) {
        var start = sentence.startIndex
        while start < sentence.endIndex {
            let end = sentence.index(start, offsetBy: maxLength, limitedBy: sentence.endIndex) ?? sentence.endIndex
            chunks.append(String(sentence[start..<end]))
            start = end
        }
    }
}
