import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

actor M03ContextRequestRecorder {
    struct Request: Sendable {
        let contents: [String]
        let maxTokens: Int
        let systemPrompt: String?
    }

    private var requests: [Request] = []
    private var firstReleased = false
    private var firstWaiter: CheckedContinuation<Void, Never>?
    let holdFirst: Bool
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }

    func append(messages: [LLMMessage], maxTokens: Int, systemPrompt: String?) async {
        requests.append(Request(contents: messages.map(\.content), maxTokens: maxTokens, systemPrompt: systemPrompt))
        if holdFirst && requests.count == 1 && !firstReleased {
            await withCheckedContinuation { firstWaiter = $0 }
        }
    }
    func releaseFirst() { firstReleased = true; firstWaiter?.resume(); firstWaiter = nil }

    func recorded() -> [Request] { requests }
}

struct M03ContextRecordingProvider: LLMProvider, Sendable {
    let name = "synthetic"
    var model = LLMModel(
        id: "m03-context-model", displayName: "M03 Context", provider: "synthetic",
        contextWindow: 8_192
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    let recorder: M03ContextRequestRecorder

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await recorder.append(messages: messages, maxTokens: maxTokens, systemPrompt: systemPrompt)
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        await recorder.append(messages: messages, maxTokens: maxTokens, systemPrompt: systemPrompt)
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await recorder.append(messages: messages, maxTokens: maxTokens, systemPrompt: systemPrompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("ok"))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

/// D-CTX3: the real AgentLoop request, rather than a value-only settings test.
@Suite("D-CTX3 context settings reach the next AgentLoop request", .serialized)
@MainActor
struct P3AcceptanceM03_ContextSettingsAgentLoopConsumerTests {
    @Test("settings edits leave the admitted request intact and change the next request")
    func settingsEditsApplyOnNextTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3AcceptanceM03-DCTX3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "P3AcceptanceM03.DCTX3.\(UUID().uuidString)"
        // Retain owned synthetic artifacts for exact-byte diagnosis.

        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: sessions.directory),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skills,
            usageStore: UsageStore(domain: .suite(suiteName)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        let sessionID = "m03-context-session"
        _ = try sessions.createSession(
            id: sessionID, projectID: "m03-context-project", projectName: "Synthetic",
            workingDirectory: root.path
        )
        for message in [
            LLMMessage(role: .user, content: "old-user-marker"),
            LLMMessage(role: .assistant, content: "old-assistant-marker"),
            LLMMessage(role: .user, content: "current-user-marker")
        ] {
            try sessions.saveMessage(message, sessionID: sessionID)
        }

        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "m03-context-workspace", revision: "m03-context-policy",
            grantEpoch: "m03-context-epoch", leaseID: "m03-context-lease",
            expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3
        )
        let manifests = try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json"))
        let engine = AgentLoopChatEngine(
            contextManifestStore: manifests,
            chatRuntimeDependencies: .init(
                sessionStore: sessions, memoryStore: memory, skillStore: skills,
                soulStore: SoulStore(directory: root.appendingPathComponent("soul"))
            ),
            composerPolicyFacts: facts
        )
        let recorder = M03ContextRequestRecorder(holdFirst: true)
        let provider = M03ContextRecordingProvider(recorder: recorder)

        var admittedIdentities: [Int: AgentExecutionIdentity] = [:]
        func admit(_ turnNumber: Int) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            let turn = AgentTurnIdentity(
                sessionID: sessionID, turnID: turnNumber,
                messageID: "assistant:\(turnNumber)"
            )
            let snapshot = ChatTurnRuntimeSnapshot(
                turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil
            )
            let composer = ComposerSubmissionSnapshot(
                mode: .auto, approvalScope: .request, effort: .standard,
                sessionID: sessionID, turnID: turnNumber,
                taskID: "task:\(turnNumber)", attemptID: "attempt:\(turnNumber)",
                messageID: turn.messageID, inputDigest: "digest:\(turnNumber)",
                workspaceID: facts.workspaceID, createdAt: Date(),
                policyRevision: facts.revision, grantEpoch: facts.grantEpoch, autonomyCeiling: .l3
            )
            let identity = AgentExecutionIdentity(turn: turn)
            admittedIdentities[turnNumber] = identity
            return try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "stale-ui-copy")],
                systemPrompt: "synthetic-system", maxTokens: 4_096,
                conversationID: sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turnNumber,
                composerSnapshot: composer,
                executionIdentity: identity,
                turnRuntimeSnapshot: snapshot
            )
        }

        #expect(center.setContextLengthTokens(6_144))
        #expect(center.setHistoryTurnLimit(2))
        func settings() throws -> ContextTurnSettingsSnapshot {
            guard case .accepted(let value) = SettingsCenter.contextTurnSettingsSnapshot(
                for: sessions, sessionID: sessionID, model: provider.model) else {
                throw CocoaError(.coderInvalidValue)
            }
            return value
        }
        let before = try settings()
        // Admit the normal (non-explicit-manifest) request and suspend its
        // actual provider before editing either setting on the same owner.
        let first = try await admit(1)
        for _ in 0..<200 {
            if await recorder.recorded().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.recorded().count == 1)
        let firstIdentity = try #require(admittedIdentities[1])
        let firstRunID = try AgentLoopChatEngine.generatedContextManifestRunID(for: firstIdentity)
        let firstManifest = try #require(manifests.manifest(runID: firstRunID))
        let firstReceipt = try #require(manifests.receipt(runID: firstRunID))
        #expect(center.setContextLengthTokens(1_024))
        #expect(center.setHistoryTurnLimit(1))
        let after = try settings()
        #expect(after.revision != before.revision)
        #expect(before.contextLengthTokens == 6_144 && before.historyTurnLimit == 2)
        #expect(after.contextLengthTokens == 1_024 && after.historyTurnLimit == 1)
        #expect(manifests.manifest(runID: firstRunID) == firstManifest)
        #expect(manifests.receipt(runID: firstRunID) == firstReceipt)
        await recorder.releaseFirst()
        for try await _ in first {}
        let second = try await admit(2)
        for try await _ in second {}

        let calls = await recorder.recorded()
        #expect(calls.count == 2)
        guard calls.count == 2 else { return }
        #expect(calls[0].contents.contains("old-user-marker"))
        #expect(calls[0].contents.contains("old-assistant-marker"))
        #expect(calls[0].contents.contains("current-user-marker"))
        #expect(calls[0].maxTokens == 4_096)
        #expect(calls[1].contents.contains("current-user-marker"))
        #expect(!calls[1].contents.contains("old-user-marker"))
        #expect(!calls[1].contents.contains("old-assistant-marker"))
        #expect(calls[1].maxTokens > 0 && calls[1].maxTokens < 1_024)
        let secondIdentity = try #require(admittedIdentities[2])
        let secondRunID = try AgentLoopChatEngine.generatedContextManifestRunID(for: secondIdentity)
        let secondManifest = try #require(manifests.manifest(runID: secondRunID))
        let secondReceipt = try #require(manifests.receipt(runID: secondRunID))
        #expect(firstManifest.snapshot.configurationFingerprint.hasSuffix(before.revision))
        #expect(secondManifest.snapshot.configurationFingerprint.hasSuffix(after.revision))
        #expect(firstManifest.snapshot.snapshotID != secondManifest.snapshot.snapshotID)
        #expect(firstReceipt.requestedBudget == 6_144)
        #expect(secondReceipt.requestedBudget == 1_024)
        let reopened = try ContextManifestStore(persistenceURL: root.appendingPathComponent("manifests.json"))
        #expect(reopened.manifest(runID: firstReceipt.runID) == firstManifest)
        #expect(reopened.receipt(runID: secondReceipt.runID) == secondReceipt)
        print("CTX705_NEXT_TURN actualCalls=2 history=2->1 budget=6144->1024 revisionsDiffer=true inflightUnchanged=true")
        // Request trimming must not rewrite canonical history.
        let durable = try #require(sessions.loadSession(id: sessionID))
        #expect(Array(durable.messages.prefix(3)).map(\.content) == [
            "old-user-marker", "old-assistant-marker", "current-user-marker"
        ])
    }
}
