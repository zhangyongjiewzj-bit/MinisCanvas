import Foundation
import Testing
@testable import MinisCore

private final class M01PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolExecutionPhaseFact] = []

    func record(_ fact: ToolExecutionPhaseFact) {
        lock.lock()
        stored.append(fact)
        lock.unlock()
    }

    var phases: [ToolExecutionPhaseFact] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor M01ApprovalContextDelegate: ApprovalDelegate {
    private var observedKey: ToolExecutionCompositeKey?
    private var observedToolName: String?
    private var observedCallID: String?
    private var observedBoundRequest = false
    private let approves: Bool
    private var callOrder: [String] = []
    private let pauseAt: Int?
    private var held = false
    private var barrierCancelled = false
    private var heldDecision: CheckedContinuation<Bool, Never>?
    private var presentation: CheckedContinuation<Bool, Never>?
    init(approves: Bool = false, pauseAt: Int? = nil) { self.approves = approves; self.pauseAt = pauseAt }
    func approvalOrder() -> [String] { callOrder }
    func waitForHeldApproval() async -> Bool {
        if held { return true }
        if barrierCancelled { return false }
        return await withCheckedContinuation { presentation = $0 }
    }
    func cancelHeldApproval() {
        barrierCancelled = true
        heldDecision?.resume(returning: false); heldDecision = nil
        presentation?.resume(returning: false); presentation = nil
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        callOrder.append(request.callID)
        observedKey = ApprovalPresentationContext.current?.compositeKey
        observedToolName = ApprovalPresentationContext.current?.toolName
        observedCallID = request.callID
        observedBoundRequest = request.binding != nil
        if callOrder.count == pauseAt {
            held = true
            presentation?.resume(returning: true); presentation = nil
            let approved = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if barrierCancelled { continuation.resume(returning: false) }
                    else { heldDecision = continuation }
                }
            }, onCancel: { Task { await self.cancelHeldApproval() } }, isolation: self)
            return ApprovalDecision(approved: approved, confirmed: approved,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        // A delegate decision is not evidence that the UI presented pending.
        return approves ? ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest) : .deny
    }

    func observation() -> (ToolExecutionCompositeKey?, String?, String?, Bool) {
        (observedKey, observedToolName, observedCallID, observedBoundRequest)
    }
}

private actor M01PresentedComposerDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        // A synthetic UI accepts the request as pending only after its typed
        // identity matches the scoped call. AgentLoop itself never emits this.
        if let context = ApprovalPresentationContext.current,
           let presented = context.makeFact(for: request, stage: .presented) {
            context.eventSink(presented)
        }
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor M01UnexecutedComposerBase: ToolExecutor {
    private var count = 0

    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        await recordExecution()
        return "unexpected-base-effect"
    }

    private func recordExecution() {
        count += 1
    }

    var executionCount: Int { count }
}

private final class M01ApprovalFactRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ApprovalLifecycleFact] = []

    func record(_ fact: ApprovalLifecycleFact) {
        lock.lock()
        stored.append(fact)
        lock.unlock()
    }

    var facts: [ApprovalLifecycleFact] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct M01SyntheticToolExecutor: ToolExecutor {
    let shouldFail: Bool

    func execute(name: String, input: [String: Any]) async throws -> String {
        if shouldFail {
            throw ToolExecutorError.fileNotFound("private-path-should-not-enter-phase")
        }
        return "synthetic-result-should-not-enter-phase"
    }
}

/// N-15 regression draft: timing surrounds the real constrained Builtin
/// executor. It never supplies tool output or mints a receipt/fact itself.
private final class M01BoundedBuiltinBatchAdapter: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    struct Interval { let start: UInt64; let end: UInt64 }
    let base: BuiltinToolExecutor
    let delays: [String: Duration]
    let route: (any BuiltinOwnerBoundToolExecutor)?
    let noncooperativeDelays: Set<String>
    private let lock = NSLock()
    private var starts: [String: UInt64] = [:]
    private var finished: [String: Interval] = [:]
    init(base: BuiltinToolExecutor, delays: [String: Duration],
         route: (any BuiltinOwnerBoundToolExecutor)? = nil,
         noncooperativeDelays: Set<String> = []) {
        self.base = base; self.delays = delays; self.route = route
        self.noncooperativeDelays = noncooperativeDelays
    }
    var currentBuiltinOwner: BuiltinToolExecutor? { base }
    func executeBoundToBuiltinOwner(_ owner: BuiltinToolExecutor, name: String,
                                   input: [String: Any]) async throws -> String {
        guard owner === base else { throw ToolExecutorError.invalidParameter("builtin_owner_changed") }
        return try await execute(name: name, input: input)
    }
    var intervals: [String: Interval] { lock.withLock { finished } }
    private func begin(_ id: String) {
        lock.withLock { starts[id] = DispatchTime.now().uptimeNanoseconds }
    }
    private func end(_ id: String) {
        lock.withLock {
            if let start = starts[id] {
                finished[id] = Interval(start: start, end: DispatchTime.now().uptimeNanoseconds)
            }
        }
    }
    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let receipt = ToolExecutionReceiptContext.current else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        let id = receipt.toolCallID
        begin(id)
        defer { end(id) }
        if let delay = delays[id] {
            if noncooperativeDelays.contains(id) {
                // A finite test-only late body. The actual owner's task awaits
                // it, so it cannot outlive that owner's physical drain.
                try await Task.detached { try await Task.sleep(for: delay) }.value
            } else { try await Task.sleep(for: delay) }
        }
        try Task.checkCancellation()
        if let route {
            guard route.currentBuiltinOwner === base else { throw ToolExecutorError.resourceScopeInvalid }
            return try await route.executeBoundToBuiltinOwner(base, name: name, input: input)
        }
        return try await base.execute(name: name, input: input)
    }
}

