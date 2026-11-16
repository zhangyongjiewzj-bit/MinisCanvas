import AppKit
import Foundation
import Testing
import SwiftUI
@testable import MinisCanvasApp

@Suite("D-PERF-02/03/04 transcript append batches and coalesced consumer")
@MainActor
struct TranscriptIncrementalBatchTests {
    @Test(arguments: [50_000, 100_000, 150_000])
    func sendBatchFormatsOnlyNewMessages(characterCount: Int) throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let secret = "synthetic-secret-in-history"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let history = ChatMessageUI(role: .user, content: String(repeating: "史", count: characterCount) + secret)
        let initial = cache.render(sessionID: session, messages: [history], baseSize: 13, redactor: redactor)
        let initialLength = initial.attributedString.length
        let prefix = initial.attributedString.attributedSubstring(from: NSRange(location: 0, length: initialLength))
        let generation = cache.update.generation
        let revision = cache.update.revision
        #expect(cache.lastFormattedMessageCount == 1)
        for _ in 0..<5 {
            _ = cache.render(sessionID: session, messages: [history], baseSize: 13, redactor: redactor)
            #expect(cache.lastFormattedMessageCount == 0)
            #expect(cache.update.revision == revision)
        }
        let user = ChatMessageUI(role: .user, content: "新问题 " + secret)
        var assistant = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let batch = cache.render(sessionID: session, messages: [history, user, assistant], baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 2)
        #expect(cache.update.generation == generation)
        #expect(cache.update.baseRevision == revision)
        #expect(cache.update.replacementStart == initialLength)
        #expect(batch.messageStartLocations.count == 3)
        #expect(batch.messageStartLocations[1] == initialLength + 2)
        #expect(batch.attributedString.attributedSubstring(from: NSRange(location: 0, length: initialLength)).isEqual(to: prefix))
        #expect(!batch.attributedString.string.contains(secret))
        #expect(!cache.accessibilityText.contains(secret))
        let storage = NSTextStorage()
        storage.setAttributedString(prefix)
        let start = try #require(cache.update.replacementStart)
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: try #require(cache.update.replacement))
        #expect(storage.string == batch.attributedString.string)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText([history, user, assistant], redactor: redactor))

        assistant.content = "流式首段 " + secret
        _ = cache.render(sessionID: session, messages: [history, user, assistant], baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(cache.update.generation == generation)
        #expect(cache.update.replacementStart == batch.messageStartLocations.last)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText([history, user, assistant], redactor: redactor))
    }

