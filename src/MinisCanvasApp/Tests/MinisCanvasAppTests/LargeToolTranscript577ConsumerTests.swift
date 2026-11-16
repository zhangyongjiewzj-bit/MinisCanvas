import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Exercises the same native-result -> restored UI -> transcript projection
/// used by the parent transcript. No windows, defaults or external providers.
struct LargeToolTranscript577ConsumerTests {
    @Test func actualFileReadKeepsCanonicalBytesButNotLargeRawDisplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Output577-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let canary = "synthetic-private-log577"
        let input = canary + "\n" + String(repeating: "普通输出行\n", count: 1_000)
        let file = root.appendingPathComponent("owned.txt")
        try Data(input.utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let result = try await executor.execute(name: "file_read", input: ["path": file.path])
        #expect(result.count > ProductRedactionPolicy.maxTranscriptFieldLength)
        #expect(result.contains(canary))
        let canonical = LLMMessage(role: .tool, content: result, toolCallID: "call577")
        // Use the actual persistence representation and restore conversion.
        let restored = try JSONDecoder().decode(LLMMessage.self, from: JSONEncoder().encode(canonical))
        let message = restored.asChatMessageUI()
        #expect(message.asLLMMessage() == canonical)
        #expect(message.toolCallID == canonical.toolCallID)
        let visible = message.displayContent
        #expect(visible.contains("仅显示统计"))
        #expect(visible.contains("返回 \(result.utf8.count) 字节"))
        #expect(visible.count < 200)
        #expect(!visible.contains(canary))
        for redactor in [nil, ChatTranscriptRedactor(secretValues: [])] {
            let plain = ChatTranscriptFormatter.plainText([message], redactor: redactor)
            let accessible = ChatTranscriptFormatter.accessibilityText([message], redactor: redactor)
            #expect(plain.contains(visible))
            #expect(accessible.contains(visible))
            #expect(!plain.contains(canary))
            #expect(!accessible.contains(canary))
            #expect(plain.count < 240)
            #expect(accessible.count < 240)
        }
    }

    @Test(arguments: [4_096, 4_097])
    func exactExistingBoundaryOnlyFoldsLargeToolResults(size: Int) {
        let raw = String(repeating: "界", count: size)
        let tool = LLMMessage(role: .tool, content: raw, toolCallID: "boundary577").asChatMessageUI()
        if size == ProductRedactionPolicy.maxTranscriptFieldLength {
            #expect(tool.displayContent == raw)
        } else {
            #expect(tool.displayContent.contains("返回 \(raw.utf8.count) 字节、1 行"))
            #expect(!tool.displayContent.contains("界"))
        }
        #expect(tool.asLLMMessage().content == raw)
        // Ordinary prose is not misclassified based on size or JSON appearance.
        for role in [LLMMessage.Role.user, .assistant] {
            let ordinary = LLMMessage(role: role, content: raw).asChatMessageUI()
            #expect(ordinary.displayContent == raw)
        }
    }

    @Test func largeToolErrorTextDoesNotInferSuccessOrExposeRawBody() {
        let marker = "synthetic-failure577"
        let raw = marker + String(repeating: " failure detail", count: 1_000)
        let canonical = LLMMessage(role: .tool, content: raw, toolCallID: "failed577")
        let message = canonical.asChatMessageUI()
        let visible = message.displayContent
        #expect(visible.contains("仅显示统计"))
        #expect(!visible.contains(marker))
        #expect(!visible.contains("成功"))
        #expect(!visible.contains("完成"))
        #expect(message.asLLMMessage() == canonical)
    }
}
