import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PERF-02/05 transcript change consumer")
@MainActor
struct TranscriptChangeSignature1976Tests {
    @Test("draft edits leave the document stable, but equal-byte stream reflow wakes scroll following")
    func draftDoesNotInvalidateTranscriptAndEqualLengthStreamDoes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf1976-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "perf1976-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        chat.appendUser("历史正文")
        #expect(chat.appendAssistant("", toSession: session, isStreaming: true))
        let tailIndex = chat.messages.count - 1
        #expect(chat.messages[tailIndex].role == .assistant)

        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        func renderSignature() -> ChatTranscriptChangeSignature {
            _ = cache.render(sessionID: session, messages: chat.messages,
                             baseSize: 13, redactor: redactor)
            return ChatTranscriptChangeSignature(
                messages: chat.messages, documentRevision: cache.update.revision
            )
        }
        let initial = renderSignature()
        let initialGeneration = cache.update.generation
        let initialRevision = cache.update.revision
        chat.draftText = String(repeating: "长草稿", count: 10_000)
        let afterDraft = renderSignature()
        #expect(afterDraft == initial)
        #expect(cache.lastFormattedMessageCount == 0)
        #expect(cache.update.revision == initialRevision)
        #expect(cache.update.generation == initialGeneration)

        #expect(chat.replaceMessageContent(sessionID: session, at: tailIndex, with: "aaaa"))
        let beforeReflow = renderSignature()
        #expect(beforeReflow != afterDraft)
        #expect(cache.lastFormattedMessageCount == 1)
        let previousRevision = cache.update.revision
        #expect(chat.replaceMessageContent(sessionID: session, at: tailIndex, with: "a\nbb"))
        let afterReflow = renderSignature()
        // The old id/role/UTF8-count/streaming signature is identical here.
        #expect(afterReflow.messages == beforeReflow.messages)
        #expect(afterReflow != beforeReflow)
        #expect(cache.update.revision == previousRevision + 1)
        #expect(cache.update.generation == initialGeneration)
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(cache.document.attributedString.string.contains("a\nbb"))
        var scroll = ChatTranscriptScrollState()
        scroll.resetForSession(session)
        #expect(scroll.apply(.streamContentChanged, identity: scroll.identity) == .followBottom)
        #expect(chat.flushPendingDraftForTermination())
    }
}
