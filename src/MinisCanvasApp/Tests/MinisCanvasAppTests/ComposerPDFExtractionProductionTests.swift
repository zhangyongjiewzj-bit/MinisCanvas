import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class PDFOfflineProvider: LLMProvider, @unchecked Sendable {
    let name = "pdf-extraction-fixture"
    var model = LLMModel(id: "pdf-extraction-fixture", displayName: "PDF Fixture", provider: "test")

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "fixture", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class PDFCaptureEngine: ChatAgentEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var histories: [[ChatMessageUI]] = []
    var firstHistory: [ChatMessageUI]? { lock.withLock { histories.first } }
    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> { record(history) }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
        maxTokens: Int, conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> { record(history) }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI], systemPrompt: String,
        maxTokens: Int, conversationID: String?, authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot, executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> { record(history) }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }

    private func record(_ history: [ChatMessageUI]) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { histories.append(history) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}

private func isMainThreadForPDFWorkerCheck() -> Bool {
    Thread.isMainThread
}

/// Compare every JSON field while reporting only changed paths, so an
/// unsorted encoder's dictionary order cannot masquerade as sent-data drift.
private func pdfJSONFieldDifferences(_ before: Data, _ after: Data) throws -> [String] {
    let original = try JSONSerialization.jsonObject(with: before)
    let current = try JSONSerialization.jsonObject(with: after)
    var differences: [String] = []
    func walk(_ left: Any, _ right: Any, path: String) {
        if let left = left as? [String: Any], let right = right as? [String: Any] {
            for key in Set(left.keys).union(right.keys).sorted() {
                let childPath = path + "/" + key.replacingOccurrences(of: "~", with: "~0")
                    .replacingOccurrences(of: "/", with: "~1")
                switch (left[key], right[key]) {
                case (.some(let old), .some(let new)):
                    walk(old, new, path: childPath)
                default:
                    differences.append(childPath)
                }
            }
        } else if let left = left as? [Any], let right = right as? [Any] {
            if left.count != right.count { differences.append(path + "/length") }
            for index in 0..<min(left.count, right.count) {
                walk(left[index], right[index], path: path + "/\(index)")
            }
        } else {
            let leftBytes = try? JSONSerialization.data(withJSONObject: left, options: [.fragmentsAllowed])
            let rightBytes = try? JSONSerialization.data(withJSONObject: right, options: [.fragmentsAllowed])
            if leftBytes != rightBytes { differences.append(path) }
        }
    }
    walk(original, current, path: "$")
    return differences
}

