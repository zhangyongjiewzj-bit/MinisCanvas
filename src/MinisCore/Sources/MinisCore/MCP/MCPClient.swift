import Foundation
import Darwin
import Dispatch

private enum MCPRuntimeLimits {
    static let minimumTimeoutSeconds = 1
    static let maximumTimeoutSeconds = 24 * 60 * 60
    static let maximumOutboundPayloadBytes = 1_048_576
    static let maximumHTTPHeaderCount = 64
    static let maximumHTTPHeaderNameBytes = 256
    static let maximumHTTPHeaderValueBytes = 8 * 1024
    static let maximumHTTPHeaderBytes = 16 * 1024

    static func validate(timeoutSeconds: Int) throws {
        guard (minimumTimeoutSeconds...maximumTimeoutSeconds).contains(timeoutSeconds) else {
            throw MCPClientError.invalidServer(
                "timeoutSeconds must be between \(minimumTimeoutSeconds) and \(maximumTimeoutSeconds)"
            )
        }
    }

    static func validateOutboundPayloadBytes(_ byteCount: Int) throws {
        guard byteCount <= maximumOutboundPayloadBytes else {
            throw MCPClientError.invalidMessage("MCP outbound payload exceeds byte limit")
        }
    }
}

// MARK: - Transport Protocol

/// A JSON-RPC transport for one MCP server (stdio process or HTTP endpoint).
public protocol MCPTransport: Sendable {
    /// Whether this transport still owns a live/reusable runtime.
    /// Stateless transports are ready by default; process transports override
    /// this so a natural exit cannot leave the client falsely connected.
    var isReady: Bool { get }
    /// Establish the transport (spawn process / warm up). Idempotent-safe.
    func start() async throws
    /// Send one JSON-RPC request and await its response (with timeout).
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse
    /// Send a JSON-RPC notification (no id — the server sends no response).
    func notify(_ notification: MCPJSONRPCNotification) throws
    /// Tear the transport down (terminate process / cancel pending).
    func stop()
}

public extension MCPTransport {
    var isReady: Bool { true }
}

/// A small, user-facing lifecycle projection for MCP clients.  It deliberately
/// contains no command arguments, environment values, or server output.
public enum MCPClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Process/transport lifecycle used by recovery and diagnostics consumers.
/// `ownerID` is an opaque fence token and must never be treated as a secret.
public enum MCPTransportState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed(String)
}

public struct MCPTransportSnapshot: Equatable, Sendable {
    public let state: MCPTransportState
    public let ownerID: UUID?
    public let generation: UInt64
    public let processIdentifier: Int32?

    public init(state: MCPTransportState, ownerID: UUID?, generation: UInt64, processIdentifier: Int32?) {
        self.state = state
        self.ownerID = ownerID
        self.generation = generation
        self.processIdentifier = processIdentifier
    }

    /// Stable identity for accepting runtime output.  A missing identity is
    /// intentionally not usable: stopped/failed runtimes cannot authorize
    /// late output from an older process.
    public var runtimeIdentity: MCPRuntimeIdentity? {
        guard let ownerID else { return nil }
        return MCPRuntimeIdentity(ownerID: ownerID, generation: generation)
    }
}

/// Opaque owner + generation fence for one MCP runtime instance.  Consumers
/// must capture this before dispatching work and reject any result that no
/// longer matches the current transport runtime.
public struct MCPRuntimeIdentity: Equatable, Sendable {
    public let ownerID: UUID
    public let generation: UInt64

    public init(ownerID: UUID, generation: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
    }
}

/// Client-level lifecycle projection. The generation changes whenever a
/// connection owner is replaced, so consumers can reject stale callbacks.
public struct MCPClientLifecycleSnapshot: Equatable, Sendable {
    public let state: MCPClientState
    public let generation: UInt64
    public let replacementSessionID: String
    public let runtime: MCPTransportSnapshot?

    public init(
        state: MCPClientState,
        generation: UInt64,
        replacementSessionID: String,
        runtime: MCPTransportSnapshot?
    ) {
        self.state = state
        self.generation = generation
        self.replacementSessionID = replacementSessionID
        self.runtime = runtime
    }
}

// MARK: - Client

/// Minimal MCP client: `initialize` handshake → `tools/list` → `tools/call`,
/// over a pluggable transport. Ported in spirit from OpenMinis
/// (Agent/Session/MCPStore.swift manages configs; the client itself lived in
/// the in-guest `minis-mcp-cli` — here it is native Swift).
public final class MCPClient: @unchecked Sendable {

    public let server: MCPServer
    /// Hard upper bound for textual tool output returned to the agent loop.
    public let maxOutputCharacters: Int
    private let transport: any MCPTransport
    private let stateLock = NSLock()
    private static let maxCallArgumentJSONDepth = 64
    private var connectedRuntimeID: UUID?
    private var connected = false
    private var state: MCPClientState = .disconnected
    private var nextRequestID = 1
    private var lifecycleGeneration: UInt64 = 0
    /// One handshake owner per client. Concurrent callers join this task so
    /// a second `initialize` cannot invalidate the first caller's generation.
    private var connectionAttempt: Task<Void, Error>?
    private struct ElicitationCall {
        let requestID: MCPID
        let runtimeID: UUID
        let invocation: MCPToolInvocationIdentity
        let handler: @Sendable (MCPElicitationContext, MCPElicitationForm) async throws -> MCPElicitationResult
    }
    private var elicitationCall: ElicitationCall?
    private var activeElicitationRequest: MCPID?
    private var runtimeChangedHandler: (@Sendable () -> Void)?
    private var toolsChangedHandler: (@Sendable () -> Void)?
    private var serverSupportsListChanged = false
    private var negotiatedElicitation = false
    private var diagnosticFailureObserver: (@Sendable (MCPClientLifecycleSnapshot) -> Void)?

    /// `transport` defaults to the transport matching `server.type`
    /// (stdio / http). Inject a mock in tests.
    public init(server: MCPServer, transport: (any MCPTransport)? = nil, maxOutputCharacters: Int = MCPOutputLimiter.defaultMaximumCharacters) {
        self.server = server
        self.transport = transport ?? MCPClient.makeTransport(for: server)
        self.maxOutputCharacters = max(0, maxOutputCharacters)
        if let stdio = self.transport as? MCPStdioTransport {
            stdio.setInboundHandlers(request: { [weak self] request, owner in
                guard let self else { return MCPJSONRPCResponse(id: request.id, error: .init(code: -32603, message: "Client retired")) }
                return await self.receiveServerRequest(request, runtimeID: owner)
            }, notification: { [weak self] notification, owner in
                self?.receiveServerNotification(notification, runtimeID: owner)
            }, exited: { [weak self] owner in self?.observedTransportExit(ownerID: owner) })
        }
    }

    deinit {
        // A turn snapshot owns its cached clients separately from the origin
        // registry. Release its real process when the last client owner leaves.
        transport.stop()
    }

    public static func makeTransport(for server: MCPServer) -> any MCPTransport {
        switch server.type {
        case .http:
            guard let urlString = server.url, let url = URL(string: urlString) else {
                // Invalid http server — return a transport that always throws.
                return MCPHTTPTransport(url: URL(string: "http://127.0.0.1:1")!, headers: server.headers, timeoutSeconds: server.timeoutSeconds, invalid: true)
            }
            return MCPHTTPTransport(url: url, headers: server.headers, timeoutSeconds: server.timeoutSeconds)
        case .stdio:
            guard let command = server.command, !command.isEmpty else {
                return MCPStdioTransport(command: "/bin/false", args: [], env: [:], timeoutSeconds: server.timeoutSeconds, invalid: true)
            }
            return MCPStdioTransport(command: command, args: server.args, env: server.env, timeoutSeconds: server.timeoutSeconds)
        }
    }

    /// Start the transport and run the MCP `initialize` handshake
    /// (+ `notifications/initialized`). Idempotent: repeated calls no-op.
    public func connect() async throws {
        guard let attempt = beginOrJoinConnection() else { return }
        try await attempt.value
        try Task.checkCancellation()
    }

    private func beginOrJoinConnection() -> Task<Void, Error>? {
        stateLock.lock()
        if connected, transport.isReady {
            stateLock.unlock()
            return nil
        }
        if let connectionAttempt {
            stateLock.unlock()
            return connectionAttempt
        }
        lifecycleGeneration &+= 1
        connectedRuntimeID = nil
        connected = false
        state = .connecting
        let generation = lifecycleGeneration
        let attempt = Task { [weak self] in
            guard let self else { throw MCPClientError.transportNotStarted }
            defer { self.finishConnectionAttempt(generation: generation) }
            try await self.performConnection(generation: generation)
        }
        connectionAttempt = attempt
        stateLock.unlock()
        publishRuntimeChange()
        return attempt
    }

