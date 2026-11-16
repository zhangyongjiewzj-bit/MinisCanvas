import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private struct MCP1025UnexpectedApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        Issue.record("schema-only SDK reply must not request tool approval")
        return .deny
    }
}

/// Only the remote MCP server and HTTP endpoint are synthetic. Discovery,
/// turn-scoped tooling, AgentLoopChatEngine and the OpenAI-compatible SDK are
/// the production implementations. The HTTP fixture retains tool definitions,
/// never an Authorization header or conversation content.
private final class MCP1025HTTPWire: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var capturedTools: [[[String: Any]]] = []
    private var releaseHeldResponse = false
    private var failure: String?
    private var stopped = false
    let port: UInt16

    var tools: [[[String: Any]]] { lock.withLock { capturedTools } }
    var captureFailure: String? { lock.withLock { failure } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            _ = Darwin.close(fd); throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else {
            _ = Darwin.close(fd); throw URLError(.cannotConnectToHost)
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }

    deinit { stop() }

    func releaseFirstResponse() { lock.withLock { releaseHeldResponse = true } }

    func stop() {
        let shouldClose = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            releaseHeldResponse = true
            return true
        }
        if shouldClose {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
    }

    private func serve() {
        for _ in 0..<2 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let complete = serve(client: client)
            _ = Darwin.close(client)
            guard complete else { return }
        }
    }

    private func serve(client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 2_000_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failure = "incomplete HTTP entity" }; return false }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
            let lines = headers.components(separatedBy: "\r\n")
            let entityLength = lines.compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces))
            }.first
            guard let entityLength, entityLength > 0, entityLength < 2_000_000 else {
                lock.withLock { failure = "missing bounded Content-Length" }
                return false
            }
            guard received.count >= boundary.upperBound + entityLength else { continue }
            let entity = received.subdata(in: boundary.upperBound..<(boundary.upperBound + entityLength))
            guard let body = try? JSONSerialization.jsonObject(with: entity) as? [String: Any],
                  let definitions = body["tools"] as? [[String: Any]] else {
                lock.withLock { failure = "SDK request omitted tool definitions" }
                return false
            }
            let requestIndex = lock.withLock { () -> Int in
                capturedTools.append(definitions)
                return capturedTools.count - 1
            }
            if requestIndex == 0 {
                for _ in 0..<400 {
                    if lock.withLock({ releaseHeldResponse || stopped }) { break }
                    usleep(10_000)
                }
                guard lock.withLock({ releaseHeldResponse }) else {
                    lock.withLock { failure = "held response was not released" }
                    return false
                }
            }
            let payload = #"data: {"choices":[{"index":0,"delta":{"content":"owned1025"},"finish_reason":null}]}"#
                + "\n\n" + #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
                + "\n\ndata: [DONE]\n\n"
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)".utf8)
            return response.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return false }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { return false }
                    sent += count
                }
                return true
            }
        }
        lock.withLock { failure = "HTTP entity exceeded fixture bound" }
        return false
    }
}

