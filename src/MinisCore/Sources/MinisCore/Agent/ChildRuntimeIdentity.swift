import Foundation

public enum ChildRuntimeIdentityError: Error, Sendable, Equatable {
    case invalidField(String)
    case missingCapability
    case recursiveOrchestrationDenied
    case parentMismatch
    case parentTurnHandleUnavailable
}

public struct ChildRuntimeIdentity: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 3
    private static let maxOpaqueIDBytes = 4_096
    private static let maxCancelGeneration = Int.max - 1

    /// Version of the encoded identity contract. Payloads without this field
    /// are treated as the original v1 shape; unknown versions fail closed.
    public let schemaVersion: Int
    public let parentSessionID: String
    public let parentConversationID: String
    public let parentTurnID: String
    public let parentTaskID: String
    /// In the current one-level production hierarchy the verified parent is
    /// also the root. Legacy callers have no verified root authority.
    public let rootParentIdentity: ParentRuntimeIdentity?
    /// Identity facts copied from the parent's already-frozen GoalEnvelope.
    /// The child's private `scopeID` is deliberately distinct.
    public let parentGoalID: UUID?
    public let parentGoalScopeID: String?
    public let childSessionID: String
    public let childTaskID: String
    public let scopeID: String
    public let grantedCapabilities: Set<ProviderCapability>
    /// Immutable parent/request/catalog/policy provenance for the grant.
    /// Keeping the full intersection on the identity prevents a later child
    /// boundary from widening a grant by re-evaluating only its capabilities.
    public let capabilityIntersection: AgentCapabilityIntersection
    public let providerSnapshot: ParentContextSnapshotV1
    public let memoryScopeID: String
    public let workingDirectory: String
    public let cancelGeneration: Int
    /// Nil means this identity was constructed by a legacy library caller
    /// without a real parent turn handle and is not valid for production
    /// writeback.
    public let generationID: String?
    public let evidenceRoot: String
    public var allowsOrchestration: Bool { false }

    /// Length-prefixed identity used by session/child consumers. Opaque IDs
    /// remain case-sensitive and cannot collide through separators.
    public var compositeIdentityKey: String {
        var parts = [
            parentSessionID, parentConversationID, parentTurnID, parentTaskID,
            childSessionID, childTaskID, scopeID, memoryScopeID,
            String(cancelGeneration), generationID ?? "",
        ]
        if let rootParentIdentity, let parentGoalID, let parentGoalScopeID {
            parts += [rootParentIdentity.actorID, parentGoalID.uuidString, parentGoalScopeID]
        }
        return parts.map { value in
            "\(value.utf8.count)#\(value)"
        }.joined()
    }

    public static func derive(
        parent: ParentRuntimeIdentity,
        childSessionID: String,
        childTaskID: String,
        scopeID: String,
        requestedCapabilities: Set<ProviderCapability>,
        parentCapabilities: Set<ProviderCapability>,
        policyCapabilities: Set<ProviderCapability>,
        providerSnapshot: ParentContextSnapshotV1,
        memoryScopeID: String,
        workingDirectory: String,
        cancelGeneration: Int,
        evidenceRoot: String,
        parentTurnHandle: TurnController.TurnHandle? = nil,
        childExecutionID: String? = nil,
        catalogCapabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases),
        requestsOrchestration: Bool = false,
        parentGoal: GoalEnvelope? = nil
    ) throws -> ChildRuntimeIdentity {
        guard parent.isValid else {
            throw ChildRuntimeIdentityError.invalidField("parentRuntimeIdentity")
        }
        let parentFields = [
            ("parentSessionID", parent.sessionID),
            ("parentConversationID", parent.conversationID),
            ("parentTurnID", parent.turnID),
            ("parentTaskID", parent.taskID),
            ("actorID", parent.actorID),
        ]
        guard parentFields.allSatisfy({ Self.isBoundedOpaqueID($0.1) }) else {
            throw ChildRuntimeIdentityError.invalidField("parentRuntimeIdentity")
        }
        let fields = [
            ("childSessionID", childSessionID), ("childTaskID", childTaskID),
            ("scopeID", scopeID), ("memoryScopeID", memoryScopeID),
            ("workingDirectory", workingDirectory), ("evidenceRoot", evidenceRoot),
        ]
        if let invalid = fields.first(where: {
            !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !Self.isBoundedOpaqueID($0.1)
        }) {
            throw ChildRuntimeIdentityError.invalidField(invalid.0)
        }
        if let invalid = fields.first(where: {
            $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw ChildRuntimeIdentityError.invalidField(invalid.0)
        }
        if let childExecutionID,
           childExecutionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChildRuntimeIdentityError.invalidField("childExecutionID")
        }
        if let childExecutionID, !Self.isBoundedOpaqueID(childExecutionID) {
            throw ChildRuntimeIdentityError.invalidField("childExecutionID")
        }
        guard childSessionID != parent.sessionID else {
            throw ChildRuntimeIdentityError.invalidField("childSessionID")
        }
        guard childTaskID != parent.taskID else {
            throw ChildRuntimeIdentityError.invalidField("childTaskID")
        }
        guard !requestsOrchestration else {
            throw ChildRuntimeIdentityError.recursiveOrchestrationDenied
        }
        let capabilityIntersection = AgentCapabilityIntersection.resolve(
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requestedCapabilities,
            policyCapabilities: policyCapabilities,
            catalogCapabilities: catalogCapabilities,
            requestsOrchestration: requestsOrchestration
        )
        let granted = capabilityIntersection.grantedCapabilities
        guard (0...Self.maxCancelGeneration).contains(cancelGeneration) else {
            throw ChildRuntimeIdentityError.invalidField("cancelGeneration")
        }
        let generationID: String?
        if let parentTurnHandle {
            guard let childExecutionID,
                  !childExecutionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cancelGeneration == parentTurnHandle.turnID else {
                throw ChildRuntimeIdentityError.parentMismatch
            }
            generationID = Self.verifiedGenerationID(
                parentSessionID: parent.sessionID,
                parentTurnID: parentTurnHandle.turnID,
                childSessionID: childSessionID,
                childTaskID: childTaskID,
                childExecutionID: childExecutionID
            )
        } else {
            generationID = nil
        }
        if let parentGoal {
            guard parentTurnHandle != nil,
                  Self.isBoundedOpaqueID(parentGoal.scopeID),
                  !parentGoal.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChildRuntimeIdentityError.parentTurnHandleUnavailable
            }
        }
        return ChildRuntimeIdentity(
            schemaVersion: Self.currentSchemaVersion,
            parentSessionID: parent.sessionID,
            parentConversationID: parent.conversationID,
            parentTurnID: parent.turnID,
            parentTaskID: parent.taskID,
            rootParentIdentity: parentGoal == nil ? nil : parent,
            parentGoalID: parentGoal?.goalID,
            parentGoalScopeID: parentGoal?.scopeID,
            childSessionID: childSessionID,
            childTaskID: childTaskID,
            scopeID: scopeID,
            grantedCapabilities: granted,
            capabilityIntersection: capabilityIntersection,
            providerSnapshot: providerSnapshot,
            memoryScopeID: memoryScopeID,
            workingDirectory: workingDirectory,
            cancelGeneration: cancelGeneration,
            generationID: generationID,
            evidenceRoot: evidenceRoot
        )
    }

    private init(
        schemaVersion: Int,
        parentSessionID: String, parentConversationID: String, parentTurnID: String, parentTaskID: String,
        rootParentIdentity: ParentRuntimeIdentity?, parentGoalID: UUID?, parentGoalScopeID: String?,
        childSessionID: String, childTaskID: String, scopeID: String,
        grantedCapabilities: Set<ProviderCapability>, capabilityIntersection: AgentCapabilityIntersection,
        providerSnapshot: ParentContextSnapshotV1,
        memoryScopeID: String, workingDirectory: String, cancelGeneration: Int,
        generationID: String?, evidenceRoot: String
    ) {
        self.schemaVersion = schemaVersion
        self.parentSessionID = parentSessionID
        self.parentConversationID = parentConversationID
        self.parentTurnID = parentTurnID
        self.parentTaskID = parentTaskID
        self.rootParentIdentity = rootParentIdentity
        self.parentGoalID = parentGoalID
        self.parentGoalScopeID = parentGoalScopeID
        self.childSessionID = childSessionID
        self.childTaskID = childTaskID
        self.scopeID = scopeID
        self.grantedCapabilities = grantedCapabilities
        self.capabilityIntersection = capabilityIntersection
        self.providerSnapshot = providerSnapshot
        self.memoryScopeID = memoryScopeID
        self.workingDirectory = workingDirectory
        self.cancelGeneration = cancelGeneration
        self.generationID = generationID
        self.evidenceRoot = evidenceRoot
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, parentSessionID, parentConversationID, parentTurnID, parentTaskID
        case rootParentIdentity, parentGoalID, parentGoalScopeID
        case childSessionID, childTaskID, scopeID, grantedCapabilities
        case capabilityIntersection, providerSnapshot, memoryScopeID
        case workingDirectory, cancelGeneration, generationID, evidenceRoot
    }

    /// Decode old persisted identities as a self-contained, fail-closed
    /// snapshot. New identities always carry the complete intersection.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unknown child runtime identity schema version"
            )
        }
        schemaVersion = decodedSchemaVersion
        parentSessionID = try container.decode(String.self, forKey: .parentSessionID)
        parentConversationID = try container.decode(String.self, forKey: .parentConversationID)
        parentTurnID = try container.decode(String.self, forKey: .parentTurnID)
        parentTaskID = try container.decode(String.self, forKey: .parentTaskID)
        rootParentIdentity = try container.decodeIfPresent(ParentRuntimeIdentity.self, forKey: .rootParentIdentity)
        parentGoalID = try container.decodeIfPresent(UUID.self, forKey: .parentGoalID)
        parentGoalScopeID = try container.decodeIfPresent(String.self, forKey: .parentGoalScopeID)
        childSessionID = try container.decode(String.self, forKey: .childSessionID)
        childTaskID = try container.decode(String.self, forKey: .childTaskID)
        scopeID = try container.decode(String.self, forKey: .scopeID)
        grantedCapabilities = try container.decode(Set<ProviderCapability>.self, forKey: .grantedCapabilities)
        providerSnapshot = try container.decode(ParentContextSnapshotV1.self, forKey: .providerSnapshot)
        memoryScopeID = try container.decode(String.self, forKey: .memoryScopeID)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        cancelGeneration = try container.decode(Int.self, forKey: .cancelGeneration)
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
        evidenceRoot = try container.decode(String.self, forKey: .evidenceRoot)

        let requiredFields = [
            ("parentSessionID", parentSessionID),
            ("parentConversationID", parentConversationID),
            ("parentTurnID", parentTurnID),
            ("parentTaskID", parentTaskID),
            ("childSessionID", childSessionID),
            ("childTaskID", childTaskID),
            ("scopeID", scopeID),
            ("memoryScopeID", memoryScopeID),
            ("workingDirectory", workingDirectory),
            ("evidenceRoot", evidenceRoot),
        ]
        guard requiredFields.allSatisfy({
            !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.isBoundedOpaqueID($0.1)
        }),
        (0...Self.maxCancelGeneration).contains(cancelGeneration),
        generationID.map(Self.isBoundedOpaqueID) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .cancelGeneration,
                in: container,
                debugDescription: "Child runtime identity has invalid opaque fields or generation"
            )
        }
        guard parentSessionID != childSessionID,
              parentTaskID != childTaskID else {
            throw DecodingError.dataCorruptedError(
                forKey: .childSessionID,
                in: container,
                debugDescription: "Child runtime identity collides with its parent"
            )
        }
        let hasRootBoundary = rootParentIdentity != nil || parentGoalID != nil || parentGoalScopeID != nil
        if hasRootBoundary {
            guard let rootParentIdentity, let parentGoalID, let parentGoalScopeID,
                  rootParentIdentity.isValid,
                  rootParentIdentity.sessionID == parentSessionID,
                  rootParentIdentity.conversationID == parentConversationID,
                  rootParentIdentity.turnID == parentTurnID,
                  rootParentIdentity.taskID == parentTaskID,
                  childSessionID != rootParentIdentity.sessionID,
                  childTaskID != rootParentIdentity.taskID,
                  Self.isBoundedOpaqueID(parentGoalScopeID),
                  !parentGoalScopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rootParentIdentity, in: container,
                    debugDescription: "Child root or parent Goal boundary is inconsistent"
                )
            }
            _ = parentGoalID
        }

        capabilityIntersection = try container.decodeIfPresent(
            AgentCapabilityIntersection.self,
            forKey: .capabilityIntersection
        ) ?? AgentCapabilityIntersection(
            parentCapabilities: grantedCapabilities,
            requestedCapabilities: grantedCapabilities,
            policyCapabilities: grantedCapabilities
        )
        guard capabilityIntersection.grantedCapabilities == grantedCapabilities else {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilityIntersection,
                in: container,
                debugDescription: "Child capability grant does not match its immutable intersection"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parentSessionID, forKey: .parentSessionID)
        try container.encode(parentConversationID, forKey: .parentConversationID)
        try container.encode(parentTurnID, forKey: .parentTurnID)
        try container.encode(parentTaskID, forKey: .parentTaskID)
        try container.encodeIfPresent(rootParentIdentity, forKey: .rootParentIdentity)
        try container.encodeIfPresent(parentGoalID, forKey: .parentGoalID)
        try container.encodeIfPresent(parentGoalScopeID, forKey: .parentGoalScopeID)
        try container.encode(childSessionID, forKey: .childSessionID)
        try container.encode(childTaskID, forKey: .childTaskID)
        try container.encode(scopeID, forKey: .scopeID)
        try container.encode(grantedCapabilities, forKey: .grantedCapabilities)
        try container.encode(capabilityIntersection, forKey: .capabilityIntersection)
        try container.encode(providerSnapshot, forKey: .providerSnapshot)
        try container.encode(memoryScopeID, forKey: .memoryScopeID)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(cancelGeneration, forKey: .cancelGeneration)
        try container.encodeIfPresent(generationID, forKey: .generationID)
        try container.encode(evidenceRoot, forKey: .evidenceRoot)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    }

    public func requireVerifiedGeneration() throws {
        guard let generationID,
              !generationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cancelGeneration >= 0 else {
            throw ChildRuntimeIdentityError.parentTurnHandleUnavailable
        }
    }

    /// Bind a terminal result to the execution frozen when this child was
    /// admitted. A missing generation is never proof of a production result.
    func matchesVerifiedExecutionID(_ childExecutionID: String) -> Bool {
        guard let generationID else { return false }
        return generationID == Self.verifiedGenerationID(
            parentSessionID: parentSessionID,
            parentTurnID: cancelGeneration,
            childSessionID: childSessionID,
            childTaskID: childTaskID,
            childExecutionID: childExecutionID
        )
    }

    private static func verifiedGenerationID(
        parentSessionID: String,
        parentTurnID: Int,
        childSessionID: String,
        childTaskID: String,
        childExecutionID: String
    ) -> String {
        [
            "parent-session:\(parentSessionID)",
            "parent-turn:\(parentTurnID)",
            "child-session:\(childSessionID)",
            "child-task:\(childTaskID)",
            "execution:\(childExecutionID)"
        ].joined(separator: "|")
    }

    /// Provenance check only; it does not grant tools or change Goal policy.
    public func hasVerifiedRootBoundary(
        parent: ParentRuntimeIdentity, goal: GoalEnvelope
    ) -> Bool {
        rootParentIdentity == parent
            && parentGoalID == goal.goalID
            && parentGoalScopeID == goal.scopeID
            && parentSessionID == parent.sessionID
            && parentConversationID == parent.conversationID
            && parentTurnID == parent.turnID
            && parentTaskID == parent.taskID
            && childSessionID != parent.sessionID
            && childTaskID != parent.taskID
    }

    /// Compare the original runtime derivation without treating the child's
    /// persisted root/Goal claims as independent authority. The task store
    /// separately pins those claims to the admitted parent and Goal.
    public func matchesCanonicalExecution(_ canonical: ChildRuntimeIdentity) -> Bool {
        parentSessionID == canonical.parentSessionID
            && parentConversationID == canonical.parentConversationID
            && parentTurnID == canonical.parentTurnID
            && parentTaskID == canonical.parentTaskID
            && childSessionID == canonical.childSessionID
            && childTaskID == canonical.childTaskID
            && scopeID == canonical.scopeID
            && grantedCapabilities == canonical.grantedCapabilities
            && capabilityIntersection == canonical.capabilityIntersection
            && providerSnapshot == canonical.providerSnapshot
            && memoryScopeID == canonical.memoryScopeID
            && workingDirectory == canonical.workingDirectory
            && cancelGeneration == canonical.cancelGeneration
            && generationID == canonical.generationID
            && evidenceRoot == canonical.evidenceRoot
    }

    private static func isBoundedOpaqueID(_ value: String) -> Bool {
        value.utf8.count <= maxOpaqueIDBytes
    }

    public func validating(required: Set<ProviderCapability>, requestsOrchestration: Bool) throws {
        if (requestsOrchestration || capabilityIntersection.requestsOrchestration) && !allowsOrchestration {
            throw ChildRuntimeIdentityError.recursiveOrchestrationDenied
        }
        guard required.isSubset(of: capabilityIntersection.grantedCapabilities),
              capabilityIntersection.grantedCapabilities == grantedCapabilities,
              capabilityIntersection.unknownCapabilities.isEmpty else {
            throw ChildRuntimeIdentityError.missingCapability
        }
    }
}
