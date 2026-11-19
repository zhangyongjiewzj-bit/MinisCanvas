import Foundation

// MARK: - Frozen binding snapshots

public enum SubAgentBindingSource: Sendable, Equatable, Codable {
    case inherited
    case explicit
}

/// Non-secret provider/model identity captured at the orchestration boundary.
public struct ParentContextSnapshotV1: Sendable, Equatable, Codable {
    public let providerID: String
    public let modelID: String
    public let configurationFingerprint: String
    public let profileID: String?
    public let baseHost: String?
    public let wireAPI: String?
    public let reasoningConfiguration: String?
    public let conversationID: String?

    public init(
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        profileID: String? = nil,
        baseHost: String? = nil,
        wireAPI: String? = nil,
        reasoningConfiguration: String? = nil,
        conversationID: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.profileID = profileID
        self.baseHost = baseHost
        self.wireAPI = wireAPI
        self.reasoningConfiguration = reasoningConfiguration
        self.conversationID = conversationID
    }

    /// Stable non-secret identity used to link Task/Run/Attempt/Event/Receipt records.
    /// It includes every binding fact that must remain immutable across child dispatch.
    public var snapshotID: String {
        if profileID == nil, baseHost == nil, wireAPI == nil, reasoningConfiguration == nil {
            return "binding:" + providerID + ":" + modelID + ":" + configurationFingerprint + ":" + (conversationID ?? "")
        }
        return "binding:" + [providerID, modelID, configurationFingerprint, profileID ?? "", baseHost ?? "", wireAPI ?? "", reasoningConfiguration ?? "", conversationID ?? ""].joined(separator: ":")
    }

    public func matches(_ other: ParentContextSnapshotV1) -> Bool {
        self == other
    }
}

// MARK: - Sub-Agent Task

/// 子智能体执行方式：内置（独立 AgentLoop 实例）或外部 CLI agent（Codex/Hermes/Claude）。
public enum SubAgentAgentType: Sendable, Equatable, Hashable, Codable {
    /// Minis 内置子 agent：每个任务用独立 `AgentLoop` 实例（独立消息历史）执行。
    case builtin
    /// 外部 CLI agent，`name` 对应注入 `AgentOrchestrator` 的 `ExternalAgentRunner` 键
    /// （惯例：`"codex"` / `"hermes"` / `"claude"`）。
    case external(name: String)
}

/// A task's requested resources are data, not an authorization grant. The
/// production builtin boundary validates them against its trusted parent
/// executor and policy before a child can start.
public struct SubAgentResourceRequest: Sendable, Equatable, Codable {
    public let allowedToolNames: [String]
    public let allowedReadRoots: [String]
    /// Nil inherits the trusted parent write ceiling; [] explicitly removes writes.
    public let allowedWriteRoots: [String]?
    /// A requested child directory, never an authorization grant.
    public let workingDirectory: String?
    public let inheritsToolNames: Bool

    public init(allowedToolNames: [String], allowedReadRoots: [String],
                allowedWriteRoots: [String]? = nil, workingDirectory: String? = nil,
                inheritsToolNames: Bool = false) {
        self.allowedToolNames = allowedToolNames
        self.allowedReadRoots = allowedReadRoots
        self.allowedWriteRoots = allowedWriteRoots
        self.workingDirectory = workingDirectory
        self.inheritsToolNames = inheritsToolNames
    }

    private enum CodingKeys: String, CodingKey {
        case allowedToolNames, allowedReadRoots, allowedWriteRoots, workingDirectory, inheritsToolNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedToolNames = try c.decode([String].self, forKey: .allowedToolNames)
        allowedReadRoots = try c.decode([String].self, forKey: .allowedReadRoots)
        allowedWriteRoots = try c.decodeIfPresent([String].self, forKey: .allowedWriteRoots)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        inheritsToolNames = try c.decodeIfPresent(Bool.self, forKey: .inheritsToolNames) ?? false
    }
}

/// Missing persisted or model input retains the original unisolated behavior.
public enum SubAgentIsolation: String, Codable, Sendable {
    case none
    case worktree
}

