import Foundation
import CoreFoundation
import Darwin
import CryptoKit
import ImageIO

/// The result of querying one recovered built-in file_write receipt. Only a
/// receipt-bound durable completion can produce a successful canonical fact.
public enum FileWriteReconciliationResult: Equatable, Sendable {
    case notExecuted
    case unknown
    case succeeded(ToolExecutionFact)
}

// MARK: - Relative path input

/// File tools accept `~/…` and project-relative paths and resolve them against
/// the current working directory before any policy or authorization check, so
/// every later stage still sees one absolute path.
enum ToolPathResolution {
    static let toolNames: Set<String> = [
        "file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete"
    ]

    /// Absolute spelling of a relative or `~` path; nil when the path is already
    /// absolute, contains `..`, names another user's home, or has no base.
    static func absolutePath(for raw: String, workingDirectory: String?) -> String? {
        guard !raw.isEmpty, !raw.hasPrefix("/") else { return nil }
        let base: String
        let relative: String
        if raw == "~" {
            base = NSHomeDirectory(); relative = ""
        } else if raw.hasPrefix("~/") {
            base = NSHomeDirectory(); relative = String(raw.dropFirst(2))
        } else if raw.hasPrefix("~") {
            return nil
        } else {
            guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
            base = workingDirectory; relative = raw
        }
        var components: [Substring] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { return nil }
            if component != "." { components.append(component) }
        }
        let tail = components.joined(separator: "/")
        return tail.isEmpty ? base : (base.hasSuffix("/") ? base + tail : base + "/" + tail)
    }
}

// MARK: - Protocol

/// Executes a single agent tool call and returns its output as text.
///
/// The returned string is fed back to the model as the tool result
/// (wrapped in an Anthropic-style `tool_result` user message by `AgentLoop`).
/// Implementations throw `ToolExecutorError` on failure — the loop converts
/// thrown errors into `is_error: true` results so the model can self-correct.
public protocol ToolExecutor: Sendable {
    /// Execute the tool named `name` with `input` arguments (already
    /// decoded from JSON). Returns the textual output.
    func execute(name: String, input: [String: Any]) async throws -> String
}

/// A decorator must derive this owner from the executor it actually forwards
/// to. The bound call repeats the check at the effect boundary and forwards
/// through the same decorator chain; a mutable decorator must capture its
/// current base before awaiting anything.
public protocol BuiltinOwnerBoundToolExecutor: ToolExecutor {
    var currentBuiltinOwner: BuiltinToolExecutor? { get }
    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String
}

public func executeThroughBoundBuiltinOwner(
    _ executor: any ToolExecutor,
    owner: BuiltinToolExecutor,
    name: String,
    input: [String: Any]
) async throws -> String {
    guard let bound = executor as? any BuiltinOwnerBoundToolExecutor,
          bound.currentBuiltinOwner === owner else {
        throw ToolExecutorError.resourceScopeInvalid
    }
    return try await bound.executeBoundToBuiltinOwner(owner, name: name, input: input)
}

/// Split the Composer policy/approval phase from its effect call so the
/// AgentLoop can mint a durable receipt only after authorization succeeds.
/// The Composer executor revalidates and observes the recorded grant again
/// when `execute` is called, so this does not bypass its final boundary.
public extension ComposerPolicyEnforcedToolExecutor {
    func authorizeBeforeExecution(
        callID: String,
        name: String,
        input: [String: Any]
    ) async throws {
        let frozen = try ComposerToolInput(input)
        let decision = try await controller.authorize(
            capability: name,
            input: frozen
        )
        switch decision {
        case .execute, .dryRun:
            return
        case .requestApproval(let requiresSecondConfirmation):
            // Use the same call-bound request and decision check as the
            // Composer execution path before recording any capability grant.
            let pending = try await requestApproval(
                callID: callID,
                name: name,
                input: frozen,
                requiresSecondConfirmation: requiresSecondConfirmation
            )
            try await controller.recordApproval(
                capability: name,
                input: frozen
            )
            try await controller.revalidate(
                capability: name,
                input: frozen
            )
            try await persistAllowIfRequested(pending, name: name, input: frozen)
        }
    }
}

/// A decorator forwards this typed entry to the same Composer chain rather
/// than dropping the nested call ID through ToolExecutor's generic entry.
public enum NestedShellExecutionScope {
    @TaskLocal public static var requiresFreshApproval: Bool = false
}

public protocol NestedShellToolExecutor: ToolExecutor {
    func executeNestedShell(callID: String, input: [String: Any]) async throws -> String
}

/// The minted parent must still be pending in the same durable authority.
/// Internal to MinisCore: only the Composer consumer supplies its own snapshot
/// and consumes its original one-shot authorization inside this receipt scope.
enum NestedShellReceiptBridge {
    struct Parent: Sendable {
        let receipt: ToolExecutionReceipt
        let ledger: ToolExecutionFactLedger
        fileprivate init(receipt: ToolExecutionReceipt, ledger: ToolExecutionFactLedger) {
            self.receipt = receipt; self.ledger = ledger
        }
    }

    static func captureParent(snapshot: ComposerSubmissionSnapshot, callID: String) throws -> Parent {
        guard !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parent = ToolExecutionReceiptContext.current,
              parent.toolName == OrchestrationToolExecutor.toolName,
              callID != parent.toolCallID,
              let identity = parent.executionIdentity, identity.isValid,
              let key = parent.compositeKey, key.isValid,
              let ledger = ToolExecutionReceiptContext.ledger, ledger.hasDurableAuthority,
              ledger.pendingReceipts.contains(parent) else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        guard identity.turn.sessionID == snapshot.sessionID,
              identity.turn.turnID == snapshot.turnID,
              identity.turn.messageID == snapshot.messageID,
              parent.attemptID == AgentToolExecutionAttemptID.canonical(
                executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil),
              parent.attemptNumber == identity.attempt,
              key == ToolExecutionCompositeKey(sessionID: identity.turn.sessionID,
                turnID: identity.turn.turnID, messageID: identity.turn.messageID,
                operationID: identity.operationID, attemptID: parent.attemptID,
                attemptNumber: parent.attemptNumber, toolCallID: parent.toolCallID) else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        return Parent(receipt: parent, ledger: ledger)
    }

    static func execute(parent: Parent, callID: String, input: ComposerToolInput,
        executor: any ToolExecutor,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        let original = parent.receipt, ledger = parent.ledger
        guard ToolExecutionReceiptContext.current == original,
              ToolExecutionReceiptContext.ledger === ledger,
              ledger.pendingReceipts.contains(original),
              callID != original.toolCallID else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        let receipt = try ledger.mint(toolCallID: callID, toolName: "shell_execute",
            attemptID: original.attemptID, attemptNumber: original.attemptNumber,
            executionIdentity: original.executionIdentity,
            parentRuntimeIdentity: original.parentRuntimeIdentity,
            childTranscriptLocator: original.childTranscriptLocator,
            targetTaskBinding: original.targetTaskBinding, targetTaskSource: original.targetTaskSource)
        do {
            let result = try await executeToolWithTimeout(name: "shell_execute", timeout: nil,
                input: input.toolExecutionDictionary, executor: executor, receipt: receipt, ledger: ledger) {
                try Task.checkCancellation()
                guard ToolExecutionReceiptContext.ledger === ledger,
                      ToolExecutionReceiptContext.current == receipt else {
                    throw ToolExecutionFactLedgerError.receiptIdentityMismatch
                }
                let pending = ledger.pendingReceipts
                guard pending.contains(original), pending.contains(receipt) else {
                    throw ToolExecutionFactLedgerError.unknownReceipt
                }
                return try await operation()
            }
            guard try ledger.settle(receipt, status: .succeeded) != nil else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            return result
        } catch {
            _ = try ledger.settle(receipt,
                status: ProviderCancellationPolicy.isCancellation(error) ? .cancelled : .failed)
            throw error
        }
    }
}

/// Marks an executor chain whose concrete production boundary already owns
/// PolicyRuntime validation. Decorators must transparently report the state of
/// their wrapped executor so secure loop entry points cannot mistake a raw
/// executor for a policy-bound one.
public protocol PolicyRuntimeBoundToolExecutor {
    var policyRuntimeBound: Bool { get }
}

/// Optional execution-layer contract for executors that own a finite catalog.
/// The agent loop invokes this before the first provider call, so a schema
/// cannot be advertised while its dispatcher silently accepts another set.
public protocol ToolCatalogValidatingExecutor: ToolExecutor {
    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws
}

/// The App installs its verified, immutable turn snapshot only around one
/// speech effect. A shared BuiltinToolExecutor never stores turn availability.
/// Without this context, even a configured SpeechTool fails closed.
public enum SpeechToolExecutionAuthorization {
    @TaskLocal public static var current: SpeechToolAvailabilitySnapshot?
}

/// Deterministic race probe used only by owned synthetic-file tests. Release
/// operation never sets this internal TaskLocal, so its value stays nil.
enum FileDeleteRaceFixture {
    @TaskLocal static var beforeFinalCheck: (@Sendable () -> Void)? = nil
    @TaskLocal static var beforeQuarantineMove: (@Sendable () -> Void)? = nil
    @TaskLocal static var afterQuarantineMove: (@Sendable (URL) -> Void)? = nil
    @TaskLocal static var beforePhysicalUnlink: (@Sendable () -> Int32)? = nil
}

// MARK: - Errors

public enum ToolExecutorError: Error, Equatable, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case invalidParameter(String)
    /// Parent/provider/model inheritance could not be proven at dispatch time.
    case modelModeUnverified
    case resourceScopeInvalid
    /// Path resolved outside the executor's allowed root.
    case pathViolation(String)
    case fileNotFound(String)
    case fileIsBinary(String)
    case readFailed(String)
    /// A path inside the allowed root whose read OR write the filesystem refused
    /// for permission reasons (EACCES/EPERM, Cocoa fileRead/fileWriteNoPermission).
    /// PRIVACY-05 requires this to be an explicit denial instead of a raw
    /// Foundation/POSIX error string.
    case permissionDenied(String)
    case writeFailed(String)
    /// Edit failed (old_string not found / not unique).
    case editFailed(String)
    case shellTimeout(String)
    case toolTimeout(String)
    case shellSpawnFailed(String)
    /// Shell syntax rejected before a process is spawned.
    case shellRejected(String)
    /// Tool is declared in the catalog but its backing executor was not
    /// composed into `BuiltinToolExecutor` (browser/speech/mcp not configured).
    case toolNotConfigured(String)
    /// A high-risk call reached the loop without an approval decision.
    case approvalRequired(String)
    /// 浏览器属于当前打开的会话；发起调用的会话已不是它（例如切到了别的会话）。
    case browserSessionUnavailable
}

extension ToolExecutorError {
    /// Localized UI text; machine-facing legacy errors keep their stable codes.
    public var displayDescription: String {
        switch self {
        case .modelModeUnverified: return "无法确认继承的模型配置，请重新选择模型。"
        case .resourceScopeInvalid: return "任务资源范围无效，请重新确认授权目录。"
        default: return localizedDescription
        }
    }
}

extension ToolExecutorError: LocalizedError {
    public var errorDescription: String? {
        let message: String
        switch self {
        case .unknownTool(let name): message = "未知工具：\(name)"
        case .missingParameter(let param): message = "缺少必填参数：\(param)"
        case .invalidParameter(let param): message = "参数无效：\(param)"
        case .modelModeUnverified: message = "MODEL_MODE_UNVERIFIED"
        case .resourceScopeInvalid: message = "TASK_RESOURCE_SCOPE_INVALID"
        case .pathViolation(let path): message = "路径超出授权目录或已被拒绝：\(path)"
        case .fileNotFound(let path): message = "文件不存在：\(path)"
        case .fileIsBinary(let path): message = "无法按文本读取二进制文件：\(path)"
        case .readFailed(let detail): message = "读取失败：\(detail)"
        case .permissionDenied(let path): message = "没有访问此路径的权限：\(path)"
        case .writeFailed(let detail): message = "写入失败：\(detail)"
        case .editFailed(let detail): message = "编辑失败：\(detail)"
        case .shellTimeout(let detail): message = "终端命令执行超时：\(detail)"
        case .toolTimeout(let detail): message = "工具执行超时：\(detail)"
        case .shellSpawnFailed(let detail): message = "无法启动终端命令：\(detail)"
        case .shellRejected(let detail):
            let reason = detail == "command denied by terminal policy"
                ? "终端策略已拒绝此命令；请在终端策略设置中查看拒绝表。" : detail
            message = "终端命令已被拒绝：\(reason)"
        case .toolNotConfigured(let name): message = "工具尚未配置执行器：\(name)"
        case .approvalRequired(let name): message = "执行工具前需要审批：\(name)"
        case .browserSessionUnavailable:
            message = "浏览器只属于当前打开的会话，这个会话已不在前台，浏览器调用被拒绝；请切回该会话后再重试。"
        }
        return ContentSecretRedactor.redact(message, knownSecrets: ModelShellEnvironment.knownCredentialValues())
    }
}

/// A synchronous snapshot only; the existing actor still owns cancellation and
/// the physical tail. The lock is never held across an await.
private final class ToolExecutionActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isActive: Bool { lock.withLock { count > 0 } }
    func add() { lock.withLock { count += 1 } }
    func remove() { lock.withLock { count -= 1 } }
}

actor ToolExecutionOwnership {
    private var tail: Task<Void, Never>?
    private var running: [UUID: Task<String, Error>] = [:]
    private var shuttingDown = false
    private nonisolated let activity = ToolExecutionActivity()
    nonisolated var hasPendingOperations: Bool { activity.isActive }

    func cancelAndDrainForApplicationExit() async {
        shuttingDown = true
        for task in running.values { task.cancel() }
        // The timeout race may already have returned CancellationError. This
        // tail, rather than that logical result, joins the actual executor.
        await tail?.value
    }

    func perform(
        _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        guard !shuttingDown else { throw CancellationError() }
        let id = UUID()
        activity.add()
        defer { running.removeValue(forKey: id); activity.remove() }
        let predecessor = tail
        let task = Task<String, Error> {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        running[id] = task
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    /// One FIFO reservation owns all read effects in a cohort. Logical
    /// cancellation/timeout can return promptly; the original physical tail
    /// remains held until every child operation has really retired.
    func performReadCohort(
        count: Int, timeout: TimeInterval?, enqueuedAt: UInt64,
        operation: @escaping @Sendable ([ToolExecutionOwnership]) async -> [ToolRunResult]
    ) async throws -> [ToolRunResult] {
        guard !shuttingDown else { throw CancellationError() }
        let remaining = Self.remainingReadCohortTimeout(timeout, enqueuedAt: enqueuedAt)
        if let remaining, remaining <= 0 { throw ToolExecutorError.toolTimeout("Read cohort expired in the execution queue") }
        let race = ToolOperationTimeoutRace<[ToolRunResult]>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                // This watchdog owns FIFO waiting only. The same race lock
                // arbitrates queue expiry against acquiring the physical slot.
                race.beginQueueWait()
                let watchdog = remaining.map { duration in
                    ToolOperationTimeoutWatchdog(after: duration) {
                        race.finishQueueTimeout(ToolExecutorError.toolTimeout("Read cohort timed out in the execution queue"))
                    }
                }
                let id = UUID()
                let predecessor = tail
                let children = (0..<count).map { _ in ToolExecutionOwnership() }
                activity.add()
                let logical = Task<[ToolRunResult], Error> {
                    let result: Result<[ToolRunResult], Error>
                    do {
                        await predecessor?.value
                        guard race.endQueueWait() else { throw CancellationError() }
                        watchdog?.cancel()
                        try Task.checkCancellation()
                        if let budget = Self.remainingReadCohortTimeout(timeout, enqueuedAt: enqueuedAt), budget <= 0 {
                            throw ToolExecutorError.toolTimeout("Read cohort expired in the execution queue")
                        }
                        result = .success(await operation(children))
                    } catch { result = .failure(error) }
                    // Closing admission is separate from waiting for physical
                    // completion. A late cancelled executor cannot start new IO.
                    for child in children { await child.closeReadCohortAdmission() }
                    race.finish(result)
                    return try result.get()
                }
                // A bounded strong owner matches original perform's physical
                // lifetime even after its caller receives a logical timeout.
                let physical = Task<String, Error> { [self] in
                    try await withTaskCancellationHandler(operation: {
                        let result = await logical.result
                        for child in children { await child.cancelAndDrainForApplicationExit() }
                        self.finishReadCohort(id)
                        _ = try result.get()
                        return ""
                    }, onCancel: {
                        logical.cancel()
                        race.cancel()
                    })
                }
                running[id] = physical
                tail = Task { _ = await physical.result }
                race.setCancelTasks { logical.cancel(); watchdog?.cancel() }
            }
        }, onCancel: { race.cancel() }, isolation: self)
    }

    /// One monotonic budget spans parent FIFO wait and the later cohort gate.
    /// Nonpositive configured timeouts retain the original unlimited meaning.
    nonisolated static func remainingReadCohortTimeout(_ timeout: TimeInterval?, enqueuedAt: UInt64) -> TimeInterval? {
        guard let timeout, timeout > 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= enqueuedAt ? Double(now - enqueuedAt) / 1_000_000_000 : 0
        return max(0, timeout - elapsed)
    }

    private func closeReadCohortAdmission() {
        shuttingDown = true
        for task in running.values { task.cancel() }
    }

    private func finishReadCohort(_ id: UUID) {
        running.removeValue(forKey: id)
        activity.remove()
    }

}

private final class WeakToolExecutionOwnership {
    weak var value: ToolExecutionOwnership?

    init(_ value: ToolExecutionOwnership) {
        self.value = value
    }
}

/// Shared concrete executor instances keep the same physical tail across
/// separate loop invocations. Weak entries do not retain idle executors.
actor ToolExecutionOwnershipRegistry {
    static let shared = ToolExecutionOwnershipRegistry()
    private var entries: [ObjectIdentifier: WeakToolExecutionOwnership] = [:]

    func ownership(for executor: any ToolExecutor) -> ToolExecutionOwnership {
        let builtinOwner = (executor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
        if let builtinOwner { return builtinOwner.executionOwnership }
        guard Mirror(reflecting: executor).displayStyle == .class else {
            // A value executor has no stable object identity to register.
            return ToolExecutionOwnership()
        }
        let identity: AnyObject = executor as AnyObject
        let key = ObjectIdentifier(identity)
        if let existing = entries[key]?.value { return existing }
        entries = entries.filter { $0.value.value != nil }
        let created = ToolExecutionOwnership()
        entries[key] = WeakToolExecutionOwnership(created)
        return created
    }
}

private func approvalStringValue(_ input: ComposerToolInput, for key: String) -> String? {
    guard case .string(let value) = input.values[key] else { return nil }
    return value
}

extension ComposerToolInput {
    public var toolExecutionDictionary: [String: Any] {
        values.mapValues(\.toolExecutionValue)
    }
}

private extension ComposerInputValue {
    var toolExecutionValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.toolExecutionValue)
        case .object(let values): return values.mapValues(\.toolExecutionValue)
        }
    }
}

/// Shared command-only budget parsing; not a grant of execution permission.
public enum ShellCommandTimeoutPolicy {
    public static let defaultSeconds = 120
    public static let maximumSeconds = 600
    static let cleanupSeconds: TimeInterval = 10
    @TaskLocal static var currentBudget: ShellCommandBudget?

    public static func seconds(_ raw: Any?, defaultValue: Int = defaultSeconds) -> TimeInterval {
        let fallback = TimeInterval(min(maximumSeconds, max(1, defaultValue)))
        guard let number = raw as? NSNumber else { return fallback }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return min(TimeInterval(maximumSeconds), max(0.001, seconds))
    }

    static func budget(name: String, input: [String: Any]?, executor: (any ToolExecutor)?, childTimeout: TimeInterval?) -> ShellCommandBudget? {
        guard name == "shell_execute", let executor else { return nil }
        // Only the known final Composer wrapper is inspected for configuration.
        // Execution still goes through that wrapper and the scoped child chain.
        let configurationBase = (executor as? ComposerPolicyEnforcedToolExecutor)?.base ?? executor
        let owner = configurationBase as? BuiltinToolExecutor
            ?? (configurationBase as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
        let seconds = Self.seconds(input?["timeout"], defaultValue: owner?.defaultShellTimeout ?? defaultSeconds)
        return ShellCommandBudget(seconds: seconds, childTimeout: childTimeout)
    }

    static func timeoutDetail(seconds: TimeInterval, stdout: Data, stderr: Data, limit: Int) -> String {
        func captured(_ data: Data) -> String {
            let text = ContentSecretRedactor.redact(String(decoding: data, as: UTF8.self), knownSecrets: ModelShellEnvironment.knownCredentialValues())
            return String(decoding: Data(text.utf8).prefix(limit), as: UTF8.self)
        }
        let envelope: [String: Any] = ["timed_out": true, "timeout_seconds": seconds,
            "stdout": captured(stdout), "stderr": captured(stderr)]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return "命令执行超时" }
        return text
    }
}

final class ShellCommandBudget: @unchecked Sendable {
    let seconds: TimeInterval
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var parentDeadline: TimeInterval?
    private var executionDeadline: TimeInterval?
    private var selectedSeconds: TimeInterval?
    private var observer: (@Sendable (TimeInterval) -> Void)?
    private var cancelTimer: (@Sendable () -> Void)?
    private var cancelled = false

    init(seconds: TimeInterval, childTimeout: TimeInterval? = nil,
         clock: @escaping @Sendable () -> TimeInterval = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        self.seconds = seconds
        self.clock = clock
        self.parentDeadline = childTimeout.map { clock() + ($0.isFinite ? max(0, $0) : 0) }
    }

    var executionStarted: Bool { lock.lock(); defer { lock.unlock() }; return executionDeadline != nil }
    var executionSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return selectedSeconds ?? seconds }
    var parentRemaining: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return parentDeadline.map { max(0, $0 - clock()) }
    }
    var remaining: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return executionDeadline.map { max(0, $0 - clock()) } ?? seconds
    }
    var hasExecutionDeadlineElapsed: Bool {
        lock.lock(); defer { lock.unlock() }
        return executionDeadline.map { $0 <= clock() } ?? false
    }
    var cleanupRemaining: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return executionDeadline.map { max(0, $0 + ShellCommandTimeoutPolicy.cleanupSeconds - clock()) } ?? 0
    }

    func constrainParentDeadline(remaining: TimeInterval) {
        lock.lock()
        let candidate = clock() + (remaining.isFinite ? max(0, remaining) : 0)
        parentDeadline = min(parentDeadline ?? candidate, candidate)
        if let current = executionDeadline { executionDeadline = min(current, candidate) }
        let observer = executionDeadline == nil ? nil : self.observer
        let cleanup = executionDeadline.map { max(0, $0 + ShellCommandTimeoutPolicy.cleanupSeconds - clock()) }
        lock.unlock()
        if let cleanup { observer?(cleanup) }
    }

    /// Configuration is resolved before approval; its execution clock starts
    /// only here, immediately before spawning. An expired parent cannot spawn.
    @discardableResult func beginExecution() -> TimeInterval {
        lock.lock()
        let now = clock()
        let firstStart = executionDeadline == nil
        if firstStart {
            let selected = min(seconds, parentDeadline.map { max(0, $0 - now) } ?? seconds)
            selectedSeconds = selected
            guard selected > 0 else { lock.unlock(); return 0 }
            executionDeadline = now + selected
        }
        let remaining = max(0, (executionDeadline ?? now) - now)
        let observer = firstStart && !cancelled ? self.observer : nil
        lock.unlock()
        observer?(remaining + ShellCommandTimeoutPolicy.cleanupSeconds)
        return remaining
    }

    func installDeadlineObserver(_ observer: @escaping @Sendable (TimeInterval) -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        self.observer = observer
        let duration = executionDeadline.map { max(0, $0 + ShellCommandTimeoutPolicy.cleanupSeconds - clock()) }
        lock.unlock()
        if let duration { observer(duration) }
    }
    func setTimerCancellation(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let old = cancelTimer
        let alreadyCancelled = cancelled
        if !alreadyCancelled { cancelTimer = cancel }
        lock.unlock()
        old?()
        if alreadyCancelled { cancel() }
    }
    func cancelWatchdog() {
        lock.lock()
        cancelled = true
        let cancel = cancelTimer
        cancelTimer = nil
        observer = nil
        lock.unlock()
        cancel?()
    }
}

/// Run one arbitrary tool operation under a wall-clock deadline.
///
/// The watchdog is deliberately backed by GCD rather than a Swift task so an
/// executor that ignores cancellation cannot starve the deadline. A single
/// locked race owns the continuation: timeout, cancellation, executor success,
/// and executor failure can each publish at most one outcome.
func executeToolWithTimeout(
    name: String,
    timeout: TimeInterval?,
    input: [String: Any]? = nil,
    executor: (any ToolExecutor)? = nil,
    childTimeout: TimeInterval? = nil,
    receipt: ToolExecutionReceipt? = nil,
    ledger: ToolExecutionFactLedger? = nil,
    ownership: ToolExecutionOwnership = ToolExecutionOwnership(),
    operation: @escaping @Sendable () async throws -> String
) async throws -> String {
    let budget = ShellCommandTimeoutPolicy.budget(name: name, input: input, executor: executor, childTimeout: childTimeout)
    let boundOperation: @Sendable () async throws -> String = {
        try await ShellCommandTimeoutPolicy.$currentBudget.withValue(budget) {
        try await ToolExecutionReceiptContext.$current.withValue(receipt) {
            try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
                try await operation()
            }
        }
        }
    }
    guard budget != nil || (timeout ?? 0) > 0 else {
        return try await ownership.perform(boundOperation)
    }
    let race = ToolOperationTimeoutRace<String>()
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard race.install(continuation) else { return }

            // A child can publish timeout/cancellation before this task exits.
            // Retain its existing launch permit until the actual operation ends.
            let finishChildOperation = ChildLaunchPermitLifetime.current?.retainOperation()
            let executorTask = Task<Void, Never> {
                defer { finishChildOperation?() }
                do {
                    race.finish(.success(try await ownership.perform(boundOperation)))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let watchdogTask: ToolOperationTimeoutWatchdog?
            if let budget {
                watchdogTask = nil
                budget.installDeadlineObserver { [weak budget] duration in
                    let timer = ToolOperationTimeoutWatchdog(after: duration) {
                        race.finish(.failure(ToolExecutorError.toolTimeout("Command cleanup exceeded its bound")))
                    }
                    budget?.setTimerCancellation { timer.cancel() }
                }
            } else if let timeout, timeout > 0 {
                watchdogTask = ToolOperationTimeoutWatchdog(after: timeout) {
                    race.finish(.failure(ToolExecutorError.toolTimeout("Tool '\(name)' timed out after \(timeout)s")))
                }
            } else { watchdogTask = nil }
            race.setCancelTasks {
                executorTask.cancel()
                budget?.cancelWatchdog()
                watchdogTask?.cancel()
            }
        }
    }, onCancel: {
        race.cancel()
    })
}

