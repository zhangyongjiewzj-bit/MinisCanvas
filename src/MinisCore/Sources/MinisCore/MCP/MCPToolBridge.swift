import Foundation

// MARK: - Tool Bridge

/// A tool bound to a concrete MCP server, exposed to the agent loop under a
/// flat, unique name: `mcp_<serverID>_<toolName>` (server/tool ids are
/// made ASCII-only and at most 64 characters).
public struct MCPBoundTool: Sendable, Equatable {
    public var fullName: String
    public var serverID: String
    public var tool: MCPTool

    public init(fullName: String, serverID: String, tool: MCPTool) {
        self.fullName = fullName
        self.serverID = serverID
        self.tool = tool
    }

    /// Build `mcp_<server>_<tool>` from a server id and tool name.
    ///
    /// 11/16：接口要求工具名匹配 `^[a-zA-Z0-9_-]{1,64}$`。非 ASCII 字符一律换成 `-`；
    /// 含非 ASCII 字符或总长超过 64 时，截断并追加 8 位短哈希（取自原始 serverID+toolName），
    /// 保证不同原名不会撞成同一个名字。名字到原工具的对应关系由注册表的正查表保存。
    public static func makeFullName(serverID: String, toolName: String) -> String {
        let full = "mcp_\(asciiToolID(serverID))_\(asciiToolID(toolName))"
        let lossy = !serverID.utf8.allSatisfy { $0 < 0x80 } || !toolName.utf8.allSatisfy { $0 < 0x80 }
        guard full.utf8.count > maxToolNameLength || lossy else { return full }
        var hash: UInt32 = 2_166_136_261
        for byte in (serverID + "\u{0}" + toolName).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let suffix = String(format: "%08x", hash)
        return String(full.prefix(maxToolNameLength - suffix.count - 1)) + "_" + suffix
    }

    private static let maxToolNameLength = 64

    private static func asciiToolID(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let ok = (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v) || v == 95 || v == 45
            return ok ? Character(scalar) : "-"
        })
    }

    /// Split a bridged full name back into (serverID, toolName). Returns nil
    /// for names that don't carry the `mcp_` prefix.
    ///
    /// ⚠️ AMBIGUOUS (P2-1): this is a lossy string reverse-parse. Server ids
    /// may legally contain underscores (`sanitizeToolId` preserves `_`), so
    /// `mcp_my_server_greet` splits into server="my", tool="server_greet" —
    /// the round-trip `makeFullName → parseFullName` is NOT injective.
    /// `MCPToolRegistry` therefore resolves names via its registration-time
    /// forward lookup table instead; use this static helper only as a
    /// best-effort fallback for names the registry doesn't know.
    public static func parseFullName(_ fullName: String) -> (serverID: String, toolName: String)? {
        let parts = fullName.split(separator: "_", maxSplits: 2)
        guard parts.count == 3, parts[0] == "mcp" else { return nil }
        // NOTE: ids were sanitized on the way in, so the mapping back to the
        // original id is lossy for names containing non-`[a-zA-Z0-9_-]`
        // characters — the registry resolves against its live server list.
        return (String(parts[1]), String(parts[2]))
    }
}

/// Explicit MCP execution grants. A tool declaration or description never
/// adds a name to this set; callers must construct the allowlist separately.
public struct MCPToolAuthorization: Codable, Sendable, Equatable {
    public let allowedFullNames: Set<String>
    public let serverID: String?
    public let descriptorFingerprint: String?
    public let serverAuthorized: Bool
    public var authorizedToolNames: Set<String>
    /// Persisted discovery-schema binding for manager-issued tool grants.
    /// nil is an unbound legacy grant (deny), "" is an explicit grant waiting
    /// for its first discovery, and a digest binds the granted names exactly.
    public var schemaBindingDigest: String?
    /// 每个已授权工具各自的定义摘要（工具名 -> 摘要）。服务器的工具列表变化时，
    /// 只撤销自己定义变了或已消失的工具；新增工具默认未授权，也不连累其它工具。
    /// nil 表示旧版授权（无逐工具摘要），摘要不一致时整体撤销。
    public var toolSchemaDigests: [String: String]?

    public init(
        allowedFullNames: Set<String> = [],
        serverID: String? = nil,
        descriptorFingerprint: String? = nil,
        serverAuthorized: Bool = false,
        authorizedToolNames: Set<String> = [],
        schemaBindingDigest: String? = nil,
        toolSchemaDigests: [String: String]? = nil
    ) {
        self.toolSchemaDigests = toolSchemaDigests
        self.allowedFullNames = allowedFullNames
        self.serverID = serverID
        self.descriptorFingerprint = descriptorFingerprint
        self.serverAuthorized = serverAuthorized
        self.authorizedToolNames = authorizedToolNames
        self.schemaBindingDigest = schemaBindingDigest
    }

    public static let denyAll = MCPToolAuthorization()

    public static func allowing(_ fullNames: [String]) -> MCPToolAuthorization {
        MCPToolAuthorization(allowedFullNames: Set(fullNames))
    }

    public func allows(_ fullName: String) -> Bool {
        allowedFullNames.contains(fullName)
    }

    /// Validate the full grant against the live server descriptor. A stale
    /// grant, a different server, or a tool outside the explicit tool set is
    /// denied even when a forged full name happens to match the static list.
    public func allows(
        fullName: String,
        serverID: String,
        toolName: String,
        descriptorFingerprint: String
    ) -> Bool {
        guard allows(fullName) else { return false }
        guard self.serverID == nil || self.serverID == serverID else { return false }
        guard self.descriptorFingerprint == nil || self.descriptorFingerprint == descriptorFingerprint else {
            return false
        }
        guard authorizedToolNames.isEmpty || authorizedToolNames.contains(toolName) else {
            return false
        }
        return true
    }
}

/// Stable identity supplied by the production caller for one logical MCP
/// invocation. The pair is never reusable: retries must mint a new attempt.
public struct MCPToolInvocationIdentity: Codable, Hashable, Sendable, Equatable {
    public let correlationID: String
    public let attemptID: String

