import Foundation

/// The three 24C tools are deliberately absent from the default catalog and
/// BuiltinToolExecutor whitelist. The App may publish these definitions only
/// after it has installed a production handler in the policy-gated tool chain.
public enum ProjectSessionToolContract {
    public static let projectList = "project_list"
    public static let projectResolve = "project_resolve"
    public static let sessionCreate = "session_create"

    public static let toolNames: Set<String> = [projectList, projectResolve, sessionCreate]

    public static var definitions: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: projectList,
                description: "List projects already authorized for this turn; grants no access.",
                parameters: ["input_version": .init(type: .integer, description: "Contract version, currently 1.")],
                required: ["input_version"]
            ),
            AgentToolDefinition(
                name: projectResolve,
                description: "Turn a project_id from project_list into an opaque workdir reference; unknown projects need the app's picker and the user's grant.",
                parameters: [
                    "input_version": .init(type: .integer, description: "Contract version, currently 1."),
                    "project_id": .init(type: .string, description: "An ID returned by project_list; never an absolute path.")
                ],
                required: ["input_version", "project_id"]
            ),
            AgentToolDefinition(
                name: sessionCreate,
                description: "Create a new user-visible session running a real task in an authorized project, only when the user explicitly asks for a separate session; for subtasks use orchestrate. Call project_list then project_resolve first. The source conversation stays active unless the user explicitly asked to switch. Approval follows the user's session-creation setting; sub-agents cannot use it.",
                parameters: [
                    "input_version": .init(type: .integer, description: "Contract version, currently 1."),
                    "source_session_id": .init(type: .string, description: "Bound by the runtime; normally omit. If supplied, must equal the trusted active source session."),
                    "source_turn_id": .init(type: .string, description: "Bound by the runtime; normally omit. If supplied, must equal the trusted active source turn."),
                    "project_id": .init(type: .string, description: "An authorized project ID."),
                    "workdir_reference": .init(type: .string, description: "Opaque value from project_resolve, never a path."),
                    "title": .init(type: .string, description: "User-readable title for the new task."),
                    "initial_task": .init(type: .string, description: "Self-contained: the new session does not see this conversation unless capsule_reference is given."),
                    "capsule_reference": .init(type: .string, description: "Optional App-approved minimal context reference."),
                    "switch_after_create": .init(type: .boolean, description: "Defaults to false; true requires independent App proof of explicit user intent."),
                    "idempotency_key": .init(type: .string, description: "Stable key for replay of this source turn and request.")
                ],
                required: ["input_version", "project_id", "workdir_reference", "title", "initial_task", "idempotency_key"]
            )
        ]
    }
}

public enum ProjectSessionToolContractError: Error, Equatable, Sendable {
    case handlerUnavailable
    case untrustedSource
    case unknownTool
    case invalidInput(String)
    case sourceMismatch
    case unauthorizedProject
    case creationNotAuthorized
    case invalidProductionReceipt
}

/// Only the Core runtime can make this value for a tool call. Model input may
/// assert its source IDs, but cannot supply or replace this identity.
public struct ProjectSessionTrustedSource: Sendable, Equatable {
    public let identity: ParentRuntimeIdentity

    internal init(identity: ParentRuntimeIdentity) {
        self.identity = identity
    }
}

/// A grant-owned project reference. The App handler must check current
/// bookmark validity, realpath, root containment and symlink escape before
/// returning it; the model never grants a project by naming a path.
public struct ProjectSessionAuthorizedProject: Sendable, Equatable {
    public let projectID: String
    public let displayName: String
    public let workdirReference: String

    public init(projectID: String, displayName: String, workdirReference: String) {
        self.projectID = projectID
        self.displayName = displayName
        self.workdirReference = workdirReference
    }

