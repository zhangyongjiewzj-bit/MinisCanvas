import Foundation
import Testing
@testable import MinisCore

/// 可观察底层执行计数器：证明非法工具调用在到达 base 前被 Policy 层拒绝。
private final class CountingToolExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _executionCount = 0

    var executionCount: Int {
        lock.withLock { _executionCount }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { _executionCount += 1 }
        return "ok:\(name)"
    }
}

/// Suspend only the first real base entry. A regressed second admission returns
/// immediately, so the budget assertion fails instead of hanging behind a gate.
private actor PolicyBudgetEntryGate {
    private(set) var entries = 0
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async -> Int {
        entries += 1
        let entry = entries
        if entry == 1 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
                let waiters = firstEntryWaiters
                firstEntryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return entry
    }

    func waitForFirstEntry() async {
        if entries > 0 { return }
        await withCheckedContinuation { firstEntryWaiters.append($0) }
    }

    func releaseFirst() {
        let continuation = firstRelease
        firstRelease = nil
        continuation?.resume()
    }
}

enum PolicyBudgetFirstOutcome: Sendable {
    case success, failure, cooperativeCancellation
}

private enum PolicyBudgetFixtureError: Error { case syntheticFailure }

private final class GatedPolicyBudgetExecutor: ToolExecutor, Sendable {
    let gate = PolicyBudgetEntryGate()
    let firstOutcome: PolicyBudgetFirstOutcome

    init(firstOutcome: PolicyBudgetFirstOutcome = .success) {
        self.firstOutcome = firstOutcome
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        let entry = await gate.enter()
        if entry == 1 {
            switch firstOutcome {
            case .success: break
            case .failure: throw PolicyBudgetFixtureError.syntheticFailure
            case .cooperativeCancellation: try Task.checkCancellation()
            }
        }
        return "ok:\(name)"
    }
}

/// 动态 capability 解析器替身（生产路径由 BuiltinToolExecutor 提供 live MCP 注册表）。
private struct FakeCapabilityResolver: PolicyCapabilityResolving {
    let allowed: Set<String>
    func resolvesCapability(_ name: String) async throws -> Bool {
        allowed.contains(name)
    }
}

private func violation(of error: any Error) -> PolicyViolation? {
    guard let e = error as? PolicyEnforcedToolExecutorError,
          case .policyViolation(let v) = e else { return nil }
    return v
}

private final class PolicyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private var index = 0
    var onFirstRead: (() -> Void)?

    init(values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        let callback: (() -> Void)?
        let value: Date
        lock.lock()
        if index == 0 {
            callback = onFirstRead
        } else {
            callback = nil
        }
        value = values[min(index, values.count - 1)]
        index += 1
        lock.unlock()
        callback?()
        return value
    }
}

