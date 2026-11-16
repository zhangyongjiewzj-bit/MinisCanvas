import AppKit
import Foundation
import Testing
import SwiftUI
@testable import MinisCanvasApp

@Suite("D-PERF-04 attributed stream tail append")
@MainActor
struct TranscriptAttributedTailAppend1982Tests {
    @Test("plain Unicode growth edits only the changed TextKit suffix and a missed delta falls back safely")
    func strictAttributedPrefixEditsOnlyChangedSuffix() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "保持历史")
        var tail = ChatMessageUI(role: .assistant, content: "hello🙂", isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail],
                                   baseSize: 13, redactor: redactor)
        let initialLength = initial.attributedString.length
        let tailStart = try #require(initial.messageStartLocations.last)
        let initialUpdate = cache.update
        let initialRevision = cache.update.revision
        let generation = cache.update.generation
        let storage = NSTextStorage(attributedString: initial.attributedString)
        let missedStorage = NSTextStorage(attributedString: initial.attributedString)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let mounted = ReadOnlyAttributedTextView(
            transcriptDocument: initial, update: initialUpdate
        ).makeNSView(coordinator: coordinator)

        tail.content += "👩🏽‍💻"
        let first = cache.render(sessionID: session, messages: [history, tail],
                                 baseSize: 13, redactor: redactor)
        let firstUpdate = cache.update
        #expect(cache.lastFormattedMessageCount == 1)
        #expect(firstUpdate.generation == generation)
        let firstPatch = try #require(firstUpdate.patch(
            forAppliedRevision: initialRevision
        ))
        let firstStart = firstPatch.start
        #expect(firstStart > tailStart && firstStart <= initialLength)
        #expect(firstPatch.value.length < first.attributedString.length - tailStart)
        #expect(firstUpdate.replacementStart == tailStart)
        #expect(ReadOnlyAttributedTextView.canApplyTranscriptPatch(
            firstUpdate, appliedRevision: initialRevision,
            appliedGeneration: generation, appliedTailStart: tailStart
        ))
        ReadOnlyAttributedTextView(transcriptDocument: first, update: firstUpdate)
            .updateNSView(mounted, coordinator: coordinator)
        #expect(coordinator.pendingTailStart == firstStart)
        #expect((mounted.documentView as? NSTextView)?.string == first.attributedString.string)
        storage.replaceCharacters(
            in: NSRange(location: firstStart, length: storage.length - firstStart),
            with: firstPatch.value
        )
        #expect(storage.string == first.attributedString.string)
        let firstControl = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.formattedDocument(
                [history, tail], baseSize: 13, redactor: redactor
            ).attributedString
        )
        #expect(UX02ChatReadingTests.renderingDifference(first.attributedString, firstControl) == nil)

        let firstLength = first.attributedString.length
        tail.content += " more"
        let second = cache.render(sessionID: session, messages: [history, tail],
                                  baseSize: 13, redactor: redactor)
        let secondUpdate = cache.update
        let secondPatch = try #require(secondUpdate.patch(
            forAppliedRevision: firstUpdate.revision
        ))
        let secondStart = secondPatch.start
        #expect(secondStart > tailStart && secondStart <= firstLength)
        #expect(ReadOnlyAttributedTextView.canApplyTranscriptPatch(
            secondUpdate, appliedRevision: initialRevision,
            appliedGeneration: generation, appliedTailStart: tailStart
        ), "a missed tail revision must use the anchored recovery patch")
        let recovery = try #require(secondUpdate.patch(
            forAppliedRevision: initialRevision
        ))
        #expect(recovery.start == tailStart)
        missedStorage.replaceCharacters(
            in: NSRange(location: recovery.start, length: missedStorage.length - recovery.start),
            with: recovery.value
        )
        #expect(missedStorage.string == second.attributedString.string)

        _ = cache.render(sessionID: UUID(), messages: [history, tail],
                         baseSize: 13, redactor: redactor)
        #expect(cache.update.generation == generation + 1)
        #expect(cache.update.replacementStart == nil)
    }

    @Test("closing Markdown syntax restyles the old body instead of preserving it")
    func markdownRestyleCannotPreserveOldBody() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "保持历史")
        var tail = ChatMessageUI(role: .assistant, content: "**unfinished", isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail],
                                   baseSize: 13, redactor: redactor)
        let tailStart = try #require(initial.messageStartLocations.last)
        let initialLength = initial.attributedString.length
        let generation = cache.update.generation
        let revision = cache.update.revision
        let storage = NSTextStorage(attributedString: initial.attributedString)

        tail.content += "**"
        let changed = cache.render(sessionID: session, messages: [history, tail],
                                   baseSize: 13, redactor: redactor)
        let update = cache.update
        let exactPatch = try #require(update.patch(forAppliedRevision: revision))
        let changedStart = exactPatch.start
        #expect(changedStart > tailStart && changedStart < initialLength)
        #expect(update.replacementStart == tailStart)
        #expect(update.generation == generation)
        #expect(ReadOnlyAttributedTextView.canApplyTranscriptPatch(
            update, appliedRevision: revision,
            appliedGeneration: generation, appliedTailStart: tailStart
        ))
        storage.replaceCharacters(
            in: NSRange(location: changedStart, length: storage.length - changedStart),
            with: exactPatch.value
        )
        #expect(storage.string == changed.attributedString.string)
        let control = ReadOnlyAttributedTextView.sanitized(
            ChatTranscriptFormatter.formattedDocument(
                [history, tail], baseSize: 13, redactor: redactor
            ).attributedString
        )
        #expect(UX02ChatReadingTests.renderingDifference(changed.attributedString, control) == nil)
    }
    @Test("the actual twelve-chunk long stream preserves stable attributed prefixes in the native host")
    func twelveChunkStreamKeepsNativeSuffixAndCompleteAttributes() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "G22_PERF04_STREAM12")
        var tail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let initial = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let mounted = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
            .makeNSView(coordinator: coordinator)
        let text = try #require(mounted.documentView as? NSTextView)
        for index in 1...12 {
            let previous = NSAttributedString(attributedString: cache.document.attributedString)
            let revision = cache.update.revision
            let prefix = String(format: "G22_PERF04_DELTA_%02d\n", index)
            tail.content += prefix + String(repeating: "p", count: 8191 - prefix.utf16.count) + "\n"
            let current = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
            let patch = try #require(cache.update.patch(forAppliedRevision: revision))
            let oldText = previous.string as NSString
            let newText = current.attributedString.string as NSString
            var common = 0
            while common < min(oldText.length, newText.length),
                  oldText.character(at: common) == newText.character(at: common) { common += 1 }
            var firstDifference: Int?
            var differingKeys: [String] = []
            var cursor = 0
            while cursor < common {
                var leftRange = NSRange(), rightRange = NSRange()
                let left = previous.attributes(at: cursor, effectiveRange: &leftRange)
                let right = current.attributedString.attributes(at: cursor, effectiveRange: &rightRange)
                if !NSDictionary(dictionary: left).isEqual(to: right) {
                    firstDifference = cursor
                    differingKeys = Set(left.keys).union(right.keys).filter { key in
                        let a = left[key].map { [$0] } ?? []
                        let b = right[key].map { [$0] } ?? []
                        return !NSArray(array: a).isEqual(to: b)
                    }.map(\.rawValue).sorted()
                    break
                }
                cursor = min(common, NSMaxRange(leftRange), NSMaxRange(rightRange))
            }
            if index > 1 {
                #expect(patch.start >= previous.length - "\n".utf16.count,
                    "chunk=\(index) commonUTF16=\(common) firstAttributeDifferenceUTF16=\(firstDifference ?? -1) keys=\(differingKeys)")
            }
            ReadOnlyAttributedTextView(transcriptDocument: current, update: cache.update)
                .updateNSView(mounted, coordinator: coordinator)
            #expect(text.attributedString().isEqual(to: current.attributedString))
            let control = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.formattedDocument(
                [history, tail], baseSize: 13, redactor: redactor).attributedString)
            #expect(UX02ChatReadingTests.renderingDifference(current.attributedString, control) == nil)
        }
        #expect(tail.content.utf16.count == 98_304)
    }

    @Test("late Markdown restyling retains the earlier Unicode paragraphs but not changed styles")
    func lateAttributeDifferenceRetainsOnlyTheActuallyEqualPrefix() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let stable = "unchanged 🙂👩🏽‍💻e\u{301}\n\n"
        var tail = ChatMessageUI(role: .assistant, content: stable + "**pending", isStreaming: true)
        let before = cache.render(sessionID: session, messages: [tail], baseSize: 13, redactor: redactor)
        let frozen = NSAttributedString(attributedString: before.attributedString)
        let revision = cache.update.revision
        let initialView = ReadOnlyAttributedTextView(transcriptDocument: before, update: cache.update)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let mounted = initialView.makeNSView(coordinator: coordinator)
        let native = try #require(mounted.documentView as? NSTextView)
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = initialView.sizeThatFits(proposal, nsView: mounted, coordinator: coordinator)
        tail.content += "**"
        let current = cache.render(sessionID: session, messages: [tail], baseSize: 13, redactor: redactor)
        let patch = try #require(cache.update.patch(forAppliedRevision: revision))
        let marker = (frozen.string as NSString).range(of: "pending")
        try #require(marker.location != NSNotFound)
        let stableRange = (frozen.string as NSString).range(of: "unchanged 🙂👩🏽‍💻e\u{301}")
        try #require(stableRange.location != NSNotFound)
        #expect(patch.start >= NSMaxRange(stableRange) && patch.start <= marker.location)
        // Compare canonical attributes before TextKit performs font fixing.
        let storage = NSMutableAttributedString(attributedString: frozen)
        storage.replaceCharacters(in: NSRange(location: patch.start, length: storage.length - patch.start), with: patch.value)
        #expect(storage.isEqual(to: current.attributedString))
        // Both native consumers must undergo the same AppKit normalization;
        // preserve an exact all-attribute comparison, not a string-only oracle.
        let updatedView = ReadOnlyAttributedTextView(transcriptDocument: current, update: cache.update)
        updatedView.updateNSView(mounted, coordinator: coordinator)
        _ = updatedView.sizeThatFits(proposal, nsView: mounted, coordinator: coordinator)
        let freshCoordinator = ReadOnlyAttributedTextView.Coordinator()
        let fresh = updatedView.makeNSView(coordinator: freshCoordinator)
        let freshText = try #require(fresh.documentView as? NSTextView)
        _ = updatedView.sizeThatFits(proposal, nsView: fresh, coordinator: freshCoordinator)
        #expect(native.attributedString().isEqual(to: freshText.attributedString()))
        let control = ReadOnlyAttributedTextView.sanitized(ChatTranscriptFormatter.formattedDocument(
            [tail], baseSize: 13, redactor: redactor).attributedString)
        #expect(UX02ChatReadingTests.renderingDifference(current.attributedString, control) == nil)
    }

}
