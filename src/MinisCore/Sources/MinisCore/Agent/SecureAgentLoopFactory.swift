import Foundation

/// 生产路径专用的 fail-closed AgentLoop 工厂。
/// 普通构造器保留给兼容测试/离线编排；生产装配必须使用此入口并提供审批门。
public enum SecureAgentLoopFactory {
    /// Production wall-clock bound for provider and tool work.
    public static let defaultTimeout: TimeInterval = 300

    /// Build a secure child loop from one immutable capability/scope/
    /// cancellation snapshot. The boundary and snapshot are checked before a
    /// caller can start the loop; a missing field or generation drift is never
    /// deferred until after provider/tool work.
    public static func makeChild(
        maxIterations: Int = 10,
        approvalDelegate: any ApprovalDelegate,
        childBoundary: AgentChildBoundary,
        childRuntimeSnapshot: AgentChildRuntimeSnapshot,
        expectedCancelGeneration: Int? = nil,
        policyRuntime: PolicyRuntimeBinding? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = SecureAgentLoopFactory.defaultTimeout
    ) throws -> AgentLoop {
        try validateChildSnapshot(
            childRuntimeSnapshot,
            boundary: childBoundary,
            expectedCancelGeneration: expectedCancelGeneration
        )
        return AgentLoop(
            maxIterations: maxIterations,
            approvalGate: ApprovalGate(delegate: approvalDelegate),
            requestBudget: childBoundary.budget,
            compactor: compactor,
            timeout: timeout,
            parentBinding: childBoundary.identity.providerSnapshot,
            childBoundary: childBoundary,
            policyRuntime: policyRuntime,
            requiresPolicyRuntime: true,
            toolExecutionFactLedger: toolExecutionFactLedger
        )
    }

    /// Context-consuming overload used by production composition roots. The
    /// context must carry the same immutable snapshot and an active parent
    /// handle; no child loop is returned for an incomplete or stale context.
    public static func makeChild(
        context: AgentExecutionContextSnapshot,
        maxIterations: Int = 10,
        approvalDelegate: any ApprovalDelegate,
        childBoundary: AgentChildBoundary,
        expectedCancelGeneration: Int? = nil,
        policyRuntime: PolicyRuntimeBinding? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = SecureAgentLoopFactory.defaultTimeout
    ) throws -> AgentLoop {
        guard context.hasVerifiedChildRuntime,
              let snapshot = context.childRuntimeSnapshot else {
            throw SecureAgentLoopError.childRuntimeSnapshotRequired
        }
        return try makeChild(
            maxIterations: maxIterations,
            approvalDelegate: approvalDelegate,
            childBoundary: childBoundary,
            childRuntimeSnapshot: snapshot,
            expectedCancelGeneration: expectedCancelGeneration,
            policyRuntime: policyRuntime,
            toolExecutionFactLedger: toolExecutionFactLedger,
            compactor: compactor,
            timeout: timeout
        )
    }

    /// Build a production loop from an approval delegate without exposing the
    /// optional gate seam to the composition root.
    public static func makeOrchestrator(
        defaultMaxConcurrent: Int = 4,
        maxIterationsPerTask: Int = 10,
        provider: (any LLMProvider)? = nil,
        toolExecutor: (any ToolExecutor)? = nil,
        externalRunners: [String: any ExternalAgentRunner] = [:],
        approvalDelegate: any ApprovalDelegate,
        policyRuntime: PolicyRuntimeBinding? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        capabilityPolicy: AgentCapabilityPolicy? = nil,
        parentCapabilities: Set<ProviderCapability>? = nil,
        turnController: TurnController? = nil,
        makeLoopDetector: @escaping @Sendable () -> ToolLoopDetector? = { ToolLoopDetector() },
        makeChildBudget: (@Sendable () -> BudgetTracker?)? = nil,
        childTimeout: TimeInterval? = SecureAgentLoopFactory.defaultTimeout,
        currentConversationID: String? = nil,
        childGovernor: ChildConcurrencyGovernor? = nil
    ) -> AgentOrchestrator {
        AgentOrchestrator(
            defaultMaxConcurrent: defaultMaxConcurrent,
            maxIterationsPerTask: maxIterationsPerTask,
            provider: provider,
            toolExecutor: toolExecutor.map { policyRuntime?.wrap($0) ?? $0 },
            externalRunners: externalRunners,
            approvalGate: ApprovalGate(delegate: approvalDelegate),
            turnController: turnController,
            makeLoopDetector: makeLoopDetector,
            makeChildBudget: makeChildBudget,
            childTimeout: childTimeout,
            currentConversationID: currentConversationID,
            toolExecutionFactLedger: toolExecutionFactLedger,
            capabilityPolicy: capabilityPolicy,
            parentCapabilities: parentCapabilities,
            requiresPolicyRuntime: true,
            childGovernor: childGovernor
        )
    }

    public static func make(
        maxIterations: Int = 10,
        approvalDelegate: any ApprovalDelegate,
        policyRuntime: PolicyRuntimeBinding? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        turnController: TurnController? = nil,
        requestBudget: BudgetTracker? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = SecureAgentLoopFactory.defaultTimeout
    ) -> AgentLoop {
        make(
            maxIterations: maxIterations,
            approvalGate: ApprovalGate(delegate: approvalDelegate),
            policyRuntime: policyRuntime,
            toolExecutionFactLedger: toolExecutionFactLedger,
            turnController: turnController,
            requestBudget: requestBudget,
            compactor: compactor,
            timeout: timeout
        )
    }

    public static func make(
        maxIterations: Int = 10,
        approvalGate: ApprovalGate,
        policyRuntime: PolicyRuntimeBinding? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        turnController: TurnController? = nil,
        requestBudget: BudgetTracker? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = SecureAgentLoopFactory.defaultTimeout
    ) -> AgentLoop {
        AgentLoop(
            maxIterations: maxIterations,
            approvalGate: approvalGate,
            turnController: turnController,
            requestBudget: requestBudget,
            compactor: compactor,
            timeout: timeout,
            policyRuntime: policyRuntime,
            requiresPolicyRuntime: true,
            toolExecutionFactLedger: toolExecutionFactLedger
        )
    }

    private static func validateChildSnapshot(
        _ snapshot: AgentChildRuntimeSnapshot,
        boundary: AgentChildBoundary,
        expectedCancelGeneration: Int?
    ) throws {
        guard snapshot.isValid else {
            throw SecureAgentLoopError.invalidChildRuntimeSnapshot
        }
        guard snapshot.matches(boundary) else {
            throw SecureAgentLoopError.invalidChildRuntimeSnapshot
        }
        guard let parentTurnHandle = boundary.parentTurnHandle else {
            throw SecureAgentLoopError.childRuntimeSnapshotRequired
        }
        guard snapshot.cancelGeneration == parentTurnHandle.turnID else {
            throw SecureAgentLoopError.childRuntimeGenerationMismatch
        }
        if let expectedCancelGeneration,
           expectedCancelGeneration != snapshot.cancelGeneration {
            throw SecureAgentLoopError.childRuntimeGenerationMismatch
        }
    }
}

public enum SecureAgentLoopError: Error, Equatable, Sendable {
    case approvalGateRequired
    case policyRuntimeRequired
    case childRuntimeSnapshotRequired
    case invalidChildRuntimeSnapshot
    case childRuntimeGenerationMismatch
}

public extension AgentLoop {
    /// 安全运行入口：没有审批门时拒绝启动，不允许生产调用方误走兼容构造器。
    func requireApprovalGate() throws {
        guard approvalGate != nil else { throw SecureAgentLoopError.approvalGateRequired }
    }
}
