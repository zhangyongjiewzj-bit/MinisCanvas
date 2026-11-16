import Foundation
import CryptoKit
import Darwin

private struct BrowserApprovalIdentity: Encodable {
    let callID: String
    let toolName: String
    let inputDigest: String
}

/// These facts describe the result of the existing authority checks. They
/// cannot approve a call or replace an ApprovalReceipt.
enum ApprovalAuthorityObservation {
    static func emit(_ stage: ApprovalLifecycleStage, for request: ApprovalRequest) {
        emit(stage, for: request, using: ApprovalPresentationContext.current)
    }

    static func emit(
        _ stage: ApprovalLifecycleStage,
        for request: ApprovalRequest,
        using context: ApprovalPresentationContext?
    ) {
        guard let context,
              let fact = context.makeFact(for: request, stage: stage) else { return }
        context.eventSink(fact)
    }

    static func rejected(_ error: Error, decision: ApprovalDecision? = nil) -> ApprovalLifecycleStage {
        if error is CancellationError || error is InterruptedError {
            return .authorityCancelled
        }
        if let error = error as? ApprovalError {
            switch error {
            case .expired(_): return .authorityExpired
            case .revoked(_): return .authorityRevoked
            case .cancelled(_): return .authorityCancelled
            default: break
            }
        }
        if let error = error as? ComposerAuthorizationError {
            switch error {
            case .factsExpired: return .authorityExpired
            case .authorizationRevoked: return .authorityRevoked
            default: break
            }
        }
        if let error = error as? ToolExecutorError,
           case .toolTimeout(_) = error {
            return .authorityExpired
        }
        // A pinned destination failure does not reverse an already approved
        // human decision. This observation grants no execution/network permit.
        if decision?.approved == true, decision?.status == .approved, error is WebFetchPinnedError {
            return .authorityApproved
        }
        guard let decision, !decision.approved else { return .authorityDenied }
        switch decision.status {
        case .expired: return .authorityExpired
        case .revoked: return .authorityRevoked
        case .cancelled: return .authorityCancelled
        default: return .authorityDenied
        }
    }
}

// MARK: - Approval Delegate

/// Backs the approval UI (MinisCanvasApp wires a SwiftUI sheet/prompt here).
/// The delegate is consulted for every `alwaysAsk` tool call.
public protocol ApprovalDelegate: Sendable {
    /// Present `request` to the user (or an automated policy) and return the
    /// verdict. Must not throw — decisions are communicated via
    /// `ApprovalDecision.approved`.
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Process-local replay fence for immutable approval identities. A reference
/// store makes copies of `ApprovalGate` share the same one-time consumption
/// decision while keeping the gate value type and its public API intact.
private final class ApprovalIdentityConsumptionStore: @unchecked Sendable {
    static let shared = ApprovalIdentityConsumptionStore()

    private let lock = NSLock()
    private var consumed: Set<String> = []

    func contains(_ identityDigest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return consumed.contains(identityDigest)
    }

    func consume(_ identityDigest: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard consumed.insert(identityDigest).inserted else { return false }
        return true
    }
}

// MARK: - Approval Gate

/// Gate that decides whether a tool call may execute (E1 工具审批流).
///
/// The gate itself is policy-only: it classifies a call (`shouldAsk`), builds
/// a redacted `ApprovalRequest`, and either approves automatically, asks the
/// `ApprovalDelegate`, or denies outright — throwing
/// `ApprovalError.denied(reason:)` on refusal.
///
///     let gate = ApprovalGate(delegate: uiDelegate)          // default policy
///     let gate = ApprovalGate(policyByTool: ["shell_execute": .deny])
///
/// The `AgentLoop` consults an optional `approvalGate` before each tool call.
/// The gate itself fails closed; callers must still treat a missing gate as a
/// composition error because an optional hook cannot intercept execution.
public struct ApprovalGate: Sendable {

    /// Policy overrides keyed by tool name. Tools not present fall back to
    /// `.alwaysAsk` (safe default: unknown tools are treated as risky).
    public var terminalPolicySnapshot: TerminalPolicySnapshot = .default
    /// Resolves an MCP server id to its display name for the removal approval card.
    public var mcpServerDisplayName: (@Sendable (String) -> String?)?
    /// Session id -> title for the conversation_settings session-management cards.
    public var sessionTitles: SessionTitleDirectory?

    private var configuredPolicyByTool: [String: ApprovalPolicy]

    public var policyByTool: [String: ApprovalPolicy] {
        get { configuredPolicyByTool }
        set {
            configuredPolicyByTool = newValue
            // Dictionary writeback cannot identify an equal-value assignment.
            // Keep every configured policy and discard only the new waiver.
            globalAlwaysAskFileOverlay.removeAll()
            sessionCreatePolicyIsGloballyDerived = false
        }
    }

    // Ordinary file mutations may defer to the interactive Composer mode.
    // Keep their global prompt separate so a per-tool assignment of the same
    // .alwaysAsk value still carries independent authority.
    private var globalAlwaysAskFileOverlay: Set<String> = []
    private var sessionCreatePolicyIsGloballyDerived = false

    private struct OrdinaryChildPolicy: Sendable {
        let configuredPolicyByTool: [String: ApprovalPolicy]
        let globalAlwaysAskFileOverlay: Set<String>
        let sessionCreatePolicyIsGloballyDerived: Bool
    }

    private var ordinaryChildPolicy: OrdinaryChildPolicy?

    /// Preserve the ordinary policy when preparing a legacy unattended top-level gate.
    public func applyingLegacyUnattendedAutoApproval() -> ApprovalGate {
        guard ordinaryChildPolicy == nil else { return self }
        var copy = self
        copy.ordinaryChildPolicy = OrdinaryChildPolicy(
            configuredPolicyByTool: configuredPolicyByTool,
            globalAlwaysAskFileOverlay: globalAlwaysAskFileOverlay,
            sessionCreatePolicyIsGloballyDerived: sessionCreatePolicyIsGloballyDerived
        )
        for tool in globalAlwaysAskFileOverlay where configuredPolicyByTool[tool] == .alwaysAsk {
            copy.setPolicy(.autoApprove, for: tool)
        }
        if sessionCreatePolicyIsGloballyDerived, configuredPolicyByTool["session_create"] == .alwaysAsk {
            copy.setPolicy(.autoApprove, for: "session_create")
        }
        return copy
    }

    func liftedUnattendedFileApproval(for tool: String) -> Bool {
        guard let ordinaryChildPolicy else { return false }
        return ordinaryChildPolicy.globalAlwaysAskFileOverlay.contains(tool)
            && ordinaryChildPolicy.configuredPolicyByTool[tool] == .alwaysAsk
            && configuredPolicyByTool[tool] == .autoApprove
    }

    /// Restore the ordinary strategy on an inherited child copy.
    public func restoringOrdinaryChildPolicy() -> ApprovalGate {
        guard let ordinaryChildPolicy else { return self }
        var copy = self
        copy.configuredPolicyByTool = ordinaryChildPolicy.configuredPolicyByTool
        copy.globalAlwaysAskFileOverlay = ordinaryChildPolicy.globalAlwaysAskFileOverlay
        copy.sessionCreatePolicyIsGloballyDerived = ordinaryChildPolicy.sessionCreatePolicyIsGloballyDerived
        copy.ordinaryChildPolicy = nil
        return copy
    }

    /// Delegate consulted for `alwaysAsk` calls. May be `nil` when the gate is
    /// used for classification only (`shouldAsk` / `riskLevel`); an `alwaysAsk`
    /// call without a delegate is denied.
    public var delegate: (any ApprovalDelegate)?

    /// Optional sink for immutable, redacted approval facts.
    /// The sink must finish before the approved call is dispatched. A failed
    /// delivery is an approval failure, including browser target replacement.
    public var onApprovalReceipt: (@Sendable (ApprovalReceipt) async throws -> Void)?

    /// Shared replay fence for bound approvals. This is intentionally not
    /// persisted: each process lifetime gets one lease-consumption boundary.
    private let identityConsumptionStore: ApprovalIdentityConsumptionStore

