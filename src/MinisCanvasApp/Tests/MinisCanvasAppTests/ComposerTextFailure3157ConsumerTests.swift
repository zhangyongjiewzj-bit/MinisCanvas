import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class TextFailure3157Provider: LLMProvider, @unchecked Sendable {
    let name = "synthetic-text-failure3157"
    var model = LLMModel(id: "synthetic-text-failure3157", displayName: "Owned text control",
                         provider: "synthetic-text-failure3157")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var requests = 0
    var callCount: Int { lock.withLock { requests } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { requests += 1 }
        return LLMResponse(text: "owned text accepted", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { requests += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("owned text accepted"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@Suite("D-COMPOSER-05/08 actual text failure remains a blocked draft", .serialized)
@MainActor
struct ComposerTextFailure3157ConsumerTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "original owned text preparation/submission did not settle")
    }

    @Test("missing, denied and undecodable text traverse the real worker and cannot send",
          arguments: ["missing", "denied", "corrupt"])
    func originalTextFailuresBlockActualSubmitAndExplicitRepairCanSend(reason: String) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "composer-text3157", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: profile.makeLogManager())
        let provider = TextFailure3157Provider()
        // Reuse the existing 2760 synthetic AgentLoop fixture boundary. No
        // production credential, network transport or tool authority is used.
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "synthetic3157",
            grantEpoch: "synthetic3157", leaseID: "synthetic3157", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let injector = SkillInjector(store: SkillStore(
            skillsRoot: profile.rootDirectory.appendingPathComponent("synthetic-skills3157")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider,
                modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:synthetic3157")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety() }
        let owner = try #require(chat.activeSessionID)
        let url = profile.rootDirectory.appendingPathComponent("owned-failure3157.txt")
        if reason == "missing" {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            let bytes = reason == "corrupt" ? Data([0xFF, 0xFE, 0xFF, 0xFE]) : Data("owned readable text".utf8)
            try bytes.write(to: url)
            if reason == "denied" {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
                #expect(!FileManager.default.isReadableFile(atPath: url.path))
            }
        }
        defer {
            if reason == "denied" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }

        let originalMessages = chat.messages
        chat.draftText = "original owned draft3157"
        let pending = try #require(chat.addAttachments(urls: [url]).first)
        #expect(pending.status == .pending && pending.fileType == .text)
        #expect(!ComposerAttachmentPresentation.status(for: pending).claimsSuccess)
        try await waitUntil { chat.pendingAttachments.first?.status == .failed }
        let failed = try #require(chat.pendingAttachments.first)
        #expect(failed.id == pending.id && failed.kind == .file && failed.data == nil)
        #expect(failed.statusText?.isEmpty == false)
        #expect(ComposerAttachmentPresentation.status(for: failed) == .readFailed)
        #expect(!ComposerAttachmentPresentation.status(for: failed).claimsSuccess)
        let value = ComposerAttachmentPresentation.accessibilityValue(for: failed)
        #expect(value.contains(failed.fileName) && value.contains("读取失败") && !value.contains("就绪"))
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: failed.id)?.readiness == .failed)
        #expect(!GlobalComposer.canPreviewPendingAttachment(failed, expectedSessionID: owner,
            activeSessionID: owner, pendingAttachments: chat.pendingAttachments))
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.messages == originalMessages)
        #expect(chat.draftText == "original owned draft3157" && chat.pendingAttachments == [failed])
        #expect(chat.lastComposerSubmissionSnapshot == nil)
        #expect(chat.turnTaskForTests(sessionID: owner) == nil)
        #expect(provider.callCount == 0)

        // Repairing the bytes alone cannot silently retry a failed draft.
        if reason == "denied" {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let repairedBytes = Data("REPAIRED OWNED TEXT3157".utf8)
        try repairedBytes.write(to: url)
        #expect(chat.pendingAttachments == [failed] && !chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.messages == originalMessages && provider.callCount == 0)
        #expect(chat.draftText == "original owned draft3157")

        chat.removePendingAttachment(id: failed.id)
        let retry = try #require(chat.addAttachments(urls: [url]).first)
        #expect(retry.id != failed.id)
        try await waitUntil { chat.pendingAttachments.first?.status == .ready }
        let ready = try #require(chat.pendingAttachments.first)
        #expect(ready.id == retry.id && ready.kind == .text && ready.data == repairedBytes)
        #expect(ComposerAttachmentPresentation.status(for: ready).claimsSuccess)
        #expect(chat.canSubmitComposerAttachments && chat.messages == originalMessages)
        #expect(chat.draftText == "original owned draft3157" && provider.callCount == 0)
        chat.submitComposer()
        try await waitUntil { provider.callCount > 0 && !chat.isActiveSessionStreaming }
        let sent = try #require(chat.messages.last(where: { $0.role == .user }))
        #expect(sent.content.contains("REPAIRED OWNED TEXT3157"))
        #expect(sent.attachments.first?.id == retry.id)
        #expect(chat.pendingAttachments.isEmpty && chat.draftText.isEmpty)
        #expect(chat.lastComposerSubmissionSnapshot?.messageID == sent.id.uuidString)
        #expect(chat.activeSessionID == owner)
    }
}