    @Test func appendBatchAfterEmptyInitializationHasNoLeadingSeparator() {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        _ = cache.render(sessionID: session, messages: [], baseSize: 13, redactor: redactor)
        let generation = cache.update.generation
        let messages = [ChatMessageUI(role: .user, content: "问题"), ChatMessageUI(role: .assistant, content: "", isStreaming: true)]
        let document = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 2)
        #expect(cache.update.generation == generation)
        #expect(document.messageStartLocations.first == 0)
        #expect(document.attributedString.string == ChatTranscriptFormatter.formattedDocument(messages, baseSize: 13, redactor: redactor).attributedString.string)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText(messages, redactor: redactor))
    }

    @Test func historicalEditWithAppendStillTakesFullInvalidation() {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        var old = ChatMessageUI(role: .user, content: "原历史")
        _ = cache.render(sessionID: session, messages: [old], baseSize: 13, redactor: redactor)
        let generation = cache.update.generation
        old.content = "改过的历史"
        let messages = [old, ChatMessageUI(role: .user, content: "新问题"), ChatMessageUI(role: .assistant, content: "", isStreaming: true)]
        let document = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        #expect(cache.lastFormattedMessageCount == 3)
        #expect(cache.update.generation == generation + 1)
        #expect(cache.update.replacementStart == nil)
        #expect(document.attributedString.string.contains("改过的历史"))
        #expect(!document.attributedString.string.contains("原历史"))
    }

    @Test func missedShortenedTailBeforeAppendCannotPatchStaleStorage() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "历史")
        var tail = ChatMessageUI(role: .assistant, content: String(repeating: "旧", count: 100), isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let staleStorage = NSTextStorage()
        staleStorage.setAttributedString(initial.attributedString)
        let revision = cache.update.revision
        let generation = cache.update.generation
        let tailStart = initial.messageStartLocations.last
        tail.content = "短"
        _ = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let appended = ChatMessageUI(role: .user, content: "下一轮")
        let current = cache.render(sessionID: session, messages: [history, tail, appended], baseSize: 13, redactor: redactor)
        let update = cache.update
        let start = try #require(update.replacementStart)
        // Old generation-only + bounds checks accept this corrupting patch.
        #expect(update.generation == generation)
        #expect(start <= staleStorage.length)
        #expect(!ReadOnlyAttributedTextView.canApplyTranscriptPatch(update, appliedRevision: revision, appliedGeneration: generation, appliedTailStart: tailStart))
        staleStorage.replaceCharacters(in: NSRange(location: start, length: staleStorage.length - start), with: try #require(update.replacement))
        #expect(staleStorage.string != current.attributedString.string)
        // updateNSView's fallback installs the latest safe document atomically.
        staleStorage.setAttributedString(current.attributedString)
        #expect(staleStorage.string == current.attributedString.string)
        #expect(!staleStorage.string.contains("旧"))
    }

    @Test func missedTailDeltasWithSamePrefixRemainIncremental() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "历史")
        var tail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let storage = NSTextStorage()
        storage.setAttributedString(initial.attributedString)
        let revision = cache.update.revision
        let generation = cache.update.generation
        let tailStart = initial.messageStartLocations.last
        for text in ["一", "一二", "一二三"] {
            tail.content = text
            _ = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
            #expect(cache.lastFormattedMessageCount == 1)
        }
        let update = cache.update
        #expect(update.baseRevision != revision)
        #expect(ReadOnlyAttributedTextView.canApplyTranscriptPatch(update, appliedRevision: revision, appliedGeneration: generation, appliedTailStart: tailStart))
        let start = try #require(update.replacementStart)
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: try #require(update.replacement))
        #expect(storage.string == cache.document.attributedString.string)
    }

    @Test func exactBaseAppendAcceptedButDifferentGenerationRejected() {
        let update = ChatTranscriptStorageUpdate(revision: 8, generation: 3, replacementStart: 30, replacement: NSAttributedString(string: "new"), baseRevision: 7)
        #expect(ReadOnlyAttributedTextView.canApplyTranscriptPatch(update, appliedRevision: 7, appliedGeneration: 3, appliedTailStart: 10))
        #expect(!ReadOnlyAttributedTextView.canApplyTranscriptPatch(update, appliedRevision: 7, appliedGeneration: 2, appliedTailStart: 30))
        #expect(!ReadOnlyAttributedTextView.canApplyTranscriptPatch(update, appliedRevision: 6, appliedGeneration: 3, appliedTailStart: 10))
    }
    private func hostForFullSetControl(
        initial: ChatTranscriptFormattedDocument, proposal: ProposedViewSize,
        coordinator: ReadOnlyAttributedTextView.Coordinator
    ) -> NSScrollView {
        let view = ReadOnlyAttributedTextView(
            transcriptDocument: initial,
            update: ChatTranscriptStorageUpdate(revision: 0, generation: 0,
                                                replacementStart: nil, replacement: nil)
        )
        let host = view.makeNSView(coordinator: coordinator)
        _ = view.sizeThatFits(proposal, nsView: host, coordinator: coordinator)
        return host
    }

    @Test func nativeConsumerRejectsMissedShortTailAppendAndPreservesReadingState() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: ["synthetic-hidden-token"])
        let history = ChatMessageUI(role: .user, content: "Readable history **bold**\n\n- list item")
        var tail = ChatMessageUI(role: .assistant, content: String(repeating: "obsolete ", count: 100), isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail], baseSize: 17, redactor: redactor)
        let initialFrozen = ChatTranscriptFormattedDocument(
            attributedString: NSAttributedString(attributedString: initial.attributedString),
            messageStartLocations: initial.messageStartLocations
        )
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let host = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
            .makeNSView(coordinator: coordinator)
        let textView = try #require(host.documentView as? NSTextView)
        textView.selectedRanges = [NSValue(range: NSRange(location: 2, length: 5))]
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
            .sizeThatFits(proposal, nsView: host, coordinator: coordinator)
        tail.content = "Short **formatted** synthetic-hidden-token"
        _ = cache.render(sessionID: session, messages: [history, tail], baseSize: 17, redactor: redactor)
        let next = ChatMessageUI(role: .user, content: "Next question")
        let messages = [history, tail, next]
        let document = cache.render(sessionID: session, messages: messages, baseSize: 17, redactor: redactor)
        let currentView = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
        currentView.updateNSView(host, coordinator: coordinator)
        #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
        #expect(coordinator.pendingTailStart == nil) // actual safe full-set branch
        let full = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.formattedDocument(messages, baseSize: 17, redactor: redactor).attributedString)
        // Exact native equality uses the identical full canonical input.
        // Independent formatter allocations use the existing strict semantic
        // comparator: every attribute and block layout/sharing still matters.
        let control = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
        let controlCoordinator = ReadOnlyAttributedTextView.Coordinator()
        let controlHost = control.makeNSView(coordinator: controlCoordinator)
        let controlText = try #require(controlHost.documentView as? NSTextView)
        let actualSize = try #require(currentView.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        let controlSize = try #require(control.sizeThatFits(proposal, nsView: controlHost, coordinator: controlCoordinator))
        #expect(textView.string == full.string)
        #expect(textView.accessibilityValue() == full.string)
        #expect(!textView.string.contains("obsolete"))
        #expect(!textView.string.contains("synthetic-hidden-token"))
        #expect(textView.selectedRanges.first?.rangeValue == NSRange(location: 2, length: 5))
        #expect(actualSize == controlSize)
        // A fresh full-set consumer of the identical canonical document proves
        // whether incremental/coalesced lifecycle changes any native attribute.
        let sameDocumentControl = ReadOnlyAttributedTextView(
            transcriptDocument: document, update: cache.update
        )
        let sameDocumentCoordinator = ReadOnlyAttributedTextView.Coordinator()
        let sameDocumentHost = sameDocumentControl.makeNSView(coordinator: sameDocumentCoordinator)
        let sameDocumentText = try #require(sameDocumentHost.documentView as? NSTextView)
        _ = sameDocumentControl.sizeThatFits(proposal, nsView: sameDocumentHost, coordinator: sameDocumentCoordinator)
        let sameInitialCoordinator = ReadOnlyAttributedTextView.Coordinator()
        let sameInitialHost = hostForFullSetControl(initial: initialFrozen, proposal: proposal, coordinator: sameInitialCoordinator)
        currentView.updateNSView(sameInitialHost, coordinator: sameInitialCoordinator)
        _ = currentView.sizeThatFits(proposal, nsView: sameInitialHost, coordinator: sameInitialCoordinator)
        let sameInitialText = try #require(sameInitialHost.documentView as? NSTextView)
        #expect(textView.attributedString().isEqual(to: sameDocumentText.attributedString()))
        #expect(textView.attributedString().isEqual(to: sameInitialText.attributedString()))
        #expect(textView.attributedString().isEqual(to: controlText.attributedString()))
        #expect(UX02ChatReadingTests.renderingDifference(
            document.attributedString, full
        ) == nil)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText(messages, redactor: redactor))
    }

    @Test func nativeConsumerCoalescedTailUsesSuffixWithoutResettingWidth() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "Stable prefix")
        var tail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let first = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let host = first.makeNSView(coordinator: coordinator)
        let textView = try #require(host.documentView as? NSTextView)
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = first.sizeThatFits(proposal, nsView: host, coordinator: coordinator)
        let width = coordinator.cachedWidth
        for text in ["First", "First second", "First second third"] {
            tail.content = text
            _ = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        }
        let view = ReadOnlyAttributedTextView(transcriptDocument: cache.document, update: cache.update)
        view.updateNSView(host, coordinator: coordinator)
        #expect(coordinator.pendingTailStart == cache.document.messageStartLocations.last)
        #expect(coordinator.cachedWidth == width)
        #expect(textView.string == cache.document.attributedString.string)
        #expect(textView.accessibilityValue() == textView.string)
        _ = view.sizeThatFits(proposal, nsView: host, coordinator: coordinator)
        #expect(coordinator.pendingTailStart == nil)
        #expect(coordinator.cachedHeight > 0)
    }

}