    public init(correlationID: String, attemptID: String) {
        self.correlationID = correlationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool { !correlationID.isEmpty && !attemptID.isEmpty }
}

public typealias MCPInvocationIdentity = MCPToolInvocationIdentity

public enum MCPToolInvocationFenceError: Error, Equatable, Sendable {
    case invalidIdentity
    case duplicate(MCPToolInvocationIdentity)
    case capacityExhausted(MCPToolInvocationIdentity)
    case runtimeRetired(MCPToolInvocationIdentity)
}

extension MCPToolInvocationFenceError: LocalizedError {
    /// 模型收到的报错：只有"配置被改动、结果被丢弃"这一种需要说清楚，其余沿用系统默认文案。
    public var errorDescription: String? {
        guard case .runtimeRetired = self else { return nil }
        return "MCP 配置在调用期间被改动，这次调用的结果已被丢弃；该操作可能已经在服务器上生效，请先核实结果，再决定是否重试。"
    }
}

/// Identity of the bridge runtime that owns an agent-turn invocation.  A
/// rebound bridge keeps the same API surface but receives a new owner or
/// generation, so a late result from the retired bridge cannot be projected
/// into the new consumer.
public struct MCPToolBridgeRuntimeIdentity: Codable, Hashable, Sendable, Equatable {
    public let ownerID: UUID
    public let generation: UInt64

    public init(ownerID: UUID, generation: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
    }
}

/// A typed product-facing result for a fenced MCP invocation. The raw server
/// error text never crosses this boundary.
public struct MCPToolInvocationProjection: Codable, Equatable, Sendable {
    public let identity: MCPToolInvocationIdentity
    public let fullName: String
    public let response: MCPResponseProjection

    public static func success(
        identity: MCPToolInvocationIdentity,
        fullName: String,
        text: String
    ) -> Self {
        Self(
            identity: identity,
            fullName: fullName,
            response: .success(.string(MCPOutputLimiter.project(text)))
        )
    }

    public static func failure(
        identity: MCPToolInvocationIdentity,
        fullName: String,
        error: Error
    ) -> Self {
        Self(identity: identity, fullName: fullName, response: .failure(.from(error)))
    }

    private init(
        identity: MCPToolInvocationIdentity,
        fullName: String,
        response: MCPResponseProjection
    ) {
        self.identity = identity
        self.fullName = fullName
        self.response = response
    }
}

/// Bridge protocol for plugging MCP tools into B1b's `ToolExecutor`.
///
/// 已确认完成（B1f→B1b merge，BUG-8 核查 2026-08-06）：`BuiltinToolExecutor`
/// 已持有 `mcpBridge: (any MCPToolBridge)?`（ToolExecutor.swift:112），
/// `execute(name:)` 对 `mcp_` 前缀工具名分发到
/// `callMCPTool(fullName:arguments:)`（ToolExecutor.swift:203），agent 循环
/// 可直接调用 MCP 工具。registry 同时保持 standalone 可用（发现 + 调用）。
public protocol MCPToolBridge: Sendable {
    /// All tools currently available across the *enabled* servers, with their
    /// bridged `mcp_<server>_<tool>` full names.
    func mcpBoundTools() async throws -> [MCPBoundTool]
    /// Invoke a tool by its bridged full name. Throws `MCPClientError` on
    /// transport/RPC failure and `MCPClientError.toolNotFound` for unknown
    /// names.
    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String
}

/// Optional live capability fence for policy gates. A turn may retain an
/// immutable catalog after a settings edit, while execution still has to
/// consult the live origin before accepting a dynamic MCP name.
public protocol MCPToolBridgeLiveCapabilityResolving: MCPToolBridge {
    func resolvesCapability(_ name: String) async throws -> Bool
}

public protocol MCPToolBridgeInteractionResolving: MCPToolBridge {
    func requiresUserInteraction(_ fullName: String) -> Bool
}

/// 一个 MCP 工具在“以后都允许”规则里的身份：所属服务器的配置指纹 + 工具全名。
/// 服务器的命令、参数、地址或超时一变，指纹就变，旧规则自然失效。
public struct MCPToolRuleIdentity: Sendable, Equatable {
    public let serverID: String
    public let serverFingerprint: String
    public let fullName: String
    /// 服务器自述只读（annotations.readOnlyHint）。只用于计划模式放行，不用来免审批。
    public let readOnlyHint: Bool

    /// 规则里保存的匹配串：服务器配置指纹 + 工具全名，不含通配。
    public var rulePattern: String { "\(serverFingerprint):\(fullName)" }

    public init(serverID: String, serverFingerprint: String, fullName: String, readOnlyHint: Bool) {
        self.serverID = serverID
        self.serverFingerprint = serverFingerprint
        self.fullName = fullName
        self.readOnlyHint = readOnlyHint
    }
}

public protocol MCPToolBridgeRuleIdentityResolving: MCPToolBridge {
    func ruleIdentity(forFullName fullName: String) -> MCPToolRuleIdentity?
}

/// Capability boundary for callers that must supply a unique turn/attempt
/// identity. Legacy bridges remain source-compatible but cannot be projected
/// as fenced production invocations unless they opt into this protocol.
public protocol MCPToolBridgeInvocationFencing: MCPToolBridge {
    func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        invocation: MCPToolInvocationIdentity
    ) async throws -> String
}

/// Capability boundary for callers that must retain the exact bridge runtime
/// across an awaited call.  The optional identity permits task-local wrappers
/// to fail closed when their currently selected bridge has no fence.
public protocol MCPToolBridgeRuntimeFencing: MCPToolBridge {
    var runtimeIdentity: MCPToolBridgeRuntimeIdentity? { get }
    func accepts(_ identity: MCPToolBridgeRuntimeIdentity) -> Bool
}

public extension MCPToolBridge {
    /// Produce a typed, redacted result only through an identity-aware bridge.
    func callMCPToolProjection(
        fullName: String,
        arguments: [String: Any]?,
        identity: MCPToolInvocationIdentity
    ) async -> MCPToolInvocationProjection {
        if let runtime = self as? any MCPToolBridgeRuntimeFencing,
           let expected = runtime.runtimeIdentity {
            return await runtime.callMCPToolProjection(
                fullName: fullName,
                arguments: arguments,
                identity: identity,
                runtimeIdentity: expected
            )
        }
        guard let fenced = self as? any MCPToolBridgeInvocationFencing else {
            return .failure(
                identity: identity,
                fullName: fullName,
                error: MCPToolInvocationFenceError.invalidIdentity
            )
        }
        do {
            return .success(
                identity: identity,
                fullName: fullName,
                text: try await fenced.callMCPTool(
                    fullName: fullName,
                    arguments: arguments,
                    invocation: identity
                )
            )
        } catch {
            return .failure(identity: identity, fullName: fullName, error: error)
        }
    }
}