@Suite("D-MULTIMODAL-05 PDF production text consumer")
@MainActor
struct ComposerPDFExtractionProductionTests {
    /// Real text-layer pages, with nil standing for a scanned/blank page.
    private func pdfFixture(pages: [String?]) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return Data()
        }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: attributes)
                )
                context.textPosition = CGPoint(x: 72, y: box.height - 72)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: output as Data)?.dataRepresentation() ?? (output as Data)
    }

    private func writeFixture(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func awaitSettled(_ chat: ChatStore) async throws {
        for _ in 0..<100 where chat.pendingAttachments.contains(where: { $0.status == .pending }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(chat.pendingAttachments.allSatisfy { $0.status != .pending })
    }

    @Test("ready PDF extraction reaches the existing right-panel preview without rereading PDF bytes")
    func realPDFExtractionFeedsRightPanelPreview() async throws {
        let chat = ChatStore()
        let url = try writeFixture(pdfFixture(pages: ["ALPHA extracted page", "BETA extracted page"]),
                                   name: "preview.pdf")
        _ = chat.addAttachments(urls: [url])
        try await awaitSettled(chat)
        let attachment = try #require(chat.pendingAttachments.first)
        #expect(attachment.status == .ready)
        #expect(attachment.kind == .text)
        #expect(ComposerAttachmentPresentation.status(for: attachment) == .ready)
        #expect(ComposerAttachmentPresentation.status(for: attachment).claimsSuccess)
        #expect(!ComposerAttachmentPresentation.accessibilityValue(for: attachment).contains("失败"))
        let sessionID = try #require(chat.activeSessionID)
        #expect(GlobalComposer.canPreviewPendingAttachment(attachment, expectedSessionID: sessionID,
            activeSessionID: sessionID, pendingAttachments: chat.pendingAttachments))
        let selection = ChatAttachmentPreviewSelection(sessionID: sessionID, attachment: attachment,
            url: try ChatAttachmentOpenTarget().resolve(attachment))
        #expect(selection.visible(in: sessionID) == selection)
        #expect(selection.visible(in: UUID()) == nil)
        #expect(ChatAttachmentPreviewSelection(sessionID: sessionID, url: url,
            agentWorkspaceRoot: url.deletingLastPathComponent(),
            extractedPDFText: selection.extractedPDFText).extractedPDFText == nil)
        #expect(FileKind(url: url) == .other) // Generic file support is unchanged.
        let fileTree = FileTreeStore(rootURL: url.deletingLastPathComponent())
        fileTree.selectAttachment(selection)
        let preview = try #require(fileTree.preview)
        #expect(fileTree.selectedURL == url)
        #expect(preview.kind == .text)
        #expect(preview.text?.contains("ALPHA extracted page") == true)
        #expect(preview.text?.contains("BETA extracted page") == true)
        #expect(preview.text?.contains("[原文第 1 页]") == true)
        let extractedData = try #require(attachment.data)
        let extractedText = try #require(String(data: extractedData, encoding: .utf8))
        #expect(preview.text == FilePreview.truncated(extractedText))
        #expect(preview.error == nil)
        #expect(preview.imageData == nil && preview.videoURL == nil)
        fileTree.clearChatAttachmentSelection()
        #expect(fileTree.preview == nil)
        #expect(fileTree.selectedURL == nil)
        // Retain the owned fixture; no real source or file tree is deleted.
    }

    @Test("the real addAttachments path freezes source, byte limit and original PDF page numbers")
    func realConsumerKeepsPageProvenance() async throws {
        let chat = ChatStore()
        let pdfBytes = pdfFixture(pages: [nil, "ALPHA page two", nil, "BETA page four"])
        let url = try writeFixture(pdfBytes, name: "source.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let added = chat.addAttachments(urls: [url])
        #expect(added.count == 1)
        #expect(added.first?.status == .pending)
        #expect(!chat.canSubmitComposerAttachments)
        try await awaitSettled(chat)
        let attachment = try #require(chat.pendingAttachments.first)
        #expect(attachment.status == .ready)
        #expect(attachment.kind == .text)
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.size == Int64(pdfBytes.count))
        let content = ChatStore.composeUserContent(text: "总结", attachments: [attachment])
        #expect(content.contains("source.pdf"))
        #expect(content.contains("[原文第 2 页]"))
        #expect(content.contains("[原文第 4 页]"))
        #expect(!content.contains("[原文第 1 页]"))
        #expect(content.contains("仅包含提取的文本层，不含原生 PDF"))
        #expect(!content.contains("file_read 工具读取全文"))
    }

    @Test("actual missing, permission-denied and corrupt PDF failures reach the chip without claiming success",
          arguments: ["missing", "permission-denied", "corrupt"])
    func realPDFFailureFeedsAttachmentStatus(failure: String) async throws {
        let chat = ChatStore()
        let url: URL
        if failure == "missing" {
            let anchor = try writeFixture(Data("owned fixture".utf8), name: "anchor.txt")
            url = anchor.deletingLastPathComponent().appendingPathComponent("missing.pdf")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else if failure == "permission-denied" {
            url = try writeFixture(pdfFixture(pages: ["UNREADABLE owned page"]), name: "unreadable.pdf")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        } else {
            url = try writeFixture(Data("not a PDF".utf8), name: "corrupt.pdf")
        }
        defer {
            if failure == "permission-denied" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            // Keep the owned fixture; restore only its synthetic permission change.
        }
        let added = chat.addAttachments(urls: [url])
        let pending = try #require(added.first)
        #expect(pending.status == .pending)
        #expect(ComposerAttachmentPresentation.status(for: pending) == .reading)
        #expect(!ComposerAttachmentPresentation.status(for: pending).claimsSuccess)
        try await awaitSettled(chat)
        #expect(chat.pendingAttachments.count == 1)
        let failed = try #require(chat.pendingAttachments.first)
        #expect(failed.id == pending.id)
        #expect(failed.status == .failed && failed.kind == .file && failed.data == nil)
        #expect(failed.failureReason == (failure == "corrupt" ? "PDF 文件无法解析" : "PDF 文件读取失败"))
        let projection = ComposerAttachmentPresentation.status(for: failed)
        #expect(projection == .readFailed)
        #expect(!projection.claimsSuccess)
        let value = ComposerAttachmentPresentation.accessibilityValue(for: failed)
        #expect(value.contains(failed.fileName))
        #expect(value.contains("读取失败"))
        #expect(value.contains(try #require(failed.failureReason)))
        #expect(!value.contains("就绪"))
        #expect(SessionSidebarAttachmentChipInfo(failed).statusText == failed.failureReason)
        let sessionID = try #require(chat.activeSessionID)
        #expect(!GlobalComposer.canPreviewPendingAttachment(failed, expectedSessionID: sessionID,
            activeSessionID: sessionID, pendingAttachments: chat.pendingAttachments))
        let selection = ChatAttachmentPreviewSelection(sessionID: sessionID, attachment: failed, url: url)
        #expect(selection.extractedPDFText == nil)
        #expect(!chat.canSubmitComposerAttachments)
        // The ready PDF control above traverses the same actual producer and preview consumer.
    }

    @Test("page and character budgets do not renumber omitted pages or claim full coverage")
    func boundedPrimitiveReportsPartialCoverageOnWorker() async throws {
        let bytes = pdfFixture(pages: [nil, "ABCDEFGHIJ", "later page"])
        // Exercise the same synchronous PDFKit primitive from a detached
        // worker, rather than merely checking source annotations. The real
        // addAttachments test above also requires the guarded worker result
        // to become ready, so a MainActor regression fails behaviorally.
        let worker = await Task.detached(priority: .userInitiated) {
            let onMainThread = isMainThreadForPDFWorkerCheck()
            let bounded = MediaConversion.extractPDFPages(
                bytes, maxPages: 2, maxCharacters: 4
            )
            let oversize = MediaConversion.extractPDFPages(
                bytes, maxInputBytes: bytes.count - 1
            )
            return (onMainThread, bounded, oversize)
        }.value
        #expect(!worker.0)
        guard case .success(let result) = worker.1 else {
            Issue.record("synthetic PDF must have extractable text")
            return
        }
        #expect(result.pages.count == 1)
        #expect(result.pages.first?.pageNumber == 2)
        #expect(result.pages.first?.text == "ABCD")
        #expect(result.totalPageCount == 3)
        #expect(result.inspectedPageCount == 2)
        #expect(result.isTruncated)
        if case .failure(.sourceTooLarge) = worker.2 {} else {
            Issue.record("oversize PDF must fail with the size reason")
        }
    }

    @Test("textless, corrupt and oversize PDFs remain visible failed drafts and never send")
    func failedPDFsRequireExplicitRemoval() async throws {
        let chat = ChatStore()
        let textless = try writeFixture(pdfFixture(pages: [nil]), name: "scanned.pdf")
        let corrupt = try writeFixture(Data("not a pdf".utf8), name: "corrupt.pdf")
        let oversize = try writeFixture(
            Data(repeating: 0x20, count: MediaConversion.defaultMaxPDFInputBytes + 1), name: "large.pdf"
        )
        defer {
            for url in [textless, corrupt, oversize] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        chat.draftText = "请读 PDF"
        chat.addAttachments(urls: [textless, corrupt, oversize])
        try await awaitSettled(chat)
        #expect(chat.pendingAttachments.count == 3)
        #expect(chat.pendingAttachments.allSatisfy { $0.status == .failed && $0.data == nil })
        #expect(chat.pendingAttachments[0].statusText?.contains("没有可提取文本") == true)
        #expect(chat.pendingAttachments[1].statusText?.contains("无法解析") == true)
        #expect(chat.pendingAttachments[2].statusText?.contains("超过") == true)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.draftText == "请读 PDF")
        #expect(chat.messages.allSatisfy { $0.role != .user })
    }

    @Test("resolution owns its original session and sent page text stays frozen across replay")
    func sessionOwnerAndSentHistoryRemainFrozen() async throws {
        let chat = ChatStore()
        let engine = PDFCaptureEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = PDFOfflineProvider()
        let owner = try #require(chat.activeSessionID)
        let url = try writeFixture(pdfFixture(pages: ["FROZEN PAGE"]), name: "frozen.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pending = try #require(chat.addAttachments(urls: [url]).first)
        let other = chat.applyNewSession(title: "other")
        #expect(chat.activeSessionID == other)
        #expect(chat.pendingAttachments.isEmpty)
        chat.switchSession(id: owner)
        try await awaitSettled(chat)
        let ready = try #require(chat.pendingAttachments.first)
        #expect(ready.id == pending.id)
        #expect(ready.status == .ready)
        #expect(ready.data != nil)

        chat.draftText = "冻结 PDF"
        chat.submitComposer()
        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        let snapshotDigest = try #require(chat.lastComposerSubmissionSnapshot?.inputDigest)
        let originalBytes = try JSONEncoder().encode(sent)
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let canonicalOriginalBytes = try canonicalEncoder.encode(sent)
        #expect(sent.content.contains("[原文第 1 页]"))
        #expect(sent.content.contains("FROZEN PAGE"))
        #expect(sent.asLLMMessage().content == sent.content)
        #expect(sent.asLLMMessage().images.isEmpty)
        #expect(sent.asLLMMessage().audios.isEmpty)
        let late = ChatAttachment(
            id: pending.id, kind: .text, fileName: "frozen.pdf", fileType: .unknown,
            mimeType: "application/pdf", data: Data("late replacement".utf8),
            fileURL: url.path
        )
        chat.applyComposerAttachmentResolution(late, sessionID: owner)
        chat.switchSession(id: other)
        chat.applyComposerAttachmentResolution(late, sessionID: owner)
        chat.switchSession(id: owner)
        let unchanged = try #require(chat.messages.last(where: { $0.id == sent.id }))
        let unchangedBytes = try JSONEncoder().encode(unchanged)
        let changedPaths = try pdfJSONFieldDifferences(originalBytes, unchangedBytes)
        let canonicalUnchangedBytes = try canonicalEncoder.encode(unchanged)
        print("PDF238_FROZEN_JSON rawBytesEqual=\(unchangedBytes == originalBytes) canonicalBytesEqual=\(canonicalUnchangedBytes == canonicalOriginalBytes) changedPaths=\(changedPaths)")
        #expect(changedPaths.isEmpty, "sent JSON field changes: \(changedPaths)")
        #expect(canonicalUnchangedBytes == canonicalOriginalBytes)
        #expect(unchanged == sent)
        #expect(chat.lastComposerSubmissionSnapshot?.inputDigest == snapshotDigest)
        let replayed = try JSONDecoder().decode(ChatMessageUI.self, from: originalBytes)
        #expect(replayed.content == sent.content)
        #expect(replayed.attachments == sent.attachments)
        for _ in 0..<50 where engine.firstHistory == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstRequest = try #require(engine.firstHistory?.last(where: { $0.role == .user }))
        #expect(firstRequest.content == sent.content)
        #expect(firstRequest.attachments == sent.attachments)
    }
}
