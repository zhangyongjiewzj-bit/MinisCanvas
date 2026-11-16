import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Main transcript answer-only regeneration production consumer", .serialized)
@MainActor
struct TranscriptRegenerationProductionConsumerTests {
    @Test func regenerationCreatesANewTurnAndKeepsHistoryAndGlobalPolicy() async throws {
        let f = try await fixture(attack: false)
        defer { f.chat.stopAllStreamingForSafety(); f.registry.disconnectAll(); try? f.profile.cleanupDisposableRoots() }
        try await send("original question", chat: f.chat, provider: f.provider)
        let session = try #require(f.chat.activeSessionID)
        let answer = try #require(f.chat.messages.last(where: { $0.role == .assistant }))
        let history = f.chat.messages
        let snapshot = try #require(f.chat.lastComposerSubmissionSnapshot)
        let selection = f.chat.composerPolicySelection
        let facts = f.chat.composerPolicyFacts
        let revision = try #require(f.chat.transcriptRevision(forSession: session))
        #expect(await f.chat.regenerateAnswer(sessionID: session, messageID: answer.id, expectedRevision: revision))
        await finish(f.chat, session: session)
        let next = try #require(f.chat.lastComposerSubmissionSnapshot)
        #expect(next.turnID > snapshot.turnID && next.taskID != snapshot.taskID)
        #expect(next.sessionID == snapshot.sessionID)
        #expect(f.chat.messages.starts(with: history))
        #expect(f.chat.messages.last(where: { $0.role == .assistant })?.id != answer.id)
        #expect(f.chat.draftText.isEmpty && f.chat.pendingAttachments.isEmpty)
        #expect(f.chat.composerPolicySelection == selection && f.chat.composerPolicyFacts == facts)
        #expect(f.provider.catalogs.last == [])
        #expect(f.transport.calls == 0)
    }

