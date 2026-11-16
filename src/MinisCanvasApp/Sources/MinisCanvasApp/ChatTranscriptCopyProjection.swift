import Foundation
import MinisCore

struct ChatTranscriptCopyProjection: Equatable {
    let message: String
    let codeBlocks: [String]
    init(redactedBody: String) {
        message = redactedBody
        codeBlocks = MinisCore.MarkdownParser.parse(redactedBody).compactMap { block in
            if case .codeBlock(_, let code) = block { return code }
            return nil
        }
    }

    /// Menu-title helper: counts fenced blocks from the unredacted body without
    /// running redaction. Redaction runs only when a copy action is invoked.
    static func codeBlockCount(unredactedBody: String) -> Int {
        guard unredactedBody.contains("```") || unredactedBody.contains("~~~") else { return 0 }
        return ChatTranscriptCopyProjection(redactedBody: unredactedBody).codeBlocks.count
    }
}