    /// - Parameters:
    ///   - policyByTool: per-tool overrides merged on top of
    ///     `ApprovalGate.defaultPolicies` (pass `[:]` to keep defaults).
    ///   - delegate: approval delegate (may be `nil` for classification-only use).
    public init(
        policyByTool overrides: [String: ApprovalPolicy] = [:],
        delegate: (any ApprovalDelegate)? = nil,
        onApprovalReceipt: (@Sendable (ApprovalReceipt) async throws -> Void)? = nil
    ) {
        self.configuredPolicyByTool = ApprovalGate.defaultPolicies.merging(overrides) { _, new in new }
        self.delegate = delegate
        self.onApprovalReceipt = onApprovalReceipt
        self.identityConsumptionStore = .shared
    }

    /// Build a gate from the user-facing global policy. Per-tool overrides
    /// remain available for capability-specific policy tightening.
    public init(
        policy: ApprovalPolicy,
        delegate: (any ApprovalDelegate)? = nil,
        onApprovalReceipt: (@Sendable (ApprovalReceipt) async throws -> Void)? = nil
    ) {
        self.init(
            policyByTool: Self.policyOverrides(for: policy),
            delegate: delegate,
            onApprovalReceipt: onApprovalReceipt
        )
        if policy == .alwaysAsk || policy == .riskOnlyAsk {
            globalAlwaysAskFileOverlay = ["file_write", "file_edit"]
        }
    }

    /// Set an explicit tool policy without losing the origin of unrelated policies.
    public mutating func setPolicy(_ policy: ApprovalPolicy, for tool: String) {
        configuredPolicyByTool[tool] = policy
        globalAlwaysAskFileOverlay.remove(tool)
        if tool == "session_create" { sessionCreatePolicyIsGloballyDerived = false }
    }

    /// Record the policy derived from the user's global setting for session creation.
    public mutating func setGloballyDerivedSessionCreatePolicy(_ policy: ApprovalPolicy) {
        setPolicy(policy, for: "session_create")
        sessionCreatePolicyIsGloballyDerived = true
    }

    // MARK: Default policy

    /// Default per-tool policy (E1 spec):
    /// - File mutations always ask; shell input risk asks except finite read-only Git forms.
    /// - `file_read` / `browser` / `speech` → `autoApprove` (low risk); `session_read` always asks
    /// - `web_search` reads the network but not the filesystem → auto.
    /// - `orchestrate` (P3-AGENT-01): the opt-in tool ships with MinisCore
    ///   (`OrchestrationToolExecutor.makeDefinition`), so every default-shaped
    ///   gate — including the `ApprovalGate(delegate:)` instances built by
    ///   `SecureAgentLoopFactory` and the `AgentOrchestrator` default — must
    ///   consult the delegate instead of fail-closing at `isKnownTool` with
    ///   "Unknown capability" before any affirmative approval is possible.
    ///   `.alwaysAsk` keeps the tool never autonomous.
    public static let defaultPolicies: [String: ApprovalPolicy] = [
        // High risk — always ask.
        "file_write": .alwaysAsk,
        "file_edit": .alwaysAsk,
        "file_delete": .alwaysAsk,
        // Concrete shell input remains high risk except the finite read-only Git forms.
        "shell_execute": .autoApprove,
        "shell_stop": .autoApprove,
        "shell_output": .autoApprove,
        "shell": .alwaysAsk,
        // Low risk — auto approve.
        AskUserQuestionTool.toolName: .autoApprove,
        SessionTodoProgress.toolName: .autoApprove,
        ContextCompactTool.toolName: .autoApprove,
        "file_read": .autoApprove,
        "file_grep": .autoApprove,
        "file_glob": .autoApprove,
        "browser": .autoApprove,
        "browser_use": .autoApprove,
        "speech": .autoApprove,
        "web_search": .autoApprove,
        "web_fetch": .alwaysAsk,
        "session_read": .alwaysAsk,
        // Read is authorized by the mounted sessions directory; send is an
        // outbound, irrevocable message and is asked on every call.
        ExternalSessionToolNames.read: .autoApprove,
        ExternalSessionToolNames.send: .alwaysAsk,
        // 只读技能内容（第七版）：给 skill_update/skill_delete 取当前哈希。
        SkillMaintenanceTool.readName: .autoApprove,
        OrchestrationToolExecutor.resultToolName: .autoApprove,
        OrchestrationToolExecutor.toolName: .alwaysAsk,
        BL6SettingsToolApproval.catalogToolName: .alwaysAsk,
        BL6SettingsToolApproval.toolName: .alwaysAsk,
    ]

    /// Default risk table (drives `ApprovalRequest.riskLevel` styling).
    public static let riskByTool: [String: ApprovalRiskLevel] = [
        "file_write": .high,
        "file_edit": .high,
        "file_delete": .high,
        "shell_execute": .high,
        "shell_stop": .low,
        "shell_output": .low,
        "shell": .high,
        AskUserQuestionTool.toolName: .low,
        SessionTodoProgress.toolName: .low,
        ContextCompactTool.toolName: .low,
        "file_read": .low,
        "file_grep": .low,
        "file_glob": .low,
        "browser": .low,
        "browser_use": .low,
        "speech": .low,
        "web_search": .low,
        "web_fetch": .medium,
        "session_read": .low,
        ExternalSessionToolNames.read: .low,
        SkillMaintenanceTool.readName: .low,
        ExternalSessionToolNames.send: .high,
        OrchestrationToolExecutor.resultToolName: .low,
        OrchestrationToolExecutor.toolName: .medium,
        BL6SettingsToolApproval.catalogToolName: .low,
        BL6SettingsToolApproval.toolName: .high,
    ]

    /// Read-only file tools that never need a card under the default "ask every time"
    /// policy (user decision 2026-11-16, aligned with Claude Code). Input risk still applies.
    public static let readOnlyFileToolNames: Set<String> = ["file_read", "file_grep", "file_glob"]

    /// Expand one user-facing policy into the explicit per-tool table used by
    /// the gate. Unknown tools remain fail-closed regardless of this table.
    public static func policyOverrides(for policy: ApprovalPolicy) -> [String: ApprovalPolicy] {
        switch policy {
        case .alwaysAsk:
            // 用户 2026-11-10 决定：外部会话读取免批；授权来自用户挂载 sessions 目录，send 仍每次询问。
            // 第七版旅程：向用户提问（ask_user）本身就是在等用户，不能先再弹一张审批卡；
            // 读技能（skill_read）只读、给 skill_update 取哈希用，同样免批。
            // 用户 2026-11-16 决定（对齐 Claude Code）：授权目录内的只读文件工具不弹卡；压缩上下文也不弹卡（用户追加确认）。
            // 敏感文件、相对路径、含 .. 的路径仍由 inputRiskLevel 判高风险而询问；授权根与拒绝目录照旧生效。
            return defaultPolicies.keys.reduce(into: [:]) { result, name in
                result[name] = name == SessionTodoProgress.toolName
                    || name == ExternalSessionToolNames.read
                    || name == AskUserQuestionTool.toolName
                    || name == SkillMaintenanceTool.readName
                    || Self.readOnlyFileToolNames.contains(name)
                    || name == ContextCompactTool.toolName ? .autoApprove : .alwaysAsk
            }
        case .autoApprove:
            return defaultPolicies.keys.reduce(into: [:]) { result, name in
                result[name] = name == BL6SettingsToolApproval.toolName
                    || name == BL6SettingsToolApproval.catalogToolName
                    || name == "file_delete"
                    || name == ExternalSessionToolNames.send ? .alwaysAsk : .autoApprove
            }
        case .riskOnlyAsk:
            return defaultPolicies.keys.reduce(into: [:]) { result, name in
                result[name] = (riskByTool[name] == .high && name != "shell_execute")
                    || name == BL6SettingsToolApproval.catalogToolName ? .alwaysAsk : .autoApprove
            }
        case .deny, .never:
            return defaultPolicies.keys.reduce(into: [:]) { result, name in
                result[name] = .deny
            }
        }
    }

