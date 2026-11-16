import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Composer2760CountingProvider: LLMProvider, @unchecked Sendable {
    let name = "synthetic-reference-2760"
    var model = LLMModel(id: "synthetic-reference-2760", displayName: "Synthetic reference", provider: "synthetic-reference-2760")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { calls += 1 }
        return LLMResponse(text: "synthetic reply", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("synthetic reply"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@MainActor
@Suite("D-COMPOSER-08 unknown reference failure at production send", .serialized)
struct ComposerMissingReference2760Tests {
    private func fixture() throws -> (ChatStore, Composer2760CountingProvider, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer2760-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "composer2760-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let provider = Composer2760CountingProvider()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "synthetic2760",
            grantEpoch: "synthetic2760", leaseID: "synthetic2760", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider,
                modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:synthetic2760")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        return (chat, provider, root)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "owned attachment send did not settle")
    }

    @Test("missing or unreadable unknown file stays a failed draft and never reaches Provider",
          arguments: ["missing", "denied"])
    func failedUnknownReferenceBlocksSend(reason: String) async throws {
        let (chat, provider, root) = try fixture()
        defer { chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reference.bin")
        var restorePermissions = false
        defer {
            if restorePermissions {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if reason == "denied" {
            try Data([0x10, 0x20]).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            restorePermissions = true
        } else {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        #expect(staged.kind == .file && staged.fileType == .unknown)
        chat.draftText = "请读取附件"
        chat.submitComposer() // the real boundary awaits the original unknown-file worker
        try await waitUntil {
            chat.pendingAttachments.first?.status == .failed && !chat.isComposerAttachmentPreflightPending
        }
        let failed = try #require(chat.pendingAttachments.first)
        #expect(failed.id == staged.id && failed.data == nil)
        #expect(failed.statusText?.contains("无法读取") == true)
        #expect(ComposerAttachmentPresentation.status(for: failed) == .readFailed)
        #expect(!ComposerAttachmentPresentation.status(for: failed).claimsSuccess)
        #expect(ComposerAttachmentPresentation.accessibilityValue(for: failed).contains("读取失败"))
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: failed.id)?.readiness == .failed)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.pendingAttachments == [failed] && chat.draftText == "请读取附件")
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(provider.callCount == 0)
    }

    @Test("readable unknown file remains a sendable reference on the same production path")
    func readableReferencePositiveControl() async throws {
        let (chat, provider, root) = try fixture()
        defer { chat.stopAllStreamingForSafety(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reference.bin")
        try Data([0x10, 0x20]).write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        chat.draftText = "请读取附件"
        chat.submitComposer()
        try await waitUntil { chat.messages.contains { $0.role == .user } && provider.callCount > 0 }
        #expect(staged.kind == .file && staged.fileType == .unknown)
        #expect(chat.messages.contains { $0.role == .user && $0.content.contains("reference.bin") })
        #expect(provider.callCount > 0)
    }
}
