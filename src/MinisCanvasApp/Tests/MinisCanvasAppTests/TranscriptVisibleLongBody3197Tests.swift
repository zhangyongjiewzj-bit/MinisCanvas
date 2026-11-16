import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-CHAT-12/13 long completed transcript visibility")
@MainActor
struct TranscriptVisibleLongBody3197Tests {
    @Test("40 synthetic stream paragraphs reach native text, copy and AX without weakening bounded records")
    func completedLongAssistantBodyRemainsVisible() throws {
        let secret = "syntheticCredentialValue3197"
        let chunks = (1...40).map { index in
            "TASK3197 chunk\(String(format: "%02d", index)) — "
                + String(repeating: "Controlled line without account data. ", count: 12)
        }
        let body = chunks.joined(separator: "\n\n")
            + "\n\n" + secret
            + "\nhttps://example.invalid/task3197\n/synthetic/task3197/private"
        #expect(body.count > 16_000)
        let session = UUID()
        let history = ChatMessageUI(role: .user, content: "Earlier synthetic question")
        var reply = ChatMessageUI(role: .assistant,
                                  content: chunks.prefix(10).joined(separator: "\n\n"),
                                  isStreaming: true)
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let cache = ChatTranscriptDocumentCache()
        let first = cache.render(sessionID: session, messages: [history, reply],
                                 baseSize: 13, redactor: redactor)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let native = ReadOnlyAttributedTextView(transcriptDocument: first, update: cache.update)
            .makeNSView(coordinator: coordinator)

        reply.content = body
        reply.isStreaming = false
        let completed = cache.render(sessionID: session, messages: [history, reply],
                                     baseSize: 13, redactor: redactor)
        let view = ReadOnlyAttributedTextView(transcriptDocument: completed,
                                              update: cache.update)
        view.updateNSView(native, coordinator: coordinator)
        let textView = try #require(native.documentView as? NSTextView)
        let measured = try #require(view.sizeThatFits(
            ProposedViewSize(width: 600, height: nil), nsView: native,
            coordinator: coordinator
        ))
        let copied = ChatTranscriptFormatter.plainText([history, reply], redactor: redactor)
        let accessible = ChatTranscriptFormatter.accessibilityText([history, reply], redactor: redactor)

        for actual in [completed.attributedString.string, textView.string, copied, accessible] {
            #expect(actual.contains("TASK3197 chunk40"))
            #expect(!actual.contains(secret))
            // 20261103T0521: public non-credential conversation URLs remain visible.
            #expect(actual.contains("https://example.invalid/task3197"))
            #expect(actual.contains("/synthetic/task3197/private"))
        }
        #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
        #expect(measured.height > 1)
        #expect((ChatTranscriptFormatter.persistedEntries([reply], redactor: redactor)
            .first?.text.count ?? 0) <= 4_096)
        #expect(redactor.redactRawResponse(body).count <= 4_096)
        #expect(ChatTranscriptFormatter.plainText([
            ChatMessageUI(role: .system, content: body)
        ], redactor: redactor).count <= 4_096 + 8)
        #expect(ChatTranscriptFormatter.plainText([
            ChatMessageUI(role: .tool, content: body)
        ], redactor: redactor).count <= 4_096 + 8)
    }
}
