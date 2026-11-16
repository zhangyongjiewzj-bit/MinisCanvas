import Foundation

/// Incrementally consumes UTF-8-safe text chunks without repeatedly deleting
/// from the front of a long `String`.
///
/// The consumer keeps a cursor into the existing storage. The common path
/// drains one provider delta before the next delta arrives, so storage is
/// reused and the front of a long response is never shifted per character.
struct ChatStreamTextBuffer {
    private var storage = ""
    private var cursor: String.Index?

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }

        if let cursor {
            if cursor < storage.endIndex {
                storage = String(storage[cursor...])
            } else {
                storage.removeAll(keepingCapacity: true)
            }
        }
        storage.append(contentsOf: text)
        cursor = storage.startIndex
    }

    mutating func nextChunk(maxCharacters: Int) -> String? {
        guard maxCharacters > 0,
              let cursor,
              cursor < storage.endIndex else {
            return nil
        }

        let end = storage.index(
            cursor,
            offsetBy: maxCharacters,
            limitedBy: storage.endIndex
        ) ?? storage.endIndex
        let chunk = String(storage[cursor..<end])
        self.cursor = end
        if end == storage.endIndex {
            storage.removeAll(keepingCapacity: true)
            self.cursor = storage.startIndex
        }
        return chunk
    }
}