/// P3-G1：PolicyRuntime 进入生产 executor seam 的可观察执行测试。
/// 负例一律断言底层 executor 调用数为 0；正例断言恰好一次。
struct ProductionPolicyExecutionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func goal(
        allowed: Set<String> = ["file_read", "browser"],
        roots: [String] = ["/tmp/policy-work"],
        domains: Set<String> = ["example.com"],
        budget: Int = 10,
        deadline: Date? = nil,
        scopeID: String = "task:policy",
        concurrency: Int = 4
    ) -> GoalEnvelope {
        GoalEnvelope(
            scopeID: scopeID,
            allowedCapabilities: allowed,
            fileRoots: roots,
            networkDomains: domains,
            budget: budget,
            deadline: deadline ?? now.addingTimeInterval(3600),
            concurrencyLimit: concurrency,
            autonomyLevel: .l3,
            creatorID: "user:test",
            createdAt: now.addingTimeInterval(-1)
        )
    }

    private func lease(for g: GoalEnvelope, expiresAt: Date? = nil) -> AutonomyLease {
        AutonomyLease(
            goalID: g.goalID,
            scopeID: g.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: expiresAt ?? now.addingTimeInterval(60)
        )
    }

    private func defaultBuilder(domain: String? = nil, scope: String? = nil) -> @Sendable (String, [String: Any]) -> PolicyRequest {
        { name, input in
            PolicyRequest(
                capabilityID: name,
                scopeID: scope,
                filePath: input["path"] as? String,
                networkDomain: domain,
                estimatedCost: 1
            )
        }
    }

    // MARK: - 正例：合法调用恰好执行一次

    @Test func legalCallReachesBaseExactlyOnce() async throws {
        let base = CountingToolExecutor()
        let g = goal()
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            clock: { self.now }
        )
        let output = try await executor.execute(name: "file_read", input: ["path": "/tmp/policy-work/a.txt"])
        #expect(output == "ok:file_read")
        #expect(base.executionCount == 1)
        #expect(executor.acceptedExecutionCount == 1)
        #expect(executor.deniedExecutionCount == 0)
    }

    // MARK: - 负例：底层执行 = 0

    @Test func unknownCapabilityNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal(allowed: ["file_read"])
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.capabilityNotAllowed)) {
            _ = try await executor.execute(name: "shell_execute", input: [:])
        }
        #expect(base.executionCount == 0)
        #expect(executor.acceptedExecutionCount == 0)
        #expect(executor.deniedExecutionCount == 1)
    }

    @Test func missingLeaseFailsClosedWithoutBaseExecution() async {
        let base = CountingToolExecutor()
        let executor = PolicyEnforcedToolExecutor(base: base, goal: goal(), lease: nil, clock: { self.now })
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.invalidLease)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func expiredLeaseNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal()
        // 结构合法（issuedAt < expiresAt）但在 now 已过期。
        let expiredLease = AutonomyLease(
            goalID: g.goalID,
            scopeID: g.scopeID,
            issuedAt: now.addingTimeInterval(-2),
            expiresAt: now.addingTimeInterval(-1)
        )
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: expiredLease,
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.leaseExpired)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func revokedLeaseNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal()
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        executor.revokeLease()
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.leaseRevoked)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func revocationAfterInitialValidationNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal()
        let probe = PolicyTestClock(values: [now, now])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            clock: { probe.next() }
        )
        probe.onFirstRead = { executor.revokeLease() }

        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.leaseRevoked)) {
            _ = try await executor.execute(name: "file_read", input: ["path": "/tmp/policy-work/a.txt"])
        }
        #expect(base.executionCount == 0)
        #expect(executor.acceptedExecutionCount == 0)
        #expect(executor.deniedExecutionCount == 1)
    }

    @Test func expiryAtExecutionConsumptionBoundaryNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal()
        let probe = PolicyTestClock(values: [now, now.addingTimeInterval(61)])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            clock: { probe.next() }
        )

        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.leaseExpired)) {
            _ = try await executor.execute(name: "file_read", input: ["path": "/tmp/policy-work/a.txt"])
        }
        #expect(base.executionCount == 0)
        #expect(executor.acceptedExecutionCount == 0)
        #expect(executor.deniedExecutionCount == 1)
    }

    @Test func wrongScopeNeverReachesBase() async {
        let base = CountingToolExecutor()
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: goal(scopeID: "task:policy"),
            lease: lease(for: goal(scopeID: "task:policy")),
            requestBuilder: defaultBuilder(scope: "task:other"),
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.scopeMismatch)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func outOfBoundsPathNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal()
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed)) {
            _ = try await executor.execute(name: "file_read", input: ["path": "/tmp/other/secret.txt"])
        }
        #expect(base.executionCount == 0)
    }

    @Test func outOfBoundsDomainNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal(domains: ["example.com"])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            requestBuilder: defaultBuilder(domain: "evil.example.org"),
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
            _ = try await executor.execute(name: "browser", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func overBudgetNeverReachesBaseForExcessCall() async throws {
        let base = CountingToolExecutor()
        let g = goal(budget: 1)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        _ = try await executor.execute(name: "file_read", input: ["path": "/tmp/policy-work/a.txt"])
        #expect(base.executionCount == 1)
        do {
            _ = try await executor.execute(name: "file_read", input: ["path": "/tmp/policy-work/b.txt"])
            Issue.record("第二次调用应因预算耗尽被拒绝")
        } catch let error {
            #expect(violation(of: error) == .budgetExceeded)
        }
        #expect(base.executionCount == 1)
        #expect(executor.acceptedExecutionCount == 1)
    }

    @Test func inFlightBudgetRejectsTheSecondActualBaseEntry() async throws {
        let base = GatedPolicyBudgetExecutor()
        let g = goal(budget: 1, concurrency: 2)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        let first = Task { try await executor.execute(name: "file_read", input: [:]) }
        await base.gate.waitForFirstEntry()

        var rejection: PolicyViolation?
        do { _ = try await executor.execute(name: "file_read", input: [:]) }
        catch { rejection = violation(of: error) }
        let entriesWhileFirstIsHeld = await base.gate.entries
        #expect(rejection == .budgetExceeded)
        #expect(entriesWhileFirstIsHeld == 1)
        #expect(executor.acceptedExecutionCount == 1)
        #expect(executor.deniedExecutionCount == 1)

        await base.gate.releaseFirst()
        let firstOutput = try await first.value
        #expect(firstOutput == "ok:file_read")
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        let finalEntries = await base.gate.entries
        #expect(finalEntries == 1)
    }

    @Test(arguments: [PolicyBudgetFirstOutcome.failure, .cooperativeCancellation])
    func thrownActionReleasesItsReservationOnlyAfterItReturns(_ outcome: PolicyBudgetFirstOutcome) async throws {
        let base = GatedPolicyBudgetExecutor(firstOutcome: outcome)
        let g = goal(budget: 1, concurrency: 2)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        let first = Task { try await executor.execute(name: "file_read", input: [:]) }
        await base.gate.waitForFirstEntry()
        if case .cooperativeCancellation = outcome { first.cancel() }

        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        let heldEntries = await base.gate.entries
        #expect(heldEntries == 1)
        await base.gate.releaseFirst()
        switch await first.result {
        case .success: Issue.record("The first base action must report its configured failure")
        case .failure(let error):
            switch outcome {
            case .failure: #expect(error is PolicyBudgetFixtureError)
            case .cooperativeCancellation: #expect(error is CancellationError)
            case .success: Issue.record("Unexpected fixture outcome")
            }
        }

        // This is the existing successful-return cost contract, not a claim
        // that a thrown tool has made no external effect or incurred no charge.
        let retry = try await executor.execute(name: "file_read", input: [:])
        #expect(retry == "ok:file_read")
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        let finalEntries = await base.gate.entries
        #expect(finalEntries == 2)
        #expect(executor.acceptedExecutionCount == 2)
    }

    @Test func cancellationDoesNotRefundAnActionThatStillSucceeds() async throws {
        let base = GatedPolicyBudgetExecutor()
        let g = goal(budget: 1, concurrency: 2)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        let first = Task { try await executor.execute(name: "file_read", input: [:]) }
        await base.gate.waitForFirstEntry()
        first.cancel()
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        await base.gate.releaseFirst()
        let output = try await first.value
        #expect(output == "ok:file_read")
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        let finalEntries = await base.gate.entries
        #expect(finalEntries == 1)
        #expect(executor.acceptedExecutionCount == 1)
    }

    @Test func sufficientBudgetAllowsBothCallsBeforeTheFirstReturns() async throws {
        let base = GatedPolicyBudgetExecutor()
        let g = goal(budget: 2, concurrency: 2)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        let first = Task { try await executor.execute(name: "file_read", input: [:]) }
        await base.gate.waitForFirstEntry()
        let secondResult: Result<String, any Error>
        do { secondResult = .success(try await executor.execute(name: "file_read", input: [:])) }
        catch { secondResult = .failure(error) }
        let heldEntries = await base.gate.entries
        #expect(heldEntries == 2)
        await base.gate.releaseFirst()
        let firstOutput = try await first.value
        let second = try secondResult.get()
        #expect(second == "ok:file_read")
        #expect(firstOutput == "ok:file_read")
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.budgetExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(executor.acceptedExecutionCount == 2)
    }

    @Test func expiredDeadlineNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal(deadline: now.addingTimeInterval(-1))
        let executor = PolicyEnforcedToolExecutor(base: base, goal: g, lease: lease(for: g), clock: { self.now })
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.deadlineExceeded)) {
            _ = try await executor.execute(name: "file_read", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    // MARK: - 动态 capability（MCP live registry seam）

    @Test func resolverAuthorizedDynamicCapabilityExecutesOnce() async throws {
        let base = CountingToolExecutor()
        let g = goal(allowed: ["file_read"])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            capabilityResolver: FakeCapabilityResolver(allowed: ["mcp_echo"]),
            clock: { self.now }
        )
        let output = try await executor.execute(name: "mcp_echo", input: [:])
        #expect(output == "ok:mcp_echo")
        #expect(base.executionCount == 1)
        #expect(executor.acceptedExecutionCount == 1)
    }

    @Test func resolverRejectedDynamicCapabilityNeverReachesBase() async {
        let base = CountingToolExecutor()
        let g = goal(allowed: ["file_read"])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            capabilityResolver: FakeCapabilityResolver(allowed: []),
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.capabilityNotAllowed)) {
            _ = try await executor.execute(name: "mcp_echo", input: [:])
        }
        #expect(base.executionCount == 0)
    }

    @Test func productionRequestBuilderExtractsBrowserHost() {
        let request = PolicyEnforcedToolExecutor.productionRequestBuilder(
            BrowserTool.toolName,
            ["url": "https://evil.example.org/page"]
        )
        #expect(request.networkDomain == "evil.example.org")
    }

    @Test func productionRequestBuilderIgnoresNonBrowserOrUrlLessInput() {
        #expect(PolicyEnforcedToolExecutor.productionRequestBuilder("web_search", ["query": "天气"]).networkDomain == nil)
        #expect(PolicyEnforcedToolExecutor.productionRequestBuilder(BrowserTool.toolName, ["action": "screenshot"]).networkDomain == nil)
    }

    @Test func productionBuilderDeniesOutOfDomainBrowserBeforeBase() async {
        let base = CountingToolExecutor()
        let g = goal(domains: ["example.com"])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder,
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
            _ = try await executor.execute(name: BrowserTool.toolName, input: ["url": "https://evil.example.org/x"])
        }
        #expect(base.executionCount == 0)
    }

    @Test func productionBuilderAllowsInDomainBrowserOnce() async throws {
        let base = CountingToolExecutor()
        let g = goal(domains: ["example.com"])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder,
            clock: { self.now }
        )
        _ = try await executor.execute(name: BrowserTool.toolName, input: ["url": "https://www.example.com/x"])
        #expect(base.executionCount == 1)
    }

    @Test func productionBuilderFailsClosedWhenBrowserDomainsEmpty() async {
        let base = CountingToolExecutor()
        let g = goal(domains: [])
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: g,
            lease: lease(for: g),
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder,
            clock: { self.now }
        )
        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
            _ = try await executor.execute(name: BrowserTool.toolName, input: ["url": "https://example.com/x"])
        }
        #expect(base.executionCount == 0)
    }
}
