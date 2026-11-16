import Foundation
import Testing
@testable import MinisCore

@Suite("Batch2M 对话正文保留用户本地路径")
struct Batch2MConversationBodyPathsTests {
    private let paths = [
        "/Users/demo/Desktop/a.txt",
        "~/Documents/b.md",
        "codex:/Users/demo/.codex/sessions/x.jsonl"
    ]

    @Test func conversationBodyKeepsUserTypedLocalPathsVerbatim() {
        let text = "请读 \(paths[0]) 和 \(paths[1])，还有 \(paths[2]) 这个会话"
        let body = ProductRedactionPolicy.redactConversationBody(text)
        for path in paths { #expect(body.contains(path)) }
        #expect(!body.contains("<path>"))
        #expect(body == text)
    }

    @Test func conversationBodyStillMasksSecretsNextToPaths() {
        let known = "batch2m-known-secret-7781"
        let text = "\(paths[0]) sk-batch2mFormatToken1234567890 Bearer batch2mBearerToken123456 \(known) \(paths[1])"
        let body = ProductRedactionPolicy.redactConversationBody(text, knownSecrets: [known])
        #expect(body.contains(paths[0]) && body.contains(paths[1]))
        for secret in ["sk-batch2mFormatToken1234567890", "batch2mBearerToken123456", known] {
            #expect(!body.contains(secret))
        }
    }

    @Test func conversationBodyKeepsPlainHttpLinksBehavior() {
        let link = "[doc](https://example.invalid/docs(v1)) \(paths[0])"
        #expect(ProductRedactionPolicy.redactConversationBody(link) == link)
        let credentialLink = "https://example.invalid/a?token=abc \(paths[0])"
        let body = ProductRedactionPolicy.redactConversationBody(credentialLink)
        #expect(!body.contains("example.invalid"))
        #expect(body.contains(paths[0]))
    }

    /// 护栏：审计/回执用的 redact 对路径仍输出 <path>（预计当前即通过）。
    @Test func auditRedactionStillMasksPaths() {
        let masked = ProductRedactionPolicy.redact(paths.joined(separator: " "))
        for path in paths { #expect(!masked.contains(path)) }
        #expect(masked.contains("<path>"))
    }
}
