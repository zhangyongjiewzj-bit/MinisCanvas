import Foundation

// MARK: - Tool Invocation & Result

/// A single tool call to execute, matching the shape the agent loop already
/// parses out of model responses (`AgentLoop.ParsedToolCall`).
/// (`[String: Any]` blocks automatic Sendable synthesis — same `@unchecked`
/// convention as `AgentContentPart` / `ParsedToolCall` in this module.)
public struct ToolInvocation: @unchecked Sendable {
    public let id: String
    public let name: String
    public let input: [String: Any]

    public init(id: String = "", name: String, input: [String: Any] = [:]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Outcome of one tool execution. `output` is non-nil on success; `errorMessage`
/// is non-nil on failure. Exactly one of the two is set.
public struct ToolRunResult: Sendable {
    /// Index of the invocation in the original input array (for re-ordering).
    public let index: Int
    public let invocation: ToolInvocation
    public let output: String?
    public let errorMessage: String?
    /// Measured monotonic execution interval in nanoseconds, recorded from the
    /// instant just before the executor race starts until its terminal state
    /// (success, executor failure, timeout, or mid-execution cancellation).
    ///
    /// This is the processing duration, not "time since some earlier event":
    /// invocations that never started executing (duplicate-identity rejection,
    /// stale child boundary, cancellation before dispatch, rejection before the
    /// executor ran) carry `nil` so downstream projection keeps rendering
    /// 「耗时 未记录」 instead of a fabricated zero.
    public let executionElapsedNanoseconds: UInt64?
    /// Retain typed control-flow failures for the owning loop; display callers
    /// keep using the bounded errorMessage projection.
    public let underlyingError: (any Error)?

    public init(
        index: Int,
        invocation: ToolInvocation,
        output: String?,
        errorMessage: String?,
        executionElapsedNanoseconds: UInt64? = nil,
        underlyingError: (any Error)? = nil
    ) {
        self.index = index
        self.invocation = invocation
        self.output = output
        self.errorMessage = errorMessage
        self.executionElapsedNanoseconds = executionElapsedNanoseconds
        self.underlyingError = underlyingError
    }

    /// Truncated millisecond view of the measured execution interval for
    /// consumers that project `elapsedMilliseconds`. `nil` stays `nil`.
    public var elapsedMilliseconds: Int? {
        executionElapsedNanoseconds.map { Int($0 / 1_000_000) }
    }

    public var isSuccess: Bool { output != nil }

    /// Canonical invocation identity used by downstream terminal consumers.
    ///
    /// Model-provided IDs are trimmed before comparison. Legacy callers that
    /// omit an ID still receive a deterministic per-batch identity, while two
    /// explicit calls with the same ID are rejected before either effect runs.
    public var invocationIdentity: String {
        let trimmed = invocation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "index:\(index)" : trimmed
    }

    /// The one terminal state represented by this result. Cancellation is
    /// distinct from an executor failure so lifecycle consumers can preserve
    /// the user-visible terminal reason without guessing from output text.
    public var terminalStatus: ToolExecutionStatus {
        if output != nil { return .succeeded }
        if errorMessage == "cancelled" { return .cancelled }
        return .failed
    }

    /// A result is publishable only when exactly one terminal payload exists.
    public var hasExactlyOneTerminalPayload: Bool {
        (output != nil) != (errorMessage != nil)
    }
}

// MARK: - Concurrency Gate

/// A missing receipt is one legacy owner: it still shares the configured cap,
/// but cannot enter while a canonical execution has a physical task in flight.
private enum ToolPhysicalOwner: Equatable, Sendable {
    case execution(AgentExecutionIdentity)
    case unbound

    init(_ identity: AgentExecutionIdentity?) {
        if let identity, identity.isValid {
            self = .execution(identity)
        } else {
            self = .unbound
        }
    }
}

/// The configured permit count applies within one execution identity. A new
/// identity waits for every physical executor task of the current owner to
/// finish, including tasks whose outward call already timed out.
private actor ConcurrencyGate {
    private struct Waiter {
        let id: UUID
        let owner: ToolPhysicalOwner
        let continuation: CheckedContinuation<Void, Error>
    }
    private let permits: Int
    private var holders = 0
    private var activeOwner: ToolPhysicalOwner?
    private var waiters: [Waiter] = []

    var waitingCount: Int { waiters.count }

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    func acquire(owner: ToolPhysicalOwner) async throws {
        try Task.checkCancellation()
        if holders < permits && waiters.isEmpty &&
            (activeOwner == nil || activeOwner == owner) {
            activeOwner = owner
            holders += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation may arrive before the actor enqueues this waiter.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, owner: owner, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        dispatchWaiters()
    }

    nonisolated func scheduleRelease(owner: ToolPhysicalOwner) {
        Task.detached { await self.release(owner: owner) }
    }

    private func release(owner: ToolPhysicalOwner) {
        precondition(activeOwner == owner && holders > 0)
        holders -= 1
        if holders == 0 { activeOwner = nil }
        dispatchWaiters()
    }

    private func dispatchWaiters() {
        while holders < permits, let next = waiters.first,
              activeOwner == nil || activeOwner == next.owner {
            activeOwner = next.owner
            holders += 1
            waiters.removeFirst().continuation.resume()
        }
    }
}

// MARK: - Concurrent Tool Runner

/// Executes a batch of tool calls concurrently, bounded by a configurable
/// concurrency cap (default 4).
///
/// Concurrency concept reference: OpenMinis `AIChatViewModel+ConcurrentTools`.
/// This runner uses this project's ConcurrencyGate, execution owners and timeout settlement:
/// - All invocations are dispatched through a `TaskGroup`, each inside a
///   `ConcurrencyGate` that limits simultaneous in-flight executions.
/// - A failing tool is recorded as an error result and NEVER blocks or cancels
///   its siblings — the batch always completes every invocation.
/// - Results are returned in the original invocation order (Anthropic requires
///   `tool_result` order to mirror `tool_use` order), regardless of completion
///   order.
public struct ConcurrentToolRunner: Sendable {

    /// Maximum number of tools executing at the same time. Defaults to 4.
    public var maxConcurrent: Int

    /// 跨调用持久的并发门（F6-fix：原实现每次 run() 新建批内私有门，
    /// 单调用包装器（ConcurrentToolLimitingExecutor 每次传 1 元素批）批间
    /// 零限制，并发上限形同虚设。actor 为引用语义，随 runner 存活，
    /// 批内限流语义不变，批间/跨调用限流真实生效）。
    private let gate: ConcurrencyGate

    public init(maxConcurrent: Int = 4) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.gate = ConcurrencyGate(permits: self.maxConcurrent)
    }

    /// Internal read-only observation of the shared queue; never alters permits.
    internal var queuedInvocationCount: Int {
        get async { await gate.waitingCount }
    }

    /// Execute `invocations` concurrently via `executor`.
    ///
    /// - Returns: one `ToolRunResult` per input invocation, in input order.
    public func run(
        _ invocations: [ToolInvocation],
        executor: any ToolExecutor,
        timeout: TimeInterval? = nil,
        childBoundary: AgentChildBoundary? = nil
    ) async -> [ToolRunResult] {
        await runInvocations(invocations, executor: executor, timeout: timeout,
            childBoundary: childBoundary, effects: nil, executionIdentity: nil)
    }

    /// The loop has already frozen each call's ordinary authorization and
    /// receipt. Only its effect is scheduled here; no authority is created.
    public func runPreparedEffects(
        _ invocations: [ToolInvocation], executor: any ToolExecutor,
        executionIdentity: AgentExecutionIdentity?,
        effects: [String: @Sendable () async throws -> String],
        childBoundary: AgentChildBoundary? = nil
    ) async -> [ToolRunResult] {
        await runInvocations(invocations, executor: executor, timeout: nil,
            childBoundary: childBoundary, effects: effects, executionIdentity: executionIdentity)
    }

    private func runInvocations(
        _ invocations: [ToolInvocation], executor: any ToolExecutor,
        timeout: TimeInterval?, childBoundary: AgentChildBoundary?,
        effects: [String: @Sendable () async throws -> String]?,
        executionIdentity: AgentExecutionIdentity?
    ) async -> [ToolRunResult] {
        guard !invocations.isEmpty else { return [] }

        let indexed = Array(invocations.enumerated())

        // A duplicate explicit invocation ID makes the effect winner
        // ambiguous. Reject every member of that identity group before any
        // executor call, while allowing independently identified calls to
        // retain their normal failure isolation.
        let duplicateIndexes: Set<Int> = {
            var firstIndexByIdentity: [String: Int] = [:]
            var duplicates = Set<Int>()
            for (index, invocation) in indexed {
                let identity = invocation.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !identity.isEmpty else { continue }
                if let firstIndex = firstIndexByIdentity[identity] {
                    duplicates.insert(firstIndex)
                    duplicates.insert(index)
                } else {
                    firstIndexByIdentity[identity] = index
                }
            }
            return duplicates
        }()

        let effectiveTimeout = minTimeout(
            timeout,
            childBoundary?.remainingTimeout()
        )
        if let childBoundary {
            guard await childBoundary.receiptLedger.isRunning(
                identity: childBoundary.identity,
                attemptID: childBoundary.identity.generationID ?? childBoundary.identity.childTaskID
            ) else {
                return indexed.map {
                    ToolRunResult(
                        index: $0.offset,
                        invocation: $0.element,
                        output: nil,
                        errorMessage: AgentChildLifecycleError.staleReceipt.localizedDescription
                    )
                }
            }
        }

        if Task.isCancelled {
            return indexed.map {
                ToolRunResult(
                    index: $0.offset,
                    invocation: $0.element,
                    output: nil,
                    errorMessage: "cancelled", underlyingError: CancellationError()
                )
            }
        }

        // `ToolExecutor` is not Sendable-constrained; box it so child tasks can
        // capture it safely (same convention as `AgentContentPart`).
        final class ExecutorBox: @unchecked Sendable {
            let executor: any ToolExecutor
            init(_ executor: any ToolExecutor) { self.executor = executor }
        }
        let box = ExecutorBox(executor)
        let gate = self.gate // F6-fix：用持久门（跨调用限流），不再批内新建
        let physicalOwner = ToolPhysicalOwner(
            executionIdentity ?? ToolExecutionReceiptContext.current?.executionIdentity
        )
        var results: [ToolRunResult] = []
        results.reserveCapacity(indexed.count)

        await withTaskGroup(of: ToolRunResult.self) { group in
            for (index, invocation) in indexed {
                group.addTask {
                    if duplicateIndexes.contains(index) {
                        let identity = invocation.id.trimmingCharacters(in: .whitespacesAndNewlines)
                        return ToolRunResult(
                            index: index,
                            invocation: invocation,
                            output: nil,
                            errorMessage: "duplicate invocation identity '\(identity)'"
                        )
                    }
                    do {
                        try await gate.acquire(owner: physicalOwner)
                        // Only an acquired permit is released. A cancelled
                        // queued waiter must neither free A's permit nor strand
                        // the next waiter. Cleanup survives child cancellation.
                        var permitTransferredToExecutor = false
                        defer {
                            if !permitTransferredToExecutor {
                                gate.scheduleRelease(owner: physicalOwner)
                            }
                        }
                        if let childBoundary {
                            try await childBoundary.check()
                            guard childBoundary.allowsTool(invocation.name) else {
                                throw ToolExecutorError.unknownTool(invocation.name)
                            }
                        }
                        try Task.checkCancellation()
                        // Execution starts here. From this line on, every
                        // terminal path below reports the measured interval;
                        // anything that throws before it stays `nil` because
                        // the tool never actually ran.
                        let executionStartedAtUptime = DispatchTime.now().uptimeNanoseconds
                        do {
                            // Always install the cancellation race. With no
                            // deadline this is still required to interrupt an
                            // executor that ignores cooperative cancellation.
                            // Outward timeout/cancellation does not prove that
                            // the actual executor stopped. It owns this permit
                            // until execute returns, including a late return.
                            permitTransferredToExecutor = true
                            let output = try await Self.executeWithTimeout(
                                invocation,
                                executor: box.executor,
                                timeout: effectiveTimeout,
                                childTimeout: childBoundary?.remainingTimeout(),
                                gate: gate,
                                owner: physicalOwner,
                                effect: effects?[invocation.id]
                            )
                            if let childBoundary {
                                try await childBoundary.check()
                            }
                            return ToolRunResult(
                                index: index,
                                invocation: invocation,
                                output: output,
                                errorMessage: nil,
                                executionElapsedNanoseconds: Self.executionElapsedNanoseconds(
                                    sinceUptime: executionStartedAtUptime
                                )
                            )
                        } catch let error as CancellationError {
                            return ToolRunResult(
                                index: index,
                                invocation: invocation,
                                output: nil,
                                errorMessage: "cancelled",
                                executionElapsedNanoseconds: Self.executionElapsedNanoseconds(
                                    sinceUptime: executionStartedAtUptime
                                ), underlyingError: error
                            )
                        } catch {
                            return ToolRunResult(
                                index: index,
                                invocation: invocation,
                                output: nil,
                                errorMessage: error.localizedDescription,
                                executionElapsedNanoseconds: Self.executionElapsedNanoseconds(
                                    sinceUptime: executionStartedAtUptime
                                ), underlyingError: error
                            )
                        }
                    } catch let error as CancellationError {
                        // Cancelled before the executor started: no measured
                        // processing duration exists.
                        return ToolRunResult(
                            index: index,
                            invocation: invocation,
                            output: nil,
                            errorMessage: "cancelled", underlyingError: error
                        )
                    } catch {
                        // Rejected before execution (stale boundary check or
                        // unknown tool): likewise no execution interval.
                        return ToolRunResult(
                            index: index,
                            invocation: invocation,
                            output: nil,
                            errorMessage: error.localizedDescription, underlyingError: error
                        )
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        // Merge back into original order.
        return results.sorted { $0.index < $1.index }
    }

    /// Elapsed nanoseconds on the project's existing monotonic uptime clock
    /// (`DispatchTime.uptimeNanoseconds`, same time source as the App-side
    /// budget telemetry). The clock never moves backwards, so the saturating
    /// guard only collapses a same-tick completion to a true 0 ns interval;
    /// it never manufactures duration for an execution that did not start.
    private static func executionElapsedNanoseconds(sinceUptime startedAt: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > startedAt ? now - startedAt : 0
    }

    private static func executeWithTimeout(
        _ invocation: ToolInvocation,
        executor: any ToolExecutor,
        timeout: TimeInterval?,
        childTimeout: TimeInterval?,
        gate: ConcurrencyGate,
        owner: ToolPhysicalOwner,
        effect: (@Sendable () async throws -> String)? = nil
    ) async throws -> String {
        final class ExecutorBox: @unchecked Sendable {
            let executor: any ToolExecutor
            init(_ executor: any ToolExecutor) { self.executor = executor }
        }
        let box = ExecutorBox(executor)
        let budget = ShellCommandTimeoutPolicy.budget(name: invocation.name, input: invocation.input,
            executor: executor, childTimeout: childTimeout)
        let race = ToolTimeoutRace()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard race.install(continuation) else {
                    // Cancellation won before any executor task was installed.
                    gate.scheduleRelease(owner: owner)
                    return
                }

                let executorTask = Task<Void, Never> {
                    defer { gate.scheduleRelease(owner: owner) }
                    do {
                        let result = try await ShellCommandTimeoutPolicy.$currentBudget.withValue(budget) {
                            if let effect { return try await effect() }
                            return try await box.executor.execute(name: invocation.name, input: invocation.input)
                        }
                        race.finish(.success(result))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                // Keep the deadline on a wall-clock dispatch queue so an
                // executor that ignores cancellation cannot starve the timer
                // behind Swift's cooperative task executor.
                let watchdogTask: ToolTimeoutWatchdog?
                if let budget {
                    watchdogTask = nil
                    budget.installDeadlineObserver { [weak budget] duration in
                        let timer = ToolTimeoutWatchdog(after: duration) {
                            race.finish(.failure(ToolExecutorError.toolTimeout("Command cleanup exceeded its bound")))
                        }
                        budget?.setTimerCancellation { timer.cancel() }
                    }
                } else {
                    watchdogTask = timeout.flatMap { timeout -> ToolTimeoutWatchdog? in
                        guard timeout > 0 else { return nil }
                        return ToolTimeoutWatchdog(after: timeout) {
                            race.finish(.failure(ToolExecutorError.toolTimeout("Tool '\(invocation.name)' timed out after \(timeout)s")))
                        }
                    }
                }
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
}

private final class ToolTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelTasks: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
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

    func finish(_ result: Result<String, Error>) {
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

private final class ToolTimeoutWatchdog: @unchecked Sendable {
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
