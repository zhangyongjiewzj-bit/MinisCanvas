import Foundation
import Testing
@testable import MinisCore

// D-MCP-05 (parent P3-MCP-01): after an MCP server is disabled or deleted,
// no new request may keep using its tools. The pre-existing
// toolNotFound/permissionDenied refusals in `MCPToolRegistry.callMCPTool`
// stay in place; these tests pin the additional guarantee that the registry
// never continues, resurrects, or re-admits a client session across the
// disable/delete boundary:
//   * a refusal caused by a server-boundary close also retires the cached
//     client for that server (no continuing/stale client),
//   * a client admitted under one discovery session can never serve a call
//     admitted under a later discovery session (an unobserved
//     disable→re-enable cycle cannot be carried by the pre-boundary session),
//   * an in-flight call whose server is disabled before publication is
//     rejected and its serving client is retired,
//   * stable sessions still reuse one client (the fence is not over-eager).

// MARK: - Helpers

private func dmcp05MakeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func dmcp05MakeManager(_ name: String) throws -> MCPServerManager {
    let dir = try dmcp05MakeTempDir(name)
    return MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json"))
}

private actor DMCP05AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private final class DMCP05Transport: MCPTransport, @unchecked Sendable {
    let tag: String
    let tools: [MCPTool]
    let callEntered: DMCP05AsyncSignal?
    let callRelease: DMCP05AsyncSignal?

    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _callCount = 0

    init(
        tag: String,
        tools: [MCPTool],
        callEntered: DMCP05AsyncSignal? = nil,
        callRelease: DMCP05AsyncSignal? = nil
    ) {
        self.tag = tag
        self.tools = tools
        self.callEntered = callEntered
        self.callRelease = callRelease
    }

    var startCount: Int { lock.dmcp05WithLock { _startCount } }
    var stopCount: Int { lock.dmcp05WithLock { _stopCount } }
    var callCount: Int { lock.dmcp05WithLock { _callCount } }
    var isStopped: Bool { lock.dmcp05WithLock { _startCount > 0 && _stopCount >= _startCount } }

    var isReady: Bool { lock.dmcp05WithLock { _startCount > _stopCount } }

    func start() async throws {
        lock.dmcp05WithLock { _startCount += 1 }
    }

    func stop() {
        lock.dmcp05WithLock { _stopCount += 1 }
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string(tag), "version": .string("1.0")]),
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array(tools.map { tool in
                    var object: [String: MCPJSONValue] = ["name": .string(tool.name)]
                    if let description = tool.description {
                        object["description"] = .string(description)
                    }
                    if let schema = tool.inputSchema {
                        object["inputSchema"] = schema
                    }
                    return .object(object)
                }),
            ]))
        case "tools/call":
            if let callEntered { await callEntered.signal() }
            if let callRelease { await callRelease.wait() }
            let ordinal = lock.dmcp05WithLock { () -> Int in
                _callCount += 1
                return _callCount
            }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("\(tag):\(ordinal)"),
                ])]),
            ]))
        default:
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "method not found")
            )
        }
    }
}

/// Records every client the registry creates (discovery clients included),
/// so tests can distinguish the pre-boundary session from any later session.
private final class DMCP05ClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [DMCP05Transport] = []
    let tools: [MCPTool]
    let gatedCallEntered: DMCP05AsyncSignal?
    let gatedCallRelease: DMCP05AsyncSignal?

    init(
        tools: [MCPTool],
        callEntered: DMCP05AsyncSignal? = nil,
        callRelease: DMCP05AsyncSignal? = nil
    ) {
        self.tools = tools
        self.gatedCallEntered = callEntered
        self.gatedCallRelease = callRelease
    }

    func make(_ server: MCPServer) -> MCPClient {
        let transport: DMCP05Transport = lock.dmcp05WithLock {
            let transport = DMCP05Transport(
                tag: "t\(_transports.count + 1)",
                tools: tools,
                callEntered: gatedCallEntered,
                callRelease: gatedCallRelease
            )
            _transports.append(transport)
            return transport
        }
        return MCPClient(server: server, transport: transport)
    }

    var transports: [DMCP05Transport] { lock.dmcp05WithLock { _transports } }
    var createdCount: Int { lock.dmcp05WithLock { _transports.count } }
}