    @Test(arguments: [ComposerTaskMode.manual, .bypassPermission])
    func forgedBuiltinAndMCPCallsHaveNoEffectAndTheNextOrdinaryTurnCanWrite(mode: ComposerTaskMode) async throws {
        let f = try await fixture(attack: true, mode: mode)
        defer { f.chat.stopAllStreamingForSafety(); f.registry.disconnectAll(); try? f.profile.cleanupDisposableRoots() }
        try await send("original question", chat: f.chat, provider: f.provider)
        let session = try #require(f.chat.activeSessionID)
        let answer = try #require(f.chat.messages.last(where: { $0.role == .assistant }))
        #expect(await f.chat.regenerateAnswer(sessionID: session, messageID: answer.id,
            expectedRevision: try #require(f.chat.transcriptRevision(forSession: session))))
        await finish(f.chat, session: session)
        #expect(!FileManager.default.fileExists(atPath: f.provider.target.path))
        #expect(f.transport.calls == 0)
        #expect(await f.approval.calls == 0)
        #expect(f.provider.catalogs.dropFirst().allSatisfy { $0.isEmpty })
        #expect(f.provider.requests.contains { messages in
            messages.contains { $0.content.contains("regen-file") && $0.content.contains("is_error") }
        })
        #expect(f.provider.requests.contains { messages in
            messages.contains { $0.content.contains("regen-mcp") && $0.content.contains("is_error") }
        })
        // A separate explicit ordinary send must regain the unchanged runtime.
        try await send("ordinary write", chat: f.chat, provider: f.provider)
        #expect(try String(contentsOf: f.provider.target, encoding: .utf8) == "ordinary-effect")
        #expect(await f.approval.calls == (mode == .manual ? 1 : 0))
        #expect(f.provider.catalogs.last?.contains("file_write") == true)
        #expect(f.chat.composerPolicySelection.mode == mode)
    }

    @Test func staleOwnersDraftAttachmentsAndLiveGenerationAreRefusedWithoutLosingInput() async throws {
        let f = try await fixture(attack: false)
        defer {
            f.provider.release.continuation.finish()
            f.chat.stopAllStreamingForSafety(); f.registry.disconnectAll(); try? f.profile.cleanupDisposableRoots()
        }
        try await send("original question", chat: f.chat, provider: f.provider)
        let session = try #require(f.chat.activeSessionID)
        let answer = try #require(f.chat.messages.last(where: { $0.role == .assistant }))
        let revision = try #require(f.chat.transcriptRevision(forSession: session))
        let history = f.chat.messages
        #expect(await f.chat.regenerateAnswer(sessionID: UUID(), messageID: answer.id, expectedRevision: revision) == false)
        #expect(await f.chat.regenerateAnswer(sessionID: session, messageID: answer.id, expectedRevision: revision &+ 1) == false)
        f.chat.draftText = "retain unsent draft"
        let attachmentURL = f.profile.rootDirectory.appendingPathComponent("owned.g22fixture")
        try Data([0, 1, 255, 2]).write(to: attachmentURL)
        let added = try #require(f.chat.addAttachments(urls: [attachmentURL]).first)
        let preparation = try #require(f.chat.attachmentPreparationTask(for: added, sessionID: session))
        let resolved = await preparation.value
        let attachments = f.chat.pendingAttachments
        #expect(attachments == [resolved] && resolved.id == added.id && resolved.status == .ready)
        #expect(await f.chat.regenerateAnswer(sessionID: session, messageID: answer.id, expectedRevision: revision) == false)
        #expect(f.chat.draftText == "retain unsent draft" && f.chat.pendingAttachments == attachments)
        #expect(f.chat.messages == history && f.provider.requests.count == 1)
        f.chat.removePendingAttachment(id: added.id)
        #expect(f.chat.pendingAttachments.isEmpty)
        f.chat.draftText = "hold ordinary"
        f.chat.submitComposer()
        let running = try #require(f.chat.turnTaskForTests(sessionID: session))
        let completion = Task { await running.value; f.provider.entered.continuation.finish() }
        var entered = f.provider.entered.stream.makeAsyncIterator()
        _ = try #require(await entered.next(), "The owned provider must receive the live turn before this guard is tested")
        let liveHistory = f.chat.messages
        #expect(await f.chat.regenerateAnswer(sessionID: session, messageID: answer.id,
            expectedRevision: try #require(f.chat.transcriptRevision(forSession: session))) == false)
        #expect(f.chat.messages == liveHistory)
        f.provider.release.continuation.finish()
        await running.value
        await completion.value
    }

    private func send(_ text: String, chat: ChatStore, provider: RegenerationProvider) async throws {
        let requestCount = provider.requests.count
        let oldAnswers = Set(chat.messages.filter { $0.role == .assistant }.map(\.id))
        chat.draftText = text
        let session = try #require(chat.activeSessionID)
        chat.submitComposer()
        await finish(chat, session: session)
        #expect(!chat.isActiveSessionGenerating)
        try #require(provider.requests.count > requestCount,
            "Owned ordinary Provider was not reached; final synthetic message: \(chat.messages.last?.content ?? "none")")
        let answer = try #require(chat.messages.last(where: { $0.role == .assistant }))
        try #require(!oldAnswers.contains(answer.id) && !answer.isStreaming && !answer.wasInterrupted
            && answer.content == "已完成的合成回答", Comment(rawValue:
                "The original ordinary turn must succeed before regeneration is exercised; "
                    + "fixture input=\(text), requestDelta=\(provider.requests.count - requestCount), "
                    + "actualAnswer=\(chat.credentialBroker.protect(answer.content))"))
    }
    private func finish(_ chat: ChatStore, session: UUID) async {
        if let running = chat.turnTaskForTests(sessionID: session) { await running.value }
    }

    private func fixture(attack: Bool, mode: ComposerTaskMode = .manual) async throws -> (profile: RuntimeIsolationProfile, chat: ChatStore,
        registry: MCPToolRegistry, provider: RegenerationProvider, transport: RegenerationMCPTransport,
        approval: RegenerationApproval) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "answer-regeneration",
            processEnvironment: [:], processArguments: ["TranscriptRegenerationProductionConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = profile.makeKeychainStore()
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let center = SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: profile.makeEnvironmentStore(keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, logManager: profile.makeLogManager(), mcpManager: manager,
            skillStore: skills, usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain))
        let server = MCPServer(id: "regen", name: "Owned MCP", command: "fixture-never-spawned")
        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "echo", authorized: true))
        let transport = RegenerationMCPTransport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "regeneration-owned", grantEpoch: "regeneration-owned", leaseID: "regeneration-owned",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection.mode = mode
        chat.composerPolicySelection.bypassModeConfirmed = mode == .bypassPermission
        let approval = RegenerationApproval()
        // Supplying an approval delegate selects SecureAgentLoopFactory. Its
        // ordinary turn must carry the real policy wrapper, not just Composer
        // facts. Reuse only the owned write root and already-authorized MCP.
        let goal = GoalEnvelope(scopeID: "regeneration-owned", allowedCapabilities: ["file_write", "mcp_regen_echo"],
            fileRoots: [root.path], budget: 100, deadline: Date().addingTimeInterval(3600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "regeneration-fixture")
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: Date(), expiresAt: goal.deadline)
        let executor = PolicyRuntimeBinding(goal: goal, lease: lease).wrap(
            BuiltinToolExecutor(allowedRoot: root, mcpBridge: registry))
        // Ordinary tool effects require the same durable receipt authority as
        // production; an in-memory ledger cannot mint an execution receipt.
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts.json"))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor,
            maxIterations: 4, approvalDelegate: approval, requestBudget: chat.budgetTracker,
            mcpBridge: registry, toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let route = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:regeneration")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: try! registry.snapshotForTurn(),
                providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: route, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        let provider = RegenerationProvider(target: root.appendingPathComponent("effect.txt"), attack: attack)
        chat.streamingProviderOverride = provider
        return (profile, chat, registry, provider, transport, approval)
    }
}