    public var isValid: Bool {
        Self.nonblank(projectID) && Self.nonblank(displayName) && Self.nonblank(workdirReference)
            && !workdirReference.hasPrefix("/")
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ProjectSessionCreateRequest: Sendable, Equatable {
    public let source: ProjectSessionTrustedSource
    public let project: ProjectSessionAuthorizedProject
    public let title: String
    public let initialTask: String
    public let capsuleReference: String?
    public let switchAfterCreate: Bool
    public let idempotencyKey: String

    internal init(
        source: ProjectSessionTrustedSource,
        project: ProjectSessionAuthorizedProject,
        title: String,
        initialTask: String,
        capsuleReference: String?,
        switchAfterCreate: Bool,
        idempotencyKey: String
    ) {
        self.source = source
        self.project = project
        self.title = title
        self.initialTask = initialTask
        self.capsuleReference = capsuleReference
        self.switchAfterCreate = switchAfterCreate
        self.idempotencyKey = idempotencyKey
    }
}

/// A committed outcome carries the receipt from the existing canonical task
/// creation consumer. A partial outcome is explicitly unsuccessful and must
/// remain recoverable by the App under the same idempotency key.
public enum ProjectSessionCreateOutcome: Sendable {
    case committed(ProjectSessionCommittedCreation)
    case partial(ProjectSessionPartialCreation)
}

public struct ProjectSessionCommittedCreation: Sendable {
    public let targetSessionID: String
    public let runID: String
    public let sourceBacklinkID: String
    public let creationReceipt: AgentTaskCreationReceipt
    public let didSwitch: Bool

    public init(targetSessionID: String, runID: String, sourceBacklinkID: String, creationReceipt: AgentTaskCreationReceipt, didSwitch: Bool) {
        self.targetSessionID = targetSessionID
        self.runID = runID
        self.sourceBacklinkID = sourceBacklinkID
        self.creationReceipt = creationReceipt
        self.didSwitch = didSwitch
    }
}

public struct ProjectSessionPartialCreation: Sendable, Equatable {
    public let source: ParentRuntimeIdentity
    public let projectID: String
    public let idempotencyKey: String
    public let recoveryReceiptID: String

    public init(source: ParentRuntimeIdentity, projectID: String, idempotencyKey: String, recoveryReceiptID: String) {
        self.source = source
        self.projectID = projectID
        self.idempotencyKey = idempotencyKey
        self.recoveryReceiptID = recoveryReceiptID
    }
}

/// Implemented only by the App production owner. `resolveProject` checks a
/// trusted project registry; `createSession` additionally proves user intent
/// for an explicit switch/capsule and owns session + canonical task/run +
/// source backlink atomicity/reconciliation. `createSession` must recheck the
/// same authorization at its effect boundary; `authorizeCreate` is not a
/// reusable grant. Core never writes those stores.
public protocol ProjectSessionProductionHandler: Sendable {
    func listProjects(source: ProjectSessionTrustedSource) async throws -> [ProjectSessionAuthorizedProject]
    func resolveProject(id: String, source: ProjectSessionTrustedSource) async throws -> ProjectSessionAuthorizedProject
    /// Must establish the App's current user intent, capsule approval and
    /// explicit-switch permission. Model parameters alone never authorize an effect.
    func authorizeCreate(_ request: ProjectSessionCreateRequest) async throws -> Bool
    func createSession(_ request: ProjectSessionCreateRequest) async throws -> ProjectSessionCreateOutcome
}

/// A hidden, fail-closed dispatcher. Production must wrap it in the existing
/// policy/approval/recording chain and publish the definitions only together
/// with a real handler. It does not register any built-in tool name itself.
public final class ProjectSessionToolExecutor: ToolExecutor, @unchecked Sendable {
    private let handler: (any ProjectSessionProductionHandler)?

    public init(handler: (any ProjectSessionProductionHandler)?) {
        self.handler = handler
    }

    public func execute(name: String, input: [String: Any]) async throws -> String {
        guard ProjectSessionToolContract.toolNames.contains(name) else {
            throw ProjectSessionToolContractError.unknownTool
        }
        guard let handler else { throw ProjectSessionToolContractError.handlerUnavailable }
        guard let context = AgentExecutionContext.current,
              context.hasVerifiedParentRuntime,
              let identity = context.parentRuntimeIdentity,
              let turnHandle = context.parentTurnHandle,
              context.currentConversationID == identity.conversationID else {
            throw ProjectSessionToolContractError.untrustedSource
        }
        guard await turnHandle.isActive(),
              !(await turnHandle.isCancelled()), !Task.isCancelled else {
            throw ProjectSessionToolContractError.untrustedSource
        }
        // Keep model-authored, frozen call arguments separate from the trusted
        // execution identity. The outer policy/recording chain retains `input`;
        // only this local execution copy can acquire missing source bindings.
        // Explicit values, including null, empty or malformed ones, must still
        // reach the existing parser and equality checks without replacement.
        var executionInput = input
        if name == ProjectSessionToolContract.sessionCreate {
            if !input.keys.contains("source_session_id") {
                executionInput["source_session_id"] = identity.sessionID
            }
            if !input.keys.contains("source_turn_id") {
                executionInput["source_turn_id"] = identity.turnID
            }
        }
        return try await executeValidated(
            name: name,
            input: executionInput,
            source: ProjectSessionTrustedSource(identity: identity),
            handler: handler
        )
    }

    /// Internal so Core contract tests can exercise parsing/receipt checks
    /// without claiming that a test double is an App production composition.
    internal func executeValidated(
        name: String,
        input: [String: Any],
        source: ProjectSessionTrustedSource,
        handler: any ProjectSessionProductionHandler
    ) async throws -> String {
        guard source.identity.isValid else { throw ProjectSessionToolContractError.untrustedSource }
        guard ProjectSessionToolContract.toolNames.contains(name) else {
            throw ProjectSessionToolContractError.unknownTool
        }
        switch name {
        case ProjectSessionToolContract.projectList:
            try validate(input, allowed: ["input_version"])
            let projects = try await handler.listProjects(source: source)
            guard projects.allSatisfy(\.isValid),
                  Set(projects.map(\.projectID)).count == projects.count else {
                throw ProjectSessionToolContractError.invalidProductionReceipt
            }
            return try encode([
                "ok": true,
                "tool": name,
                "projects": projects.map { projectDictionary($0) }
            ])

        case ProjectSessionToolContract.projectResolve:
            try validate(input, allowed: ["input_version", "project_id"])
            let projectID = try requiredString(input, "project_id")
            try validateProjectID(projectID)
            let project = try await handler.resolveProject(id: projectID, source: source)
            guard project.isValid, project.projectID == projectID else {
                throw ProjectSessionToolContractError.unauthorizedProject
            }
            return try encode(["ok": true, "tool": name, "project": projectDictionary(project)])

        case ProjectSessionToolContract.sessionCreate:
            try validate(input, allowed: [
                "input_version", "source_session_id", "source_turn_id", "project_id",
                "workdir_reference", "title", "initial_task", "capsule_reference",
                "switch_after_create", "idempotency_key"
            ])
            guard try requiredString(input, "source_session_id") == source.identity.sessionID,
                  (try requiredString(input, "source_turn_id")) == source.identity.turnID else {
                throw ProjectSessionToolContractError.sourceMismatch
            }
            let projectID = try requiredString(input, "project_id")
            try validateProjectID(projectID)
            let workdirReference = try requiredString(input, "workdir_reference")
            let title = try requiredString(input, "title")
            let initialTask = try requiredString(input, "initial_task")
            let idempotencyKey = try requiredString(input, "idempotency_key")
            let capsuleReference = try optionalString(input, "capsule_reference")
            let switchAfterCreate = try optionalBool(input, "switch_after_create") ?? false
            let project = try await handler.resolveProject(id: projectID, source: source)
            guard project.isValid, project.projectID == projectID,
                  project.workdirReference == workdirReference else {
                throw ProjectSessionToolContractError.unauthorizedProject
            }
            let request = ProjectSessionCreateRequest(
                source: source, project: project, title: title,
                initialTask: initialTask, capsuleReference: capsuleReference,
                switchAfterCreate: switchAfterCreate, idempotencyKey: idempotencyKey
            )
            guard try await handler.authorizeCreate(request) else {
                throw ProjectSessionToolContractError.creationNotAuthorized
            }
            let outcome = try await handler.createSession(request)
            switch outcome {
            case .committed(let committed):
                let receipt = committed.creationReceipt
                guard nonblank(committed.targetSessionID), nonblank(committed.runID),
                      nonblank(committed.sourceBacklinkID),
                      receipt.request.source == source.identity,
                      receipt.request.parentID == source.identity.taskID,
                      receipt.request.projectID == projectID,
                      receipt.request.idempotencyKey == idempotencyKey,
                      receipt.request.title == title,
                      receipt.snapshot.taskID == receipt.request.taskID,
                      receipt.snapshot.parentID == receipt.request.parentID,
                      receipt.snapshot.creation?.source == source.identity,
                      receipt.action.switchAfterCreate == false,
                      committed.didSwitch == switchAfterCreate else {
                    throw ProjectSessionToolContractError.invalidProductionReceipt
                }
                return try encode([
                    "ok": true, "status": "committed", "tool": name,
                    "source_session_id": source.identity.sessionID,
                    "target_session_id": committed.targetSessionID,
                    "task_id": receipt.request.taskID,
                    "run_id": committed.runID,
                    "project_id": projectID,
                    "workdir_reference": project.workdirReference,
                    "source_backlink_id": committed.sourceBacklinkID,
                    "idempotency_key": idempotencyKey,
                    "did_switch": committed.didSwitch
                ])
            case .partial(let partial):
                guard partial.source == source.identity, partial.projectID == projectID,
                      partial.idempotencyKey == idempotencyKey,
                      nonblank(partial.recoveryReceiptID) else {
                    throw ProjectSessionToolContractError.invalidProductionReceipt
                }
                return try encode([
                    "ok": false, "status": "partial", "tool": name,
                    "recovery_receipt_id": partial.recoveryReceiptID,
                    "idempotency_key": idempotencyKey
                ])
            }
        default:
            throw ProjectSessionToolContractError.unknownTool
        }
    }

    private func validate(_ input: [String: Any], allowed: Set<String>) throws {
        guard Set(input.keys).isSubset(of: allowed) else {
            throw ProjectSessionToolContractError.invalidInput("unknown_key")
        }
        guard let version = OrchestrateRequestV1.decodeInteger(input["input_version"]),
              version == 1 else {
            throw ProjectSessionToolContractError.invalidInput("input_version")
        }
    }

    private func requiredString(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String, nonblank(value) else {
            throw ProjectSessionToolContractError.invalidInput(key)
        }
        return value
    }

    private func optionalString(_ input: [String: Any], _ key: String) throws -> String? {
        guard let value = input[key] else { return nil }
        guard let string = value as? String, nonblank(string) else {
            throw ProjectSessionToolContractError.invalidInput(key)
        }
        return string
    }

    private func optionalBool(_ input: [String: Any], _ key: String) throws -> Bool? {
        guard let value = input[key] else { return nil }
        guard let bool = value as? Bool else {
            throw ProjectSessionToolContractError.invalidInput(key)
        }
        return bool
    }

    private func validateProjectID(_ value: String) throws {
        guard value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProjectSessionToolContractError.invalidInput("project_id")
        }
    }

    private func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func projectDictionary(_ project: ProjectSessionAuthorizedProject) -> [String: String] {
        [
            "project_id": project.projectID,
            "display_name": project.displayName,
            "workdir_reference": project.workdirReference
        ]
    }

    private func encode(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProjectSessionToolContractError.invalidProductionReceipt
        }
        return string
    }
}