@Suite("D-MCP-03 actual stdio discovery reaches SDK wire definitions")
@MainActor
struct MCPDiscoveryWireSnapshot1025Tests {
    private func waitForCaptured(_ wire: MCP1025HTTPWire, count: Int) async throws {
        for _ in 0..<300 {
            if wire.tools.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(wire.tools.count >= count, "owned SDK request was not captured")
    }

    private func function(_ name: String, in definitions: [[String: Any]]) -> [String: Any]? {
        definitions.compactMap { $0["function"] as? [String: Any] }
            .first { $0["name"] as? String == name }
    }

    @Test func configChangeAfterSDKRequestCannotMutateFirstTurnAndNextTurnDropsMCP() async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("MCP1025-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.sh")
        let body = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\')
          case "$method" in
            initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"owned1025","version":"1"}}}\n' "$id";;
            tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"greet","description":"owned stdio schema","inputSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}]}}\n' "$id";;
            *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"unknown"}}\n' "$id";;
          esac
        done
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
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
            usageStore: UsageStore(domain: .suite("mcp1025-\(root.lastPathComponent)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let server = MCPServer(id: "owned1025", name: "Owned stdio", type: .stdio,
            command: "/bin/sh", args: [script.path], env: [:], timeoutSeconds: 5)
        try #require(center.addMCPServer(server))
        try #require(center.setMCPServerAuthorized(id: server.id, authorized: true))
        try #require(center.setMCPToolAuthorized(serverID: server.id, toolName: "greet", authorized: true))
        let registry = MCPToolRegistry(manager: manager)
        defer { registry.disconnectAll() }
        try #require(await center.discoverMCPTools(for: server))
        let discovery = try #require(manager.discoverySnapshot(serverID: server.id))
        #expect(discovery.serverID == server.id && discovery.tools.map(\.name) == ["greet"])
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        let wire = try MCP1025HTTPWire()
        defer { wire.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(apiKey: "owned-synthetic1025",
            model: LLMModel(id: "owned-model1025", displayName: "Owned", provider: "owned"),
            customBaseURL: "http://127.0.0.1:\(wire.port)", appendV1Suffix: false,
            session: session, providerName: "Owned1025")

        func runTurn(_ stage: String) async throws -> (allowed: [String], dynamicMCPAllowed: Bool, response: String) {
            let bridge = TurnScopedMCPToolBridge(base: try registry.snapshotForTurn())
            let builtin = BuiltinToolExecutor(allowedRoot: root, mcpBridge: bridge)
            let created = Date()
            let goal = GoalEnvelope(scopeID: "test:mcp1025", allowedCapabilities: builtin.registeredToolNames,
                fileRoots: [root.path], budget: 10, deadline: created.addingTimeInterval(60),
                concurrencyLimit: 1, autonomyLevel: .l1, createdAt: created)
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: created, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease,
                capabilityResolver: builtin)
            let dynamicMCPAllowed = try await builtin.resolvesCapability(fullName)
            let engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 2,
                approvalDelegate: MCP1025UnexpectedApproval(), mcpBridge: bridge,
                toolExecutionFactLedger: try ToolExecutionFactLedger(
                    persistenceURL: root.appendingPathComponent("facts-\(stage).json")))
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "owned synthetic request")],
                systemPrompt: "owned synthetic fixture", maxTokens: 128,
                conversationID: "mcp1025-\(stage)", authorizedSessionReadSessionID: nil, turnID: 1)
            var text = ""
            for try await event in stream {
                if case .textDelta(let delta) = event { text += delta }
            }
            return (builtin.registeredToolNames.sorted(), dynamicMCPAllowed, text)
        }

        let first = Task { try await runTurn("first") }
        // A captured HTTP request is pending while settings change. Its body
        // is already the SDK's actual immutable wire entity for this turn.
        defer { wire.releaseFirstResponse() }
        try await waitForCaptured(wire, count: 1)
        let firstDefinitions = try #require(wire.tools.first)
        let firstFunction = try #require(function(fullName, in: firstDefinitions))
        let firstSchema = try #require(firstFunction["parameters"] as? [String: Any])
        #expect(firstSchema["type"] as? String == "object")
        #expect(firstSchema["required"] as? [String] == ["value"])
        try #require(center.toggleMCPServer(id: server.id, enabled: false))
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        #expect(function(fullName, in: try #require(wire.tools.first)) != nil)
        wire.releaseFirstResponse()
        let firstResult = try await first.value
        #expect(firstResult.response.contains("owned1025"))
        #expect(firstResult.dynamicMCPAllowed)
        let secondResult = try await runTurn("second")
        #expect(secondResult.response.contains("owned1025"))
        #expect(!secondResult.dynamicMCPAllowed)
        try await waitForCaptured(wire, count: 2)
        #expect(function(fullName, in: wire.tools[1]) == nil)
        #expect(wire.captureFailure == nil)

        let snapshot: [String: Any] = [
            "serverID": server.id, "originalToolID": "greet", "providerToolID": fullName,
            "discoveryID": discovery.id, "discoveryRevision": discovery.revision,
            "schemaDigest": discovery.schemaDigest,
            "turn1PolicyAllowedNames": firstResult.allowed,
            "turn2PolicyAllowedNames": secondResult.allowed,
            "turn1DynamicMCPAllowed": firstResult.dynamicMCPAllowed,
            "turn2DynamicMCPAllowed": secondResult.dynamicMCPAllowed,
            "turn1ActualSDKWireTools": firstDefinitions,
            "turn2ActualSDKWireTools": wire.tools[1],
            "configChangedWhileTurn1HTTPRequestPending": true
        ]
        let artifact = root.appendingPathComponent("mcp03-actual-sdk-wire.json")
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        print("MCP1025_ACTUAL_WIRE artifact=\(artifact.path)")
    }
}