public extension MCPToolBridgeRuntimeFencing {
    /// Project a result only if the same bridge owner/generation remains
    /// active after transport awaits.  Rebinds and retirements become the
    /// existing typed invocation rejection rather than a late success.
    func callMCPToolProjection(
        fullName: String,
        arguments: [String: Any]?,
        identity: MCPToolInvocationIdentity,
        runtimeIdentity expected: MCPToolBridgeRuntimeIdentity
    ) async -> MCPToolInvocationProjection {
        guard runtimeIdentity != nil, accepts(expected) else {
            return .failure(
                identity: identity,
                fullName: fullName,
                error: MCPToolInvocationFenceError.runtimeRetired(identity)
            )
        }
        guard let fenced = self as? any MCPToolBridgeInvocationFencing else {
            return .failure(
                identity: identity,
                fullName: fullName,
                error: MCPToolInvocationFenceError.invalidIdentity
            )
        }
        do {
            let output = try await fenced.callMCPTool(
                fullName: fullName,
                arguments: arguments,
                invocation: identity
            )
            try Task.checkCancellation()
            guard runtimeIdentity != nil, accepts(expected) else {
                throw MCPToolInvocationFenceError.runtimeRetired(identity)
            }
            return .success(identity: identity, fullName: fullName, text: output)
        } catch is CancellationError {
            return .failure(
                identity: identity,
                fullName: fullName,
                error: MCPToolInvocationFenceError.runtimeRetired(identity)
            )
        } catch {
            return .failure(identity: identity, fullName: fullName, error: error)
        }
    }
}

/// Optional bridge capability for binding one turn to immutable MCP settings.
/// A bridge that cannot provide an immutable turn snapshot is rejected rather
/// than being admitted as a live bridge.
public protocol MCPToolBridgeTurnSnapshotting: MCPToolBridge {
    func snapshotForTurn() throws -> any MCPToolBridge
}

/// Capture a turn's authority now while allowing its expensive immutable
/// projection to be built on a worker. Bridges without this capability keep
/// their existing synchronous snapshot contract.
public protocol MCPToolBridgeTurnPreparing: MCPToolBridge {
    func captureTurnSnapshotPreparation() -> @Sendable () throws -> any MCPToolBridge
}

public enum MCPToolBridgeSnapshotError: Error, Equatable, Sendable {
    case unsupportedBase
    case invocationIdentityUnsupported
    case runtimeRetired
}

/// Task-local bridge selected by the current agent turn. The production
/// executor is composed once, while each turn can still use an immutable MCP
/// settings snapshot without mutating shared executor state.
public enum MCPToolBridgeTaskContext {
    @TaskLocal public static var current: (any MCPToolBridge)?
}

public final class TurnScopedMCPToolBridge: MCPToolBridgeInteractionResolving, MCPToolBridgeRuleIdentityResolving, MCPToolBridge, MCPToolBridgeLiveCapabilityResolving, MCPToolBridgeInvocationFencing, MCPToolBridgeRuntimeFencing, MCPToolBridgeTurnSnapshotting, @unchecked Sendable {
    public let base: any MCPToolBridge

    public init(base: any MCPToolBridge) {
        self.base = base
    }

    private var resolved: any MCPToolBridge {
        MCPToolBridgeTaskContext.current ?? base
    }

    public var runtimeIdentity: MCPToolBridgeRuntimeIdentity? {
        (resolved as? any MCPToolBridgeRuntimeFencing)?.runtimeIdentity
    }

    public func accepts(_ identity: MCPToolBridgeRuntimeIdentity) -> Bool {
        (resolved as? any MCPToolBridgeRuntimeFencing)?.accepts(identity) ?? false
    }

    public func requiresUserInteraction(_ fullName: String) -> Bool {
        (resolved as? any MCPToolBridgeInteractionResolving)?.requiresUserInteraction(fullName) ?? false
    }

    public func ruleIdentity(forFullName fullName: String) -> MCPToolRuleIdentity? {
        (resolved as? any MCPToolBridgeRuleIdentityResolving)?.ruleIdentity(forFullName: fullName)
    }

    public func snapshotForTurn() throws -> any MCPToolBridge {
        guard let snapshotting = base as? any MCPToolBridgeTurnSnapshotting else {
            throw MCPToolBridgeSnapshotError.unsupportedBase
        }
        return try snapshotting.snapshotForTurn()
    }

    public func captureTurnSnapshotPreparation() -> (@Sendable () throws -> any MCPToolBridge)? {
        (base as? any MCPToolBridgeTurnPreparing)?.captureTurnSnapshotPreparation()
    }

    public func mcpBoundTools() async throws -> [MCPBoundTool] {
        try await resolved.mcpBoundTools()
    }

    public func resolvesCapability(_ name: String) async throws -> Bool {
        if let resolving = resolved as? any MCPToolBridgeLiveCapabilityResolving {
            return try await resolving.resolvesCapability(name)
        }
        return try await resolved.mcpBoundTools().contains { $0.fullName == name }
    }

    public func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        MCPOutputLimiter.project(
            try await resolved.callMCPTool(fullName: fullName, arguments: arguments)
        )
    }

    public func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        invocation: MCPToolInvocationIdentity
    ) async throws -> String {
        guard let fenced = resolved as? any MCPToolBridgeInvocationFencing else {
            throw MCPToolBridgeSnapshotError.invocationIdentityUnsupported
        }
        return MCPOutputLimiter.project(
            try await fenced.callMCPTool(
                fullName: fullName,
                arguments: arguments,
                invocation: invocation
            )
        )
    }
}

/// Owns the single refresh task admitted by a live registry. A frozen turn
/// registry has no coordinator and therefore cannot start transport work.
private final class MCPBackgroundDiscoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var task: Task<Void, Never>?

    func claim() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == nil else { return nil }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    func install(_ task: Task<Void, Never>, generation: UInt64) {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func finish(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        task = nil
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        activeGeneration = nil
        let pending = task
        task = nil
        lock.unlock()
        pending?.cancel()
    }
}

/// Default `MCPToolBridge` implementation backed by an `MCPServerManager` and
/// a per-server `MCPClient` factory (injectable for tests).
public final class MCPToolRegistry: MCPToolBridgeInteractionResolving, MCPToolBridgeRuleIdentityResolving, MCPToolBridge, MCPToolBridgeLiveCapabilityResolving, MCPToolBridgeInvocationFencing, MCPToolBridgeRuntimeFencing, MCPToolBridgeTurnSnapshotting, MCPToolBridgeTurnPreparing, @unchecked Sendable {

    private struct ToolRoute: Sendable {
        let serverID: String
        let toolName: String
        let snapshotID: String
        /// Revision-independent identity of the tools/list publication. A
        /// change to another server restamps this server's snapshot (new
        /// `snapshotID`) without changing the publication.
        let publicationID: UUID?
        let schemaDigest: String
        let authorization: MCPToolAuthorization
    }

