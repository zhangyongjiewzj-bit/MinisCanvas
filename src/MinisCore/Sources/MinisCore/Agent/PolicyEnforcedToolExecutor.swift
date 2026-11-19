import Foundation

// MARK: - Dynamic Capability Resolution

/// 动态 capability 解析源（MCP live registry seam）。
///
/// Policy 层的 capability 门禁以 `GoalEnvelope.allowedCapabilities` 为权威；
/// 对运行期才发现/授权的工具（如 MCP 工具），由该解析器按 base executor 的
/// live 注册表确认 —— 与 `BuiltinToolExecutor.execute` 的前置白名单共用同一
/// 事实源，避免静态 allowlist 误伤合法 MCP 调用。
public protocol PolicyCapabilityResolving {
    func resolvesCapability(_ name: String) async throws -> Bool
}

extension BuiltinToolExecutor: PolicyCapabilityResolving {
    public func resolvesCapability(_ name: String) async throws -> Bool {
        // MCP names are dynamic capabilities. `registeredToolNames` is a
        // dispatch cache populated after a prior call, so consulting it first
        // would let a stale descriptor or revoked name pass the original
        // request capability gate. Resolve every MCP name against the same
        // live/cached bridge catalog that the dispatcher uses; the bridge
        // remains responsible for descriptor, grant, lease and identity
        // fences. Native tools keep their static registration behavior.
        if name.hasPrefix("mcp_") {
            guard let mcpBridge else { return false }
            if let liveResolver = mcpBridge as? any MCPToolBridgeLiveCapabilityResolving {
                return try await liveResolver.resolvesCapability(name)
            }
            let discovered = try await mcpBridge.mcpBoundTools().map(\.fullName)
            return discovered.contains(name)
        }
        return registeredToolNames.contains(name)
    }
}

// MARK: - Error

public enum PolicyEnforcedToolExecutorError: Error, Equatable, Sendable {
    case policyViolation(PolicyViolation)
}

extension PolicyEnforcedToolExecutorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .policyViolation(let violation):
            return "策略不允许本次操作，未执行：\(violation.userFacingReason)"
        }
    }
}

extension PolicyViolation {
    /// 面向用户和模型的中文原因；不带内部枚举名，也不含路径或密钥。
    public var userFacingReason: String {
        switch self {
        case .emptyScope, .scopeMismatch, .invalidLease, .leaseGoalMismatch:
            return "本次任务的授权范围无效或与当前任务不符"
        case .capabilityNotAllowed, .invalidCapability:
            return "这个工具不在当前授权范围内"
        case .fileRootNotAllowed, .invalidFileRoot:
            return "目标路径不在授权的文件夹内"
        case .networkDomainNotAllowed, .invalidNetworkDomain:
            return "目标网址不在允许访问的范围内"
        case .budgetExceeded, .invalidBudget, .invalidRequestCost:
            return "本次任务的用量预算已用完或无效"
        case .deadlineExceeded, .requestDeadlineExceeded:
            return "已超过本次任务的时限"
        case .leaseExpired:
            return "本次授权已过期，请重新发送请求"
        case .leaseRevoked:
            return "本次授权已被撤销"
        case .autonomyLevelExceeded:
            return "这个操作超出了当前的自主权上限"
        case .concurrencyExceeded, .invalidConcurrency, .invalidActiveTasks:
            return "同时进行的任务过多，请稍后再试"
        }
    }
}

/// Secret-free evidence of the last capability denial. The identifier is
/// normalized and bounded by `CapabilityRouter`; the policy violation remains
/// the single denial reason consumed by callers and thrown by this executor.
public struct CapabilityDenialReceipt: Sendable, Equatable {
    public let capabilityID: String
    public let reason: PolicyViolation

    public init(capabilityID: String, reason: PolicyViolation) {
        self.capabilityID = CapabilityRouter.boundedCapabilityIdentifier(capabilityID)
        self.reason = reason
    }
}