/// 一个可派发的子任务（E23 多智能体协同）。
///
/// 总控 agent 把大任务拆成多个 `SubAgentTask`，交给 `AgentOrchestrator` 并行或串行执行。
public struct SubAgentTask: Sendable, Equatable, Codable {
    /// 唯一任务 ID（reports 按此回填）。
    public let id: String
    /// 人类可读标题（用于日志/汇总）。
    public let title: String
    /// 给子 agent 的具体指令（内置子 agent 作为首条 user 消息；外部 CLI 作为参数）。
    public let instructions: String
    /// 可选的共享上下文（项目背景、代码库说明等）。
    public let context: String?
    /// 期望产出描述（供总控汇总时对照）。
    public let expectedOutput: String?
    /// 由哪个 agent 类型执行。默认 `.builtin`。
    public let agentType: SubAgentAgentType
    /// Optional provider binding; nil inherits the orchestrator's provider.
    public let providerID: String?
    /// Optional model binding; nil inherits the orchestrator's model.
    public let modelID: String?
    /// Immutable non-secret configuration identity for the selected binding.
    public let configurationFingerprint: String?
    public let profileID: String?
    public let baseHost: String?
    public let wireAPI: String?
    public let reasoningConfiguration: String?
    /// Capabilities required by the child execution path.
    public let requiredCapabilities: Set<ProviderCapability>
    /// Nil inherits the trusted parent tool/project ceiling. An explicit
    /// request can only narrow it; it never supplies authorization.
    public let resourceRequest: SubAgentResourceRequest?
    public let isolation: SubAgentIsolation?
    /// Runtime-only identity used to cancel one external invocation without
    /// confusing equal display task IDs from different parent sessions.
    public let executionID: String?
    /// Immutable identity of the parent context that authorized this task.
    public let parentContextSnapshotID: String?
    public let bindingSource: SubAgentBindingSource

    public init(
        id: String,
        title: String,
        instructions: String,
        context: String? = nil,
        expectedOutput: String? = nil,
        agentType: SubAgentAgentType = .builtin,
        providerID: String? = nil,
        modelID: String? = nil,
        configurationFingerprint: String? = nil,
        profileID: String? = nil,
        baseHost: String? = nil,
        wireAPI: String? = nil,
        reasoningConfiguration: String? = nil,
        requiredCapabilities: Set<ProviderCapability> = [],
        resourceRequest: SubAgentResourceRequest? = nil,
        isolation: SubAgentIsolation? = nil,
        executionID: String? = nil,
        parentContextSnapshotID: String? = nil,
        bindingSource: SubAgentBindingSource = .inherited
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.context = context
        self.expectedOutput = expectedOutput
        self.agentType = agentType
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.profileID = profileID
        self.baseHost = baseHost
        self.wireAPI = wireAPI
        self.reasoningConfiguration = reasoningConfiguration
        self.requiredCapabilities = requiredCapabilities
        self.resourceRequest = resourceRequest
        self.isolation = isolation
        self.executionID = executionID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.bindingSource = bindingSource
    }

    public func withIsolation(_ isolation: SubAgentIsolation) -> SubAgentTask {
        SubAgentTask(id: id, title: title, instructions: instructions, context: context,
            expectedOutput: expectedOutput, agentType: agentType, providerID: providerID,
            modelID: modelID, configurationFingerprint: configurationFingerprint,
            profileID: profileID, baseHost: baseHost, wireAPI: wireAPI,
            reasoningConfiguration: reasoningConfiguration, requiredCapabilities: requiredCapabilities,
            resourceRequest: resourceRequest, isolation: isolation, executionID: executionID,
            parentContextSnapshotID: parentContextSnapshotID, bindingSource: bindingSource)
    }

    public func withExecutionID(_ executionID: String) -> SubAgentTask {
        SubAgentTask(
            id: id,
            title: title,
            instructions: instructions,
            context: context,
            expectedOutput: expectedOutput,
            agentType: agentType,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            profileID: profileID,
            baseHost: baseHost,
            wireAPI: wireAPI,
            reasoningConfiguration: reasoningConfiguration,
            requiredCapabilities: requiredCapabilities,
            resourceRequest: resourceRequest,
            isolation: isolation,
            executionID: executionID,
            parentContextSnapshotID: parentContextSnapshotID,
            bindingSource: bindingSource
        )
    }

