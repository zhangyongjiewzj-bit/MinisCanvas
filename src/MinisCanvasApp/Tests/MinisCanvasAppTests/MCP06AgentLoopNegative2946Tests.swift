import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class MCP06Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { lock.withLock { signaled } }

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            signaled = true
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Only the remote MCP endpoint is synthetic. Discovery, policy and tool
/// dispatch remain the production objects used by AgentLoopChatEngine.
private final class MCP06Transport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var valueType = "string"
    private var callCount = 0
    private var listCount = 0

    var calls: Int { lock.withLock { callCount } }
    var lists: Int { lock.withLock { listCount } }
    func replaceSchemaWithInteger() { lock.withLock { valueType = "integer" } }
    func start() async throws {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])
            ]))
        case "tools/list":
            let type = lock.withLock { () -> String in
                listCount += 1
                return valueType
            }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array([.object([
                    "name": .string("greet"),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["value": .object(["type": .string(type)])]),
                        "required": .array([.string("value")])
                    ])
                ])])
            ]))
        case "tools/call":
            lock.withLock { callCount += 1 }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("unexpected call")])])
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "unknown fixture method"))
        }
    }
}

/// The model sees the actual offered catalog, pauses, then returns a native
/// call with a fixed ID. The second request observes the production feedback.
private final class MCP06HeldModel: LLMProvider, @unchecked Sendable {
    let name = "MCP06 held model"
    var model = LLMModel(id: "mcp06-held", displayName: "Synthetic MCP06", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.tools]
    let entered = MCP06Signal()
    let release = MCP06Signal()
    let requestedName: String
    let callID: String
    private let lock = NSLock()
    private var count = 0
    private var catalogs: [[String]] = []
    private var feedback: [LLMMessage] = []

    init(requestedName: String, callID: String) {
        self.requestedName = requestedName
        self.callID = callID
    }

    var offeredNames: [[String]] { lock.withLock { catalogs } }
    var receivedFeedback: [LLMMessage] { lock.withLock { feedback } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        throw LLMError.providerError(message: "unexpected tool-free MCP06 request")
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let requestNumber = lock.withLock { () -> Int in
            count += 1
            catalogs.append(tools.map(\.name))
            if count > 1 { feedback = messages.filter { $0.role == .tool } }
            return count
        }
        if requestNumber == 1 {
            entered.signal()
            await release.wait()
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                toolCalls: [LLMToolCall(id: callID, name: requestedName,
                    rawArguments: "{\"value\":\"denied\"}", arguments: ["value": "denied"])])
        }
        return LLMResponse(text: "denied", stopReason: "stop", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.providerError(message: "unexpected text-only MCP06 stream")
    }
}

@Suite("D-MCP-06 actual AgentLoop schema and unknown-name rejection")
@MainActor
struct MCP06AgentLoopNegative2946Tests {
    @Test(arguments: ["explicit-schema-rediscovery", "unknown-model-name"])
    func offeredCatalogCannotAuthorizeInvalidModelCall(_ caseName: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp06-agentloop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root, keychain: keychain),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root, ringCapacity: 10),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("mcp06-\(UUID().uuidString)"))
        )
        let server = MCPServer(id: "settings", name: "Settings fixture", type: .stdio,
            command: "never-launched-fake")
        #expect(center.addMCPServer(server))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        let transport = MCP06Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = {
            MCPClient(server: $0, transport: transport)
        }
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let originalDiscovery = try #require(manager.discoverySnapshot(serverID: server.id))
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let frozen = try registry.snapshotForTurn()
        let bridge = TurnScopedMCPToolBridge(base: frozen)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        #expect(try await bridge.mcpBoundTools().map(\.fullName) == [fullName])
        let requestedName = caseName == "unknown-model-name" ? "mcp_settings_missing" : fullName
        let callID = "mcp06-\(caseName)-call"

        let builtin = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
        let createdAt = Date()
        let goal = GoalEnvelope(scopeID: "test:mcp06-\(caseName)",
            allowedCapabilities: builtin.registeredToolNames, fileRoots: [root.path], budget: 10,
            deadline: createdAt.addingTimeInterval(60), concurrencyLimit: 1,
            autonomyLevel: .l1, createdAt: createdAt)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: createdAt, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
            capabilityResolver: builtin)
        let factURL = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: factURL)
        let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
            approvalDelegate: ProductionApprovalDelegate(), mcpBridge: bridge,
            toolExecutionFactLedger: ledger)
        let provider = MCP06HeldModel(requestedName: requestedName, callID: callID)
        defer { provider.release.signal() }
        let running = Task {
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "synthetic MCP06 request")],
                systemPrompt: "MCP06 synthetic fixture", maxTokens: 128,
                conversationID: "mcp06-\(caseName)", authorizedSessionReadSessionID: nil, turnID: 1)
            for try await _ in stream {}
        }
        for _ in 0..<100 where !provider.entered.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.entered.isSignaled)
        #expect(provider.offeredNames.first?.contains(fullName) == true)

        if caseName == "explicit-schema-rediscovery" {
            transport.replaceSchemaWithInteger()
            #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
            let changed = try #require(manager.discoverySnapshot(serverID: server.id))
            #expect(changed.schemaDigest != originalDiscovery.schemaDigest)
            #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "greet"))
            #expect(try await bridge.mcpBoundTools().isEmpty)
            #expect(transport.lists == 2)
        } else {
            #expect(manager.discoverySnapshot(serverID: server.id) == originalDiscovery)
            #expect(transport.lists == 1)
        }
        provider.release.signal()
        try await running.value

        let feedback = provider.receivedFeedback.filter { $0.toolCallID == callID }
        #expect(feedback.count == 1)
        #expect(feedback.first?.content.contains(requestedName) == true)
        #expect(transport.calls == 0, "Neither invalid model call may reach tools/call")
        #expect(executor.acceptedExecutionCount == 0)
        #expect(ledger.pendingReceipts.isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopened.facts == ledger.facts)
        #expect(reopened.pendingReceipts.isEmpty)
        if caseName == "explicit-schema-rediscovery" {
            #expect(executor.deniedExecutionCount == 1)
            #expect(executor.lastCapabilityDenialReceipt?.capabilityID == fullName)
            #expect(executor.lastCapabilityDenialReceipt?.reason == .capabilityNotAllowed)
            #expect(ledger.facts.count == 1)
            let fact = try #require(ledger.facts.first)
            #expect(fact.toolCallID == callID && fact.toolName == fullName && fact.status == .failed)
        } else {
            // The catalog fence rejects an invented name before Policy or a
            // durable attempt is minted. Its negative outcome is feedback,
            // not a fabricated Policy denial receipt.
            #expect(executor.deniedExecutionCount == 0)
            #expect(ledger.facts.isEmpty)
        }
    }
}
