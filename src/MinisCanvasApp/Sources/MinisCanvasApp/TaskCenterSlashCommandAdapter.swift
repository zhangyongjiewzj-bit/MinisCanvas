import Foundation
import MinisCore

/// Read-only provider used by the task-center slash contract.
///
/// The provider returns an already captured observation. It must not perform task
/// mutations, transcript reads, or model/provider calls.
public typealias TaskCenterObservationProvider = @Sendable () -> TaskCenterObservationSnapshot

/// A redacted, immutable scheduler read model for the task-center slash
/// boundary. The command/prompt, credentials, and process output are
/// deliberately not part of this contract.
public struct SchedulerSlashOccurrenceSnapshot: Codable, Equatable, Sendable {
    public let occurrenceID: String
    public let taskID: String
    public let effectID: String
    public let idempotencyKey: String
    /// Definition version fixed when this occurrence was created.
    public let taskVersion: Int?
    /// Present only for a new attempt explicitly linked to a reconciled one.
    public let retryOfOccurrenceID: String?
    public let state: String
    public let recoveryAction: String
    /// Stable Chinese copy for the user-facing task center. The raw state and
    /// machine action remain available for automation consumers.
    public let userFacingState: String
    public let userFacingRecoveryAction: String
    public let requiresUserAction: Bool

    public init(
        occurrenceID: String,
        taskID: String,
        effectID: String,
        idempotencyKey: String,
        taskVersion: Int? = nil,
        retryOfOccurrenceID: String? = nil,
        state: String,
        recoveryAction: String,
        userFacingState: String? = nil,
        userFacingRecoveryAction: String? = nil,
        requiresUserAction: Bool? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.taskID = taskID
        self.effectID = effectID
        self.idempotencyKey = idempotencyKey
        self.taskVersion = taskVersion
        self.retryOfOccurrenceID = retryOfOccurrenceID
        self.state = state
        self.recoveryAction = recoveryAction
        self.userFacingState = userFacingState ?? state
        self.userFacingRecoveryAction = userFacingRecoveryAction ?? recoveryAction
        self.requiresUserAction = requiresUserAction ?? (recoveryAction != "none")
    }
}

public struct SchedulerSlashObservation: Codable, Equatable, Sendable {
    public let totalTasks: Int
    public let enabledTasks: Int
    public let totalOccurrences: Int
    public let stateCounts: [String: Int]
    public let occurrences: [SchedulerSlashOccurrenceSnapshot]

    public init(
        totalTasks: Int,
        enabledTasks: Int,
        totalOccurrences: Int,
        stateCounts: [String: Int],
        occurrences: [SchedulerSlashOccurrenceSnapshot]
    ) {
        self.totalTasks = max(0, totalTasks)
        self.enabledTasks = max(0, enabledTasks)
        self.totalOccurrences = max(0, totalOccurrences)
        self.stateCounts = stateCounts
        self.occurrences = occurrences
    }

    /// Captures only scheduler metadata and is intended to be called by the
    /// main-actor composition root. It never serializes a task command.
    @MainActor
    static func capture(from store: SchedulerTaskStore) -> SchedulerSlashObservation {
        let rows = store.occurrences
            .sorted { $0.createdAt < $1.createdAt }
            .map { occurrence in
                SchedulerSlashOccurrenceSnapshot(
                    occurrenceID: occurrence.id.uuidString.lowercased(),
                    taskID: occurrence.taskID.uuidString.lowercased(),
                    effectID: occurrence.effectID,
                    idempotencyKey: occurrence.idempotencyKey,
                    taskVersion: occurrence.taskVersion,
                    retryOfOccurrenceID: occurrence.retryOfOccurrenceID?.uuidString.lowercased(),
                    state: occurrence.state.rawValue,
                    recoveryAction: Self.recoveryAction(for: occurrence.state),
                    userFacingState: Self.userFacingState(for: occurrence.state),
                    userFacingRecoveryAction: Self.userFacingRecoveryAction(for: occurrence.state),
                    requiresUserAction: Self.requiresUserAction(for: occurrence.state)
                )
            }
        var counts: [String: Int] = [:]
        for row in rows {
            counts[row.state, default: 0] += 1
        }
        return SchedulerSlashObservation(
            totalTasks: store.allTasks().count,
            enabledTasks: store.enabledTasks().count,
            totalOccurrences: rows.count,
            stateCounts: counts,
            occurrences: rows
        )
    }