    public func resolvedBinding(
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        profileID: String? = nil,
        baseHost: String? = nil,
        wireAPI: String? = nil,
        reasoningConfiguration: String? = nil,
        parentContextSnapshotID: String? = nil,
        source: SubAgentBindingSource
    ) -> SubAgentTask {
        SubAgentTask(
            id: id,
            title: title,
            instructions: instructions,
            context: context,
            expectedOutput: expectedOutput,
            agentType: agentType,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            profileID: profileID ?? self.profileID,
            baseHost: baseHost ?? self.baseHost,
            wireAPI: wireAPI ?? self.wireAPI,
            reasoningConfiguration: reasoningConfiguration ?? self.reasoningConfiguration,
            requiredCapabilities: requiredCapabilities,
            resourceRequest: resourceRequest,
            isolation: isolation,
            executionID: executionID ?? self.executionID,
            parentContextSnapshotID: parentContextSnapshotID ?? self.parentContextSnapshotID,
            bindingSource: source
        )
    }
}

// MARK: - Sub-Agent Result

/// 单个子任务的执行结果。成功时携带 output 文本；失败时携带 error 描述。
public enum SubAgentResult: Sendable, Equatable {
    case succeeded(output: String)
    case failed(error: String)

    public var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }

    public var output: String? {
        if case .succeeded(let output) = self { return output }
        return nil
    }

    public var error: String? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - Sub-Agent Report

/// 一个子任务从派发到结束的完整报告（供总控 agent 汇总给用户）。
public struct SubAgentReport: Sendable, Equatable {
    /// 对应 `SubAgentTask.id`。
    public let taskID: String
    /// 实际执行该任务的 agent 类型。
    public let agentType: SubAgentAgentType
    /// 执行耗时（秒）。
    public let duration: TimeInterval
    public let result: SubAgentResult
    public let partialOutput: String?
    /// Exact durable result route. Nil for preflight/library-only reports.
    public let parentID: String?
    public let runID: String?
    public let attemptID: String?
    /// 隔离（worktree）子任务的工作区目录与分支；非隔离任务为 nil。
    public let workspacePath: String?
    public let workspaceBranch: String?

    public init(taskID: String, agentType: SubAgentAgentType, duration: TimeInterval, result: SubAgentResult,
                parentID: String? = nil, runID: String? = nil, attemptID: String? = nil,
                partialOutput: String? = nil,
                workspacePath: String? = nil, workspaceBranch: String? = nil) {
        self.workspacePath = workspacePath
        self.workspaceBranch = workspaceBranch
        self.taskID = taskID
        self.agentType = agentType
        self.duration = duration
        self.result = result
        self.partialOutput = partialOutput
        self.parentID = parentID
        self.runID = runID
        self.attemptID = attemptID
    }

    func withResultIdentity(parentID: String, runID: String, attemptID: String) -> SubAgentReport {
        SubAgentReport(taskID: taskID, agentType: agentType, duration: duration, result: result,
            parentID: parentID, runID: runID, attemptID: attemptID, partialOutput: partialOutput,
            workspacePath: workspacePath, workspaceBranch: workspaceBranch)
    }

    func withWorkspace(path: String, branch: String) -> SubAgentReport {
        SubAgentReport(taskID: taskID, agentType: agentType, duration: duration, result: result,
            parentID: parentID, runID: runID, attemptID: attemptID, partialOutput: partialOutput,
            workspacePath: path, workspaceBranch: branch)
    }

    /// 给总控汇总用的一行摘要。
    public var summaryLine: String {
        let workspace = workspacePath.map { "（隔离工作区：\($0)，分支：\(workspaceBranch ?? "未知")）" } ?? ""
        if let partialOutput {
            let preview = partialOutput.isEmpty ? "没有已结算的可见正文。" : OrchestrationToolExecutor.resultSummary(partialOutput)
            return "[\(taskID)] 部分结果：\(preview)\(workspace)"
        }
        switch result {
        case .succeeded(let output):
            let preview = OrchestrationToolExecutor.resultSummary(output)
            return "[\(taskID)] 成功 (\(String(format: "%.2f", duration))s): \(preview)\(workspace)"
        case .failed(let error):
            return "[\(taskID)] 失败 (\(String(format: "%.2f", duration))s): \(OrchestrationToolExecutor.resultSummary(error))\(workspace)"
        }
    }
}
