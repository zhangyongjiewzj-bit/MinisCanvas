import Foundation
import Testing
@testable import MinisCore

@Suite("D-SETC model-facing settings tool boundary")
struct BL6SettingsModelCatalog2093Tests {
    @Test("default catalog omits settings; opt-in advertises exact read and approved mutation tools")
    func catalogIsBoundToInstalledSettingsOwner() throws {
        let names = Set(AgentToolCatalog.makeTools().map(\.name))
        #expect(!names.contains(BL6SettingsToolApproval.catalogToolName))
        #expect(!names.contains(BL6SettingsToolApproval.toolName))

        let tools = AgentToolCatalog.makeTools(orchestration: nil, settingsAvailable: true)
        #expect(tools.filter { $0.name == BL6SettingsToolApproval.catalogToolName }.count == 1)
        #expect(tools.filter { $0.name == BL6SettingsToolApproval.toolName }.count == 1)
        let catalog = try #require(tools.first { $0.name == BL6SettingsToolApproval.catalogToolName })
        #expect(catalog.parameters.isEmpty)
        #expect(catalog.required.isEmpty)
        let mutation = try #require(tools.first { $0.name == BL6SettingsToolApproval.toolName })
        #expect(Set(mutation.parameters.keys) == ["operation", "changes", "expectedRevision", "undoReceiptID"])
        #expect(Set(mutation.required) == ["operation", "expectedRevision"])
        #expect(mutation.parameters["operation"]?.enumValues == ["apply", "reset", "rollback"])
        #expect(mutation.parameters["changes"]?.type == .object)
        #expect(!mutation.parameters.keys.contains("grant"))
        #expect(!mutation.parameters.keys.contains("approval"))
        #expect(!mutation.parameters.keys.contains("credential"))
    }

    @Test("OpenAI and Anthropic schema both preserve object changes without credential fields")
    func providerSchemasKeepClosedTopLevel() throws {
        let mutation = AgentToolCatalog.makeConversationSettingsDefinition()
        let openAI = try #require(mutation.openAIFunctionDict["function"] as? [String: Any])
        let openAIParameters = try #require(openAI["parameters"] as? [String: Any])
        let openAIProperties = try #require(openAIParameters["properties"] as? [String: [String: Any]])
        #expect(openAIProperties["changes"]?["type"] as? String == "object")
        #expect(openAIProperties["expectedRevision"]?["type"] as? String == "string")
        #expect(Set(openAIProperties.keys) == Set(mutation.parameters.keys))

        let anthropic = try #require(mutation.anthropicToolDict["input_schema"] as? [String: Any])
        let anthropicProperties = try #require(anthropic["properties"] as? [String: [String: Any]])
        #expect(anthropicProperties["changes"]?["type"] as? String == "object")
        #expect(Set(anthropicProperties.keys) == Set(mutation.parameters.keys))
    }

    @Test("catalog read and mutation both require separate approval under auto")
    func approvalPoliciesStaySeparate() {
        let gate = ApprovalGate(policy: .autoApprove)
        #expect(gate.isKnownTool(BL6SettingsToolApproval.catalogToolName))
        #expect(gate.policy(for: BL6SettingsToolApproval.catalogToolName) == .alwaysAsk)
        #expect(gate.isKnownTool(BL6SettingsToolApproval.toolName))
        #expect(gate.policy(for: BL6SettingsToolApproval.toolName) == .alwaysAsk)
        #expect(gate.riskLevel(for: BL6SettingsToolApproval.toolName) == .high)

        let denied = ApprovalGate(policy: .deny)
        #expect(denied.policy(for: BL6SettingsToolApproval.catalogToolName) == .deny)
        #expect(denied.policy(for: BL6SettingsToolApproval.toolName) == .deny)
    }