    private static func recoveryAction(for state: SchedulerOccurrenceState) -> String {
        switch state {
        case .triggered, .authorized, .admitted, .dispatched: return "resume"
        case .waitingApproval: return "approve_or_cancel"
        case .leased, .running: return "none"
        case .unknown, .unknownReconciled: return "reconcile"
        case .failed, .retryRequested: return "retry_or_inspect"
        case .succeeded, .cancelled, .aborted: return "none"
        }
    }

    static func userFacingState(for state: SchedulerOccurrenceState) -> String {
        switch state {
        case .triggered: return "待调度"
        case .waitingApproval: return "等待授权"
        case .authorized: return "已授权"
        case .admitted: return "已接纳"
        case .dispatched: return "已派发"
        case .leased: return "已取得执行租约"
        case .running: return "执行中"
        case .succeeded: return "已完成"
        case .failed: return "执行失败"
        case .cancelled: return "已取消"
        case .unknown: return "结果未知"
        case .unknownReconciled: return "未知结果已核对"
        case .retryRequested: return "已请求重试"
        case .aborted: return "已终止"
        }
    }

    static func userFacingDeliveryStatus(_ status: SchedulerDeliveryReceipt.Status) -> String {
        switch status {
        case .delivered: return "已投递"
        case .failed: return "投递失败"
        case .unknown: return "投递结果未知"
        }
    }

    private static func userFacingRecoveryAction(for state: SchedulerOccurrenceState) -> String {
        switch state {
        case .triggered, .authorized, .admitted, .dispatched:
            return "调度器会继续处理"
        case .waitingApproval:
            return "请授权或取消"
        case .unknown, .unknownReconciled:
            return "请核对执行结果"
        case .leased, .running:
            return "执行中，无需重试"
        case .failed, .retryRequested:
            return "请检查后重试或查看详情"
        case .succeeded, .cancelled, .aborted:
            return "无需操作"
        }
    }

    private static func requiresUserAction(for state: SchedulerOccurrenceState) -> Bool {
        switch state {
        case .waitingApproval, .unknown, .unknownReconciled, .failed, .retryRequested:
            return true
        case .triggered, .authorized, .admitted, .dispatched, .leased, .running,
             .succeeded, .cancelled, .aborted:
            return false
        }
    }
}

public typealias SchedulerSlashObservationProvider = @Sendable () -> SchedulerSlashObservation

/// Stable, redacted JSON adapter for the task-center slash read model.
///
/// Supported commands are `/status`, `/tasks`, `/boundary`, `/provider`, and
/// the metadata-only `/scheduler` read.
/// This adapter has no command/use-case or provider execution path.
public struct TaskCenterSlashCommandAdapter: Sendable {
    public static let schemaVersion = 1

    private let observationProvider: TaskCenterObservationProvider
    private let schedulerObservationProvider: SchedulerSlashObservationProvider?

    public init(observation: TaskCenterObservationSnapshot) {
        self.observationProvider = { observation }
        self.schedulerObservationProvider = nil
    }

    /// Both snapshots are captured by the composition root from its canonical
    /// stores; the adapter never owns a second scheduler or executes controls.
    public init(
        observation: TaskCenterObservationSnapshot,
        schedulerObservation: SchedulerSlashObservation
    ) {
        self.observationProvider = { observation }
        self.schedulerObservationProvider = { schedulerObservation }
    }

    public init(viewModel: TaskCenterViewModel) {
        self.observationProvider = { TaskCenterObservationSnapshot(viewModel: viewModel) }
        self.schedulerObservationProvider = nil
    }

    public init(provider: @escaping TaskCenterObservationProvider) {
        self.observationProvider = provider
        self.schedulerObservationProvider = nil
    }

    /// Creates an adapter with a scheduler read model. A missing scheduler
    /// provider is an explicit unavailable error rather than an empty/green
    /// response, preventing stale UI from being mistaken for live state.
    public init(schedulerObservation: @escaping SchedulerSlashObservationProvider) {
        self.observationProvider = { TaskCenterObservationSnapshot(snapshots: []) }
        self.schedulerObservationProvider = schedulerObservation
    }

    /// Returns true only for the task-center command names. This lets the
    /// composition root route malformed supported commands to the JSON error
    /// contract without intercepting unrelated slash commands.
    public static func handles(_ input: String) -> Bool {
        let firstToken = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        guard let firstToken else { return false }
        return Command(rawValue: String(firstToken)) != nil
    }

