import Foundation

/// Only trusted App composition may supply this list, from the existing applied
/// model picker and frozen runtime identity. Never constructed from tool input.
public struct ReadyChildModel: Sendable {
    public let stableID: String
    public let displayName: String
    public let binding: ParentContextSnapshotV1
    public let maximumThinkingLevel: ThinkingLevel

    public init(stableID: String, displayName: String, binding: ParentContextSnapshotV1,
                maximumThinkingLevel: ThinkingLevel) {
        self.stableID = stableID
        self.displayName = displayName
        self.binding = binding
        self.maximumThinkingLevel = maximumThinkingLevel
    }
}

public enum ChildModelBindingError: Error, LocalizedError, Equatable {
    case unauthorized, notReady(String), invalidThinkingLevel, ambiguousBinding, parentUnavailable

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "未授权子任务使用其他模型和思考档位"
        case .notReady(let id): return "子任务模型未就绪：\(id)"
        case .invalidThinkingLevel: return "子任务思考档位无效"
        case .ambiguousBinding: return "model/thinking_level 不能与旧 model_binding 或 reasoning_configuration 混用"
        case .parentUnavailable: return "无法确认父级模型快照"
        }
    }
}

/// Value snapshot, frozen when the parent tool is composed. Settings changes
/// cannot modify already parsed tasks. No provider/Key/Store ownership here.
public struct ChildModelBindingPolicy: Sendable {
    public let allowsOverrides: Bool
    public let readyModels: [ReadyChildModel]
    public let thinkingLevelCeiling: ThinkingLevel?

    public init(settings: AgentSettings = .default, readyModels: [ReadyChildModel] = []) {
        allowsOverrides = settings.childModelOverridesEnabled
        thinkingLevelCeiling = settings.childModelThinkingLevelCeiling
        self.readyModels = readyModels
    }

    public var toolDescription: String {
        guard allowsOverrides else { return "" }
        let models = readyModels.map {
            "\($0.displayName) [\($0.stableID)]，最高 \(min($0.maximumThinkingLevel, thinkingLevelCeiling ?? $0.maximumThinkingLevel).rawValue)"
        }.joined(separator: "；")
        return "可按任务指定 model（以下稳定 ID）与 thinking_level（缺省继承父级）：\(models)。未就绪拒绝；超上限截断。"
    }

    public func resolve(modelID: String?, thinkingLevel: String?,
                        parent: ParentContextSnapshotV1) throws -> ChildModelSelection {
        let requestedLevel: ThinkingLevel?
        if let thinkingLevel {
            guard let parsed = ThinkingLevel(rawValue: thinkingLevel) else {
                throw ChildModelBindingError.invalidThinkingLevel
            }
            requestedLevel = parsed
        } else { requestedLevel = nil }
        // Picker IDs identify provider instances; runtime bindings may use a
        // provider's wire name. Do not equate those two namespaces.
        let parentMatches = readyModels.filter {
            $0.binding.providerID == parent.providerID && $0.binding.modelID == parent.modelID
                && $0.binding.configurationFingerprint == parent.configurationFingerprint
        }
        let parentModel = parentMatches.count == 1 ? parentMatches[0] : nil
        let parentID = parentModel?.stableID ?? parent.providerID + "/" + parent.modelID
        let isOverride = (modelID != nil && modelID != parentID)
            || (thinkingLevel != nil && thinkingLevel != parent.reasoningConfiguration)
        guard allowsOverrides || !isOverride else { throw ChildModelBindingError.unauthorized }
        let selected: ReadyChildModel?
        if let modelID {
            let matches = readyModels.filter { $0.stableID == modelID }
            guard matches.count == 1 else { throw ChildModelBindingError.notReady(modelID) }
            selected = matches[0]
        } else {
            selected = parentModel
        }
        if thinkingLevel != nil, selected == nil {
            throw ChildModelBindingError.notReady(modelID ?? parentID)
        }
        let binding = modelID == nil ? parent : (selected?.binding ?? parent)
        let changedModel = binding.providerID != parent.providerID || binding.modelID != parent.modelID
            || binding.configurationFingerprint != parent.configurationFingerprint
        guard allowsOverrides || !changedModel else { throw ChildModelBindingError.unauthorized }
        if modelID == nil, thinkingLevel == nil {
            return ChildModelSelection(binding: parent, displayName: selected?.displayName ?? parent.modelID,
                inheritsParent: true, truncationNote: nil)
        }
        let inheritedLevel = parent.reasoningConfiguration.flatMap(ThinkingLevel.init(rawValue:))
        let requested = requestedLevel ?? inheritedLevel
        let maximum = min(selected?.maximumThinkingLevel ?? requested ?? .off,
                          thinkingLevelCeiling ?? selected?.maximumThinkingLevel ?? requested ?? .off)
        let effective = requested.map { min($0, maximum) }
        // Keep the trusted provider identity and only replace its reasoning value.
        let frozen = ParentContextSnapshotV1(providerID: binding.providerID, modelID: binding.modelID,
            configurationFingerprint: binding.configurationFingerprint, profileID: binding.profileID,
            baseHost: binding.baseHost, wireAPI: binding.wireAPI,
            reasoningConfiguration: effective?.rawValue ?? parent.reasoningConfiguration,
            conversationID: parent.conversationID)
        return ChildModelSelection(binding: frozen,
            displayName: selected?.displayName ?? parent.modelID,
            inheritsParent: !changedModel && (effective?.rawValue ?? parent.reasoningConfiguration) == parent.reasoningConfiguration,
            truncationNote: requested != effective ? "已截断到 \(effective?.rawValue ?? "off")" : nil)
    }
}

public struct ChildModelSelection: Sendable {
    public let binding: ParentContextSnapshotV1
    public let displayName: String
    public let inheritsParent: Bool
    public let truncationNote: String?

    public var presentation: String {
        ProductRedactionPolicy.redact(displayName, maxLength: 36) + " · 请求档位 " + (binding.reasoningConfiguration ?? "继承父级档位")
            + (inheritsParent ? "（继承父级）" : "")
            + (truncationNote.map { "；" + $0 } ?? "") + "；是否写入见回执"
    }

    func applying(to task: SubAgentTask, parent: ParentContextSnapshotV1) -> SubAgentTask {
        SubAgentTask(id: task.id, title: presentation + " · " + task.title,
            instructions: task.instructions, context: task.context, expectedOutput: task.expectedOutput,
            agentType: task.agentType, providerID: binding.providerID, modelID: binding.modelID,
            configurationFingerprint: binding.configurationFingerprint, profileID: binding.profileID,
            baseHost: binding.baseHost, wireAPI: binding.wireAPI,
            reasoningConfiguration: binding.reasoningConfiguration, requiredCapabilities: task.requiredCapabilities,
            resourceRequest: task.resourceRequest, executionID: task.executionID,
            parentContextSnapshotID: parent.snapshotID,
            bindingSource: inheritsParent ? .inherited : .explicit)
    }
}