    @Test("a catalog read consumes the same approved tool receipt exactly once")
    func approvedCatalogReadIsCallBound() async throws {
        let suffix = UUID().uuidString
        let now = Date()
        let callID = "read:\(suffix)"
        let attemptID = "attempt:\(suffix)"
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "session:\(suffix)", turnID: 1, taskID: "task:\(suffix)",
            attemptID: attemptID, messageID: "message:\(suffix)",
            workspaceID: "workspace:\(suffix)", createdAt: now,
            policyRevision: "policy:\(suffix)", grantEpoch: "epoch:\(suffix)",
            autonomyCeiling: .l3
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [BL6SettingsToolApproval.catalogToolName],
            grantedCapabilities: [BL6SettingsToolApproval.catalogToolName],
            allowedWriteRoots: [], workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision, grantEpoch: snapshot.grantEpoch,
            leaseID: "lease:\(suffix)", expiresAt: now.addingTimeInterval(120),
            autonomyCeiling: .l3
        )
        let base = CatalogReadProbe()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: BoundApprovalDelegate())
        )
        let authorization = try await executor.authorizeExecution(
            callID: callID, name: BL6SettingsToolApproval.catalogToolName, input: [:]
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: snapshot.sessionID, turnID: snapshot.turnID,
                messageID: snapshot.messageID
            ), operationID: "operation:\(suffix)", attempt: 1
        )
        let key = ToolExecutionCompositeKey(
            sessionID: snapshot.sessionID, turnID: snapshot.turnID,
            messageID: snapshot.messageID, operationID: identity.operationID,
            attemptID: attemptID, attemptNumber: 1, toolCallID: callID
        )
        let receipt = ToolExecutionReceipt(
            toolCallID: callID, receiptID: "receipt:\(suffix)",
            toolName: BL6SettingsToolApproval.catalogToolName,
            attemptID: attemptID, attemptNumber: 1,
            executionIdentity: identity, compositeKey: key
        )
        let output = try await ToolExecutionReceiptContext.$current.withValue(receipt) {
            try await executor.execute(
                preauthorization: authorization, callID: callID,
                name: BL6SettingsToolApproval.catalogToolName, input: [:]
            )
        }
        #expect(output == "approved catalog read")
        #expect(await base.effectCount == 1)
        await #expect(throws: (any Error).self) {
            try await base.execute(name: BL6SettingsToolApproval.catalogToolName, input: [:])
        }
        #expect(await base.effectCount == 1)
    }

    @Test("Policy wrapper forwards catalog validation to the installed owner")
    func policyWrapperDoesNotHideCatalogValidation() {
        let now = Date()
        let goal = GoalEnvelope(
            scopeID: "task:setc-validator", allowedCapabilities: [],
            budget: 1, deadline: now.addingTimeInterval(60), createdAt: now
        )
        let wrapper = PolicyEnforcedToolExecutor(
            base: RejectingCatalogOwner(), goal: goal, lease: nil
        )
        #expect(throws: CatalogValidationProbeError.rejected) {
            try wrapper.validateToolCatalog([
                AgentToolCatalog.makeSettingsCatalogDefinition()
            ])
        }
    }

    private enum CatalogValidationProbeError: Error, Equatable {
        case rejected
    }

    private struct RejectingCatalogOwner: ToolCatalogValidatingExecutor {
        func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
            throw CatalogValidationProbeError.rejected
        }

        func execute(name: String, input: [String: Any]) async throws -> String {
            throw CatalogValidationProbeError.rejected
        }
    }

    private struct BoundApprovalDelegate: ApprovalDelegate {
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            ApprovalDecision(
                approved: true, confirmed: true,
                requestID: request.requestID, bindingDigest: request.identityDigest
            )
        }
    }

    private actor CatalogReadProbe: ToolExecutor {
        private(set) var effectCount = 0

        nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
            guard name == BL6SettingsToolApproval.catalogToolName,
                  let read = BL6SettingsToolApproval.currentCatalogRead else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            _ = try await read.consumeCurrent()
            await recordEffect()
            return "approved catalog read"
        }

        private func recordEffect() { effectCount += 1 }
    }
}