// MARK: - Policy-Enforced Executor

/// 把 `PolicyRuntime.validatePolicy` 接进 ToolExecutor seam 的单一强制包装
/// （P3-G1 / MC0-P1-01 的生产组合根）。
///
/// 每次 `execute` 在触碰 base 之前先做 capability / lease / scope / budget /
/// deadline / fileRoot / networkDomain 校验；任一失败立即抛
/// `PolicyEnforcedToolExecutorError.policyViolation`，**base 不被调用**。
/// `acceptedExecutionCount` / `deniedExecutionCount` 为可观察计数，测试据此
/// 断言「非法工具调用底层执行 = 0、合法调用恰好一次」。
/// Read-only destination check from the runtime that will execute the call.
public protocol BrowserDestinationPolicyChecking: Sendable {
    func permitsBrowserDestination(host: String) -> Bool?
}

public final class PolicyEnforcedToolExecutor: BrowserDestinationPolicyChecking, ToolExecutor, ToolCatalogValidatingExecutor, PolicyRuntimeBoundToolExecutor, SessionReadCapabilityAwareToolExecutor, BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    /// 底层真实执行器（生产路径为 `BuiltinToolExecutor`）。
    public let base: any ToolExecutor
    /// 不可变执行上下文（scope / allowlist / roots / domains / budget / deadline）。
    public let goal: GoalEnvelope
    /// 动态 capability 解析器（nil = 只认 goal allowlist，fail-closed）。
    public let capabilityResolver: (any PolicyCapabilityResolving)?
    /// 可注入时钟（测试固定时间；生产默认 Date()）。
    public let clock: @Sendable () -> Date
    /// 从工具名 + 输入构建 `PolicyRequest`（可注入；默认只取 path / 计费 1）。
    public let requestBuilder: @Sendable (String, [String: Any]) -> PolicyRequest
    public let policyRuntimeBound = true

    private let lock = NSLock()
    private var leaseValue: AutonomyLease?
    private var spentBudget = 0
    private var reservedBudget = 0
    private var activeTasks = 0
    private var _acceptedExecutionCount = 0
    private var _deniedExecutionCount = 0
    private var _lastCapabilityDenialReceipt: CapabilityDenialReceipt?

    public init(
        base: any ToolExecutor,
        goal: GoalEnvelope,
        lease: AutonomyLease?,
        capabilityResolver: (any PolicyCapabilityResolving)? = nil,
        requestBuilder: (@Sendable (String, [String: Any]) -> PolicyRequest)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.goal = goal
        self.leaseValue = lease
        self.capabilityResolver = capabilityResolver
        self.requestBuilder = requestBuilder ?? Self.defaultRequestBuilder
        self.clock = clock
    }

    public func permitsBrowserDestination(host: String) -> Bool? {
        goal.permitsNetworkDomain(host)
    }

    /// Catalog validation is a source/dispatcher consistency check, not a
    /// PolicyRuntime permission. Preserve the installed owner's exact result.
    public func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(tools)
    }

    /// 生产请求构建器：browser 请求从显式 URL 提取 network domain，
    /// 让空域名 allowlist 对真实网络调用保持 fail-closed。
    public static let productionRequestBuilder: @Sendable (String, [String: Any]) -> PolicyRequest = { name, input in
        let rawURL = (input["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var domain: String?
        if name == WebFetchToolContract.toolName {
            domain = try? WebFetchToolContract.normalizedURLHost(input)
        } else if (name == BrowserTool.toolName || name == BrowserTool.legacyToolName), !rawURL.isEmpty {
            if let url = URL(string: rawURL), let host = url.host, !host.isEmpty {
                domain = host.lowercased()
            } else if !rawURL.contains(":") && !rawURL.contains("/") {
                domain = rawURL.lowercased()
            }
        }
        return PolicyRequest(
            capabilityID: name,
            // 11/16：MCP 工具的 path 由 MCP 服务器自己的访问边界决定，不当作本机文件路径检查。
            filePath: name.hasPrefix("mcp_") ? nil : input["path"] as? String,
            networkDomain: domain,
            estimatedCost: 1
        )
    }

    /// 默认请求构建器：capabilityID = 工具名，filePath = input["path"]，
    /// 单次调用计费 1；不推断网络域（测试/兼容 seam）。
    public static let defaultRequestBuilder: @Sendable (String, [String: Any]) -> PolicyRequest = { name, input in
        PolicyRequest(
            capabilityID: name,
            // 11/16：MCP 工具的 path 由 MCP 服务器自己的访问边界决定，不当作本机文件路径检查。
            filePath: name.hasPrefix("mcp_") ? nil : input["path"] as? String,
            estimatedCost: 1
        )
    }

    /// 当前 lease 快照（revoke 后 revoked == true）。
    public var currentLease: AutonomyLease? {
        lock.withLock { leaseValue }
    }

    /// 通过 policy 门禁并实际交给 base 的调用数（底层执行数）。
    public var acceptedExecutionCount: Int {
        lock.withLock { _acceptedExecutionCount }
    }

    /// 被 policy 门禁拒绝、从未触碰 base 的调用数。
    public var deniedExecutionCount: Int {
        lock.withLock { _deniedExecutionCount }
    }

    /// Most recent capability denial, retained as bounded, secret-free data.
    /// Non-capability policy denials do not overwrite this receipt.
    public var lastCapabilityDenialReceipt: CapabilityDenialReceipt? {
        lock.withLock { _lastCapabilityDenialReceipt }
    }

    /// 撤销当前 lease —— 后续调用一律 `leaseRevoked` 拒绝。
    public func revokeLease() {
        lock.withLock { leaseValue?.revoke() }
    }

    public func execute(name: String, input: [String: Any]) async throws -> String {
        try await perform(name: name, input: input) { name, input in
            try await base.execute(name: name, input: input)
        }
    }

    public var currentBuiltinOwner: BuiltinToolExecutor? {
        (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    public func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await perform(name: name, input: input) { name, input in
            try await executeThroughBoundBuiltinOwner(base, owner: owner, name: name, input: input)
        }
    }

    /// Capability-aware `session_read` seam (S3 hardening).
    ///
    /// The policy gate runs exactly as for `execute` — capability / lease /
    /// scope / budget / deadline are checked before the base is touched — and
    /// only then is the typed capability forwarded to an aware base. The model
    /// tool input never carries the capability; a base that is not
    /// capability-aware fails closed with `capabilityRequired` instead of
    /// falling back to the legacy `[String: Any]` entry point.
    public func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        try await perform(name: SessionReadTool.toolName, input: input) { name, input in
            guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
                throw CrossSessionReadAuthorizationError.capabilityRequired
            }
            return try await aware.executeSessionRead(
                input: input,
                authorization: authorization,
                context: context,
                now: now
            )
        }
    }

    /// Shared policy gate + accounting path for both execution entry points.
    /// `action` runs only after the gate passes and counts as one accepted
    /// execution; the typed capability never enters this seam as raw input.
    private func perform(
        name: String,
        input: [String: Any],
        action: (String, [String: Any]) async throws -> String
    ) async throws -> String {
        var builtRequest = requestBuilder(name, input)
        if name == WebFetchToolContract.toolName {
            // web_fetch always carries its real URL host, even if an injected
            // generic builder omitted networkDomain. Invalid URLs fail before
            // any budget reservation or call to the fetch producer.
            let host = try WebFetchToolContract.normalizedURLHost(input)
            builtRequest = PolicyRequest(capabilityID: builtRequest.capabilityID,
                scopeID: builtRequest.scopeID, filePath: builtRequest.filePath,
                networkDomain: host, estimatedCost: builtRequest.estimatedCost,
                activeTasks: builtRequest.activeTasks, autonomyLevel: builtRequest.autonomyLevel,
                requestedUntil: builtRequest.requestedUntil)
        }
        // 绕过模式（已确认）下文件路径不再受 goal.fileRoots 限制；
        // 系统底线与凭据保护在 Composer 授权与 BuiltinToolExecutor 里判断。
        let approvedOutsideRead = builtRequest.filePath.map {
            ApprovedFileReadScope.permits(tool: name, path: $0)
                || ApprovedFileWriteScope.permits(tool: name, path: $0)
        } ?? false
        let ownedArtifactRead: Bool
        if name == "file_read", let path = builtRequest.filePath {
            ownedArtifactRead = try OwnedOutputArtifactReadContext.resolve(path: path) != nil
        } else { ownedArtifactRead = false }
        let request: PolicyRequest = (BypassOpenScope.isActive || approvedOutsideRead || ownedArtifactRead) && builtRequest.filePath != nil
            ? PolicyRequest(
                capabilityID: builtRequest.capabilityID, scopeID: builtRequest.scopeID,
                filePath: nil, networkDomain: builtRequest.networkDomain,
                estimatedCost: builtRequest.estimatedCost, activeTasks: builtRequest.activeTasks,
                autonomyLevel: builtRequest.autonomyLevel, requestedUntil: builtRequest.requestedUntil)
            : builtRequest

        // 1) Capability 门禁：MCP 每次先查当前 bridge，即使名称曾被注册
        //    或出现在旧 goal allowlist。其他工具保留 goal 优先、resolver
        //    兜底语义。动态 capability 仅扩展影子 goal 的 allowlist。
        if name.hasPrefix("mcp_"), let resolver = capabilityResolver,
           (try? await resolver.resolvesCapability(name)) != true {
            return try deny(.capabilityNotAllowed, capabilityID: request.capabilityID)
        }
        var effectiveGoal: GoalEnvelope
        // MCP names can remain in a long-lived goal after the dispatch cache
        // learned them. They are still dynamic capabilities, so a stale goal
        // allowlist must not bypass the current descriptor/grant resolver.
        let requiresLiveResolution = request.capabilityID.hasPrefix("mcp_")
        if !requiresLiveResolution && goal.allowedCapabilities.contains(request.capabilityID) {
            effectiveGoal = goal
        } else if let resolver = capabilityResolver,
                  (try? await resolver.resolvesCapability(request.capabilityID)) == true {
            if goal.allowedCapabilities.contains(request.capabilityID) {
                effectiveGoal = goal
            } else {
                effectiveGoal = GoalEnvelope(
                    goalID: goal.goalID,
                    scopeID: goal.scopeID,
                    allowedCapabilities: goal.allowedCapabilities.union([request.capabilityID]),
                    fileRoots: goal.fileRoots,
                    networkDomains: goal.networkDomains,
                    budget: goal.budget,
                    deadline: goal.deadline,
                    concurrencyLimit: goal.concurrencyLimit,
                    autonomyLevel: goal.autonomyLevel,
                    creatorID: goal.creatorID,
                    createdAt: goal.createdAt
                )
            }
        } else {
            return try deny(.capabilityNotAllowed, capabilityID: request.capabilityID)
        }

        if name == WebFetchToolContract.toolName, let permit = WebFetchPinnedCallContext.current {
            try permit.validatePolicyInput(input)
            guard request.networkDomain == permit.binding.endpoint.host else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            // Per-call evaluation only. The original parent Goal and lease are
            // immutable; budget/scope/revision/expiry checks below stay intact.
            effectiveGoal = GoalEnvelope(goalID: effectiveGoal.goalID, scopeID: effectiveGoal.scopeID,
                allowedCapabilities: effectiveGoal.allowedCapabilities, fileRoots: effectiveGoal.fileRoots,
                networkDomains: effectiveGoal.networkDomains.union([permit.binding.endpoint.host]),
                budget: effectiveGoal.budget, deadline: effectiveGoal.deadline,
                concurrencyLimit: effectiveGoal.concurrencyLimit, autonomyLevel: effectiveGoal.autonomyLevel,
                creatorID: effectiveGoal.creatorID, createdAt: effectiveGoal.createdAt)
        }

        // 2) Include accepted work still awaiting its base result. The live
        // consumption check below reserves against the same total atomically.
        let (lease, spent, reserved, active) = lock.withLock {
            (leaseValue, spentBudget, reservedBudget, activeTasks)
        }
        guard let lease else { return try deny(.invalidLease) }

        // 3) PolicyRuntime 校验（唯一强制边界，见 PolicyRuntime.validatePolicy）。
        let effectiveRequest = PolicyRequest(
            capabilityID: request.capabilityID,
            scopeID: request.scopeID,
            filePath: request.filePath,
            networkDomain: request.networkDomain,
            estimatedCost: request.estimatedCost,
            activeTasks: active,
            autonomyLevel: request.autonomyLevel,
            requestedUntil: request.requestedUntil
        )
        let result = validatePolicy(
            goal: effectiveGoal,
            lease: lease,
            request: effectiveRequest,
            now: clock(),
            spentBudget: spent + reserved
        )
        if case .failure(let violation) = result {
            return try deny(violation, capabilityID: request.capabilityID)
        }

        // 4) Re-read the live lease at the consumption boundary. Validation
        // above uses a snapshot because it may follow an async capability
        // resolver; revoke/expiry must be checked again before reserving the
        // execution. The lock linearizes this reservation with revokeLease:
        // revocation that wins before reservation prevents the base call,
        // while revocation after reservation is already after the execution
        // boundary and cannot retroactively cancel an accepted operation.
        let consumeNow = clock()
        let consumeResult: Result<Void, PolicyViolation> = lock.withLock {
            guard let currentLease = leaseValue else {
                return .failure(.invalidLease)
            }
            let consumeRequest = PolicyRequest(
                capabilityID: request.capabilityID,
                scopeID: request.scopeID,
                filePath: request.filePath,
                networkDomain: request.networkDomain,
                estimatedCost: request.estimatedCost,
                activeTasks: activeTasks,
                autonomyLevel: request.autonomyLevel,
                requestedUntil: request.requestedUntil
            )
            let result = validatePolicy(
                goal: effectiveGoal,
                lease: currentLease,
                request: consumeRequest,
                now: consumeNow,
                spentBudget: spentBudget + reservedBudget
            )
            guard case .success = result else { return result }
            activeTasks += 1
            reservedBudget += max(0, request.estimatedCost)
            _acceptedExecutionCount += 1
            return .success(())
        }
        if case .failure(let violation) = consumeResult {
            return try deny(violation, capabilityID: request.capabilityID)
        }
        defer { lock.withLock { activeTasks = max(0, activeTasks - 1) } }
        do {
            let output = try await action(name, input)
            lock.withLock {
                let cost = max(0, request.estimatedCost)
                reservedBudget = max(0, reservedBudget - cost)
                spentBudget += cost
            }
            return output
        } catch {
            // Preserve successful-return accounting. Cancellation alone does
            // not release a running action; only its actual thrown completion
            // gets here. This does not assert that a failed tool had no effects
            // or external charges, which this estimated-cost seam cannot know.
            lock.withLock {
                reservedBudget = max(0, reservedBudget - max(0, request.estimatedCost))
            }
            throw error
        }
    }

    private func deny(_ violation: PolicyViolation, capabilityID: String? = nil) throws -> String {
        lock.withLock {
            _deniedExecutionCount += 1
            if violation == .capabilityNotAllowed, let capabilityID {
                _lastCapabilityDenialReceipt = CapabilityDenialReceipt(
                    capabilityID: capabilityID,
                    reason: violation
                )
            }
        }
        throw PolicyEnforcedToolExecutorError.policyViolation(violation)
    }
}
