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


    // MARK: 流畅度修复 C 组：Markdown 块缓存、消息级格式化缓存、展示投影缓存

    private static func sameAttributedContent(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard a.string == b.string else { return false }
        var location = 0
        while location < a.length {
            var rangeA = NSRange(), rangeB = NSRange()
            var attrsA = a.attributes(at: location, effectiveRange: &rangeA)
            var attrsB = b.attributes(at: location, effectiveRange: &rangeB)
            let styleA = attrsA.removeValue(forKey: .paragraphStyle) as? NSParagraphStyle
            let styleB = attrsB.removeValue(forKey: .paragraphStyle) as? NSParagraphStyle
            guard NSDictionary(dictionary: attrsA).isEqual(to: attrsB) else { return false }
            guard styleA?.alignment == styleB?.alignment,
                  styleA?.headIndent == styleB?.headIndent,
                  styleA?.firstLineHeadIndent == styleB?.firstLineHeadIndent,
                  styleA?.tailIndent == styleB?.tailIndent,
                  styleA?.paragraphSpacing == styleB?.paragraphSpacing,
                  styleA?.textBlocks.count == styleB?.textBlocks.count else { return false }
            location = min(NSMaxRange(rangeA), NSMaxRange(rangeB))
        }
        return true
    }

    private static let markdownSamples: [String] = [
        "# 标题\n\n段落 **粗体** 和 `代码`，见 [链接](https://example.com)。\n\n- 项 A\n\n- 项 B\n  - 嵌套\n\n> 引用\n\n---\n",
        "1. 第一\n2. 第二\n\n3. 跨空行继续\n\n正文",
        "```swift\nlet x = 1\n\nlet y = 2\n```\n\n后续段落",
        "```swift\nlet unclosed = 1\n\n还在代码块里",
        "| a | b |\n|---|---|\n| 1 | 2 |\n\n表后段落\n\n| a | b |\n|---|---|\n| 1 | 2 |",
        "半个 `反引号 还没闭合\n\n下一段 [坏链接](javascript:alert(1))",
        "重复段落\n\n重复段落\n\n重复段落",
    ]

    @Test
    func markdownBlockCacheMatchesFullBuildForVariedMarkdown() {
        let cache = MarkdownBlockRenderCache()
        for sample in Self.markdownSamples {
            for streaming in [false, true] {
                let full = MarkdownAttributedTextBuilder.renderState(
                    content: sample, isMarkdown: true, isStreaming: streaming)
                for _ in 0..<2 { // 第一次全部未命中，第二次命中
                    let cached = MarkdownAttributedTextBuilder.renderState(
                        content: sample, isMarkdown: true, isStreaming: streaming, blockCache: cache)
                    #expect(cached.status == full.status)
                    #expect(Self.sameAttributedContent(cached.attributedString, full.attributedString))
                }
            }
        }
        #expect(cache.hitCount > 0)
    }

    @Test
    func markdownBlockCacheMatchesFullBuildForEveryStreamingPrefix() {
        let cache = MarkdownBlockRenderCache()
        let sample = Self.markdownSamples.joined(separator: "\n\n")
        let characters = Array(sample)
        var end = 0
        while end < characters.count {
            end = min(characters.count, end + 5)
            let prefix = String(characters[0..<end])
            let full = MarkdownAttributedTextBuilder.renderState(
                content: prefix, isMarkdown: true, isStreaming: true)
            let cached = MarkdownAttributedTextBuilder.renderState(
                content: prefix, isMarkdown: true, isStreaming: true, blockCache: cache)
            #expect(cached.status == full.status, "prefix \(end)")
            #expect(Self.sameAttributedContent(cached.attributedString, full.attributedString), "prefix \(end)")
        }
        #expect(cache.hitCount > 0)
    }

    private static func longTranscript(count: Int) -> [ChatMessageUI] {
        (0..<count).map { index in
            index % 5 == 4
                ? ChatMessageUI(role: .tool, content: String(repeating: "build output line\n", count: 40),
                                toolCallID: "call-\(index)")
                : ChatMessageUI(role: index % 2 == 0 ? .user : .assistant,
                                content: "消息 \(index)\n\n- 列表 **加粗**\n\n`code` \(index)")
        }
    }

    @Test
    func expandingOneToolOutputReformatsOnlyThatMessageAndMatchesFullRebuild() throws {
        let store = ChatTranscriptFormatStore()
        let cache = ChatTranscriptDocumentCache(formatStore: store)
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let session = UUID()
        let messages = Self.longTranscript(count: 30)
        let projection = ChatTranscriptDisplayProjectionCache()
        let toolID = try #require(messages.first(where: { $0.role == .tool })?.id)

        let collapsed = projection.project(messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
        _ = cache.render(sessionID: session, messages: collapsed, baseSize: 13, redactor: redactor)
        #expect(cache.lastFreshlyFormattedCount == messages.count)

        let expandedSet: Set<UUID> = [toolID]
        let shown = projection.project(messages, toolExpanded: { expandedSet.contains($0) }, thinkingExpanded: { _ in false })
        let incremental = cache.render(sessionID: session, messages: shown, baseSize: 13,
                                       redactor: redactor, expandedToolOutputIDs: expandedSet)
        #expect(cache.lastFormattedMessageCount == messages.count)
        #expect(cache.lastFreshlyFormattedCount == 1)
        #expect(cache.lastCacheHitCount == messages.count - 1)

        let reference = ChatTranscriptDocumentCache(formatStore: ChatTranscriptFormatStore())
        let full = reference.render(sessionID: session, messages: shown, baseSize: 13,
                                    redactor: redactor, expandedToolOutputIDs: expandedSet)
        #expect(Self.sameAttributedContent(incremental.attributedString, full.attributedString))
        #expect(incremental.messageStartLocations == full.messageStartLocations)
        #expect(cache.accessibilityText == reference.accessibilityText)

        // 收起回去：同样只重排那一条，并与全量重建一致。
        let collapsedAgain = projection.project(messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
        let back = cache.render(sessionID: session, messages: collapsedAgain, baseSize: 13, redactor: redactor)
        #expect(cache.lastFreshlyFormattedCount <= 1)
        let backReference = ChatTranscriptDocumentCache(formatStore: ChatTranscriptFormatStore())
            .render(sessionID: session, messages: collapsedAgain, baseSize: 13, redactor: redactor)
        #expect(Self.sameAttributedContent(back.attributedString, backReference.attributedString))
    }

    /// 流式尾消息每个前缀：增量加工（检查点前缀复用）的文档与全新缓存整段构建一致，
    /// 且按更新补丁回放到旧存储后与文档一致；含状态图标、代码块、列表。
    @Test
    func streamingTailIncrementalPrepareMatchesFullBuildForEveryPrefix() throws {
        let sample = "## 进度\n\n✅ 第一步完成\n⏳ 第二步进行中 **加粗**\n\n- 项 A\n- 项 B ⚠️ 注意\n\n```swift\nlet a = \"✅\"\n```\n\n结尾 🪄 段落 ❌\n"
        let characters = Array(sample)
        let session = UUID()
        let id = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let cache = ChatTranscriptDocumentCache()
        let user = ChatMessageUI(role: .user, content: "问")
        let storage = NSTextStorage()
        var end = 0
        var applied: UInt64?
        while end < characters.count {
            end = min(characters.count, end + 3)
            let message = ChatMessageUI(id: id, role: .assistant, content: String(characters[0..<end]), isStreaming: end < characters.count)
            let document = cache.render(sessionID: session, messages: [user, message], baseSize: 13, redactor: redactor)
            let reference = ChatTranscriptDocumentCache(formatStore: ChatTranscriptFormatStore())
                .render(sessionID: session, messages: [user, message], baseSize: 13, redactor: redactor)
            #expect(Self.sameAttributedContent(Self.withoutAttachments(document.attributedString),
                                               Self.withoutAttachments(reference.attributedString)))
            #expect(ChatTranscriptStatusIconProjection.copyText(document.attributedString)
                    == ChatTranscriptStatusIconProjection.copyText(reference.attributedString))
            #expect(ChatTranscriptStatusIconProjection.containsIcons(document.attributedString)
                    == ChatTranscriptStatusIconProjection.containsIcons(reference.attributedString))
            if cache.update.replacementStart == nil {
                storage.setAttributedString(document.attributedString)
            } else if let patch = cache.update.patch(forAppliedRevision: applied) {
                storage.replaceCharacters(in: NSRange(location: patch.start, length: storage.length - patch.start), with: patch.value)
            }
            applied = cache.update.revision
            #expect(storage.string == document.attributedString.string)
        }
    }

    private static func withoutAttachments(_ source: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: source)
        copy.removeAttribute(.attachment, range: NSRange(location: 0, length: copy.length))
        return copy
    }

    @Test
    func displayProjectionCacheMatchesDirectProjectionAndSkipsRescan() throws {
        let messages = Self.longTranscript(count: 20)
        let projection = ChatTranscriptDisplayProjectionCache()
        let toolID = try #require(messages.first(where: { $0.role == .tool })?.id)
        let direct = messages.map {
            ChatTranscriptFormatter.thinkingDisplayMessage(
                ChatTranscriptFormatter.toolOutputDisplayMessage($0, expanded: $0.id == toolID),
                expanded: false)
        }
        let first = projection.project(messages, toolExpanded: { $0 == toolID }, thinkingExpanded: { _ in false })
        #expect(first == direct)
        let builds = projection.projectionBuildCount
        let second = projection.project(messages, toolExpanded: { $0 == toolID }, thinkingExpanded: { _ in false })
        #expect(second == direct)
        #expect(projection.projectionBuildCount == builds)
    }

    // MARK: 显示层增量脱敏（第二道保险）与首开预热

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static let displayKnownSecret = "my-known-secret-value 含空格"

    private static func displayCorpus(seed: UInt64) -> String {
        let fragments = [
            "普通的一行说明文字，没有任何密钥。\n",
            "## 小节\n\n- 列表项 A\n- 列表项 B\n\n",
            "```swift\nlet token = \"abcdef0123456789abcdef\"\n```\n",
            "令牌sk-proj-abcdefghijklmnopqrstuvwxyz012345紧贴中文\n",
            "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCD ",
            "Authorization: Bearer abcdef0123456789abcdef0123456789\n",
            "api_key=\"abcdef0123456789abcdef\"\n",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789\n",
            "密钥\(displayKnownSecret)后面还有字。\n",
            "访问 https://example.com/doc?token=abcdef0123456789abcdef 与 https://example.com/plain 两个链接\n",
            "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC\n-----END PRIVATE KEY-----\n",
            "Cookie: session_id=abcdef0123456789\n",
            "本地路径 /Users/example/project/file.swift 保持原样\n",
        ]
        var generator = SeededGenerator(state: seed)
        var text = ""
        for _ in 0..<40 { text += fragments[Int(generator.next() >> 33) % fragments.count] }
        return text
    }

    @Test(arguments: [UInt64(1), 7, 42, 2026, 90210, 123_456_789])
    func displayIncrementalRedactionMatchesFullUnderRandomSlicing(seed: UInt64) {
        let redactor = ChatTranscriptRedactor(secretValues: [Self.displayKnownSecret])
        let cache = StreamingDisplayRedactionCache()
        let id = UUID()
        let characters = Array(Self.displayCorpus(seed: seed))
        var generator = SeededGenerator(state: seed &* 31 &+ 5)
        var accumulated = ""
        var index = 0
        var mismatches = 0
        var firstMismatch = ""
        var steps = 0
        while index < characters.count {
            let size = 1 + Int(generator.next() >> 33) % 37
            let end = min(characters.count, index + size)
            accumulated += String(characters[index..<end])
            index = end
            steps += 1
            let incremental = cache.redactedBody(
                messageID: id, body: accumulated, secrets: redactor.secretValues)
            let full = redactor.redactVisibleConversationBody(accumulated)
            if incremental != full {
                mismatches += 1
                if firstMismatch.isEmpty { firstMismatch = "step \(steps) len \(accumulated.count)" }
            }
        }
        #expect(mismatches == 0, Comment(rawValue: firstMismatch))
        #expect(cache.rebuildCount == 1)
        #expect(cache.incrementalCount == steps - 1)
        #expect(!accumulated.isEmpty && !cache.redactedBody(
            messageID: id, body: accumulated, secrets: redactor.secretValues).contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    }

    @Test func displayIncrementalRedactionRebuildsOnNonAppendAndReleasesOnFinish() {
        let redactor = ChatTranscriptRedactor(secretValues: [Self.displayKnownSecret])
        let cache = StreamingDisplayRedactionCache()
        let id = UUID()
        let first = "第一段\nsk-abcdefghijklmnopqrstuvwxyz0123456789ABCD\n第二段"
        #expect(cache.redactedBody(messageID: id, body: first, secrets: redactor.secretValues)
            == redactor.redactVisibleConversationBody(first))
        // 截断后再追加（不是在上次文本后追加）：必须重建且与全量一致。
        let truncated = "第一段\n新的内容 \(Self.displayKnownSecret) 与 https://example.com/a?api_key=abcdef0123456789"
        #expect(cache.redactedBody(messageID: id, body: truncated, secrets: redactor.secretValues)
            == redactor.redactVisibleConversationBody(truncated))
        #expect(cache.rebuildCount == 2)
        // 脱敏值集合变化：重建。
        let other = ChatTranscriptRedactor(secretValues: ["another-secret-value-1234"])
        let text = truncated + " another-secret-value-1234"
        #expect(cache.redactedBody(messageID: id, body: text, secrets: other.secretValues)
            == other.redactVisibleConversationBody(text))
        #expect(cache.rebuildCount == 3)
        #expect(cache.trackedCount == 1)
        cache.finish(messageID: id)
        #expect(cache.trackedCount == 0)
    }

    @Test func streamingRenderUsesIncrementalDisplayRedactionAndSettlesToFullResult() {
        let secret = "streamed-secret-value-0001"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let cache = ChatTranscriptDocumentCache(formatStore: ChatTranscriptFormatStore())
        let session = UUID()
        var assistant = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let user = ChatMessageUI(role: .user, content: "问")
        let pieces = ["第一行\n", "令牌", "streamed-secret", "-value-0001 后面\n", "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCD\n", "结尾"]
        for piece in pieces {
            assistant.content += piece
            let document = cache.render(
                sessionID: session, messages: [user, assistant], baseSize: 13, redactor: redactor)
            #expect(!document.attributedString.string.contains(secret))
            #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText(
                [user, assistant], redactor: redactor))
        }
        #expect(cache.streamRedaction.incrementalCount > 0)
        #expect(cache.streamRedaction.trackedCount == 1)
        assistant.isStreaming = false
        _ = cache.render(sessionID: session, messages: [user, assistant], baseSize: 13, redactor: redactor)
        #expect(cache.streamRedaction.trackedCount == 0)
        #expect(cache.accessibilityText == ChatTranscriptFormatter.accessibilityText(
            [user, assistant], redactor: redactor))
    }

    @Test func prewarmedSessionOpensThroughCacheHitPath() async {
        let secret = "prewarm-secret-value-0001"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        var messages: [ChatMessageUI] = []
        for i in 0..<30 {
            messages.append(ChatMessageUI(role: i % 2 == 0 ? .user : .assistant,
                content: "第 \(i) 条：**加粗** `code` \(secret) 与列表\n- 要点"))
        }
        messages.append(ChatMessageUI(role: .tool, content: String(repeating: "工具输出行\n", count: 40)))
        let store = ChatTranscriptFormatStore()
        // 与真实视图同一个字号算法（无 typography 环境、默认动态字号）与同一份展示投影。
        let baseSize = ChatTranscriptView.transcriptBaseSize(typography: nil, dynamicTypeSize: .large)
        let iconRevision = ChatTranscriptStatusIconProjection.resourceRevision
        let fresh = await ChatTranscriptPrewarmer.prewarm(
            targets: [.init(messages: messages, projectRoot: nil)],
            baseSize: baseSize, redactor: redactor, palette: nil, iconRevision: iconRevision,
            store: store, batchBudget: .milliseconds(1))
        #expect(fresh == messages.count)
        #expect(store.count == messages.count)

        let displayed = ChatTranscriptDisplayProjectionCache().project(
            messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
        let opened = ChatTranscriptDocumentCache(formatStore: store)
        let warmDocument = opened.render(
            sessionID: UUID(), messages: displayed, baseSize: baseSize, redactor: redactor)
        #expect(opened.lastCacheHitCount == messages.count)
        #expect(opened.lastFreshlyFormattedCount == 0)

        let cold = ChatTranscriptDocumentCache(formatStore: ChatTranscriptFormatStore())
        let coldDocument = cold.render(
            sessionID: UUID(), messages: displayed, baseSize: baseSize, redactor: redactor)
        #expect(cold.lastCacheHitCount == 0)
        #expect(warmDocument.attributedString.string == coldDocument.attributedString.string)
        #expect(opened.accessibilityText == cold.accessibilityText)
        #expect(!warmDocument.attributedString.string.contains(secret))

        // 已预热后再次预热不重做。
        let again = await ChatTranscriptPrewarmer.prewarm(
            targets: [.init(messages: messages, projectRoot: nil)],
            baseSize: baseSize, redactor: redactor, palette: nil, iconRevision: iconRevision, store: store)
        #expect(again == 0)
        // 反向对照：字号不同不得命中（证明命中确实依赖参数一致）。
        let mismatched = ChatTranscriptDocumentCache(formatStore: store)
        _ = mismatched.render(sessionID: UUID(), messages: displayed, baseSize: baseSize + 1, redactor: redactor)
        #expect(mismatched.lastCacheHitCount == 0)
    }
}