    // MARK: Classification

    /// Effective policy for `tool`, honoring `policyByTool` overrides.
    public func policy(for tool: String) -> ApprovalPolicy {
        policyByTool[tool] ?? .alwaysAsk
    }

    /// Risk level for `tool` (`.medium` for unclassified/unknown tools).
    public func riskLevel(for tool: String) -> ApprovalRiskLevel {
        ApprovalGate.riskByTool[tool] ?? .medium
    }

    /// Whether the tool name is explicitly known to this gate. Unknown
    /// capability descriptions are untrusted data and are never executable.
    public func isKnownTool(_ tool: String) -> Bool {
        policyByTool[tool] != nil
    }

    /// Classify the concrete input as well as the tool name. This is kept
    /// deterministic and side-effect free so it can be tested independently.
    public static func inputRiskLevel(tool: String, input: [String: Any]) -> ApprovalRiskLevel {
        let tool = tool.lowercased()
        if tool == "shell_execute", let command = input["command"] as? String,
           GitWorkflowPolicy.automaticallyAllows(command: command) {
            return .low
        }
        if tool == "shell" || tool == "shell_execute" {
            return .high
        }

        if tool == "orchestrate", !Self.externalOrchestrationTasks(input).isEmpty {
            return .high
        }

        // D-BROWSER-07: browser side effects (click/type/download/upload and
        // any unclassified future action) always require an explicit
        // Policy/Approval decision, even when the tool-level policy is
        // `.autoApprove` — `shouldAsk` consults input risk and the gate
        // routes `.autoApprove where request.requiresApproval` to the
        // delegate. Read actions (navigate/back/read/screenshot) keep the
        // existing low-risk behavior.
        if BrowserSideEffectPolicy.inputRequiresApproval(tool: tool, input: input) {
            return .high
        }

        if let path = input["path"] as? String {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || !trimmed.hasPrefix("/") || trimmed.contains("..") || trimmed.contains("\0") {
                return .high
            }
            if ["file_write", "file_edit", "file_delete"].contains(tool),
               SensitiveFilePolicy.isProtectedGitWritePath(trimmed) {
                return .high
            }
            if SensitiveFilePolicy.contains(trimmed) {
                return .high
            }
        } else if ["file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete"].contains(tool) {
            return .high
        }

        if tool == "browser" || tool == "browser_use" || tool == "web_search",
           let urlString = (input["url"] as? String) ?? (input["query"] as? String),
           urlString.contains(":") {
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host, !host.isEmpty else {
                return .high
            }
            let hostLower = host.lowercased()
            if hostLower == "localhost" || hostLower.hasPrefix("127.") || hostLower == "::1" {
                return .high
            }
        }

        if input.keys.contains(where: { key in
            let key = key.lowercased()
            return key.contains("token") || key.contains("password") || key.contains("secret")
                || key.contains("cookie") || key.contains("authorization")
        }) {
            return .high
        }
        return .low
    }

    /// User-entered confirmation names override finite read-only shell shortcuts.
    /// This is also mandatory-human input to Composer, before grants or hooks.
    func requiresExplicitShellConfirmation(tool: String, input: [String: Any]) -> Bool {
        guard tool == "shell_execute", let command = input["command"] as? String else { return false }
        let inspected = TerminalGuard.inspect(command)
        guard inspected.isAllowed,
              let executable = TerminalGuard.effectiveExecutable(in: inspected.words)
                .flatMap(TerminalPolicySnapshot.normalizeCommandName) else { return false }
        return terminalPolicySnapshot.explicitConfirmationCommands.contains(executable)
    }

    /// Whether a call to `tool` with `input` requires human approval.
    ///
    public func shouldAsk(tool: String, input: [String: Any]) -> Bool {
        shouldAsk(tool: tool, input: input, deferringGlobalFilePromptToComposer: false)
    }

    func shouldAsk(tool: String, input: [String: Any], deferringGlobalFilePromptToComposer: Bool) -> Bool {
        if tool == "shell_execute", let command = input["command"] as? String,
           terminalPolicySnapshot.classify(command: command) == .denied { return true }
        let globalPromptDeferred = deferringGlobalFilePromptToComposer
            && globalAlwaysAskFileOverlay.contains(tool) && policyByTool[tool] == .alwaysAsk
        return requiresExplicitShellConfirmation(tool: tool, input: input)
            || (!globalPromptDeferred && policy(for: tool) == .alwaysAsk)
            || Self.inputRiskLevel(tool: tool, input: input) != .low
    }

    // MARK: Gating

    /// Redacted one-line digest of `input` for the approval prompt.
    ///
    /// Masks large payloads (`content`, `new_string`, `old_string`) and
    /// likely secrets by key name; every shown string value is additionally
    /// passed through `ContentSecretRedactor` so embedded secret VALUES
    /// (Bearer tokens, API keys, cookies, URL userinfo) inside otherwise
    /// non-secret text (e.g. a `command`) never reach the prompt; truncates
    /// every other string to 80 chars.
    public static func makeInputSummary(_ input: [String: Any]) -> String {
        guard !input.isEmpty else { return "(no input)" }
        var parts: [String] = []
        for (key, value) in input.sorted(by: { $0.key < $1.key }) {
            let normalizedKey = key.lowercased()
            let sensitive = normalizedKey == "content"
                || normalizedKey == "new_string"
                || normalizedKey == "old_string"
                || normalizedKey.contains("api_key")
                || normalizedKey.contains("token")
                || normalizedKey.contains("password")
                || normalizedKey.contains("secret")
                || normalizedKey.contains("authorization")
                || normalizedKey.contains("cookie")
            if sensitive {
                parts.append("\(key): <redacted>")
            } else if let string = value as? String {
                let safe = string.map { $0.isNewline || $0.isWhitespace && $0 != " " ? " " : $0 }
                    .reduce(into: "") { $0.append($1) }
                // Content-level redaction: a non-secret-looking key can still
                // carry an embedded Bearer/API-key/cookie/userinfo value.
                let redacted = ContentSecretRedactor.redact(safe)
                let trimmed = redacted.count > 80 ? String(redacted.prefix(80)) + "…" : redacted
                parts.append("\(key): \(trimmed)")
            } else if value is [String: Any] || value is [Any] {
                parts.append("\(key): <structured input>")
            } else {
                let valueDescription = String(describing: value)
                    .replacingOccurrences(of: "\n", with: " ")
                let redacted = ContentSecretRedactor.redact(valueDescription)
                let trimmed = redacted.count > 80 ? String(redacted.prefix(80)) + "…" : redacted
                parts.append("\(key): \(trimmed)")
            }
        }
        let summary = parts.joined(separator: ", ")
        return summary.count > 512 ? String(summary.prefix(512)) + "…" : summary
    }

    /// A scope-only display, not a grant or an alternative request validator.
    /// Keep complete scope values; task prose and arbitrary JSON never enter it.
    private static func normalizedOrchestrationInput(_ input: [String: Any]) -> [String: Any]? {
        guard let encoded = input["tasks"] as? String else { return input }
        guard let data = encoded.data(using: .utf8),
              let tasks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var normalized = input
        normalized["tasks"] = tasks
        return normalized
    }

    private static func externalOrchestrationTasks(_ input: [String: Any]) -> [OrchestrateRequestV1.Task] {
        guard let normalized = normalizedOrchestrationInput(input),
              let request = try? OrchestrateRequestV1.decode(input: normalized,
                    maxTasks: OrchestrationToolExecutor.maxTasks) else { return [] }
        return request.tasks.filter { $0.agent?.hasPrefix("external:") == true }
    }

    private static func externalOrchestrationDisplayName(_ agent: String?) -> String? {
        switch agent {
        case "external:claude": "claude"
        case "external:codex": "codex"
        case "external:hermes": "hermes"
        default: nil
        }
    }