    /// Invocation claims belong to the bridge lineage, not one turn snapshot.
    /// A rebound snapshot must reject a replayed toolCall identity before it
    /// can repeat an external effect on the new owner.
    private final class InvocationLedger: @unchecked Sendable {
        /// Eviction is forbidden: forgetting an old identity would make a
        /// replayed toolCall executable again. Saturate and fail closed once
        /// the bounded ledger is full instead.
        private static let maximumClaims = 4_096
        private let lock = NSLock()
        private var claimed: Set<MCPToolInvocationIdentity> = []

        func claim(_ invocation: MCPToolInvocationIdentity) throws {
            lock.lock()
            defer { lock.unlock() }
            if claimed.contains(invocation) {
                throw MCPToolInvocationFenceError.duplicate(invocation)
            }
            guard claimed.count < Self.maximumClaims else {
                throw MCPToolInvocationFenceError.capacityExhausted(invocation)
            }
            claimed.insert(invocation)
        }
    }

    public let manager: MCPServerManager
    /// A frozen turn retains the original authority and runtime identity. Its
    /// catalog remains immutable, but a revoked grant cannot cause an effect.
    private let turnAuthority: (registry: MCPToolRegistry, identity: MCPToolBridgeRuntimeIdentity)?
    /// Factory used to build a client for a server. Defaults to
    /// `MCPClient(server:)` (real stdio/http transport).
    public let clientFactory: @Sendable (MCPServer) -> MCPClient
    /// Execution permission is independent from discovered tool declarations.
    /// Optional legacy static allowlist. When nil, persisted manager grants
    /// are the sole execution authority; missing grants remain deny-all.
    public let authorization: MCPToolAuthorization?

    private let lock = NSLock()
    /// serverID → client, reused across calls until `disconnectAll`.
    private var clients: [String: MCPClient] = [:]
    /// serverID → discovery-session identity the cached client was admitted
    /// under (D-MCP-05). A disable or delete boundary always invalidates the
    /// server grant and the discovery snapshot, so the next admitted route
    /// carries a new session id; a client whose admission session no longer
    /// matches the live route is retired and reconnected instead of
    /// resurrecting the capability through a session that survived the
    /// boundary.
    private var clientAdmissionSessions: [String: String] = [:]
    /// P2-1 正查表：fullName → (serverID, toolName)，在发现（refreshTools）
    /// 时随 boundTool 一起记录。`callMCPTool` 用它解析名字，而不是走
    /// `MCPBoundTool.parseFullName` 的字符串反解 —— 后者对含下划线的
    /// server id 非单射（"mcp_my_server_greet" 会被反解成 server="my"）。
    private var nameLookup: [String: ToolRoute] = [:]
    /// Retained for source compatibility. Discovery readiness is owned by the
    /// manager snapshot; this value no longer controls a second cache.
    public let cacheTTL: TimeInterval
    /// Present only on the live registry. Turn snapshots are cache-only and
    /// cannot create discovery tasks or touch transports.
    private let backgroundDiscoveryCoordinator: MCPBackgroundDiscoveryCoordinator?
    /// Invocation identities already claimed by this registry lineage.
    /// Keeping the ledger across completion and turn snapshots makes duplicate
    /// effects fail closed during recovery/rebind. It is replaced only by the
    /// explicit disconnect/reset lifecycle, which also rotates the owner.
    private var invocationLedger: InvocationLedger
    /// Incremented on disconnect/reconnect so an in-flight late result cannot
    /// be published after its runtime owner has been retired.
    private var invocationGeneration: UInt64 = 0
    /// Stable owner until the explicit disconnect/reset lifecycle. A turn
    /// snapshot gets a new owner, so rebinds cannot accept prior results.
    private var runtimeOwnerID = UUID()

    /// NSLock 的 lock/unlock 在 Swift 6 中不可直接从 async 上下文调用，
    /// 统一走这个同步辅助函数。
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public init(
        manager: MCPServerManager,
        clientFactory: (@Sendable (MCPServer) -> MCPClient)? = nil,
        cacheTTL: TimeInterval = 30,
        authorization: MCPToolAuthorization? = nil
    ) {
        self.manager = manager
        self.turnAuthority = nil
        self.clientFactory = clientFactory ?? { manager.makeClient(server: $0) }
        self.cacheTTL = max(0, cacheTTL)
        self.authorization = authorization
        self.invocationLedger = InvocationLedger()
        self.backgroundDiscoveryCoordinator = MCPBackgroundDiscoveryCoordinator()
    }

    private init(
        manager: MCPServerManager,
        clientFactory: @escaping @Sendable (MCPServer) -> MCPClient,
        cacheTTL: TimeInterval,
        authorization: MCPToolAuthorization?,
        invocationLedger: InvocationLedger,
        turnAuthority: (registry: MCPToolRegistry, identity: MCPToolBridgeRuntimeIdentity)
    ) {
        self.turnAuthority = turnAuthority
        self.manager = manager
        self.clientFactory = clientFactory
        self.cacheTTL = cacheTTL
        self.authorization = authorization
        self.invocationLedger = invocationLedger
        self.backgroundDiscoveryCoordinator = nil
    }

    public var runtimeIdentity: MCPToolBridgeRuntimeIdentity? {
        withLock {
            MCPToolBridgeRuntimeIdentity(ownerID: runtimeOwnerID, generation: invocationGeneration)
        }
    }

    public func accepts(_ identity: MCPToolBridgeRuntimeIdentity) -> Bool {
        withLock {
            runtimeOwnerID == identity.ownerID && invocationGeneration == identity.generation
        }
    }

    /// Freeze manager settings for one turn. The authoritative discovery
    /// snapshot is copied with the manager; only invocation/client runtime
    /// state remains private to the returned registry.
    public func snapshotForTurn() throws -> any MCPToolBridge {
        let (ledger, identity) = withLock {
            (invocationLedger, MCPToolBridgeRuntimeIdentity(ownerID: runtimeOwnerID, generation: invocationGeneration))
        }
        let frozenManager = manager.makeSnapshotManager()
        scheduleBackgroundDiscoveryIfNeeded()
        return MCPToolRegistry(
            manager: frozenManager,
            clientFactory: clientFactory,
            cacheTTL: cacheTTL,
            authorization: authorization,
            invocationLedger: ledger,
            turnAuthority: turnAuthority ?? (self, identity)
        )
    }