private final class ToolOperationTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waitingForQueue = false
    private var completed = false
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelTasks: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancellationRequested {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func beginQueueWait() {
        lock.withLock { waitingForQueue = true }
    }

    func endQueueWait() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            waitingForQueue = false
            return true
        }
    }

    func finishQueueTimeout(_ error: any Error) {
        lock.lock()
        guard waitingForQueue, !completed else { lock.unlock(); return }
        completed = true
        waitingForQueue = false
        let continuation = self.continuation
        self.continuation = nil
        let cancel = cancelTasks
        lock.unlock()
        continuation?.resume(throwing: error)
        cancel?()
    }

    func setCancelTasks(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelNow = completed
        if !cancelNow { cancelTasks = cancel }
        lock.unlock()
        if cancelNow { cancel() }
    }

    func cancel() {
        lock.lock()
        if continuation == nil && !completed {
            cancellationRequested = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let cancel = cancelTasks
        lock.unlock()

        continuation?.resume(with: result)
        cancel?()
    }
}

private final class ToolOperationTimeoutWatchdog: Sendable {
    private let timer: DispatchSourceTimer

    init(after timeout: TimeInterval, operation: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(
            label: "com.miniscanvas.miniscore.tool-timeout",
            qos: .userInitiated
        )
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler(handler: operation)
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }
}

// MARK: - Built-in macOS Executor

/// Built-in tool executor for the MinisCore agent loop.
///
/// Provides macOS-native implementations (no iSH):
/// - `shell_execute` — runs a command via `/bin/zsh -c` (Process), returns a
///   JSON envelope `{"exit_code":…,"stdout":…,"stderr":…}` so the model can
///   inspect exit codes and stderr.
/// - `file_read` / `file_write` / `file_edit` / `file_delete` — direct file access,
///   with all paths confined to `allowedRoot` (path traversal / symlink
///   escapes rejected).
/// - `web_search` — backed by `WebSearchService` (E1) only when the composition
///   root passes `webSearch:`. It stays absent from `defaultRegisteredToolNames()`,
///   so default calls fail closed at the whitelist gate with `unknownTool`
///   (error-class `is_error` tool_result in `AgentLoop`); a consumer that
///   registers the name without a service, or whose search settings are
///   unusable, gets `toolNotConfigured` at dispatch. It never returns a
///   fake-success prose string.
///
/// Composed native tools (B1j) — each optional, dispatch happens in
/// `execute(name:)` by tool name:
/// - `browser` / `browser_use` → `BrowserTool` (headless WKWebView).
/// - `speech` → `SpeechTool` (macOS TTS).
/// - `mcp_*` → `MCPToolBridge` (`MCPToolRegistry`), routed to
///   `callMCPTool(fullName:arguments:)` so the agent loop can call MCP tools
///   directly. `input` is forwarded verbatim as the tool arguments.
///
/// Tools declared in `AgentToolCatalog` whose backing executor is not
/// configured throw `ToolExecutorError.toolNotConfigured`.

/// App-issued target workspace identity. Model tool arguments cannot construct
/// this value; the executor also compares every field with the Core task/run
/// ledger and the active turn before applying it.
public struct TargetWorkspaceBinding: Sendable, Equatable {
    public let source: ParentRuntimeIdentity
    public let targetSessionID: String
    public let taskID: String
    public let runID: String
    public let projectID: String
    public let workingDirectory: String

    public init(source: ParentRuntimeIdentity, targetSessionID: String,
                taskID: String, runID: String, projectID: String,
                workingDirectory: String) {
        self.source = source
        self.targetSessionID = targetSessionID
        self.taskID = taskID
        self.runID = runID
        self.projectID = projectID
        self.workingDirectory = workingDirectory
    }
}

/// The built-in tool executor described above.
private struct BuiltinToolMutableState: Sendable {
    var fileCheckpointsEnabled: Bool
    var fileCheckpointStore: FileCheckpointStore?
    var fileChangeLedger: FileChangeLedger?
    var fileChangeSessionID: String
    var taskFileArtifactBinding: TaskFileArtifactBinding?
    var taskArtifactProjectResolver: (@MainActor @Sendable (String) -> String?)?
    var defaultShellTimeout: Int
    var browser: (any ToolExecutor)?
    var speech: (any ToolExecutor)?
    var mcpBridge: (any MCPToolBridge)?
    var sessionManager: SessionManager?
    var registeredToolNames: Set<String>
    var terminalPolicySnapshot: TerminalPolicySnapshot
}

/// NSLock covers every read and write of the mutable configuration. The
/// unchecked conformance is limited to this lock-protected store; callers
/// receive Sendable snapshots and never hold its lock across an await.
private final class BuiltinToolMutableStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state: BuiltinToolMutableState

    init(_ state: BuiltinToolMutableState) {
        self.state = state
    }

    func withLock<Result: Sendable>(
        _ body: (inout BuiltinToolMutableState) -> Result
    ) -> Result {
        lock.withLock { body(&state) }
    }
}

public final class BuiltinToolExecutor: ToolCatalogValidatingExecutor, SessionReadCapabilityAwareToolExecutor, BuiltinOwnerBoundToolExecutor {
    public var currentBuiltinOwner: BuiltinToolExecutor? { self }
    fileprivate let executionOwnership = ToolExecutionOwnership()

    public var hasPendingOwnedToolOperations: Bool { executionOwnership.hasPendingOperations }

    /// Permanently close this concrete owner's admission and join its existing
    /// physical execution tail. Only the application exit boundary uses this.
    public func cancelOwnedToolsForApplicationExit() async {
        await executionOwnership.cancelAndDrainForApplicationExit()
    }

