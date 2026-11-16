import Foundation
import MinisCore

/// App-only presentation fact captured after the ordered stream's text flush.
/// The existing canonical key ties one visible boundary to one real tool call.
/// Neither this key nor the boundary is added to provider message content.
struct ChatInlineToolAnchor: Codable, Equatable, Sendable {
    let compositeKey: ToolExecutionCompositeKey
    let utf16Offset: Int

    /// Build the grapheme-safe UTF-16 boundary index once per message, then
    /// validate all its anchors with constant-time membership checks.
    static func validated(_ anchors: [Self], in content: String) -> [Self] {
        guard !anchors.isEmpty else { return [] }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in content {
            offset += String(character).utf16.count
            boundaries.insert(offset)
        }
        return anchors.filter { $0.compositeKey.isValid && boundaries.contains($0.utf16Offset) }
    }
}

extension ChatMessageUI {
    mutating func captureInlineToolAnchor(for key: ToolExecutionCompositeKey) {
        guard role == .assistant, key.isValid,
              !inlineToolAnchors.contains(where: { $0.compositeKey == key }) else { return }
        inlineToolAnchors.append(ChatInlineToolAnchor(compositeKey: key, utf16Offset: content.utf16.count))
    }
}
