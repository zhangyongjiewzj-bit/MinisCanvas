import Foundation
import Testing
@testable import MinisCore

private actor Child683CoreApproval: ApprovalDelegate {
    private(set) var requests = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests += 1
        return ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class Child683BuiltinProbe: ToolExecutor, @unchecked Sendable {
    private let builtin: BuiltinToolExecutor
    private let lock = NSLock()
    private var calls = 0
    init(_ builtin: BuiltinToolExecutor) { self.builtin = builtin }
    var executionCount: Int { lock.withLock { calls } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { calls += 1 }
        return try await builtin.execute(name: name, input: input)
    }
}

@Suite("683 child authority and canonical attempt observations")
struct ChildAuthority683Tests {
    private func ownedRoot() throws -> URL {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child683-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("missing durable authority refuses before the actual builtin can write")
    func missingLedgerRefusesBeforeBuiltinEffect() async throws {
        let root = try ownedRoot()
        let target = root.appendingPathComponent("owned.txt")
        try "untouched owned bytes".write(to: target, atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "683-no-ledger-write", "name": "file_write",
            "input": ["path": target.path, "content": "must not write"]
        ]]])
        let provider = MockLLMProvider(responses: [String(decoding: data, as: UTF8.self)])
        let probe = Child683BuiltinProbe(BuiltinToolExecutor(allowedRoot: root, deniedRoots: []))
        let approval = Child683CoreApproval()
        let identity = minisCoreToolContractIdentity("683-no-ledger")
        let loop = AgentLoop(maxIterations: 1,
            approvalGate: ApprovalGate(policyByTool: ["file_write": .alwaysAsk], delegate: approval),
            turnController: TurnController(), loopDetector: nil, timeout: 30)
        await #expect(throws: AgentLoopError.toolExecutionFactsUnavailable) {
            _ = try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: probe, tools: minisCoreToolContractCatalog(["file_write"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                    taskID: "task:683-no-ledger", actorID: "owned-synthetic"),
                executionIdentity: identity)
        }
        #expect(await approval.requests == 1)
        #expect(probe.executionCount == 0)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched owned bytes")
    }

    @Test("canonical lifecycle clocks persist and terminal replay never changes them")
    func attemptClocksPersistWithoutChangingSettlementIdentity() throws {
        let root = try ownedRoot()
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        _ = try store.enqueue(taskID: "683-child", parentID: "683-parent",
            providerID: "683-provider", modelID: "683-model", parentContextSnapshotID: "683-context")
        let lowerBound = Date()
        _ = try store.startRun(taskID: "683-child", parentID: "683-parent", runID: "683-run")
        let running = try #require(store.attempts(runID: "683-run").first)
        let started = try #require(running.startedAt)
        #expect(started >= lowerBound && started <= Date())
        #expect(running.finishedAt == nil)
        let receipt = try store.finish(runID: "683-run", outcome: .cancelled)
        let terminal = try #require(store.attempts(runID: "683-run").first)
        let finished = try #require(terminal.finishedAt)
        #expect(terminal.startedAt == started && finished >= started && finished <= Date())
        #expect(terminal.status == .cancelled && receipt.childResultEnvelope == nil)
        #expect(try store.finish(runID: "683-run", outcome: .succeeded) == receipt)
        #expect(store.attempts(runID: "683-run").first == terminal)
        let reloaded = try AgentTaskStore(persistenceURL: url)
        #expect(reloaded.attempts(runID: "683-run").first == terminal)
        #expect(reloaded.receipt(runID: "683-run") == receipt)
        let identity = try #require(reloaded.historicalRunIdentity(runID: "683-run",
            taskID: "683-child", parentID: "683-parent"))
        #expect(identity.attemptID == terminal.attemptID && identity.parentContextSnapshotID == "683-context")
    }
}