    private static func externalOrchestrationDisplayText(_ value: String, limit: Int) -> String {
        let safe = ContentSecretRedactor.redact(value)
        let singleLine = String(safe.map { character in
            character.isNewline || character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                ? " " : character
        })
        return singleLine.count <= limit ? singleLine : String(singleLine.prefix(limit)) + "…"
    }

    private static func externalOrchestrationWarning(_ tasks: [OrchestrateRequestV1.Task]) -> String {
        guard !tasks.isEmpty else { return "" }
        let labels = tasks.map { externalOrchestrationDisplayName($0.agent) ?? "其他外部智能体" }
        let heading = "启动外部程序：" + Set(labels).sorted().joined(separator: "、")
        let warning = "外部程序以你的用户身份在本机运行，可以读写你有权限访问的文件，不受本应用的文件范围、Hooks 和审批约束。"
        let descriptions = tasks.map { task in
            let title = externalOrchestrationDisplayText(task.title, limit: 80)
            let instructions = externalOrchestrationDisplayText(task.instructions, limit: 160)
            let agent = externalOrchestrationDisplayName(task.agent).map { "external:" + $0 } ?? "其他外部智能体"
            return "\(title)（\(agent)）：\(instructions)"
        }
        return ([heading, warning] + descriptions).joined(separator: "\n") + "\n\n"
    }

    private static func orchestrateScopeSummary(_ input: [String: Any]) -> String {
        let unavailable = "请求授权范围（非实际授权）：范围未能提取；仍由执行器校验。"
        guard let normalized = normalizedOrchestrationInput(input) else { return unavailable }
        guard let decoded = try? OrchestrateRequestV1.decode(input: normalized,
                    maxTasks: OrchestrationToolExecutor.maxTasks),
              let tasks = normalized["tasks"] as? [[String: Any]] else { return unavailable }
        let rows: [[String: Any]] = tasks.enumerated().map { index, task in
            let request = decoded.tasks[index].resourceRequest
            var row: [String: Any] = [
                "task_index": index + 1,
                "task_id_summary": makeInputSummary(["id": decoded.tasks[index].id]),
            ]
            var redactedScope = false
            func safe(_ value: String) -> String {
                let result = ContentSecretRedactor.redact(value)
                if result != value { redactedScope = true }
                return result
            }
            for key in ["allowed_tool_names", "allowed_read_roots", "allowed_write_roots", "working_directory"] {
                if let values = task[key] as? [String] {
                    row[key] = values.map(safe)
                } else if let value = task[key] as? String {
                    row[key] = safe(value)
                } else {
                    switch key {
                    case "allowed_tool_names": row[key] = "未指定，继承父已授权工具"
                    case "allowed_write_roots": row[key] = "未指定，继承父工作目录作为写根，仍受父授权范围限制"
                    case "working_directory": row[key] = "未指定，使用父工作目录"
                    default: row[key] = "未指定，按下方读根规则处理"
                    }
                }
            }
            // Match the existing executor's empty-read behavior: even explicit
            // [] inherits parentCwd when tool names themselves are inherited.
            let inheritsReads = request == nil
                || request?.inheritsToolNames == true && request?.allowedReadRoots.isEmpty == true
            row["allowed_read_roots_rule"] = inheritsReads
                ? "读根为空且工具范围未指定时，继承父工作目录；显式 [] 也适用"
                : "读根使用所列数组；未指定解码为空数组，不继承读根"
            if task["allowed_write_roots"] as? [String] == [] {
                row["allowed_write_roots_rule"] = "显式 []：无写根，不继承"
            }
            if redactedScope {
                row["scope_display_warning"] = "范围值含敏感内容，已脱敏；显示值不是完整原值"
            }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return unavailable }
        return "请求授权范围（非实际授权；缺省语义见各字段说明，仍受父权限与执行器校验）：\n" + text
    }

    /// Readable card for conversation_settings mcp.servers.add/remove: full
    /// name, command and args, and environment variable NAMES only (never values).
    func mcpServerManagementSummary(_ input: [String: Any]) -> String? {
        guard let changes = input["changes"] as? [String: Any] else { return nil }
        func fields(_ key: String) -> [String: Any]? {
            (changes[key] as? [String: Any])?["object"] as? [String: Any]
        }
        func text(_ fields: [String: Any], _ key: String) -> String {
            ((fields[key] as? [String: Any])?["text"] as? String) ?? ""
        }
        func safe(_ value: String) -> String { ContentSecretRedactor.redact(value) }
        if let add = fields("mcp.servers.add") {
            let args = ((add["args"] as? [String: Any])?["list"] as? [String]) ?? []
            let envNames = (((add["env"] as? [String: Any])?["object"] as? [String: Any]) ?? [:]).keys.sorted()
            return "新增 MCP 服务器（批准后将授权本机以下命令；新增后仍需在设置页授权才会连接）：\n"
                + "名称：\(safe(text(add, "name")))\n"
                + "命令：\(safe(text(add, "command")))\n"
                + "参数：\(args.map(safe).joined(separator: " "))\n"
                + "环境变量名：\(envNames.isEmpty ? "无" : envNames.joined(separator: ", "))（值不显示）"
        }
        if let remove = fields("mcp.servers.remove") {
            let id = text(remove, "id")
            return "移除 MCP 服务器：\(safe(mcpServerDisplayName?(id) ?? id))（id：\(safe(id))，进入 MCP 回收站）"
        }
        return nil
    }

