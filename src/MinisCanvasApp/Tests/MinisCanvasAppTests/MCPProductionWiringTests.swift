import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class ProductionMCPBridge: MCPToolBridgeTurnSnapshotting, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        var callCount = 0
    }

    let boundTool: MCPBoundTool
    private let state: State

    init() {
        let tool = MCPTool(
            name: "echo",
            description: "Echo a value",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object(["type": .string("string")])
                ]),
                "required": .array([.string("value")])
            ])
        )
        self.boundTool = MCPBoundTool(
            fullName: "mcp_production_echo",
            serverID: "production",
            tool: tool
        )
        self.state = State()
    }

    private init(boundTool: MCPBoundTool, state: State) {
        self.boundTool = boundTool
        self.state = state
    }

    var callCount: Int {
        state.callCount
    }

    func snapshotForTurn() throws -> any MCPToolBridge {
        ProductionMCPBridge(boundTool: boundTool, state: state)
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        [boundTool]
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        guard fullName == boundTool.fullName else {
            throw MCPClientError.toolNotFound(fullName)
        }
        state.callCount += 1
        return "echo:\((arguments?["value"] as? String) ?? "")"
    }
}

final class ProductionMCPProvider: LLMProvider, @unchecked Sendable {
    let name = "Test"
    var model = LLMModel(id: "mcp-wiring", displayName: "MCP wiring", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    private(set) var receivedToolNames: [[String]] = []
    private(set) var receivedToolDefinitions: [[AgentToolDefinition]] = []
    var requestedToolName = "mcp_production_echo"
    private var callIndex = 0
    var returnsPlainResponse = false
    var onCall: (@Sendable () -> Void)?

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        onCall?()
        return LLMResponse(text: "plain", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedToolNames.append(tools.map(\.name))
        receivedToolDefinitions.append(tools)
        onCall?()
        if returnsPlainResponse {
            return LLMResponse(text: "plain", stopReason: "stop", usage: nil)
        }
        defer { callIndex += 1 }
        if callIndex == 0 {
            return LLMResponse(
                text: "",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "mcp-call-1",
                    name: requestedToolName,
                    rawArguments: "{\"value\":\"hello\"}",
                    arguments: ["value": "hello"]
                )]
            )
        }
        return LLMResponse(text: "完成", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct ProductionApprovalDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let identityDigest = request.identityDigest else { return .deny }
        return ApprovalDecision(
            approved: true,
            reason: "Approved synthetic MCP request",
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: identityDigest
        )
    }
}

private final class ProductionMCPAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private struct SuspendedProductionMCPTransport: MCPTransport {
    let entered: ProductionMCPAsyncSignal
    let release: ProductionMCPAsyncSignal

    func start() async throws {
        entered.signal()
        await release.wait()
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("suspended"), "version": .string("1.0")]),
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object(["name": .string("greet")])]),
            ]))
        default:
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "method not found")
            )
        }
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

private final class CountingProductionMCPTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _lists = 0

    var lists: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lists
    }

    private func recordList() {
        lock.lock()
        _lists += 1
        lock.unlock()
    }

    func start() async throws {}
    func stop() {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("cached"), "version": .string("1.0")]),
            ]))
        case "tools/list":
            recordList()
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("greet"),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["value": .object(["type": .string("string")])]),
                    ]),
                ])]),
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }
}