    public func captureTurnSnapshotPreparation() -> @Sendable () throws -> any MCPToolBridge {
        let (ledger, identity) = withLock {
            (invocationLedger, MCPToolBridgeRuntimeIdentity(ownerID: runtimeOwnerID, generation: invocationGeneration))
        }
        let prepareManager = manager.captureSnapshotManagerPreparation()
        return { [self] in
            try Task.checkCancellation()
            guard accepts(identity) else { throw MCPToolBridgeSnapshotError.runtimeRetired }
            let frozenManager = prepareManager()
            try Task.checkCancellation()
            guard accepts(identity) else { throw MCPToolBridgeSnapshotError.runtimeRetired }
            scheduleBackgroundDiscoveryIfNeeded()
            let turn = MCPToolRegistry(
                manager: frozenManager,
                clientFactory: clientFactory,
                cacheTTL: cacheTTL,
                authorization: authorization,
                invocationLedger: ledger,
                turnAuthority: turnAuthority ?? (self, identity)
            )
            try Task.checkCancellation()
            guard accepts(identity) else { throw MCPToolBridgeSnapshotError.runtimeRetired }
            return turn
        }
    }

    /// Only a canonical cache-only turn can supply explicit Composer grants.
    /// Discovery, enablement, or an arbitrary MCPToolBridge is not authority.
    public func composerCapabilityGrantBindings() throws -> [String: String] {
        guard let turnAuthority, backgroundDiscoveryCoordinator == nil else { return [:] }
        try syncNameLookup()
        let routes = withLock { nameLookup }
        var bindings: [String: String] = [:]
        for (name, route) in routes where routeIsCurrent(route)
            && routeIsAuthorizedNow(route, fullName: name)
            && routeIsAuthorizedAtOrigin(route, fullName: name) {
            let identity = [route.snapshotID, route.schemaDigest, name,
                            turnAuthority.identity.ownerID.uuidString,
                            String(turnAuthority.identity.generation)]
            bindings[name] = DeletionGate.fingerprint(try JSONEncoder().encode(identity))
        }
        return bindings
    }

    private func routeIsAuthorizedAtOrigin(_ route: ToolRoute, fullName: String) -> Bool {
        guard let turnAuthority else { return true }
        return turnAuthority.registry.accepts(turnAuthority.identity)
            && turnAuthority.registry.routeIsCurrent(route)
            && turnAuthority.registry.routeIsAuthorizedNow(route, fullName: fullName)
    }

    // MARK: Discovery

    /// Discover tools from all enabled servers (connect + `tools/list`).
    /// Individual server failures are skipped (logged) — one dead server must
    /// not block the others.
    public func refreshTools() async throws {
        try Task.checkCancellation()
        let servers = manager.enabledServers().filter { manager.isServerAuthorized($0) }
        try await refreshTools(servers: servers, automatic: false)
    }

    // Automatic reads admit granted tools or unbound schema metadata.
    // Explicit refresh can still inspect a revoked tool schema.
    private func refreshTools(servers: [MCPServer], automatic: Bool) async throws {
        try Task.checkCancellation()
        for server in servers {
            try Task.checkCancellation()
            // Recheck a queued automatic request before opening a transport.
            // The manager still fences every subsequent await/commit.
            if automatic {
                guard let grant = manager.authorization(serverID: server.id),
                      !grant.authorizedToolNames.isEmpty || grant.schemaBindingDigest == nil else { continue }
            }
            let previousDiscovery = manager.discoverySnapshot(serverID: server.id)
            do {
                _ = try await manager.discoverTools(
                    serverID: server.id,
                    clientFactory: clientFactory
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A known failed reconnect must not leave its old tools/list
                // result in the next model-visible catalog. Other servers
                // remain available; cancellation does not revoke discovery.
                try manager.retireDiscoveryAfterFailedRefresh(
                    serverID: server.id, expected: previousDiscovery
                )
                AppLogger(category: "MCP").warning("MCP server '\(server.id)' tool discovery failed: \(error.localizedDescription)")
            }
        }
        try syncNameLookup()
        retireObsoleteClients(for: manager.enabledServers().filter { manager.isServerAuthorized($0) })
    }

    public func mcpBoundTools() async throws -> [MCPBoundTool] {
        try Task.checkCancellation()
        let servers = manager.enabledServers().filter { manager.isServerAuthorized($0) }
        let eligible = servers.filter {
            guard let grant = manager.authorization(serverID: $0.id) else { return false }
            // Nil admits schema metadata discovery, never execution. Explicit
            // tool revocation retains its nonnil binding and stays fenced.
            return !grant.authorizedToolNames.isEmpty || grant.schemaBindingDigest == nil
        }
        let needsDiscovery = eligible.contains {
            manager.discoverySnapshot(serverID: $0.id) == nil
        }
        if needsDiscovery, backgroundDiscoveryCoordinator != nil {
            try await refreshTools(servers: eligible, automatic: true)
        }
        try syncNameLookup()
        retireObsoleteClients(for: servers)
        return authorizedTools()
    }

    /// Resolve an MCP capability against both the captured turn route and its
    /// live origin. Frozen turns may keep advertising their captured catalog,
    /// but a descriptor/grant boundary must fail closed before policy accepts
    /// the model call.
    public func resolvesCapability(_ name: String) async throws -> Bool {
        guard name.hasPrefix("mcp_") else { return false }
        _ = try await mcpBoundTools()
        guard let route = withLock({ nameLookup[name] }) else { return false }
        guard routeIsCurrent(route),
              routeIsAuthorizedNow(route, fullName: name),
              routeIsAuthorizedAtOrigin(route, fullName: name) else {
            return false
        }
        return true
    }

    public func requiresUserInteraction(_ fullName: String) -> Bool {
        // Exact registration-time route and catalog metadata, never a guessed
        // MCP prefix, tool description, or model-supplied argument.
        guard let bound = authorizedTools().first(where: { $0.fullName == fullName }) else { return false }
        return bound.tool.requiresUserInteraction
    }

    /// 规则身份：只对用户已授权的服务器里、已授权的工具返回；服务器配置指纹取当前值。
    public func ruleIdentity(forFullName fullName: String) -> MCPToolRuleIdentity? {
        guard let bound = authorizedTools().first(where: { $0.fullName == fullName }),
              let server = manager.server(id: bound.serverID) else { return nil }
        return MCPToolRuleIdentity(
            serverID: bound.serverID, serverFingerprint: server.descriptorFingerprint,
            fullName: fullName, readOnlyHint: bound.tool.readOnlyHint)
    }

    // MARK: Invocation

    public func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        try await callMCPTool(fullName: fullName, arguments: arguments, invocation: nil)
    }