    private func performConnection(generation: UInt64) async throws {

        do {
            try MCPRuntimeLimits.validate(timeoutSeconds: server.timeoutSeconds)
            try await transport.start()
            guard lifecycleGenerationMatches(generation) else {
                throw MCPClientError.transportNotStarted
            }
            var clientCapabilities: [String: MCPJSONValue] = ["roots": .object(["listChanged": .bool(false)])]
            if transport is MCPStdioTransport { clientCapabilities["elicitation"] = .object(["form": .object([:])]) }
            let capabilities = MCPJSONValue.object(clientCapabilities)
            let request = MCPJSONRPCRequest(
                id: nextID(),
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(transport is MCPStdioTransport ? "2025-11-25" : "2024-11-05"),
                    "capabilities": capabilities,
                    "clientInfo": .object([
                        "name": .string("MinisCanvas"),
                        "version": .string("0.1.0"),
                    ]),
                ])
            )
            let response = try await transport.send(request)
            try validate(response, for: request, generation: generation)
            if let rpcError = response.error {
                throw MCPClientError.rpcError(code: rpcError.code, message: rpcError.message)
            }
            setServerCapabilities(response.result)
            // `notifications/initialized` — one-way notification (no id, no
            // response; per MCP spec), but its local write must succeed.
            let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)
            // The notification has no response, but a failed write still
            // means the server was never fully initialized. Do not publish a
            // connected state after a transport rejected this lifecycle edge.
            try transport.notify(notification)

            // A response can race with process EOF.  Do not publish a
            // connected state after the transport has already lost its live
            // owner; the caller must take the explicit recovery path.
            guard lifecycleGenerationMatches(generation), transport.isReady else {
                throw MCPClientError.processExited(-1)
            }
            setConnected(true, generation: generation)
        } catch {
            guard lifecycleGenerationMatches(generation) else { throw error }
            transport.stop()
            setState(.failed(Self.userFacing(error)), generation: generation)
            throw error
        }
    }

    private func finishConnectionAttempt(generation: UInt64) {
        stateLock.lock()
        if lifecycleGeneration == generation {
            connectionAttempt = nil
        }
        stateLock.unlock()
    }

    private static let maxToolListPages = 1_024
    private static let maxToolsPerPage = 2_048
    private static let maxToolNameBytes = 256
    private static let maxToolListCursorBytes = 64 * 1024
    private static let maxPageSerializedSchemaBytes = 512 * 1024
    private static let maxToolListTools = 10_000
    private static let maxToolListJSONBytes = 4 * 1024 * 1024
    private static let maxToolListSerializedSchemaBytes = 4 * 1024 * 1024

    /// Fetch every page of the server's tool list (`tools/list`). A repeated
    /// cursor or unbounded page stream fails closed before returning any
    /// partial list.
    public func listTools() async throws -> [MCPTool] {
        var allTools: [MCPTool] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var totalTools = 0
        var totalJSONBytes = 0
        var totalSerializedSchemaBytes = 0
        var finished = false
        var expectedServerIdentity: String?
        var expectedTransportGeneration: UInt64?
        for _ in 0..<Self.maxToolListPages {
            let page = try await listToolsPage(cursor: cursor)
            if let expectedServerIdentity {
                guard page.serverIdentity == expectedServerIdentity else {
                    disconnect()
                    throw MCPClientError.badResponse("tools/list pagination changed server identity")
                }
            } else {
                expectedServerIdentity = page.serverIdentity
            }
            if let expectedTransportGeneration {
                guard page.transportGeneration == expectedTransportGeneration else {
                    disconnect()
                    throw MCPClientError.badResponse("tools/list pagination changed transport generation")
                }
            } else {
                expectedTransportGeneration = page.transportGeneration
            }
            totalTools += page.tools.count
            totalJSONBytes += page.jsonBytes
            totalSerializedSchemaBytes += page.serializedSchemaBytes
            guard totalTools <= Self.maxToolListTools else {
                throw MCPClientError.badResponse("tools/list pagination exceeded tool limit")
            }
            guard totalJSONBytes <= Self.maxToolListJSONBytes else {
                throw MCPClientError.badResponse("tools/list pagination exceeded JSON byte limit")
            }
            guard totalSerializedSchemaBytes <= Self.maxToolListSerializedSchemaBytes else {
                throw MCPClientError.badResponse("tools/list pagination exceeded schema byte limit")
            }
            allTools.append(contentsOf: page.tools)
            guard let nextCursor = page.nextCursor else {
                finished = true
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw MCPClientError.badResponse("tools/list pagination repeated cursor")
            }
            cursor = nextCursor
            try Task.checkCancellation()
        }
        guard finished else {
            throw MCPClientError.badResponse("tools/list pagination exceeded page limit")
        }
        return allTools
    }

    /// Fetch one page of `tools/list`. Discovery consumers can check their
    /// own configuration/authorization generation between pages.
    public func listToolsPage(cursor: String? = nil) async throws -> MCPToolListPage {
        if let cursor {
            guard cursor.utf8.count <= Self.maxToolListCursorBytes else {
                throw MCPClientError.badResponse("tools/list cursor exceeded byte limit")
            }
        }
        let generation = try await ensureConnected()
        let request = MCPJSONRPCRequest(
            id: nextID(),
            method: "tools/list",
            params: cursor.map { .object(["cursor": .string($0)]) }
        )
        let response = try await transport.send(request)
        try validate(response, for: request, generation: generation)
        if let rpcError = response.error {
            throw MCPClientError.rpcError(code: rpcError.code, message: rpcError.message)
        }
        guard case .object(let result)? = response.result,
              case .array(let rawTools)? = result["tools"] else {
            throw MCPClientError.badResponse("tools/list result missing 'tools' array")
        }
        guard rawTools.count <= Self.maxToolsPerPage else {
            throw MCPClientError.badResponse("tools/list page exceeded tool limit")
        }
        var tools: [MCPTool] = []
        var serializedSchemaBytes = 0
        let encoder = JSONEncoder()
        for raw in rawTools {
            guard case .object(let obj) = raw,
                  case .string(let name)? = obj["name"],
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPClientError.badResponse(
                    "tools/list tool entry missing non-empty 'name'"
                )
            }
            guard name.utf8.count <= Self.maxToolNameBytes else {
                throw MCPClientError.badResponse("tools/list tool entry name exceeds byte limit")
            }
            guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MCPClientError.badResponse("tools/list tool entry name contains a control character")
            }
            let description: String?
            switch obj["description"] {
            case nil:
                description = nil
            case .some(.string(let value)):
                description = value
            default:
                throw MCPClientError.badResponse(
                    "tools/list tool entry has invalid 'description'"
                )
            }
            if let schema = obj["inputSchema"] {
                guard case .object = schema else {
                    throw MCPClientError.badResponse(
                        "tools/list tool entry has invalid 'inputSchema'"
                    )
                }
            }
            if let schema = obj["inputSchema"] {
                do {
                    serializedSchemaBytes += try encoder.encode(schema).count
                } catch {
                    throw MCPClientError.badResponse("tools/list input schema could not be measured")
                }
                guard serializedSchemaBytes <= Self.maxPageSerializedSchemaBytes else {
                    throw MCPClientError.badResponse("tools/list page exceeded schema byte limit")
                }
            }
            tools.append(MCPTool(name: name, description: description, inputSchema: obj["inputSchema"], _meta: obj["_meta"]))
        }
        let nextCursor: String?
        switch result["nextCursor"] {
        case nil, .some(.null):
            nextCursor = nil
        case .some(.string(let value)):
            guard !value.isEmpty, value.utf8.count <= Self.maxToolListCursorBytes else {
                throw MCPClientError.badResponse("tools/list result has invalid 'nextCursor'")
            }
            nextCursor = value
        default:
            throw MCPClientError.badResponse("tools/list result has invalid 'nextCursor'")
        }
        let jsonBytes: Int
        do {
            jsonBytes = try JSONEncoder().encode(MCPJSONValue.object(result)).count
        } catch {
            throw MCPClientError.badResponse("tools/list result could not be measured")
        }
        return MCPToolListPage(
            tools: tools,
            nextCursor: nextCursor,
            jsonBytes: jsonBytes,
            serializedSchemaBytes: serializedSchemaBytes,
            serverIdentity: "\(server.id):\(server.descriptorFingerprint)",
            transportGeneration: generation
        )
    }

    /// Call one tool (`tools/call`) and return its textual content — the
    /// `text` parts of the `content` array joined with newlines.
    public func callTool(name: String, arguments: [String: Any]?, invocation: MCPToolInvocationIdentity? = nil) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPClientError.toolNotFound(name)
        }
        guard name.utf8.count <= Self.maxToolNameBytes,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPClientError.toolNotFound(name)
        }
        if let arguments,
           arguments.values.contains(where: { !Self.isJSONRepresentable($0, depth: 0) }) {
            throw MCPClientError.badResponse(
                "tools/call arguments contain an unsupported value"
            )
        }
        let generation = try await ensureConnected()
        var params: MCPJSONValue = .object(["name": .string(name)])
        if let arguments {
            params = .object(["name": .string(name), "arguments": .object(arguments.mapValues { MCPJSONValue.fromAny($0) })])
        }
        let request = MCPJSONRPCRequest(
            id: nextID(),
            method: "tools/call",
            params: params
        )
        installElicitationCall(requestID: request.id, invocation: invocation)
        defer { clearElicitationCall(requestID: request.id) }
        let response = try await transport.send(request)
        try validate(response, for: request, generation: generation)
        if let rpcError = response.error {
            throw MCPClientError.rpcError(code: rpcError.code, message: rpcError.message)
        }
        guard case .object(let result)? = response.result,
              case .array(let content)? = result["content"] else {
            throw MCPClientError.badResponse("tools/call result missing 'content' array")
        }
        var texts: [String] = []
        for raw in content {
            guard case .object(let obj) = raw,
                  case .string(let type)? = obj["type"] else {
                throw MCPClientError.badResponse(
                    "tools/call content item missing string 'type'"
                )
            }
            guard type == "text" else { continue }
            guard case .string(let text)? = obj["text"] else {
                throw MCPClientError.badResponse(
                    "tools/call text content item missing string 'text'"
                )
            }
            texts.append(text)
        }
        return MCPOutputLimiter.limit(texts, to: maxOutputCharacters)
    }

    public func setRuntimeChangedHandler(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock(); defer { stateLock.unlock() }
        runtimeChangedHandler = handler
    }
    private func observedTransportExit(ownerID: UUID) {
        stateLock.lock()
        guard connectedRuntimeID == ownerID else { stateLock.unlock(); return }
        let generation = lifecycleGeneration
        stateLock.unlock()
        setState(.failed("MCP 服务器已断开，请重连"), generation: generation)
    }
    private func publishRuntimeChange() {
        stateLock.lock(); let handler = runtimeChangedHandler; stateLock.unlock()
        handler?()
    }
    public func setToolsChangedHandler(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock(); defer { stateLock.unlock() }
        toolsChangedHandler = handler
    }
    private func setServerCapabilities(_ result: MCPJSONValue?) {
        stateLock.lock(); defer { stateLock.unlock() }
        serverSupportsListChanged = false
        negotiatedElicitation = false
        guard case .object(let result)? = result else { return }
        if case .string(let version)? = result["protocolVersion"] {
            negotiatedElicitation = ["2025-06-18", "2025-11-25"].contains(version)
        }
        if case .object(let caps)? = result["capabilities"], case .object(let tools)? = caps["tools"] {
            serverSupportsListChanged = tools["listChanged"] == .bool(true)
        }
    }
    private func receiveServerNotification(_ notification: MCPJSONRPCNotification, runtimeID: UUID) {
        guard (transport as? MCPStdioTransport)?.runtimeSnapshot().ownerID == runtimeID else { return }
        stateLock.lock()
        let callback = connected && serverSupportsListChanged && notification.method == "notifications/tools/list_changed" ? toolsChangedHandler : nil
        stateLock.unlock()
        callback?()
    }
    private func installElicitationCall(requestID: MCPID, invocation: MCPToolInvocationIdentity?) {
        guard let handler = MCPElicitationTaskContext.handler, let invocation,
              let stdio = transport as? MCPStdioTransport,
              let runtimeID = stdio.runtimeSnapshot().ownerID else { return }
        stateLock.lock(); defer { stateLock.unlock() }
        // A second ordinary call must still reach the original transport.
        // It does not inherit or replace the first call's UI handler.
        guard elicitationCall == nil else { return }
        elicitationCall = ElicitationCall(requestID: requestID, runtimeID: runtimeID, invocation: invocation, handler: handler)
    }
    private func clearElicitationCall(requestID: MCPID) {
        stateLock.lock()
        let owns = elicitationCall?.requestID == requestID
        if owns { elicitationCall = nil; activeElicitationRequest = nil }
        stateLock.unlock()
        if owns { (transport as? MCPStdioTransport)?.cancelInboundRequests() }
    }
    private func activeElicitationCall(runtimeID: UUID) -> ElicitationCall? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard negotiatedElicitation, let call = elicitationCall, call.runtimeID == runtimeID else { return nil }
        return call
    }
    private func claimElicitationRequest(_ requestID: MCPID, parentID: MCPID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard elicitationCall?.requestID == parentID, activeElicitationRequest == nil else { return false }
        activeElicitationRequest = requestID
        return true
    }
    private func releaseElicitationRequest(_ requestID: MCPID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if activeElicitationRequest == requestID { activeElicitationRequest = nil }
    }
    private func receiveServerRequest(_ request: MCPJSONRPCRequest, runtimeID: UUID) async -> MCPJSONRPCResponse {
        guard request.method == "elicitation/create" else {
            return MCPJSONRPCResponse(id: request.id, error: .init(code: -32601, message: "Unsupported client method"))
        }
        guard let call = activeElicitationCall(runtimeID: runtimeID),
              let stdio = transport as? MCPStdioTransport,
              stdio.elicitationParentRequestID(ownerID: runtimeID) == call.requestID else {
            return MCPJSONRPCResponse(id: request.id, result: MCPElicitationResult(action: .decline).json)
        }
        guard claimElicitationRequest(request.id, parentID: call.requestID) else {
            return MCPJSONRPCResponse(id: request.id, result: MCPElicitationResult(action: .decline).json)
        }
        defer { releaseElicitationRequest(request.id) }
        do {
            let form = try MCPElicitationForm(params: request.params)
            stdio.pauseToolTimeout(call.requestID, ownerID: runtimeID)
            defer { stdio.resumeToolTimeout(call.requestID, ownerID: runtimeID) }
            let context = MCPElicitationContext(serverID: server.id, serverName: server.name,
                requestID: request.id, runtimeID: runtimeID, invocation: call.invocation, oneShotID: UUID())
            let result = try await call.handler(context, form)
            try Task.checkCancellation()
            guard activeElicitationCall(runtimeID: context.runtimeID)?.requestID == call.requestID else { throw CancellationError() }
            try form.validate(result)
            if result.action == .cancel {
                // Write action:cancel before settling the original tools/call.
                // The incoming request's owner fence is checked by respond().
                try stdio.cancelToolForElicitation(call.requestID,
                    response: MCPJSONRPCResponse(id: context.requestID, result: result.json), ownerID: context.runtimeID)
                throw CancellationError()
            }
            return MCPJSONRPCResponse(id: context.requestID, result: result.json)
        } catch is CancellationError {
            return MCPJSONRPCResponse(id: request.id, result: MCPElicitationResult(action: .cancel).json)
        } catch {
            return MCPJSONRPCResponse(id: request.id, error: .init(code: -32602, message: "Unsupported schema or invalid MCP form response"))
        }
    }

    /// Tear down the transport. Safe to call multiple times.
    public func disconnect() {
        let generation = invalidateLifecycle(.disconnected)
        transport.stop()
        setState(.disconnected, generation: generation)
    }

    /// Retire the previous owner before starting a fresh stdio process.  This
    /// is the supported recovery path after cancellation, EOF, or crash.
    public func reconnect() async throws {
        disconnect()
        try await connect()
    }

    /// Recover a disconnected/failed runtime by retiring its previous owner
    /// and completing a fresh handshake.  The operation is intentionally
    /// explicit so a caller can distinguish recovery from an ordinary call.
    public func recover() async throws {
        try await reconnect()
    }

    /// Roll back the client to a disconnected terminal state.  This is the
    /// fail-closed path for a rejected recovery decision or unsafe result.
    public func rollback() {
        disconnect()
    }

    public var isConnected: Bool {
        readConnected() && transport.isReady
    }

    public var connectionState: MCPClientState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    /// Stable replacement-session state for settings and diagnostics.
    public var lifecycleSnapshot: MCPClientLifecycleSnapshot {
        stateLock.lock()
        let snapshot = MCPClientLifecycleSnapshot(
            state: state,
            generation: lifecycleGeneration,
            replacementSessionID: replacementSessionID,
            runtime: nil
        )
        stateLock.unlock()
        let runtime: MCPTransportSnapshot?
        if let stdio = transport as? MCPStdioTransport {
            runtime = stdio.runtimeSnapshot()
        } else {
            runtime = nil
        }
        return MCPClientLifecycleSnapshot(
            state: snapshot.state,
            generation: snapshot.generation,
            replacementSessionID: snapshot.replacementSessionID,
            runtime: runtime
        )
    }

    // MARK: - Helpers

    // NSLock 的 lock/unlock 在 Swift 6 中不可直接从 async 上下文调用，
    // 统一走同步辅助函数。

    private func readConnected() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected
    }

    private func invalidateLifecycle(_ nextState: MCPClientState) -> UInt64 {
        stateLock.lock()
        let attempt = connectionAttempt
        connectionAttempt = nil
        lifecycleGeneration &+= 1
        connected = false
        connectedRuntimeID = nil
        state = nextState
        let generation = lifecycleGeneration
        stateLock.unlock()
        attempt?.cancel()
        return generation
    }

    private func lifecycleGenerationMatches(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleGeneration == generation
    }

    private func connectedLifecycleGeneration() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard connected else { return nil }
        return lifecycleGeneration
    }

    private var replacementSessionID: String {
        "\(server.id):\(server.descriptorFingerprint)"
    }

    private func setConnected(_ value: Bool, generation: UInt64) {
        let runtimeID = (transport as? MCPStdioTransport)?.runtimeSnapshot().ownerID
        stateLock.lock()
        guard lifecycleGeneration == generation else {
            stateLock.unlock()
            return
        }
        connected = value
        connectedRuntimeID = value ? runtimeID : nil
        state = value ? .connected : .disconnected
        stateLock.unlock()
        publishRuntimeChange()
    }

    /// Optional diagnostic consumer for the existing failed-state publication.
    /// Normal clients leave this nil; observation cannot change connection state.
    func setDiagnosticFailureObserver(_ observer: (@Sendable (MCPClientLifecycleSnapshot) -> Void)?) {
        stateLock.lock()
        diagnosticFailureObserver = observer
        stateLock.unlock()
    }

    private func setState(_ value: MCPClientState, generation: UInt64? = nil) {
        stateLock.lock()
        if let generation, lifecycleGeneration != generation {
            stateLock.unlock()
            return
        }
        state = value
        connected = value == .connected
        let observer: (@Sendable (MCPClientLifecycleSnapshot) -> Void)?
        if case .failed = value { observer = diagnosticFailureObserver } else { observer = nil }
        let snapshot = observer.map { _ in
            MCPClientLifecycleSnapshot(state: state, generation: lifecycleGeneration,
                replacementSessionID: replacementSessionID, runtime: nil)
        }
        stateLock.unlock()
        publishRuntimeChange()
        if let observer, let snapshot {
            let runtime = (transport as? MCPStdioTransport)?.runtimeSnapshot()
            observer(MCPClientLifecycleSnapshot(state: snapshot.state, generation: snapshot.generation,
                replacementSessionID: snapshot.replacementSessionID, runtime: runtime))
        }
    }

    private static func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "MCP 连接失败，请检查服务器配置后重试"
    }

    private func nextID() -> MCPID {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextRequestID
        nextRequestID += 1
        return .int(id)
    }

    private static func isJSONRepresentable(_ value: Any, depth: Int) -> Bool {
        guard depth <= maxCallArgumentJSONDepth else { return false }
        switch value {
        case let value as MCPJSONValue:
            return isJSONValueRepresentable(value, depth: depth)
        case _ as NSNull, _ as Bool, _ as Int, _ as String:
            return true
        case let value as Double:
            return value.isFinite
        case let values as [Any]:
            return values.allSatisfy { Self.isJSONRepresentable($0, depth: depth + 1) }
        case let values as [String: Any]:
            return values.values.allSatisfy { Self.isJSONRepresentable($0, depth: depth + 1) }
        default:
            return false
        }
    }

    private static func isJSONValueRepresentable(_ value: MCPJSONValue, depth: Int) -> Bool {
        guard depth <= maxCallArgumentJSONDepth else { return false }
        switch value {
        case .null, .bool, .string:
            return true
        case .number(let number):
            return number.isFinite
        case .array(let values):
            return values.allSatisfy { isJSONValueRepresentable($0, depth: depth + 1) }
        case .object(let values):
            return values.values.allSatisfy { isJSONValueRepresentable($0, depth: depth + 1) }
        }
    }

    private func ensureConnected() async throws -> UInt64 {
        if !isConnected {
            try await connect()
        }
        guard let generation = connectedLifecycleGeneration(), transport.isReady else {
            throw MCPClientError.transportNotStarted
        }
        return generation
    }

    private func validate(
        _ response: MCPJSONRPCResponse,
        for request: MCPJSONRPCRequest,
        generation: UInt64
    ) throws {
        try Task.checkCancellation()
        guard lifecycleGenerationMatches(generation), transport.isReady else {
            throw MCPClientError.processExited(-1)
        }
        guard response.matches(request: request) else {
            throw MCPClientError.badResponse("JSON-RPC response id mismatch")
        }
        guard response.jsonrpc == "2.0" else {
            throw MCPClientError.badResponse("unsupported JSON-RPC version")
        }
        guard (response.result != nil) != (response.error != nil) else {
            throw MCPClientError.badResponse("JSON-RPC response must contain exactly one of result or error")
        }
    }
}