@Suite("MCP 生产接线")
@MainActor
struct MCPProductionWiringTests {
    @Test("BridgeStore reuses canonical MCP discovery across consecutive turns in one session")
    func sameSessionTurnsReuseMCPDiscoveryAndUnrelatedDiscoveryDoesNotBlock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProductionSameSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let release = ProductionMCPAsyncSignal()
        defer {
            release.signal()
            try? FileManager.default.removeItem(at: root)
        }
        let entered = ProductionMCPAsyncSignal()
        let cachedTransport = CountingProductionMCPTransport()
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let cached = MCPServer(id: "cached", name: "Cached", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(cached)
        try manager.authorizeServer(id: cached.id)
        try manager.authorizeTool(serverID: cached.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager) { server in
            let transport: any MCPTransport
            if server.id == "cached" {
                transport = cachedTransport
            } else {
                transport = SuspendedProductionMCPTransport(entered: entered, release: release)
            }
            return MCPClient(server: server, transport: transport)
        }
        defer { registry.disconnectAll() }
        try await registry.refreshTools()
        let discovery = try #require(manager.discoverySnapshot(serverID: cached.id))
        #expect(cachedTransport.lists == 1)

        let expectedSessionID = UUID()
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(id: expectedSessionID.uuidString, title: "MCP same session")

        let readinessStore = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        #expect(readinessStore.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "Test", modelID: "mcp-wiring", status: .passed,
                readinessState: .mock, checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "same-session-primary", isApplied: true,
                discoveryReceiptID: "same-session-discovery",
                applyReceiptID: "provider-readiness-apply:same-session-discovery",
                appliedAt: Date(timeIntervalSince1970: 1_787_200_001)
            )
        ]))
        let appBridge = BridgeStore(providerReadinessStore: readinessStore)
        appBridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: root,
            mcpManager: manager, mcpBridgeOverride: registry,
            approvalDelegateOverride: ProductionApprovalDelegate()
        )
        let engine = try #require(appBridge.chat.agentEngine as? AgentLoopChatEngine)
        let scopedBridge = try #require(engine.mcpBridge as? TurnScopedMCPToolBridge)
        #expect((scopedBridge.base as? MCPToolRegistry) === registry)
        let sessionID = try #require(appBridge.chat.activeSessionID)
        #expect(sessionID == expectedSessionID)
        #expect(appBridge.chat.sessionStore?.loadSession(id: sessionID.uuidString) != nil)
        let fullName = MCPBoundTool.makeFullName(serverID: cached.id, toolName: "greet")

        func submitPlainTurn(_ prompt: String) async throws -> (ProductionMCPProvider, Int) {
            let provider = ProductionMCPProvider()
            provider.returnsPlainResponse = true
            appBridge.chat.streamingProviderOverride = provider
            appBridge.chat.draftText = prompt
            appBridge.chat.sendDraft()
            for _ in 0..<100 where provider.receivedToolDefinitions.isEmpty || appBridge.chat.isStreaming {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(provider.receivedToolDefinitions.count == 1)
            #expect(!appBridge.chat.isStreaming)
            #expect(appBridge.chat.activeSessionID == sessionID)
            let execution = try #require(appBridge.chat.executionSnapshot(forSessionID: sessionID))
            return (provider, try #require(execution.turnID))
        }

        let (first, firstTurnID) = try await submitPlainTurn("first cached MCP turn")
        let (second, secondTurnID) = try await submitPlainTurn("second cached MCP turn")
        let firstNames = try #require(first.receivedToolNames.first)
        let secondNames = try #require(second.receivedToolNames.first)
        #expect(secondTurnID == firstTurnID + 1)
        #expect(firstNames.contains(fullName))
        #expect(secondNames.contains(fullName))
        #expect(cachedTransport.lists == 1)
        #expect(manager.discoverySnapshot(serverID: cached.id) == discovery)

        let suspended = MCPServer(id: "suspended", name: "Suspended", type: .http,
                                  url: "http://127.0.0.1:1")
        try manager.addServer(suspended)
        try manager.authorizeServer(id: suspended.id)
        try manager.authorizeTool(serverID: suspended.id, toolName: "greet")
        let (unrelated, thirdTurnID) = try await submitPlainTurn("answer without using MCP")
        let unrelatedNames = try #require(unrelated.receivedToolNames.first)
        for _ in 0..<100 where !entered.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.isSignaled)
        #expect(!release.isSignaled)
        #expect(thirdTurnID == secondTurnID + 1)
        #expect(!unrelatedNames.contains("mcp_suspended_greet"))
        #expect(manager.discoverySnapshot(serverID: suspended.id) == nil)
        release.signal()
        for _ in 0..<100 where manager.discoverySnapshot(serverID: suspended.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.discoverySnapshot(serverID: suspended.id) != nil)
    }

    @Test func productionAgentLoopReachesProviderWhileDiscoveryIsSuspended() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProductionNonblocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let entered = ProductionMCPAsyncSignal()
        let release = ProductionMCPAsyncSignal()
        defer { release.signal() }
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let server = MCPServer(
            id: "suspended",
            name: "Suspended",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(
                server: server,
                transport: SuspendedProductionMCPTransport(entered: entered, release: release)
            )
        }

        let readinessStore = ProviderReadinessStore(
            directory: root.appendingPathComponent("readiness", isDirectory: true)
        )
        #expect(readinessStore.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "Test",
                modelID: "mcp-wiring",
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "nonblocking-primary",
                isApplied: true,
                discoveryReceiptID: "nonblocking-discovery",
                applyReceiptID: "provider-readiness-apply:nonblocking-discovery",
                appliedAt: Date(timeIntervalSince1970: 1_787_200_001)
            )
        ]))
        let appBridge = BridgeStore(providerReadinessStore: readinessStore)
        appBridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            mcpManager: manager,
            mcpBridgeOverride: registry,
            approvalDelegateOverride: ProductionApprovalDelegate()
        )
        let provider = ProductionMCPProvider()
        provider.returnsPlainResponse = true
        let providerCalled = ProductionMCPAsyncSignal()
        provider.onCall = { providerCalled.signal() }
        appBridge.chat.streamingProviderOverride = provider
        appBridge.chat.draftText = "continue while MCP discovery is suspended"
        appBridge.chat.sendDraft()

        for _ in 0..<100 where !entered.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.isSignaled)
        for _ in 0..<100 where !providerCalled.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(providerCalled.isSignaled)
        #expect(provider.receivedToolNames.count == 1)
        #expect(provider.receivedToolNames.first?.contains("mcp_suspended_greet") == false)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        #expect(!release.isSignaled)
        appBridge.chat.stopStreaming()
    }

    @Test func discoveredToolsReachProviderAndDynamicExecutor() async throws {
        let bridge = ProductionMCPBridge()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProductionWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let builtinExecutor = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
        let policyCreatedAt = Date()
        let policyGoal = GoalEnvelope(
            scopeID: "test:mcp-production",
            allowedCapabilities: builtinExecutor.registeredToolNames,
            fileRoots: [root.path],
            budget: 10,
            deadline: policyCreatedAt.addingTimeInterval(60),
            concurrencyLimit: 1,
            autonomyLevel: .l1,
            createdAt: policyCreatedAt
        )
        let policyLease = AutonomyLease(
            goalID: policyGoal.goalID,
            scopeID: policyGoal.scopeID,
            issuedAt: policyCreatedAt,
            expiresAt: policyGoal.deadline
        )
        let executor = PolicyEnforcedToolExecutor(
            base: builtinExecutor,
            goal: policyGoal,
            lease: policyLease,
            capabilityResolver: builtinExecutor
        )
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: executor,
            maxIterations: 3,
            approvalDelegate: ProductionApprovalDelegate(),
            mcpBridge: bridge,
            toolExecutionFactLedger: ledger
        )
        let provider = ProductionMCPProvider()
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "调用 MCP")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "mcp-production-discovery",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )

        var output = ""
        for try await event in stream {
            if case .textDelta(let text) = event { output += text }
        }

        #expect(output == "完成")
        #expect(provider.receivedToolNames.count == 2)
        #expect(provider.receivedToolNames.allSatisfy { $0.contains("mcp_production_echo") })
        #expect(bridge.callCount == 1)
    }

    @Test func productionCompositionRootInjectsSecureEngineAndMCPBridge() async throws {
        let bridge = ProductionMCPBridge()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProductionRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readinessStore = ProviderReadinessStore(
            directory: root.appendingPathComponent("readiness", isDirectory: true)
        )
        let sessionID = UUID().uuidString
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(
            id: sessionID,
            title: "MCP production",
            projectID: "mcp-production-project"
        )
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "Test",
                modelID: "mcp-wiring",
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
                evidenceID: "mock-primary",
                isApplied: true,
                discoveryReceiptID: "discovery-primary",
                applyReceiptID: "provider-readiness-apply:discovery-primary",
                appliedAt: Date(timeIntervalSince1970: 1_787_200_001)
            )
        )

        let settingsOwner: SettingsCenter
        if let active = SettingsCenter.active {
            let expected = try #require(BridgeStore.canonicalSessionDirectoryIdentity(sessionStore.directory))
            try #require(BridgeStore.canonicalSessionDirectoryIdentity(active.sessionStore.directory) == expected,
                         "Run this fixture in its dedicated process, without a foreign settings owner")
            settingsOwner = active
        } else {
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            settingsOwner = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: sessionStore,
                logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                providerReadinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: readinessStore
            )
        }
        try #require(SettingsCenter.active === settingsOwner)
        defer { withExtendedLifetime(settingsOwner) {} }

        let appBridge = BridgeStore(providerReadinessStore: readinessStore)
        appBridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            mcpBridgeOverride: bridge,
            approvalDelegateOverride: ProductionApprovalDelegate()
        )

        let engine = try #require(appBridge.chat.agentEngine as? AgentLoopChatEngine)
        try engine.loop.requireApprovalGate()
        #expect(engine.mcpBridge != nil)
        let primaryReceipt = appBridge.chat.chatModelPickerReceipt(
            providerID: "Test",
            modelID: "mcp-wiring"
        )
        #expect(primaryReceipt?.evidenceID == "mock-primary")
        #expect(primaryReceipt?.applyReceiptID == "provider-readiness-apply:discovery-primary")

        let provider = ProductionMCPProvider()
        let turn = AgentTurnIdentity(
            sessionID: try #require(appBridge.chat.activeSessionID?.uuidString),
            turnID: 1,
            messageID: "mcp-production-assistant-1"
        )
        #expect(turn.sessionID == sessionID)
        let facts = appBridge.chat.composerPolicyFacts
        let ceiling = try #require(facts.autonomyCeiling)
        #expect(ceiling == .l2)
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            taskID: "mcp-production-task-1",
            attemptID: "mcp-production-attempt-1",
            messageID: turn.messageID,
            inputDigest: "mcp-production-input",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: ceiling
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "mcp-production-operation-1"
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(
                    skillsRoot: root.appendingPathComponent("skills")
                )
            ).snapshotForTurn(),
            mcpBridge: try bridge.snapshotForTurn()
        )
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "调用 MCP")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: runtimeSnapshot
        )

        var output = ""
        for try await event in stream {
            if case .textDelta(let text) = event { output += text }
        }

        #expect(output == "完成")
        #expect(provider.receivedToolNames.allSatisfy { $0.contains("mcp_production_echo") })
        // The production Composer facts are frozen before dynamic MCP
        // discovery, so advertising the tool must not grant its execution.
        #expect(bridge.callCount == 0)
    }
}
