import Foundation
import CoreFoundation

/// Immutable binding declaration carried by an OrchestrateRequestV1 task.
public enum ModelBindingV1: Sendable, Equatable {
    case inheritParent
    case explicit(providerID: String, modelID: String, configurationFingerprint: String)
}

/// Versioned public request contract for the opt-in orchestrate tool.
public struct OrchestrateRequestV1: Sendable, Equatable {
    public static let inputVersion = 1
    public static let latestInputVersion = 2
    public typealias Binding = ModelBindingV1

    /// Immutable execution choices carried across the orchestration request
    /// boundary. The selected value is never replaced by the effective value;
    /// callers can explain a conservative runtime decision without losing the
    /// user's request.
    public let childConcurrencySelection: ChildConcurrencySelection
    public let selectedEffort: ComposerEffort
    public let effectiveEffort: ComposerEffort

    public var selectedChildConcurrency: Int {
        childConcurrencySelection.userSelected
    }

    public var requestedChildConcurrency: Int {
        selectedChildConcurrency
    }

    public var recommendedChildConcurrency: Int {
        childConcurrencySelection.recommended
    }

    public var effectiveChildConcurrency: Int {
        childConcurrencySelection.effective
    }

    /// Materializes the execution-only effort budget without discarding the
    /// selected/effective values carried by this request.
    public func makeEffortExecutionProfile(
        baseMaxIterations: Int,
        baseMaxTokens: Int
    ) -> ComposerEffortExecutionProfile {
        ComposerEffortExecutionProfile(
            selectedEffort: selectedEffort,
            effectiveEffort: effectiveEffort,
            baseMaxIterations: baseMaxIterations,
            baseMaxTokens: baseMaxTokens
        )
    }

    public struct Task: Sendable, Equatable {
        public let id: String
        public let title: String
        public let instructions: String
        public let context: String?
        public let expectedOutput: String?
        public let agent: String?
        public let modelBinding: ModelBindingV1
        public let profileID: String?
        public let baseHost: String?
        public let wireAPI: String?
        public let reasoningConfiguration: String?
        public let requiredCapabilities: [String]
        public let resourceRequest: SubAgentResourceRequest?

        public init(
            id: String,
            title: String,
            instructions: String,
            context: String? = nil,
            expectedOutput: String? = nil,
            agent: String? = nil,
            modelBinding: ModelBindingV1 = .inheritParent,
            profileID: String? = nil,
            baseHost: String? = nil,
            wireAPI: String? = nil,
            reasoningConfiguration: String? = nil,
            requiredCapabilities: [String] = [],
            resourceRequest: SubAgentResourceRequest? = nil
        ) {
            self.id = id
            self.title = title
            self.instructions = instructions
            self.context = context
            self.expectedOutput = expectedOutput
            self.agent = agent
            self.modelBinding = modelBinding
            self.profileID = profileID
            self.baseHost = baseHost
            self.wireAPI = wireAPI
            self.reasoningConfiguration = reasoningConfiguration
            self.requiredCapabilities = requiredCapabilities
            self.resourceRequest = resourceRequest
        }
    }

    public let tasks: [Task]

    public init(
        tasks: [Task],
        childConcurrencySelection: ChildConcurrencySelection = .default,
        selectedEffort: ComposerEffort = .standard,
        effectiveEffort: ComposerEffort? = nil
    ) {
        self.tasks = tasks
        self.childConcurrencySelection = childConcurrencySelection
        self.selectedEffort = selectedEffort
        self.effectiveEffort = effectiveEffort ?? selectedEffort
    }

    public static func decode(input: [String: Any], maxTasks: Int) throws -> OrchestrateRequestV1 {
        guard let rawVersion = input["input_version"] else {
            throw ToolExecutorError.missingParameter("input_version")
        }
        guard let version = decodeInteger(rawVersion),
              version == inputVersion || version == latestInputVersion else {
            throw ToolExecutorError.invalidParameter("input_version")
        }
        guard let rawTasks = input["tasks"] else {
            throw ToolExecutorError.missingParameter("tasks")
        }
        guard let taskDictionaries = rawTasks as? [[String: Any]], taskDictionaries.count <= maxTasks else {
            throw ToolExecutorError.invalidParameter("tasks")
        }
        let tasks = try taskDictionaries.map { try decodeTask($0, version: version) }
        guard Set(tasks.map(\.id)).count == tasks.count else {
            throw ToolExecutorError.invalidParameter("tasks")
        }
        let childConcurrencySelection = try decodeChildConcurrencySelection(
            input["child_concurrency"]
                ?? input["child_concurrency_selection"]
                ?? flatChildConcurrencySelection(input)
        )
        let efforts = try decodeEfforts(input)
        return OrchestrateRequestV1(
            tasks: tasks,
            childConcurrencySelection: childConcurrencySelection,
            selectedEffort: efforts.selected,
            effectiveEffort: efforts.effective
        )
    }