@Suite("M01 tool lifecycle producer")
struct P3AcceptanceM01ToolLifecyclePhaseTests {
    // N-15 draft, UNRUN against the serial 02c baseline. The overlap/max
    // assertions are necessary counterexamples, not recorded runtime failures.
    @Test func sameResponseRealReadsOverlapAndCostTheSlowestCall() async throws {
        try await exerciseReadCohort(searchMix: false)
    }

    @Test func canonicalFileReadGrepAndGlobOverlapInOneResponse() async throws {
        try await exerciseReadCohort(searchMix: true)
    }

    @Test func realReadsRespectTheExistingPolicyConcurrencyCeiling() async throws {
        try await exerciseReadCohort(searchMix: false, policyConcurrency: 1)
    }

    private func exerciseReadCohort(searchMix: Bool, policyConcurrency: Int? = nil) async throws {
        let root = try minisCoreToolContractRoot("n15-real-read-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("read.txt")
        try "N15 owned read".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let base = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let executor = M01BoundedBuiltinBatchAdapter(base: base,
            delays: ["n15-a": .milliseconds(300), "n15-b": .milliseconds(400), "n15-c": .milliseconds(500)])
        let calls: [[String: Any]] = searchMix ? [
            ["id": "n15-a", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-b", "name": "file_grep", "input": ["path": root.path, "pattern": "N15 owned read"]],
            ["id": "n15-c", "name": "file_glob", "input": ["path": root.path, "pattern": "read.txt"]]
        ] : ["n15-a", "n15-b", "n15-c"].map {
            ["id": $0, "name": "file_read", "input": ["path": path.path]]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "done"])
        let phases = M01PhaseRecorder()
        let runtime: PolicyRuntimeBinding? = policyConcurrency.map { limit in
            let now = Date()
            let goal = GoalEnvelope(scopeID: "n15-policy-read-ceiling", allowedCapabilities: ["file_read"],
                fileRoots: [root.path], budget: 100, deadline: now.addingTimeInterval(60),
                concurrencyLimit: limit, autonomyLevel: .l2, creatorID: "M01", createdAt: now)
            return PolicyRuntimeBinding(goal: goal,
                lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline))
        }
        var loop = AgentLoop(maxIterations: 2, loopDetector: nil, policyRuntime: runtime,
            toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phases.record($0) }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: executor, tools: minisCoreToolContractCatalog(searchMix ? ["file_read", "file_grep", "file_glob"] : ["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("n15-read-batch"))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let intervals = try ["n15-a", "n15-b", "n15-c"].map { try #require(executor.intervals[$0]) }
        for left in 0..<intervals.count {
            for right in (left + 1)..<intervals.count {
                if policyConcurrency == 1 {
                    #expect(intervals[left].end <= intervals[right].start)
                } else {
                    #expect(max(intervals[left].start, intervals[right].start)
                        < min(intervals[left].end, intervals[right].end))
                }
            }
        }
        let longest = try #require(intervals.map { Double($0.end - $0.start) / 1_000_000_000 }.max())
        // Fixed scheduling/IO allowance; no threshold ratchet to hide serialization.
        if policyConcurrency == nil { #expect(elapsed <= longest + 0.20) }
        #expect(result.toolExecutionFacts.count == 3)
        #expect(result.toolExecutionFacts.allSatisfy { $0.status == .succeeded && $0.elapsedMilliseconds != nil })
        #expect(phases.phases.filter { $0.phase == .running }.count == 3)
        let history = try #require(provider.receivedHistory.last?.last?.content.data(using: .utf8))
        let outputs = try #require(JSONSerialization.jsonObject(with: history) as? [[String: Any]])
        #expect(outputs.compactMap { $0["tool_use_id"] as? String } == ["n15-a", "n15-b", "n15-c"])
        #expect((outputs[0]["content"] as? String)?.contains("N15 owned read") == true)
        #expect((outputs[1]["content"] as? String)?.contains("N15 owned read") == true)
        #expect((outputs[2]["content"] as? String)?.contains(searchMix ? "read.txt" : "N15 owned read") == true)
    }

    @Test func sameResponseWriteIsABarrierAndApprovalsAndResultsKeepInputOrder() async throws {
        let root = try minisCoreToolContractRoot("n15-real-write-barrier")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("barrier.txt")
        try "N15 BEFORE".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let identity = minisCoreToolContractIdentity("n15-write-barrier")
        let delegate = M01ApprovalContextDelegate(approves: true)
        let executor = M01BoundedBuiltinBatchAdapter(
            base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            delays: ["n15-before-a": .milliseconds(200), "n15-before-b": .milliseconds(200),
                     "n15-write": .milliseconds(50), "n15-middle": .milliseconds(100),
                     "n15-write-two": .milliseconds(50), "n15-after": .milliseconds(200)])
        let calls: [[String: Any]] = [
            ["id": "n15-before-a", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-before-b", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-write", "name": "file_write", "input": ["path": path.path, "content": "N15 MIDDLE"]],
            ["id": "n15-middle", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-write-two", "name": "file_write", "input": ["path": path.path, "content": "N15 AFTER"]],
            ["id": "n15-after", "name": "file_read", "input": ["path": path.path]]]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "done"])
        let loop = AgentLoop(maxIterations: 2,
            approvalGate: m01ReadsAskingGate(delegate: delegate),
            turnController: TurnController(), loopDetector: nil, timeout: 30, toolExecutionFactLedger: ledger)
        let result = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read", "file_write"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                taskID: "task:n15-write-barrier", actorID: "synthetic"),
            executionIdentity: identity)
        let a = try #require(executor.intervals["n15-before-a"])
        let b = try #require(executor.intervals["n15-before-b"])
        let write = try #require(executor.intervals["n15-write"])
        let middle = try #require(executor.intervals["n15-middle"])
        let writeTwo = try #require(executor.intervals["n15-write-two"])
        let after = try #require(executor.intervals["n15-after"])
        #expect(max(a.start, b.start) < min(a.end, b.end))
        #expect(max(a.end, b.end) <= write.start && write.end <= middle.start)
        #expect(middle.end <= writeTwo.start && writeTwo.end <= after.start)
        #expect(write.end <= writeTwo.start)
        #expect(await delegate.approvalOrder() == ["n15-before-a", "n15-before-b", "n15-write", "n15-middle", "n15-write-two", "n15-after"])
        #expect(result.toolExecutionFacts.count == 6 && result.toolExecutionFacts.allSatisfy { $0.status == .succeeded })
        #expect(try String(contentsOf: path, encoding: .utf8) == "N15 AFTER")
        let history = try #require(provider.receivedHistory.last?.last?.content.data(using: .utf8))
        let outputs = try #require(JSONSerialization.jsonObject(with: history) as? [[String: Any]])
        #expect(outputs.compactMap { $0["tool_use_id"] as? String } == ["n15-before-a", "n15-before-b", "n15-write", "n15-middle", "n15-write-two", "n15-after"])
        #expect((outputs[0]["content"] as? String)?.contains("N15 BEFORE") == true)
        #expect((outputs[1]["content"] as? String)?.contains("N15 BEFORE") == true)
        #expect((outputs[3]["content"] as? String)?.contains("N15 MIDDLE") == true)
        #expect((outputs[5]["content"] as? String)?.contains("N15 AFTER") == true)
    }

