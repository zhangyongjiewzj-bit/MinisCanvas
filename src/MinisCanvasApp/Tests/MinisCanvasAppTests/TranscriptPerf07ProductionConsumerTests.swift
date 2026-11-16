import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// D-PERF-07's bounded in-memory source consumer. Instruments still needs a
/// package-bound App field run for 60/120 Hz and long-run acceptance.
@Suite("D-PERF-07 production transcript signpost paths")
@MainActor
struct TranscriptPerf07ProductionConsumerTests {
    @Test(arguments: [50_000, 100_000])
    func twentyStreamingUpdatesTraverseFormatterNativeApplyAndLayout(characterCount: Int) throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: String(repeating: "史", count: characterCount))
        var tail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let messages = [history, tail]
        let initial = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        #expect(history.content.utf16.count == characterCount)

        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let initialView = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let host = initialView.makeNSView(coordinator: coordinator)
        let textView = try #require(host.documentView as? NSTextView)
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = try #require(initialView.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        let initialGeneration = cache.update.generation
        let initialRevision = cache.update.revision

        // Unchanged SwiftUI refreshes are a real production path. Their
        // historical equality cost must appear inside TranscriptRender.
        for _ in 0..<20 {
            _ = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
            #expect(cache.update.revision == initialRevision)
            #expect(cache.lastFormattedMessageCount == 0)
        }

        for _ in 1...20 {
            tail.content += "增"
            let document = cache.render(
                sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor
            )
            let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
            view.updateNSView(host, coordinator: coordinator)
            let size = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
            #expect(size.height > 0)
            #expect(cache.update.generation == initialGeneration)
            #expect(cache.lastFormattedMessageCount == 1)
            #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
            #expect(coordinator.pendingTailStart == nil)
            #expect(textView.string == document.attributedString.string)
        }
    }
}
