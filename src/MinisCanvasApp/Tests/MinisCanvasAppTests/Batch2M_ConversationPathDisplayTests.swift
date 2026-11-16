import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Batch2M 转录显示与复制保留用户路径")
@MainActor
struct Batch2MConversationPathDisplayTests {
    private let userPath = "/Users/demo/Desktop/a.txt"
    private let tildePath = "~/Documents/b.md"
    private let sessionPath = "codex:/Users/demo/.codex/sessions/x.jsonl"
    private let secret = "batch2m-registered-secret-5521"

    private func text(_ lead: String) -> String {
        "\(lead) \(userPath) \(tildePath) \(sessionPath) sk-batch2mFormatToken1234567890 Bearer batch2mBearerToken123456 \(secret)"
    }

    private func assertKept(_ output: String) {
        for path in [userPath, tildePath, sessionPath] { #expect(output.contains(path)) }
        #expect(!output.contains("<path>"))
        for hidden in ["sk-batch2mFormatToken1234567890", "batch2mBearerToken123456", secret] {
            #expect(!output.contains(hidden))
        }
    }

    @Test func redactorKeepsPathsButMasksSecrets() {
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        assertKept(redactor.redactVisibleConversationBody(text("看")))
    }

    @Test func userAndAssistantTranscriptDisplayKeepPaths() {
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let user = ChatMessageUI(role: .user, content: text("用户"))
        let assistant = ChatMessageUI(role: .assistant, content: text("助手"))
        assertKept(ChatTranscriptFormatter.plainText([user, assistant], redactor: redactor))
        assertKept(ChatTranscriptFormatter.accessibilityText([user, assistant], redactor: redactor))
        let doc = ChatTranscriptFormatter.attributedString([user, assistant], baseSize: 13, redactor: redactor)
        assertKept(doc.string)
    }

    @Test func copyMessageAndMarkdownExportKeepPaths() {
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let user = ChatMessageUI(role: .user, content: text("用户"))
        let assistant = ChatMessageUI(role: .assistant, content: text("助手"))
        // 复制消息 = ChatTranscriptCopyProjection(redactedBody: redactVisibleConversationBody(displayContent))
        for message in [user, assistant] {
            let projection = ChatTranscriptCopyProjection(
                redactedBody: redactor.redactVisibleConversationBody(message.displayContent))
            assertKept(projection.message)
        }
        // 复制/导出对话
        assertKept(SessionMarkdownExport.markdown(title: "会话", messages: [user, assistant], redactor: redactor))
    }
}
