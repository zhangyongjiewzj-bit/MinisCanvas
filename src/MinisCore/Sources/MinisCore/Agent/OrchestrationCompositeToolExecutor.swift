import Foundation

/// Opt-in executor composition for the Agent-First orchestration capability.
/// The base executor remains authoritative for every name except "orchestrate".
public final class OrchestrationCompositeToolExecutor: ToolCatalogValidatingExecutor, PolicyRuntimeBoundToolExecutor, PolicyCapabilityResolving, SessionReadCapabilityAwareToolExecutor, BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    public let base: any ToolExecutor
    public let orchestration: OrchestrationToolExecutor
    public var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
    private let makeRuntimeOrchestrator: (@Sendable (AgentExecutionContextSnapshot) async throws -> AgentOrchestrator)?

    public init(
        base: any ToolExecutor,
        orchestration: OrchestrationToolExecutor,
        makeRuntimeOrchestrator: (@Sendable (AgentExecutionContextSnapshot) async throws -> AgentOrchestrator)? = nil
    ) {
        self.base = base
        self.orchestration = orchestration
        self.makeRuntimeOrchestrator = makeRuntimeOrchestrator
    }

    public func execute(name: String, input: [String: Any]) async throws -> String {
        if name == OrchestrationToolExecutor.toolName || name == OrchestrationToolExecutor.resultToolName {
            let executor: OrchestrationToolExecutor
            if let makeRuntimeOrchestrator, let context = AgentExecutionContext.current {
                executor = OrchestrationToolExecutor(orchestrator: try await makeRuntimeOrchestrator(context),
                    resultFactsSource: orchestration.resultFactsSource)
            } else {
                executor = orchestration
            }
            return try await executor.execute(name: name, input: input)
        }
        return try await base.execute(name: name, input: input)
    }

    public var currentBuiltinOwner: BuiltinToolExecutor? {
        (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    public func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        if name == OrchestrationToolExecutor.toolName || name == OrchestrationToolExecutor.resultToolName {
            return try await execute(name: name, input: input)
        }
        return try await executeThroughBoundBuiltinOwner(base, owner: owner, name: name, input: input)
    }

    public func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
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

    public func resolvesCapability(_ name: String) async throws -> Bool {
        if name == OrchestrationToolExecutor.toolName || name == OrchestrationToolExecutor.resultToolName { return true }
        guard let resolver = base as? any PolicyCapabilityResolving else { return false }
        return try await resolver.resolvesCapability(name)
    }

    public func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        // A child receives a capability/resource-scoped projection of its
        // parent's executor. Omission keeps orchestrate unexposed; validation
        // must not turn that omission into a requirement to grant it.
        guard tools.filter({ $0.name == OrchestrationToolExecutor.toolName }).count <= 1,
              tools.filter({ $0.name == OrchestrationToolExecutor.resultToolName }).count <= 1 else {
            throw ToolExecutorError.invalidParameter("duplicate_orchestration_definition")
        }
        let withoutOrchestration = tools.filter { $0.name != OrchestrationToolExecutor.toolName && $0.name != OrchestrationToolExecutor.resultToolName }
        guard let validator = base as? any ToolCatalogValidatingExecutor else { return }
        try validator.validateToolCatalog(withoutOrchestration)
    }
}
