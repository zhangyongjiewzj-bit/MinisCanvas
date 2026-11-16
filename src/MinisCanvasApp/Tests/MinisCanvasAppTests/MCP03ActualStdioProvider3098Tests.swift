import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

final class MCP3098Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isReady: Bool { lock.withLock { ready } }

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            ready = true
            let pending = waiting
            waiting = []
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if ready { return true }
                waiting.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }
}

/// Hold the model reply after the production catalog is offered. The remote
/// endpoint remains the real Process/Pipe worker created by MCPClient.
final class MCP3098HeldModel: LLMProvider, @unchecked Sendable {
    let name = "MCP3098 held model"
    var model = LLMModel(id: "mcp3098-held", displayName: "Synthetic MCP3098", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.tools]
    let entered = MCP3098Gate()
    let release = MCP3098Gate()
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
        throw LLMError.providerError(message: "unexpected tool-free MCP3098 request")
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
        throw LLMError.providerError(message: "unexpected text-only MCP3098 stream")
    }
}

@Suite("MCP03 actual stdio to Provider catalog consumer")
@MainActor
struct MCP03ActualStdioProvider3098Tests {
    final class ClientCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var client: MCPClient?
        private var events: [[String: String]] = []
        private var attempt = 0

        func makeClient(for server: MCPServer) -> MCPClient {
            // Exactly the manager's default construction, including its real
            // Process/Pipe/reader. The observer does not initiate a handshake.
            let client = MCPClient(server: server)
            client.setDiagnosticFailureObserver { [weak self] snapshot in
                self?.record(snapshot, edge: "existing_failed_publication")
            }
            lock.withLock { self.client = client }
            return client
        }

        private func record(_ snapshot: MCPClientLifecycleSnapshot, edge: String) {
            let state: String
            let failureClass: String
            switch snapshot.state {
            case .disconnected: state = "disconnected"; failureClass = "none"
            case .connecting: state = "connecting"; failureClass = "none"
            case .connected: state = "connected"; failureClass = "none"
            case .failed(let message):
                state = "failed"
                // Only known error category prefixes are retained; never retain
                // the message, response payload, arguments or environment.
                let prefixes = [
                    ("MCP request timed out:", "timeout"),
                    ("Bad MCP response:", "badResponse"),
                    ("Invalid MCP message:", "invalidMessage"),
                    ("MCP server process exited", "processExited"),
                    ("MCP transport has not been started", "transportNotStarted"),
                    ("Failed to spawn MCP server process:", "spawnFailed"),
                    ("MCP RPC error", "rpcError"),
                    ("Invalid MCP server config:", "invalidServer"),
                    ("Invalid MCP tool schema", "invalidSchema")
                ]
                failureClass = prefixes.first { message.hasPrefix($0.0) }?.1 ?? "unclassified"
            }
            let event = ["edge": edge, "state": state, "failureClass": failureClass,
                "classificationSource": "existing_userFacing_prefix_not_original_typed_Error",
                "generation": String(snapshot.generation),
                "runtimeGeneration": snapshot.runtime.map { String($0.generation) } ?? "unavailable",
                "ownedSyntheticPID": snapshot.runtime?.processIdentifier.map(String.init) ?? "unavailable_after_stop",
                "at": String(Date().timeIntervalSince1970)]
            lock.withLock { events.append(event) }
        }