private actor RegenerationApproval: ApprovalDelegate {
    private(set) var calls = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        calls += 1
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
private final class RegenerationProvider: LLMProvider, @unchecked Sendable {
    let name = "regeneration-owned"
    var model = LLMModel(id: "regeneration-owned", displayName: "Owned", provider: "regeneration-owned")
    var capabilities: Set<ProviderCapability> { [.tools] }
    let target: URL
    let attack: Bool
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private var offered: [Set<String>] = []
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    var catalogs: [Set<String>] { lock.withLock { offered } }
    init(target: URL, attack: Bool) { self.target = target; self.attack = attack }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        // The real actor-owned route uses this overload for an empty catalog.
        lock.withLock { offered.append([]) }
        return try await respond(messages)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { offered.append(Set(tools.map(\.name))) }
        return try await respond(messages)
    }
    private func respond(_ messages: [LLMMessage]) async throws -> LLMResponse {
        let count = lock.withLock { captured.append(messages); return captured.count }
        let user = messages.last(where: { $0.role == .user })?.content ?? ""
        if user == "hold ordinary" {
            entered.continuation.yield(())
            var gate = release.stream.makeAsyncIterator(); _ = await gate.next()
            try Task.checkCancellation()
        }
        // Native results carry their call ID outside the content. Keep the
        // legacy content-ID match too; neither form may trigger a duplicate write.
        let receivedOrdinaryResult = messages.contains {
            $0.role == .tool && $0.toolCallID == "ordinary-file"
        } || messages.contains { $0.content.contains("ordinary-file") }
        let calls: [[String: Any]]
        if attack && count == 2 {
            calls = [["id": "regen-file", "name": "file_write", "input": ["path": target.path, "content": "forbidden-effect"]],
                     ["id": "regen-mcp", "name": "mcp_regen_echo", "input": [:]]]
        } else if user == "ordinary write" && !receivedOrdinaryResult {
            calls = [["id": "ordinary-file", "name": "file_write", "input": ["path": target.path, "content": "ordinary-effect"]]]
        } else { calls = [] }
        if !calls.isEmpty {
            return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": calls]), as: UTF8.self),
                stopReason: "tool_use", usage: nil)
        }
        return LLMResponse(text: "已完成的合成回答", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
private final class RegenerationMCPTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    var calls: Int { lock.withLock { callCount } }
    func start() async throws {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize": return MCPJSONRPCResponse(id: request.id, result: .object([
            "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
            "serverInfo": .object(["name": .string("owned"), "version": .string("1")])]))
        case "tools/list": return MCPJSONRPCResponse(id: request.id, result: .object([
            "tools": .array([.object(["name": .string("echo"), "inputSchema": .object(["type": .string("object")])])])]))
        case "tools/call":
            lock.withLock { callCount += 1 }
            return MCPJSONRPCResponse(id: request.id, result: .object(["content": .array([])]))
        default: return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "unsupported"))
        }
    }
}