    /// Executes a slash read and returns stable JSON. Invalid input never reads the
    /// injected observation provider and never echoes the submitted text.
    public func execute(_ input: String) -> String {
        let parsed = Self.parse(input)
        switch parsed {
        case let .failure(code):
            return Self.encode(Envelope(
                command: nil,
                ok: false,
                error: ErrorPayload(code: code.rawValue),
                payload: nil
            ))
        case let .success(command, parameters):
            let payload: Payload

            switch command {
            case .status:
                payload = .status(StatusPayload(observation: observationProvider()))
            case .tasks:
                payload = .tasks(TasksPayload(observation: observationProvider(), parameters: parameters))
            case .boundary:
                payload = .boundary(BoundaryPayload())
            case .provider:
                payload = .provider(ProviderPayload(observation: observationProvider(), parameters: parameters))
            case .scheduler:
                guard let schedulerObservationProvider else {
                    return Self.encode(Envelope(
                        command: command.rawValue,
                        ok: false,
                        error: ErrorPayload(code: "scheduler_unavailable"),
                        payload: nil
                    ))
                }
                payload = .scheduler(SchedulerPayload(observation: schedulerObservationProvider()))
            }

            return Self.encode(Envelope(
                command: command.rawValue,
                ok: true,
                error: nil,
                payload: payload
            ))
        }
    }
}

private extension TaskCenterSlashCommandAdapter {
    enum Command: String {
        case status = "/status"
        case tasks = "/tasks"
        case boundary = "/boundary"
        case provider = "/provider"
        case scheduler = "/scheduler"
    }

    enum ParameterError: String {
        case invalidSyntax = "invalid_syntax"
        case unknownCommand = "unknown_command"
        case unsupportedParameter = "unsupported_parameter"
        case repeatedParameter = "repeated_parameter"
        case sensitiveParameter = "sensitive_parameter"
        case invalidParameter = "invalid_parameter"
        case parametersNotAllowed = "parameters_not_allowed"
    }

    struct ParsedCommand {
        let command: Command
        let parameters: [String: String]
    }

    enum ParseResult {
        case success(Command, [String: String])
        case failure(ParameterError)
    }