        func finishDiscovery(_ succeeded: Bool) throws -> (Int, Data) {
            let captured = lock.withLock { client }
            if let captured { record(captured.lifecycleSnapshot, edge: "after_discovery_return") }
            let result = lock.withLock { () -> (Int, [[String: String]]) in
                attempt += 1
                return (attempt, events)
            }
            return (result.0, try JSONSerialization.data(withJSONObject: [
                "discoverySucceeded": succeeded, "events": result.1
            ], options: [.prettyPrinted, .sortedKeys]))
        }
    }

    struct Fixture {
        let root: URL
        let center: SettingsCenter
        let manager: MCPServerManager
        let server: MCPServer
        let registry: MCPToolRegistry
        let ledger: ToolExecutionFactLedger
        let clientCapture: ClientCapture
        var fullName: String { MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet") }
    }

    func fixture(_ label: String, holdsList: Bool = false) throws -> Fixture {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("MCP3098-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.sh")
        // The original MCPClient selects its production Process/Pipe transport.
        // Only the remote MCP server and model reply are synthetic. No injected
        // MCPTransport, mock Process, external listener, or credentials are used.
        let body = #"""
        #!/bin/sh
        printf '%s\n' "$$" > "$MCP3098_ROOT/started.$$"
        [ ! -f "$MCP3098_ROOT/offline" ] || exit 7
        exec 2>> "$MCP3098_ROOT/stderr.$$.log"
        list_release=release-list
        if [ -f "$MCP3098_ROOT/hold-overlapping-discovery" ]; then
          list_release=release-overlapping-discovery
          printf 'waiting\n' > "$MCP3098_ROOT/overlap-waiting.$$"
          count=0
          while [ ! -f "$MCP3098_ROOT/$list_release" ] && [ ! -f "$MCP3098_ROOT/release-list" ] && [ "$count" -lt 200 ]; do
            sleep 0.02
            count=$((count + 1))
          done
          [ -f "$MCP3098_ROOT/$list_release" ] || exit 8
        fi
        emit_response() {
          printf '%s\n' "response:begin:$method:$id" >> "$MCP3098_ROOT/phase.$$.txt"
          printf "$@" >> "$MCP3098_ROOT/responses.$$.jsonl"
          printf "$@"
          response_status=$?
          printf '%s\n' "$response_status" >> "$MCP3098_ROOT/printf-exit.$$.txt"
          printf '%s\n' "response:printf-exit:$method:$id:$response_status" >> "$MCP3098_ROOT/phase.$$.txt"
          return "$response_status"
        }
        while IFS= read -r -t 20 line; do
          printf '%s\n' "$line" >> "$MCP3098_ROOT/requests.$$.jsonl"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\')
          printf '%s\n' "request:$method:$id" >> "$MCP3098_ROOT/phase.$$.txt"
          case "$method" in
            initialize)
              emit_response '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"owned3098","version":"1"}}}\n' "$id";;
            tools/list)
              if [ -f "$MCP3098_ROOT/hold-list" ]; then
                printf 'waiting\n' > "$MCP3098_ROOT/list-waiting.$$"
                count=0
                while [ ! -f "$MCP3098_ROOT/$list_release" ] && [ "$count" -lt 200 ]; do
                  sleep 0.02
                  count=$((count + 1))
                done
                [ -f "$MCP3098_ROOT/$list_release" ] || exit 8
              fi
              schema_type=string
              [ ! -f "$MCP3098_ROOT/schema-integer" ] || schema_type=integer
              emit_response '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"greet","description":"owned stdio fixture","inputSchema":{"type":"object","properties":{"value":{"type":"%s"}},"required":["value"]}}]}}\n' "$id" "$schema_type"
              printf 'written\n' > "$MCP3098_ROOT/list-written.$$";;
            tools/call)
              if [ -f "$MCP3098_ROOT/exit-on-call" ]; then
                printf 'offline\n' > "$MCP3098_ROOT/offline"
                printf 'exit7\n' > "$MCP3098_ROOT/exit-observed.$$"
                exit 7
              fi
              emit_response '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"owned stdio result"}]}}\n' "$id";;
            *) emit_response '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"unknown"}}\n' "$id";;
          esac
        done
        printf 'eof-or-bounded-timeout\n' > "$MCP3098_ROOT/finished.$$"
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        if holdsList { try Data().write(to: root.appendingPathComponent("hold-list")) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("environment"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("mcp3098-\(root.lastPathComponent)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        let server = MCPServer(id: "owned3098", name: "Owned stdio", type: .stdio,
            command: "/bin/sh", args: [script.path], env: ["MCP3098_ROOT": root.path], timeoutSeconds: 5)
        try #require(center.addMCPServer(server))
        try #require(center.setMCPServerAuthorized(id: server.id, authorized: true))
        try #require(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        return Fixture(root: root, center: center, manager: manager, server: server,
            registry: MCPToolRegistry(manager: manager),
            ledger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            clientCapture: ClientCapture())
    }

    func discover(_ f: Fixture, onFailure: ((String) -> Void)? = nil) async throws -> Bool {
        let capture = f.clientCapture
        let succeeded = await f.center.discoverMCPTools(for: f.server, clientFactory: {
            capture.makeClient(for: $0)
        }, onFailure: onFailure)
        let (attempt, data) = try f.clientCapture.finishDiscovery(succeeded)
        try data.write(to: f.root.appendingPathComponent("client-lifecycle.\(attempt).json"), options: .atomic)
        return succeeded
    }

    private func marker(_ name: String, _ f: Fixture) throws {
        try Data().write(to: f.root.appendingPathComponent(name))
    }

    private func hasFile(_ prefix: String, _ f: Fixture) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(prefix) }
    }

    private func waitForFile(_ prefix: String, _ f: Fixture) async throws {
        for _ in 0..<200 {
            if try hasFile(prefix, f) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let observedMarker = try hasFile(prefix, f)
        try #require(observedMarker, "real stdio marker missing: \(prefix)")
    }

    func wire(_ f: Fixture) throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("requests.") }.sorted { $0.path < $1.path }
        return try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
    }

    func providerTurn(
        _ f: Fixture, stage: String, callsTool: Bool,
        conversationID: String? = nil, turnID: Int = 1,
        sharedEngine: AgentLoopChatEngine? = nil
    ) async throws -> ProductionMCPProvider {
        let before = f.manager.discoverySnapshot(serverID: f.server.id)
        let engine: AgentLoopChatEngine
        if let sharedEngine {
            engine = sharedEngine
        } else {
            let bridge = TurnScopedMCPToolBridge(base: try f.registry.snapshotForTurn())
            let builtin = BuiltinToolExecutor(allowedRoot: f.root, mcpBridge: bridge)
            let created = Date()
            let goal = GoalEnvelope(scopeID: "test:mcp3098", allowedCapabilities: builtin.registeredToolNames,
                fileRoots: [f.root.path], budget: 10, deadline: created.addingTimeInterval(60),
                concurrencyLimit: 1, autonomyLevel: .l1, createdAt: created)
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: created, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
                capabilityResolver: builtin)
            engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
                approvalDelegate: ProductionApprovalDelegate(), mcpBridge: bridge,
                toolExecutionFactLedger: f.ledger)
        }
        let provider = ProductionMCPProvider()
        provider.requestedToolName = f.fullName
        provider.returnsPlainResponse = !callsTool
        let conversationID = conversationID ?? "mcp3098-\(f.root.lastPathComponent)-\(stage)"
        let history = [ChatMessageUI(role: .user, content: "owned synthetic MCP request")]
        let stream: AsyncThrowingStream<AgentStreamEvent, Error>
        if sharedEngine != nil {
            // ChatStore owns the stable conversation and Composer turn identity.
            // AgentLoopChatEngine creates a fresh local cancellation handle per
            // stream; its local handle number is not the persistent chat turn.
            let turn = AgentTurnIdentity(sessionID: conversationID, turnID: turnID,
                messageID: history[0].id.uuidString)
            let attemptID = UUID().uuidString
            let inputDigest = ComposerToolInput(values: [
                "content": .string(history[0].content), "attachments": .array([])
            ]).digest
            let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
                effort: .standard, sessionID: conversationID, turnID: turnID,
                taskID: "chat:\(conversationID):\(turnID):\(attemptID)",
                attemptID: attemptID, messageID: turn.messageID, inputDigest: inputDigest,
                workspaceID: "mcp3098-\(f.root.lastPathComponent)", createdAt: Date(),
                policyRevision: "mcp3098-policy", grantEpoch: "mcp3098-grant",
                autonomyCeiling: .l1)
            let identity = AgentExecutionIdentity(turn: turn,
                operationID: "chat:\(conversationID):\(turnID):\(turn.messageID)", attempt: 1)
            let runtime = ChatTurnRuntimeSnapshot(turn: turn, skillInjector: nil,
                skillsDisabled: true, mcpBridge: try f.registry.snapshotForTurn())
            stream = try await engine.streamReply(provider: provider, history: history,
                systemPrompt: "owned synthetic fixture", maxTokens: 128,
                conversationID: conversationID, authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil, turnID: turnID,
                composerSnapshot: snapshot, executionIdentity: identity,
                turnRuntimeSnapshot: runtime)
        } else {
            stream = try await engine.streamReply(provider: provider, history: history,
                systemPrompt: "owned synthetic fixture", maxTokens: 128,
                conversationID: conversationID, authorizedSessionReadSessionID: nil, turnID: turnID)
        }
        for try await _ in stream { }
        let encoder = JSONEncoder()
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        }
        let captured: [String: Any] = [
            "stage": stage, "root": f.root.path, "conversationID": conversationID, "localTurnID": turnID,
            "serverID": f.server.id, "fullName": f.fullName,
            "discoveryBeforeProvider": try object(before),
            "discoveryAfterProvider": try object(f.manager.discoverySnapshot(serverID: f.server.id)),
            "actualProviderTools": provider.receivedToolDefinitions.map { $0.map(\.openAIFunctionDict) },
            "actualCanonicalFacts": try object(f.ledger.facts), "actualStdioRequests": try wire(f)
        ]
        let file = f.root.appendingPathComponent("\(stage).runtime.json")
        try JSONSerialization.data(withJSONObject: captured, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
        print("TASK3098_RUNTIME stage=\(stage) root=\(f.root.path) artifact=\(file.path)")
        return provider
    }

    private func sameConversationEngine(_ f: Fixture) -> AgentLoopChatEngine {
        // Keep one App engine and its Core composition across all chat turns.
        // Dynamic MCP grants are minted only by each authorized registry turn
        // snapshot; the static Composer facts do not grant an MCP name.
        let builtin = BuiltinToolExecutor(allowedRoot: f.root, mcpBridge: f.registry)
        let created = Date()
        let goal = GoalEnvelope(scopeID: "test:mcp3098", allowedCapabilities: builtin.registeredToolNames,
            fileRoots: [f.root.path], budget: 10, deadline: created.addingTimeInterval(60),
            concurrencyLimit: 1, autonomyLevel: .l1, createdAt: created)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: created, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
            capabilityResolver: builtin)
        let facts = ComposerPolicyFactSource(knownCapabilities: [],
            grantedCapabilities: [], allowedWriteRoots: [f.root.path],
            workspaceID: "mcp3098-\(f.root.lastPathComponent)",
            revision: "mcp3098-policy", grantEpoch: "mcp3098-grant",
            leaseID: "mcp3098-lease-\(f.root.lastPathComponent)",
            expiresAt: created.addingTimeInterval(60), autonomyCeiling: .l1)
        return AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
            approvalDelegate: ProductionApprovalDelegate(), mcpBridge: f.registry,
            toolExecutionFactLedger: f.ledger, composerPolicyFacts: facts)
    }

    @Test func actualStdioSchemaReachesProviderAndDisabledNextTurnRemovesTool() async throws {
        let f = try fixture("schema-disabled")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let discovery = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        let first = try await providerTurn(f, stage: "online", callsTool: true)
        #expect(first.receivedToolDefinitions.count == 2)
        for request in first.receivedToolDefinitions {
            let tool = try #require(request.first { $0.name == f.fullName })
            #expect(tool.parameters["value"]?.type == .string)
            #expect(tool.required == ["value"])
        }
        #expect(try await f.registry.snapshotForTurn().mcpBoundTools().map(\.serverID) == [f.server.id])
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == discovery)
        let before = try wire(f)
        #expect(before.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(before.filter { $0["method"] as? String == "tools/call" }.count == 1)
        #expect(f.ledger.facts.count == 1 && f.ledger.facts.first?.status == .succeeded)
        try #require(f.center.toggleMCPServer(id: f.server.id, enabled: false))
        let next = try await providerTurn(f, stage: "disabled", callsTool: false)
        #expect(next.receivedToolDefinitions.count == 1)
        #expect(next.receivedToolDefinitions.allSatisfy { !$0.contains { $0.name == f.fullName } })
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
        #expect(try wire(f).count == before.count)
    }

    @Test func actualStdioAuthorizedCallsCacheDiscoveryAndRevocationFencesNextCall() async throws {
        let f = try fixture("grant-revoked")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let discovery = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        let frozenBeforeRevocation = try f.registry.snapshotForTurn()

        let first = try await providerTurn(f, stage: "first-authorized", callsTool: true)
        let second = try await providerTurn(f, stage: "second-authorized", callsTool: true)
        #expect(first.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
        #expect(second.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
        let before = try wire(f)
        #expect(before.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(before.filter { $0["method"] as? String == "tools/call" }.count == 2)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == discovery)
        #expect(f.ledger.facts.count == 2)
        #expect(f.ledger.facts.allSatisfy { $0.status == .succeeded })

        try #require(f.center.setMCPToolAuthorized(
            serverID: f.server.id, toolName: "greet", authorized: false
        ))
        #expect(!f.center.isMCPToolAuthorized(serverID: f.server.id, toolName: "greet"))
        await #expect(throws: MCPClientError.permissionDenied(f.fullName)) {
            try await frozenBeforeRevocation.callMCPTool(
                fullName: f.fullName, arguments: ["value": "denied"]
            )
        }
        let next = try await providerTurn(f, stage: "after-tool-revocation", callsTool: false)
        #expect(next.receivedToolDefinitions.count == 1)
        #expect(next.receivedToolDefinitions.allSatisfy { !$0.contains { $0.name == f.fullName } })
        let nextConsumer = try f.registry.snapshotForTurn()
        #expect(try await nextConsumer.mcpBoundTools().isEmpty)
        await #expect(throws: MCPClientError.toolNotFound(f.fullName)) {
            try await nextConsumer.callMCPTool(
                fullName: f.fullName, arguments: ["value": "denied"]
            )
        }
        let after = try wire(f)
        #expect(after.filter { $0["method"] as? String == "tools/list" }.count ==
            before.filter { $0["method"] as? String == "tools/list" }.count)
        #expect(after.filter { $0["method"] as? String == "tools/call" }.count ==
            before.filter { $0["method"] as? String == "tools/call" }.count)
        #expect(f.ledger.facts.count == 2)
        #expect(f.ledger.facts.allSatisfy { $0.status == .succeeded })
    }

    @Test func actualStdioSameConversationTwoTurnsReuseDiscoveryWithDistinctReceipts() async throws {
        let f = try fixture("same-conversation")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let discovery = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        let conversationID = "mcp3098-\(f.root.lastPathComponent)"
        let frozenBeforeRevocation = try f.registry.snapshotForTurn()
        let engine = sameConversationEngine(f)

        let first = try await providerTurn(f, stage: "same-conversation-turn-1",
            callsTool: true, conversationID: conversationID, turnID: 1, sharedEngine: engine)
        let second = try await providerTurn(f, stage: "same-conversation-turn-2",
            callsTool: true, conversationID: conversationID, turnID: 2, sharedEngine: engine)
        #expect(first.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
        #expect(second.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == discovery)
        let authorizedWire = try wire(f)
        #expect(authorizedWire.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(authorizedWire.filter { $0["method"] as? String == "tools/call" }.count == 2)
        let facts = f.ledger.facts
        #expect(facts.count == 2)
        #expect(facts.allSatisfy { $0.toolName == f.fullName && $0.status == .succeeded })
        #expect(facts.compactMap { $0.compositeKey?.sessionID } == [conversationID, conversationID])
        #expect(facts.compactMap { $0.compositeKey?.turnID } == [1, 2])
        #expect(facts.compactMap { $0.executionIdentity?.turn.sessionID } == [conversationID, conversationID])
        #expect(facts.compactMap { $0.executionIdentity?.turn.turnID } == [1, 2])
        #expect(Set(facts.map(\.receiptID)).count == 2)
        #expect(Set(facts.compactMap { $0.compositeKey?.rawValue }).count == 2)

        try #require(f.center.setMCPToolAuthorized(
            serverID: f.server.id, toolName: "greet", authorized: false
        ))
        #expect(!f.center.isMCPToolAuthorized(serverID: f.server.id, toolName: "greet"))
        await #expect(throws: MCPClientError.permissionDenied(f.fullName)) {
            try await frozenBeforeRevocation.callMCPTool(
                fullName: f.fullName, arguments: ["value": "denied"]
            )
        }
        let blocked = try await providerTurn(f, stage: "same-conversation-turn-3-blocked",
            callsTool: false, conversationID: conversationID, turnID: 3, sharedEngine: engine)
        #expect(blocked.receivedToolDefinitions.count == 1)
        #expect(blocked.receivedToolDefinitions.allSatisfy { !$0.contains { $0.name == f.fullName } })
        let after = try wire(f)
        #expect(after.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(after.filter { $0["method"] as? String == "tools/call" }.count == 2)
        #expect(f.ledger.facts == facts)
    }

    @Test func actualStdioExitWithdrawsNextProviderUntilExplicitRecovery() async throws {
        let f = try fixture("exit-recovery")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let original = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        try marker("exit-on-call", f)
        let failed = try await providerTurn(f, stage: "exited", callsTool: true)
        #expect(failed.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
        let observedProcessExit = try hasFile("exit-observed.", f)
        try #require(observedProcessExit)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
        #expect(f.ledger.facts.first?.status == .failed)
        let next = try await providerTurn(f, stage: "after-exit", callsTool: false)
        #expect(next.receivedToolDefinitions.count == 1)
        #expect(next.receivedToolDefinitions.allSatisfy { !$0.contains { $0.name == f.fullName } })
        #expect(try wire(f).filter { $0["method"] as? String == "tools/call" }.count == 1)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("offline"))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("exit-on-call"))
        try #require(try await discover(f))
        let recovered = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        #expect(recovered.schemaDigest == original.schemaDigest && recovered != original)
        #expect(try f.manager.retireDiscoveryAfterFailedRefresh(serverID: f.server.id, expected: original) == false)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == recovered)
        let final = try await providerTurn(f, stage: "recovered", callsTool: false)
        #expect(final.receivedToolDefinitions.first?.contains { $0.name == f.fullName } == true)
    }

    @Test func actualStdioLateListAfterDisableCannotPublishToNextProvider() async throws {
        let f = try fixture("late-list", holdsList: true)
        defer { f.registry.disconnectAll() }
        let discovery = Task { try await discover(f) }
        // Preserve bounded fixture retirement even if an assertion fails.
        defer { try? marker("release-list", f) }
        try await waitForFile("list-waiting.", f)
        try #require(f.center.toggleMCPServer(id: f.server.id, enabled: false))
        try marker("release-list", f)
        #expect(try await discovery.value == false)
        try await waitForFile("list-written.", f)
        #expect(f.center.mcpTools(for: f.server.id).isEmpty)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
        let next = try await providerTurn(f, stage: "late-disabled", callsTool: false)
        #expect(next.receivedToolDefinitions.count == 1)
        #expect(next.receivedToolDefinitions.allSatisfy { !$0.contains { $0.name == f.fullName } })
        #expect(try wire(f).filter { $0["method"] as? String == "tools/call" }.isEmpty)
        #expect(f.ledger.facts.isEmpty)
    }

    @Test(arguments: ["schema-drift", "descriptor-identity-drift", "unknown-model-name"])
    func actualStdioOfferedCatalogCannotDispatchInvalidHeldCall(_ caseName: String) async throws {
        let f = try fixture("negative-\(caseName)")
        defer { f.registry.disconnectAll() }
        try #require(try await discover(f))
        let initial = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
        let bridge = TurnScopedMCPToolBridge(base: try f.registry.snapshotForTurn())
        let offered = try await bridge.mcpBoundTools()
        #expect(offered.map(\.fullName) == [f.fullName])

        let builtin = BuiltinToolExecutor(allowedRoot: f.root, mcpBridge: bridge)
        let created = Date()
        let goal = GoalEnvelope(scopeID: "test:mcp3098-negative-\(caseName)",
            allowedCapabilities: builtin.registeredToolNames, fileRoots: [f.root.path],
            budget: 10, deadline: created.addingTimeInterval(60), concurrencyLimit: 1,
            autonomyLevel: .l1, createdAt: created)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: created, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
            capabilityResolver: builtin)
        let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 3,
            approvalDelegate: ProductionApprovalDelegate(), mcpBridge: bridge,
            toolExecutionFactLedger: f.ledger)
        let requestedName = caseName == "unknown-model-name"
            ? MCPBoundTool.makeFullName(serverID: f.server.id, toolName: "missing") : f.fullName
        let callID = "mcp3098-negative-\(caseName)-call"
        let provider = MCP3098HeldModel(requestedName: requestedName, callID: callID)
        defer { provider.release.signal() }
        let running = Task {
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "owned synthetic MCP request")],
                systemPrompt: "owned synthetic fixture", maxTokens: 128,
                conversationID: "mcp3098-negative-\(caseName)",
                authorizedSessionReadSessionID: nil, turnID: 1)
            for try await _ in stream { }
        }
        for _ in 0..<100 where !provider.entered.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.entered.isReady)
        #expect(provider.offeredNames.first?.contains(f.fullName) == true)
        let before = try wire(f)
        #expect(before.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(before.filter { $0["method"] as? String == "tools/call" }.isEmpty)

        switch caseName {
        case "schema-drift":
            // A second real tools/list response changes the same tool schema.
            try marker("schema-integer", f)
            try #require(try await discover(f))
            let changed = try #require(f.manager.discoverySnapshot(serverID: f.server.id))
            #expect(changed.schemaDigest != initial.schemaDigest)
            #expect(!f.center.isMCPToolAuthorized(serverID: f.server.id, toolName: "greet"))
            #expect(try await bridge.mcpBoundTools().isEmpty)
            #expect(try wire(f).filter { $0["method"] as? String == "tools/list" }.count == 2)
        case "descriptor-identity-drift":
            // The server still points to the same owned script; changed argv
            // gives it a new descriptor identity and retires the old grant.
            let changedServer = MCPServer(id: f.server.id, name: f.server.name,
                type: .stdio, command: "/bin/sh",
                args: [f.root.appendingPathComponent("server.sh").path, "--identity-drift"],
                env: ["MCP3098_ROOT": f.root.path], timeoutSeconds: 5)
            #expect(changedServer.descriptorFingerprint != f.server.descriptorFingerprint)
            try #require(f.center.addMCPServer(changedServer))
            #expect(!f.center.isMCPServerAuthorized(id: f.server.id))
            #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
            // An in-flight turn retains its captured catalog; the next turn
            // must observe the descriptor boundary as deny-all.
            let nextTurn = try f.registry.snapshotForTurn()
            #expect(try await nextTurn.mcpBoundTools().isEmpty)
        default:
            #expect(caseName == "unknown-model-name")
            #expect(f.manager.discoverySnapshot(serverID: f.server.id) == initial)
            #expect(try await bridge.mcpBoundTools().map(\.fullName) == [f.fullName])
        }
        provider.release.signal()
        try await running.value

        let feedback = provider.receivedFeedback.filter { $0.toolCallID == callID }
        #expect(feedback.count == 1)
        #expect(feedback.first?.content.contains(requestedName) == true)
        let after = try wire(f)
        #expect(after.filter { $0["method"] as? String == "tools/call" }.isEmpty,
            "Invalid model calls must never reach the actual stdio worker")
        #expect(executor.acceptedExecutionCount == 0)
        #expect(f.ledger.pendingReceipts.isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("facts.json"))
        #expect(reopened.facts == f.ledger.facts)
        #expect(reopened.pendingReceipts.isEmpty)
        if caseName == "unknown-model-name" {
            // Catalog rejection occurs before Policy and before minting a fact.
            #expect(executor.deniedExecutionCount == 0)
            #expect(f.ledger.facts.isEmpty)
        } else {
            #expect(executor.deniedExecutionCount == 1)
            #expect(executor.lastCapabilityDenialReceipt?.capabilityID == f.fullName)
            #expect(executor.lastCapabilityDenialReceipt?.reason == .capabilityNotAllowed)
            #expect(f.ledger.facts.count == 1)
            let fact = try #require(f.ledger.facts.first)
            #expect(fact.toolCallID == callID && fact.toolName == f.fullName && fact.status == .failed)
        }
    }
}
