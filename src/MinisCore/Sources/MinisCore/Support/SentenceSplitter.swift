// Historical source: OpenMinis SentenceSplitter; reimplemented from an independent behavior specification.
import Foundation

public enum SentenceSplitter {
    public static let terminators: Set<Character> = Set("。！？；….!?;")

    public static func isTerminator(_ character: Character) -> Bool {
        terminators.contains(character)
    }

    public static func split(_ text: String) -> [String] {
        var beginning = text.startIndex
        var pieces: [String] = []
        let boundaries = text.indices.filter { isTerminator(text[$0]) }
        for boundary in boundaries {
            let end = text.index(after: boundary)
            let piece = text[beginning..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            beginning = end
        }
        let tail = text[beginning...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
