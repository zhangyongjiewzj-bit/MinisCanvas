import Testing
import Foundation
import AppKit
import MinisCore
@testable import MinisCanvasApp

private final class CountingKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var reads = 0

    var getCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return values[key]
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }
}

// MARK: - S2：转录面内容级 secret 脱敏（plainText / accessibilityText / 富文本转录）
//
// 缺口：ChatTranscriptFormatter.plainText / accessibilityText 直接拼装
// displayContent，secret 值会原样进入「复制全部」「屏幕朗读」内容。
// 修法：ChatTranscriptRedactor 作为可复用脱敏接缝（复用 MinisCore
// EnvVarRedactor 的掩码规则），三种转录输出统一在 bodyText 层脱敏。
// 断言纪律：已知 secret 绝不出现；非 secret 内容原样保留；掩码形式可见。

@Suite("S2 转录面 secret 脱敏", .serialized)
struct TranscriptRedactionTests {

    /// Synthetic secret; no original prefix or suffix may remain visible.
    private let secret = "sk-s2-redaction-test-9f3a"
    private var masked: String { String(repeating: "*", count: secret.count) }

    @Test func toolResultRedactsContentWithoutExposingNativeMetadata() {
        let call = LLMToolCall(
            id: "call-redaction-private",
            name: "file_read",
            rawArguments: "{\"path\":\"private.txt\"}",
            arguments: ["path": "private.txt"]
        )
        let message = ChatMessageUI(
            role: .tool,
            content: "结果包含 sk-s2-redaction-test-9f3a",
            toolCallID: call.id,
            toolCalls: [call]
        )
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let plain = ChatTranscriptFormatter.plainText([message], redactor: redactor)
        let accessible = ChatTranscriptFormatter.accessibilityText([message], redactor: redactor)

        #expect(plain.contains("【工具】"))
        #expect(plain.contains(masked))
        #expect(!plain.contains(secret))
        #expect(!plain.contains("call-redaction-private"))
        #expect(!plain.contains("file_read"))
        #expect(!plain.contains("private.txt"))
        #expect(accessible.contains("工具："))
        #expect(!accessible.contains("call-redaction-private"))
    }

    @Test func plainTextNeverContainsKnownSecretValues() {
        let messages = [
            ChatMessageUI(role: .user, content: "请用 key sk-s2-redaction-test-9f3a 调用服务"),
            ChatMessageUI(role: .assistant, content: "好的，正在处理")
        ]
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let text = ChatTranscriptFormatter.plainText(messages, redactor: redactor)

        // secret 绝不出现；掩码形式与普通内容保留。
        #expect(!text.contains(secret))
        #expect(text.contains(masked))
        #expect(text.contains("请用 key"))
        #expect(text.contains("调用服务"))
        #expect(text.contains("好的，正在处理"))
    }

    @Test func plainTextRedactsSecretsInsideAttachmentLines() {
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "report-sk-s2-redaction-test-9f3a.pdf",
            fileType: .unknown,
            fileURL: "/tmp/report.pdf"
        )
        let message = ChatMessageUI(
            role: .user,
            content: "请查看附件",
            attachments: [attachment]
        )
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let text = ChatTranscriptFormatter.plainText([message], redactor: redactor)

        #expect(!text.contains(secret))
        #expect(text.contains(masked))
        #expect(text.contains("附件：report-"))
        #expect(text.contains(".pdf"))
    }

    @Test func accessibilityTextNeverContainsKnownSecretValues() {
        let messages = [
            ChatMessageUI(role: .user, content: "凭据：sk-s2-redaction-test-9f3a"),
            ChatMessageUI(role: .assistant, content: "收到，凭据已记录")
        ]
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let text = ChatTranscriptFormatter.accessibilityText(messages, redactor: redactor)

        #expect(!text.contains(secret))
        #expect(text.contains(masked))
        #expect(text.contains("用户：凭据："))
        #expect(text.contains("收到，凭据已记录"))
    }

    @Test func attributedTranscriptNeverContainsKnownSecretValues() {
        let messages = [
            ChatMessageUI(role: .user, content: "密钥是 sk-s2-redaction-test-9f3a，请勿外泄")
        ]
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        let attributed = ChatTranscriptFormatter.attributedString(messages, redactor: redactor)

        // 富文本转录（可见视图数据源）同样不得含 secret；普通内容保留。
        #expect(!attributed.string.contains(secret))
        #expect(attributed.string.contains("密钥是"))
    }

    @Test func redactorDerivesSecretValuesFromStoreEntries() {
        let entries = [
            EnvVarEntry(name: "TEST_API_KEY", value: secret, isSecret: true),
            EnvVarEntry(name: "TEST_URL", value: "https://example.com/v1", isSecret: false)
        ]
        let redactor = ChatTranscriptRedactor(entries: entries)

        let text = redactor.redact(
            "调用 TEST_API_KEY 的值 sk-s2-redaction-test-9f3a，端点 https://example.com/v1"
        )

        #expect(!text.contains(secret))
        #expect(text.contains(masked))
        // 非 secret 条目值原样保留。
        #expect(text.contains("<remote-url>"))
    }

    @Test func redactorBuildsFromLiveStoreAndRedactsTranscript() throws {
        TestEnvIsolation.hermeticize()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S2RedactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EnvVarStore(directory: dir)
        store.setEnvVar(name: "S2_TEST_KEY", value: secret, isSecret: true)

        let redactor = ChatTranscriptRedactor(store: store)
        let messages = [ChatMessageUI(role: .user, content: "当前 key：sk-s2-redaction-test-9f3a")]
        let text = ChatTranscriptFormatter.plainText(messages, redactor: redactor)

        #expect(!text.contains(secret))
        #expect(text.contains(masked))
    }

    @Test func redactorConstructionDoesNotReadUnloadedKeychainSecrets() throws {
        TestEnvIsolation.hermeticize()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S2RedactionKeychainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let backing = CountingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let firstStore = EnvVarStore(directory: dir, keychain: keychain)
        firstStore.setEnvVar(name: "S2_KEYCHAIN_API_KEY", value: secret, isSecret: true)

        // Reloading preserves only the metadata placeholder. The real value is
        // intentionally left in Keychain until a credential consumer needs it.
        let reloadedStore = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reloadedStore.entry(name: "S2_KEYCHAIN_API_KEY")?.value.isEmpty == true)

        _ = ChatTranscriptRedactor(store: reloadedStore)

        #expect(backing.getCount == 0)
    }

    @Test func redactorPreservesTextWhenNoSecretsConfigured() {
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let text = "完全正常的对话内容，无任何秘密"
        #expect(redactor.redact(text) == text)
    }

    @Test func shortSecretStillMasked() {
        let redactor = ChatTranscriptRedactor(secretValues: ["abc123"])
        let text = redactor.redact("临时口令 abc123 已失效")

        #expect(!text.contains("abc123"))
        #expect(text.contains("******"))
        #expect(text.contains("临时口令"))
    }
}