    public func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard self === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input)
    }
    private static let processTerminationGracePeriod: TimeInterval = 0.5
    private static let shellOutputLimit = 4 * 1024 * 1024
    private static let shellDrainGracePeriod: TimeInterval = 1

    /// Shared registry also observed by the background-command UI.
    public let backgroundShells: BackgroundShellRegistry = .shared
    /// shell 命令结束后登记的“命令生成（未经写入验证）”产物，与台账里已证实的写入分开。
    public let commandGeneratedArtifacts = CommandGeneratedArtifactLog()

    /// Root directory that file tools may touch. Everything else is rejected.
    private let webFetchTransport: WebFetchTransport?
    public var webFetchAvailable: Bool { webFetchTransport != nil }
    internal var webFetchPinnedConfiguration: WebFetchPinnedConfiguration? { webFetchTransport?.pinnedConfiguration }
    /// E1: nil unless the composition root wired a search service.
    private let webSearchService: WebSearchService?
    /// A search service was composed (the name may be registered). Says nothing about
    /// whether the user's settings are usable; see `webSearchAvailable`.
    public var webSearchConfigured: Bool { webSearchService != nil }
    /// Composed and the user's settings are usable right now: only then is the tool advertised.
    public var webSearchAvailable: Bool { webSearchService?.isAvailable == true }

    private let configuredAllowedRoot: URL
    public let sessionDerivedRoot: Bool
    public var allowedRoot: URL {
        if sessionDerivedRoot, let scope = ChildToolWorkspaceScope.current {
            return URL(fileURLWithPath: scope.workingDirectory, isDirectory: true)
        }
        return configuredAllowedRoot
    }
    /// A captured turn/child scope changes cwd, never the shared owner's
    /// allowed roots. Child dispatch installs its own narrower scope.
    public var effectiveWorkingDirectory: URL {
        ChildToolWorkspaceScope.current.map {
            URL(fileURLWithPath: $0.workingDirectory, isDirectory: true)
        } ?? allowedRoot
    }
    /// AJ-45：额外允许访问的根目录白名单（挂载的外部文件夹）。
    /// 文件工具可访问 allowedRoot 之外、但位于任一 `additionalAllowedRoots` 内的路径。
    /// 桌面端等价物 = 移动端挂载目录；经 `resolveAllowedPath` 与 `allowedRoot` 一并放行，
    /// 任何路径仍受 `deniedRoots` 拦截。
    public let additionalAllowedRoots: [URL]
    /// 本机 Codex / Claude Code 会话目录所在 home；仅 external_session_* 使用，不参与文件工具路径判断。
    public let localAgentSessionHome: URL?
    public let allowsLocalAgentSessionRead: Bool
    /// 外部会话工具可读根 = 已挂载根 + （开关开时）存在的默认会话目录。
    var externalSessionRoots: [URL] {
        guard allowsLocalAgentSessionRead, let home = localAgentSessionHome else { return additionalAllowedRoots }
        let defaults = [home.appendingPathComponent(".codex/sessions", isDirectory: true),
                        home.appendingPathComponent(".claude/projects", isDirectory: true)]
            .map { $0.standardizedFileURL }
            .filter { var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
            .filter { !additionalAllowedRoots.contains($0) }
        return additionalAllowedRoots + defaults
    }
    /// Directories that file tools must never touch, even if they fall under
    /// `allowedRoot`. Defaults to the app's Application Support directory,
    /// where the agent's own secrets (API keys in `envvars.json`) live.
    public let deniedRoots: [URL]
    /// Explicit caller policy, including [], is preserved independently of the
    /// app-private floor and can never be waived by an owned output receipt.
    private let configuredDeniedRoots: [URL]?
    public let appPrivateDeniedRoots: [URL]
    public var explicitDeniedRoots: [URL] { configuredDeniedRoots ?? [] }
    /// P3-OUTPUT-01（DEV-286）：逐文件变更台账生产者。nil 时写入口完全保持
    /// 原语义（不登记、结果串不变）；由组合根/App 侧适配器（下一条线）注入，
    /// 本执行器只在既有写成功后追加登记，不改工具语义、审批/隔离/授权判断。
    public var fileCheckpointsEnabled: Bool {
        get { mutableState.withLock { $0.fileCheckpointsEnabled } }
        set { mutableState.withLock { $0.fileCheckpointsEnabled = newValue } }
    }
    public var fileCheckpointStore: FileCheckpointStore? {
        get { mutableState.withLock { $0.fileCheckpointStore } }
        set { mutableState.withLock { $0.fileCheckpointStore = newValue } }
    }
    public var fileChangeLedger: FileChangeLedger? {
        get { mutableState.withLock { $0.fileChangeLedger } }
        set { mutableState.withLock { $0.fileChangeLedger = newValue } }
    }
    /// 台账会话隔离键。空串视为未接线：不登记（不猜会话身份）。
    public var fileChangeSessionID: String {
        get { mutableState.withLock { $0.fileChangeSessionID } }
        set { mutableState.withLock { $0.fileChangeSessionID = newValue } }
    }
    /// Set only on the scoped executor after verified target task admission.
    private var taskFileArtifactBinding: TaskFileArtifactBinding? {
        get { mutableState.withLock { $0.taskFileArtifactBinding } }
        set { mutableState.withLock { $0.taskFileArtifactBinding = newValue } }
    }
    /// Read-only App native-grant lookup. It cannot authorize a tool effect.
    public var taskArtifactProjectResolver: (@MainActor @Sendable (String) -> String?)? {
        get { mutableState.withLock { $0.taskArtifactProjectResolver } }
        set { mutableState.withLock { $0.taskArtifactProjectResolver = newValue } }
    }
    /// Default shell timeout in seconds when the model does not pass one.
    private let mutableState: BuiltinToolMutableStateStore
    public var defaultShellTimeout: Int {
        get { mutableState.withLock { $0.defaultShellTimeout } }
        set { mutableState.withLock { $0.defaultShellTimeout = newValue } }
    }
    /// Optional `BrowserTool` — handles `browser` / `browser_use` calls.
    public var browser: (any ToolExecutor)? {
        get { mutableState.withLock { $0.browser } }
        set { mutableState.withLock { $0.browser = newValue } }
    }
    /// Optional `SpeechTool` — handles `speech` calls.
    public var speech: (any ToolExecutor)? {
        get { mutableState.withLock { $0.speech } }
        set { mutableState.withLock { $0.speech = newValue } }
    }
    /// Optional MCP bridge (e.g. `MCPToolRegistry`) — handles `mcp_*` calls.
    public var mcpBridge: (any MCPToolBridge)? {
        get { mutableState.withLock { $0.mcpBridge } }
        set { mutableState.withLock { $0.mcpBridge = newValue } }
    }
    /// Read-only local conversation access for the `session_read` tool.
    /// Nil keeps the tool declared but reports `toolNotConfigured`, which is
    /// safer than silently falling back to filesystem access.
    public var sessionManager: SessionManager? {
        get { mutableState.withLock { $0.sessionManager } }
        set { mutableState.withLock { $0.sessionManager = newValue } }
    }
    /// Trusted call-time memory snapshot; evaluated by SessionReadTool only
    /// after its capability is validated and consumed. Never model input.
    private let sessionReadKnownSecretsProvider: @Sendable () -> [String]
    /// P1-1 工具白名单：唯一允许 `execute(name:)` 执行的工具名集合。
    /// 任何不在集合内的工具名在 dispatch 前即被拒绝（抛
    /// `ToolExecutorError.unknownTool`），杜绝 Agent 调用未注册/伪造工具。
    /// 默认值 = 已实现的内置工具 + browser + speech + 兼容别名（`browser_use`）。
    /// 这是实现注册名单；speech 效果另需同回合 TaskLocal 可用性证明。
    /// MCP 工具名（`mcp_*`）需通过 `registerToolNames(_:)` 或
    /// setter 追加；未被注册的 `mcp_*` 同样拒绝。
    public var registeredToolNames: Set<String> {
        get { mutableState.withLock { $0.registeredToolNames } }
        set { mutableState.withLock { $0.registeredToolNames = newValue } }
    }
    /// Immutable command-policy value used by the next shell request. The
    /// production SettingsCenter callback replaces this value only between
    /// requests; `runShell` captures its local copy before awaiting.
    public var terminalPolicySnapshot: TerminalPolicySnapshot {
        get { mutableState.withLock { $0.terminalPolicySnapshot } }
        set { mutableState.withLock { $0.terminalPolicySnapshot = newValue } }
    }

    private let skillMaintenance: SkillMaintenanceTool?

    public init(
        allowedRoot: URL,
        defaultShellTimeout: Int = ShellCommandTimeoutPolicy.defaultSeconds,
        deniedRoots: [URL]? = nil,
        appPrivateDeniedRoots: [URL]? = nil,
        additionalAllowedRoots: [URL] = [],
        localAgentSessionHome: URL? = nil,
        allowsLocalAgentSessionRead: Bool = false,
        browser: (any ToolExecutor)? = nil,
        speech: (any ToolExecutor)? = nil,
        mcpBridge: (any MCPToolBridge)? = nil,
        sessionManager: SessionManager? = nil,
        skillMaintenance: SkillMaintenanceTool? = nil,
        registeredToolNames: Set<String>? = nil,
        terminalPolicySnapshot: TerminalPolicySnapshot = .default,
        sessionReadKnownSecretsProvider: @escaping @Sendable () -> [String] = { [] },
        sessionDerivedRoot: Bool = false,
        webFetch: WebFetchTransport? = nil,
        webSearch: WebSearchService? = nil
    ) {
        self.configuredAllowedRoot = allowedRoot.standardizedFileURL
        self.sessionDerivedRoot = sessionDerivedRoot
        self.webFetchTransport = webFetch
        self.webSearchService = webSearch
        self.skillMaintenance = skillMaintenance
        self.configuredDeniedRoots = deniedRoots?.map { $0.standardizedFileURL }
        let privateFloor = appPrivateDeniedRoots
            ?? (deniedRoots == nil ? Self.defaultDeniedRoots() : [])
        self.appPrivateDeniedRoots = privateFloor.map { $0.standardizedFileURL }
        self.deniedRoots = Array(Set(self.appPrivateDeniedRoots + (self.configuredDeniedRoots ?? [])))
            .sorted { $0.path < $1.path }
        self.additionalAllowedRoots = additionalAllowedRoots.map { $0.standardizedFileURL }
        self.localAgentSessionHome = localAgentSessionHome
        self.allowsLocalAgentSessionRead = allowsLocalAgentSessionRead
        self.sessionReadKnownSecretsProvider = sessionReadKnownSecretsProvider
        self.mutableState = BuiltinToolMutableStateStore(BuiltinToolMutableState(
            fileCheckpointsEnabled: false,
            fileCheckpointStore: nil,
            fileChangeLedger: nil,
            fileChangeSessionID: "",
            taskFileArtifactBinding: nil,
            taskArtifactProjectResolver: nil,
            defaultShellTimeout: defaultShellTimeout,
            browser: browser,
            speech: speech,
            mcpBridge: mcpBridge,
            sessionManager: sessionManager,
            registeredToolNames: registeredToolNames ?? BuiltinToolExecutor.defaultRegisteredToolNames(),
            terminalPolicySnapshot: terminalPolicySnapshot
        ))
    }

    /// Trusted composition-root clone for the next admitted turn. This does
    /// not authorize roots: the caller must already hold session/Goal approval.
    /// Existing mounts come exclusively from this owner and retain their original
    /// representation. Only newly approved roots are strictly revalidated here;
    /// callers cannot designate arbitrary URLs as existing mounts. Reject new
    /// noncanonical/symlink aliases rather than authorizing their destination.
    /// Capturing the mutable configuration once preserves every injected service
    /// and receipt binding while leaving the previous turn's owner unchanged.
    public func copyingAddingAdditionalAllowedRoots(_ newRoots: [URL]) throws -> BuiltinToolExecutor {
        for root in newRoots {
            let raw = root.path
            var isDirectory: ObjCBool = false
            guard root.isFileURL, raw.hasPrefix("/"),
                  raw.rangeOfCharacter(from: .controlCharacters) == nil,
                  !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  let physical = PolicyRuntimePathBoundary.canonicalPath(raw),
                  physical == root.standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: physical, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !SensitiveFilePolicy.isCredentialPath(physical),
                  !SensitiveFilePolicy.isProtectedStatePath(physical),
                  !root.pathComponents.contains(where: { $0.lowercased() == ".git" }) else {
                throw ToolExecutorError.pathViolation(raw)
            }
            for denied in deniedRoots {
                guard let deniedPhysical = PolicyRuntimePathBoundary.canonicalPath(denied.path),
                      !PolicyRuntimePathBoundary.foldedCandidate(physical, isWithin: deniedPhysical) else {
                    throw ToolExecutorError.pathViolation(raw)
                }
            }
        }
        let configuration = mutableState.withLock { $0 }
        let copy = BuiltinToolExecutor(
            allowedRoot: configuredAllowedRoot,
            defaultShellTimeout: configuration.defaultShellTimeout,
            deniedRoots: configuredDeniedRoots,
            appPrivateDeniedRoots: appPrivateDeniedRoots,
            additionalAllowedRoots: additionalAllowedRoots + newRoots.filter { !additionalAllowedRoots.contains($0) },
            localAgentSessionHome: localAgentSessionHome,
            allowsLocalAgentSessionRead: allowsLocalAgentSessionRead,
            browser: configuration.browser,
            speech: configuration.speech,
            mcpBridge: configuration.mcpBridge,
            sessionManager: configuration.sessionManager,
            skillMaintenance: skillMaintenance,
            registeredToolNames: configuration.registeredToolNames,
            terminalPolicySnapshot: configuration.terminalPolicySnapshot,
            sessionReadKnownSecretsProvider: sessionReadKnownSecretsProvider,
            sessionDerivedRoot: sessionDerivedRoot,
            webFetch: webFetchTransport,
            webSearch: webSearchService
        )
        copy.mutableState.withLock { $0 = configuration }
        return copy
    }

    /// P1-1 默认实现名单与逐回合广告目录分开。speech 可由 dispatcher
    /// 识别，但只在广告目录和效果门都持有同一支持快照时可执行。
    /// `browser_use` 是未列入目录的兼容别名。
    /// `web_search` 已从未接入占位移除（P3-P1-05）：默认能力广播
    /// （GoalEnvelope.allowedCapabilities / composer 能力面，均由本集合派生）
    /// 不得宣告无法工作的工具。
    public static func defaultRegisteredToolNames() -> Set<String> {
        var names = AgentToolCatalog.implementedNativeToolNames
        names.insert(BrowserTool.legacyToolName) // browser_use 兼容别名
        names.formUnion([ExternalSessionToolNames.read, ExternalSessionToolNames.send])
        names.insert(SkillMaintenanceTool.readName) // 只读：给 skill_update/skill_delete 取当前哈希
        return names
    }

    /// P1-1 追加已注册工具名（主要为运行期发现的 MCP 工具）。
    public func registerToolNames(_ names: [String]) {
        // Discovery can return to several calls on this shared executor at
        // once. Keep the read/modify/write under one lock, not a snapshot getter.
        mutableState.withLock { $0.registeredToolNames.formUnion(names) }
    }

    public func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        let configuration = mutableState.withLock { $0 }
        var seen = Set<String>()
        for tool in tools {
            guard seen.insert(tool.name).inserted else {
                throw ToolExecutorError.invalidParameter("duplicate tool catalog entry: \(tool.name)")
            }
            // MCP declarations are discovered asynchronously and are checked
            // again against the live bridge at execute time. Allow the
            // discovered catalog through this synchronous validation step;
            // execute(name:) remains the authoritative exact-name gate.
            let isDynamicMCP = tool.name.hasPrefix("mcp_") && configuration.mcpBridge != nil
            guard configuration.registeredToolNames.contains(tool.name) || isDynamicMCP else {
                throw ToolExecutorError.unknownTool(tool.name)
            }
            if tool.name == SpeechTool.toolName, configuration.speech == nil {
                throw ToolExecutorError.toolNotConfigured(tool.name)
            }
        }
    }

    /// Default set of directories the agent must never read/write: the app's
    /// Application Support directory, where its own secrets (API keys in
    /// `envvars.json`) are persisted. Denying the whole Application Support
    /// root keeps the agent from reading its own key material while leaving
    /// all user work (documents, canvas assets) readable.
    /// 绕过模式（已确认）下这个整体拒绝不再生效，改为只拒绝 MinisCanvas 自己的
    /// 目录与钥匙串，见 `BypassAppDataFloor`（用户 2026-10-22 决定）。
    public static func defaultDeniedRoots() -> [URL] {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }
        return [base]
    }

    public func execute(name: String, input: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        var input = input
        if ToolPathResolution.toolNames.contains(name), let raw = input["path"] as? String,
           !raw.isEmpty, !raw.hasPrefix("/") {
            guard let absolute = ToolPathResolution.absolutePath(
                for: raw, workingDirectory: effectiveWorkingDirectory.path) else {
                throw ToolExecutorError.invalidParameter("path 需要绝对路径（不能含 ..）：\(raw)")
            }
            input["path"] = absolute
        }
        try await validateChildWorkspace(name: name, input: input)
        let configuration = mutableState.withLock { $0 }
        // P1-1 工具白名单强制：任何未注册工具名在 dispatch 前被拒绝。
        // MCP 工具在每次动态发现后由 live registry 精确确认并加入白名单；
        // 仅凭 `mcp_*` 前缀不能放行伪造名称。
        if !configuration.registeredToolNames.contains(name) {
            guard name.hasPrefix("mcp_"), let mcpBridge = configuration.mcpBridge else {
                throw ToolExecutorError.unknownTool(name)
            }
            let discoveredNames = try await mcpBridge.mcpBoundTools().map(\.fullName)
            guard discoveredNames.contains(name) else {
                throw ToolExecutorError.unknownTool(name)
            }
            registerToolNames([name])
        }
        switch name {
        case SkillMaintenanceTool.readName:
            guard let skillMaintenance else { throw ToolExecutorError.toolNotConfigured(name) }
            return try await skillMaintenance.readIncludingExternal(input: input)
        case "skill_create", "skill_update", "skill_delete":
            guard let request = SkillMaintenanceApprovalContext.request,
                  request.toolName == name, request.inputDigest == (try ComposerToolInput(input)).digest,
                  let receipt = SkillMaintenanceApprovalContext.receipt,
                  let diff = request.skillDiff, let skillMaintenance else {
                throw ComposerAuthorizationError.approvalRequired(name)
            }
            return try await skillMaintenance.commit(name: name, input: ComposerToolInput(input),
                receipt: receipt, reviewedDiff: diff, deletionIntent: request.skillDeletionIntent)
        case SessionTodoProgress.toolName:
            return try SessionTodoProgress.execute(input: input)
        case "shell_execute":
            return try await runShell(input)
        case "shell_output":
            return try runShellOutput(input)
        case "shell_stop":
            return try await runShellStop(input)
        case "file_read":
            return try runFileRead(input)
        case "file_grep", "file_glob":
            return try ReadOnlyFileSearch.execute(name: name, input: input,
                validatePath: { try self.resolveReadablePath($0, tool: name) },
                isSensitive: SensitiveFilePolicy.isSensitive)
        case "file_write", "file_edit", "file_delete":
            return try await runSerialFileMutation(name: name, input: input)
        case "session_read":
            guard let sessionManager = configuration.sessionManager else {
                throw ToolExecutorError.toolNotConfigured("session_read")
            }
            return try SessionReadTool.read(input: input, manager: sessionManager)
        case ExternalSessionToolNames.read:
            return try await ExternalSessionReadTool.execute(
                input: input, roots: externalSessionRoots,
                knownSecrets: sessionReadKnownSecretsProvider(), now: Date())
        case ExternalSessionToolNames.send:
            return try await ExternalSessionSendTool.execute(
                input: input, roots: externalSessionRoots,
                knownSecrets: sessionReadKnownSecretsProvider(),
                attachmentPaths: try sessionAttachments(input: input).map(\.path))
        case SessionMessagingTool.toolName:
            return try await SessionMessagingTool.execute(
                input: input, knownSecrets: sessionReadKnownSecretsProvider(),
                attachments: try sessionAttachments(input: input))
        case TaskBoardTool.toolName:
            return try await TaskBoardTool.execute(input: input)
        case "web_fetch":
            guard let raw = input["url"] as? String, !raw.isEmpty else {
                throw ToolExecutorError.missingParameter("url")
            }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else { throw ToolExecutorError.invalidParameter("url") }
            guard let webFetchTransport else { throw ToolExecutorError.toolNotConfigured("web_fetch") }
            let content = try await webFetchTransport.fetch(url)
            return try webFetchEnvelope(url: raw, content: content)
        case "web_search":
            // E1: dispatches only when a search service was composed AND the
            // user's search settings are usable (the service itself throws
            // toolNotConfigured otherwise). With no service — the default, and
            // any consumer that registered the name explicitly — it still
            // fails with the typed error (error-class tool_result), never a
            // prose string that would look like a successful search.
            guard let webSearchService else { throw ToolExecutorError.toolNotConfigured("web_search") }
            return try await webSearchService.execute(input: input)
        default:
            // Composed native tools.
            if name == BrowserTool.toolName || name == BrowserTool.legacyToolName {
                guard let browser = configuration.browser else {
                    throw ToolExecutorError.toolNotConfigured(name)
                }
                return try await browser.execute(name: name, input: input)
            }
            if name == SpeechTool.toolName {
                guard SpeechToolExecutionAuthorization.current?.isSupported == true else {
                    throw ToolExecutorError.toolNotConfigured(name)
                }
                guard let speech = configuration.speech else {
                    throw ToolExecutorError.toolNotConfigured(name)
                }
                return try await speech.execute(name: name, input: input)
            }
            if name.hasPrefix("mcp_") {
                guard let mcpBridge = configuration.mcpBridge else {
                    throw ToolExecutorError.toolNotConfigured(name)
                }
                if let receipt = ToolExecutionReceiptContext.current,
                   receipt.toolName == name,
                   let execution = receipt.executionIdentity, execution.isValid,
                   let key = receipt.compositeKey, key.isValid,
                   key == ToolExecutionCompositeKey(sessionID: execution.turn.sessionID,
                       turnID: execution.turn.turnID, messageID: execution.turn.messageID,
                       operationID: execution.operationID, attemptID: receipt.attemptID,
                       attemptNumber: receipt.attemptNumber, toolCallID: receipt.toolCallID),
                   let fenced = mcpBridge as? any MCPToolBridgeInvocationFencing {
                    let invocation = MCPToolInvocationIdentity(correlationID: receipt.receiptID,
                        attemptID: receipt.attemptID)
                    guard invocation.isValid else { throw AgentLoopError.invalidToolExecutionAttempt }
                    return try await fenced.callMCPTool(fullName: name,
                        arguments: input.isEmpty ? nil : input, invocation: invocation)
                }
                // Legacy noninteractive dispatch remains available; without a
                // real receipt and fenced bridge it cannot present a form.
                return try await MCPElicitationTaskContext.$handler.withValue(nil) {
                    try await mcpBridge.callMCPTool(fullName: name,
                        arguments: input.isEmpty ? nil : input)
                }
            }
            throw ToolExecutorError.unknownTool(name)
        }
    }

    private func validateChildWorkspace(name: String, input: [String: Any]) async throws {
        try Task.checkCancellation()
        if let context = AgentExecutionContext.current, let binding = context.childToolRuntimeBinding {
            guard await binding.verifiedParentSessionID(for: name, context: context) == binding.parent.sessionID else {
                throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
            }
        }
        guard let scope = ChildToolWorkspaceScope.current else { return }
        guard await scope.parentAuthorityCheck?() != false else { throw CancellationError() }
        // Root identity must not move through a symlink after the turn froze it.
        guard PolicyRuntimePathBoundary.canonicalPath(scope.workingDirectory) == scope.workingDirectory,
              (scope.readRoots + scope.writeRoots).allSatisfy({ PolicyRuntimePathBoundary.canonicalPath($0) == $0 }) else {
            throw ToolExecutorError.pathViolation(scope.workingDirectory)
        }
        if name == "file_read", let raw = input["path"] as? String,
           try resolveOwnedOutputArtifactRead(path: raw) != nil {
            // Only the current session's already-produced output object may
            // cross the project path ceiling; parent identity/authority checks
            // above still run. Mutations and directory searches never use it.
            return
        }
        if ["file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete"].contains(name) {
            guard let raw = input["path"] as? String,
                  let physical = PolicyRuntimePathBoundary.canonicalPath(raw) else {
                throw ToolExecutorError.invalidParameter("path")
            }
            // 子任务文件跟随父会话（用户 2026-10-22 决定）：父会话是已确认的绕过、且
            // 「子任务写入」开关打开（scope.filesOpen 由编排器据此设置），同时当前确实处于
            // 由已确认绕过快照打开的 BypassOpenScope 内，才不再按子任务工作目录/父目录限制
            // 文件读写删。系统底线、MinisCanvas 自身目录、凭据保护、废纸篓删除仍由
            // 本执行器在 scope 内照常判断。其余情形一律保持原限制。
            if scope.filesOpen, BypassOpenScope.isActive { try Task.checkCancellation(); return }
            let roots = ["file_read", "file_grep", "file_glob"].contains(name) ? scope.readRoots : scope.writeRoots
            let hasReadApproval = ["file_read", "file_grep", "file_glob"].contains(name)
                && ApprovedFileReadScope.permits(tool: name, path: physical)
            let hasWriteApproval = ["file_write", "file_edit"].contains(name)
                && ApprovedFileWriteScope.permits(tool: name, path: physical)
            guard (roots.contains(where: { physical == $0 || physical.hasPrefix($0 + "/") }) || hasReadApproval || hasWriteApproval),
                  !scope.deniedRoots.contains(where: { PolicyRuntimePathBoundary.foldedCandidate(physical, isWithin: $0) }) else {
                throw ToolExecutorError.pathViolation(raw)
            }
        }
        try Task.checkCancellation()
    }

    /// A durable before-image under the existing pre-Gate resource lock. This
    /// does not grant permission, mint a receipt, or execute any deletion.
    public func prepareChildDeletionReview(path: String, context: AgentExecutionContextSnapshot,
        approvalContext: ApprovalPresentationContext) async throws -> ChildDeletionReviewPreparation? {
        guard fileCheckpointsEnabled, let store = fileCheckpointStore else { return nil }
        guard let binding = context.childToolRuntimeBinding,
              approvalContext.toolName == "file_delete",
              approvalContext.executionIdentity.turn.sessionID == binding.boundary.identity.childSessionID,
              let parentSessionID = await binding.verifiedParentSessionID(for: "file_delete", context: context)
        else { throw ToolExecutorError.permissionDenied(path) }
        let physical = try Self.resolveAllowedPath(path, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots).path
        let key = PolicyRuntimePathBoundary.foldedForPathComparison(physical)
        guard let lease = ToolFileMutationLease.current, lease.key == key,
              lease.matchesApprovalContext(approvalContext),
              await ToolFileMutationSerialiser.shared.owns(key: key, token: lease.token)
        else { throw ToolExecutionFactLedgerError.receiptIdentityMismatch }
        try await validateChildWorkspace(name: "file_delete", input: ["path": physical])
        guard try Self.resolveAllowedPath(path, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots).path == physical,
              lease.matchesApprovalContext(approvalContext) else {
            throw ToolExecutorError.pathViolation(path)
        }
        try ToolFileMutationScope.validateSingleLinkedTarget(physical)
        try Task.checkCancellation()
        let producer = binding.boundary.identity.childSessionID
        let url = URL(fileURLWithPath: physical)
        let id = try store.begin(path: url, sessionID: producer, operation: .delete, expectedAfter: nil,
            conversation: FileCheckpointConversationContext.current, parentSessionID: parentSessionID)
        _ = try store.verifiedDeletionBackup(id, path: url, sessionID: producer)
        return ChildDeletionReviewPreparation(store: store, checkpointID: id, approvalContext: approvalContext)
    }

    private func runSerialFileMutation(name: String, input: [String: Any]) async throws -> String {
        // Preserve the existing crash-recovery proof when path validation or
        // lock admission refuses before runFileWrite. This is idempotent and
        // never clears an already-started marker or claims completion.
        if name == "file_write", let receipt = ToolExecutionReceiptContext.current,
           let ledger = ToolExecutionReceiptContext.ledger {
            try ledger.prepareFileWrite(receipt)
        }
        guard let raw = input["path"] as? String else { throw ToolExecutorError.invalidParameter("path") }
        let physical = try Self.resolveAllowedPath(raw, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots).path
        // 凭据保护只在绕过模式（已确认）生效；其他模式保持 7428f83 原行为。
        if BypassOpenScope.isActive,
           SensitiveFilePolicy.credentialDenial(for: physical, forWrite: true) != nil {
            throw ToolExecutorError.permissionDenied(raw)
        }
        let key = PolicyRuntimePathBoundary.foldedForPathComparison(physical)
        if let outer = ToolFileMutationLease.current {
            guard outer.key == key,
                  await ToolFileMutationSerialiser.shared.owns(key: key, token: outer.token),
                  outer.claimBuiltinUse(key: key, receipt: ToolExecutionReceiptContext.current) else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            defer { outer.finishBuiltinUse() }
            return try await performCheckedFileMutation(name: name, input: input, physical: physical)
        }
        let frozen = try ComposerToolInput(input)
        return try await ToolFileMutationScope.withLock(path: URL(fileURLWithPath: physical)) {
            try await self.performCheckedFileMutation(name: name, input: frozen.toolExecutionDictionary, physical: physical)
        }
    }

    private func performCheckedFileMutation(name: String, input: [String: Any], physical: String) async throws -> String {
        try Task.checkCancellation()
        try await validateChildWorkspace(name: name, input: input)
        guard let raw = input["path"] as? String else { throw ToolExecutorError.invalidParameter("path") }
        let current = try Self.resolveAllowedPath(raw, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots).path
        guard current == physical else { throw ToolExecutorError.pathViolation(raw) }
        if BypassOpenScope.isActive {
            // 系统底线：改写/删除操作系统文件、卸载或改写已安装软件，绕过下也拒绝。
            if let reason = BypassSystemFloor.violation(
                path: physical, operation: name == "file_delete" ? .delete : .modify) {
                throw ToolExecutorError.writeFailed(reason)
            }
            // 删除包含 MinisCanvas 自身数据目录的父目录（如整个 Application Support）同样拒绝；
            // 目录内部的读写删已在 resolveAllowedPath 里按 BypassAppDataFloor 拒绝。
            if let reason = BypassAppDataFloor.violation(
                path: physical, access: name == "file_delete" ? .delete : .modify) {
                throw ToolExecutorError.writeFailed(reason)
            }
            // 绕过模式下删除改为移入废纸篓，不永久删除。
            if name == "file_delete", !fileCheckpointsEnabled {
                return try runFileTrash(raw: raw, physical: physical)
            }
            if name == "file_delete", fileCheckpointsEnabled {
                var leaf = stat()
                if Darwin.lstat(URL(fileURLWithPath: raw).standardizedFileURL.path, &leaf) == 0,
                   (leaf.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                    // Trash moves the link, not its target. The existing
                    // regular-file checkpoint cannot restore a link safely.
                    throw FileCheckpointStore.Failure.unsafeFile
                }
            }
        }
        // Match the existing delete policy: regular files with hard-link
        // aliases are refused rather than assigned independent pathname locks.
        try ToolFileMutationScope.validateSingleLinkedTarget(physical)
        // Revalidate the exact approved snapshot after waiting for the lock.
        try ApprovalFilePreviewContext.current?.validateCurrent()
        // 先读再改：执行锁内再复核一次（审批预检之前已查过一次）。
        try verifyReadBeforeMutation(name: name, physical: physical, input: input)
        try Task.checkCancellation()
        var checked = input
        checked["path"] = physical
        if name == "file_write", let content = checked["content"] as? String,
           content.contains(Self.redactedFileMarker) || content.contains("*") {
            let original: String
            if FileManager.default.fileExists(atPath: physical) {
                let url = URL(fileURLWithPath: physical)
                if content.contains(Self.redactedFileMarker) {
                    original = String(decoding: try readFileDataOrDenial(at: url, path: physical), as: UTF8.self)
                } else {
                    // Ordinary asterisks do not add a read requirement to
                    // existing write-only targets.
                    original = (try? readFileDataOrDenial(at: url, path: physical))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                }
            } else {
                original = ""
            }
            let proposed = checked["append"] as? Bool == true ? original + content : content
            guard !Self.introducesRedactedFileMask(from: original, to: proposed) else {
                throw ToolExecutorError.writeFailed(Self.redactedFileMutationMessage)
            }
        }
        let checkpoint: (store: FileCheckpointStore, id: UUID)?
        if name == "file_delete", ChildDeletionReviewPreparationContext.current != nil, !fileCheckpointsEnabled {
            throw ToolExecutorError.writeFailed("检查点配置已变化，本次删除未执行。")
        }
        // 真密钥文件（.env、密钥、凭据目录）的编辑：允许，但不留检查点备份
        // （备份会把密钥正文复制进检查点存储）；审批卡已写明改动不可撤销。
        // 删除仍要备份，由检查点存储按原规则拒绝。
        let skipSecretCheckpoint = name != "file_delete" && SensitiveFilePolicy.isUncheckpointedSecretFile(physical)
        if fileCheckpointsEnabled, !skipSecretCheckpoint {
            guard let store = fileCheckpointStore else {
                throw ToolExecutorError.writeFailed("检查点存储不可用，本次文件改动未执行。")
            }
            let url = URL(fileURLWithPath: physical)
            let operation: FileCheckpointStore.Operation
            let expected: Data?
            switch name {
            case "file_write":
                guard let content = checked["content"] as? String else { throw ToolExecutorError.missingParameter("content") }
                operation = .write
                var output = (checked["append"] as? Bool == true) && FileManager.default.fileExists(atPath: physical)
                    ? try readFileDataOrDenial(at: url, path: physical) : Data()
                output.append(Data(content.utf8)); expected = output
            case "file_edit":
                guard let old = checked["old_string"] as? String, !old.isEmpty,
                      let new = checked["new_string"] as? String else { throw ToolExecutorError.invalidParameter("edit strings") }
                let data = try readFileDataOrDenial(at: url, path: physical)
                if FileImporter.isPDF(data: data, pathExtension: url.pathExtension) {
                    throw ToolExecutorError.editFailed("PDF 无法编辑：\(physical)。请另存为文本或 Markdown 后再改，或用 file_write 新建文件。")
                }
                guard let text = String(data: data, encoding: .utf8) else { throw ToolExecutorError.fileIsBinary(physical) }
                let edited: String
                switch Self.matchAndReplaceEdit(in: text, old: old, new: new, replaceAll: checked["replace_all"] as? Bool == true) {
                case .notFound:
                    throw ToolExecutorError.editFailed(Self.editNotFoundDetail(path: physical, text: text, old: old))
                case .ambiguous:
                    throw ToolExecutorError.editFailed("old_string must identify one location, or use replace_all=true")
                case .replaced(let result, _, _):
                    edited = result
                }
                guard !Self.introducesRedactedFileMask(from: text, to: edited) else {
                    throw ToolExecutorError.editFailed(Self.redactedFileMutationMessage)
                }
                operation = .edit; expected = Data(edited.utf8)
            default: operation = .delete; expected = nil
            }
            let sessionID = ToolExecutionReceiptContext.current?.compositeKey?.sessionID ?? fileChangeSessionID
            let parentSessionID: String?
            if let context = AgentExecutionContext.current, let binding = context.childToolRuntimeBinding {
                guard let verified = await binding.verifiedParentSessionID(for: name, context: context) else {
                    throw ToolExecutorError.permissionDenied(physical)
                }
                parentSessionID = verified
            } else { parentSessionID = nil }
            try Task.checkCancellation()
            try ApprovalFilePreviewContext.current?.validateCurrent()
            if name == "file_delete", let preparation = ChildDeletionReviewPreparationContext.current {
                guard preparation.store === store,
                      let receipt = ToolExecutionReceiptContext.current, preparation.matches(receipt) else {
                    throw ToolExecutionFactLedgerError.receiptIdentityMismatch
                }
                do { _ = try store.verifiedDeletionBackup(preparation.checkpointID, path: url, sessionID: sessionID) }
                catch {
                    throw ToolExecutorError.writeFailed("删除检查点已失效或文件已变化，本次删除未执行；请重新发起审批。")
                }
                checkpoint = (store, preparation.checkpointID)
            } else {
                let id = try store.begin(path: url, sessionID: sessionID, operation: operation,
                    expectedAfter: expected, conversation: FileCheckpointConversationContext.current,
                    parentSessionID: parentSessionID)
                checkpoint = (store, id)
            }
        } else { checkpoint = nil }
        // Durable backup reads cannot extend the approved version's lifetime.
        try ApprovalFilePreviewContext.current?.validateCurrent()
        try Task.checkCancellation()
        let result: String
        switch name {
        case "file_write":
            try await validateChildTaskArtifactProject(tool: name)
            try Task.checkCancellation()
            result = try await runFileWrite(checked)
        case "file_edit":
            try await validateChildTaskArtifactProject(tool: name)
            try Task.checkCancellation()
            result = try await runFileEdit(checked)
        default:
            result = BypassOpenScope.isActive
                ? try runFileTrash(raw: raw, physical: physical)
                : try runFileDelete(checked)
        }
        if let checkpoint { try checkpoint.store.commit(checkpoint.id) }
        // 写入/编辑成功后，本会话视为已读到最新版本；删除后清除记录。
        if let session = fileReadRecordSessionID {
            if name == "file_delete" {
                FileReadRecordStore.shared.forget(sessionID: session, path: physical)
            } else {
                FileReadRecordStore.shared.recordRead(sessionID: session, path: physical)
            }
        }
        return result
    }

    func captureChildTaskArtifactProject(workingDirectory: String) async -> TaskFileArtifactProjectGrant? {
        guard let directory = try? validatedTargetWorkspaceDirectory(workingDirectory),
              let resolver = taskArtifactProjectResolver,
              let projectID = await resolver(directory.path), !projectID.isEmpty else { return nil }
        return TaskFileArtifactProjectGrant(projectID: projectID, workingDirectory: directory.path)
    }

    /// Generic child provenance uses the existing child receipt. Its operation
    /// remains generationID; canonical task attempts come only from the store.
    static func captureChildTaskArtifactBinding(context: AgentExecutionContextSnapshot,
        receipt: ToolExecutionReceipt) throws -> TaskFileArtifactBinding? {
        guard let project = context.taskArtifactProject else { return nil }
        guard let runtime = context.childToolRuntimeBinding,
              let store = context.taskStore, let key = receipt.compositeKey,
              let execution = receipt.executionIdentity,
              receipt.parentRuntimeIdentity == runtime.parent,
              receipt.childTranscriptLocator == runtime.locator,
              receipt.targetTaskBinding == nil, receipt.targetTaskSource == nil,
              execution.operationID == runtime.boundary.identity.generationID,
              execution.turn.sessionID == runtime.locator.childSessionID,
              execution.turn.messageID == runtime.locator.taskID,
              key.sessionID == runtime.locator.childSessionID,
              key.turnID == execution.turn.turnID,
              key.messageID == execution.turn.messageID, key.operationID == execution.operationID,
              key.toolCallID == receipt.toolCallID,
              key.attemptID == receipt.attemptID, key.attemptNumber == receipt.attemptNumber,
              let task = store.taskSnapshot(runID: runtime.locator.runID),
              task.creation == nil, task.status == .running,
              task.taskID == runtime.locator.taskID, task.parentID == runtime.locator.parentID,
              store.canonicalAttemptID(runID: runtime.locator.runID) == runtime.locator.attemptID,
              (store.retryRunRuntimeBinding(runID: runtime.locator.runID)?.child
                ?? task.childRuntimeIdentity) == runtime.boundary.identity,
              store.childTranscriptLocator(taskID: task.taskID, parentID: task.parentID,
                  runID: runtime.locator.runID, attemptID: runtime.locator.attemptID,
                  childExecutionID: runtime.locator.childExecutionID,
                  parentContextSnapshotID: runtime.locator.parentContextSnapshotID) == runtime.locator,
              PolicyRuntimePathBoundary.canonicalPath(runtime.boundary.identity.workingDirectory)
                == project.workingDirectory else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        return TaskFileArtifactBinding(taskID: task.taskID, parentID: task.parentID,
            runID: runtime.locator.runID, attemptID: runtime.locator.attemptID,
            sourceSessionID: runtime.locator.parentSessionID,
            producerSessionID: runtime.locator.childSessionID,
            workingDirectory: project.workingDirectory, projectID: project.projectID)
    }

    private func validateChildTaskArtifactProject(tool: String) async throws {
        guard let context = AgentExecutionContext.current,
              let project = context.taskArtifactProject else { return }
        guard fileChangeLedger != nil,
              let runtime = context.childToolRuntimeBinding,
              await runtime.verifiedParentSessionID(for: tool, context: context) == runtime.parent.sessionID,
              let receipt = ToolExecutionReceiptContext.current, receipt.toolName == tool,
              try Self.captureChildTaskArtifactBinding(context: context, receipt: receipt) != nil else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        guard let resolver = taskArtifactProjectResolver,
              await resolver(project.workingDirectory) == project.projectID else {
            throw ToolExecutorError.writeFailed("原生项目授权已撤销或变化")
        }
    }

    /// The project-task producer already uses operationID = runID. Read only
    /// that exact run; ordinary Chat and child operations have no target origin.
    /// This is provenance capture, not workspace or tool authorization.
    static func captureTargetTaskOrigin(
        context: AgentExecutionContextSnapshot, executionIdentity: AgentExecutionIdentity?
    ) throws -> (binding: TaskFileArtifactBinding, source: ParentRuntimeIdentity)? {
        guard context.childToolRuntimeBinding == nil,
              let identity = executionIdentity, let store = context.taskStore,
              let task = store.taskSnapshot(runID: identity.operationID),
              let creation = task.creation, creation.projectID != nil else { return nil }
        guard identity.isValid, context.hasVerifiedParentRuntime,
              let parent = context.parentRuntimeIdentity,
              parent.taskID == task.taskID, parent.sessionID == identity.turn.sessionID,
              context.currentConversationID == parent.sessionID,
              task.status == .running, creation.source.isValid,
              task.parentID == creation.source.taskID,
              let directory = creation.action.workingDirectory,
              let attemptID = store.canonicalAttemptID(runID: identity.operationID) else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        let binding = TaskFileArtifactBinding(taskID: task.taskID, parentID: task.parentID,
            runID: identity.operationID, attemptID: attemptID,
            sourceSessionID: creation.source.sessionID, producerSessionID: parent.sessionID,
            workingDirectory: directory)
        guard binding.isValid,
              store.taskSnapshot(runID: identity.operationID) == task else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        return (binding, creation.source)
    }

    /// Run one App-bound target task from its canonical project directory.
    /// The caller supplies an immutable binding outside tool JSON; Core checks
    /// it against the active turn and durable task/run facts on every effect.
    /// A scoped executor narrows file tools to that project and gives shell
    /// its target cwd, while the caller's Safety/Policy/Recording/Composer
    /// wrappers remain outside this dispatch.
    public func executeInTargetWorkspace(
        name: String, input: [String: Any], binding: TargetWorkspaceBinding
    ) async throws -> String {
        guard ["shell_execute", "file_read", "file_grep", "file_glob", "file_write", "file_edit", "file_delete"].contains(name),
              registeredToolNames.contains(name), binding.source.isValid,
              !binding.taskID.isEmpty, !binding.runID.isEmpty,
              !binding.projectID.isEmpty,
              let context = AgentExecutionContext.current,
              context.hasVerifiedParentRuntime,
              context.currentConversationID == binding.targetSessionID,
              context.parentRuntimeIdentity?.sessionID == binding.targetSessionID,
              context.parentRuntimeIdentity?.taskID == binding.taskID,
              let handle = context.parentTurnHandle,
              let store = context.taskStore,
              let task = store.taskSnapshot(runID: binding.runID),
              task.taskID == binding.taskID, task.parentID == binding.source.taskID,
              task.status == .running,
              task.creation?.source == binding.source,
              task.creation?.projectID == binding.projectID,
              task.creation?.action.workingDirectory == binding.workingDirectory,
              store.controlSnapshot(taskID: binding.taskID,
                  parentID: binding.source.taskID)?.runID == binding.runID,
              let taskAttemptID = store.canonicalAttemptID(runID: binding.runID),
              await handle.acceptsToolEvent(), !Task.isCancelled else {
            throw ToolExecutorError.pathViolation(binding.workingDirectory)
        }
        let directory = try validatedTargetWorkspaceDirectory(binding.workingDirectory)
        // The original receipt stays immutable. Recheck the mint-time origin
        // against both the live canonical run and the App registry binding
        // after the awaited turn check, before any physical effect.
        if name == "file_write" || name == "file_edit" || name == "file_delete" {
            guard let receipt = ToolExecutionReceiptContext.current,
                  receipt.toolName == name,
                  let captured = try Self.captureTargetTaskOrigin(
                    context: context, executionIdentity: receipt.executionIdentity),
                  captured.source == binding.source,
                  captured.binding == receipt.targetTaskBinding,
                  captured.source == receipt.targetTaskSource,
                  captured.binding.taskID == binding.taskID,
                  captured.binding.runID == binding.runID,
                  captured.binding.attemptID == taskAttemptID,
                  captured.binding.producerSessionID == binding.targetSessionID,
                  captured.binding.workingDirectory == directory.path else {
                throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
            }
        }
        let scopedConfiguration = mutableState.withLock { $0 }
        let scoped = BuiltinToolExecutor(
            allowedRoot: directory,
            defaultShellTimeout: scopedConfiguration.defaultShellTimeout,
            deniedRoots: configuredDeniedRoots,
            appPrivateDeniedRoots: appPrivateDeniedRoots,
            additionalAllowedRoots: [],
            registeredToolNames: scopedConfiguration.registeredToolNames,
            terminalPolicySnapshot: scopedConfiguration.terminalPolicySnapshot
        )
        scoped.fileCheckpointsEnabled = scopedConfiguration.fileCheckpointsEnabled
        scoped.fileCheckpointStore = scopedConfiguration.fileCheckpointStore
        scoped.fileChangeLedger = scopedConfiguration.fileChangeLedger
        scoped.fileChangeSessionID = binding.targetSessionID
        scoped.taskFileArtifactBinding = TaskFileArtifactBinding(
            taskID: binding.taskID, parentID: binding.source.taskID,
            runID: binding.runID, attemptID: taskAttemptID,
            sourceSessionID: binding.source.sessionID,
            producerSessionID: binding.targetSessionID, workingDirectory: directory.path
        )
        return try await scoped.execute(name: name, input: input)
    }

    /// Public for the App's pre-run check and focused Core path tests. It
    /// grants nothing: the actual call repeats this check after validating
    /// the Core turn and task/run ledger.
    /// The trusted session producer supplies its frozen project directory.
    /// Model-controlled cwd continues to use validatedTargetWorkspaceDirectory.
    func validatedSessionWorkspaceDirectory(_ raw: String) throws -> URL {
        guard sessionDerivedRoot else { return try validatedTargetWorkspaceDirectory(raw) }
        return try Self.validatedTargetWorkspaceDirectory(raw,
            allowedRoot: URL(fileURLWithPath: raw, isDirectory: true),
            additionalAllowedRoots: [], deniedRoots: deniedRoots)
    }

    /// Trusted App admission after human approval, never a model-call path.
    /// Returns a canonical directory for a new immutable session-root snapshot;
    /// this method does not mutate this executor or grant any file/tool effect.
    public func validatedApprovedSessionDirectory(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/") else { throw ToolExecutorError.pathViolation(raw) }
        return try Self.validatedTargetWorkspaceDirectory(raw,
            allowedRoot: URL(fileURLWithPath: raw, isDirectory: true),
            additionalAllowedRoots: [], deniedRoots: deniedRoots)
    }

    public enum ProjectDirectoryAuthorizationError: Error {
        case directoryUnavailable
        case outsideAccessibleRoots
    }

    /// Native project picker admission with a specific root-boundary failure.
    /// Other policy failures retain their original error and remain denied.
    public func validatedProjectAuthorizationDirectory(_ raw: String) throws -> URL {
        try Self.validatedTargetWorkspaceDirectory(raw, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots,
            reportAuthorizationFailure: true)
    }

    public func validatedTargetWorkspaceDirectory(_ raw: String) throws -> URL {
        try Self.validatedTargetWorkspaceDirectory(raw, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots)
    }

    private static func validatedTargetWorkspaceDirectory(_ raw: String, allowedRoot: URL, additionalAllowedRoots: [URL], deniedRoots: [URL], reportAuthorizationFailure: Bool = false) throws -> URL {
        let canonical = try resolveAllowedPath(raw, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots, reportRootBoundary: reportAuthorizationFailure)
        guard canonical.path == URL(fileURLWithPath: raw).standardizedFileURL.path else {
            throw ToolExecutorError.pathViolation(raw)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if reportAuthorizationFailure { throw ProjectDirectoryAuthorizationError.directoryUnavailable }
            throw ToolExecutorError.pathViolation(raw)
        }
        return URL(fileURLWithPath: canonical.path, isDirectory: true)
    }

    /// Read-only result admission through the same current allow/deny table.
    /// Checking the directory alone would miss a newly denied child path.
    public func validatedFileArtifactTarget(_ raw: String, workingDirectory: String) throws -> URL {
        try Self.validatedFileArtifactTarget(raw, workingDirectory: workingDirectory, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots)
    }

    /// Only immutable path authority crosses to the background reader. The
    /// mutable executor is never declared Sendable or captured across actors.
    public func fileArtifactTargetValidator() -> @Sendable (String, String) -> URL? {
        let root = allowedRoot, additional = additionalAllowedRoots, denied = deniedRoots
        return { raw, directory in
            try? Self.validatedFileArtifactTarget(raw, workingDirectory: directory, allowedRoot: root, additionalAllowedRoots: additional, deniedRoots: denied)
        }
    }

    private static func validatedFileArtifactTarget(_ raw: String, workingDirectory: String, allowedRoot: URL, additionalAllowedRoots: [URL], deniedRoots: [URL]) throws -> URL {
        let directory = try validatedTargetWorkspaceDirectory(workingDirectory, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots)
        let target = try resolveAllowedPath(raw, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots)
        guard BypassOpenScope.isActive || target.path.hasPrefix(directory.path + "/") else {
            throw ToolExecutorError.pathViolation(raw)
        }
        return target
    }

    /// Capability-aware session access used by `AgentLoop`. The typed
    /// authorization and turn context stay outside model-controlled input;
    /// the legacy `execute(name:input:)` entry point remains fail-closed.
    public func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        guard let sessionManager else {
            throw ToolExecutorError.toolNotConfigured("session_read")
        }
        return try SessionReadTool.read(
            input: input,
            manager: sessionManager,
            authorization: authorization,
            context: context,
            now: now,
            knownSecretsProvider: sessionReadKnownSecretsProvider
        )
    }

    /// Confirmation-card text for `external_session_send`. Throws (and so
    /// refuses the call) when the session cannot be located, the message is
    /// secret-shaped, or the whole card would exceed the dialog window.
    func externalSessionApprovalSummary(input: [String: Any]) async throws -> String {
        try await ExternalSessionSendTool.approvalSummary(
            input: input, roots: externalSessionRoots,
            knownSecrets: sessionReadKnownSecretsProvider(),
            attachmentPaths: try sessionAttachments(input: input).map(\.path))
    }

    /// session_send / external_session_send 的文件附件：每个路径都过读取授权根和敏感文件检查，
    /// 越权或敏感时整个调用被拒绝，不静默丢掉附件。
    func sessionAttachments(input: [String: Any]) throws -> [SessionAttachmentFiles.Resolved] {
        let paths = try SessionAttachmentFiles.requestedPaths(input)
        guard !paths.isEmpty else { return [] }
        return try SessionAttachmentFiles.resolve(paths: paths) { raw in
            try Self.resolveAllowedPath(
                raw, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots,
                deniedRoots: deniedRoots)
        }
    }

    // MARK: - shell_execute

    private static func makePipeReader(
        _ handle: FileHandle,
        lifetime: ShellPipeReaderLifetime,
        onChunk: (@Sendable (Data) -> Void)? = nil
    ) -> Task<Data, Never> {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else {
            return Task {
                await lifetime.recordIncomplete()
                return Data()
            }
        }
        let maxBytes = shellOutputLimit
        return Task.detached(priority: .userInitiated) {
            let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            return await readPipeData(reader, maxBytes: maxBytes, lifetime: lifetime, onChunk: onChunk)
        }
    }

    /// Approval is owned by the existing gate; this check only applies denials.
    @discardableResult
    static func validateShellPolicy(command: String, snapshot: TerminalPolicySnapshot) throws -> TerminalCommandDisposition {
        let disposition = snapshot.classify(command: command)
        if disposition == .denied {
            throw ToolExecutorError.shellRejected("command denied by terminal policy")
        }
        return disposition
    }

    /// Each call selects its directory explicitly; a standalone cd cannot
    /// silently pretend to change the working directory of subsequent calls.
    func shellWorkingDirectory(_ input: [String: Any]) throws -> URL {
        if let command = input["command"] as? String {
            let parsed = TerminalGuard.inspect(command)
            if parsed.isAllowed, parsed.words.first == "cd" {
                throw ToolExecutorError.invalidParameter("此工具不保持目录，请使用 cwd 参数；一次执行一条命令。")
            }
        }
        guard let value = ShellToolInput.explicitWorkingDirectory(input) else { return effectiveWorkingDirectory }
        guard let raw = value as? String, raw.hasPrefix("/") else {
            throw ToolExecutorError.invalidParameter("cwd（请提供授权目录内的绝对路径）")
        }
        let directory = try validatedTargetWorkspaceDirectory(raw)
        if let scope = ChildToolWorkspaceScope.current {
            guard (scope.readRoots + scope.writeRoots).contains(where: {
                directory.path == $0 || directory.path.hasPrefix($0 + "/")
            }), !scope.deniedRoots.contains(where: {
                PolicyRuntimePathBoundary.foldedCandidate(directory.path, isWithin: $0)
            }) else { throw ToolExecutorError.pathViolation(raw) }
        }
        return directory
    }

    /// Trusted async preflight for presentation only. Never executes the proposed
    /// write and never changes its JSON, input digest or approval identity.
    public func prepareGitWriteSummary(_ input: [String: Any], policySnapshot: TerminalPolicySnapshot? = nil) async throws -> String? {
        guard let command = input["command"] as? String,
              GitWorkflowPolicy.approvalContext(command: command) != nil else { return nil }
        let snapshot = policySnapshot ?? terminalPolicySnapshot
        try Self.validateShellPolicy(command: command, snapshot: snapshot)
        let directory = try shellWorkingDirectory(input)
        let denied = configuredDeniedRoots
        let privateFloor = appPrivateDeniedRoots
        let timeout = defaultShellTimeout
        try await validateChildWorkspace(name: "shell_execute", input: input)
        return try await Self.gitWriteApprovalPresentation(command: command, directory: directory,
            snapshot: snapshot, knownSecrets: ModelShellEnvironment.knownCredentialValues()) {
            try await GitWorkflowService.prepareWriteSummary(
                command: command, workingDirectory: directory.path,
                readOnly: { readCommand, workingDirectory in
                    // The service may only use finite read-only forms and the
                    // exact same captured directory/policy as this preflight.
                    if snapshot.classify(command: readCommand) == .denied {
                        throw GitSummaryPresentationError.policyDenied
                    }
                    guard workingDirectory == directory.path,
                          snapshot.classify(command: readCommand) == .allowed,
                          GitWorkflowPolicy.automaticallyAllows(command: readCommand) else {
                        throw ToolExecutorError.shellRejected("Git 审批摘要只允许在当前目录读取状态和差异统计")
                    }
                    let reader = BuiltinToolExecutor(allowedRoot: directory,
                        defaultShellTimeout: timeout, deniedRoots: denied, appPrivateDeniedRoots: privateFloor,
                        terminalPolicySnapshot: snapshot)
                    let raw = try await ShellCommandTimeoutPolicy.$currentBudget.withValue(nil) {
                        try await reader.runShell(["command": readCommand, "cwd": directory.path])
                    }
                    guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                          let exitCode = object["exit_code"] as? Int,
                          let stdout = object["stdout"] as? String,
                          let stderr = object["stderr"] as? String,
                          let code = Int32(exactly: exitCode) else {
                        throw ToolExecutorError.shellRejected("Git 摘要读取结果格式无效")
                    }
                    var captured = stdout
                    if let artifact = object["stdout_artifact"] as? [String: Any], let path = artifact["path"] as? String {
                        captured += "\n已捕获的统计输出文件：" + path
                    }
                    return GitWorkflowService.CommandResult(exitCode: code, stdout: captured, stderr: stderr)
                })
        }
    }

    private enum GitSummaryPresentationError: Error { case policyDenied }

    /// Presentation failures do not change the original command's approval
    /// eligibility. No input dictionary, command or approval identity is rebuilt.
    /// The injected operation is internal so synthetic tests launch no process.
    static func gitWriteApprovalPresentation(
        command: String, directory: URL, snapshot: TerminalPolicySnapshot,
        knownSecrets: [String],
        prepare: () async throws -> GitWorkflowService.WriteSummary
    ) async throws -> String {
        try Task.checkCancellation()
        try validateShellPolicy(command: command, snapshot: snapshot)
        let text: String
        do {
            let summary = try await prepare()
            text = "工作目录：" + directory.path + "\n当前状态：\n" + summary.status + "\n" + summary.approvalText
                + "\n以上为审批前读取的状态；批准前文件仍可能变化。"
        } catch {
            // Preserve the original typed cancellation, including wrapped forms.
            if ProviderCancellationPolicy.isCancellation(error) { throw error }
            try Task.checkCancellation()
            if error is GitSummaryPresentationError {
                throw ToolExecutorError.shellRejected("command denied by terminal policy")
            }
            let reason: String
            switch error {
            case GitWorkflowService.WorkflowError.unsupportedWriteCommand:
                reason = "此命令形式不支持可靠的审批前差异摘要"
            case GitWorkflowService.WorkflowError.commandFailed(let readCommand, let exitCode, let stdout, let stderr):
                reason = "摘要读取失败（exit \(exitCode)）：\(readCommand)\n\(stdout)\n\(stderr)"
            default:
                reason = "摘要读取失败或超时：" + error.localizedDescription
            }
            text = "工作目录：" + directory.path + "\n审批前摘要不可用：" + reason
                + "\n差异统计：未能形成；未提供统计。\n仍按原命令与目录进行本次审批；摘要不可用不代表命令已执行或已获批准。"
        }
        try Task.checkCancellation()
        return ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
    }

    private func runShell(_ input: [String: Any]) async throws -> String {
        guard let command = input["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutorError.missingParameter("command")
        }
        // ApprovalGate asks for the exact shell input before this executor runs.
        // Unknown commands therefore proceed after approval, like confirmation
        // commands; the shared snapshot still enforces actual denials.
        if let reason = SensitiveFilePolicy.protectedStateShellViolation(command: command) {
            throw ToolExecutorError.shellRejected(reason)
        }
        if BypassOpenScope.isActive {
            // 绕过模式「全面放开」：任何命令都可执行，不再看终端策略的未登记命令
            // 拒绝与硬拒绝表。只保留系统底线与凭据保护的「尽力匹配」。
            // 这不是安全边界：文本匹配拦不住 python -c、脚本文件、find -exec、
            // 变量拼接、相对路径等间接写法；可靠兜底是 macOS 系统完整性保护。
            if let reason = BypassSystemFloor.shellViolation(command: command)
                ?? SensitiveFilePolicy.credentialShellViolation(command: command)
                ?? BypassAppDataFloor.shellMentionViolation(command: command)
                ?? ShellNestedCommandInspector.violation(command: command) {
                throw ToolExecutorError.shellRejected(reason)
            }
            // 用户自己在终端策略里设置的拒绝命令（userDeniedCommands）在绕过下继续生效
            // （用户 2026-10-22 决定）。只取消系统硬拒绝表与「未登记即拒绝」。
            // 判断口径与 `TerminalPolicySnapshot.classify` 里的拒绝分支一致。
            if terminalPolicySnapshot.userDeniedExecutable(in: command) != nil {
                throw ToolExecutorError.shellRejected("command denied by terminal policy")
            }
        } else {
            let policySnapshot = terminalPolicySnapshot
            let disposition = try Self.validateShellPolicy(command: command, snapshot: policySnapshot)
            // 只读免问的命令（od、hexdump、xxd、strings 等不在终端策略放行表里）没有用户当场批准，
            // 但授权时已过效果检查器，下面 recheckViolation 在执行前会再过一次同一个检查器。
            if disposition == .unknown,
               !ApprovedShellCallScope.permits(input: input),
               ApprovedShellCallScope.effectRecheck == nil {
                throw ToolExecutorError.approvalRequired("shell_execute")
            }
        }
        let directory = try shellWorkingDirectory(input)
        // 规则命中、计划模式或自动档免问的调用没有用户当场批准：真正执行前对同一条命令
        // 再过一次效果检查器（路径包含、敏感文件、授权根），防止检查之后路径被换成符号链接。
        if let reason = ApprovedShellCallScope.recheckViolation(input: input, workingDirectory: directory.path) {
            throw ToolExecutorError.shellRejected("原先放行的规则或免问条件已不满足（\(reason)）。请重新发起，由你确认。")
        }
        // 绕过档：命令的操作数命中敏感文件（.env、密钥、凭据）时，没有用户当场批准的调用不执行（审批卡在授权阶段已弹）。
        if BypassOpenScope.isActive, SensitiveFilePolicy.credentialProtectionEnabled,
           !ApprovedShellCallScope.permits(input: input),
           let reason = ShellEffectGuard.sensitiveOperandViolation(command: command, workingDirectory: directory.path) {
            throw ToolExecutorError.shellRejected(reason)
        }
        if try Self.wantsBackground(input) {
            return try await startBackgroundShell(command: command, input: input)
        }
        let budget = ShellCommandTimeoutPolicy.currentBudget ?? ShellCommandBudget(
            seconds: ShellCommandTimeoutPolicy.seconds(input["timeout"], defaultValue: defaultShellTimeout))
        // Approved Composer integers return as native Int64, not Int.
        let requestedDelay: Int?
        if let raw = input["delay"], Swift.type(of: raw) == Int64.self, let integer = raw as? Int64 {
            requestedDelay = Int(exactly: integer)
        } else {
            requestedDelay = input["delay"] as? Int
        }
        let delay = min(600, max(0, requestedDelay ?? 0))
        if delay > 0 {
            try await Task.sleep(for: .seconds(min(TimeInterval(delay), budget.parentRemaining ?? TimeInterval(delay))))
        }
        // Finish the last live authority/workspace await before starting the
        // execution budget. No suspension remains between begin and spawn.
        try await validateChildWorkspace(name: "shell_execute", input: input)
        try Task.checkCancellation()
        let timeout = budget.beginExecution()
        guard timeout > 0 else {
            throw ToolExecutorError.shellTimeout(ShellCommandTimeoutPolicy.timeoutDetail(
                seconds: budget.executionSeconds, stdout: Data(), stderr: Data(), limit: Self.shellOutputLimit))
        }

        let commandStartedAt = Date()
        let shell: SpawnedShell
        do {
            // Foundation's Process exposes no pre-exec process-group hook.
            // Spawn directly so the child enters its private group before zsh
            // can fork a descendant that inherits either output pipe.
            // A child gets a fixed trusted cwd, not a persistent shell state.
            shell = try spawnShell(command: command, currentDirectory: directory)
        } catch {
            throw ToolExecutorError.shellSpawnFailed("启动 /bin/zsh 失败：\(error.localizedDescription)")
        }

        // Drain stdout/stderr CONCURRENTLY with the process. Reading them only
        // after waitUntilExit() deadlocks whenever a command emits more than the
        // OS pipe buffer (64KB on macOS): the child blocks forever on write, the
        // watchdog below then misreports it as a shell timeout. The readers use
        // poll(2), retain at most shellOutputLimit bytes, and have a final
        // drain deadline so a broken child cannot hold this tool indefinitely.
        let shellPID = shell.pid
        let readerLifetime = ShellPipeReaderLifetime()
        // 前台实时输出：只给界面的进度通道（不进工具结果、不起新一轮）；
        // 由调用方通过 ShellLiveOutput.sink 提供，限速限量并先脱敏。
        let liveRelay = ShellLiveOutput.sink.map {
            ShellLiveOutputRelay(sink: $0, knownSecrets: ModelShellEnvironment.knownCredentialValues())
        }
        defer { liveRelay?.finish() }
        let stdoutTask = Self.makePipeReader(shell.stdout, lifetime: readerLifetime,
            onChunk: liveRelay.map { relay in { @Sendable data in relay.feed(data, isStderr: false) } })
        let stderrTask = Self.makePipeReader(shell.stderr, lifetime: readerLifetime,
            onChunk: liveRelay.map { relay in { @Sendable data in relay.feed(data, isStderr: true) } })

        // Keep the watchdog off the cooperative executor. The affected
        // MinisCore suite runs blocking fixtures in parallel; an async
        // 50ms poll can otherwise be delayed until a descendant closes its
        // inherited pipe.
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let watchdog = Task.detached(priority: .userInitiated) {
            while true {
                if Task.isCancelled { return ShellWatchdogResult.cancelled }
                if let status = pollShellExit(shellPID) {
                    return ShellWatchdogResult.exited(status)
                }
                if Date() >= deadline {
                    return ShellWatchdogResult.timedOut
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let watchdogResult = await withTaskCancellationHandler(operation: {
            await watchdog.value
        }, onCancel: {
            // Wake the sole watchdog; cleanup below is joined before return.
            // No detached signal timer may outlive this owned operation.
            watchdog.cancel()
        })

        if Task.isCancelled {
            let deadlineCancellation = budget.remaining <= 0
            // A fresh non-cancelled cleanup task preserves a real TERM grace:
            // sleeping in this cancelled task would throw immediately. Keep
            // the leader unreaped during grace so its PGID cannot be reused.
            await Task.detached(priority: .userInitiated) {
                terminateShell(shellPID, force: false)
                try? await Task.sleep(nanoseconds: UInt64(Self.processTerminationGracePeriod * 1_000_000_000))
                terminateShell(shellPID, force: true)
                _ = await reapShell(shellPID, timeout: Self.processTerminationGracePeriod)
            }.value
            // Readers are detached to keep blocking poll off the cooperative
            // executor, but still honor their own cancellation state so a
            // delayed reader cannot hold cancellation for the full drain grace.
            if deadlineCancellation {
                // A parent deadline may cancel this Task at the command's
                // execution limit. It is still a timeout, not a user cancel;
                // settle the same owned buffers after bounded drain.
                await readerLifetime.beginFinalDrain(gracePeriod: Self.shellDrainGracePeriod)
                let stdoutData = await stdoutTask.value
                let stderrData = await stderrTask.value
                throw shellTimeoutError(seconds: budget.executionSeconds, stdout: stdoutData, stderr: stderrData)
            }
            stdoutTask.cancel()
            stderrTask.cancel()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw CancellationError()
        }
        let timedOut: Bool
        let exitStatus: Int32
        switch watchdogResult {
        case .cancelled:
            // Only cancellation of this operation cancels the watchdog.
            throw CancellationError()
        case .timedOut:
            timedOut = true
            terminateShell(shellPID, force: false)
            _ = await reapShell(shellPID, timeout: Self.processTerminationGracePeriod)
            terminateShell(shellPID, force: true)
            exitStatus = await reapShell(shellPID, timeout: Self.processTerminationGracePeriod) ?? -1
        case .exited(let status):
            timedOut = false
            // The leader is already reaped, but a descendant may still own an
            // inherited pipe. Kill the private group before awaiting EOF.
            terminateShell(shellPID, force: true)
            exitStatus = status
        }

        // The grace period bounds final draining after the child is terminal;
        // it must not discard output while a legitimate command still runs.
        await readerLifetime.beginFinalDrain(gracePeriod: Self.shellDrainGracePeriod)
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        // Lossy decoding: a stray non-UTF-8 byte becomes U+FFFD instead of
        // blanking the whole stream (same decoding the timeout path uses).
        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        let stderrText = String(decoding: stderrData, as: UTF8.self)
        let stdout = ContentSecretRedactor.redact(stdoutText, knownSecrets: ModelShellEnvironment.knownCredentialValues())
        let stderr = ContentSecretRedactor.redact(stderrText, knownSecrets: ModelShellEnvironment.knownCredentialValues())
        let outputComplete = await readerLifetime.outputComplete()

        if timedOut {
            throw shellTimeoutError(seconds: budget.executionSeconds, stdout: stdoutData, stderr: stderrData)
        }
        let generated = CommandGeneratedArtifacts.detect(
            command: command, workingDirectory: directory, startedAt: commandStartedAt)
        if !generated.isEmpty {
            let sessionKey = AgentExecutionContext.current?.currentConversationID ?? fileChangeSessionID
            if !sessionKey.isEmpty { commandGeneratedArtifacts.record(sessionID: sessionKey, paths: generated) }
        }
        return try shellResult(command: command, exitCode: shellExitCode(exitStatus), stdout: stdout, stderr: stderr,
            outputComplete: outputComplete, commandGeneratedFiles: generated)
    }

    /// Preserve timeout as the primary failure even when the secondary log write fails.
    func shellTimeoutError(seconds: TimeInterval, stdout: Data, stderr: Data) -> ToolExecutorError {
        let detail = ShellCommandTimeoutPolicy.timeoutDetail(
            seconds: seconds, stdout: stdout, stderr: stderr, limit: Self.shellOutputLimit)
        let artifactDetail: String
        do {
            let references = try [stdout, stderr].compactMap { data in
                try persistShellOutput(ContentSecretRedactor.redact(String(decoding: data, as: UTF8.self),
                    knownSecrets: ModelShellEnvironment.knownCredentialValues()))?.referenceText
            }
            artifactDetail = references.isEmpty ? "" : "\n已捕获输出（每流最多 \(Self.shellOutputLimit) 字节）：\n" + references.joined(separator: "\n")
        } catch {
            artifactDetail = "\n输出落盘失败：" + ContentSecretRedactor.redact(error.localizedDescription,
                knownSecrets: ModelShellEnvironment.knownCredentialValues())
        }
        return .shellTimeout(detail + artifactDetail)
    }

    /// web_fetch text longer than this is cut inline; the full text is saved to a
    /// session file the model can page through with file_read.
    private static let webFetchInlineCharacters = 40_000

    private func webFetchEnvelope(url: String, content: String) throws -> String {
        var result: [String: Any] = ["url": ContentSecretRedactor.redact(url)]
        let total = content.count
        if total <= Self.webFetchInlineCharacters {
            result["untrustedPageContent"] = content
        } else {
            let limit = Self.webFetchInlineCharacters
            let redacted = ContentSecretRedactor.redact(content,
                knownSecrets: ModelShellEnvironment.knownCredentialValues())
            result["untrustedPageContent"] = String(redacted.prefix(limit))
            result["content_truncated"] = true
            result["total_characters"] = total
            if let artifact = try? persistShellOutput(redacted, threshold: limit) {
                result["full_content_path"] = artifact.fileURL.path
                result["note"] = "页面全文共 \(total) 字符，这里只给出前 \(limit) 字符。全文已保存到 full_content_path，需要后面的内容时用 file_read（offset、lines）分段读取。"
            } else {
                result["note"] = "页面全文共 \(total) 字符，这里只给出前 \(limit) 字符，全文未能保存。需要其余部分时，请改用能指定页面片段的方式（如浏览器工具）。"
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Called only with output that has already passed through the secret redactor.
    private func persistShellOutput(_ redactedOutput: String, threshold: Int = 30_000) throws -> ToolOutputArtifact? {
        guard redactedOutput.count > threshold else { return nil }
        guard let session = ToolOutputArtifactSessionScope.current,
              session.sessionStorageRoot.isFileURL else {
            throw ToolExecutorError.toolNotConfigured("会话输出存储")
        }
        let store = ToolOutputArtifactStore(sessionStorageRoot: session.sessionStorageRoot, sessionID: session.sessionID)
        let proposed = try store.validatedDirectory()
        let directory = try Self.resolveAllowedPath(proposed.path,
            allowedRoot: session.sessionStorageRoot, additionalAllowedRoots: [], deniedRoots: [])
        guard directory.path == proposed.path else { throw ToolExecutorError.pathViolation(proposed.path) }
        return try store.persistIfLarge(redactedOutput: redactedOutput, thresholdCharacters: threshold)
    }

    /// Pure outcome formatting plus authorized output-file persistence; no shell spawn.
    func shellResult(command: String, exitCode: Int32, stdout: String, stderr: String,
        outputComplete: Bool = false, commandGeneratedFiles: [String] = []) throws -> String {
        let stdoutArtifact = try persistShellOutput(stdout)
        let stderrArtifact = try persistShellOutput(stderr)
        var envelope: [String: Any] = [
            "exit_code": Int(exitCode),
            "output_complete": outputComplete,
            "stdout": stdoutArtifact?.preview ?? stdout,
            "stderr": stderrArtifact?.preview ?? stderr,
        ]
        for (key, artifact) in [("stdout_artifact", stdoutArtifact), ("stderr_artifact", stderrArtifact)] {
            if let artifact {
                envelope[key] = ["path": artifact.fileURL.path, "characters": artifact.characterCount,
                                 "utf8_bytes": artifact.byteCount, "capture_scope": "retained_shell_output",
                                 "capture_limit_bytes": Self.shellOutputLimit] as [String: Any]
            }
        }
        if !commandGeneratedFiles.isEmpty {
            envelope["command_generated_files"] = ["status": CommandGeneratedArtifacts.statusLabel,
                                                   "paths": commandGeneratedFiles] as [String: Any]
        }
        let gitFields = GitWorkflowProjection.sessionFields(command: command, exitCode: exitCode, stdout: stdout, stderr: stderr)
        if !gitFields.isEmpty { envelope["git_workflow"] = gitFields }
        let words = TerminalGuard.inspect(command).words
        if words.first == "git" || words.first == "gh" {
            envelope["git_workflow_instructions"] = GitWorkflowPolicy.workflowInstructions
        }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - shell_execute run_in_background / shell_output / shell_stop

    private static func wantsBackground(_ input: [String: Any]) throws -> Bool {
        guard let raw = input["run_in_background"] else { return false }
        if raw is NSNull { return false }
        guard let flag = raw as? Bool else {
            throw ToolExecutorError.invalidParameter("run_in_background")
        }
        return flag
    }

    /// Owner key for background commands: the conversation of the current
    /// dispatch, falling back to the executor's ledger session.
    ///
    /// An empty key is refused: all callers without a conversation would share
    /// one namespace (able to read and stop each other's commands), and the
    /// completion notice is dropped for an empty session id.
    private func backgroundSessionKey() throws -> String {
        let key = AgentExecutionContext.current?.currentConversationID ?? fileChangeSessionID
        guard !key.isEmpty else {
            throw ToolExecutorError.shellRejected("后台命令需要所属会话；当前调用没有会话标识，已拒绝")
        }
        return key
    }

    /// Child tasks and project-task workspaces must not create or read
    /// background commands; child background lifecycle belongs to O-04.
    private func rejectScopedBackgroundUse() throws {
        if ChildToolWorkspaceScope.current.map({ $0.backgroundOrigin != .globalParent }) == true
            || taskFileArtifactBinding != nil
            || AgentExecutionContext.current?.childToolRuntimeBinding != nil
            || AgentExecutionContext.current?.childRuntimeSnapshot != nil {
            AppLogger(category: "ToolExecutor").warning(
                "background_scope_rejected workspace=\(ChildToolWorkspaceScope.current != nil) artifact=\(taskFileArtifactBinding != nil) runtime=\(AgentExecutionContext.current?.childToolRuntimeBinding != nil) snapshot=\(AgentExecutionContext.current?.childRuntimeSnapshot != nil)",
                eventID: "background_scope_rejected"
            )
            throw ToolExecutorError.shellRejected("子任务或项目任务暂不支持后台命令")
        }
    }

    private static func backgroundJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func startBackgroundShell(command: String, input: [String: Any]) async throws -> String {
        if let delay = (input["delay"] as? NSNumber)?.intValue, delay != 0 {
            throw ToolExecutorError.invalidParameter("delay 不能与 run_in_background 同时使用")
        }
        try rejectScopedBackgroundUse()
        let sessionKey = try backgroundSessionKey()
        let directory = try shellWorkingDirectory(input)
        try await validateChildWorkspace(name: "shell_execute", input: input)
        try Task.checkCancellation()
        let timeout = backgroundShells.resolveTimeout(input["timeout"])
        let id: String
        do {
            id = try backgroundShells.reserve(
                command: command, sessionID: sessionKey, timeoutSeconds: timeout,
                knownSecrets: ModelShellEnvironment.knownCredentialValues())
        } catch BackgroundShellError.tooManyRunning(let limit) {
            throw ToolExecutorError.shellRejected(
                "后台命令数量已达上限（\(limit)），请先用 shell_stop 停止一条命令")
        }
        let shell: SpawnedShell
        do {
            shell = try spawnShell(command: command, currentDirectory: directory)
        } catch {
            backgroundShells.abandon(id: id)
            throw ToolExecutorError.shellSpawnFailed("启动 /bin/zsh 失败： \(error.localizedDescription)")
        }
        do {
            guard try backgroundShells.attach(id: id, shell: shell) != nil else {
                throw ToolExecutorError.shellSpawnFailed("后台命令未能登记")
            }
        } catch {
            terminateShell(shell.pid, force: true)
            _ = await reapShell(shell.pid, timeout: Self.processTerminationGracePeriod)
            backgroundShells.abandon(id: id)
            throw error
        }
        // 后台命令结束时也登记命令生成的产物（与前台命令同一判定，同样标"未经写入验证"）。
        let artifactLog = commandGeneratedArtifacts
        let backgroundStartedAt = Date()
        backgroundShells.addFinishHook(id: id) {
            let generated = CommandGeneratedArtifacts.detect(
                command: command, workingDirectory: directory, startedAt: backgroundStartedAt)
            if !generated.isEmpty { artifactLog.record(sessionID: sessionKey, paths: generated) }
        }
        return try Self.backgroundJSON([
            "background": true,
            "task_id": id,
            "status": BackgroundShellState.running.wireName,
            "timeout_seconds": (timeout > 0 ? timeout as Any : NSNull() as Any),
            "max_timeout_seconds": backgroundShells.maximumTimeoutSeconds,
            "note": "命令没有时间上限，会一直运行到自己结束、被 shell_stop 停止，或应用退出（退出时会终止命令）。用 shell_output 读取输出与状态。",
        ])
    }

    private func runShellOutput(_ input: [String: Any]) throws -> String {
        try rejectScopedBackgroundUse()
        guard let id = input["task_id"] as? String, !id.isEmpty else {
            throw ToolExecutorError.missingParameter("task_id")
        }
        let offset: Int
        if let raw = input["offset"] {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw ToolExecutorError.invalidParameter("offset（应为非负整数）")
            }
            offset = number.intValue
        } else { offset = 0 }
        let sessionKey = try backgroundSessionKey()
        guard let output = backgroundShells.readOutput(
            id: id, sessionID: sessionKey, offset: offset) else {
            throw ToolExecutorError.invalidParameter("task_id")
        }
        return try Self.backgroundJSON(Self.envelope(for: output.snapshot, extra: [
            "stdout": output.stdout,
            "stderr": output.stderr,
            "stdout_dropped_bytes": output.stdoutDroppedBytes,
            "stderr_dropped_bytes": output.stderrDroppedBytes,
            "more_available": output.moreAvailable,
            "next_offset": output.nextOffset,
            "output_path": output.outputPath as Any? ?? NSNull(),
            "read_error": output.readError as Any? ?? NSNull(),
        ]))
    }

    private func runShellStop(_ input: [String: Any]) async throws -> String {
        try rejectScopedBackgroundUse()
        guard let id = input["task_id"] as? String, !id.isEmpty else {
            throw ToolExecutorError.missingParameter("task_id")
        }
        let session = try backgroundSessionKey()
        guard backgroundShells.snapshot(id: id, sessionID: session) != nil else {
            throw ToolExecutorError.invalidParameter("task_id")
        }
        let requested = backgroundShells.stop(id: id, reason: .model, sessionID: session)
        if requested { await backgroundShells.waitUntilFinished(ids: [id], waitSeconds: 2) }
        guard let snapshot = backgroundShells.snapshot(id: id, sessionID: session) else {
            throw ToolExecutorError.invalidParameter("task_id")
        }
        return try Self.backgroundJSON(Self.envelope(for: snapshot, extra: ["stop_requested": requested]))
    }

    private static func envelope(for snapshot: BackgroundShellSnapshot, extra: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "task_id": snapshot.id,
            "status": snapshot.state.wireName,
            "elapsed_seconds": Int(snapshot.elapsed()),
            "timeout_seconds": (snapshot.timeoutSeconds > 0 ? snapshot.timeoutSeconds as Any : NSNull() as Any),
        ]
        if let code = snapshot.exitCode { object["exit_code"] = Int(code) } else { object["exit_code"] = NSNull() }
        if let note = snapshot.endNote { object["note"] = note }
        for (key, value) in extra { object[key] = value }
        return object
    }

    func spawnShell(command: String, currentDirectory: URL) throws -> SpawnedShell {
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        var stderrPipe = [Int32](repeating: 0, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            if stdoutPipe[0] > 0 { close(stdoutPipe[0]); close(stdoutPipe[1]) }
            throw POSIXSpawnError(errno: errno)
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let actionResult = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[1]),
        ].first { $0 != 0 }
        guard actionResult == nil else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: actionResult ?? EINVAL)
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Spawned tools must not inherit a Swift/Dispatch worker thread's
        // blocked signals or the host's ignored termination dispositions.
        // Configure only the child attributes; never change the caller mask.
        var childSignalMask = sigset_t()
        guard sigemptyset(&childSignalMask) == 0 else {
            let failure = errno
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: failure)
        }
        var childSignalDefaults = sigset_t()
        guard sigemptyset(&childSignalDefaults) == 0 else {
            let failure = errno
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: failure)
        }
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] {
            guard sigaddset(&childSignalDefaults, signal) == 0 else {
                let failure = errno
                close(stdoutPipe[0]); close(stdoutPipe[1])
                close(stderrPipe[0]); close(stderrPipe[1])
                throw POSIXSpawnError(errno: failure)
            }
        }
        let maskResult = posix_spawnattr_setsigmask(&attributes, &childSignalMask)
        let defaultsResult = posix_spawnattr_setsigdefault(&attributes, &childSignalDefaults)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        let flagsResult = posix_spawnattr_setflags(&attributes, flags)
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        if let failure = [maskResult, defaultsResult, flagsResult, groupResult].first(where: { $0 != 0 }) {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: failure)
        }

        let chdirResult = currentDirectory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        guard chdirResult == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: chdirResult)
        }

        var pid: pid_t = 0
        let spawnResult: Int32 = "/bin/zsh".withCString { executable in
            "-c".withCString { flag in
                command.withCString { commandCString in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executable),
                        UnsafeMutablePointer(mutating: flag),
                        UnsafeMutablePointer(mutating: commandCString),
                        nil,
                    ]
                    return argv.withUnsafeMutableBufferPointer { buffer in
                        ModelShellEnvironment.withCStringVector { environment in
                            posix_spawn(
                                &pid,
                                executable,
                                &actions,
                                &attributes,
                                buffer.baseAddress,
                                environment
                            )
                        }
                    }
                }
            }
        }
        guard spawnResult == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            throw POSIXSpawnError(errno: spawnResult)
        }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        return SpawnedShell(
            pid: pid,
            stdout: FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        )
    }

    // MARK: - file_read / file_write

    /// P3-OUTPUT-01（DEV-286）：写成功后的 best-effort 台账登记。返回带
    /// `diffID` 的结果串后缀；台账未注入、会话未接线、路径越界（如外部
    /// 挂载根）或登记失败时，普通调用保持原语义；child 产物登记失败
    /// 明确说明原因，不能把已经落盘的写入报成失败。
    private func registerFileChange(
        rawPath: String,
        kind: FileChangeRecord.Kind,
        oldContent: String,
        newContent: String,
        verifiedOutputContent: String?,
        verifiedDeletedContentSHA256: String? = nil
    ) async throws -> String {
        let registration = mutableState.withLock {
            (ledger: $0.fileChangeLedger,
             sessionID: $0.fileChangeSessionID,
             binding: $0.taskFileArtifactBinding)
        }
        guard let ledger = registration.ledger else {
            if AgentExecutionContext.current?.taskArtifactProject != nil {
                return " 文件已写入，但未登记为任务产物（原因：文件变更台账不可用）。"
            }
            return " 文件已写入，但文件变更台账不可用。"
        }
        let receipt = ToolExecutionReceiptContext.current
        // The minted receipt wins over mutable UI session selection. A switch
        // during execution must not attribute the write to the new session.
        let sessionID = receipt?.compositeKey?.sessionID ?? registration.sessionID
        guard !sessionID.isEmpty else { return " 文件已写入，但缺少所属会话，未登记文件变更台账。" }
        let boundReceipt = receipt?.compositeKey?.sessionID == sessionID
            ? receipt : nil
        let artifactBinding: TaskFileArtifactBinding?
        let artifactOmissionReason: String?
        if let context = AgentExecutionContext.current, let project = context.taskArtifactProject {
            do {
                guard let boundReceipt else { throw ToolExecutionFactLedgerError.receiptIdentityMismatch }
                try await validateChildTaskArtifactProject(tool: boundReceipt.toolName)
                let captured = try Self.captureChildTaskArtifactBinding(context: context, receipt: boundReceipt)
                // A confirmed bypass can still write outside its cwd. Such a file
                // does not borrow this project's native grant for a preview.
                let physical = PolicyRuntimePathBoundary.canonicalPath(rawPath)
                let belongsToProject = physical.map {
                    PolicyRuntimePathBoundary.isWithinRoots(path: $0, roots: [project.workingDirectory])
                        && ledger.recordingRoot(for: rawPath) != nil
                } == true
                artifactBinding = belongsToProject ? captured : nil
                artifactOmissionReason = belongsToProject ? nil : "目标不在当前原生项目或现有台账登记范围"
                if belongsToProject, let verifiedOutputContent {
                    let url = try resolveAllowedPath(rawPath)
                    let actual = try readFileDataOrDenial(at: url, path: rawPath)
                    guard Self.sha256(actual) == Self.sha256(Data(verifiedOutputContent.utf8)) else {
                        throw ToolExecutorError.writeFailed("写后文件内容已变化")
                    }
                }
            } catch ToolExecutorError.writeFailed(let reason) {
                return " 文件已写入，但未登记为任务产物（原因：\(reason)）。"
            } catch is ToolExecutionFactLedgerError {
                return " 文件已写入，但未登记为任务产物（原因：子任务身份或任务轮次已失效）。"
            } catch {
                return " 文件已写入，但未登记为任务产物（原因：写后文件内容无法读取或核对）。"
            }
        } else {
            artifactBinding = registration.binding
            artifactOmissionReason = nil
        }
        do {
            let record = try ledger.register(
                sessionID: sessionID,
                path: rawPath,
                kind: kind,
                oldContent: oldContent,
                newContent: newContent,
                producerReceipt: boundReceipt,
                verifiedOutputContent: boundReceipt == nil ? nil : verifiedOutputContent,
                verifiedDeletedContentSHA256: verifiedDeletedContentSHA256,
                taskArtifactBinding: artifactBinding
            )
            let suffix = " [diffID:\(record.diffID)]"
            if let artifactOmissionReason {
                return suffix + " 文件已写入，但未登记为任务产物（原因：\(artifactOmissionReason)）。"
            }
            return suffix
        } catch {
            if AgentExecutionContext.current?.taskArtifactProject != nil {
                let reason = artifactOmissionReason ?? "文件变更台账登记失败"
                return " 文件已写入，但未登记为任务产物（原因：\(reason)）。"
            }
            return " 文件已写入，但文件变更台账登记失败：\(ContentSecretRedactor.redact(error.localizedDescription, knownSecrets: ModelShellEnvironment.knownCredentialValues()))"
        }
    }

    /// 写入口的 pre-write 正文捕获（尽力而为，仅作差异素材）：文件不存在、
    /// 读取失败、二进制或非 UTF-8 一律按「无先前内容」处理，绝不影响
    /// 工具本身的错误路径。
    private func captureTextContentIfPresent(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads raw bytes for a file tool and maps a filesystem permission refusal
    /// to an explicit `ToolExecutorError.permissionDenied` decision, so
    /// PRIVACY-05's "无权限路径被明确拒绝" clause is a first-class outcome rather
    /// than a raw Foundation/POSIX string escaping the tool boundary. Every
    /// non-permission failure is re-thrown unchanged: strictly stronger.
    private func readFileDataOrDenial(at url: URL, path: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            if Self.isPermissionRefusal(error) {
                throw ToolExecutorError.permissionDenied(path)
            }
            throw error
        }
    }

    /// True when `error` is, or wraps at a bounded depth, a permission refusal.
    /// Foundation surfaces an unreadable file as an `NSCocoaErrorDomain`
    /// no-permission file-read failure (257 = `NSFileReadNoPermissionError`)
    /// carrying the `NSPOSIXErrorDomain` EACCES/EPERM under
    /// `NSUnderlyingErrorKey`, and an unwritable target as the sibling
    /// no-permission file-write failure (513 = `NSFileWriteNoPermissionError`)
    /// with the same POSIX wrapper shape; an unwrapped `NSPOSIXErrorDomain`
    /// EACCES/EPERM also reaches us directly (e.g. `FileHandle.write`).
    /// All shapes are recognised. The unwrap mirrors the existing
    /// underlying-error walk in `ProviderCancellationPolicy`.
    private static func isPermissionRefusal(_ error: Error, depth: Int = 0) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return true
        }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == CocoaError.Code.fileReadNoPermission.rawValue
             || ns.code == CocoaError.Code.fileWriteNoPermission.rawValue {
            return true
        }
        guard depth < 4, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isPermissionRefusal(underlying, depth: depth + 1)
    }

    /// Exact owned-read candidate after caller/child hard denials. Default
    /// private-state protection may be narrowed only for a produced receipt;
    /// provenance absent from an older child scope remains fully denying.
    public func resolveOwnedOutputArtifactRead(path: String) throws -> URL? {
        let scopedDenials = ChildToolWorkspaceScope.current.map {
            $0.explicitDeniedRoots ?? $0.deniedRoots
        } ?? []
        for root in scopedDenials {
            guard let physicalRoot = PolicyRuntimePathBoundary.canonicalPath(root),
                  let candidate = PolicyRuntimePathBoundary.canonicalPath(path) else {
                throw ToolExecutorError.pathViolation(path)
            }
            if PolicyRuntimePathBoundary.foldedCandidate(path, isWithin: physicalRoot)
                || PolicyRuntimePathBoundary.foldedCandidate(candidate, isWithin: physicalRoot) {
                throw ToolExecutorError.pathViolation(path)
            }
        }
        guard let artifact = try ToolOutputArtifactStore.resolveOwnedArtifact(path: path) else { return nil }
        for root in explicitDeniedRoots.map(\.path) {
            guard let physicalRoot = PolicyRuntimePathBoundary.canonicalPath(root),
                  let candidate = PolicyRuntimePathBoundary.canonicalPath(path) else {
                throw ToolExecutorError.pathViolation(path)
            }
            if PolicyRuntimePathBoundary.foldedCandidate(path, isWithin: physicalRoot)
                || PolicyRuntimePathBoundary.foldedCandidate(candidate, isWithin: physicalRoot) {
                throw ToolExecutorError.pathViolation(path)
            }
        }
        return artifact
    }

    private static func fileReadInteger(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 {
            return Int(exactly: value)
        }
        return nil
    }

    /// Files up to this size are read into memory; larger text files are read in
    /// blocks (head) or from the end (tail) so a log file never fills memory.
    private static let fileReadInMemoryLimit = 8 * 1024 * 1024
    private static let fileReadTailWindowBytes = 4 * 1024 * 1024
    private static let fileReadHeadScanLimit = 512 * 1024 * 1024
    private static let fileReadDefaultMaxLength = 30_000

    /// 读取记录用的会话键；会话未接线（空串）时不记录、也不强制“先读再改”。
    private var fileReadRecordSessionID: String? {
        // 优先用本次调用自己的会话（执行上下文里的会话）：执行器上的会话键是界面当前打开的会话，
        // 后台会话的回合会读错键。预检与锁内复核、读与写都走这一个来源；
        // 没有执行上下文时退回执行器自己的会话键；未接线（空串）不强制“先读再改”。
        if let own = AgentExecutionContext.current?.currentConversationID, !own.isEmpty { return own }
        let own = fileChangeSessionID
        return own.isEmpty ? nil : own
    }

    /// 登记“本会话已读过此文件的当前版本”。file_read 成功后自动调用；
    /// 用户随消息附上的文件、@ 引用的文件也由 App 经此登记为已读。
    public func markFileRead(path: String, sessionID: String? = nil) {
        // 只做登记（不读出、不返回内容）；调用方是已通过授权的 file_read，
        // 或用户自己附上/@ 引用的文件。写入时仍要过完整的路径与审批检查。
        guard let session = sessionID.flatMap({ $0.isEmpty ? nil : $0 }) ?? fileReadRecordSessionID else { return }
        let physical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        // 可能在主线程上调用：只同步记大小和修改时间，内容摘要放后台补算。
        FileReadRecordStore.shared.recordReadDeferringDigest(sessionID: session, path: physical)
    }

    /// 先读再改：读取之后文件被外部改动则拒绝并提示重读；从未读过的文件放行编辑，
    /// 但整体覆盖已有的非空文件必须先读。审批预检之前和执行锁内各调用一次。
    private func verifyReadBeforeMutation(name: String, physical: String, input: [String: Any]) throws {
        guard name == "file_write" || name == "file_edit", let session = fileReadRecordSessionID else { return }
        var info = stat()
        guard stat(physical, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
        switch FileReadRecordStore.shared.status(sessionID: session, path: physical) {
        case .current:
            return
        case .modifiedSinceRead:
            throw ToolExecutorError.writeFailed("文件在你读取之后被改动过（可能是用户或其他任务）：\(physical)。本次未修改；请先用 file_read 重新读取，再据最新内容修改。")
        case .neverRead:
            guard name == "file_write", (input["append"] as? Bool) != true, info.st_size > 0 else { return }
            throw ToolExecutorError.writeFailed("覆盖已有文件前请先用 file_read 读取它：\(physical)。本次未修改；用户随消息附上或 @ 引用的文件视为已读。")
        }
    }

    private func runFileRead(_ rawInput: [String: Any]) throws -> String {
        // 可选参数显式传 null（ChatGPT 等模型常把未用的可选项填成 null）等同于没传；
        // 否则文本文件会因 page_start/page_count 为 null 被当成“仅适用于 PDF”而反复失败（用户 11/20 会话 893B52D5）。
        let input = rawInput.filter { !($0.value is NSNull) }
        let result = try performFileRead(input)
        if let path = input["path"] as? String, !path.isEmpty { markFileRead(path: path) }
        return result
    }

    private func performFileRead(_ input: [String: Any]) throws -> String {
        guard let path = input["path"] as? String, !path.isEmpty else {
            throw ToolExecutorError.missingParameter("path")
        }
        let ownedData: Data?
        do {
            _ = try resolveOwnedOutputArtifactRead(path: path)
            ownedData = try ToolOutputArtifactStore.readOwnedArtifact(path: path)
        } catch {
            if Self.isPermissionRefusal(error) { throw ToolExecutorError.permissionDenied(path) }
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                || failure.code == CocoaError.Code.fileNoSuchFile.rawValue {
                throw ToolExecutorError.fileNotFound(path)
            }
            throw error
        }
        let offset = max(1, Self.fileReadInteger(input["offset"]) ?? 1)
        let maxLines = Self.fileReadInteger(input["lines"]).map { max(1, $0) }
        let maxLength = max(1, Self.fileReadInteger(input["max_length"]) ?? Self.fileReadDefaultMaxLength)
        let direction = (input["direction"] as? String) ?? "head"

        let url: URL
        let data: Data
        if let ownedData {
            url = URL(fileURLWithPath: path)
            data = ownedData
        } else {
            url = try resolveReadablePath(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolExecutorError.fileNotFound(path)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.fileReadInMemoryLimit {
                let head = try readFileHead(at: url, path: path, count: 8192)
                if !FileImporter.isPDF(data: head, pathExtension: url.pathExtension) {
                    if input["page_start"] != nil || input["page_count"] != nil {
                        throw ToolExecutorError.invalidParameter("page_start/page_count 仅适用于 PDF 文件")
                    }
                    return try readLargeTextFile(url: url, path: path, size: size, head: head,
                        offset: offset, maxLines: maxLines, maxLength: maxLength, direction: direction)
                }
                // 大 PDF 不设字节上限：file_read 按 page_start/page_count 分页读，输出由 max_length 限长（对齐 Claude Code 大 PDF 分页读）。
            }
            data = try readFileDataOrDenial(at: url, path: path)
        }
        if ownedData == nil, FileImporter.isPDF(data: data, pathExtension: url.pathExtension) {
            if (input["as_images"] as? Bool) == true {
                return try FileImporter.readPDFAsImages(data: data, input: input)
            }
            return try FileImporter.readPDF(data: data, input: input)
        }
        if (input["as_images"] as? Bool) == true {
            throw ToolExecutorError.invalidParameter("as_images 仅适用于 PDF 文件；图片文件会直接提供给模型")
        }
        if input["page_start"] != nil || input["page_count"] != nil {
            throw ToolExecutorError.invalidParameter("page_start/page_count 仅适用于 PDF 文件")
        }
        // BOM-marked UTF-16 is text even though it is full of NUL bytes: decode it before the binary check.
        let utf16Text = ReadOnlyFileSearch.decodeUTF16WithBOM(data)
        // Reject binary files (NUL byte heuristic); images get an explanation.
        if utf16Text == nil,
           data.contains(0) || { if let kind = Self.imageKind(head: data.prefix(16)) { return kind != "bmp" }; return false }() {
            if let image = Self.describeImage(head: data.prefix(16), url: url, byteCount: data.count, data: data) {
                return image
            }
            throw ToolExecutorError.fileIsBinary(path)
        }
        // BOM UTF-16 first, then UTF-8, then GB18030 (covers GBK/GB2312) for legacy Chinese files.
        guard let decoded = utf16Text ?? ReadOnlyFileSearch.decodeText(data) else {
            throw ToolExecutorError.readFailed("File is not valid UTF-8 text: \(path)")
        }
        let text = ownedData == nil ? decoded : ContentSecretRedactor.redact(decoded,
            knownSecrets: ModelShellEnvironment.knownCredentialValues())
        return Self.renderFileRead(text: text, offset: offset, maxLines: maxLines, maxLength: maxLength,
            direction: direction, windowStartLine: nil, totalLines: nil, textIsComplete: true, scanNote: nil)
    }

    private func readFileHead(at url: URL, path: String, count: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            if Self.isPermissionRefusal(error) { throw ToolExecutorError.permissionDenied(path) }
            throw error
        }
    }

    /// Block-wise read of a text file too large for memory. A head read scans
    /// forward to `offset` and stops once the requested window is full; a tail
    /// read decodes only the last few MiB.
    private func readLargeTextFile(url: URL, path: String, size: Int, head: Data,
                                   offset: Int, maxLines: Int?, maxLength: Int,
                                   direction: String) throws -> String {
        let utf16 = Self.largeFileUTF16Layout(head: head)
        if utf16 == nil, head.contains(0) {
            let imageData = size <= Self.fileReadImageMaxBytes ? try? Data(contentsOf: url) : nil
            if let image = Self.describeImage(head: head.prefix(16), url: url, byteCount: size, data: imageData) { return image }
            throw ToolExecutorError.fileIsBinary(path)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            if Self.isPermissionRefusal(error) { throw ToolExecutorError.permissionDenied(path) }
            throw error
        }
        defer { try? handle.close() }
        let sizeNote = "file is \(size) bytes"
        if direction == "tail" {
            var window = min(size, Self.fileReadTailWindowBytes)
            var data: Data
            if let utf16 {
                // UTF-16：窗口起止对齐到 2 字节，截掉被切开的代理对，再转成 UTF-8 走同一套按行处理。
                let end = size & ~1
                window = min(end - utf16.bomLength, Self.fileReadTailWindowBytes) & ~1
                try handle.seek(toOffset: UInt64(end - window))
                let raw = try handle.read(upToCount: window) ?? Data()
                var carry = Data()
                var units = Data(raw)
                if units.count >= 2 {
                    let first = utf16.bigEndian ? UInt16(units[units.startIndex]) << 8 | UInt16(units[units.startIndex + 1])
                        : UInt16(units[units.startIndex + 1]) << 8 | UInt16(units[units.startIndex])
                    if (0xDC00...0xDFFF).contains(first) { units = Data(units.dropFirst(2)) }
                }
                guard let converted = Self.utf16BlockToUTF8(units, bigEndian: utf16.bigEndian, carry: &carry) else {
                    throw ToolExecutorError.readFailed("File is not valid UTF-16 text: \(path)")
                }
                data = converted
            } else {
                try handle.seek(toOffset: UInt64(size - window))
                data = try handle.read(upToCount: window) ?? Data()
            }
            let startsMidFile = size - window > (utf16.map { $0.bomLength + (size & 1) } ?? 0)
            if startsMidFile, let newline = data.firstIndex(of: 10) {
                data = Data(data[(newline + 1)...]) // drop the partial first line
            }
            guard !data.contains(0), let text = ReadOnlyFileSearch.decodeText(data) else {
                throw ToolExecutorError.readFailed("File is not valid UTF-8 text: \(path)")
            }
            return Self.renderFileRead(text: text, offset: 1, maxLines: maxLines, maxLength: maxLength,
                direction: "tail", windowStartLine: nil, totalLines: nil, textIsComplete: false,
                scanNote: "\(sizeNote); only the last \(window) bytes were read, line numbers are unknown")
        }
        let collectCap = maxLength * 4 + 4096
        let lastWanted = maxLines.map { offset + $0 - 1 }
        var lineNumber = 1
        var collected = Data()
        var pending = Data()
        var scanned = 0
        var windowFilled = false
        var reachedEnd = false
        var utf16Carry = Data()
        if let utf16 { try handle.seek(toOffset: UInt64(utf16.bomLength)) }
        // UTF-16 按 4 MiB 块读取并转成 UTF-8（块边界的半个代理对留到下一块），之后与 UTF-8 文件同一套按行扫描。
        func nextBlock() throws -> Data? {
            guard let raw = try handle.read(upToCount: 4 * 1024 * 1024), !raw.isEmpty else { return nil }
            guard let utf16 else { return raw }
            guard let converted = Self.utf16BlockToUTF8(raw, bigEndian: utf16.bigEndian, carry: &utf16Carry) else {
                throw ToolExecutorError.readFailed("File is not valid UTF-16 text: \(path)")
            }
            return converted
        }
        scan: while scanned < Self.fileReadHeadScanLimit {
            guard let block = try nextBlock(), !block.isEmpty else {
                reachedEnd = true
                break
            }
            scanned += block.count
            var lineStart = block.startIndex
            while let newline = block[lineStart...].firstIndex(of: 10) {
                var line = pending
                pending.removeAll(keepingCapacity: true)
                line.append(block[lineStart..<newline])
                if lineNumber >= offset {
                    collected.append(line)
                    collected.append(10)
                }
                lineNumber += 1
                lineStart = newline + 1
                if let lastWanted, lineNumber > lastWanted { windowFilled = true; break scan }
                if collected.count > collectCap { windowFilled = true; break scan }
            }
            pending.append(block[lineStart...])
            if pending.count > 64 * 1024 * 1024 {
                throw ToolExecutorError.readFailed("File has a line longer than 64 MiB: \(path)")
            }
        }
        var totalLines: Int?
        if reachedEnd {
            if !pending.isEmpty {
                if lineNumber >= offset { collected.append(pending) }
                lineNumber += 1
            }
            totalLines = lineNumber - 1
        } else if !windowFilled {
            throw ToolExecutorError.readFailed("offset is too far into a \(size)-byte file; read with direction=tail or use file_grep")
        }
        if let totalLines, offset > totalLines {
            return "（offset \(offset) is past the end: the file has \(totalLines) line(s)）"
        }
        if windowFilled, collected.last == 10 { collected.removeLast() }
        guard !collected.contains(0), let text = ReadOnlyFileSearch.decodeText(collected) else {
            throw ToolExecutorError.readFailed("File is not valid UTF-8 text: \(path)")
        }
        return Self.renderFileRead(text: text, offset: offset, maxLines: maxLines, maxLength: maxLength,
            direction: "head", windowStartLine: offset, totalLines: totalLines, textIsComplete: false,
            scanNote: nil)
    }

    /// 超大文件的 UTF-16 判定：先认 BOM（FF FE / FE FF，纯中文也没有 NUL，所以不能靠 NUL）；
    /// 无 BOM 时只认“全部 NUL 都落在同一奇偶位上且占比不低”的头部（ASCII 为主的 UTF-16）。
    struct LargeFileUTF16Layout: Equatable {
        let bigEndian: Bool
        let bomLength: Int
    }

    static func largeFileUTF16Layout(head: Data) -> LargeFileUTF16Layout? {
        let bytes = [UInt8](head.prefix(8192))
        if bytes.count >= 2 {
            if bytes[0] == 0xFF, bytes[1] == 0xFE { return LargeFileUTF16Layout(bigEndian: false, bomLength: 2) }
            if bytes[0] == 0xFE, bytes[1] == 0xFF { return LargeFileUTF16Layout(bigEndian: true, bomLength: 2) }
        }
        let pairs = bytes.count / 2
        guard pairs >= 16 else { return nil }
        var evenNULs = 0
        var oddNULs = 0
        for index in 0..<(pairs * 2) where bytes[index] == 0 {
            if index % 2 == 0 { evenNULs += 1 } else { oddNULs += 1 }
        }
        if evenNULs == 0, oddNULs * 4 >= pairs { return LargeFileUTF16Layout(bigEndian: false, bomLength: 0) }
        if oddNULs == 0, evenNULs * 4 >= pairs { return LargeFileUTF16Layout(bigEndian: true, bomLength: 0) }
        // 无 BOM 的纯中文 UTF-16 几乎没有 NUL：头部不是合法 UTF-8（允许末尾被截断的半个字符）时，
        // 按小端、大端各试解，可读字符占比 ≥ 0.9 且明显高于另一种字节序才认。否则维持原行为（二进制或非 UTF-8 报错）。
        let evenBytes = Array(bytes.prefix(pairs * 2))
        guard !(0...3).contains(where: { String(data: Data(evenBytes.dropLast($0)), encoding: .utf8) != nil }) else {
            return nil
        }
        let little = plausibleUTF16Ratio(evenBytes, bigEndian: false)
        let big = plausibleUTF16Ratio(evenBytes, bigEndian: true)
        if little >= 0.9, little - big >= 0.2 { return LargeFileUTF16Layout(bigEndian: false, bomLength: 0) }
        if big >= 0.9, big - little >= 0.2 { return LargeFileUTF16Layout(bigEndian: true, bomLength: 0) }
        return nil
    }

    /// 按给定字节序把字节当 UTF-16 看，返回“常见可读字符”（ASCII 可打印与换行制表、拉丁、希腊西里尔、常用标点、
    /// 日文假名、汉字、谚文、全角形式、成对代理项）占全部码元的比例。
    private static func plausibleUTF16Ratio(_ bytes: [UInt8], bigEndian: Bool) -> Double {
        let count = bytes.count / 2
        guard count > 0 else { return 0 }
        func unit(_ index: Int) -> UInt16 {
            let first = UInt16(bytes[index * 2]), second = UInt16(bytes[index * 2 + 1])
            return bigEndian ? first << 8 | second : second << 8 | first
        }
        var plausible = 0
        var index = 0
        while index < count {
            let value = unit(index)
            switch value {
            case 0x20...0x7E, 0x09, 0x0A, 0x0D, 0xA0...0x24F, 0x370...0x52F, 0x2000...0x206F,
                 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xFF00...0xFFEF:
                plausible += 1
            case 0xD800...0xDBFF:
                if index + 1 < count, (0xDC00...0xDFFF).contains(unit(index + 1)) {
                    plausible += 2
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return Double(plausible) / Double(count)
    }

    /// 把一块 UTF-16 字节转成 UTF-8。奇数的尾字节和被切开的高代理项放进 `carry`，下一块开头接上，
    /// 保证块边界不会切坏字符。解码失败返回 nil。
    static func utf16BlockToUTF8(_ block: Data, bigEndian: Bool, carry: inout Data) -> Data? {
        var combined = carry
        combined.append(block)
        carry = Data()
        var usable = combined.count & ~1
        if usable < combined.count { carry = Data(combined[(combined.startIndex + usable)...]) }
        if usable >= 2 {
            let hi = combined[combined.startIndex + usable - 2]
            let lo = combined[combined.startIndex + usable - 1]
            let last = bigEndian ? UInt16(hi) << 8 | UInt16(lo) : UInt16(lo) << 8 | UInt16(hi)
            if (0xD800...0xDBFF).contains(last) {
                carry = Data(combined[(combined.startIndex + usable - 2)..<(combined.startIndex + usable)]) + carry
                usable -= 2
            }
        }
        guard usable > 0 else { return Data() }
        let units = Data(combined[combined.startIndex..<(combined.startIndex + usable)])
        guard let text = String(data: units, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian) else { return nil }
        return Data(text.utf8)
    }

    /// Window, bound and annotate file text. `windowStartLine` is set when `text`
    /// is already the requested window (block-wise reads). Every truncation says
    /// where to continue.
    private static func renderFileRead(text: String, offset: Int, maxLines: Int?, maxLength: Int,
                                       direction: String, windowStartLine: Int?, totalLines: Int?,
                                       textIsComplete: Bool, scanNote: String?) -> String {
        // NSString splitting handles "\r\n" (one Character in Swift) as well as "\n".
        let allLines = text.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var contentLines = allLines
        if contentLines.count > 1, contentLines.last == "" { contentLines.removeLast() }
        var total = totalLines
        if windowStartLine == nil, textIsComplete { total = text.isEmpty ? 0 : contentLines.count }

        let isTail = direction == "tail"
        let selected: ArraySlice<String>
        var startLine = 1
        if let windowStartLine {
            selected = contentLines[...]
            startLine = windowStartLine
        } else if isTail {
            selected = contentLines.suffix(maxLines ?? contentLines.count)
            startLine = contentLines.count - selected.count + 1
        } else {
            if let total, !text.isEmpty, offset > total {
                return "（offset \(offset) is past the end: the file has \(total) line(s)）"
            }
            selected = contentLines.dropFirst(offset - 1).prefix(maxLines ?? Int.max)
            startLine = offset
        }
        // 行号按 Claude Code 的 cat -n 格式（右对齐 6 位 + 制表符）加在每行前面；
        // max_length 只计正文字符，不含行号前缀。尾部只读了一段（行号未知）时不加行号。
        let numberLines = !text.isEmpty && !(isTail && !textIsComplete)
        func numbered(_ body: String, firstLine: Int) -> String {
            guard numberLines else { return body }
            var number = firstLine - 1
            return body.components(separatedBy: "\n").map { line -> String in
                number += 1
                let digits = String(number)
                return String(repeating: " ", count: max(0, 6 - digits.count)) + digits + "\t" + line
            }.joined(separator: "\n")
        }
        var out = selected.joined(separator: "\n")
        let totalText = total.map { " of \($0)" } ?? ""
        if out.count > maxLength {
            if isTail {
                let kept = String(out.suffix(maxLength))
                let lastLine = startLine + selected.count - 1
                let keptCount = kept.components(separatedBy: "\n").count
                out = numbered(kept, firstLine: lastLine - keptCount + 1)
                out += "\n…[truncated at \(maxLength) chars; showing the end of the file\(textIsComplete ? " (\(total ?? 0) lines)" : ""); use offset and lines to read earlier text]"
            } else {
                let kept = String(out.prefix(maxLength))
                if let lastNewline = kept.lastIndex(of: "\n") {
                    let whole = String(kept[..<lastNewline])
                    let end = startLine + whole.components(separatedBy: "\n").count - 1
                    out = numbered(whole, firstLine: startLine) + "\n…[truncated at \(maxLength) chars; showing lines \(startLine)-\(end)\(totalText); continue with offset=\(end + 1)]"
                } else {
                    out = numbered(kept, firstLine: startLine) + "\n…[truncated at \(maxLength) chars; line \(startLine) is longer than max_length, raise max_length to read more]"
                }
            }
        } else {
            out = numbered(out, firstLine: startLine)
        }
        if let scanNote { out += "\n[\(scanNote)]" }
        return out
    }

    /// Plain-text explanation for an image file: file_read returns text, so the
    /// model is told what the file is instead of receiving an error.
    /// 读图片文件时最多整文件读入内存的字节数；更大的图片只给文字说明。
    private static let fileReadImageMaxBytes = 25 * 1024 * 1024

    private static func imageKind(head: Data) -> String? {
        let bytes = [UInt8](head.prefix(16))
        func starts(_ prefix: [UInt8], at index: Int = 0) -> Bool {
            bytes.count >= index + prefix.count && Array(bytes[index..<(index + prefix.count)]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "webp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts(Array("ftyp".utf8), at: 4),
           ["heic", "heix", "mif1", "avif"].contains(String(decoding: bytes[min(8, bytes.count)..<min(12, bytes.count)], as: UTF8.self)) {
            return "heic/avif"
        }
        if starts([0x42, 0x4D]) { return "bmp" }
        return nil
    }

    /// 图片文件的文字说明；传入 `data` 时同时把图片经旁路交给模型（由 AgentLoop 按模型能力决定是否真正发送）。
    private static func describeImage(head: Data, url: URL, byteCount: Int, data: Data? = nil) -> String? {
        guard let kind = imageKind(head: head) else { return nil }
        var dimensions = ""
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            dimensions = "，\(width)×\(height)"
        }
        let description = "这是图片文件（\(kind)\(dimensions)，\(byteCount) 字节）。"
        let mimeByKind = ["png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                          "tiff": "image/tiff", "heic/avif": "image/heic", "bmp": "image/bmp"]
        if let data, let mime = mimeByKind[kind],
           let marker = ToolResultImageChannel.attach(data: data, mimeType: mime) {
            return description + "图片本身随本次结果一并提供。\n" + marker
        }
        return description + "这张图片无法交给模型（文件过大或无法解码），file_read 只能给出以上信息；需要看图时，请让用户把它作为附件发送。"
    }

    private func runFileWrite(_ input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String, !path.isEmpty else {
            throw ToolExecutorError.missingParameter("path")
        }
        guard let content = input["content"] as? String else {
            throw ToolExecutorError.missingParameter("content")
        }
        let receipt = ToolExecutionReceiptContext.current
        let factLedger = ToolExecutionReceiptContext.ledger
        if let receipt, let factLedger {
            try factLedger.prepareFileWrite(receipt)
        }
        let url = try resolveAllowedPath(path)

        let append = (input["append"] as? Bool) ?? false
        // 默认自动建缺失的父目录（对齐 Claude Code）；父路径存在但不是目录时，
        // createDirectory 仍会失败并按写入失败报告。
        let createDirs = (input["create_dirs"] as? Bool) ?? true

        // A missing/non-directory parent is a known refusal before any write
        // attempt. Keep the prepared receipt unstarted so the ordinary loop can
        // settle it as failed; failures after beginFileWrite remain UNKNOWN.
        if !createDirs {
            var isDirectory: ObjCBool = false
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ToolExecutorError.writeFailed("Failed to write \(path): parent directory is unavailable")
            }
        } else {
            // 自动建目录时，最近的已存在祖先必须是目录；是普通文件就在任何写入前明确失败。
            var ancestor = url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) {
                let next = ancestor.deletingLastPathComponent()
                if next.path == ancestor.path { break }
                ancestor = next
            }
            if FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw ToolExecutorError.writeFailed("Failed to write \(path): parent path is not a directory")
            }
        }

        // P3-OUTPUT-01（DEV-286）：写入口捕获写入前内容（尽力而为，仅作
        // 差异素材，失败不影响写语义）；已有审批全文摘要时必须匹配。
        let preWriteContent: String? = try {
            let data = FileManager.default.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
            try ApprovalFilePreviewContext.current?.validateMutation(data: data)
            // 带 BOM 的 UTF-16 文件 file_read 能读出正文，模型很容易"读完改好整份写回"；
            // file_write 一律写 UTF-8，会悄悄改掉编码，所以和 GBK 一样拒绝（含 0 字节，不能放在下一行判断之后）。
            if let data, ReadOnlyFileSearch.decodeUTF16WithBOM(data) != nil {
                throw ToolExecutorError.writeFailed("\(path) 现有内容是 UTF-16 编码，file_write 会把它改成 UTF-8，本次未写入。请先告诉用户并确认是否转为 UTF-8，再用 shell 转码后修改。")
            }
            guard let data, !data.contains(0) else { return nil }
            if !data.isEmpty, String(data: data, encoding: .utf8) == nil, !FileImporter.isPDF(data: data, pathExtension: url.pathExtension) {
                // 已有文件不是 UTF-8（例如 GBK）：file_write 一律写 UTF-8，会悄悄改掉编码、造成乱码，所以拒绝。
                throw ToolExecutorError.writeFailed("\(path) 现有内容不是 UTF-8 编码（可能是 GBK），file_write 会把它改成 UTF-8 并可能造成乱码，本次未写入。请先告诉用户并确认是否转为 UTF-8，再用 shell 转码后修改。")
            }
            return String(data: data, encoding: .utf8)
        }()

        // A started marker is durable before the first filesystem effect. It
        // cannot claim completion: the process may die on the next instruction.
        let expectedOutputSHA256 = append && FileManager.default.fileExists(atPath: url.path)
            ? nil : Self.sha256(Data(content.utf8))
        if let receipt, let factLedger {
            try factLedger.beginFileWrite(
                receipt,
                targetPath: url.standardizedFileURL.path,
                expectedSHA256: expectedOutputSHA256,
                beforeSHA256: preWriteContent.map { Self.sha256(Data($0.utf8)) }
            )
        }

        var appendedToExistingFile = false
        try ApprovalFilePreviewContext.current?.validateCurrent()
        do {
            if createDirs {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            if append, FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(content.utf8))
                appendedToExistingFile = true
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // PRIVACY-05 (delta 167V-D1): a filesystem permission refusal on the
            // write seam is the same denial class the read seam already types via
            // `readFileDataOrDenial`, so it surfaces as the existing typed
            // `permissionDenied` case instead of being flattened into the
            // untyped `writeFailed` string. Every other failure keeps the
            // existing `writeFailed` shape unchanged: strictly stronger.
            if Self.isPermissionRefusal(error) {
                throw ToolExecutorError.permissionDenied(path)
            }
            throw ToolExecutorError.writeFailed("Failed to write \(path): \(error.localizedDescription)")
        }
        // A completed write is recorded only after real file I/O returned and
        // readback still equals this receipt's exact full-output bytes. If the
        // readback raced another writer or failed, leave only dispatchStarted;
        // recovery must report UNKNOWN rather than infer attribution by hash.
        if let receipt, let factLedger, let expectedOutputSHA256,
           let readback = try? readFileDataOrDenial(at: url, path: path),
           Self.sha256(readback) == expectedOutputSHA256 {
            try factLedger.completeFileWrite(receipt, outputSHA256: expectedOutputSHA256)
        }
        let byteCount = content.utf8.count
        // P3-OUTPUT-01（DEV-286）：写成功后登记台账并把 diffID 透传进结果串。
        // 台账不可用或登记失败时，明确说明已发生写入但未登记。
        let newContent = append ? (preWriteContent ?? "") + content : content
        let kind: FileChangeRecord.Kind
        if preWriteContent == nil {
            kind = .created
        } else if newContent.isEmpty {
            kind = .deleted
        } else {
            kind = .modified
        }
        let diffIDSuffix = try await registerFileChange(
            rawPath: path,
            kind: kind,
            oldContent: preWriteContent ?? "",
            newContent: newContent,
            // Only an actual append lacks a provable full-output checksum.
            // append=true with no file takes the atomic create branch above,
            // whose complete written bytes are exactly content.
            verifiedOutputContent: appendedToExistingFile ? nil : content
        )
        return "Wrote \(byteCount) bytes to \(url.path)\(append ? " (appended)" : "")" + diffIDSuffix
    }

    /// Reconcile exactly one receipt recovered by the existing durable fact
    /// ledger. The same path policy used by execution is re-applied before any
    /// read. Identical current bytes without a completed receipt stay UNKNOWN.
    /// This never dispatches a tool or requests a new approval.
    public func queryRecoveredFileWrite(
        _ receipt: ToolExecutionReceipt,
        ledger: ToolExecutionFactLedger
    ) -> FileWriteReconciliationResult {
        guard receipt.toolName == "file_write",
              ledger.recoveredPendingReceipts.contains(receipt),
              ledger.pendingReceipts.contains(receipt) else { return .unknown }
        guard let evidence = ledger.pendingFileWriteEvidence(for: receipt) else {
            return ledger.fileWriteWasNeverDispatched(receipt) ? .notExecuted : .unknown
        }
        guard let expected = evidence.expectedSHA256,
              evidence.completedSHA256 == expected,
              let target = try? resolveAllowedPath(evidence.targetPath),
              target.standardizedFileURL.path == evidence.targetPath,
              let current = try? readFileDataOrDenial(at: target, path: evidence.targetPath),
              Self.sha256(current) == expected else { return .unknown }
        do {
            guard let fact = try ledger.settle(receipt, status: .succeeded),
                  fact.status == .succeeded,
                  fact.receiptID == receipt.receiptID,
                  fact.compositeKey == receipt.compositeKey else { return .unknown }
            return .succeeded(fact)
        } catch {
            return .unknown
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - file_edit

    enum FileEditMatchResult {
        case notFound
        case ambiguous(Int)
        /// `appliedNew` is the replacement text actually written (CRLF-adapted when needed).
        case replaced(edited: String, occurrences: Int, appliedNew: String)
    }

    /// file_edit 的唯一匹配/替换实现：执行、检查点预计算、审批预览三处共用，
    /// 保证预览与检查点摘要和实际写入的字节一致。
    /// file_read 把 CRLF 文件显示成 "\n" 换行；从中复制的多行 old_string 必须能匹配
    /// CRLF 文件，替换后保持文件自己的换行风格。
    static func matchAndReplaceEdit(in text: String, old: String, new: String, replaceAll: Bool) -> FileEditMatchResult {
        let textScalars = Array(text.unicodeScalars)
        let hasCRLF = zip(textScalars, textScalars.dropFirst()).contains { $0 == "\r" && $1 == "\n" }
        if hasCRLF {
            return matchAndReplaceEditPreservingCRLF(text: textScalars, old: old, new: new, replaceAll: replaceAll)
        }
        let oldString = old
        let newString = new
        let occurrences = text.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else { return .notFound }
        if !replaceAll && occurrences > 1 { return .ambiguous(occurrences) }
        return .replaced(edited: text.replacingOccurrences(of: oldString, with: newString),
                         occurrences: occurrences, appliedNew: newString)
    }

    /// 含 CRLF 的文件：按 unicode 标量匹配，old_string 里的换行同时匹配 "\r\n" 与 "\n"
    /// （混合换行文件两种都计入次数、replace_all 都替换）；写入的 new_string 换行
    /// 统一成文件的主导风格（CRLF 不少于孤立 LF 时用 CRLF）。未命中的部分字节不变。
    private static func matchAndReplaceEditPreservingCRLF(
        text: [Unicode.Scalar], old: String, new: String, replaceAll: Bool
    ) -> FileEditMatchResult {
        func normalized(_ s: String) -> [Unicode.Scalar] {
            let scalars = Array(s.unicodeScalars)
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(scalars.count)
            var i = 0
            while i < scalars.count {
                if scalars[i] == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    i += 1
                    continue
                }
                out.append(scalars[i])
                i += 1
            }
            return out
        }
        var crlfCount = 0
        var lfCount = 0
        for (i, scalar) in text.enumerated() where scalar == "\n" {
            if i > 0, text[i - 1] == "\r" { crlfCount += 1 } else { lfCount += 1 }
        }
        let useCRLF = crlfCount >= lfCount
        let pattern = normalized(old)
        guard !pattern.isEmpty else { return .notFound }
        var newScalars = normalized(new)
        if useCRLF {
            var converted: [Unicode.Scalar] = []
            converted.reserveCapacity(newScalars.count)
            for scalar in newScalars {
                if scalar == "\n" { converted.append("\r") }
                converted.append(scalar)
            }
            newScalars = converted
        }
        // 匹配区间（半开）
        var ranges: [Range<Int>] = []
        var i = 0
        while i < text.count {
            var t = i
            var p = 0
            while p < pattern.count, t < text.count {
                if pattern[p] == "\n" {
                    if text[t] == "\n" {
                        t += 1
                    } else if text[t] == "\r", t + 1 < text.count, text[t + 1] == "\n" {
                        t += 2
                    } else {
                        break
                    }
                } else if text[t] == pattern[p] {
                    t += 1
                } else {
                    break
                }
                p += 1
            }
            if p == pattern.count {
                ranges.append(i..<t)
                i = t
                if !replaceAll, ranges.count > 1 { break }
            } else {
                i += 1
            }
        }
        guard !ranges.isEmpty else { return .notFound }
        if !replaceAll && ranges.count > 1 { return .ambiguous(ranges.count) }
        var out = String.UnicodeScalarView()
        var cursor = 0
        for range in ranges {
            out.append(contentsOf: text[cursor..<range.lowerBound])
            out.append(contentsOf: newScalars)
            cursor = range.upperBound
        }
        out.append(contentsOf: text[cursor...])
        var appliedView = String.UnicodeScalarView()
        appliedView.append(contentsOf: newScalars)
        return .replaced(edited: String(out), occurrences: ranges.count, appliedNew: String(appliedView))
    }

    private func runFileEdit(_ input: [String: Any]) async throws -> String {
        guard let path = input["path"] as? String, !path.isEmpty else {
            throw ToolExecutorError.missingParameter("path")
        }
        guard let requestedOld = input["old_string"] as? String, !requestedOld.isEmpty else {
            throw ToolExecutorError.missingParameter("old_string")
        }
        guard let requestedNew = input["new_string"] as? String else {
            throw ToolExecutorError.missingParameter("new_string")
        }
        let url = try resolveAllowedPath(path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolExecutorError.fileNotFound(path)
        }
        let data = try readFileDataOrDenial(at: url, path: path)
        try ApprovalFilePreviewContext.current?.validateMutation(data: data)
        if FileImporter.isPDF(data: data, pathExtension: url.pathExtension) {
            throw ToolExecutorError.editFailed("PDF 无法编辑：\(path)。请另存为文本或 Markdown 后再改，或用 file_write 新建文件。")
        }
        if data.contains(0) {
            throw ToolExecutorError.fileIsBinary(path)
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw ToolExecutorError.readFailed("File is not valid UTF-8 text: \(path)")
        }
        // P3-OUTPUT-01（DEV-286）：file_edit 已天然持有写入前内容，直接留档
        // 作差异素材；不额外触盘。
        let preEditContent = text

        let replaceAll = (input["replace_all"] as? Bool) ?? false
        let newString: String
        let occurrences: Int
        switch Self.matchAndReplaceEdit(in: text, old: requestedOld, new: requestedNew, replaceAll: replaceAll) {
        case .notFound:
            throw ToolExecutorError.editFailed(Self.editNotFoundDetail(path: path, text: text, old: requestedOld))
        case .ambiguous(let count):
            throw ToolExecutorError.editFailed(
                "old_string matches \(count) locations in \(path); pass replace_all=true to replace all"
            )
        case .replaced(let edited, let count, let appliedNew):
            text = edited
            occurrences = count
            newString = appliedNew
        }
        guard !Self.introducesRedactedFileMask(from: preEditContent, to: text) else {
            throw ToolExecutorError.editFailed(Self.redactedFileMutationMessage)
        }

        try ApprovalFilePreviewContext.current?.validateCurrent()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // PRIVACY-05 (residual registered by delta 167V-D1, lane 172): a
            // filesystem permission refusal on the file_edit write seam is the
            // same denial class the read seam already types via
            // `readFileDataOrDenial` and the file_write seam types since
            // 167V-D1, so it surfaces as the existing typed `permissionDenied`
            // case instead of being flattened into the untyped `writeFailed`
            // string. Every other failure keeps the existing `writeFailed`
            // shape unchanged: strictly stronger.
            if Self.isPermissionRefusal(error) {
                throw ToolExecutorError.permissionDenied(path)
            }
            throw ToolExecutorError.writeFailed("Failed to edit \(path): \(error.localizedDescription)")
        }
        // P3-OUTPUT-01（DEV-286）：编辑成功后登记台账；编辑把正文清空的
        // 删除类语义按 .deleted 记录，其余为 .modified（文件本已存在）。
        let editKind: FileChangeRecord.Kind =
            (text.isEmpty && !preEditContent.isEmpty) ? .deleted : .modified
        let diffIDSuffix = try await registerFileChange(
            rawPath: path,
            kind: editKind,
            oldContent: preEditContent,
            newContent: text,
            verifiedOutputContent: text
        )
        return "Edited \(path): replaced \(occurrences) occurrence(s) (\(newString.utf8.count) bytes written)." + diffIDSuffix
    }

    /// 绕过模式下的 file_delete：移入废纸篓（可恢复），不永久删除。
    /// 不走检查点（它只覆盖 ≤64KiB 文本的物理删除）。若是 ≤64KiB 的 UTF-8 文本
    /// 且台账可用，仍登记一条 `.deleted` 记录，改动面板与撤销入口保持可用；
    /// 移入废纸篓失败时回滚该登记。
    private func runFileTrash(raw: String, physical: String) throws -> String {
        let lexical = URL(fileURLWithPath: raw).standardizedFileURL.path
        var info = stat()
        var target = physical
        // 符号链接本身移入废纸篓，而不是它指向的目标；链接位置也要过底线。
        if Darwin.lstat(lexical, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            if let reason = BypassSystemFloor.violation(path: lexical, operation: .delete) {
                throw ToolExecutorError.writeFailed(reason)
            }
            if let reason = BypassAppDataFloor.violation(path: lexical, access: .delete) {
                throw ToolExecutorError.writeFailed(reason)
            }
            target = lexical
        }
        guard Darwin.lstat(target, &info) == 0 else {
            throw ToolExecutorError.fileNotFound(raw)
        }
        let url = URL(fileURLWithPath: target)
        var registration: (record: FileChangeRecord, undo: FileChangeLedger.RegistrationUndo)?
        let context = mutableState.withLock {
            (ledger: $0.fileChangeLedger, sessionID: $0.fileChangeSessionID, binding: $0.taskFileArtifactBinding)
        }
        let receipt = ToolExecutionReceiptContext.current
        let sessionID = receipt?.compositeKey?.sessionID ?? context.sessionID
        if let ledger = context.ledger, !sessionID.isEmpty,
           (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size <= 64 * 1024,
           let data = try? Data(contentsOf: url), !data.contains(0),
           let oldContent = String(data: data, encoding: .utf8) {
            registration = try ledger.registerWithUndo(
                sessionID: sessionID, path: url.path, kind: .deleted,
                oldContent: oldContent, newContent: "",
                producerReceipt: receipt?.compositeKey?.sessionID == sessionID ? receipt : nil,
                verifiedDeletedContentSHA256: Self.sha256(data),
                taskArtifactBinding: context.binding)
        }
        var resulting: URL?
        do {
            if let mover = BypassTrashSeam.mover {
                resulting = try mover(url)
            } else {
                var item: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &item)
                resulting = item as URL?
            }
        } catch {
            if let registration { context.ledger?.rollbackRegistration(registration.undo) }
            throw ToolExecutorError.writeFailed("无法移入废纸篓：\(error.localizedDescription)")
        }
        var message = "已移入废纸篓（未永久删除，可在废纸篓恢复）：\(target)"
        if let resulting { message += " -> \(resulting.path)" }
        if let registration { message += " [diffID:\(registration.record.diffID)]" }
        return message
    }

    /// Physical deletion is deliberately narrower than shell rm: one existing
    /// regular UTF-8 file, through the same allow/deny path gate as file_write.
    /// Parent and owner-only quarantine descriptors anchor the final unlink;
    /// it cannot recurse or delete a different inode substituted at the
    /// original path between the last stat and the move.
    /// A read-only snapshot through this executor's existing mutation authority.
    /// Rootless approval requests cannot invoke this producer.
    nonisolated func prepareDeletionPreview(path: String) async throws -> ApprovalFilePreview {
        try await prepareFileApprovalPreview(tool: "file_delete", input: ComposerToolInput(["path": path]))
    }

    nonisolated func prepareFileApprovalPreview(tool: String, input: ComposerToolInput) async throws -> ApprovalFilePreview {
        guard ["file_write", "file_edit", "file_delete"].contains(tool),
              let path = approvalStringValue(input, for: "path") else { throw ToolExecutorError.invalidParameter("path") }
        // Swift 6 generic executor: off-main I/O with the original TaskLocals.
        try await validateChildWorkspace(name: tool, input: input.toolExecutionDictionary)
        // 先读再改的检查放在审批预检之前：不合格的写入不弹审批卡，直接把原因返回给模型。
        if tool == "file_write" || tool == "file_edit",
           let physical = try? resolveAllowedPath(path).path {
            try verifyReadBeforeMutation(name: tool, physical: physical, input: input.toolExecutionDictionary)
        }
        let preview = try captureFileApprovalPreview(tool: tool, input: input, path: path)
        try await validateChildWorkspace(name: tool, input: input.toolExecutionDictionary)
        return preview
    }

    private func captureFileApprovalPreview(tool: String, input: ComposerToolInput, path: String) throws -> ApprovalFilePreview {
        let url = try resolveAllowedPath(path)
        let version = try ApprovalFileVersion.capture(path: path)
        func hidden() -> ApprovalFilePreview {
            var info = stat()
            let size = Darwin.lstat(version.canonicalPath, &info) == 0 ? "\(info.st_size) bytes" : "无法检查大小"
            return ApprovalFilePreview(version: version,
                text: ContentSecretRedactor.redact("文件：\(url.lastPathComponent)\n大小：\(size)\n敏感文件：内容已隐藏"),
                isSensitive: true, available: true)
        }
        if SensitiveFilePolicy.contains(path) || SensitiveFilePolicy.contains(url.path)
            || SensitiveFilePolicy.contains(version.canonicalPath) { return hidden() }
        var existence = stat()
        if Darwin.lstat(url.path, &existence) != 0, errno == ENOENT, tool == "file_write" {
            return .write(version: version, content: approvalStringValue(input, for: "content") ?? "", exists: false,
                oldLines: nil, append: input.toolExecutionDictionary["append"] as? Bool == true, digest: nil)
        }
        let parent = url.deletingLastPathComponent()
        var expectedParent = stat()
        guard Darwin.lstat(parent.path, &expectedParent) == 0 else { throw ApprovalFileChangedError() }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ToolExecutorError.readFailed("无法提供正文预览") }
        defer { _ = Darwin.close(parentFD) }
        var anchored = stat()
        guard Darwin.fstat(parentFD, &anchored) == 0, anchored.st_dev == expectedParent.st_dev,
              anchored.st_ino == expectedParent.st_ino else { throw ApprovalFileChangedError() }
        func validateParent() throws -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = buffer.withUnsafeMutableBufferPointer { fcntl(parentFD, F_GETPATH, $0.baseAddress!) }
            guard result == 0 else { throw ApprovalFileChangedError() }
            let actual = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let target = URL(fileURLWithPath: actual).appendingPathComponent(url.lastPathComponent).path
            guard try resolveAllowedPath(target).path == url.path else { throw ApprovalFileChangedError() }
            return target
        }
        let anchoredPath = try validateParent()
        if SensitiveFilePolicy.contains(anchoredPath) { return hidden() }
        var before = stat()
        guard Darwin.fstatat(parentFD, url.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0,
              version.matches(before), (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_nlink == 1, before.st_size >= 0, (tool != "file_delete" || before.st_size <= 64 * 1024) else {
            throw ToolExecutorError.invalidParameter(tool == "file_delete"
                ? (before.st_size > 64 * 1024
                    ? "文件超过 64 KiB，不能用 file_delete 删除。请先把文件名和大小告诉用户并征得确认，确认后改用 shell_execute 执行 rm（需要审批）。"
                    : "无法提供正文预览：仅支持不超过64 KiB的普通文本文件")
                : "无法提供正文预览：目标不是同一普通文件")
        }
        let fd = Darwin.openat(parentFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let failure = errno
            let append = input.toolExecutionDictionary["append"] as? Bool == true
            // Preserve the original write-only overwrite/append contract only
            // for a stable, already-authorized regular leaf and an exact OS
            // permission refusal. No other read failure degrades to metadata.
            if tool == "file_write", failure == EACCES || failure == EPERM {
                let writable = append
                    ? Darwin.faccessat(parentFD, url.lastPathComponent, W_OK, AT_EACCESS) == 0
                    : Darwin.faccessat(parentFD, ".", W_OK | X_OK, AT_EACCESS) == 0
                var current = stat()
                if writable, Darwin.fstatat(parentFD, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   version.matches(current), current.st_nlink == 1 {
                    _ = try validateParent()
                    try version.validateCurrent()
                    return .write(version: version, content: approvalStringValue(input, for: "content") ?? "", exists: true,
                        oldLines: nil, append: append, digest: nil, oldUnreadable: true)
                }
            }
            throw ToolExecutorError.readFailed("无法提供正文预览")
        }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0, version.matches(opened), opened.st_nlink == 1 else {
            throw ApprovalFileChangedError()
        }
        var data = Data()
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var lineCounter = ApprovalUTF8LineCounter()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0, tool != "file_delete" || byteCount + Int64(count) <= 64 * 1024 else {
                throw ToolExecutorError.readFailed("无法提供正文预览")
            }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            byteCount += Int64(count)
            if tool == "file_write" {
                lineCounter.consume(chunk)
                // 覆盖写入：旧文件不超过 256KiB 时留存正文，供审批卡给新旧对比。
                if byteCount <= Int64(ApprovalFilePreview.overwriteDiffMaxBytes) { data.append(chunk) }
                else if !data.isEmpty { data = Data() }
            } else { data.append(chunk) }
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0, version.matches(after), after.st_nlink == 1,
              after.st_size == off_t(byteCount) else { throw ApprovalFileChangedError() }
        _ = try validateParent()
        try version.validateCurrent()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if tool == "file_write" {
            let oldText: String? = byteCount <= Int64(ApprovalFilePreview.overwriteDiffMaxBytes) && !data.contains(0)
                ? String(data: data, encoding: .utf8) : nil
            return .write(version: version, content: approvalStringValue(input, for: "content") ?? "", exists: true,
                oldLines: lineCounter.finish(), append: input.toolExecutionDictionary["append"] as? Bool == true, digest: digest,
                oldContent: oldText)
        }
        if tool == "file_edit", FileImporter.isPDF(data: data, pathExtension: url.pathExtension) {
            // Match runFileEdit's existing PDF read branch, without inventing
            // a text edit or extracting additional PDF content for this card.
            return ApprovalFilePreview(version: version,
                text: ContentSecretRedactor.redact("路径：\(version.path)\n大小：\(byteCount) bytes\nPDF：沿用现有PDF读取路径，不执行文本替换；统一文本diff不可用"),
                isSensitive: false, available: true, deletionContentDigest: digest)
        }
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw ToolExecutorError.readFailed("无法提供正文预览：文件不是UTF8文本")
        }
        if tool == "file_edit" {
            guard let old = approvalStringValue(input, for: "old_string"), !old.isEmpty,
                  let replacement = approvalStringValue(input, for: "new_string") else { throw ToolExecutorError.invalidParameter("edit strings") }
            switch Self.matchAndReplaceEdit(in: content, old: old, new: replacement,
                                            replaceAll: input.toolExecutionDictionary["replace_all"] as? Bool == true) {
            case .notFound:
                throw ToolExecutorError.editFailed(
                    Self.editNotFoundDetail(path: version.canonicalPath, text: content, old: old))
            case .ambiguous:
                throw ToolExecutorError.editFailed("old_string must identify one location, or use replace_all=true")
            case .replaced(let edited, _, _):
                return .edit(version: version, old: content, new: edited, digest: digest)
            }
        }
        return .deletion(version: version, data: data, content: content)
    }

    private func runFileDelete(_ input: [String: Any]) throws -> String {
        guard let path = input["path"] as? String, !path.isEmpty else {
            throw ToolExecutorError.missingParameter("path")
        }
        let url = try resolveAllowedPath(path)
        // Deletion cannot use file_write's best-effort ledger semantics. A
        // missing ledger or session must fail before any filesystem mutation.
        let registrationContext = mutableState.withLock {
            (ledger: $0.fileChangeLedger,
             sessionID: $0.fileChangeSessionID,
             binding: $0.taskFileArtifactBinding)
        }
        guard let ledger = registrationContext.ledger else {
            throw ToolExecutorError.writeFailed("File change ledger unavailable for deletion")
        }
        let receipt = ToolExecutionReceiptContext.current
        let sessionID = receipt?.compositeKey?.sessionID ?? registrationContext.sessionID
        guard !sessionID.isEmpty else {
            throw ToolExecutorError.writeFailed("File change session unavailable for deletion")
        }
        let boundReceipt = receipt?.compositeKey?.sessionID == sessionID ? receipt : nil
        var rawInfo = stat()
        guard Darwin.lstat(path, &rawInfo) == 0 else {
            throw ToolExecutorError.fileNotFound(path)
        }
        guard (rawInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ToolExecutorError.invalidParameter("path must name a regular file")
        }
        let parent = url.deletingLastPathComponent()
        // Snapshot the canonical parent's identity before opening it. A
        // replaced directory cannot silently turn the anchored fd into a
        // different ledger path.
        var resolvedParent = stat()
        guard Darwin.lstat(parent.path, &resolvedParent) == 0,
              (resolvedParent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ToolExecutorError.pathViolation(path)
        }
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw ToolExecutorError.pathViolation(path)
        }
        defer { _ = Darwin.close(parentFD) }
        var anchoredParent = stat()
        guard Darwin.fstat(parentFD, &anchoredParent) == 0,
              (anchoredParent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              anchoredParent.st_dev == resolvedParent.st_dev,
              anchoredParent.st_ino == resolvedParent.st_ino else {
            throw ToolExecutorError.pathViolation(path)
        }
        let name = url.lastPathComponent
        var before = stat()
        guard Darwin.fstatat(parentFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_dev == rawInfo.st_dev,
              before.st_ino == rawInfo.st_ino,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 64 * 1024 else {
            throw ToolExecutorError.invalidParameter("path must name the same regular text file of at most 64 KiB")
        }
        let fileFD = Darwin.openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else {
            throw ToolExecutorError.fileNotFound(path)
        }
        defer { _ = Darwin.close(fileFD) }
        var opened = stat()
        guard Darwin.fstat(fileFD, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_nlink == 1 else {
            throw ToolExecutorError.invalidParameter("file changed before deletion")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileFD, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw ToolExecutorError.readFailed("Failed to read file before deletion")
            }
            guard data.count + count <= 64 * 1024 else {
                throw ToolExecutorError.invalidParameter("file exceeds 64 KiB deletion limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.contains(0), let oldContent = String(data: data, encoding: .utf8) else {
            throw ToolExecutorError.fileIsBinary(path)
        }
        var afterRead = stat()
        guard Darwin.fstat(fileFD, &afterRead) == 0,
              afterRead.st_size == off_t(data.count),
              afterRead.st_nlink == 1,
              afterRead.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              afterRead.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw ToolExecutorError.invalidParameter("file changed while reading before deletion")
        }
        try ApprovalFilePreviewContext.current?.validateDeletion(data: data, info: afterRead)
        FileDeleteRaceFixture.beforeFinalCheck?()
        var finalParent = stat()
        guard Darwin.lstat(parent.path, &finalParent) == 0,
              (finalParent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              finalParent.st_dev == anchoredParent.st_dev,
              finalParent.st_ino == anchoredParent.st_ino else {
            throw ToolExecutorError.pathViolation(path)
        }
        var final = stat()
        guard Darwin.fstatat(parentFD, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
              (final.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              final.st_dev == opened.st_dev,
              final.st_ino == opened.st_ino,
              final.st_nlink == 1,
              final.st_size == off_t(data.count),
              final.st_mtimespec.tv_sec == afterRead.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == afterRead.st_mtimespec.tv_nsec else {
            throw ToolExecutorError.invalidParameter("file changed before deletion")
        }
        // A final stat followed by unlinkat still has a name-replacement
        // window. Atomically move whatever currently owns the name into a
        // fresh, owner-only sibling directory, then verify that moved inode
        // against the one whose bytes were inspected. A substituted regular
        // file is restored rather than deleted or attributed to oldContent.
        let quarantineName = ".minis-delete-\(UUID().uuidString)"
        guard Darwin.mkdirat(parentFD, quarantineName, 0o700) == 0 else {
            throw ToolExecutorError.writeFailed("Failed to create deletion quarantine for \(path)")
        }
        let quarantineFD = Darwin.openat(
            parentFD, quarantineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard quarantineFD >= 0 else {
            _ = Darwin.unlinkat(parentFD, quarantineName, AT_REMOVEDIR)
            throw ToolExecutorError.pathViolation(path)
        }
        defer {
            _ = Darwin.close(quarantineFD)
            // An unrecoverable restore failure leaves the object in this
            // nonempty 0700 directory for explicit recovery, never cleanup.
            _ = Darwin.unlinkat(parentFD, quarantineName, AT_REMOVEDIR)
        }
        var quarantineInfo = stat()
        guard Darwin.fstat(quarantineFD, &quarantineInfo) == 0,
              (quarantineInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (quarantineInfo.st_mode & 0o777) == 0o700,
              quarantineInfo.st_uid == geteuid(),
              quarantineInfo.st_dev == anchoredParent.st_dev else {
            throw ToolExecutorError.pathViolation(path)
        }
        FileDeleteRaceFixture.beforeQuarantineMove?()
        let movedName = "target"
        guard Darwin.renameatx_np(parentFD, name, quarantineFD, movedName,
                                  UInt32(RENAME_EXCL)) == 0 else {
            throw ToolExecutorError.writeFailed("Failed to isolate deletion target \(path)")
        }
        FileDeleteRaceFixture.afterQuarantineMove?(
            parent.appendingPathComponent(quarantineName).appendingPathComponent(movedName)
        )
        func restoreMovedFile() throws {
            guard Darwin.renameatx_np(quarantineFD, movedName, parentFD, name,
                                      UInt32(RENAME_EXCL)) == 0 else {
                throw ToolExecutorError.writeFailed(
                    "Deletion refused; recover file at \(parent.appendingPathComponent(quarantineName).appendingPathComponent(movedName).path)"
                )
            }
        }
        var movedInfo = stat()
        guard Darwin.fstatat(quarantineFD, movedName, &movedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (movedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              movedInfo.st_dev == opened.st_dev,
              movedInfo.st_ino == opened.st_ino,
              movedInfo.st_nlink == 1,
              movedInfo.st_size >= 0,
              movedInfo.st_size <= 64 * 1024 else {
            try restoreMovedFile()
            throw ToolExecutorError.invalidParameter("file changed before deletion")
        }
        let movedFD = Darwin.openat(quarantineFD, movedName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard movedFD >= 0 else {
            try restoreMovedFile()
            throw ToolExecutorError.invalidParameter("isolated file cannot be opened")
        }
        defer { _ = Darwin.close(movedFD) }
        var movedOpened = stat()
        guard Darwin.fstat(movedFD, &movedOpened) == 0,
              (movedOpened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              movedOpened.st_dev == opened.st_dev,
              movedOpened.st_ino == opened.st_ino,
              movedOpened.st_nlink == 1 else {
            try restoreMovedFile()
            throw ToolExecutorError.invalidParameter("isolated file changed before deletion")
        }
        var movedData = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(movedFD, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 || movedData.count + count > 64 * 1024 {
                try restoreMovedFile()
                throw ToolExecutorError.invalidParameter("isolated file could not be read safely")
            }
            movedData.append(contentsOf: buffer.prefix(count))
        }
        var movedAfterRead = stat()
        guard Darwin.fstat(movedFD, &movedAfterRead) == 0,
              movedAfterRead.st_size == off_t(movedData.count),
              movedAfterRead.st_nlink == 1,
              movedAfterRead.st_mtimespec.tv_sec == movedOpened.st_mtimespec.tv_sec,
              movedAfterRead.st_mtimespec.tv_nsec == movedOpened.st_mtimespec.tv_nsec,
              movedData == data,
              !movedData.contains(0),
              String(data: movedData, encoding: .utf8) != nil else {
            try restoreMovedFile()
            throw ToolExecutorError.invalidParameter("isolated file content changed before deletion")
        }
        var parentBeforeDelete = stat()
        guard Darwin.lstat(parent.path, &parentBeforeDelete) == 0,
              parentBeforeDelete.st_dev == anchoredParent.st_dev,
              parentBeforeDelete.st_ino == anchoredParent.st_ino else {
            try restoreMovedFile()
            throw ToolExecutorError.pathViolation(path)
        }
        let registration: (record: FileChangeRecord, undo: FileChangeLedger.RegistrationUndo)
        do {
            registration = try ledger.registerWithUndo(
                sessionID: sessionID, path: url.path, kind: .deleted,
                oldContent: oldContent, newContent: "",
                producerReceipt: boundReceipt,
                verifiedDeletedContentSHA256: Self.sha256(movedData),
                taskArtifactBinding: registrationContext.binding
            )
        } catch {
            try restoreMovedFile()
            throw ToolExecutorError.writeFailed("Failed to record deletion before unlink: \(error)")
        }
        let unlinkResult = FileDeleteRaceFixture.beforePhysicalUnlink?()
            ?? (Darwin.unlinkat(quarantineFD, movedName, 0) == 0 ? 0 : errno)
        guard unlinkResult == 0 else {
            let failedErrno = unlinkResult
            try restoreMovedFile()
            ledger.rollbackRegistration(registration.undo)
            if failedErrno == EACCES || failedErrno == EPERM {
                throw ToolExecutorError.permissionDenied(path)
            }
            throw ToolExecutorError.writeFailed("Failed to delete \(path): \(String(cString: strerror(failedErrno)))")
        }
        return "Deleted \(url.path) [diffID:\(registration.record.diffID)]"
    }

    private static let redactedFileMarker = "[REDACTED]"
    private static let redactedFileMutationMessage =
        "本次改动包含脱敏占位符，未写入。请用 file_edit 只修改目标行，不要把脱敏占位符写入文件。"

    /// file_edit 未命中的说明。原文带脱敏占位符，或只差空白（缩进、空格、换行）时，
    /// 补一句可操作的提示；其他未命中保持原样。
    private static func editNotFoundDetail(path: String, text: String, old: String) -> String {
        let base = "old_string not found in \(path)"
        func collapsed(_ value: String) -> String {
            value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        guard old.contains(redactedFileMarker) || text.contains(redactedFileMarker)
                || collapsed(text).contains(collapsed(old)) else { return base }
        return base + "。原文可能含脱敏占位符，或与文件里的空白（缩进、空格、换行）不一致；"
            + "请先用 file_read 重新读取这个文件，再按读到的内容原样编辑。"
    }

    private static func introducesRedactedFileMask(from original: String, to proposed: String) -> Bool {
        if proposed.contains(redactedFileMarker),
           proposed.components(separatedBy: redactedFileMarker).count
                > original.components(separatedBy: redactedFileMarker).count {
            return true
        }
        guard proposed.contains("*"), !original.isEmpty else { return false }
        let projected = ContentSecretRedactor.redact(original)
        guard projected != original else { return false }
        let existing = starMaskOccurrences(in: original)
        let replacements = starMaskOccurrences(in: proposed)
        if starMaskOccurrences(in: projected).contains(where: { context, count in
            let existingCount = existing[context, default: 0]
            return count > existingCount && replacements[context, default: 0] > existingCount
        }) {
            return true
        }
        guard original.contains("#"), proposed.contains("#") else { return false }
        let oldLiterals = starMaskOccurrences(in: original, withAssignmentComments: true)
        let newLiterals = starMaskOccurrences(in: proposed, withAssignmentComments: true)
        let oldProjected = starMaskOccurrences(in: projected, withAssignmentComments: true)
        let candidates = oldProjected.filter { context, count in
            let literalCount = oldLiterals[context, default: 0]
            return count > literalCount && newLiterals[context, default: 0] > literalCount
        }
        guard !candidates.isEmpty else { return false }
        let newProjected = starMaskOccurrences(
            in: ContentSecretRedactor.redact(proposed), withAssignmentComments: true)
        // A stable comment can distinguish same-key, same-width duplicates.
        // A literal edit alone is allowed if its actual credential remains.
        return candidates.contains { context, count in
            let oldCredentials = count - oldLiterals[context, default: 0]
            let newCredentials = newProjected[context, default: 0] - newLiterals[context, default: 0]
            return newCredentials < oldCredentials
        }
    }

    private struct FileStarMaskContext: Hashable {
        let prefix: String
        let width: Int
        let suffix: String
    }

    private static let dotenvMaskPrefix = try? NSRegularExpression(
        pattern: #"^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*["']?$"#
    )

    private static func dotenvFileMaskName(_ prefix: String) -> String? {
        guard let assignment = dotenvMaskPrefix?.firstMatch(in: prefix,
            range: NSRange(prefix.startIndex..., in: prefix)),
              let name = Range(assignment.range(at: 1), in: prefix) else { return nil }
        return String(prefix[name])
    }

    private static func strippingLineNumberPrefix(_ line: Substring) -> Substring {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        let digitsStart = index
        while index < line.endIndex, line[index].isASCII, line[index].isNumber { index = line.index(after: index) }
        guard index > digitsStart, index < line.endIndex, line[index] == "\t" else { return line }
        return line[line.index(after: index)...]
    }

    /// Match exact redaction runs by their line prefix (e.g. a dotenv key),
    /// independent of line order. Count pre-existing literal runs separately.
    private static func starMaskOccurrences(in text: String,
                                            withAssignmentComments: Bool = false) -> [FileStarMaskContext: Int] {
        var counts: [FileStarMaskContext: Int] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // file_read 的显示带 cat -n 行号前缀；模型整段抄回时前缀不能让掩码上下文对不上而放行写回。
            let line = strippingLineNumberPrefix(rawLine)
            var index = line.startIndex
            while index < line.endIndex {
                guard line[index] == "*" else {
                    line.formIndex(after: &index)
                    continue
                }
                let start = index
                var width = 0
                repeat {
                    width += 1
                    line.formIndex(after: &index)
                } while index < line.endIndex && line[index] == "*"
                let rawPrefix = line[..<start].trimmingCharacters(in: .whitespaces)
                let assignment = dotenvFileMaskName(rawPrefix)
                let prefix = assignment.map { $0 + "=" } ?? rawPrefix
                var suffix = prefix.isEmpty ? String(line[index...]) : ""
                if withAssignmentComments {
                    guard assignment != nil else { continue }
                    let tail = line[index...]
                    let unquoted = tail.first == "\"" || tail.first == "'" ? tail.dropFirst() : tail
                    suffix = unquoted.trimmingCharacters(in: .whitespaces)
                    guard unquoted.first?.isWhitespace == true, suffix.hasPrefix("#") else { continue }
                }
                let context = FileStarMaskContext(prefix: prefix, width: width, suffix: suffix)
                counts[context, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Path Safety

    /// 读路径：在 `resolveAllowedPath` 之上加凭据保护，只在绕过模式（已确认）生效，
    /// 其他模式与 7428f83 一致（读 .env 等走原有审批路径，不在此硬拒绝）。
    /// 设置里可关闭。写/改/删只拦凭据目录，见 `runSerialFileMutation`。
    private func resolveReadablePath(_ raw: String, tool: String = "file_read") throws -> URL {
        let readRoot = ApprovedFileReadScope.additionalRoot(for: tool, path: raw)
        let url = try Self.resolveAllowedPath(raw, allowedRoot: allowedRoot,
            additionalAllowedRoots: additionalAllowedRoots + (readRoot.map { [$0] } ?? []),
            deniedRoots: deniedRoots)
        if BypassOpenScope.isActive {
            // 凭据目录与 home 下的登录文件：绕过下也不读。
            if SensitiveFilePolicy.credentialDenial(for: url.path, forWrite: true) != nil {
                throw ToolExecutorError.permissionDenied(raw)
            }
            // .env、密钥文件名：绕过下改为弹卡询问，用户批准过这一个文件（ApprovedFileReadScope）才读。
            if SensitiveFilePolicy.credentialDenial(for: url.path) != nil,
               !ApprovedFileReadScope.permits(tool: tool, path: url.path) {
                throw ToolExecutorError.permissionDenied(raw)
            }
        }
        return url
    }

    /// Resolve a raw path string to an absolute URL confined to `allowedRoot`
    /// (or any `additionalAllowedRoots` — mounted external folders, AJ-45).
    /// Rejects relative paths, `.`/`..` components (rejected outright before
    /// any filesystem access, mirroring `PolicyRuntimePathBoundary` so the
    /// lexical-vs-physical `..` ambiguity can never diverge from what is
    /// opened), symlinks escaping the root (including symlinked parents of
    /// not-yet-existing write targets), and any path under a `deniedRoots`
    /// entry (e.g. Application Support, where the agent's own API keys live).
    /// Deny-table containment is compared case- and normalization-folded
    /// (`foldedCandidate(_:isWithin:)`) because macOS volumes address the
    /// same directory through NFC/NFD and upper/lower-case variants; without
    /// folding a deny entry `/Root/Secret` would not block `/root/secret/…`.
    /// Allow-side membership stays exact, so folding can only ever deny more,
    /// never grant access.
    private func resolveAllowedPath(_ raw: String) throws -> URL {
        try Self.resolveAllowedPath(raw, allowedRoot: allowedRoot, additionalAllowedRoots: additionalAllowedRoots, deniedRoots: deniedRoots)
    }

    private static func resolveAllowedPath(_ raw: String, allowedRoot: URL, additionalAllowedRoots: [URL], deniedRoots: [URL], reportRootBoundary: Bool = false) throws -> URL {
        guard raw.hasPrefix("/"), !raw.isEmpty,
              raw.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolExecutorError.pathViolation(raw)
        }
        // One canonical resolution seam for both the policy gate and the file
        // tools: absolute, no traversal components, symlinks resolved for the
        // longest existing prefix, missing write-target suffix preserved.
        guard let candidate = PolicyRuntimePathBoundary.canonicalPath(raw) else {
            throw ToolExecutorError.pathViolation(raw)
        }
        let allowedRoots = [allowedRoot] + additionalAllowedRoots
        let isUnderAnyRoot = allowedRoots.contains { root in
            let rootPath = PolicyRuntimePathBoundary.canonicalPath(root.path)
                ?? root.standardizedFileURL.path
            return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
        }
        // 绕过模式（已确认）下文件读写改删不再受项目授权根限制；
        // deniedRoots（应用自己的密钥目录等）仍然生效。
        guard isUnderAnyRoot || BypassOpenScope.isActive || ApprovedFileWriteScope.permits(path: candidate) else {
            if reportRootBoundary { throw ProjectDirectoryAuthorizationError.outsideAccessibleRoots }
            throw ToolExecutorError.pathViolation(raw)
        }
        // Goal19：绕过模式下 deniedRoots 两边都先剥 `/System/Volumes/Data` 与 `/private`
        // 前缀再比较（与系统底线、AppDataFloor 同一归一函数），否则用户自己加的拒绝目录
        // 能被 `/System/Volumes/Data/Users/u/<目录>/x` 这种 firmlink 写法绕过。
        // 非绕过模式保持原比较方式不变。
        let strippedCandidate = BypassOpenScope.isActive ? BypassPathNormalizer.strip(candidate).real : candidate
        // App-owned state (the persistent approval rule file) is never a
        // file tool target, even when a broad session root contains it.
        // 合并 persistent-allow 与 bypass：绕过模式下同样检查剥前缀后的形式，
        // 避免用 firmlink 写法绕过规则文件保护。
        if SensitiveFilePolicy.isProtectedStatePath(candidate)
            || (strippedCandidate != candidate && SensitiveFilePolicy.isProtectedStatePath(strippedCandidate)) {
            throw ToolExecutorError.pathViolation(raw)
        }
        for denied in deniedRoots {
            let deniedPath = PolicyRuntimePathBoundary.canonicalPath(denied.path)
                ?? denied.standardizedFileURL.path
            // 绕过模式（已确认）：默认的「整个 Application Support」拒绝不再整体生效，
            // 改为下面只拒绝 MinisCanvas 自己的目录与钥匙串（用户 2026-10-22 决定）。
            // 用户自己加的其他拒绝目录照旧生效。
            if BypassOpenScope.isActive, BypassAppDataFloor.isGenericApplicationSupportRoot(deniedPath) {
                continue
            }
            let deniedComparable = BypassOpenScope.isActive ? BypassPathNormalizer.strip(deniedPath).real : deniedPath
            if PolicyRuntimePathBoundary.foldedCandidate(strippedCandidate, isWithin: deniedComparable) {
                throw ToolExecutorError.pathViolation(raw)
            }
        }
        if BypassOpenScope.isActive, BypassAppDataFloor.violation(path: candidate, access: .read) != nil {
            throw ToolExecutorError.pathViolation(raw)
        }
        return URL(fileURLWithPath: candidate, isDirectory: false)
    }
}

actor ShellPipeReaderLifetime {
    private var drainDeadline: Date?
    private var incomplete = false
    private var eofCount = 0

    func recordIncomplete() { incomplete = true }
    func recordEOF() { eofCount += 1 }
    /// No EOF proof is incomplete, even if retained/redacted output is short.
    func outputComplete() -> Bool { !incomplete && eofCount == 2 }

    func beginFinalDrain(gracePeriod: TimeInterval) {
        if drainDeadline == nil {
            drainDeadline = Date().addingTimeInterval(gracePeriod)
        }
    }

    func drainExpired() -> Bool {
        guard let drainDeadline else { return false }
        return Date() >= drainDeadline
    }
}

final class SpawnedShell: Sendable {
    let pid: pid_t
    let stdout: FileHandle
    let stderr: FileHandle

    init(pid: pid_t, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.stdout = stdout
        self.stderr = stderr
    }
}

private struct POSIXSpawnError: LocalizedError {
    let errno: Int32

    var errorDescription: String? {
        String(cString: strerror(errno))
    }
}

private enum ShellWatchdogResult: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}


func pollShellExit(_ pid: pid_t) -> Int32? {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == pid {
        return status
    }
    if result < 0, errno == ECHILD {
        return 0
    }
    return nil
}

func reapShell(_ pid: pid_t, timeout: TimeInterval) async -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let status = pollShellExit(pid) {
            return status
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return pollShellExit(pid)
}

func shellTerminationTarget(pid: pid_t, groupExists: Bool) -> pid_t? {
    guard pid > 0, groupExists else { return nil }
    return -pid
}

func terminateShell(_ pid: pid_t, force: Bool) {
    let signal = force ? SIGKILL : SIGTERM
    // POSIX_SPAWN_SETPGROUP makes pid the process-group ID before exec.
    // Once waitpid reaps the leader, its positive PID may be reused. Only the
    // still-owned private group may receive a signal; a missing group has no
    // safe positive-PID fallback.
    let groupExists = pid > 0 && kill(-pid, 0) == 0
    if let target = shellTerminationTarget(pid: pid, groupExists: groupExists) {
        _ = kill(target, signal)
    }
}

func shellExitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 {
        return (status >> 8) & 0xff
    }
    if signal != 0x7f {
        return 128 + signal
    }
    return status
}

func readPipeData(
    _ handle: FileHandle,
    maxBytes: Int,
    lifetime: ShellPipeReaderLifetime,
    onChunk: (@Sendable (Data) -> Void)? = nil
) async -> Data {
    var data = Data()
    let readDescriptor = handle.fileDescriptor
    // The queued poll borrows this descriptor. Keep its original FileHandle
    // alive until that poll returns; closing remains the reader task's duty.
    defer { withExtendedLifetime(handle) {} }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        if Task.isCancelled { await lifetime.recordIncomplete(); return data }
        if await lifetime.drainExpired() { await lifetime.recordIncomplete(); return data }
        let polled: (ready: Int32, error: Int32) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var descriptor = pollfd(fd: readDescriptor,
                    events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                let error = errno
                continuation.resume(returning: (ready, error))
            }
        }
        if polled.ready < 0 {
            if polled.error == EINTR { continue }
            await lifetime.recordIncomplete()
            return data
        }
        if polled.ready == 0 { continue }
        if Task.isCancelled { await lifetime.recordIncomplete(); return data }
        // There is one reader for this descriptor. A POSIX read after poll
        // consumes available bytes without waiting to fill a 64KiB request,
        // so cancellation and the final-drain deadline remain observable.
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count == 0 { await lifetime.recordEOF(); return data }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            await lifetime.recordIncomplete()
            return data
        }
        if count > max(0, maxBytes - data.count) { await lifetime.recordIncomplete() }
        onChunk?(Data(buffer.prefix(count)))
        if data.count < maxBytes {
            data.append(contentsOf: buffer.prefix(min(count, maxBytes - data.count)))
        }
    }
}

/// All builtin writers share physical-path serialization, including different
/// executor instances and symlink aliases. This grants no filesystem authority.
actor ToolFileMutationSerialiser {
    static let shared = ToolFileMutationSerialiser()
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Bool, any Error>
    }
    private var owners: [String: UUID] = [:]
    private var queues: [String: [Waiter]] = [:]

    func waitingCount(key: String) -> Int { queues[key]?.count ?? 0 }
    func owns(key: String, token: UUID) -> Bool { owners[key] == token }

    func acquire(key: String, token: UUID) async throws -> Bool {
        try Task.checkCancellation()
        if owners[key] == nil { owners[key] = token; return false }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                queues[key, default: []].append(Waiter(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, token: token) }
        }
    }

    private func cancelWaiter(key: String, token: UUID) {
        guard let index = queues[key]?.firstIndex(where: { $0.token == token }),
              let waiter = queues[key]?.remove(at: index) else { return }
        if queues[key]?.isEmpty == true { queues.removeValue(forKey: key) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(key: String, token: UUID) {
        guard owners[key] == token else { return }
        if let waiter = queues[key]?.first {
            queues[key]?.removeFirst()
            if queues[key]?.isEmpty == true { queues.removeValue(forKey: key) }
            owners[key] = waiter.token
            waiter.continuation.resume(returning: true)
        } else { owners.removeValue(forKey: key) }
    }
}

/// Shared physical-file synchronization for product writers and checkpoint restore.
/// It grants no path or tool authority. The caller keeps its normal validators.
public enum ToolFileMutationScope {
    static func validateSingleLinkedTarget(_ physical: String) throws {
        var metadata = stat()
        let result = Darwin.lstat(physical, &metadata)
        if result == 0 {
            guard metadata.st_mode & S_IFMT != S_IFREG || metadata.st_nlink == 1 else {
                throw ToolExecutorError.writeFailed("目标文件有多个硬链接，暂不支持直接修改；请另存为独立文件后重试。")
            }
        } else if errno != ENOENT { throw ToolExecutorError.pathViolation(physical) }
    }

    private static func physicalTarget(_ path: URL) throws -> (String, String) {
        guard let physical = PolicyRuntimePathBoundary.canonicalPath(path.path) else {
            throw ToolExecutorError.pathViolation(path.path)
        }
        // Resolve only the stable queue key here. A competing owned writer
        // may be replacing this pathname; inspect mutable metadata only after
        // acquiring or proving ownership of that same queue key.
        return (physical, PolicyRuntimePathBoundary.foldedForPathComparison(physical))
    }

    private static func acquire(path: URL, receipt: ToolExecutionReceipt?,
                                approvalContext: ApprovalPresentationContext?) async throws -> ToolFileMutationLease {
        let (physical, key) = try physicalTarget(path)
        let token = UUID()
        _ = try await ToolFileMutationSerialiser.shared.acquire(key: key, token: token)
        do {
            try Task.checkCancellation()
            guard PolicyRuntimePathBoundary.canonicalPath(path.path) == physical else {
                throw ToolExecutorError.pathViolation(path.path)
            }
            try validateSingleLinkedTarget(physical)
            if let receipt { return ToolFileMutationLease(key: key, token: token, receipt: receipt) }
            if let approvalContext { return ToolFileMutationLease(key: key, token: token, approvalContext: approvalContext) }
            return ToolFileMutationLease(key: key, token: token)
        } catch {
            await ToolFileMutationSerialiser.shared.release(key: key, token: token)
            throw error
        }
    }

    /// Hold resources before approval, bound to the existing exact call context.
    /// There is no receipt or authorization until the ordinary pipeline mints one.
    public static func acquireForApproval(path: URL, context: ApprovalPresentationContext) async throws -> ToolFileMutationLease {
        let key = context.compositeKey
        let identity = context.executionIdentity
        guard key.isValid, identity.isValid,
              ["file_write", "file_edit", "file_delete"].contains(context.toolName),
              key.sessionID == identity.turn.sessionID, key.turnID == identity.turn.turnID,
              key.messageID == identity.turn.messageID, key.operationID == identity.operationID,
              key.attemptNumber == identity.attempt else {
            throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
        }
        return try await acquire(path: path, receipt: nil, approvalContext: context)
    }

    public static func release(_ lease: ToolFileMutationLease) async {
        lease.invalidate()
        // A timeout may have returned while the actual builtin still exits.
        // Keep the resource owned until that already-borrowed operation ends.
        await lease.waitForBuiltinExit()
        await ToolFileMutationSerialiser.shared.release(key: lease.key, token: lease.token)
    }

    public static func borrowRecordingIfOwned(path: URL, receipt: ToolExecutionReceipt) async throws -> Bool {
        let (physical, key) = try physicalTarget(path)
        guard let outer = ToolFileMutationLease.current, outer.key == key else { return false }
        if outer.hasSameCallKey(receipt), !outer.matchesCall(receipt) {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        guard outer.matchesCall(receipt) else { return false }
        guard await ToolFileMutationSerialiser.shared.owns(key: key, token: outer.token) else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        try validateSingleLinkedTarget(physical)
        guard outer.claimRecordingUse(key: key, receipt: receipt) else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        return true
    }

    public static func withLock<T: Sendable>(
        path: URL, receipt: ToolExecutionReceipt? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let (physical, key) = try physicalTarget(path)
        if let receipt, let outer = ToolFileMutationLease.current, outer.key == key,
           outer.hasSameCallKey(receipt), !outer.matchesCall(receipt) {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        // Composer may enter after the real receipt is minted while the
        // AgentLoop still owns this exact call's pre-approval resource lock.
        if let receipt, let outer = ToolFileMutationLease.current,
           outer.key == key, outer.matchesCall(receipt) {
            guard await ToolFileMutationSerialiser.shared.owns(key: key, token: outer.token) else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            try validateSingleLinkedTarget(physical)
            guard outer.claimAuthorizationUse(key: key, receipt: receipt) else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            return try await operation()
        }
        let lease = try await acquire(path: path, receipt: receipt, approvalContext: nil)
        do {
            let result = try await ToolFileMutationLease.$current.withValue(lease) { try await operation() }
            await release(lease)
            return result
        } catch {
            await release(lease)
            throw error
        }
    }
}

/// Streaming count for write before-images; retains at most one UTF-8 scalar.
private struct ApprovalUTF8LineCounter {
    private var carry = Data()
    private var valid = true
    private var lines = 0
    private var hasText = false
    private var endsInNewline = false
    private var previousCR = false

    mutating func consume(_ data: Data) {
        guard valid else { return }
        carry.append(data)
        var decoded: String?
        var suffix = 0
        for omitted in 0...min(3, carry.count) {
            if let text = String(data: carry.dropLast(omitted), encoding: .utf8) {
                decoded = text; suffix = omitted; break
            }
        }
        guard let decoded, !decoded.contains("\0") else { valid = false; carry.removeAll(); return }
        carry = Data(carry.suffix(suffix))
        for scalar in decoded.unicodeScalars {
            hasText = true
            let newline = [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(scalar.value)
            if newline && !(scalar.value == 10 && previousCR) { lines += 1 }
            endsInNewline = newline
            previousCR = scalar.value == 13
        }
    }

    mutating func finish() -> Int? {
        guard valid, carry.isEmpty else { return nil }
        return hasText ? lines + (endsInNewline ? 0 : 1) : 0
    }
}