    static func parse(_ input: String) -> ParseResult {
        guard let tokens = tokenize(input), let first = tokens.first else {
            return .failure(.invalidSyntax)
        }
        guard let command = Command(rawValue: first) else {
            return .failure(.unknownCommand)
        }

        if tokens.count == 1 {
            return .success(command, [:])
        }

        // Read-only commands deliberately have no parameter surface. Reject
        // that shape before validating individual keys so callers receive a
        // stable boundary error instead of an accidental allowlist detail.
        guard command == .tasks || command == .provider else {
            return .failure(.parametersNotAllowed)
        }

        var parameters: [String: String] = [:]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            let pair: (String, String)?

            if let separator = token.firstIndex(of: "=") {
                pair = (
                    String(token[..<separator]),
                    String(token[token.index(after: separator)...])
                )
            } else if token.hasPrefix("--"), index + 1 < tokens.count {
                pair = (String(token.dropFirst(2)), tokens[index + 1])
                index += 1
            } else {
                if Self.looksSensitive(token) {
                    return .failure(.sensitiveParameter)
                }
                return .failure(.invalidSyntax)
            }

            guard var key = pair?.0.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = pair?.1.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty,
                  !value.isEmpty
            else {
                return .failure(.invalidParameter)
            }

            if key.hasPrefix("--") {
                key.removeFirst(2)
            }
            key = key.lowercased()

            if Self.looksSensitive(key) || Self.looksSensitive(value) {
                return .failure(.sensitiveParameter)
            }
            guard Self.allowedParameters(for: command).contains(key) else {
                return .failure(.unsupportedParameter)
            }
            guard parameters[key] == nil else {
                return .failure(.repeatedParameter)
            }
            guard value.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }) else {
                return .failure(.invalidParameter)
            }

            parameters[key] = value
            index += 1
        }

        if command == .tasks, let status = parameters["status"],
           !["queued", "running", "succeeded", "failed", "cancelled"].contains(status.lowercased()) {
            return .failure(.invalidParameter)
        }

        return .success(command, parameters)
    }

    static func allowedParameters(for command: Command) -> Set<String> {
        switch command {
        case .tasks:
            return ["status", "task_id", "parent_id", "provider_id", "model_id", "route_receipt_id"]
        case .provider:
            return ["provider_id"]
        case .status, .boundary, .scheduler:
            return []
        }
    }

    static func looksSensitive(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let markers = [
            "api_key", "apikey", "authorization", "bearer", "cookie", "credential",
            "password", "passwd", "secret", "token", "private_key", "privatekey",
            "client_secret", "access_key", "refresh_token"
        ]
        return markers.contains { normalized.contains($0) }
    }

    static func tokenize(_ input: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                guard character == "\"" || character == "'" || character == "\\" else { return nil }
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" || character == "\n" || character == "\r" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        guard !escaping, quote == nil else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

private extension TaskCenterSlashCommandAdapter {
    struct Envelope: Encodable {
        let command: String?
        let ok: Bool
        let error: ErrorPayload?
        let payload: Payload?
        let schemaVersion: Int = TaskCenterSlashCommandAdapter.schemaVersion

        enum CodingKeys: String, CodingKey {
            case command, ok, error, payload
            case schemaVersion = "schema_version"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
            try container.encode(ok, forKey: .ok)
            try container.encode(error, forKey: .error)
            try container.encode(payload, forKey: .payload)
            try container.encode(schemaVersion, forKey: .schemaVersion)
        }
    }

    struct ErrorPayload: Encodable {
        let code: String
    }

    enum Payload: Encodable {
        case status(StatusPayload)
        case tasks(TasksPayload)
        case boundary(BoundaryPayload)
        case provider(ProviderPayload)
        case scheduler(SchedulerPayload)

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .status(value): try value.encode(to: encoder)
            case let .tasks(value): try value.encode(to: encoder)
            case let .boundary(value): try value.encode(to: encoder)
            case let .provider(value): try value.encode(to: encoder)
            case let .scheduler(value): try value.encode(to: encoder)
            }
        }
    }

    struct SchedulerOccurrencePayload: Encodable {
        let effectID: String
        let idempotencyKey: String
        let taskVersion: Int?
        let retryOfOccurrenceID: String?
        let occurrenceID: String
        let recoveryAction: String
        let state: String
        let userFacingRecoveryAction: String
        let userFacingState: String
        let requiresUserAction: Bool
        let taskID: String

        enum CodingKeys: String, CodingKey {
            case effectID = "effect_id"
            case idempotencyKey = "idempotency_key"
            case taskVersion = "task_version"
            case retryOfOccurrenceID = "retry_of_occurrence_id"
            case occurrenceID = "occurrence_id"
            case recoveryAction = "recovery_action"
            case state
            case userFacingRecoveryAction = "user_facing_recovery_action"
            case userFacingState = "user_facing_state"
            case requiresUserAction = "requires_user_action"
            case taskID = "task_id"
        }

        init(snapshot: SchedulerSlashOccurrenceSnapshot) {
            effectID = snapshot.effectID
            idempotencyKey = snapshot.idempotencyKey
            taskVersion = snapshot.taskVersion
            retryOfOccurrenceID = snapshot.retryOfOccurrenceID
            occurrenceID = snapshot.occurrenceID
            recoveryAction = snapshot.recoveryAction
            state = snapshot.state
            userFacingRecoveryAction = snapshot.userFacingRecoveryAction
            userFacingState = snapshot.userFacingState
            requiresUserAction = snapshot.requiresUserAction
            taskID = snapshot.taskID
        }
    }

    struct SchedulerPayload: Encodable {
        let enabledTasks: Int
        let occurrences: [SchedulerOccurrencePayload]
        let readModel: String = "scheduler_observation"
        let stateCounts: [String: Int]
        let totalOccurrences: Int
        let totalTasks: Int

        enum CodingKeys: String, CodingKey {
            case enabledTasks = "enabled_tasks"
            case occurrences
            case readModel = "read_model"
            case stateCounts = "state_counts"
            case totalOccurrences = "total_occurrences"
            case totalTasks = "total_tasks"
        }

        init(observation: SchedulerSlashObservation) {
            enabledTasks = observation.enabledTasks
            occurrences = observation.occurrences.map(SchedulerOccurrencePayload.init(snapshot:))
            stateCounts = observation.stateCounts
            totalOccurrences = observation.totalOccurrences
            totalTasks = observation.totalTasks
        }
    }

    struct CountsPayload: Encodable {
        let cancelled: Int
        let failed: Int
        let queued: Int
        let running: Int
        let succeeded: Int
        let total: Int

        init(counts: TaskCenterProjection.Counts) {
            cancelled = counts.cancelled
            failed = counts.failed
            queued = counts.queued
            running = counts.running
            succeeded = counts.succeeded
            total = counts.total
        }
    }

    struct StatusPayload: Encodable {
        let counts: CountsPayload
        let readModel: String = "task_center_observation"
        let totalTasks: Int

        enum CodingKeys: String, CodingKey {
            case counts
            case readModel = "read_model"
            case totalTasks = "total_tasks"
        }

        init(observation: TaskCenterObservationSnapshot) {
            counts = CountsPayload(counts: observation.counts)
            totalTasks = observation.totalTasks
        }
    }

    struct TaskPayload: Encodable {
        let modelID: String?
        let parentID: String
        let providerID: String?
        let routeReceiptID: String?
        let status: String
        let taskID: String

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case parentID = "parent_id"
            case providerID = "provider_id"
            case routeReceiptID = "route_receipt_id"
            case status
            case taskID = "task_id"
        }

        init(snapshot: AgentTaskSnapshot) {
            modelID = TaskCenterSlashCommandAdapter.safe(snapshot.modelID)
            parentID = TaskCenterSlashCommandAdapter.safe(snapshot.parentID) ?? "redacted"
            providerID = TaskCenterSlashCommandAdapter.safe(snapshot.providerID)
            routeReceiptID = TaskCenterSlashCommandAdapter.safe(snapshot.routeReceiptID)
            status = TaskCenterSlashCommandAdapter.statusName(snapshot.status)
            taskID = TaskCenterSlashCommandAdapter.safe(snapshot.taskID) ?? "redacted"
        }
    }

    struct TasksPayload: Encodable {
        let detailsAvailable: Bool
        let tasks: [TaskPayload]
        let totalTasks: Int

        enum CodingKeys: String, CodingKey {
            case detailsAvailable = "details_available"
            case tasks
            case totalTasks = "total_tasks"
        }

        init(observation: TaskCenterObservationSnapshot, parameters: [String: String]) {
            let filter = TaskCenterObservationFilter(
                taskIDs: parameters["task_id"].map { [$0] },
                parentIDs: parameters["parent_id"].map { [$0] },
                statuses: parameters["status"].flatMap { TaskCenterSlashCommandAdapter.status($0).map { [$0] } },
                providerIDs: parameters["provider_id"].map { [$0] },
                modelIDs: parameters["model_id"].map { [$0] },
                routeReceiptIDs: parameters["route_receipt_id"].map { [$0] }
            )
            let selected = observation.selecting(filter)
            detailsAvailable = !observation.taskSnapshots.isEmpty
            tasks = selected.map(TaskPayload.init(snapshot:))
            totalTasks = observation.totalTasks
        }
    }

    struct BoundaryPayload: Encodable {
        let mutations: String = "forbidden"
        let providerCalls: Int = 0
        let readModel: String = "task_center_observation"
        let transcriptIncluded: Bool = false

        enum CodingKeys: String, CodingKey {
            case mutations
            case providerCalls = "provider_calls"
            case readModel = "read_model"
            case transcriptIncluded = "transcript_included"
        }
    }

    struct ProviderBindingPayload: Encodable {
        let modelID: String?
        let providerID: String
        let routeReceiptID: String?

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case providerID = "provider_id"
            case routeReceiptID = "route_receipt_id"
        }

        init(binding: TaskCenterProjection.RouteBinding) {
            modelID = TaskCenterSlashCommandAdapter.safe(binding.modelID)
            providerID = TaskCenterSlashCommandAdapter.safe(binding.providerID) ?? "redacted"
            routeReceiptID = TaskCenterSlashCommandAdapter.safe(binding.routeReceiptID)
        }
    }

    struct ProviderPayload: Encodable {
        let bindings: [ProviderBindingPayload]
        let totalBindings: Int

        enum CodingKeys: String, CodingKey {
            case bindings
            case totalBindings = "total_bindings"
        }

        init(observation: TaskCenterObservationSnapshot, parameters: [String: String]) {
            let requestedProvider = parameters["provider_id"]
            let filtered = observation.routeBindings.filter { binding in
                requestedProvider == nil || binding.providerID == requestedProvider
            }
            bindings = filtered.map(ProviderBindingPayload.init(binding:))
            totalBindings = filtered.count
        }
    }

    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return #"{"command":null,"error":{"code":"encoding_failed"},"ok":false,"payload":null,"schema_version":1}"#
        }
        return string
    }

    static func statusName(_ status: AgentTaskStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    static func status(_ value: String) -> AgentTaskStatus? {
        switch value.lowercased() {
        case "queued": return .queued
        case "running": return .running
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    static func safe(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return "redacted" }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return "redacted"
        }
        return looksSensitive(trimmed) ? "redacted" : trimmed
    }

    static func safe(_ value: String) -> String? {
        safe(Optional(value))
    }

}