    /// Readable card for conversation_settings scheduler writes: create shows name, cron and the
    /// full command; enable/disable and delete show the task name (resolved through `sessionTitles`).
    func schedulerManagementSummary(_ input: [String: Any]) -> String? {
        guard let changes = input["changes"] as? [String: Any], changes.count == 1,
              let (key, raw) = changes.first, key.hasPrefix("scheduler."),
              let value = raw as? [String: Any] else { return nil }
        func safe(_ text: String) -> String { ContentSecretRedactor.redact(text) }
        func text(_ fields: [String: Any], _ name: String) -> String {
            ((fields[name] as? [String: Any])?["text"] as? String) ?? ""
        }
        func taskName(_ id: String) -> String {
            safe(sessionTitles?.title(for: UUID(uuidString: id)?.uuidString ?? id) ?? id)
        }
        let fields = value["object"] as? [String: Any] ?? [:]
        if key == "scheduler.tasks.add" {
            return "新增定时任务（只创建；新任务未授权，仍需你在设置页“授权预览”确认后才会运行）：\n"
                + "名称：\(safe(text(fields, "name")))\n"
                + "cron：\(safe(text(fields, "cron-expression")))\n"
                + "命令：\(safe(text(fields, "command")))"
        }
        if key == "scheduler.tasks.remove" {
            let id = text(fields, "id")
            return "删除定时任务：\(taskName(id))（id：\(safe(id))，未开始的运行会取消）"
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == "enabled" else { return nil }
        let on = value["toggle"] as? Bool ?? false
        return (on ? "启用" : "停用") + "定时任务：\(taskName(parts[1]))（启用不等于授权）"
    }

    /// Readable card for conversation_settings session.* writes: session title + action.
    func sessionManagementSummary(_ input: [String: Any]) -> String? {
        guard let changes = input["changes"] as? [String: Any], changes.count == 1,
              let (key, raw) = changes.first, key.hasPrefix("session."),
              let value = raw as? [String: Any] else { return nil }
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        func safe(_ text: String) -> String { ContentSecretRedactor.redact(text) }
        func text(_ fields: [String: Any], _ name: String) -> String {
            ((fields[name] as? [String: Any])?["text"] as? String) ?? ""
        }
        let subject = parts[1] == "current"
            ? "当前会话" : "会话「\(safe(sessionTitles?.title(for: parts[1]) ?? parts[1]))」"
        let on = value["toggle"] as? Bool ?? false
        switch parts[2] {
        case "title":
            return "重命名\(subject)为「\(safe(value["text"] as? String ?? ""))」"
        case "pinned": return on ? "置顶\(subject)" : "取消置顶\(subject)"
        case "unread": return on ? "把\(subject)标为未读" : "把\(subject)标为已读"
        case "archived": return on ? "归档\(subject)" : "把\(subject)从归档恢复到会话列表"
        case "trashed":
            return on ? "把\(subject)移入回收站（可在回收站恢复，不会永久删除）"
                : "把\(subject)从回收站恢复"
        case "group":
            let name = safe(value["text"] as? String ?? "")
            return name.isEmpty ? "把\(subject)移出分组" : "把\(subject)移入分组「\(name)」（组不存在则新建）"
        case "project":
            let fields = value["object"] as? [String: Any] ?? [:]
            let name = safe(text(fields, "name"))
            return name.isEmpty ? "解除\(subject)的项目归属"
                : "把\(subject)归入项目「\(name)」，工作目录：\(safe(text(fields, "working_directory")))（只关联，不授予文件访问）"
        default: return nil
        }
    }

    /// Deletion consent must identify the entire canonical target and size.
    /// The normal generic summary truncates paths to 80 characters.
    static func fileDeleteInputSummary(_ input: [String: Any]) -> String {
        guard let raw = input["path"] as? String else { return makeInputSummary(input) }
        let canonical = PolicyRuntimePathBoundary.canonicalPath(raw) ?? raw
        var info = stat()
        let size: String
        if Darwin.lstat(canonical, &info) == 0,
           (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
            size = "\(info.st_size) bytes"
        } else {
            size = "unknown"
        }
        return "删除文件：\(ContentSecretRedactor.redact(canonical))；大小：\(size)"
    }

    /// Build the `ApprovalRequest` for a call (no side effects).
    public func makeRequest(id: String = UUID().uuidString, tool: String, input: [String: Any]) -> ApprovalRequest {
        let toolRisk = riskLevel(for: tool)
        let inputRisk = Self.inputRiskLevel(tool: tool, input: input)
        let effectiveRisk = ApprovalRiskLevel.max(toolRisk, inputRisk)
        let browserInputDigest = BrowserSideEffectPolicy.inputRequiresApproval(tool: tool, input: input)
            ? (try? ComposerToolInput(input).digest) : nil
        let approvalInputDigest = tool == "shell_execute" ? ApprovalAuthorizationContext.payloadDigest(for: input) : browserInputDigest
        let browserIdentityDigest = browserInputDigest.flatMap { inputDigest -> String? in
            guard let data = try? JSONEncoder().encode(BrowserApprovalIdentity(
                callID: id, toolName: tool, inputDigest: inputDigest
            )) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let terminalDisposition = tool == "shell_execute"
            ? terminalPolicySnapshot.classify(command: input["command"] as? String ?? "") : nil
        let inputSummary: String
        if BrowserInteractionInput.parse(tool: tool, input: input) != nil {
            inputSummary = "action: \(input["action"] as? String ?? ""), target: <browser element>, text: <redacted>"
        } else if tool == "orchestrate" {
            let externalTasks = Self.externalOrchestrationTasks(input)
            let summaryInput = externalTasks.isEmpty ? input : input.filter { $0.key != "tasks" }
            inputSummary = Self.externalOrchestrationWarning(externalTasks) + "输入摘要（已脱敏）：\n" + Self.makeInputSummary(summaryInput)
                + "\n\n" + Self.orchestrateScopeSummary(input)
        } else if tool == "shell_execute" {
            // Describe the execution contract, not a second command policy.
            // The live TerminalPolicySnapshot remains runShell's authority.
            let command = input["command"] as? String ?? ""
            let isDenied = terminalDisposition == .denied
            let notice = isDenied
                ? "此命令被终端策略拒绝，即使批准也会拒绝；请在终端策略设置中查看拒绝表。"
                : "批准后执行此命令；系统硬拒绝和你设置的拒绝命令仍然生效。"
            let safeCommand = ContentSecretRedactor.redact(command, knownSecrets: ModelShellEnvironment.knownCredentialValues())
            let summary = Self.makeInputSummary(input.filter { $0.key != "command" && $0.key != "tool_title" })
            let gitContext = GitWorkflowPolicy.approvalContext(command: command)
                .map { "\n" + ContentSecretRedactor.redact($0, knownSecrets: ModelShellEnvironment.knownCredentialValues()) } ?? ""
            inputSummary = notice + "\n命令：" + safeCommand + (summary.isEmpty ? "" : "\n" + summary) + gitContext
        } else if tool == BL6SettingsToolApproval.toolName,
                  let mcpSummary = mcpServerManagementSummary(input) {
            inputSummary = mcpSummary
        } else if tool == BL6SettingsToolApproval.toolName,
                  let schedulerSummary = schedulerManagementSummary(input) {
            inputSummary = schedulerSummary
        } else if tool == BL6SettingsToolApproval.toolName,
                  let sessionSummary = sessionManagementSummary(input) {
            inputSummary = sessionSummary
        } else {
            inputSummary = tool == "file_delete"
                ? Self.fileDeleteInputSummary(input) : Self.makeInputSummary(input)
        }
        var request = ApprovalRequest(
            id: id,
            toolName: tool,
            inputSummary: inputSummary,
            riskLevel: effectiveRisk,
            requiresApproval: shouldAsk(tool: tool, input: input),
            inputRiskLevel: inputRisk,
            requiresSecondConfirmation: effectiveRisk == .high && tool != BL6SettingsToolApproval.toolName,
            inputDigest: approvalInputDigest,
            identityDigest: browserIdentityDigest,
            filePreview: ApprovalFilePreview.capture(tool: tool, input: input)
        )
        if ["file_read", "file_list", "file_grep", "file_glob"].contains(tool),
           let path = input["path"] as? String, !path.isEmpty {
            let safe = ContentSecretRedactor.redact(path)
            request.displayTargetPath = safe.count <= 120 ? safe
                : String(safe.prefix(40)) + "…" + String(safe.suffix(79))
        }
        request.terminalPolicyDisposition = terminalDisposition
        if BrowserSideEffectPolicy.browserToolNames.contains(tool.lowercased()),
           (input["action"] as? String) == "navigate",
           let raw = input["url"] as? String, let url = URL(string: raw),
           BrowserNavigationPolicy.isValidWebURL(url), url.user == nil, url.password == nil {
            request.browserNavigationDestination = url
        }
        request.browserInteractionInput = BrowserInteractionInput.parse(tool: tool, input: input)
        return request
    }

    /// Build a request bound to one concrete effect. Legacy unbound requests
    /// remain available for classification, but cannot authorize a durable
    /// external mutation.
    public func makeBoundRequest(
        id: String = UUID().uuidString,
        tool: String,
        input: [String: Any],
        context: ApprovalAuthorizationContext,
        requiresSecondConfirmation: Bool = false
    ) -> ApprovalRequest {
        let base = makeRequest(id: id, tool: tool, input: input)
        let boundContext = context.binding(to: tool)
        var request = ApprovalRequest(
            id: base.id, requestID: base.requestID, callID: base.callID,
            toolName: base.toolName, inputSummary: base.inputSummary,
            riskLevel: base.riskLevel, requiresApproval: base.requiresApproval,
            inputRiskLevel: base.inputRiskLevel,
            requiresSecondConfirmation: requiresSecondConfirmation || base.requiresSecondConfirmation,
            sessionID: boundContext.sessionID, turnID: boundContext.turnID,
            taskID: boundContext.taskID, attemptID: boundContext.attemptID,
            approvalScope: boundContext.scope, messageID: boundContext.runID,
            policyRevision: boundContext.policyRevision, grantEpoch: boundContext.grantEpoch,
            inputDigest: boundContext.payloadDigest, identityDigest: boundContext.identityDigest,
            actorID: boundContext.actorID, runID: boundContext.runID,
            effectID: boundContext.effectID, expiresAt: boundContext.expiresAt,
            filePreview: base.filePreview, webFetchAuthority: base.webFetchAuthority,
            displayTargetPath: base.displayTargetPath
        )
        request.terminalPolicyDisposition = base.terminalPolicyDisposition
        request.browserNavigationDestination = base.browserNavigationDestination
        request.browserInteractionInput = base.browserInteractionInput
        return request
    }

    /// Bound gate: validates identity and payload before the prompt, then
    /// rechecks cancellation/expiry/binding immediately before authorization.
    public func gate(
        tool: String,
        input: [String: Any],
        context: ApprovalAuthorizationContext,
        delegate: any ApprovalDelegate,
        now: Date = Date()
    ) async throws -> ApprovalDecision {
        try await gateBound(tool: tool, input: input, context: context, delegate: delegate, now: now)
    }

    /// Stage A of D-SETD: the only factory for a settings effect context.
    /// A non-model delegate must approve this exact bound call, even when the
    /// surrounding Composer mode or general approval policy allows autonomy.
    /// The ordinary bound gate emits its audit receipt before this returns.
    public func approveBL6SettingsCall(
        input: [String: Any],
        context: ApprovalAuthorizationContext,
        requiresSecondConfirmation: Bool = false,
        now: Date = Date()
    ) async throws -> BL6SettingsApprovedCallContext {
        let tool = BL6SettingsToolApproval.toolName
        guard policy(for: tool) == .alwaysAsk else {
            throw ApprovalError.denied(reason: "Settings calls require explicit approval")
        }
        guard let delegate else {
            throw ApprovalError.denied(reason: "No approval delegate configured for settings")
        }
        guard context.toolName == tool else {
            throw ApprovalError.bindingMismatch(requestID: context.effectID)
        }
        let bound = context
        let decision = try await gateBound(
            tool: tool,
            input: input,
            context: bound,
            delegate: delegate,
            now: now,
            requiresSecondConfirmation: requiresSecondConfirmation
        )
        try Task.checkCancellation()
        guard Date() < bound.expiresAt else {
            throw ApprovalError.expired(requestID: bound.effectID)
        }
        guard decision.status == .approved,
              decision.requestID == bound.effectID,
              decision.bindingDigest == bound.identityDigest else {
            throw ApprovalError.bindingMismatch(requestID: bound.effectID)
        }
        return BL6SettingsApprovedCallContext(
            requestID: bound.effectID,
            binding: bound
        )
    }

    private func gateBound(
        tool: String,
        input: [String: Any],
        context: ApprovalAuthorizationContext,
        delegate: (any ApprovalDelegate)?,
        now: Date,
        requiresSecondConfirmation: Bool = false,
        turnHandle: TurnController.TurnHandle? = nil,
        childBoundary: AgentChildBoundary? = nil
    ) async throws -> ApprovalDecision {
        guard context.isValid else {
            throw ApprovalError.missingIdentity(requestID: context.effectID)
        }
        guard context.expiresAt > now else {
            throw ApprovalError.expired(requestID: context.effectID)
        }
        guard context.toolName.isEmpty || context.toolName == tool else {
            throw ApprovalError.bindingMismatch(requestID: context.effectID)
        }
        let boundContext = context.binding(to: tool)
        guard let actual = Self.boundPayloadDigest(tool: tool, input: input),
              actual == boundContext.payloadDigest else {
            throw ApprovalError.bindingMismatch(requestID: context.effectID)
        }
        try Task.checkCancellation()
        guard isKnownTool(tool) else {
            throw ApprovalError.denied(reason: "Unknown capability '\(tool)' is blocked")
        }
        var request = makeBoundRequest(
            id: boundContext.effectID,
            tool: tool,
            input: input,
            context: boundContext,
            requiresSecondConfirmation: requiresSecondConfirmation
        )
        if let childBoundary {
            request.source = .childTask(taskID: childBoundary.identity.childTaskID,
                                        parentID: childBoundary.identity.parentTaskID)
        }
        var decision: ApprovalDecision
        var askedDelegate = false
        switch policy(for: tool) {
        case .deny, .never:
            throw ApprovalError.denied(reason: "Tool '\(tool)' is blocked by policy")
        case .autoApprove where request.requiresApproval:
            guard let delegate else {
                throw ApprovalError.denied(reason: "Input requires approval for tool '\(tool)'")
            }
            askedDelegate = true
            decision = await delegate.requestApproval(request)
        case .autoApprove:
            decision = ApprovalDecision(approved: true, reason: "auto-approved by policy", confirmed: true, requestID: request.requestID, bindingDigest: request.identityDigest)
        case .alwaysAsk, .riskOnlyAsk:
            guard let delegate else {
                throw ApprovalError.denied(reason: "No approval delegate configured for tool '\(tool)'")
            }
            askedDelegate = true
            decision = await delegate.requestApproval(request)
        }
        do {
            let originalRequestID = request.requestID
            if askedDelegate, let delegate {
                (request, decision) = try await reviewChangedFile(request: request, decision: decision,
                    input: input, delegate: delegate)
            }
            var refreshed = request.requestID != originalRequestID
            for _ in 0...1 {
                do {
                    try Task.checkCancellation()
                    // The prompt may outlive the exact turn that requested it. Recheck
                    // that captured handle before emitting a receipt; the controller's
                    // latest turn may already be a different, active target.
                    if let turnHandle {
                        guard await turnHandle.isActive(), !(await turnHandle.isCancelled()) else {
                            throw ApprovalError.cancelled(requestID: request.requestID)
                        }
                    }
                    if let childBoundary {
                        guard let parentHandle = childBoundary.parentTurnHandle,
                              await parentHandle.isActive(), !(await parentHandle.isCancelled()) else {
                            throw ApprovalError.cancelled(requestID: request.requestID)
                        }
                        do {
                            try await childBoundary.check()
                        } catch {
                            throw ApprovalError.cancelled(requestID: request.requestID)
                        }
                    }
                    // The delegate may suspend while the user considers the prompt. Use
                    // a fresh wall-clock check after the await so an expired grant cannot
                    // be authorized merely because the caller's entry timestamp was live.
                    guard Date() < boundContext.expiresAt else {
                        throw ApprovalError.expired(requestID: request.requestID)
                    }
                    let result = try await approved(validated(decision, for: request, now: Date()), request: request)
                    if askedDelegate {
                        ApprovalAuthorityObservation.emit(.authorityApproved, for: request)
                    }
                    return result
                } catch is ApprovalFileChangedError {
                    guard !refreshed, askedDelegate, let delegate else { throw ApprovalFileChangedError() }
                    // The old file decision has not consumed the gate identity.
                    // Revoke its presentation and use the same ordinary chain.
                    ApprovalAuthorityObservation.emit(.authorityRevoked, for: request)
                    (request, decision) = try await reviewChangedFile(request: request, decision: decision,
                        input: input, delegate: delegate)
                    refreshed = true
                }
            }
            throw ApprovalFileChangedError()
        } catch {
            if askedDelegate {
                ApprovalAuthorityObservation.emit(
                    ApprovalAuthorityObservation.rejected(error, decision: decision), for: request
                )
            }
            throw error
        }
    }

    public func gate(
        tool: String,
        input: [String: Any],
        context: ApprovalAuthorizationContext,
        now: Date = Date()
    ) async throws -> ApprovalDecision {
        try await gateBound(tool: tool, input: input, context: context, delegate: delegate, now: now)
    }

    private static func boundPayloadDigest(tool: String, input: [String: Any]) -> String? {
        if BrowserSideEffectPolicy.inputRequiresApproval(tool: tool, input: input) {
            // BrowserSideEffectGrantLedger compares this same canonical digest
            // with AgentLoop's BrowserSideEffectCallContext at dispatch.
            return try? ComposerToolInput(input).digest
        }
        return ApprovalAuthorizationContext.payloadDigest(for: input)
    }

    /// The non-Composer AgentLoop supplies its already-verified execution and
    /// canonical attempt facts for the model call it is about to dispatch.
    /// A human approval must bind to that call; the task-local parent identity
    /// alone does not contain an attempt and must never be used to invent one.
    public func gateAgentCall(
        tool: String,
        input: [String: Any],
        callID: String,
        executionIdentity: AgentExecutionIdentity?,
        attemptID: String?,
        attemptNumber: Int,
        childBoundary: AgentChildBoundary? = nil
    ) async throws -> ApprovalDecision {
        try Task.checkCancellation()
        guard !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApprovalError.missingIdentity(requestID: callID)
        }
        guard isKnownTool(tool) else {
            throw ApprovalError.denied(reason: "Unknown capability '\(tool)' is blocked")
        }
        let policy = policy(for: tool)
        if policy == .deny || policy == .never {
            throw ApprovalError.denied(reason: "Tool '\(tool)' is blocked by policy")
        }
        let classification = makeRequest(id: callID, tool: tool, input: input)
        if policy == .autoApprove && !classification.requiresApproval {
            return try await gate(tool: tool, input: input, callID: callID)
        }

        guard let runtime = AgentExecutionContext.current,
              let handle = runtime.parentTurnHandle,
              let deadline = runtime.deadline,
              let executionIdentity, executionIdentity.isValid,
              executionIdentity.attempt > 0,
              executionIdentity.attempt == attemptNumber,
              let attemptID,
              !attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payloadDigest = Self.boundPayloadDigest(tool: tool, input: input) else {
            throw ApprovalError.missingIdentity(requestID: callID)
        }
        let actorID: String
        let sessionID: String
        let turnID: Int
        let taskID: String
        let scope: String
        let grantEpoch: String
        let approvalDeadline: Date
        if let childBoundary {
            let child = childBoundary.identity
            guard child.isValid,
                  (try? child.requireVerifiedGeneration()) != nil,
                  let generationID = child.generationID,
                  let parentHandle = childBoundary.parentTurnHandle,
                  parentHandle.turnID == child.cancelGeneration,
                  let childController = childBoundary.childTurnController,
                  let runtimeController = runtime.turnController,
                  childController === runtimeController,
                  childBoundary.allowsTool(tool),
                  runtime.currentConversationID == child.childSessionID,
                  executionIdentity.turn.sessionID == child.childSessionID,
                  executionIdentity.turn.turnID == child.cancelGeneration,
                  executionIdentity.turn.messageID == child.childTaskID,
                  executionIdentity.operationID == generationID,
                  attemptID == generationID else {
                throw ApprovalError.missingIdentity(requestID: callID)
            }
            do {
                try await childBoundary.check()
            } catch {
                throw ApprovalError.cancelled(requestID: callID)
            }
            guard await parentHandle.isActive(), !(await parentHandle.isCancelled()) else {
                throw ApprovalError.cancelled(requestID: callID)
            }
            actorID = "child:\(child.childSessionID)"
            sessionID = child.childSessionID
            turnID = child.cancelGeneration
            taskID = child.childTaskID
            scope = child.scopeID
            grantEpoch = generationID
            approvalDeadline = min(deadline, childBoundary.deadline ?? deadline)
        } else {
            guard runtime.hasVerifiedParentRuntime,
                  let parent = runtime.parentRuntimeIdentity,
                  runtime.currentConversationID == parent.conversationID,
                  executionIdentity.turn.sessionID == parent.sessionID,
                  executionIdentity.turn.turnID == handle.turnID else {
                throw ApprovalError.missingIdentity(requestID: callID)
            }
            guard attemptID == "\(executionIdentity.operationID):attempt:\(executionIdentity.attempt)" else {
                throw ApprovalError.bindingMismatch(requestID: callID)
            }
            actorID = parent.actorID
            sessionID = parent.sessionID
            turnID = handle.turnID
            taskID = parent.taskID
            scope = "request"
            grantEpoch = "\(parent.turnID):\(executionIdentity.turn.messageID):\(attemptID)"
            approvalDeadline = deadline
        }
        guard await handle.isActive(), !(await handle.isCancelled()) else {
            throw ApprovalError.cancelled(requestID: callID)
        }
        let binding = ApprovalAuthorizationContext(
            actorID: actorID,
            sessionID: sessionID,
            turnID: turnID,
            taskID: taskID,
            runID: executionIdentity.operationID,
            attemptID: attemptID,
            effectID: callID,
            scope: scope,
            payloadDigest: payloadDigest,
            expiresAt: approvalDeadline,
            policyRevision: "agent-gate-v1:\(policy.rawValue)",
            grantEpoch: grantEpoch,
            toolName: tool
        )
        return try await gateBound(
            tool: tool,
            input: input,
            context: binding,
            delegate: delegate,
            now: Date(),
            turnHandle: handle,
            childBoundary: childBoundary
        )
    }

    private func legacyPromptNeedsBoundIdentity(_ request: ApprovalRequest) -> Bool {
        guard AgentExecutionContext.current != nil else { return false }
        let policy = policy(for: request.toolName)
        return request.requiresApproval || policy == .alwaysAsk || policy == .riskOnlyAsk
    }

    /// Full gate: classify → (auto-approve | ask delegate | deny).
    ///
    /// - Returns the delegate's decision when approved.
    /// - Throws `ApprovalError.denied` when the policy is `.deny`/`.never` or the
    ///   delegate (or missing delegate) refused the call.
    public func gate(
        tool: String,
        input: [String: Any],
        callID: String? = nil,
        delegate: any ApprovalDelegate
    ) async throws -> ApprovalDecision {
        try Task.checkCancellation()
        guard isKnownTool(tool) else {
            throw ApprovalError.denied(reason: "Unknown capability '\(tool)' is blocked")
        }
        let request = makeRequest(id: callID ?? UUID().uuidString, tool: tool, input: input)
        guard !legacyPromptNeedsBoundIdentity(request) else {
            throw ApprovalError.missingIdentity(requestID: request.requestID)
        }
        switch policy(for: tool) {
        case .autoApprove where request.requiresApproval:
            let decision = await delegate.requestApproval(request)
            try Task.checkCancellation()
            return try await approveAfterFileReview(request: request, decision: decision, input: input, delegate: delegate)
        case .autoApprove:
            try Task.checkCancellation()
            return try await approved(ApprovalDecision(approved: true, reason: "auto-approved by policy"), request: request)
        case .deny, .never:
            throw ApprovalError.denied(reason: "Tool '\(tool)' is blocked by policy")
        case .alwaysAsk:
            let decision = await delegate.requestApproval(request)
            try Task.checkCancellation()
            return try await approveAfterFileReview(request: request, decision: decision, input: input, delegate: delegate)
        case .riskOnlyAsk:
            let decision = await delegate.requestApproval(request)
            try Task.checkCancellation()
            return try await approveAfterFileReview(request: request, decision: decision, input: input, delegate: delegate)
        }
    }

    /// Convenience overload using the gate's stored `delegate`.
    ///
    /// An `alwaysAsk`/`riskOnlyAsk` call with no stored delegate is denied —
    /// the gate never silently executes an unapproved high-risk call.
    /// `.deny`/`.never` and low-risk `.autoApprove` policies are resolved
    /// without needing a delegate.
    public func gate(tool: String, input: [String: Any], callID: String? = nil) async throws -> ApprovalDecision {
        try Task.checkCancellation()
        guard isKnownTool(tool) else {
            throw ApprovalError.denied(reason: "Unknown capability '\(tool)' is blocked")
        }
        let request = makeRequest(id: callID ?? UUID().uuidString, tool: tool, input: input)
        guard !legacyPromptNeedsBoundIdentity(request) else {
            throw ApprovalError.missingIdentity(requestID: request.requestID)
        }
        switch policy(for: tool) {
        case .deny, .never:
            throw ApprovalError.denied(reason: "Tool '\(tool)' is blocked by policy")
        case .autoApprove where request.requiresApproval:
            guard let delegate else {
                throw ApprovalError.denied(reason: "Input requires approval for tool '\(tool)'")
            }
            return try await gate(tool: tool, input: input, callID: request.callID, delegate: delegate)
        case .autoApprove:
            return try await approved(ApprovalDecision(approved: true, reason: "auto-approved by policy"), request: request)
        case .alwaysAsk, .riskOnlyAsk:
            guard let delegate else {
                throw ApprovalError.denied(reason: "No approval delegate configured for tool '\(tool)'")
            }
            return try await gate(tool: tool, input: input, callID: request.callID, delegate: delegate)
        }
    }

    /// At most one retry through the existing human delegate. File changes
    /// do not silently renew a consumed grant or widen the requested action.
    func reviewChangedFile(
        request: ApprovalRequest, decision: ApprovalDecision,
        input: [String: Any], delegate: any ApprovalDelegate,
        refreshPreview: (() async throws -> ApprovalFilePreview)? = nil
    ) async throws -> (request: ApprovalRequest, decision: ApprovalDecision) {
        guard decision.approved, let preview = request.filePreview else { return (request, decision) }
        _ = try validated(decision, for: request)
        guard preview.available else {
            throw ApprovalError.denied(reason: "文件预览不可用，请修正路径后重新审批")
        }
        var fresh: ApprovalFilePreview?
        do {
            try preview.validateCurrent()
            if let refreshPreview {
                let captured = try await refreshPreview()
                fresh = captured
                guard captured == preview else { throw ApprovalFileChangedError() }
            }
            return (request, decision)
        }
        catch is ApprovalFileChangedError { /* Ask once for the current file. */ }
        catch { throw error }
        try Task.checkCancellation()
        let candidate: ApprovalFilePreview?
        if let fresh { candidate = fresh }
        else if let refreshPreview { candidate = try await refreshPreview() }
        else { candidate = ApprovalFilePreview.capture(tool: request.toolName, input: input) }
        guard let refreshed = candidate else {
            throw ApprovalFileChangedError()
        }
        try refreshed.validateCurrent()
        let current = request.refreshingFilePreview(refreshed, inputSummary: request.toolName == "file_delete"
            ? Self.fileDeleteInputSummary(input) : Self.makeInputSummary(input))
        let answer = await delegate.requestApproval(current)
        try Task.checkCancellation()
        guard !answer.approved || (answer.requestID == current.requestID && answer.filePreview == refreshed) else {
            throw ApprovalError.bindingMismatch(requestID: current.requestID)
        }
        // A second concurrent mutation stops here; no unbounded prompt loop.
        if answer.approved {
            try refreshed.validateCurrent()
            if let refreshPreview, try await refreshPreview() != refreshed { throw ApprovalFileChangedError() }
        }
        return (current, answer)
    }

    private func approveAfterFileReview(
        request: ApprovalRequest, decision: ApprovalDecision,
        input: [String: Any], delegate: any ApprovalDelegate
    ) async throws -> ApprovalDecision {
        let reviewed = try await reviewChangedFile(request: request, decision: decision,
            input: input, delegate: delegate)
        do {
            return try await approved(validated(reviewed.decision, for: reviewed.request), request: reviewed.request)
        } catch is ApprovalFileChangedError {
            guard reviewed.request.requestID == request.requestID else { throw ApprovalFileChangedError() }
            ApprovalAuthorityObservation.emit(.authorityRevoked, for: reviewed.request)
            let refreshed = try await reviewChangedFile(request: reviewed.request, decision: reviewed.decision,
                input: input, delegate: delegate)
            return try await approved(validated(refreshed.decision, for: refreshed.request), request: refreshed.request)
        }
    }

    private func validated(_ decision: ApprovalDecision, for request: ApprovalRequest, now: Date = Date()) throws -> ApprovalDecision {
        guard decision.approved, decision.status == .approved else {
            switch decision.status {
            case .expired: throw ApprovalError.expired(requestID: request.requestID)
            case .revoked: throw ApprovalError.revoked(requestID: request.requestID)
            case .cancelled: throw ApprovalError.cancelled(requestID: request.requestID)
            case .approved, .denied: throw ApprovalError.denied(reason: decision.reason)
            }
        }
        if let expiresAt = request.expiresAt, expiresAt <= now {
            throw ApprovalError.expired(requestID: request.requestID)
        }
        let browserSideEffect = BrowserSideEffectPolicy.browserToolNames.contains(request.toolName.lowercased())
            && request.inputDigest != nil
        if browserSideEffect && request.identityDigest == nil {
            throw ApprovalError.missingIdentity(requestID: request.requestID)
        }
        if request.binding != nil || browserSideEffect {
            guard decision.status == .approved,
                  decision.requestID == request.requestID,
                  decision.bindingDigest == request.identityDigest else {
                throw ApprovalError.bindingMismatch(requestID: request.requestID)
            }
        } else {
            if let requestID = decision.requestID, requestID != request.requestID {
                throw ApprovalError.bindingMismatch(requestID: request.requestID)
            }
            if let digest = decision.bindingDigest, digest != request.identityDigest {
                throw ApprovalError.bindingMismatch(requestID: request.requestID)
            }
        }
        if request.expiresAt != nil, request.binding == nil {
            throw ApprovalError.missingIdentity(requestID: request.requestID)
        }
        guard !request.requiresSecondConfirmation || decision.confirmed else {
            throw ApprovalError.denied(reason: "L3 requires second confirmation")
        }
        return decision
    }

    /// Composer supplies the exact request and delegate decision it already
    /// presented; it does not ask a second time or synthesize an approval.
    func acceptApprovedDecision(
        _ decision: ApprovalDecision,
        for request: ApprovalRequest,
        receiptExpiresAt: Date? = nil
    ) async throws {
        try Task.checkCancellation()
        guard isKnownTool(request.toolName),
              policy(for: request.toolName) != .deny,
              policy(for: request.toolName) != .never else {
            throw ApprovalError.denied(reason: "Capability is blocked by approval policy")
        }
        _ = try await approved(
            validated(decision, for: request),
            request: request,
            receiptExpiresAt: receiptExpiresAt
        )
    }

    private func approved(
        _ decision: ApprovalDecision,
        request: ApprovalRequest,
        receiptExpiresAt: Date? = nil
    ) async throws -> ApprovalDecision {
        try request.filePreview?.validateCurrent()
        let deferredFileConsumption = request.filePreview != nil
        if let identityDigest = request.identityDigest {
            guard !identityConsumptionStore.contains(identityDigest) else {
                throw ApprovalError.alreadyConsumed(requestID: request.requestID)
            }
            if !deferredFileConsumption, !identityConsumptionStore.consume(identityDigest) {
                throw ApprovalError.alreadyConsumed(requestID: request.requestID)
            }
        }
        let receipt = ApprovalReceipt(
                requestID: request.requestID,
                toolName: request.toolName,
                policy: policy(for: request.toolName),
                riskLevel: request.riskLevel,
                inputSummary: request.inputSummary,
                status: decision.status,
                actorID: request.actorID, sessionID: request.sessionID,
                turnID: request.turnID, taskID: request.taskID,
                runID: request.runID, attemptID: request.attemptID,
                effectID: request.effectID, approvalScope: request.approvalScope,
                inputDigest: request.inputDigest, identityDigest: request.identityDigest,
                expiresAt: receiptExpiresAt ?? request.expiresAt, policyRevision: request.policyRevision,
                grantEpoch: request.grantEpoch
            )
        try await onApprovalReceipt?(receipt)
        try Task.checkCancellation()
        // The receipt sink may suspend. Under the caller's existing physical
        // file lock, reject a stale preview BEFORE consuming this identity.
        // There is no await between the final check and file consumption.
        try request.filePreview?.validateCurrent()
        if deferredFileConsumption {
            if let expiresAt = request.expiresAt, expiresAt <= Date() {
                throw ApprovalError.expired(requestID: request.requestID)
            }
            if let identityDigest = request.identityDigest,
               !identityConsumptionStore.consume(identityDigest) {
                throw ApprovalError.alreadyConsumed(requestID: request.requestID)
            }
        }
        return decision.carrying(request.filePreview)
    }
}

/// Thread-safe session id -> title lookup that the App keeps fresh for approval cards.
public final class SessionTitleDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String: String] = [:]

    public init() {}

    public func replace(with titles: [String: String]) {
        lock.lock()
        self.titles = titles
        lock.unlock()
    }

    public func merge(_ titles: [String: String]) {
        lock.lock()
        self.titles.merge(titles) { _, new in new }
        lock.unlock()
    }

    public func title(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return titles[id]
    }
}
