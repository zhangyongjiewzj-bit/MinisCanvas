import CoreGraphics
import CryptoKit
import Foundation
import MinisCore
import PDFKit
import Testing
@testable import MinisCanvasApp

private final class PDFNextText0400Provider: LLMProvider, @unchecked Sendable {
    let name = "owned-pdf-next-text0400"
    var model = LLMModel(id: "owned-pdf-next-text0400", displayName: "Owned text control",
                         provider: "owned-pdf-next-text0400", modalityOverride: .textOnly)
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        return LLMResponse(text: "OWNED_PLAIN_REPLY0400", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { captured.append(messages) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("OWNED_PLAIN_REPLY0400"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@Suite("COMPOSER08/MULTIMODAL02/03/04/05 real media worker gates then ordinary text", .serialized)
@MainActor
struct ComposerPDFFailureNextText0400Tests {
    private func textlessPDF() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 32, height: 32)
        let consumer = try #require(CGDataConsumer(data: output as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let data = output as Data
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        #expect(document.page(at: 0)?.string?.isEmpty != false)
        return data
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "original PDF preparation or real ordinary turn did not settle")
    }

    // 目录改为路径引用、无文字层的 PDF 改为渲染成图片（见 ChatStore.resolvePDFAttachment），
    // 不再属于“失败后保持可见”的场景，所以这里只保留 missing 与 corrupt。
    @Test("missing and corrupt PDF stay visible and cannot contaminate a later real text request",
          arguments: ["missing", "corrupt"])
    func failedPDFThenExplicitRemovalSendsOnlyNewText(failure: String) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ComposerPDFNextText0400", processEnvironment: [:],
            processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let inputRoot = profile.rootDirectory.appendingPathComponent("owned-input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = inputRoot.appendingPathComponent("FAILED_SOURCE0400.pdf")
        switch failure {
        case "missing":
            #expect(!FileManager.default.fileExists(atPath: url.path))
        case "nonregular":
            // A wholly owned directory cannot be read as a PDF. No chmod,
            // OS permission grant or access to another owner's data is used.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        case "corrupt": try Data("OWNED_CORRUPT_PDF0400".utf8).write(to: url)
        case "textless": try textlessPDF().write(to: url)
        default: Issue.record("unexpected owned PDF failure input"); return
        }

        let sessions = SessionStore(directory: profile.sessionDirectory)
        let owner = UUID()
        _ = try sessions.createSession(id: owner.uuidString, title: "owned PDF0400",
                                       workingDirectory: inputRoot.path)
        let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        #expect(chat.applySwitchSession(id: owner))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "owned-pdf0400",
            grantEpoch: "owned-pdf0400", leaseID: "owned-pdf0400", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        let provider = PDFNextText0400Provider()
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned-pdf0400")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: inputRoot),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety() }

        let canonicalBefore = try #require(sessions.loadSession(id: owner.uuidString))
        let messagesBefore = chat.messages
        chat.draftText = "BLOCKED_PDF_BODY0400"
        let pending = try #require(chat.addAttachments(urls: [url]).first)
        #expect(pending.status == .pending && !chat.canSubmitComposerAttachments)
        chat.submitComposer()
        if failure == "nonregular" {
            // S23 rejects a directory by removing its placeholder, with visible feedback.
            try await waitUntil { chat.pendingAttachments.isEmpty }
            #expect(chat.pastedTextActionFeedback == "文件夹不能作为附件，请选择文件或先压缩文件夹。")
            #expect(chat.canSubmitComposerAttachments)
        } else {
            try await waitUntil { chat.pendingAttachments.first?.status == .failed }
            let failed = try #require(chat.pendingAttachments.first)
            #expect(failed.id == pending.id && failed.status == .failed && failed.data == nil)
            #expect(failed.failureReason?.isEmpty == false)
            let expectedReason = failure == "corrupt" ? "PDF 文件无法解析"
                : failure == "textless"
                    ? "PDF 已检查范围内没有可提取文本（最多 \(MediaConversion.defaultMaxPDFPages) 页，可能是扫描件）"
                    : "PDF 文件读取失败"
            #expect(failed.failureReason == expectedReason)
            #expect(ComposerAttachmentPresentation.status(for: failed) == .readFailed)
            #expect(!ComposerAttachmentPresentation.status(for: failed).claimsSuccess)
            #expect(ComposerAttachmentPresentation.accessibilityValue(for: failed).contains("读取失败"))
            #expect(!GlobalComposer.canPreviewPendingAttachment(failed, expectedSessionID: owner,
                activeSessionID: owner, pendingAttachments: chat.pendingAttachments))
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: failed.id)?.readiness == .failed)
            #expect(!chat.canSubmitComposerAttachments)
            chat.submitComposer()
        }
        #expect(chat.messages == messagesBefore && chat.draftText == "BLOCKED_PDF_BODY0400")
        #expect(chat.lastComposerSubmissionSnapshot == nil && chat.turnTaskForTests(sessionID: owner) == nil)
        #expect(provider.requests.isEmpty)
        #expect(sessions.loadSession(id: owner.uuidString) == canonicalBefore)
        #expect(try ChatAttachmentPersistence.load(forSessionID: owner.uuidString, from: sessions.directory)?.isEmpty != false)

        // No silent downgrade/retry: remove a retained failure explicitly;
        // a rejected directory is already absent. Then submit a new plain draft.
        if failure != "nonregular" { chat.removePendingAttachment(id: pending.id) }
        chat.draftText = "ONLY_NEW_PLAIN_TEXT0400"
        #expect(chat.pendingAttachments.isEmpty && chat.canSubmitComposerAttachments)
        chat.sendDraft()
        try await waitUntil { !chat.hasStreamingTasksForSafety && provider.requests.count == 1 }
        let request = try #require(provider.requests.first)
        let user = try #require(request.last { $0.role == .user })
        #expect(user.content == "ONLY_NEW_PLAIN_TEXT0400")
        #expect(user.images.isEmpty && user.audios.isEmpty)
        let requestText = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!requestText.contains("BLOCKED_PDF_BODY0400"))
        #expect(!requestText.contains("FAILED_SOURCE0400.pdf") && !requestText.contains("OWNED_CORRUPT_PDF0400"))
        let frozen = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(frozen.sessionID == owner.uuidString)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.allSatisfy { $0.attachments.isEmpty })
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains("OWNED_PLAIN_REPLY0400") })
        let canonicalAfter = try #require(sessions.loadSession(id: owner.uuidString))
        #expect(canonicalAfter.messages.filter { $0.role == .user } == [user])
        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(SessionStore(directory: sessions.directory), badgeStore: badges))
        #expect(reopened.applySwitchSession(id: owner))
        #expect(reopened.messages.filter { $0.role == .user }.map { $0.asLLMMessage() } == [user])
        #expect(reopened.messages.allSatisfy { $0.attachments.isEmpty })
        // The successful plain user owns only its zero text-source count; the
        // assistant owns terminal timing. Neither record may retain failed media.
        let records = try #require(try ChatAttachmentPersistence.load(forSessionID: owner.uuidString, from: sessions.directory))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.attachments.isEmpty })
        let recordText = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!recordText.contains(pending.id.uuidString))
        #expect(!recordText.contains("FAILED_SOURCE0400.pdf"))
        #expect(!recordText.contains("BLOCKED_PDF_BODY0400") && !recordText.contains("OWNED_CORRUPT_PDF0400"))
        for record in records {
            try #require(canonicalAfter.messages.indices.contains(record.messageIndex))
            let canonicalText = canonicalAfter.messages[record.messageIndex].content
            let digest = SHA256.hash(data: Data(canonicalText.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(record.contentDigest == digest)
            #expect(record.referenceCard == nil && record.composedContentOwnership == nil)
        }
        let userIndex = try #require(canonicalAfter.messages.firstIndex { $0.role == .user })
        let plainDigest = SHA256.hash(data: Data(canonicalAfter.messages[userIndex].content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(records.first { $0.messageIndex == userIndex } == ChatAttachmentPersistence.MessageRecord(
            messageIndex: userIndex, contentDigest: plainDigest, attachments: [], producerTextAttachmentCount: 0))
        let timingRecords = records.filter { $0.turnTiming != nil }
        try #require(timingRecords.count == 1)
        #expect(canonicalAfter.messages[timingRecords[0].messageIndex].role == .assistant)
        let liveUser = try #require(chat.messages.first { $0.role == .user })
        let restoredUser = try #require(reopened.messages.first { $0.role == .user })
        #expect(frozen.messageID == liveUser.id.uuidString)
        #expect(liveUser.asLLMMessage() == canonicalAfter.messages[userIndex])
        #expect(restoredUser.asLLMMessage() == canonicalAfter.messages[userIndex])
        #expect(liveUser.trustedSessionReadIntent == nil && restoredUser.trustedSessionReadIntent == nil)
        #expect(liveUser.turnTiming == nil && liveUser.sessionReferenceCard == nil)
        #expect(restoredUser.turnTiming == nil && restoredUser.sessionReferenceCard == nil)
        let assistantIndex = try #require(canonicalAfter.messages.lastIndex { $0.role == .assistant })
        let assistantRecord = try #require(records.first { $0.messageIndex == assistantIndex })
        let timing = try #require(assistantRecord.turnTiming)
        #expect(assistantRecord.trustedSessionReadIntent == nil && assistantRecord.sessionReferenceCard == nil)
        #expect(timing.modelID == provider.model.id && timing.providerName == provider.name)
        #expect(timing.timing.finishedAt != nil && timing.timing.firstTokenAt != nil)
        let liveAssistant = try #require(chat.messages.last { $0.role == .assistant })
        let restoredAssistant = try #require(reopened.messages.last { $0.role == .assistant })
        #expect(liveAssistant.asLLMMessage() == canonicalAfter.messages[assistantIndex])
        #expect(restoredAssistant.asLLMMessage() == canonicalAfter.messages[assistantIndex])
        #expect(liveAssistant.turnTiming == timing.timing && restoredAssistant.turnTiming == timing.timing)
        #expect(chat.composerPolicyFacts == facts)
        // All producer inputs and canonical evidence are wholly synthetic and
        // retained for the next same-head package consumer run.
    }

    @Test("a valid WAV processed by the original worker is blocked by text-only capability, then removal permits one real plain request")
    func unsupportedWorkerAudioCannotBecomeAGlobalTextGate() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ComposerAudioNextText0400", processEnvironment: [:],
            processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let inputRoot = profile.rootDirectory.appendingPathComponent("owned-input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        // Reuse the existing Media589 PCM/WAV fixture recipe. The bytes are
        // generated here so this consumer has no cross-test helper dependency.
        var bytes = Array("RIFF".utf8)
        func u16(_ value: UInt16) { bytes += [UInt8(value & 255), UInt8(value >> 8)] }
        func u32(_ value: UInt32) {
            bytes += [UInt8(value & 255), UInt8((value >> 8) & 255),
                      UInt8((value >> 16) & 255), UInt8(value >> 24)]
        }
        u32(52); bytes += Array("WAVEfmt ".utf8); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        bytes += Array("data".utf8); u32(16); bytes += [UInt8](repeating: 0, count: 16)
        let wav = Data(bytes)
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/wav") == nil)
        let url = inputRoot.appendingPathComponent("UNSUPPORTED_AUDIO0400.wav")
        try wav.write(to: url)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let owner = UUID()
        _ = try sessions.createSession(id: owner.uuidString, title: "owned audio0400",
                                       workingDirectory: inputRoot.path)
        let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        #expect(chat.applySwitchSession(id: owner))
        let provider = PDFNextText0400Provider()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "owned-audio0400",
            grantEpoch: "owned-audio0400", leaseID: "owned-audio0400", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned-audio0400")
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: inputRoot),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety() }
        let original = try #require(sessions.loadSession(id: owner.uuidString))
        chat.draftText = "BLOCKED_AUDIO_BODY0400"
        let pending = try #require(chat.addAttachments(urls: [url]).first)
        #expect(pending.status == .pending)
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let audio = try #require(chat.pendingAttachments.first)
        #expect(audio.id == pending.id && audio.status == .ready && audio.kind == .audio)
        #expect(audio.data == wav && audio.audioAttachment?.format == "wav")
        let readiness = chat.composerMediaReadinessSnapshot
        #expect(readiness.providerID == provider.name && readiness.modelID == provider.model.id)
        #expect(readiness.attachment(id: audio.id)?.readiness == .unsupported)
        #expect(readiness.blockedReason != nil && !chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(provider.requests.isEmpty && !chat.messages.contains { $0.role == .user })
        #expect(chat.draftText == "BLOCKED_AUDIO_BODY0400" && chat.pendingAttachments == [audio])
        #expect(sessions.loadSession(id: owner.uuidString) == original)
        chat.removePendingAttachment(id: audio.id)
        chat.draftText = "ONLY_AUDIO_FOLLOWUP_TEXT0400"
        #expect(chat.canSubmitComposerAttachments && chat.composerMediaReadinessSnapshot.blockedReason == nil)
        chat.sendDraft()
        try await waitUntil { !chat.hasStreamingTasksForSafety && provider.requests.count == 1 }
        let request = try #require(provider.requests.first)
        let user = try #require(request.last { $0.role == .user })
        #expect(user.content == "ONLY_AUDIO_FOLLOWUP_TEXT0400" && user.audios.isEmpty && user.images.isEmpty)
        #expect(request.allSatisfy { $0.audios.isEmpty && !$0.content.contains("BLOCKED_AUDIO_BODY0400")
            && !$0.content.contains("UNSUPPORTED_AUDIO0400.wav") })
        #expect(sessions.loadSession(id: owner.uuidString)?.messages.filter { $0.role == .user } == [user])
        #expect(try Data(contentsOf: url) == wav)
    }
}