    private static func decodeChildConcurrencySelection(_ raw: Any?) throws -> ChildConcurrencySelection {
        guard let raw else { return .default }
        guard let dictionary = raw as? [String: Any] else {
            throw ToolExecutorError.invalidParameter("child_concurrency")
        }
        guard let selected = decodeInteger(dictionary["selected"] ?? dictionary["user_selected"]),
              let recommended = decodeInteger(dictionary["recommended"]),
              let effective = decodeInteger(dictionary["effective"]) else {
            throw ToolExecutorError.invalidParameter("child_concurrency")
        }
        let enabledSessionCount = decodeInteger(dictionary["enabled_session_count"]) ?? 1
        do {
            return try ChildConcurrencySelection(
                userSelected: selected,
                recommended: recommended,
                effective: effective,
                enabledSessionCount: enabledSessionCount
            )
        } catch {
            throw ToolExecutorError.invalidParameter("child_concurrency")
        }
    }

    private static func flatChildConcurrencySelection(_ input: [String: Any]) -> [String: Any]? {
        let keys = [
            "selected_child_concurrency",
            "recommended_child_concurrency",
            "effective_child_concurrency",
            "enabled_session_count"
        ]
        guard keys.contains(where: { input[$0] != nil }) else { return nil }
        var result: [String: Any] = [:]
        if let value = input["selected_child_concurrency"] { result["selected"] = value }
        if let value = input["recommended_child_concurrency"] { result["recommended"] = value }
        if let value = input["effective_child_concurrency"] { result["effective"] = value }
        if let value = input["enabled_session_count"] { result["enabled_session_count"] = value }
        return result
    }

    private static func decodeEfforts(_ input: [String: Any]) throws -> (selected: ComposerEffort, effective: ComposerEffort) {
        let legacy = try optionalEffort(input["effort"], parameter: "effort")
        let explicitSelected = try optionalEffort(input["selected_effort"], parameter: "selected_effort")
        let explicitEffective = try optionalEffort(input["effective_effort"], parameter: "effective_effort")
        if let legacy, let explicitSelected, legacy != explicitSelected {
            throw ToolExecutorError.invalidParameter("effort")
        }
        let selected = explicitSelected ?? legacy ?? .standard
        let effective = explicitEffective ?? selected
        guard effortRank(effective) <= effortRank(selected) else {
            throw ToolExecutorError.invalidParameter("effective_effort")
        }
        return (selected: selected, effective: effective)
    }

    private static func optionalEffort(_ raw: Any?, parameter: String) throws -> ComposerEffort? {
        guard let raw else { return nil }
        guard let value = raw as? String, let effort = ComposerEffort(rawValue: value) else {
            throw ToolExecutorError.invalidParameter(parameter)
        }
        return effort
    }

    private static func effortRank(_ effort: ComposerEffort) -> Int {
        switch effort {
        case .low: return 0
        case .standard: return 1
        case .high: return 2
        }
    }