    /// Invoke with an optional identity fence. Identified calls are claimed
    /// before transport work and checked again after await; a duplicate or a
    /// result from a retired runtime is rejected without publishing output.
    public func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        invocation: MCPToolInvocationIdentity?
    ) async throws -> String {
        guard !fullName.isEmpty else {
            throw MCPClientError.toolNotFound(fullName)
        }
        let generation = try beginInvocation(invocation)
        var resolved = withLock { nameLookup[fullName] }
        if resolved == nil || !(resolved.map { routeIsCurrent($0) } ?? false) {
            if let resolved,
               !routeIsAuthorizedNow(resolved, fullName: fullName),
               !mayRediscoverExplicitlyGrantedRoute(resolved, fullName: fullName) {
                retireClientIfServerBoundaryClosed(serverID: resolved.serverID)
                throw MCPClientError.permissionDenied(fullName)
            }
            // A caller may invoke a discovered tool immediately after app
            // launch. Refresh once, then require an exact registered name;
            // never reuse a route whose snapshot or authorization grant is stale.
            if backgroundDiscoveryCoordinator != nil {
                try await ensureDiscovery()
            } else {
                try syncNameLookup()
            }
            resolved = withLock { nameLookup[fullName] }
        }
        guard let resolved,
              routeIsCurrent(resolved),
              let server = manager.server(id: resolved.serverID),
              server.enabled else {
            if let resolved {
                retireClientIfServerBoundaryClosed(serverID: resolved.serverID)
            }
            throw MCPClientError.toolNotFound(fullName)
        }
        let serverID = resolved.serverID
        let toolName = resolved.toolName
        let cachedTools = authoritativeToolCache()[serverID]
        // Ensure the tool is known; if not, refresh discovery once.
        if cachedTools?[toolName] == nil {
            guard backgroundDiscoveryCoordinator != nil else {
                throw MCPClientError.toolNotFound(fullName)
            }
            try await refreshTools()
        }
        let known = authoritativeToolCache()[serverID]?[toolName] != nil
        guard known else {
            throw MCPClientError.toolNotFound(fullName)
        }
        guard routeIsCurrent(resolved) else {
            throw MCPClientError.toolNotFound(fullName)
        }
        guard manager.isServerAuthorized(server),
              manager.isToolAuthorized(serverID: serverID, toolName: toolName),
              authorization?.allows(
                  fullName: fullName,
                  serverID: serverID,
                  toolName: toolName,
                  descriptorFingerprint: server.descriptorFingerprint
              ) ?? true else {
            throw MCPClientError.permissionDenied(fullName)
        }
        guard routeIsAuthorizedAtOrigin(resolved, fullName: fullName) else {
            throw MCPClientError.permissionDenied(fullName)
        }
        let admittedDiscovery = manager.discoverySnapshot(serverID: serverID)
        var admittedClient: MCPClient?
        let output: String
        do {
            let client = try await clientFor(server, admissionSessionID: resolved.snapshotID)
            admittedClient = client
            try Task.checkCancellation()
            guard routeIsAuthorizedAtOrigin(resolved, fullName: fullName) else {
                throw MCPClientError.permissionDenied(fullName)
            }
            do {
                output = try await client.callTool(name: toolName, arguments: arguments, invocation: invocation)
            } catch {
                await UsageTelemetryContext.observer?(.mcpCall(serverID: serverID, fullName: fullName, succeeded: false))
                throw error
            }
            await UsageTelemetryContext.observer?(.mcpCall(serverID: serverID, fullName: fullName, succeeded: true))
        } catch {
            // Compare the original admission before local disconnection cleanup
            // can advance its generation. A stable EOF retains its transport error.
            if !invocationGenerationMatches(generation) || !routeIsCurrent(resolved)
                || !routeIsAuthorizedAtOrigin(resolved, fullName: fullName) {
                retireClientIfServerBoundaryClosed(serverID: serverID)
                throw MCPToolInvocationFenceError.runtimeRetired(
                    invocation ?? MCPToolInvocationIdentity(correlationID: "anonymous", attemptID: "anonymous")
                )
            }
            if let transportError = error as? MCPClientError {
                switch transportError {
                case .processExited, .transportNotStarted:
                    try retireObservedDisconnectedRoute(
                        serverID: serverID, expected: admittedDiscovery,
                        generation: generation, client: admittedClient
                    )
                default:
                    break
                }
            }
            throw error
        }
        // A descriptor/authorization rebind can happen while the transport is
        // awaiting its final response.  Re-check the route at the publication
        // seam so a late result from the old session cannot reach the agent
        // turn, even when the transport itself does not surface cancellation.
        try Task.checkCancellation()
        guard invocationGenerationMatches(generation), routeIsCurrent(resolved),
              routeIsAuthorizedAtOrigin(resolved, fullName: fullName) else {
            // The session that served this call crossed its runtime/route
            // boundary while awaiting. Refusing publication alone would keep
            // the surviving client reusable; D-MCP-05 also requires that the
            // boundary-closed server stops holding a live client session.
            retireClientIfServerBoundaryClosed(serverID: serverID)
            throw MCPToolInvocationFenceError.runtimeRetired(
                invocation ?? MCPToolInvocationIdentity(correlationID: "anonymous", attemptID: "anonymous")
            )
        }
        // 图片标记不参与限长与脱敏，正文处理完再接回。
        let split = ToolResultImageChannel.splitTrailingMarkers(output)
        return MCPOutputLimiter.project(split.body) + split.markers
    }

    public func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        invocation: MCPToolInvocationIdentity
    ) async throws -> String {
        let fencedInvocation: MCPToolInvocationIdentity? = invocation
        return try await callMCPTool(
            fullName: fullName,
            arguments: arguments,
            invocation: fencedInvocation
        )
    }

    public func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        identity: MCPToolInvocationIdentity
    ) async throws -> String {
        try await callMCPTool(
            fullName: fullName,
            arguments: arguments,
            invocation: identity
        )
    }

    /// Disconnect all cached clients (e.g. on app shutdown).
    public func disconnectAll() {
        if turnAuthority == nil { manager.disconnectAllRuntimes() }
        backgroundDiscoveryCoordinator?.cancel()
        let all: [String: MCPClient] = withLock {
            advanceInvocationGeneration()
            // A full disconnect is the explicit lifecycle reset. Never evict
            // individual claims: rotate the owner and replace the bounded
            // ledger together so old identities remain invalid forever while
            // a fresh session cannot be memory-DoS'd by historical claims.
            runtimeOwnerID = UUID()
            invocationLedger = InvocationLedger()
            let all = clients
            clients = [:]
            clientAdmissionSessions = [:]
            nameLookup = [:]
            return all
        }
        for client in all.values {
            client.disconnect()
        }
    }

    /// Keep a retired runtime identity impossible to recreate when the
    /// generation counter reaches its UInt64 boundary.  Wrapping in place
    /// would make an ancient in-flight identity valid again after enough
    /// restarts; rotating the owner preserves the fail-closed fence.
    private func advanceInvocationGeneration() {
        if invocationGeneration == UInt64.max {
            invocationGeneration = 0
            runtimeOwnerID = UUID()
        } else {
            invocationGeneration += 1
        }
    }

    private func beginInvocation(_ invocation: MCPToolInvocationIdentity?) throws -> UInt64 {
        try withLock {
            if let invocation {
                guard invocation.isValid else { throw MCPToolInvocationFenceError.invalidIdentity }
                // Claim and generation capture are one registry-locked
                // operation, so reset cannot replace the ledger between them.
                try invocationLedger.claim(invocation)
            }
            return invocationGeneration
        }
    }

    private func invocationGenerationMatches(_ generation: UInt64) -> Bool {
        withLock { invocationGeneration == generation }
    }

    // MARK: Internals

    /// Admit at most one live-registry refresh. The turn already owns
    /// `frozenManager` before this is called, so this task cannot mutate the
    /// current turn; accepted cache publication remains fenced by the manager.
    private func scheduleBackgroundDiscoveryIfNeeded() {
        guard let coordinator = backgroundDiscoveryCoordinator else { return }
        let servers = manager.enabledServers().filter {
            guard manager.isServerAuthorized($0),
                  let grant = manager.authorization(serverID: $0.id) else { return false }
            return !grant.authorizedToolNames.isEmpty || grant.schemaBindingDigest == nil
        }
        guard servers.contains(where: { manager.discoverySnapshot(serverID: $0.id) == nil }),
              let generation = coordinator.claim() else { return }
        let task = Task { [weak self, coordinator] in
            defer { coordinator.finish(generation: generation) }
            guard let self else { return }
            do {
                try await self.refreshTools(servers: servers, automatic: true)
            } catch is CancellationError {
                return
            } catch {
                // Background discovery is opportunistic. Explicit refresh and
                // invocation paths retain their throwing behavior.
                return
            }
        }
        coordinator.install(task, generation: generation)
    }

    private func authorizedTools() -> [MCPBoundTool] {
        let cache = authoritativeToolCache()
        let filtered = cache.reduce(into: [String: [String: MCPTool]]()) { result, entry in
            guard let server = manager.server(id: entry.key),
                  manager.isServerAuthorized(server) else { return }
            let allowed = entry.value.filter { tool in
                manager.isToolAuthorized(serverID: entry.key, toolName: tool.key)
            }
            if !allowed.isEmpty { result[entry.key] = allowed }
        }
        return Self.flatten(filtered)
    }

    private func authoritativeToolCache() -> [String: [String: MCPTool]] {
        manager.enabledServers().reduce(into: [String: [String: MCPTool]]()) { result, server in
            guard manager.isServerAuthorized(server),
                  manager.discoverySnapshot(serverID: server.id) != nil else { return }
            result[server.id] = Dictionary(
                uniqueKeysWithValues: manager.cachedTools(serverID: server.id).map { ($0.name, $0) }
            )
        }
    }

    private func ensureDiscovery() async throws {
        let servers = manager.enabledServers().filter {
            guard manager.isServerAuthorized($0),
                  let grant = manager.authorization(serverID: $0.id) else { return false }
            return !grant.authorizedToolNames.isEmpty || grant.schemaBindingDigest == nil
        }
        if servers.contains(where: { manager.discoverySnapshot(serverID: $0.id) == nil }) {
            try await refreshTools(servers: servers, automatic: true)
        } else {
            try syncNameLookup()
        }
    }

    private func syncNameLookup() throws {
        let lookup = try Self.buildNameLookup(manager.snapshot())
        // A frozen turn can bind only tools authorized in its captured
        // manager. Keep origin checks at invocation time: an older turn must
        // still report revoked authority, not pretend its tool never existed.
        let capturedLookup = turnAuthority == nil ? lookup : lookup.filter {
            routeIsAuthorizedNow($0.value, fullName: $0.key)
        }
        withLock { nameLookup = capturedLookup }
    }

    private func routeIsCurrent(_ route: ToolRoute) -> Bool {
        let snapshot = manager.snapshot()
        guard let server = snapshot.servers.first(where: { $0.id == route.serverID }),
              server.enabled,
              let grant = snapshot.authorizations[route.serverID],
              grant.serverAuthorized,
              grant.serverID == route.serverID,
              grant.descriptorFingerprint == server.descriptorFingerprint,
              grant == route.authorization,
              let discovery = snapshot.discoverySnapshots[route.serverID],
              discovery.revision == snapshot.revision,
              discovery.descriptorFingerprint == server.descriptorFingerprint,
              // Same snapshot (the original rule), or the same tools/list
              // publication re-stamped because another server changed.
              discovery.id == route.snapshotID
                || (route.publicationID != nil && route.publicationID == discovery.publicationID),
              discovery.schemaDigest == route.schemaDigest,
              grant.schemaBindingDigest == route.schemaDigest,
              manager.discoverySnapshot(serverID: route.serverID)?.schemaDigest == route.schemaDigest else {
            return false
        }
        return true
    }

    private func routeIsAuthorizedNow(_ route: ToolRoute, fullName: String) -> Bool {
        guard let server = manager.server(id: route.serverID),
              server.enabled,
              manager.isServerAuthorized(server),
              manager.isToolAuthorized(
                  serverID: route.serverID,
                  toolName: route.toolName
              ) else {
            return false
        }
        return authorization?.allows(
            fullName: fullName,
            serverID: route.serverID,
            toolName: route.toolName,
            descriptorFingerprint: server.descriptorFingerprint
        ) ?? true
    }

    /// A live registry may refresh a stale discovery after an explicit
    /// re-grant. This only admits discovery, never execution: the refreshed
    /// route and schema-bound authorization are checked again below. Frozen
    /// turns cannot refresh or inherit a later grant.
    private func mayRediscoverExplicitlyGrantedRoute(_ route: ToolRoute, fullName: String) -> Bool {
        guard backgroundDiscoveryCoordinator != nil,
              let server = manager.server(id: route.serverID),
              server.enabled,
              manager.isServerAuthorized(server),
              let grant = manager.authorization(serverID: route.serverID),
              grant.serverID == route.serverID,
              grant.descriptorFingerprint == server.descriptorFingerprint,
              grant.serverAuthorized,
              grant.authorizedToolNames.contains(route.toolName) else {
            return false
        }
        return authorization?.allows(
            fullName: fullName,
            serverID: route.serverID,
            toolName: route.toolName,
            descriptorFingerprint: server.descriptorFingerprint
        ) ?? true
    }

    private func retireObsoleteClients(for servers: [MCPServer]) {
        let currentDescriptors = Dictionary(uniqueKeysWithValues: servers.map {
            ($0.id, $0.descriptorFingerprint)
        })
        let retired: [MCPClient] = withLock {
            let staleIDs = clients.keys.filter { id in
                guard let descriptorFingerprint = currentDescriptors[id],
                      let client = clients[id] else {
                    return true
                }
                return client.server.descriptorFingerprint != descriptorFingerprint
            }
            return staleIDs.compactMap { id in
                clientAdmissionSessions.removeValue(forKey: id)
                return clients.removeValue(forKey: id)
            }
        }
        for client in retired {
            client.disconnect()
        }
    }

    /// Admit a transport client for one invocation.  Reuse requires both the
    /// live descriptor fingerprint and the discovery-session identity under
    /// which the cached client was admitted. A disable/delete (or grant)
    /// boundary invalidates the discovery snapshot, so the next admitted route
    /// carries a new session id and the pre-boundary client can never serve a
    /// new request after the boundary.
    private func clientFor(_ server: MCPServer, admissionSessionID: String) async throws -> MCPClient {
        let cached: (client: MCPClient?, retired: MCPClient?) = withLock {
            guard let existing = clients[server.id] else {
                return (nil, nil)
            }
            guard existing.server.descriptorFingerprint == server.descriptorFingerprint,
                  clientAdmissionSessions[server.id] == admissionSessionID else {
                clients.removeValue(forKey: server.id)
                clientAdmissionSessions.removeValue(forKey: server.id)
                return (nil, existing)
            }
            return (existing, nil)
        }
        if let cachedClient = cached.client { return cachedClient }
        cached.retired?.disconnect()
        let client = clientFactory(server)
        (turnAuthority?.registry.manager ?? manager).observeRuntime(client)
        withLock {
            clients[server.id] = client
            clientAdmissionSessions[server.id] = admissionSessionID
        }
        do {
            try await client.connect()
            return client
        } catch {
            withLock {
                if clients[server.id] === client {
                    clients.removeValue(forKey: server.id)
                    clientAdmissionSessions.removeValue(forKey: server.id)
                }
            }
            client.disconnect()
            throw error
        }
    }

    /// Refusal is only half of the D-MCP-05 contract: when a new request is
    /// rejected because its server passed a disable/delete (or server-grant
    /// loss) boundary, the registry must also stop retaining a live client
    /// session for that server. A tool-level revocation on an otherwise
    /// enabled and server-authorized configuration intentionally keeps the
    /// shared session alive so sibling tools are not severed.
    private func retireClientIfServerBoundaryClosed(serverID: String) {
        let boundaryClosed: Bool
        if let server = manager.server(id: serverID) {
            boundaryClosed = !server.enabled || !manager.isServerAuthorized(server)
        } else {
            boundaryClosed = true
        }
        guard boundaryClosed else { return }
        let retired: MCPClient? = withLock {
            clientAdmissionSessions.removeValue(forKey: serverID)
            return clients.removeValue(forKey: serverID)
        }
        retired?.disconnect()
    }

    /// A transport exit is an observed disconnect, not a schema or grant
    /// change. Remove only this failed client, then retire the exact tools/list
    /// publication that admitted it. A concurrent successful rediscovery has
    /// a different publication identity and must remain model-visible.
    private func retireObservedDisconnectedRoute(
        serverID: String,
        expected: MCPDiscoverySnapshot?,
        generation: UInt64,
        client: MCPClient?
    ) throws {
        if let client {
            let retired: MCPClient? = withLock {
                guard clients[serverID] === client else { return nil }
                clientAdmissionSessions.removeValue(forKey: serverID)
                return clients.removeValue(forKey: serverID)
            }
            retired?.disconnect()
        }
        guard invocationGenerationMatches(generation), let expected else { return }
        let origin = turnAuthority?.registry ?? self
        if let turnAuthority,
           !turnAuthority.registry.accepts(turnAuthority.identity) { return }
        _ = try origin.manager.retireDiscoveryAfterFailedRefresh(
            serverID: serverID, expected: expected
        )
    }

    /// P2-1：由发现缓存构建 fullName → (serverID, toolName) 正查表。
    private static func buildNameLookup(
        _ snapshot: MCPServerManager.Snapshot
    ) throws -> [String: ToolRoute] {
        var lookup: [String: ToolRoute] = [:]
        for (serverID, discovery) in snapshot.discoverySnapshots {
            guard let server = snapshot.servers.first(where: { $0.id == serverID }),
                  server.enabled,
                  let grant = snapshot.authorizations[serverID],
                  grant.serverAuthorized,
                  grant.serverID == serverID,
                  grant.descriptorFingerprint == server.descriptorFingerprint,
                  discovery.revision == snapshot.revision,
                  discovery.descriptorFingerprint == server.descriptorFingerprint else {
                continue
            }
            for tool in discovery.tools {
                let toolName = tool.name
                let fullName = MCPBoundTool.makeFullName(serverID: serverID, toolName: toolName)
                if let existing = lookup[fullName], existing.serverID != serverID || existing.toolName != toolName {
                    throw MCPClientError.toolNameCollision(fullName)
                }
                lookup[fullName] = ToolRoute(
                    serverID: serverID,
                    toolName: toolName,
                    snapshotID: discovery.id,
                    publicationID: discovery.publicationID,
                    schemaDigest: discovery.schemaDigest,
                    authorization: grant
                )
            }
        }
        return lookup
    }

    private static func flatten(_ cache: [String: [String: MCPTool]]) -> [MCPBoundTool] {
        var result: [MCPBoundTool] = []
        for (serverID, tools) in cache.sorted(by: { $0.key < $1.key }) {
            for tool in tools.values.sorted(by: { $0.name < $1.name }) {
                result.append(MCPBoundTool(
                    fullName: MCPBoundTool.makeFullName(serverID: serverID, toolName: tool.name),
                    serverID: serverID,
                    tool: tool
                ))
            }
        }
        return result
    }
}