private extension NSLock {
    func dmcp05WithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func dmcp05Confirmed(_ intent: OperationIntent) -> OperationIntent {
    intent
        .withFirstConfirmation("I reviewed this exact MCP server")
        .withSecondConfirmation("I confirm moving this MCP server to trash")
}

private struct DMCP05ApproveChildCall: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true, confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private func dmcp05ChildCall(_ fullName: String) -> String {
    let call: [String: Any] = [
        "tool_calls": [["id": "dmcp05-call", "name": fullName, "input": [:]]]
    ]
    let data = try! JSONSerialization.data(withJSONObject: call)
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Tests

@Suite("D-MCP-05 disable/delete boundary client fence")
struct MCPDisableBoundaryFenceTests {

    private func makeReadyServer(
        _ manager: MCPServerManager,
        id: String
    ) throws -> MCPServer {
        let server = MCPServer(id: id, name: id, type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: id)
        try manager.authorizeTool(serverID: id, toolName: "greet")
        return server
    }

    private func runProductionChildTurn(
        bridge: any MCPToolBridge,
        fullName: String,
        root: URL,
        turnName: String
    ) async throws -> (SubAgentReport, MockLLMProvider) {
        let provider = MockLLMProvider(responses: [
            dmcp05ChildCall(fullName), "dmcp05-child-complete"
        ])
        let executor = BuiltinToolExecutor(
            allowedRoot: root, deniedRoots: [], mcpBridge: bridge
        )
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let conversationID = "dmcp05-\(turnName)-conversation"
        let sessions = SessionStore(directory: root.appendingPathComponent("\(turnName)-sessions"))
        let parentSession = try sessions.createSession(id: conversationID)
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: executor,
            approvalGate: ApprovalGate(
                policyByTool: [fullName: .alwaysAsk],
                delegate: DMCP05ApproveChildCall()
            ),
            turnController: controller,
            currentConversationID: conversationID,
            taskStore: try AgentTaskStore(
                persistenceURL: root.appendingPathComponent("\(turnName)-tasks.json")
            ),
            sessionStore: sessions,
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("\(turnName)-facts.json")
            ),
            parentID: "dmcp05-\(turnName)-parent",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "dmcp05-\(turnName)-fingerprint",
                conversationID: conversationID
            ),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: parentSession.id,
                conversationID: conversationID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "dmcp05-\(turnName)-parent",
                actorID: "dmcp05-test"
            ),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: [],
                allowedMCPToolNames: [fullName]
            ),
            parentCapabilities: provider.capabilities
        )
        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(
                id: "dmcp05-\(turnName)-child",
                title: "MCP boundary consumer",
                instructions: "Call only the synthetic MCP tool",
                requiredCapabilities: [.tools],
                resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: [fullName], allowedReadRoots: []
                )
            )],
            strategy: .sequential
        )
        await parentTurn.finish()
        return (try #require(reports.first), provider)
    }

    @Test("a new production child turn cannot dispatch a disabled or deleted MCP tool",
          arguments: ["disabled", "deleted"])
    func nextProductionTurnAfterBoundaryHasZeroDownstreamCalls(boundary: String) async throws {
        let root = try dmcp05MakeTempDir("DMCP05-Orchestrator-\(boundary)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let server = try makeReadyServer(manager, id: "dmcp05-orchestrator")
        let factory = DMCP05ClientFactory(tools: [MCPTool(name: "greet")])
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        defer { registry.disconnectAll() }
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        try await registry.refreshTools()
        #expect(try await registry.mcpBoundTools().map(\.fullName) == [fullName])

        let beforeTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        let (before, beforeProvider) = try await runProductionChildTurn(
            bridge: beforeTurn, fullName: fullName,
            root: root, turnName: "before-\(boundary)"
        )
        #expect(before.result == .succeeded(output: "dmcp05-child-complete"))
        #expect(beforeProvider.receivedHistory.count == 2)
        let toolResult = try #require(beforeProvider.receivedHistory.last?.last)
        let parts = try #require(JSONSerialization.jsonObject(
            with: Data(toolResult.content.utf8)
        ) as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts.first?["is_error"] as? Bool == false)
        #expect((parts.first?["content"] as? String)?.contains("t") == true)
        let dispatchedBefore = factory.transports.map(\.callCount).reduce(0, +)
        #expect(dispatchedBefore == 1)
        beforeTurn.disconnectAll()

        if boundary == "disabled" {
            try manager.enableServer(id: server.id, enabled: false)
        } else {
            _ = try manager.deleteServer(dmcp05Confirmed(try manager.deletionIntent(id: server.id)))
        }
        let clientsBeforeNextTurn = factory.createdCount
        let afterTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        defer { afterTurn.disconnectAll() }
        let (after, afterProvider) = try await runProductionChildTurn(
            bridge: afterTurn, fullName: fullName,
            root: root, turnName: "after-\(boundary)"
        )

        #expect(after.result.error != nil)
        #expect(afterProvider.receivedHistory.isEmpty)
        #expect(try await registry.mcpBoundTools().isEmpty)
        #expect(factory.createdCount == clientsBeforeNextTurn)
        #expect(factory.transports.map(\.callCount).reduce(0, +) == dispatchedBefore)
    }

    @Test("disabled server: new request refused and surviving client retired")
    func refusalAfterDisableLeavesNoContinuingClient() async throws {
        let manager = try dmcp05MakeManager("DMCP05-Refuse")
        let server = try makeReadyServer(manager, id: "dmcp05-refuse")
        let factory = DMCP05ClientFactory(tools: [MCPTool(name: "greet")])
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")

        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:1")
        let servingTransport = try #require(factory.transports.last { $0.callCount > 0 })
        #expect(servingTransport.isStopped == false)

        try manager.enableServer(id: server.id, enabled: false)

        // The pre-existing permissionDenied refusal must still fire…
        await #expect(throws: MCPClientError.permissionDenied(fullName)) {
            _ = try await registry.callMCPTool(fullName: fullName, arguments: nil)
        }
        // …and the refused session must not remain cached and live.
        #expect(servingTransport.isStopped)
        #expect(servingTransport.callCount == 1)
        #expect(try await registry.mcpBoundTools().isEmpty)

        registry.disconnectAll()
    }

    @Test("unobserved disable→re-enable cycle cannot be resurrected by the old client")
    func disabledBoundaryCannotBeCrossedBySurvivingSession() async throws {
        let manager = try dmcp05MakeManager("DMCP05-Cycle")
        let server = try makeReadyServer(manager, id: "dmcp05-cycle")
        let factory = DMCP05ClientFactory(tools: [MCPTool(name: "greet")])
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")

        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:1")
        let preBoundary = try #require(factory.transports.last { $0.callCount > 0 })

        // Disable and re-enable without any registry observation in between,
        // then re-grant: state is textually identical to the pre-boundary
        // configuration (descriptor fingerprint unchanged by the toggle).
        try manager.enableServer(id: server.id, enabled: false)
        try manager.enableServer(id: server.id, enabled: true)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let output = try await registry.callMCPTool(fullName: fullName, arguments: nil)
        // The call must be served by a fresh post-boundary session, not the
        // client created before the disable, and the old session must be gone.
        #expect(output != "t2:2")
        let postBoundary = try #require(factory.transports.last { $0.callCount > 0 })
        #expect(output == "\(postBoundary.tag):1")
        #expect(postBoundary !== preBoundary)
        #expect(postBoundary.callCount == 1)
        #expect(preBoundary.isStopped)
        #expect(preBoundary.callCount == 1)

        registry.disconnectAll()
    }

    @Test("deleted server: refusal retires client; recreation uses a fresh session")
    func deletionRefusesNewRequestsAndRecreationCannotReuseOldSession() async throws {
        let manager = try dmcp05MakeManager("DMCP05-Delete")
        let server = try makeReadyServer(manager, id: "dmcp05-delete")
        let factory = DMCP05ClientFactory(tools: [MCPTool(name: "greet")])
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")

        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:1")
        let preDeletion = try #require(factory.transports.last { $0.callCount > 0 })

        _ = try manager.deleteServer(dmcp05Confirmed(try manager.deletionIntent(id: server.id)))
        await #expect(throws: MCPClientError.permissionDenied(fullName)) {
            _ = try await registry.callMCPTool(fullName: fullName, arguments: nil)
        }
        #expect(preDeletion.isStopped)
        #expect(preDeletion.callCount == 1)

        // Recreating the same server id/descriptor is a new configuration
        // session: its first call must run on a client created after the
        // deletion boundary.
        _ = try makeReadyServer(manager, id: server.id)
        let output = try await registry.callMCPTool(fullName: fullName, arguments: nil)
        let postDeletion = try #require(factory.transports.last { $0.callCount > 0 })
        #expect(postDeletion !== preDeletion)
        #expect(output == "\(postDeletion.tag):1")
        #expect(preDeletion.callCount == 1)

        registry.disconnectAll()
    }

    @Test("in-flight call across disable: publication refused and client retired")
    func disableDuringInFlightCallRejectsLateResultAndStaleClient() async throws {
        let manager = try dmcp05MakeManager("DMCP05-InFlight")
        let server = try makeReadyServer(manager, id: "dmcp05-inflight")
        let entered = DMCP05AsyncSignal()
        let release = DMCP05AsyncSignal()
        let factory = DMCP05ClientFactory(
            tools: [MCPTool(name: "greet")],
            callEntered: entered,
            callRelease: release
        )
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let identity = MCPToolInvocationIdentity(correlationID: "dmcp05-inflight", attemptID: "attempt-1")

        let pending = Task {
            try await registry.callMCPTool(
                fullName: fullName,
                arguments: nil,
                invocation: identity
            )
        }
        await entered.wait()
        try manager.enableServer(id: server.id, enabled: false)
        await release.signal()

        // The in-flight session must not resurrect the disabled capability.
        await #expect(throws: MCPToolInvocationFenceError.runtimeRetired(identity)) {
            _ = try await pending.value
        }
        let served = try #require(factory.transports.last { $0.callCount > 0 })
        #expect(served.isStopped)
        #expect(served.callCount == 1)
        #expect(try await registry.mcpBoundTools().isEmpty)

        registry.disconnectAll()
    }

    @Test("stable session reuses one client across consecutive calls")
    func fenceDoesNotOverEvictStableSessions() async throws {
        let manager = try dmcp05MakeManager("DMCP05-Stable")
        let server = try makeReadyServer(manager, id: "dmcp05-stable")
        let factory = DMCP05ClientFactory(tools: [MCPTool(name: "greet")])
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory.make)
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")

        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:1")
        // One discovery client + one call client; no config change since.
        #expect(factory.createdCount == 2)

        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:2")
        #expect(try await registry.mcpBoundTools().map(\.fullName) == [fullName])
        #expect(try await registry.callMCPTool(fullName: fullName, arguments: nil) == "t2:3")
        #expect(factory.createdCount == 2)
        let serving = try #require(factory.transports.last { $0.callCount > 0 })
        #expect(serving.callCount == 3)
        #expect(serving.isStopped == false)

        registry.disconnectAll()
    }
}