    /// JSONSerialization may bridge integral values as NSNumber/Int64 rather
    /// than the platform Int used by the in-process fixtures. Accept only
    /// exact, finite integers and reject booleans/fractional values.
    static func decodeInteger(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        // NSNumber-backed JSON integers can report `is Bool` through Swift's
        // bridging rules. Reject only a real Swift Bool here; NSNumber
        // booleans are rejected below by their Core Foundation type identity.
        if type(of: raw) == Bool.self {
            return nil
        }
        // Direct Swift floating-point values are not JSON integer inputs, even
        // when their value happens to be 1. JSONSerialization numbers arrive
        // as NSNumber and are validated below by exact conversion.
        if type(of: raw) == Double.self || type(of: raw) == Float.self {
            return nil
        }
        // Check NSNumber before Swift numeric casts: NSNumber-backed booleans
        // can also dynamically cast to Int/Int64 on Apple platforms.
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double else { return nil }
            let int64 = number.int64Value
            guard Double(int64) == double,
                  number.compare(NSNumber(value: int64)) == .orderedSame else { return nil }
            return Int(exactly: int64)
        }
        if let value = raw as? Int { return value }
        if let value = raw as? Int8 { return Int(value) }
        if let value = raw as? Int16 { return Int(value) }
        if let value = raw as? Int32 { return Int(value) }
        if let value = raw as? Int64 { return Int(exactly: value) }
        if let value = raw as? UInt { return Int(exactly: value) }
        if let value = raw as? UInt8 { return Int(value) }
        if let value = raw as? UInt16 { return Int(value) }
        if let value = raw as? UInt32 { return Int(value) }
        if let value = raw as? UInt64 { return Int(exactly: value) }
        return nil
    }

    private static func decodeTask(_ raw: [String: Any], version: Int) throws -> Task {
        // P03 allocation is runtime-owned: models select only the isolation enum,
        // never a repository, checkout path, branch or starting ref. Keep this
        // explicit and task-local; unrelated unknown keys retain their semantics.
        let runtimeAllocationKeys = [
            "repo", "path", "branch", "ref",
            "isolation_repo", "isolation_path", "isolation_branch", "isolation_ref",
            "repository_path", "worktree_path"
        ]
        if let key = runtimeAllocationKeys.first(where: { raw[$0] != nil }) {
            throw ToolExecutorError.invalidParameter("tasks.\(key)")
        }
        let id = try requiredString(raw, "id")
        let title = try requiredString(raw, "title")
        let instructions = try requiredString(raw, "instructions")
        let flatBindingKeys = ["provider_id", "model_id", "configuration_fingerprint"]
        if flatBindingKeys.contains(where: { raw[$0] != nil }) {
            throw ToolExecutorError.invalidParameter("model_binding")
        }
        let modelBinding = try decodeModelBinding(raw["model_binding"])
        let isBuiltin = raw["agent"] == nil || raw["agent"] as? String == "builtin"
        let capabilities = raw["required_capabilities"] == nil && version != inputVersion && isBuiltin
            ? [ProviderCapability.tools.rawValue] : try decodeCapabilities(raw["required_capabilities"])
        let resourceRequest: SubAgentResourceRequest?
        if version == inputVersion {
            guard raw["allowed_tool_names"] == nil, raw["allowed_read_roots"] == nil,
                  raw["allowed_write_roots"] == nil, raw["working_directory"] == nil else {
                throw ToolExecutorError.invalidParameter("input_version")
            }
            resourceRequest = nil
        } else if raw["allowed_tool_names"] != nil || raw["allowed_read_roots"] != nil
                    || raw["allowed_write_roots"] != nil || raw["working_directory"] != nil {
            resourceRequest = SubAgentResourceRequest(
                allowedToolNames: try decodeResourceValues(raw["allowed_tool_names"], key: "allowed_tool_names"),
                allowedReadRoots: try decodeResourceValues(raw["allowed_read_roots"], key: "allowed_read_roots"),
                allowedWriteRoots: raw["allowed_write_roots"] == nil ? nil
                    : try decodeResourceValues(raw["allowed_write_roots"], key: "allowed_write_roots"),
                workingDirectory: try optionalString(raw, "working_directory"),
                inheritsToolNames: raw["allowed_tool_names"] == nil
            )
        } else {
            resourceRequest = nil
        }
        return Task(
            id: id,
            title: title,
            instructions: instructions,
            context: try optionalString(raw, "context"),
            expectedOutput: try optionalString(raw, "expected_output"),
            agent: try optionalString(raw, "agent"),
            modelBinding: modelBinding,
            profileID: try optionalString(raw, "profile_id"),
            baseHost: try optionalString(raw, "base_host"),
            wireAPI: try optionalString(raw, "wire_api"),
            reasoningConfiguration: try optionalString(raw, "reasoning_configuration"),
            requiredCapabilities: capabilities,
            resourceRequest: resourceRequest
        )
    }

    private static func decodeModelBinding(_ raw: Any?) throws -> ModelBindingV1 {
        guard let raw else { return .inheritParent }
        guard let dictionary = raw as? [String: Any], let kind = dictionary["kind"] as? String else {
            throw ToolExecutorError.invalidParameter("model_binding")
        }
        switch kind {
        case "inherit_parent":
            return .inheritParent
        case "explicit":
            guard let providerID = bindingString(dictionary["provider_id"]),
                  let modelID = bindingString(dictionary["model_id"]),
                  let fingerprint = bindingString(dictionary["configuration_fingerprint"]) else {
                throw ToolExecutorError.invalidParameter("model_binding")
            }
            return .explicit(providerID: providerID, modelID: modelID, configurationFingerprint: fingerprint)
        default:
            throw ToolExecutorError.invalidParameter("model_binding")
        }
    }

    private static func decodeCapabilities(_ raw: Any?) throws -> [String] {
        guard let raw else { return [] }
        guard let values = raw as? [String] else {
            throw ToolExecutorError.invalidParameter("required_capabilities")
        }
        return values
    }

    private static func decodeResourceValues(_ raw: Any?, key: String) throws -> [String] {
        guard let raw else { return [] }
        guard let values = raw as? [String], values.count <= 32,
              values.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw ToolExecutorError.invalidParameter(key)
        }
        return values
    }

    private static func requiredString(_ dictionary: [String: Any], _ key: String) throws -> String {
        guard let value = dictionary[key] else {
            throw ToolExecutorError.missingParameter(key)
        }
        guard let string = value as? String else {
            throw ToolExecutorError.invalidParameter(key)
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutorError.invalidParameter(key)
        }
        return string
    }

    private static func bindingString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func optionalString(_ dictionary: [String: Any], _ key: String) throws -> String? {
        guard let value = dictionary[key] else { return nil }
        guard value is String else { throw ToolExecutorError.invalidParameter(key) }
        return value as? String
    }
}