    @Test func sameResponseReadCohortCannotWidenTheRealBuiltinBoundary() async throws {
        let root = try minisCoreToolContractRoot("n15-read-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        let allowedPath = root.appendingPathComponent("allowed.txt")
        let deniedPath = denied.appendingPathComponent("private.txt")
        try "N15 allowed".write(to: allowedPath, atomically: true, encoding: .utf8)
        try "N15 PRIVATE".write(to: deniedPath, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let executor = M01BoundedBuiltinBatchAdapter(
            base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: [denied]), delays: [:])
        let calls: [[String: Any]] = [
            ["id": "n15-allowed", "name": "file_read", "input": ["path": allowedPath.path]],
            ["id": "n15-denied", "name": "file_read", "input": ["path": deniedPath.path]]]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "done"])
        let loop = AgentLoop(maxIterations: 2, loopDetector: nil, toolExecutionFactLedger: ledger)
        let result = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("n15-denied-read"))
        #expect(result.toolExecutionFacts.first { $0.toolCallID == "n15-allowed" }?.status == .succeeded)
        #expect(result.toolExecutionFacts.first { $0.toolCallID == "n15-denied" }?.status == .failed)
        let continuedHistory = try #require(provider.receivedHistory.last)
        #expect(!continuedHistory.contains { $0.content.contains("N15 PRIVATE") })
        #expect(try String(contentsOf: deniedPath, encoding: .utf8) == "N15 PRIVATE")
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func stopDuringReadCohortCannotCrossTheFollowingWriteBarrier() async throws {
        let root = try minisCoreToolContractRoot("n15-stop-barrier")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("unchanged.txt")
        try "N15 unchanged".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let controller = TurnController()
        let identity = minisCoreToolContractIdentity("n15-stop-batch")
        let delegate = M01ApprovalContextDelegate(approves: true)
        let executor = M01BoundedBuiltinBatchAdapter(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            delays: ["n15-stop-a": .milliseconds(200), "n15-stop-b": .milliseconds(200)])
        let calls: [[String: Any]] = [
            ["id": "n15-stop-a", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-stop-b", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-no-write", "name": "file_write", "input": ["path": path.path, "content": "must not happen"]]]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "must not request again"])
        let phases = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2,
            approvalGate: m01ReadsAskingGate(delegate: delegate),
            turnController: controller, loopDetector: nil, timeout: 30, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phase in
            phases.record(phase)
            if phase.phase == .running, phase.toolName == "file_read" {
                Task { await controller.interrupt() }
            }
        }
        do {
            _ = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read", "file_write"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                    taskID: "task:n15-stop-batch", actorID: "synthetic"),
                executionIdentity: identity)
            Issue.record("stopped batch must not complete the model turn")
        } catch {
            #expect(error is InterruptedError || error is CancellationError)
        }
        let ownership = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
        await ownership.cancelAndDrainForApplicationExit()
        #expect(phases.phases.contains { $0.phase == .running && $0.toolName == "file_read" })
        #expect(!phases.phases.contains { $0.phase == .running && $0.toolName == "file_write" })
        #expect(try String(contentsOf: path, encoding: .utf8) == "N15 unchanged")
        #expect(provider.receivedHistory.count == 1)
        #expect(!ledger.facts.contains { $0.toolCallID == "n15-no-write" && $0.status == .succeeded })
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func cancellationWithSeveralPreparedReadsClosesEveryUnexecutedReceipt() async throws {
        let root = try minisCoreToolContractRoot("n15-pending-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("note.txt")
        try "N15 pending unchanged".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let identity = minisCoreToolContractIdentity("n15-pending-cancel")
        let delegate = M01ApprovalContextDelegate(approves: true, pauseAt: 3)
        let controller = TurnController()
        let executor = M01BoundedBuiltinBatchAdapter(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), delays: [:])
        let calls: [[String: Any]] = ["n15-ready-a", "n15-ready-b", "n15-waiting"].map {
            ["id": $0, "name": "file_read", "input": ["path": path.path]]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let response = String(decoding: payload, as: UTF8.self)
        let phases = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2, approvalGate: m01ReadsAskingGate(delegate: delegate),
            turnController: controller, loopDetector: nil, timeout: 30, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phases.record($0) }
        let executionLoop = loop
        let running = Task { @Sendable in
            // This non-Sendable scripted provider belongs to this task only.
            // Cross-task observations return immutable values after it stops.
            let provider = MockLLMProvider(responses: [response, "must not run"])
            let outcome: Result<AgentLoopResult, any Error>
            do {
                outcome = .success(try await executionLoop.run(messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read"]),
                    currentConversationID: identity.turn.sessionID,
                    parentIdentitySeed: ParentRuntimeIdentitySeed(
                        sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                        taskID: "task:n15-pending-cancel", actorID: "synthetic"),
                    executionIdentity: identity))
            } catch { outcome = .failure(error) }
            return (outcome: outcome, providerRequestCount: provider.receivedHistory.count)
        }
        // A bounded test deadline only; no production polling or controller.
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            running.cancel()
            await delegate.cancelHeldApproval()
        }
        defer { deadline.cancel() }
        let held = await delegate.waitForHeldApproval()
        #expect(held)
        #expect(ledger.pendingReceipts.count == 2)
        #expect(!phases.phases.contains { $0.phase == .running })
        running.cancel()
        await controller.interrupt()
        await delegate.cancelHeldApproval()
        let returned = await running.value
        switch returned.outcome {
        case .success: Issue.record("cancelled preparation must not complete the turn")
        case .failure(let error): #expect(error is CancellationError || error is InterruptedError)
        }
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(ledger.facts.count == 2 && ledger.facts.allSatisfy { $0.status == .cancelled && $0.elapsedMilliseconds == nil })
        #expect(executor.intervals.isEmpty)
        #expect(returned.providerRequestCount == 1)
        #expect(try String(contentsOf: path, encoding: .utf8) == "N15 pending unchanged")
    }

    @Test func actualProducedChildResultPagesJoinTheSameReadCohortWithoutAcknowledging() async throws {
        let root = try minisCoreToolContractRoot("n15-actual-child-result")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let session = try sessions.createSession(id: "n15-owned-parent")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(sessionID: session.id, conversationID: session.id,
            turnID: "turn-handle:\(handle.turnID)", taskID: "n15-producing-parent", actorID: "n15")
        let goal = GoalEnvelope(scopeID: "n15-result-scope", allowedCapabilities: ["file_read"],
            fileRoots: [root.path], networkDomains: [], budget: 100,
            deadline: Date().addingTimeInterval(60), concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "n15")
        let store = AgentTaskStore()
        let ledger = try minisCoreToolContractLedger(at: root)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let producer = AgentOrchestrator(maxIterationsPerTask: 1,
            provider: ScriptedChildProvider(responses: ["N15 actual produced child output"]),
            toolExecutor: owner, turnController: controller, currentConversationID: session.id,
            taskStore: store, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentGoal: goal,
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_read"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner)
        let reports = await producer.orchestrate(tasks: [SubAgentTask(id: "n15-produced-child",
            title: "result fixture", instructions: "return the owned output", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"], allowedReadRoots: [root.path]))],
            strategy: .sequential)
        let produced = try #require(reports.first?.result.output)
        let receipt = try #require(store.allReceipts().first)
        let locator = try #require(receipt.childResultEnvelope?.childTranscriptLocator)
        let receiptsBefore = store.allReceipts()
        await handle.finish()
        let path = root.appendingPathComponent("owned.txt")
        try "N15 owned read".write(to: path, atomically: true, encoding: .utf8)
        let route = OrchestrationCompositeToolExecutor(base: owner,
            orchestration: OrchestrationToolExecutor(orchestrator: producer))
        let executor = M01BoundedBuiltinBatchAdapter(base: owner,
            delays: ["n15-file": .milliseconds(200), "n15-result-a": .milliseconds(300), "n15-result-b": .milliseconds(400)],
            route: route)
        let resultInput: [String: Any] = ["task_id": locator.taskID, "parent_id": locator.parentID,
            "run_id": locator.runID, "attempt_id": locator.attemptID, "offset": 0]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": [
            ["id": "n15-file", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-result-a", "name": OrchestrationToolExecutor.resultToolName, "input": resultInput],
            ["id": "n15-result-b", "name": OrchestrationToolExecutor.resultToolName, "input": resultInput]]])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "done"])
        let seed = ParentRuntimeIdentitySeed(sessionID: session.id, conversationID: session.id,
            taskID: "n15-reader", actorID: "n15")
        let loop = AgentLoop(maxIterations: 2, turnController: TurnController(),
            loopDetector: nil, toolExecutionFactLedger: ledger)
        let outcome = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_read"]) + [OrchestrationToolExecutor.makeResultDefinition()],
            currentConversationID: session.id, parentIdentitySeed: seed,
            executionIdentity: minisCoreToolContractIdentity("n15-reader", sessionID: session.id, messageID: seed.taskID))
        #expect(outcome.toolExecutionFacts.count == 3 && outcome.toolExecutionFacts.allSatisfy { $0.status == .succeeded })
        let a = try #require(executor.intervals["n15-file"])
        let b = try #require(executor.intervals["n15-result-a"])
        let c = try #require(executor.intervals["n15-result-b"])
        #expect(max(a.start, max(b.start, c.start)) < min(a.end, min(b.end, c.end)))
        let feedback = try #require(provider.receivedHistory.last?.last?.content.data(using: .utf8))
        let parts = try #require(JSONSerialization.jsonObject(with: feedback) as? [[String: Any]])
        for index in [1, 2] {
            let body = try #require((parts[index]["content"] as? String)?.data(using: .utf8))
            let page = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(page["content"] as? String == produced)
        }
        #expect(store.allReceipts() == receiptsBefore)
    }

    @Test func parentRequestsAgainAfterProductionChildReturnsPartialAtIterationLimit() async throws {
        let root = try minisCoreToolContractRoot("o04-partial-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let session = try sessions.createSession(id: "o04-parent-session")
        let store = AgentTaskStore()
        let ledger = try minisCoreToolContractLedger(at: root)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let childPath = root.appendingPathComponent("child-only-argument.txt")
        try "child-only-tool-result".write(to: childPath, atomically: true, encoding: .utf8)
        let childCall = try JSONSerialization.data(withJSONObject: ["tool_calls": [
            ["id": "o04-child-read", "name": "file_read", "input": ["path": childPath.path]]
        ]])
        let childProvider = ScriptedChildProvider(responses: [String(decoding: childCall, as: UTF8.self)])
        let parentCall = try JSONSerialization.data(withJSONObject: ["tool_calls": [
            ["id": "o04-parent-orchestrate", "name": OrchestrationToolExecutor.toolName, "input": [
                "input_version": OrchestrationToolExecutor.inputVersion, "strategy": "sequential",
                "tasks": [["id": "o04-child", "title": "bounded child", "instructions": "Read once",
                           "required_capabilities": ["tools"], "allowed_tool_names": ["file_read"],
                           "allowed_read_roots": [root.path]]]
            ]]
        ]])
        let finalAnswer = "Parent answered after receiving the partial result"
        let parentProvider = ScriptedChildProvider(responses: [String(decoding: parentCall, as: UTF8.self), finalAnswer])
        let settings = AgentSettings.default
        let defaults = settings.policyRuntimeDefaults
        let policyCreatedAt = Date()
        // Match BridgeStore's factory Goal, including the default tool
        // concurrency ceiling. The former hand-written ceiling of one also
        // counted the waiting parent against its child's policy admission.
        let goal = GoalEnvelope(scopeID: "o04-partial-scope",
            allowedCapabilities: ["file_read", OrchestrationToolExecutor.toolName],
            fileRoots: [root.path], networkDomains: defaults.networkDomains, budget: defaults.budget,
            deadline: defaults.deadline(from: policyCreatedAt),
            concurrencyLimit: max(1, settings.concurrentToolLimit),
            autonomyLevel: defaults.autonomyLevel, creatorID: "o04", createdAt: policyCreatedAt)
        let executorReference = ToolExecutorReference(owner)
        let executor = OrchestrationCompositeToolExecutor(base: owner,
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator()),
            makeRuntimeOrchestrator: { context in
                let inheritedSnapshot = try #require(context.composerSnapshot)
                let inheritedFacts = try #require(context.composerPolicyFacts)
                return AgentOrchestrator(maxIterationsPerTask: 1, provider: childProvider,
                    toolExecutor: executorReference.value, approvalGate: context.approvalGate,
                    turnController: context.turnController, currentConversationID: context.currentConversationID,
                    taskStore: context.taskStore, sessionStore: sessions,
                    toolExecutionFactLedger: context.toolExecutionFactLedger,
                    parentBinding: context.parentBinding, parentRuntimeIdentity: context.parentRuntimeIdentity,
                    parentGoal: goal, parentTurnHandle: context.parentTurnHandle, runtimeMode: .production,
                    capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_read"]),
                    parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
                    parentComposerSnapshot: inheritedSnapshot,
                    parentComposerFacts: inheritedFacts,
                    parentAuthorityCheck: context.parentAuthorityCheck,
                    concreteBuiltinToolExecutorOwner: owner, requiresPolicyRuntime: true)
            })
        let seed = ParentRuntimeIdentitySeed(sessionID: session.id, conversationID: session.id,
            taskID: "o04-parent-task", actorID: "o04")
        let execution = minisCoreToolContractIdentity("o04-partial", sessionID: session.id, messageID: seed.taskID)
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: session.id, turnID: execution.turn.turnID, taskID: seed.taskID,
            attemptID: "\(execution.operationID):attempt:\(execution.attempt)",
            messageID: execution.turn.messageID, workspaceID: "o04-synthetic-workspace", createdAt: now,
            policyRevision: "o04-synthetic-policy", grantEpoch: "o04-synthetic-epoch", autonomyCeiling: goal.autonomyLevel)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read", OrchestrationToolExecutor.toolName],
            grantedCapabilities: ["file_read", OrchestrationToolExecutor.toolName],
            allowedWriteRoots: [root.path], workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision, grantEpoch: snapshot.grantEpoch,
            leaseID: "o04-synthetic-lease", expiresAt: goal.deadline, autonomyCeiling: goal.autonomyLevel)
        let policy = PolicyEnforcedToolExecutor(base: executor, goal: goal,
            lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: now, expiresAt: goal.deadline),
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        executorReference.value = policy
        let approvalGate = m01ReadsAskingGate(delegate: M01PresentedComposerDelegate())
        let composer = ComposerPolicyEnforcedToolExecutor(base: policy,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: approvalGate)
        let loop = AgentLoop(maxIterations: 2, approvalGate: approvalGate,
            turnController: TurnController(), loopDetector: nil, taskStore: store, toolExecutionFactLedger: ledger)
        let result = try await loop.run(messages: [], systemPrompt: nil, provider: parentProvider,
            toolExecutor: composer, tools: minisCoreToolContractCatalog(["file_read"]) + [OrchestrationToolExecutor.makeDefinition()],
            currentConversationID: session.id, parentIdentitySeed: seed, composerSnapshot: snapshot,
            parentAuthorityCheck: { true },
            executionIdentity: execution)

        #expect(childProvider.receivedRequests.count == 1)
        let receipt = try #require(store.allReceipts().first { $0.taskID == "o04-child" })
        let partial = try #require(receipt.childResultEnvelope)
        #expect(partial.isPartial && partial.output == "" && partial.error == nil)
        let locator = try #require(partial.childTranscriptLocator)
        #expect(ledger.facts.contains {
            $0.childTranscriptLocator == locator && $0.toolName == "file_read" && $0.status == .succeeded
        })
        #expect(parentProvider.receivedRequests.count == 2)
        let feedback = try #require(parentProvider.receivedRequests.last?.last?.content)
        let parts = try #require(JSONSerialization.jsonObject(with: Data(feedback.utf8)) as? [[String: Any]])
        let joined = try #require(parts.first { $0["tool_use_id"] as? String == "o04-parent-orchestrate" })
        let content = try #require(joined["content"] as? String)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let rows = try #require(summary["results"] as? [[String: Any]])
        let row = try #require(rows.first { $0["task_id"] as? String == partial.taskID })
        #expect(row["status"] as? String == "partial")
        #expect((row["output_ref"] as? [String: String])?["run_id"] == partial.runID)
        #expect(!content.contains("child-only-argument") && !content.contains("child-only-tool-result"))
        #expect(result.messages.last?.role == .assistant && result.messages.last?.content == finalAnswer)
        #expect(result.toolExecutionFacts.contains {
            $0.toolName == OrchestrationToolExecutor.toolName && $0.status == .failed
        })
        let parent = try #require(store.taskSnapshot(runID: partial.runID)?.parentRuntimeIdentity)
        #expect(store.parentTurnTerminalFact(parent: parent, execution: execution)?.outcome == .failed)
    }

    @Test func readCohortTimeoutReturnsLogicallyButKeepsTheOriginalPhysicalTail() async throws {
        let root = try minisCoreToolContractRoot("n15-timeout-tail")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("note.txt")
        try "N15 no later write".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let executor = M01BoundedBuiltinBatchAdapter(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            delays: ["n15-timeout-a": .milliseconds(500), "n15-timeout-b": .milliseconds(600)],
            noncooperativeDelays: ["n15-timeout-a", "n15-timeout-b"])
        let calls: [[String: Any]] = [
            ["id": "n15-timeout-a", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-timeout-b", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-forbidden-after-timeout", "name": "file_write", "input": ["path": path.path, "content": "wrong"]]]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "must not request"])
        let identity = minisCoreToolContractIdentity("n15-timeout-tail")
        let delegate = M01ApprovalContextDelegate(approves: true)
        let loop = AgentLoop(maxIterations: 2, approvalGate: m01ReadsAskingGate(delegate: delegate),
            turnController: TurnController(), loopDetector: nil, timeout: 0.05, toolExecutionFactLedger: ledger)
        var caught: (any Error)?
        do {
            _ = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read", "file_write"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                    taskID: "task:n15-timeout-tail", actorID: "synthetic"),
                executionIdentity: identity)
            Issue.record("read timeout must remain fatal to this model turn")
        } catch { caught = error }
        let owner = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
        let physicalStillPending = owner.hasPendingOperations
        await owner.cancelAndDrainForApplicationExit()
        #expect(physicalStillPending)
        if let typed = caught as? ToolExecutorError, case .toolTimeout = typed {} else { Issue.record("wrong typed timeout") }
        #expect(provider.receivedHistory.count == 1)
        #expect(await delegate.approvalOrder() == ["n15-timeout-a", "n15-timeout-b"])
        #expect(executor.intervals["n15-forbidden-after-timeout"] == nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == "N15 no later write")
        #expect(!owner.hasPendingOperations)
        #expect(executor.intervals.count == 2)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(ledger.facts.count == 2 && ledger.facts.allSatisfy { $0.status == .failed && $0.failureCategory == .timeout })
    }

    @Test func queuedReadCohortTimesOutBeforeThePreviousPhysicalTailRetires() async throws {
        let root = try minisCoreToolContractRoot("n15-queued-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("note.txt")
        try "N15 queue unchanged".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try minisCoreToolContractLedger(at: root)
        let executor = M01BoundedBuiltinBatchAdapter(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            delays: ["n15-old-tail": .milliseconds(800)], noncooperativeDelays: ["n15-old-tail"])
        let oldPayload = try JSONSerialization.data(withJSONObject: ["tool_calls": [
            ["id": "n15-old-tail", "name": "file_read", "input": ["path": path.path]]]])
        let oldProvider = MockLLMProvider(responses: [String(decoding: oldPayload, as: UTF8.self), "must not request"])
        var oldLoop = AgentLoop(maxIterations: 2, loopDetector: nil, timeout: 0.05, toolExecutionFactLedger: ledger)
        oldLoop.concurrentReadToolLimit = 1 // Original single-call timeout/physical-tail path.
        var firstError: (any Error)?
        do {
            _ = try await oldLoop.run(messages: [], systemPrompt: nil, provider: oldProvider,
                toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read"]),
                executionIdentity: minisCoreToolContractIdentity("n15-old-physical-tail"))
        } catch { firstError = error }
        let calls: [[String: Any]] = [
            ["id": "n15-queued-a", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-queued-b", "name": "file_read", "input": ["path": path.path]],
            ["id": "n15-queued-write", "name": "file_write", "input": ["path": path.path, "content": "wrong"]]]
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = MockLLMProvider(responses: [String(decoding: payload, as: UTF8.self), "must not request"])
        let identity = minisCoreToolContractIdentity("n15-queued-cohort")
        let delegate = M01ApprovalContextDelegate(approves: true)
        let phases = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2, approvalGate: m01ReadsAskingGate(delegate: delegate),
            turnController: TurnController(), loopDetector: nil, timeout: 0.05, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phases.record($0) }
        var queuedError: (any Error)?
        do {
            _ = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: executor, tools: minisCoreToolContractCatalog(["file_read", "file_write"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                    taskID: "task:n15-queued-cohort", actorID: "synthetic"),
                executionIdentity: identity)
        } catch { queuedError = error }
        let owner = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
        let previousTailStillActive = executor.intervals["n15-old-tail"] == nil && owner.hasPendingOperations
        let beforeDrainPhases = phases.phases
        let queuedFacts = ledger.facts.filter { ["n15-queued-a", "n15-queued-b"].contains($0.toolCallID) }
        await owner.cancelAndDrainForApplicationExit()
        if let typed = firstError as? ToolExecutorError, case .toolTimeout = typed {} else { Issue.record("old call must reach its real timeout") }
        if let typed = queuedError as? ToolExecutorError, case .toolTimeout = typed {} else { Issue.record("queue wait must retain typed timeout") }
        #expect(previousTailStillActive)
        #expect(!beforeDrainPhases.contains { $0.phase == .running })
        #expect(await delegate.approvalOrder() == ["n15-queued-a", "n15-queued-b"])
        #expect(provider.receivedHistory.count == 1)
        #expect(Set(executor.intervals.keys) == ["n15-old-tail"])
        #expect(queuedFacts.count == 2 && queuedFacts.allSatisfy {
            $0.status == .failed && $0.failureCategory == .timeout && $0.elapsedMilliseconds == nil
        })
        #expect(ledger.pendingReceipts.isEmpty && !owner.hasPendingOperations)
        #expect(try String(contentsOf: path, encoding: .utf8) == "N15 queue unchanged")
    }

    @Test(arguments: [true, false])
    func approvedComposerCallAbortedBeforeDurableMintClosesPending(_ observesUI: Bool) async throws {
        let identity = minisCoreToolContractIdentity("composer-preexecute")
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: identity.turn.sessionID,
            turnID: identity.turn.turnID,
            taskID: "task:composer-preexecute",
            attemptID: "\(identity.operationID):attempt:\(identity.attempt)",
            messageID: identity.turn.messageID,
            workspaceID: "workspace:synthetic",
            createdAt: now,
            policyRevision: "policy:synthetic",
            grantEpoch: "epoch:synthetic",
            autonomyCeiling: .l1
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"],
            allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace:synthetic",
            revision: "policy:synthetic",
            grantEpoch: "epoch:synthetic",
            leaseID: "lease:synthetic",
            expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l1
        )
        let base = M01UnexecutedComposerBase()
        let composer = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: M01PresentedComposerDelegate())
        )
        let recorder = M01ApprovalFactRecorder()
        // Deliberately omit the durable tool ledger: approval succeeds, then
        // the production pre-dispatch guard rejects before execute is called.
        var loop = AgentLoop(maxIterations: 2, loopDetector: nil)
        if observesUI { loop.onApprovalLifecycle = { recorder.record($0) } }
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"composer-preexecute-call","name":"file_write","input":{"path":"/tmp/workspace/synthetic-no-write","content":"synthetic"}}]}"#,
            "done",
        ])

        await #expect(throws: AgentLoopError.toolExecutionFactsUnavailable) {
            _ = try await loop.run(
                messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: composer,
                tools: minisCoreToolContractCatalog(["file_write"]),
                executionIdentity: identity
            )
        }
        let observed = recorder.facts
        #expect(observed.map(\.stage) == (observesUI ? [.presented, .authorityCancelled] : []))
        #expect(observed.first?.compositeKey == observed.last?.compositeKey)
        #expect(observed.first?.requestID == observed.last?.requestID)
        #expect(observed.first?.identityDigest == observed.last?.identityDigest)
        #expect(await base.executionCount == 0)
    }

    @Test func boundGateSeesCanonicalCallContextWithoutFakePending() async throws {
        let root = try minisCoreToolContractRoot("approval-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("approval-context")
        let delegate = M01ApprovalContextDelegate()
        let recorder = M01ApprovalFactRecorder()
        var loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: delegate),
            turnController: TurnController(),
            loopDetector: nil,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        loop.onApprovalLifecycle = { recorder.record($0) }
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"approval-call","name":"file_write","input":{"path":"/tmp/synthetic-approval-no-write","content":"synthetic"}}]}"#,
            "done",
        ])

        let result = try await loop.run(
            messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: M01SyntheticToolExecutor(shouldFail: false),
            tools: minisCoreToolContractCatalog(["file_write"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:approval-context",
                actorID: "synthetic"
            ),
            executionIdentity: identity
        )

        let (key, toolName, callID, wasBound) = await delegate.observation()
        #expect(wasBound)
        #expect(toolName == "file_write")
        #expect(callID == "approval-call")
        #expect(key?.sessionID == identity.turn.sessionID)
        #expect(key?.turnID == identity.turn.turnID)
        #expect(key?.messageID == identity.turn.messageID)
        #expect(key?.operationID == identity.operationID)
        #expect(key?.attemptID == "\(identity.operationID):attempt:\(identity.attempt)")
        #expect(key?.attemptNumber == identity.attempt)
        #expect(key?.toolCallID == "approval-call")
        #expect(result.toolExecutionFacts.isEmpty)
        #expect(!recorder.facts.contains { $0.stage == .presented })
    }

    @Test func actualDispatchProducesOrderedPhasesAndMeasuredTerminal() async throws {
        let root = try minisCoreToolContractRoot("tool-phase-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try minisCoreToolContractLedger(at: root)
        let recorder = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { recorder.record($0) }
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"phase-call","name":"file_read","input":{"path":"/tmp/private-path-should-not-enter-phase"}}]}"#,
            "done",
        ])

        let result = try await loop.run(
            messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: M01SyntheticToolExecutor(shouldFail: false),
            tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("tool-phase-success")
        )

        let phases = recorder.phases
        #expect(phases.map(\.phase) == [.queued, .running])
        #expect(phases.count == 2)
        #expect(phases.first?.compositeKey == phases.last?.compositeKey)
        #expect(result.toolExecutionFacts.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .succeeded)
        #expect(result.toolExecutionFacts.first?.compositeKey == phases.last?.compositeKey)
        #expect(result.toolExecutionFacts.first?.elapsedMilliseconds != nil)
        let encoded = try JSONEncoder().encode(phases)
        let phaseText = String(decoding: encoded, as: UTF8.self)
        #expect(!phaseText.contains("private-path-should-not-enter-phase"))
        #expect(!phaseText.contains("synthetic-result-should-not-enter-phase"))
    }

    @Test func executorFailureKeepsTerminalFailureWithoutInputLeak() async throws {
        let root = try minisCoreToolContractRoot("tool-phase-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try minisCoreToolContractLedger(at: root)
        let recorder = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { recorder.record($0) }
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"failure-call","name":"file_read","input":{"path":"/tmp/private-path-should-not-enter-phase"}}]}"#,
            "done",
        ])

        let result = try await loop.run(
            messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: M01SyntheticToolExecutor(shouldFail: true),
            tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("tool-phase-failure")
        )

        #expect(recorder.phases.map(\.phase) == [.queued, .running])
        #expect(result.toolExecutionFacts.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .failed)
        #expect(result.toolExecutionFacts.first?.elapsedMilliseconds != nil)
        let phaseText = String(decoding: try JSONEncoder().encode(recorder.phases), as: UTF8.self)
        #expect(!phaseText.contains("private-path-should-not-enter-phase"))
    }

    @Test func rejectedPreflightDoesNotPretendToolWasQueued() async throws {
        let root = try minisCoreToolContractRoot("tool-phase-rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try minisCoreToolContractLedger(at: root)
        let recorder = M01PhaseRecorder()
        var loop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { recorder.record($0) }
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"rejected-call","name":"shell_execute","input":{"command":"never-execute"}}]}"#,
            "done",
        ])

        let result = try await loop.run(
            messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: M01SyntheticToolExecutor(shouldFail: false),
            tools: minisCoreToolContractCatalog(["shell_execute"]),
            executionIdentity: minisCoreToolContractIdentity("tool-phase-rejected")
        )

        #expect(recorder.phases.isEmpty)
        #expect(result.toolExecutionFacts.isEmpty)
    }
}

/// 用户 2026-11-16 决定授权目录内只读文件工具在“每次询问”下免卡；本文件用读工具检验审批顺序与生命周期，
/// 因此显式把只读文件工具收紧回“每次询问”，测试含义不变。
func m01ReadsAskingGate(delegate: any ApprovalDelegate) -> ApprovalGate {
    var gate = ApprovalGate(policy: .alwaysAsk, delegate: delegate)
    for tool in ApprovalGate.readOnlyFileToolNames { gate.setPolicy(.alwaysAsk, for: tool) }
    return gate
}
