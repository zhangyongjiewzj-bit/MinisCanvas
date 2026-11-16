import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// Controls only the LLM boundary. Attachment classification/worker, ordinary
// ChatStore submission, AgentLoop and both persistence stores are production.
private final class ComposerFailedTextProvider0741: LLMProvider, @unchecked Sendable {
    let name = "composer-failed-text-owned-0741"
    var model = LLMModel(id: "composer-failed-text-0741", displayName: "Owned Text Consumer",
        provider: "composer-failed-text-owned-0741")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captures: [[LLMMessage]] = []
    private var streams = 0
    var requests: [[LLMMessage]] { lock.withLock { captures } }
    var streamCallCount: Int { lock.withLock { streams } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captures.append(messages) }
        return LLMResponse(text: "0741 owned completion", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { streams += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-COMPOSER-08 failed text worker and explicit file-reference recovery", .serialized)
@MainActor
struct ComposerFailedTextReference0741Tests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "actual owned producer/ordinary request reached bounded phase")
    }
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("invalid UTF8 stays visibly failed and sends nothing until explicit removal and real file-source recovery")
    func failedTextWorkerExplicitReferenceAndNextOrdinaryRequestStaySessionOwned() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("composer-failed-text-0741-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let a = UUID(), b = UUID()
        for id in [a, b] {
            _ = try sessions.createSession(id: id.uuidString, title: "Owned Failed Text",
                projectID: "composer-owned-0741", projectName: "Synthetic 0741", workingDirectory: root.path)
        }
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root.appendingPathComponent("souls"))
        let chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        chat.attachDraftStore(drafts)
        chat.restoreSpeedTier(.fast)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "composer0741-policy", grantEpoch: "composer0741-epoch",
            leaseID: "composer0741-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions, memoryStore: memory,
                skillStore: skills, soulStore: souls),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts).withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = ComposerFailedTextProvider0741()
        chat.streamingProviderOverride = provider
        let aText = "OWNED0741_EXPLICIT_REFERENCE_REQUEST"
        let bText = "OWNED0741_B_UNSENT_DRAFT"
        let nextText = "OWNED0741_NEXT_PLAIN_REQUEST"
        let secretMaterial = "OWNED0741_BINARY_MATERIAL_NOT_DECODED"
        let invalid = Data([0xFF, 0xFE, 0xFF]) + Data(secretMaterial.utf8)
        #expect(String(data: invalid, encoding: .utf8) == nil)
        let brokenURL = root.appendingPathComponent("owned-broken0741.txt")
        let referenceURL = root.appendingPathComponent("owned-reference0741.bin")
        try invalid.write(to: brokenURL)
        try invalid.write(to: referenceURL)
        #expect(chat.applySwitchSession(id: b))
        chat.draftText = bText
        #expect(chat.flushPendingDraftForTermination() && drafts.flushAll())
        let bKey = DraftStore.chatDraftKey(sessionID: b)
        let bDraftBytes = try #require(drafts.load(key: bKey))
        #expect(chat.applySwitchSession(id: a))
        chat.draftText = aText
        let placeholders = chat.addAttachments(urls: [brokenURL])
        let placeholder = try #require(placeholders.first)
        #expect(placeholder.status == .pending && placeholder.fileURL == brokenURL.path)
        try await waitUntil { chat.pendingAttachments.first?.status == .failed }
        let failed = try #require(chat.pendingAttachments.first)
        #expect(failed.id == placeholder.id && failed.kind == .file && failed.fileType == .text)
        #expect(failed.data == nil && failed.fileURL == brokenURL.path)
        #expect(ComposerAttachmentPresentation.status(for: failed) == .readFailed)
        #expect(!ComposerAttachmentPresentation.status(for: failed).claimsSuccess)
        #expect(ComposerAttachmentPresentation.accessibilityValue(for: failed).contains("读取失败"))
        #expect(failed.statusText?.isEmpty == false && chat.composerAttachmentBlockReason != nil)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(provider.requests.isEmpty && chat.lastComposerSubmissionSnapshot == nil)
        #expect(chat.draftText == aText && chat.pendingAttachments == [failed])
        #expect(sessions.loadSession(id: a.uuidString)?.messages.isEmpty == true)
        let beforeSendRecords = try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory)
        #expect((beforeSendRecords ?? []).isEmpty)
        #expect(chat.applySwitchSession(id: b))
        #expect(chat.draftText == bText && chat.pendingAttachments.isEmpty)
        let bURL = sessions.sessionsDirectory.appendingPathComponent(b.uuidString + ".json")
        let bCanonicalBytes = try Data(contentsOf: bURL)
        let late = ChatAttachment(id: failed.id, kind: .text, fileName: failed.fileName,
            fileType: .text, data: Data("OWNED0741_LATE_CALLBACK_POISON".utf8), fileURL: brokenURL.path)
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        chat.applyComposerAttachmentResolution(late, sessionID: b)
        #expect(chat.draftText == bText && chat.pendingAttachments.isEmpty)
        #expect(chat.applySwitchSession(id: a))
        #expect(chat.draftText == aText && chat.pendingAttachments == [failed])
        #expect(provider.requests.isEmpty)
        chat.removePendingAttachment(id: failed.id)
        #expect(chat.pendingAttachments.isEmpty && chat.draftText == aText && provider.requests.isEmpty)

        // The replacement runs addAttachments and its real unknown-file source
        // validator, rather than constructing a ready file-reference record.
        let references = chat.addAttachments(urls: [referenceURL])
        let initialReference = try #require(references.first)
        #expect(initialReference.id != failed.id && initialReference.kind == .file)
        try await waitUntil { chat.pendingAttachments.first?.size == Int64(invalid.count) }
        let reference = try #require(chat.pendingAttachments.first)
        #expect(reference.id == initialReference.id && reference.status == .ready && reference.data == nil)
        #expect(reference.fileType == .unknown && reference.fileURL == referenceURL.path)
        #expect(ComposerAttachmentPresentation.status(for: reference) == .referenceOnly)
        #expect(!ComposerAttachmentPresentation.status(for: reference).claimsSuccess)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: reference.id)?.readiness == .referenceOnly)
        #expect(chat.canSubmitComposerAttachments && provider.requests.isEmpty)
        chat.submitComposer()
        let firstSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let sent = try #require(chat.messages(forSession: a)?.last(where: { $0.role == .user }))
        #expect(firstSnapshot.sessionID == a.uuidString && firstSnapshot.messageID == sent.id.uuidString)
        #expect(firstSnapshot.mode == .plan && firstSnapshot.approvalScope == .request)
        #expect(firstSnapshot.policyRevision == facts.revision && firstSnapshot.grantEpoch == facts.grantEpoch)
        #expect(sent.attachments == [reference] && chat.pendingAttachments.isEmpty && chat.draftText.isEmpty)
        #expect(chat.applySwitchSession(id: b))
        try await waitUntil {
            provider.requests.count == 1 && chat.messages(forSession: a)?.last(where: {
                $0.role == .assistant
            })?.turnTiming?.finishedAt != nil
        }
        let firstWire = try #require(provider.requests.first?.last(where: { $0.role == .user }))
        #expect(firstWire == sent.asLLMMessage())
        #expect(firstWire.content.contains(aText) && firstWire.content.contains(referenceURL.lastPathComponent))
        #expect(firstWire.content.contains(referenceURL.path) && firstWire.images.isEmpty)
        #expect(!firstWire.content.contains(brokenURL.lastPathComponent) && !firstWire.content.contains(secretMaterial))
        #expect(!firstWire.content.contains("OWNED0741_LATE_CALLBACK_POISON") && !firstWire.content.contains(bText))
        #expect(chat.pendingAttachments.isEmpty && chat.draftText == bText && drafts.load(key: bKey) == bDraftBytes)
        #expect(try Data(contentsOf: bURL) == bCanonicalBytes)
        #expect(chat.applySwitchSession(id: a))
        let recordsAfterFirst = try #require(try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory))
        let firstRecord = try #require(recordsAfterFirst.first(where: { $0.attachments.contains(where: { $0.id == reference.id }) }))
        #expect(firstRecord.attachments == [reference] && firstRecord.contentDigest == digest(sent.content))
        let aURL = sessions.sessionsDirectory.appendingPathComponent(a.uuidString + ".json")
        let sidecarURL = ChatAttachmentPersistence.sessionSidecarURL(for: a, in: sessions.directory)
        let aBeforeLate = try Data(contentsOf: aURL), sidecarBeforeLate = try Data(contentsOf: sidecarURL)
        chat.applyComposerAttachmentResolution(late, sessionID: a)
        #expect(chat.pendingAttachments.isEmpty && chat.draftText.isEmpty)
        #expect(try Data(contentsOf: aURL) == aBeforeLate && Data(contentsOf: sidecarURL) == sidecarBeforeLate)
        chat.draftText = nextText
        chat.submitComposer()
        let nextSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let next = try #require(chat.messages(forSession: a)?.last(where: { $0.role == .user }))
        #expect(next.id != sent.id && next.attachments.isEmpty && next.content == nextText)
        #expect(nextSnapshot.messageID == next.id.uuidString && nextSnapshot.attemptID != firstSnapshot.attemptID)
        try await waitUntil {
            provider.requests.count == 2 && chat.messages(forSession: a)?.last(where: {
                $0.role == .assistant
            })?.turnTiming?.finishedAt != nil
        }
        let nextWire = try #require(provider.requests.last?.last(where: { $0.role == .user }))
        #expect(nextWire == next.asLLMMessage() && nextWire.content == nextText && nextWire.images.isEmpty)
        #expect(provider.requests.flatMap { $0 }.allSatisfy {
            !$0.content.contains(brokenURL.lastPathComponent) && !$0.content.contains(secretMaterial)
                && !$0.content.contains("OWNED0741_LATE_CALLBACK_POISON")
        })
        let canonical = try #require(sessions.loadSession(id: a.uuidString))
        #expect(canonical.messages.filter { $0.role == .user }.count == 2)
        let records = try #require(try ChatAttachmentPersistence.load(forSessionID: a.uuidString, from: sessions.directory))
        #expect(records.first(where: { $0.messageIndex == firstRecord.messageIndex }) == firstRecord)
        try #require(canonical.messages.indices.contains(firstRecord.messageIndex))
        #expect(canonical.messages[firstRecord.messageIndex] == firstWire)
        let nextIndex = try #require(canonical.messages.lastIndex(of: nextWire))
        #expect(nextIndex > firstRecord.messageIndex)
        #expect(next.trustedSessionReadIntent == nil && next.attachments.isEmpty)
        // The new plain-message producer explicitly owns a zero text-source count.
        #expect(records.first(where: { $0.messageIndex == nextIndex }) == ChatAttachmentPersistence.MessageRecord(
            messageIndex: nextIndex, contentDigest: digest(canonical.messages[nextIndex].content),
            attachments: [], producerTextAttachmentCount: 0))
        #expect(digest(canonical.messages[nextIndex].content) == digest(nextText))
        #expect(canonical.messages[nextIndex] == nextWire)
        #expect(records.allSatisfy { !$0.attachments.contains(where: { $0.id == failed.id }) })
        #expect(try Data(contentsOf: brokenURL) == invalid && Data(contentsOf: referenceURL) == invalid)
        #expect(provider.requests.count == 2 && provider.streamCallCount == 0)
        #expect(chat.composerPolicyFacts == facts && ledger.facts.isEmpty)
        #expect(try Data(contentsOf: bURL) == bCanonicalBytes && drafts.load(key: bKey) == bDraftBytes)
        let reopened = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("fresh-logs")))
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(SessionStore(directory: sessions.directory), badgeStore: badges))
        #expect(reopened.applySwitchSession(id: a))
        let restored = try #require(reopened.messages.first(where: { $0.role == .user && $0.content == sent.content }))
        #expect(restored.asLLMMessage() == firstWire && restored.attachments == [reference])
        #expect(reopened.messages.first(where: { $0.role == .user && $0.content == nextText })?.attachments.isEmpty == true)
        #expect(reopened.messages.last(where: { $0.role == .assistant })?.turnTiming?.finishedAt != nil)
        #expect(reopened.applySwitchSession(id: b) && reopened.messages.isEmpty)
        print("COMPOSER0741 failed=\(failed.id) reference=\(reference.id) sent=\(sent.id) next=\(next.id) origin=\(a) neighbor=\(b) requests=\(provider.requests.count) sidecar=\(sidecarURL.path)")
    }
}