// MARK: - STDIO Transport

/// Spawns `command args…` and speaks newline-delimited JSON-RPC over its
/// stdin/stdout (the MCP stdio transport spec). Server stderr is drained to
/// /dev/null (TODO: surface for debugging).
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {

    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let timeoutSeconds: Int

    private let lock = NSLock()
    // Whole JSON lines share one deadline-bounded writer gate, never the state lock.
    private let writeGate = DispatchSemaphore(value: 1)
    // A timed-out partial line must never be joined to a later JSON message.
    private var failedWriteOwner: UUID?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var pending: [MCPID: PendingRequest] = [:]
    private var inboundTasks: [MCPID: (token: UUID, task: Task<Void, Never>?)] = [:]
    /// Stdio 2025-11-25 has no on-wire parent request id for elicitation.
    /// Once calls overlap, even a later singleton may receive a delayed form
    /// from the other call. Remain non-interactive until this runtime retires.
    private var ambiguousToolAssociation = false
    private var seenInboundIDs: Set<MCPID> = []
    private var exitedHandler: (@Sendable (UUID) -> Void)?
    private var inboundRequestHandler: (@Sendable (MCPJSONRPCRequest, UUID) async -> MCPJSONRPCResponse)?
    private var inboundNotificationHandler: (@Sendable (MCPJSONRPCNotification, UUID) -> Void)?
    private var started = false
    private var starting = false
    private var processGroupID: pid_t?
    private var ownerID: UUID?
    private var generation: UInt64 = 0
    private var lifecycle: MCPTransportState = .idle
    private var stopRequestedWhileStarting = false
    /// P2-6：stop() 置位的终止标志。notify 在锁内检查它——一旦 stop 过，
    /// 即使句柄尚未完全清理完也直接短路抛 transportNotStarted，不再写 stdin。
    private var stopped = false
    private let invalid: Bool

    private static let naturalExitGracePeriod: TimeInterval = 0.25
    private static let terminateGracePeriod: TimeInterval = 0.25
    private static let forceKillGracePeriod: TimeInterval = 0.25

    public init(command: String, args: [String], env: [String: String], timeoutSeconds: Int = 60, invalid: Bool = false) {
        self.command = command
        self.args = args
        self.env = env
        self.timeoutSeconds = timeoutSeconds
        self.invalid = invalid
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !stopped && failedWriteOwner != ownerID && process?.isRunning == true
    }

    public func runtimeSnapshot() -> MCPTransportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MCPTransportSnapshot(
            state: lifecycle,
            ownerID: ownerID,
            generation: generation,
            processIdentifier: process?.processIdentifier
        )
    }

    /// Return whether output tagged with `identity` belongs to this live
    /// runtime.  This is the consumer-facing late/duplicate-result fence.
    public func accepts(_ identity: MCPRuntimeIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !stopped && lifecycle == .running
            && process?.isRunning == true
            && ownerID == identity.ownerID
            && generation == identity.generation
    }

    /// Fail-closed rollback for the current stdio runtime.  It retires the
    /// owner, drains pending requests, and leaves no process eligible for
    /// late output.
    @discardableResult
    public func rollbackRuntime() -> MCPTransportSnapshot {
        stop()
        return runtimeSnapshot()
    }

    public func start() async throws {
        try MCPRuntimeLimits.validate(timeoutSeconds: timeoutSeconds)
        let launchOwner = UUID()
        if try beginStart() { return }

        if invalid {
            markStartFailure("no command configured for stdio server")
            throw MCPClientError.invalidServer("no command configured for stdio server")
        }

        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
        } else {
            // Bare name (e.g. "npx") → resolve via PATH through /usr/bin/env.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        if command.contains("/") {
            process.arguments = args
        }
        // Only this server's explicit configuration augments the shared safe
        // baseline. Never import provider credentials from the App environment.
        do {
            process.environment = try ChildProcessEnvironment.mcpValues(configured: env)
        } catch {
            markStartFailure("隔离运行环境无效")
            throw error
        }

        let outPipe = Pipe()
        let inPipe = Pipe()
        // A peer may close stdin during a write. Convert that broken pipe into
        // EPIPE rather than terminating the process with SIGPIPE.
        guard Darwin.fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            let error = Self.writeSystemError("F_SETNOSIGPIPE", code: errno)
            markStartFailure("配置 MCP 写管道失败")
            throw error
        }
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = FileHandle.nullDevice
        // Reuse the frozen stdio exit contract: a descendant can keep stdout
        // open after the root exits, so EOF is not the root's terminal signal.
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.handleProcessExit(ownerID: launchOwner, process: terminatedProcess)
        }

        do {
            try process.run()
        } catch {
            markStartFailure("启动 MCP 服务器失败")
            throw MCPClientError.spawnFailed("\(command): \(error.localizedDescription)")
        }

        let stdin = inPipe.fileHandleForWriting
        let stdout = outPipe.fileHandleForReading
        let pid = process.processIdentifier
        // Foundation may already have created the child's private group before
        // run() returns. A repeated setpgid can fail after exec; admit only the
        // actual private group, never an inherited/shared process group.
        if pid > 0 { _ = Darwin.setpgid(pid, pid) }
        let privateProcessGroupID = pid > 0 && Darwin.getpgid(pid) == pid ? pid : nil

        let shouldStopImmediately = installHandles(
            process: process,
            stdin: stdin,
            stdout: stdout,
            processGroupID: privateProcessGroupID,
            ownerID: launchOwner
        )

        if shouldStopImmediately {
            Self.terminate(process, processGroupID: privateProcessGroupID)
            throw MCPClientError.transportNotStarted
        }

        startReadLoop(process: process, stdout: stdout, ownerID: launchOwner)
        // A very short-lived child may finish before installHandles admits its
        // owner. Reconcile that exit now instead of leaving a running owner.
        if !process.isRunning {
            handleProcessExit(ownerID: launchOwner, process: process)
        }
    }

    // MARK: Lock helpers (NSLock 不可从 async 上下文直接调用)

    /// Keep lock operations inside synchronous helpers. Swift 6 rejects
    /// directly calling NSLock.lock/unlock from an async context because the
    /// lock may suspend the task's executor.
    private func beginStart() throws -> Bool {
        lock.lock()
        if started, process?.isRunning == true {
            let failed = failedWriteOwner == ownerID
            lock.unlock()
            if failed { throw MCPClientError.transportNotStarted }
            return true
        }
        if starting {
            lock.unlock()
            throw MCPClientError.transportNotStarted
        }
        starting = true
        stopRequestedWhileStarting = false
        lifecycle = .starting
        generation &+= 1
        lock.unlock()
        return false
    }

    private func markStartFailure(_ message: String) {
        lock.lock()
        starting = false
        lifecycle = .failed(message)
        lock.unlock()
    }

    private func installHandles(
        process: Process,
        stdin: FileHandle,
        stdout: FileHandle,
        processGroupID: pid_t?,
        ownerID: UUID
    ) -> Bool {
        lock.lock()
        if stopRequestedWhileStarting {
            starting = false
            stopped = true
            lifecycle = .stopped
            lock.unlock()
            return true
        }
        self.process = process
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.processGroupID = processGroupID
        self.ownerID = ownerID
        failedWriteOwner = nil
        seenInboundIDs.removeAll()
        ambiguousToolAssociation = false
        started = true
        starting = false
        stopped = false
        lifecycle = .running
        lock.unlock()
        return false
    }

    public func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try MCPRuntimeLimits.validate(timeoutSeconds: timeoutSeconds)
        let id = request.id
        let line = try request.encodeLine()
        try MCPRuntimeLimits.validateOutboundPayloadBytes(line.utf8.count)
        let bytes = Data((line + "\n").utf8)
        let cancellation = PendingRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard started, !stopped, let ownerID, let stdin = stdinHandle, process?.isRunning == true else {
                    lock.unlock()
                    continuation.resume(throwing: MCPClientError.transportNotStarted)
                    return
                }
                guard pending[id] == nil else {
                    lock.unlock()
                    continuation.resume(throwing: MCPClientError.badResponse("duplicate pending request id"))
                    return
                }
                let pendingRequest = PendingRequest(id: id, method: request.method, ownerID: ownerID, continuation: continuation)
                guard cancellation.install(pendingRequest) else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = writeDeadline()
                if request.method == "tools/call", pending.values.contains(where: { $0.method == "tools/call" }) {
                    ambiguousToolAssociation = true
                }
                pending[id] = pendingRequest
                // The timeout starts before any writer-gate wait or pipe I/O.
                pendingRequest.startTimer(seconds: TimeInterval(timeoutSeconds)) { [weak self] in
                    self?.failPending(pendingRequest, error: MCPClientError.timeout("\(request.method) after \(self?.timeoutSeconds ?? 60)s"))
                }
                let fd: Int32
                do {
                    fd = try Self.duplicateWriteFD(stdin)
                } catch {
                    pending.removeValue(forKey: id)
                    pendingRequest.timer?.cancel()
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                lock.unlock()
                do {
                    try writeLine(bytes, fd: fd, ownerID: ownerID, pendingRequest: pendingRequest,
                                  deadline: deadline, method: request.method)
                } catch {
                    // A timeout/cancellation/stop may already have settled this
                    // exact request. Never settle a later request reusing its id.
                    failPending(pendingRequest, error: error)
                }
            }
        }, onCancel: { [weak self] in
            cancellation.cancel { pendingRequest in
                self?.cancelPending(pendingRequest)
            }
        })
    }

    public func setInboundHandlers(
        request: (@Sendable (MCPJSONRPCRequest, UUID) async -> MCPJSONRPCResponse)?,
        notification: (@Sendable (MCPJSONRPCNotification, UUID) -> Void)?,
        exited: (@Sendable (UUID) -> Void)? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        inboundRequestHandler = request
        inboundNotificationHandler = notification
        exitedHandler = exited
    }
    public func cancelInboundRequests() {
        lock.lock()
        let tasks = inboundTasks.values.compactMap(\.task)
        inboundTasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
    /// Uses the existing pending table, not an inferred tool name or a second
    /// call ledger. Ambiguous streams explicitly decline every new form.
    func elicitationParentRequestID(ownerID: UUID) -> MCPID? {
        lock.lock(); defer { lock.unlock() }
        guard self.ownerID == ownerID, !ambiguousToolAssociation else { return nil }
        let tools = pending.values.filter { $0.ownerID == ownerID && $0.method == "tools/call" }
        return tools.count == 1 ? tools.first?.id : nil
    }
    public func pauseToolTimeout(_ id: MCPID, ownerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.ownerID == ownerID, let request = pending[id] else { return }
        request.timer?.cancel()
        request.timer = nil
    }
    public func resumeToolTimeout(_ id: MCPID, ownerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.ownerID == ownerID, let request = pending[id] else { return }
        request.startTimer(seconds: TimeInterval(timeoutSeconds)) { [weak self, weak request] in
            guard let request else { return }
            self?.failPending(request, error: MCPClientError.timeout("MCP tool response timed out"))
        }
    }
    /// Claim both halves before writing: a fast server response racing the
    /// cancel action must not win the original tool's terminal continuation.
    public func cancelToolForElicitation(_ id: MCPID, response: MCPJSONRPCResponse, ownerID: UUID) throws {
        lock.lock()
        guard self.ownerID == ownerID, let responseID = response.id,
              inboundTasks[responseID] != nil, let request = pending.removeValue(forKey: id) else {
            lock.unlock(); throw MCPClientError.transportNotStarted
        }
        inboundTasks.removeValue(forKey: responseID)
        lock.unlock()
        request.timer?.cancel()
        defer { request.continuation.resume(throwing: MCPElicitationUserCancelled()) }
        try respond(response, ownerID: ownerID)
        try writeNotification(MCPJSONRPCNotification(method: "notifications/cancelled",
            params: .object(["requestId": id.jsonValue, "reason": .string("User cancelled")])),
            expectedOwnerID: ownerID)
    }
    public func respond(_ response: MCPJSONRPCResponse, ownerID expected: UUID) throws {
        let line = try MCPMessage.response(response).encodeLine()
        try MCPRuntimeLimits.validateOutboundPayloadBytes(line.utf8.count)
        lock.lock()
        guard ownerID == expected, started, !stopped, let stdin = stdinHandle else {
            lock.unlock(); throw MCPClientError.transportNotStarted
        }
        let fd: Int32
        do { fd = try Self.duplicateWriteFD(stdin) } catch { lock.unlock(); throw error }
        let deadline = writeDeadline()
        lock.unlock()
        try writeLine(Data((line + "\n").utf8), fd: fd, ownerID: expected,
            pendingRequest: nil, deadline: deadline, method: "elicitation response")
    }
    private func handleInbound(_ message: MCPMessage, ownerID: UUID, process: Process) {
        lock.lock()
        guard self.ownerID == ownerID, self.process === process, started, !stopped else { lock.unlock(); return }
        switch message {
        case .notification(let notification):
            let callback = inboundNotificationHandler
            var cancelled: Task<Void, Never>?
            if notification.method == "notifications/cancelled", case .object(let params)? = notification.params,
               let value = params["requestId"], let id = MCPID(jsonValue: value) {
                cancelled = inboundTasks.removeValue(forKey: id)?.task
            }
            lock.unlock()
            cancelled?.cancel()
            callback?(notification, ownerID)
        case .request(let request):
            guard seenInboundIDs.count < 1_024, !seenInboundIDs.contains(request.id), inboundTasks.count < 16 else {
                lock.unlock()
                // Reject the active calls and their pending forms; never
                // send a second response for an already claimed server id.
                failPendingForOwner(ownerID: ownerID, error: .invalidMessage("MCP incoming request id reused or capacity exceeded"))
                return
            }
            seenInboundIDs.insert(request.id)
            let token = UUID()
            inboundTasks[request.id] = (token, nil)
            let handler = inboundRequestHandler
            lock.unlock()
            let task = Task { [weak self] in
                let response = await handler?(request, ownerID) ?? MCPJSONRPCResponse(id: request.id, error: .init(code: -32601, message: "Unsupported client method"))
                guard !Task.isCancelled, let self, self.finishInbound(id: request.id, token: token, ownerID: ownerID) else { return }
                do { try self.respond(response, ownerID: ownerID) }
                catch { self.failPendingForOwner(ownerID: ownerID, error: .invalidMessage("MCP client response write failed")) }
            }
            installInbound(task, id: request.id, token: token)
        case .response: lock.unlock()
        }
    }
    private func installInbound(_ task: Task<Void, Never>, id: MCPID, token: UUID) {
        lock.lock()
        if inboundTasks[id]?.token == token { inboundTasks[id]?.task = task; lock.unlock() }
        else { lock.unlock(); task.cancel() }
    }
    private func finishInbound(id: MCPID, token: UUID, ownerID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.ownerID == ownerID, inboundTasks[id]?.token == token else { return false }
        inboundTasks.removeValue(forKey: id)
        return true
    }

    public func stop() {
        lock.lock()
        if starting {
            stopRequestedWhileStarting = true
            lifecycle = .stopping
            lock.unlock()
            return
        }
        // Retire the owner and detach the original handles under the state
        // lock. Writers own dup fds, so closing the original outside this lock
        // cannot cause a cross-thread FileHandle close/write exception.
        let proc = process
        let groupID = processGroupID
        self.ownerID = nil
        process = nil
        processGroupID = nil
        started = false
        stopped = true
        let pendingNow = pending
        pending = [:]
        let stdinToClose = stdinHandle
        stdinHandle = nil
        stdoutHandle = nil
        lifecycle = .stopped
        lock.unlock()

        cancelInboundRequests()
        for (_, req) in pendingNow {
            req.timer?.cancel()
            req.continuation.resume(throwing: MCPClientError.processExited(-1))
        }
        // Closing stdin gives a cooperative server a bounded chance to exit.
        try? stdinToClose?.close()
        // ⚠️ 不要在这里 close stdout：startReadLoop 可能正阻塞在
        // stdout.bytes 的读取上，跨线程 close 会让读循环抛
        // NSFileHandleOperationException（ObjC 异常，Swift 无法捕获，
        // 直接 SIGABRT）。终止进程后管道写端关闭 → 读循环拿到 EOF
        // 退出 → FileHandle 随闭包 ARC 释放，fd 安全关闭。
        if let proc {
            Self.terminate(proc, processGroupID: groupID)
        }
    }

    public func notify(_ notification: MCPJSONRPCNotification) throws {
        try writeNotification(notification, expectedOwnerID: nil)
    }
    private func writeNotification(_ notification: MCPJSONRPCNotification, expectedOwnerID: UUID?) throws {
        try MCPRuntimeLimits.validate(timeoutSeconds: timeoutSeconds)
        let line = try MCPMessage.notification(notification).encodeLine()
        try MCPRuntimeLimits.validateOutboundPayloadBytes(line.utf8.count)
        let bytes = Data((line + "\n").utf8)
        lock.lock()
        guard started, !stopped, let ownerID, expectedOwnerID == nil || ownerID == expectedOwnerID,
              let stdin = stdinHandle, process?.isRunning == true else {
            lock.unlock()
            throw MCPClientError.transportNotStarted
        }
        let deadline = writeDeadline()
        let fd: Int32
        do {
            fd = try Self.duplicateWriteFD(stdin)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        do {
            try writeLine(bytes, fd: fd, ownerID: ownerID, pendingRequest: nil,
                          deadline: deadline, method: notification.method)
        } catch {
            // A stop racing an in-flight dup write still has the original
            // public notify outcome; the dup avoids a FileHandle exception.
            lock.lock()
            let retired = !started || stopped || self.ownerID != ownerID
            lock.unlock()
            if retired { throw MCPClientError.transportNotStarted }
            throw error
        }
    }

    private func writeDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000
    }

    /// Called only while the state lock still owns the original FileHandle.
    /// stop() can later close that original without touching this writer's fd.
    private static func duplicateWriteFD(_ handle: FileHandle) throws -> Int32 {
        let fd = Darwin.fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw writeSystemError("dup stdin", code: errno) }
        guard Darwin.fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
            let error = writeSystemError("dup F_SETNOSIGPIPE", code: errno)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func writeSystemError(_ operation: String, code: Int32) -> MCPClientError {
        let description = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
        return .spawnFailed("stdin \(operation) failed: \(description)")
    }

    private func checkWriteOwner(_ ownerID: UUID, pendingRequest: PendingRequest?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped, self.ownerID == ownerID else {
            throw MCPClientError.transportNotStarted
        }
        guard failedWriteOwner != ownerID else {
            throw MCPClientError.spawnFailed("stdin stream contains an incomplete JSON message; stop before restarting")
        }
        if let pendingRequest, pending[pendingRequest.id] !== pendingRequest {
            throw MCPClientError.transportNotStarted
        }
    }

    private func markIncompleteWrite(_ ownerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.ownerID == ownerID, started, !stopped else { return }
        failedWriteOwner = ownerID
        lifecycle = .failed("MCP stdin JSON message was only partially written")
    }

    /// The writer owns fd on every path. O_NONBLOCK affects the shared pipe
    /// open-file description too; both send/notify exclusively use this path.
    private func writeLine(_ bytes: Data, fd: Int32, ownerID: UUID,
                           pendingRequest: PendingRequest?, deadline: UInt64, method: String) throws {
        defer { Darwin.close(fd) }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags != -1, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw Self.writeSystemError("O_NONBLOCK", code: errno)
        }
        let timeout = MCPClientError.timeout("\(method) after \(timeoutSeconds)s")
        while true {
            try checkWriteOwner(ownerID, pendingRequest: pendingRequest)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw timeout }
            let slice = min(deadline, now + 25_000_000)
            if writeGate.wait(timeout: DispatchTime(uptimeNanoseconds: slice)) == .success { break }
        }
        defer { writeGate.signal() }
        var offset = 0
        do {
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                while offset < buffer.count {
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { throw timeout }
                    try checkWriteOwner(ownerID, pendingRequest: pendingRequest)
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count == 0 { throw Self.writeSystemError("zero-byte write", code: EIO) }
                    let code = errno
                    if code == EINTR { continue }
                    guard code == EAGAIN || code == EWOULDBLOCK else {
                        throw Self.writeSystemError("write", code: code)
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { throw timeout }
                    // Short bounded poll slices observe cancellation/retirement;
                    // they never create a new timeout budget.
                    let milliseconds = Int32(min(25, max(1, (deadline - now + 999_999) / 1_000_000)))
                    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = Darwin.poll(&event, 1, milliseconds)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw Self.writeSystemError("poll", code: errno)
                    }
                    if event.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        throw Self.writeSystemError("pipe closed", code: EPIPE)
                    }
                }
            }
        } catch {
            if offset > 0 && offset < bytes.count { markIncompleteWrite(ownerID) }
            throw error
        }
    }

    // MARK: - Internals

    private final class PendingRequest: @unchecked Sendable {
        let id: MCPID
        let method: String
        let ownerID: UUID
        let continuation: CheckedContinuation<MCPJSONRPCResponse, Error>
        var timer: Task<Void, Never>?

        init(id: MCPID, method: String, ownerID: UUID, continuation: CheckedContinuation<MCPJSONRPCResponse, Error>) {
            self.id = id
            self.method = method
            self.ownerID = ownerID
            self.continuation = continuation
        }

        func startTimer(seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
            timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                onTimeout()
            }
        }
    }

    /// Associates cancellation with the exact continuation it created. A
    /// request id is not sufficient here: a caller can submit the same id
    /// twice, and cancelling the later call must never settle the earlier one.
    private final class PendingRequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var request: PendingRequest?
        private var cancelled = false

        func install(_ request: PendingRequest) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.request = request
            return true
        }

        func cancel(_ handler: (PendingRequest) -> Void) {
            lock.lock()
            cancelled = true
            let request = self.request
            self.request = nil
            lock.unlock()
            if let request {
                handler(request)
            }
        }
    }

    private func startReadLoop(process: Process, stdout: FileHandle, ownerID: UUID) {
        lock.lock()
        guard self.ownerID == ownerID, started, self.process === process else {
            lock.unlock()
            return
        }
        defer { lock.unlock() }
        // Use an independent runtime-owned reader instead of the asynchronous
        // FileHandle byte sequence, so peer progress does not depend on that
        // sequence's scheduling while another server's stdout is idle.
        // Keep the handle alive here; stop terminates the owned process group
        // to produce EOF instead of closing a handle underneath a blocked read.
        // A retired owner's delayed EOF must not queue-block a restarted owner.
        let readQueue = DispatchQueue(label: "com.miniscanvas.mcp.stdio.reader.\(ownerID.uuidString)")
        readQueue.async { [weak self] in
            var buffered = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            do {
                while true {
                    let isCurrent: Bool = {
                        guard let transport = self else { return false }
                        transport.lock.lock()
                        defer { transport.lock.unlock() }
                        return transport.ownerID == ownerID && transport.started
                            && transport.process === process
                    }()
                    guard isCurrent else { return }
                    // A line protocol needs each available short read, not a
                    // Foundation read that may wait for the requested count.
                    let count = bytes.withUnsafeMutableBytes {
                        Darwin.read(stdout.fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    }
                    if count == 0 { break }
                    buffered.append(contentsOf: bytes.prefix(count))
                    while let newline = buffered.firstIndex(of: 0x0A) {
                        var line = buffered.subdata(in: buffered.startIndex..<newline)
                        buffered.removeSubrange(buffered.startIndex...newline)
                        if line.last == 0x0D { line.removeLast() }
                        guard !line.isEmpty else { continue }
                        self?.handleIncomingLine(String(decoding: line, as: UTF8.self),
                                                 ownerID: ownerID, process: process)
                    }
                }
                if !buffered.isEmpty {
                    self?.handleIncomingLine(String(decoding: buffered, as: UTF8.self),
                                             ownerID: ownerID, process: process)
                }
            } catch {
                // Pipe closed / read failed — preserve the original exit path.
            }
            self?.handleProcessExit(ownerID: ownerID, process: process)
        }
    }

    private func handleIncomingLine(_ line: String, ownerID: UUID, process: Process) {
        guard let message = try? MCPMessage.decodeLine(line) else {
            failPendingForOwner(
                ownerID: ownerID,
                error: MCPClientError.badResponse("malformed MCP response")
            )
            return
        }
        guard case .response(let response) = message, let id = response.id else {
            handleInbound(message, ownerID: ownerID, process: process)
            return
        }
        lock.lock()
        guard self.ownerID == ownerID, self.process === process,
              let pendingRequest = pending[id], pendingRequest.ownerID == ownerID else {
            lock.unlock()
            return
        }
        pending.removeValue(forKey: id)
        lock.unlock()
        pendingRequest.timer?.cancel()
        if let rpcError = response.error {
            pendingRequest.continuation.resume(throwing: MCPClientError.rpcError(code: rpcError.code, message: rpcError.message))
        } else {
            pendingRequest.continuation.resume(returning: response)
        }
    }

    private func failPendingForOwner(ownerID: UUID, error: MCPClientError) {
        lock.lock()
        guard self.ownerID == ownerID else { lock.unlock(); return }
        let pendingNow = pending.values.filter { $0.ownerID == ownerID }
        let inbound = inboundTasks.values.compactMap(\.task)
        inboundTasks.removeAll()
        for request in pendingNow {
            pending.removeValue(forKey: request.id)
        }
        lock.unlock()
        inbound.forEach { $0.cancel() }
        for request in pendingNow {
            request.timer?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func handleProcessExit(ownerID: UUID, process expectedProcess: Process) {
        lock.lock()
        guard self.ownerID == ownerID, process === expectedProcess else {
            lock.unlock()
            return
        }
        let proc = expectedProcess
        // stdout EOF is not proof that the child process has exited: a
        // descendant may still hold the pipe open (or the fixture may
        // intentionally close stdout while continuing to run). Retain the
        // live Process and process group while stop() takes ownership of
        // pending requests and performs the bounded teardown. Natural exit
        // clears ownership and publishes its termination status directly.
        if proc.isRunning {
            lock.unlock()
            stop()
            return
        }
        let pendingNow = pending
        let groupID = processGroupID
        process = nil
        processGroupID = nil
        self.ownerID = nil
        stdinHandle = nil
        stdoutHandle = nil
        pending = [:]
        started = false
        lifecycle = .failed(Self.userFacingTermination(of: proc))
        stopped = true
        let exited = exitedHandler
        lock.unlock()
        exited?(ownerID)
        if let groupID {
            // Root exit does not retire descendants holding inherited pipes.
            Self.retirePrivateGroup(proc, processGroupID: groupID)
        }
        cancelInboundRequests()
        for (_, req) in pendingNow {
            req.timer?.cancel()
            req.continuation.resume(throwing: MCPClientError.processExited(Self.terminationStatus(of: proc)))
        }
    }

    private func failPending(_ pendingRequest: PendingRequest, error: Error) {
        lock.lock()
        guard self.ownerID == pendingRequest.ownerID,
              pending[pendingRequest.id] === pendingRequest else {
            lock.unlock()
            return
        }
        pending.removeValue(forKey: pendingRequest.id)
        lock.unlock()
        pendingRequest.timer?.cancel()
        pendingRequest.continuation.resume(throwing: error)
    }

    private func cancelPending(_ pendingRequest: PendingRequest) {
        lock.lock()
        guard self.pending[pendingRequest.id] === pendingRequest,
              self.ownerID == pendingRequest.ownerID else {
            lock.unlock()
            return
        }
        pending.removeValue(forKey: pendingRequest.id)
        lock.unlock()
        pendingRequest.timer?.cancel()
        pendingRequest.continuation.resume(throwing: CancellationError())
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }

    private static func terminationStatus(of process: Process?) -> Int32 {
        guard let process, !process.isRunning else { return -1 }
        return process.terminationStatus
    }

    private static func userFacingTermination(of process: Process?) -> String {
        let code = terminationStatus(of: process)
        return code == 0
            ? "MCP 服务器已正常结束，可重新打开恢复"
            : "MCP 服务器意外结束（退出码 \(code)），可重试恢复"
    }

    private static func terminate(_ process: Process, processGroupID: pid_t?) {
        if !waitForExit(process, timeout: naturalExitGracePeriod) {
            signal(process, processGroupID: processGroupID, signal: SIGTERM)
            if !waitForExit(process, timeout: terminateGracePeriod) {
                signal(process, processGroupID: processGroupID, signal: SIGKILL)
                _ = waitForExit(process, timeout: forceKillGracePeriod)
            }
        }
        if let processGroupID {
            retirePrivateGroup(process, processGroupID: processGroupID)
        }
    }

    private static func retirePrivateGroup(_ process: Process, processGroupID: pid_t) {
        guard processGroupID > 0, processGroupID == process.processIdentifier,
              processGroupID != Darwin.getpgrp() else { return }
        // Preserve the original grace periods, but wait for the owned group
        // even when the root exited naturally before TERM was necessary.
        if !waitForGroupExit(processGroupID, timeout: 0) {
            signal(process, processGroupID: processGroupID, signal: SIGTERM)
            if !waitForGroupExit(processGroupID, timeout: terminateGracePeriod) {
                signal(process, processGroupID: processGroupID, signal: SIGKILL)
                _ = waitForGroupExit(processGroupID, timeout: forceKillGracePeriod)
            }
        }
    }

    private static func waitForGroupExit(_ group: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Darwin.kill(-group, 0) == 0 || errno == EPERM {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    private static func signal(
        _ process: Process,
        processGroupID: pid_t?,
        signal: Int32
    ) {
        let pid = process.processIdentifier
        let descendants = pid > 0 ? descendantPIDs(of: pid) : []
        if let processGroupID, processGroupID > 0 {
            _ = Darwin.kill(-processGroupID, signal)
        } else if pid > 0 {
            _ = Darwin.kill(pid, signal)
        } else if signal == SIGTERM, process.isRunning {
            process.terminate()
        }
        for descendant in descendants {
            _ = Darwin.kill(descendant, signal)
        }
    }

    private static func descendantPIDs(of root: pid_t) -> [pid_t] {
        var direct = [pid_t](repeating: 0, count: 64)
        let byteCount = Int32(direct.count * MemoryLayout<pid_t>.stride)
        let result = proc_listchildpids(root, &direct, byteCount)
        guard result > 0 else { return [] }
        let count = min(Int(result) / MemoryLayout<pid_t>.stride, direct.count)
        let children = direct.prefix(count).filter { $0 > 0 }
        return children + children.flatMap { descendantPIDs(of: $0) }
    }
}

// MARK: - HTTP Transport

/// POSTs JSON-RPC to an HTTP(S) endpoint.
/// Negotiates streamable HTTP first; only an initialization protocol rejection
/// enables the legacy SSE endpoint. Tool calls are never retried across transports.
public final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {

    public let url: URL
    public let headers: [String: String]
    public let timeoutSeconds: Int
    private let invalid: Bool
    private let session: URLSession
    private let oauthAuthorization: MCPOAuthHTTPAuthorization?
    private var legacy: MCPSSEConnection
    private let httpStateLock = NSLock()
    private var usesLegacy = false
    private var sessionID: String?
    private var negotiatedProtocolVersion: String?
    private var httpEpoch = UUID()

    public init(url: URL, headers: [String: String], timeoutSeconds: Int = 60, invalid: Bool = false, session: URLSession? = nil,
                oauth: MCPOAuthCoordinator? = nil, oauthServer: MCPServer? = nil) {
        self.url = url
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
        self.invalid = invalid
        if let oauth, let oauthServer, MCPOAuthCoordinator.isEligible(oauthServer), oauthServer.url == url.absoluteString {
            self.oauthAuthorization = MCPOAuthHTTPAuthorization(server: oauthServer, coordinator: oauth)
        } else { self.oauthAuthorization = nil }
        let transportSession = session ?? URLSession(configuration: .ephemeral, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
        self.session = transportSession
        self.legacy = MCPSSEConnection(url: url, headers: headers, timeoutSeconds: timeoutSeconds, session: transportSession, oauthAuthorization: oauthAuthorization)
    }

    public var isReady: Bool {
        httpStateLock.withLock { !usesLegacy || legacy.readiness.isReady }
    }

    public func start() async throws {
        try validateConfiguration()
    }

    private func validateConfiguration() throws {
        try MCPRuntimeLimits.validate(timeoutSeconds: timeoutSeconds)
        if invalid {
            throw MCPClientError.invalidServer("no url configured for http server")
        }
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            throw MCPClientError.invalidServer("http transport requires an http(s) URL")
        }
        guard url.user == nil, url.password == nil else {
            throw MCPClientError.invalidServer("http transport URL must not contain credentials")
        }
        guard url.fragment == nil else {
            throw MCPClientError.invalidServer("http transport URL must not contain a fragment")
        }
        guard headers.count <= MCPRuntimeLimits.maximumHTTPHeaderCount else {
            throw MCPClientError.invalidServer("http transport headers exceed count limit")
        }
        var headerBytes = 0
        for (name, value) in headers {
            guard name.utf8.count <= MCPRuntimeLimits.maximumHTTPHeaderNameBytes,
                  value.utf8.count <= MCPRuntimeLimits.maximumHTTPHeaderValueBytes else {
                throw MCPClientError.invalidServer("http transport headers exceed byte limit")
            }
            headerBytes += name.utf8.count + value.utf8.count
            guard headerBytes <= MCPRuntimeLimits.maximumHTTPHeaderBytes else {
                throw MCPClientError.invalidServer("http transport headers exceed byte limit")
            }
        }
        guard headers.keys.allSatisfy(Self.isValidHeaderName),
              headers.values.allSatisfy(Self.isValidHeaderValue) else {
            throw MCPClientError.invalidServer("http transport contains invalid headers")
        }
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122,
                 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 && scalar.value != 0x09) && scalar.value != 0x7F
        }
    }

    private func authorizedBytes(for input: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let request = try await oauthAuthorization?.prepare(input) ?? input
        let result = try await session.bytes(for: request)
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 401,
              let oauthAuthorization else { return result }
        try await oauthAuthorization.rejected(http, request: request)
        let retry = try await oauthAuthorization.prepare(input)
        let retried = try await session.bytes(for: retry)
        if let rejected = retried.1 as? HTTPURLResponse, rejected.statusCode == 401 {
            _ = try await oauthAuthorization.recordUnauthorized(rejected)
            throw MCPOAuthError.expired
        }
        return retried
    }

    public func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try validateConfiguration()
        let captured = httpStateLock.withLock { (usesLegacy, legacy, httpEpoch) }
        if captured.0 { return try await captured.1.send(request) }
        var urlRequest = httpRequest()
        urlRequest.httpBody = try JSONEncoder().encode(request)
        try MCPRuntimeLimits.validateOutboundPayloadBytes(urlRequest.httpBody?.count ?? 0)
        let (bytes, response) = try await authorizedBytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.badResponse("MCP endpoint returned no HTTP response")
        }
        // Only initialize is safe to negotiate. An auth/server failure or a
        // tools/call rejection must not execute that call a second time.
        if request.method == "initialize", [404, 405, 406, 415].contains(http.statusCode) {
            let current = httpStateLock.withLock {
                guard httpEpoch == captured.2 else { return false }
                usesLegacy = true
                return true
            }
            guard current else { throw MCPClientError.transportNotStarted }
            return try await captured.1.send(request)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPClientError.badResponse("HTTP \(http.statusCode)")
        }
        if request.method == "initialize", let identifier = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard !identifier.isEmpty, identifier.utf8.count <= 1024,
                  identifier.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
                throw MCPClientError.badResponse("MCP endpoint returned an invalid session identifier")
            }
            let current = httpStateLock.withLock {
                guard httpEpoch == captured.2 else { return false }
                sessionID = identifier
                return true
            }
            guard current else { throw MCPClientError.transportNotStarted }
        }
        if http.mimeType?.lowercased() == "text/event-stream" {
            var events = MCPSSEEventDecoder()
            var lines = MCPSSELineDecoder()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let line = try lines.append(byte),
                      let event = try events.append(line: line), event.name == "message" else { continue }
                // Notifications have no matching response id; keep reading.
                guard let value = try? MCPMessage.decodeResponseData(Data(event.data.utf8)), value.id == request.id else { continue }
                try rememberProtocolVersion(value, for: request, epoch: captured.2)
                return value
            }
            throw MCPClientError.badResponse("MCP event stream closed before the response")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < MCPSSEEventDecoder.maximumEventBytes else {
                throw MCPClientError.badResponse("MCP response exceeds byte limit")
            }
            data.append(byte)
        }
        let value = try MCPMessage.decodeResponseData(data)
        try rememberProtocolVersion(value, for: request, epoch: captured.2)
        return value
    }

    private func rememberProtocolVersion(_ response: MCPJSONRPCResponse, for request: MCPJSONRPCRequest, epoch: UUID) throws {
        guard request.method == "initialize", response.error == nil else { return }
        let version: String?
        if case .object(let result) = response.result, case .string(let value) = result["protocolVersion"] { version = value }
        else if case .object(let params) = request.params, case .string(let value) = params["protocolVersion"] { version = value }
        else { version = nil }
        guard let version else { return }
        guard !version.isEmpty, version.utf8.count <= 64,
              version.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw MCPClientError.badResponse("MCP endpoint returned an invalid protocol version")
        }
        let current = httpStateLock.withLock {
            guard httpEpoch == epoch else { return false }
            negotiatedProtocolVersion = version
            return true
        }
        guard current else { throw MCPClientError.transportNotStarted }
    }

    private func httpRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version = httpStateLock.withLock({ negotiatedProtocolVersion }) {
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let identifier = httpStateLock.withLock({ sessionID }) {
            request.setValue(identifier, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    public func stop() {
        let retired = httpStateLock.withLock {
            usesLegacy = false
            sessionID = nil
            negotiatedProtocolVersion = nil
            httpEpoch = UUID()
            let retired = legacy
            legacy = MCPSSEConnection(url: url, headers: headers, timeoutSeconds: timeoutSeconds, session: session, oauthAuthorization: oauthAuthorization)
            return retired
        }
        Task { await retired.stop() }
    }

    public func notify(_ notification: MCPJSONRPCNotification) throws {
        try validateConfiguration()
        let captured = httpStateLock.withLock { (usesLegacy, legacy) }
        if captured.0 {
            Task { try? await captured.1.notify(notification) }
            return
        }
        var request = httpRequest()
        request.httpBody = try JSONEncoder().encode(notification)
        try MCPRuntimeLimits.validateOutboundPayloadBytes(request.httpBody?.count ?? 0)
        let requestToSend = request
        Task {
            do {
                let authorized = try await oauthAuthorization?.prepare(requestToSend) ?? requestToSend
                let (_, response) = try await session.data(for: authorized)
                if let oauthAuthorization { _ = try await oauthAuthorization.recordUnauthorized(response) }
            } catch { /* Existing fire-and-forget notification semantics; no credential errors are logged. */ }
        }
    }
}
