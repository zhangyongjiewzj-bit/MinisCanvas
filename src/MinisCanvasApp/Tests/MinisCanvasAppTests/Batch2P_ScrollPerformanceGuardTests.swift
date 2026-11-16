import Foundation
import Testing
import MinisCore

@testable import MinisCanvasApp

/// Batch2P 对话滚动卡顿护栏：复制菜单不在行渲染时脱敏、脱敏结果不变、任务摘要按数据版本复用。
@Suite("Batch2P 滚动卡顿护栏")
@MainActor
struct Batch2PScrollPerformanceGuardTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("transcriptCopyMenu 构建期不调用脱敏，脱敏只在复制动作的 copyMessage 里")
    func copyMenuBuildDoesNotRedact() throws {
        let text = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")
        let start = try #require(text.range(of: "private func transcriptCopyMenu("))
        let end = try #require(text.range(of: "private func scrollToMessage(", range: start.upperBound..<text.endIndex))
        let menuBody = String(text[start.lowerBound..<end.lowerBound])
        #expect(!menuBody.contains("redactedCopyBody"))
        #expect(!menuBody.contains("transcriptRedactor"))
        #expect(!menuBody.contains("redact("))
        #expect(!menuBody.contains("redactVisibleConversationBody"))
        #expect(menuBody.contains("copyMessage(message.id)"))

        let copyStart = try #require(text.range(of: "private func copyMessage("))
        let copyEnd = try #require(text.range(of: "private func redactedCopyBody(", range: copyStart.upperBound..<text.endIndex))
        #expect(String(text[copyStart.lowerBound..<copyEnd.lowerBound]).contains("redactedCopyBody(message, redactor: redactor)"))
    }

    @Test("菜单标题用的代码块数量不经过脱敏，且与围栏解析一致")
    func codeBlockCountFromUnredactedBody() {
        #expect(ChatTranscriptCopyProjection.codeBlockCount(unredactedBody: "plain text") == 0)
        let body = "a\n```swift\nlet x = 1\n```\nb\n~~~\nraw\n~~~\n"
        #expect(ChatTranscriptCopyProjection.codeBlockCount(unredactedBody: body) == 2)
        #expect(ChatTranscriptCopyProjection(redactedBody: body).codeBlocks.count == 2)
    }

    @Test("脱敏结果保持不变：密钥、路径、链接样例")
    func redactionOutputsAreStable() {
        let secret = "zz-super-secret-value-9876"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        // 已知密钥被遮蔽；本地路径在对话正文里保留、在通用脱敏里被替换。
        let withSecretAndPath = "key \(secret) at /Users/someone/project/file.txt"
        let conversation = redactor.redactVisibleConversationBody(withSecretAndPath)
        #expect(!conversation.contains(secret))
        #expect(conversation.contains("/Users/someone/project/file.txt"))
        let general = redactor.redact(withSecretAndPath)
        #expect(!general.contains(secret))
        #expect(general.contains("<path>"))
        #expect(!general.contains("/Users/someone"))

        // 普通公开链接在对话正文里保留，凭据链接被替换；通用脱敏一律替换链接。
        let plain = "see https://example.com/docs/page?id=1 ok"
        #expect(redactor.redactVisibleConversationBody(plain) == plain)
        #expect(redactor.redact(plain).contains("<remote-url>"))
        let credentialLink = "go https://example.com/cb?access_token=abcdef123456 now"
        let redactedLink = redactor.redactVisibleConversationBody(credentialLink)
        #expect(!redactedLink.contains("abcdef123456"))

        // 重复调用（命中缓存的正则）结果一致。
        #expect(redactor.redactVisibleConversationBody(withSecretAndPath) == conversation)
        #expect(redactor.redact(withSecretAndPath) == general)

        // 与 ProductRedactionPolicy 直接调用一致，长度上限仍生效。
        #expect(ProductRedactionPolicy.redact("a /tmp/x https://h.io/p", maxLength: 8) == "a <path>")
    }

    @Test("任务摘要在账本版本不变时复用缓存行，版本前进后重算")
    func receiptRowsReuseUntilVersionAdvances() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2p-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let consumer = TaskCenterControlConsumer(store: store)
        _ = try store.enqueue(taskID: "p-one", parentID: "parent-p",
                              providerID: "synthetic-p", modelID: "synthetic-model-p")

        let first = consumer.receiptRowsReusingVersion()
        let versionAfterFirst = store.taskCenterReadVersion()
        let second = consumer.receiptRowsReusingVersion()
        #expect(first.map(\.stableID) == second.map(\.stableID))
        #expect(store.taskCenterReadVersion() == versionAfterFirst)
        #expect(first.map(\.stableID) == consumer.receiptRows().map(\.stableID))

        _ = try store.enqueue(taskID: "p-two", parentID: "parent-p",
                              providerID: "synthetic-p", modelID: "synthetic-model-p")
        let third = consumer.receiptRowsReusingVersion()
        #expect(third.count == first.count + 1)
    }
}
