import Foundation
import Testing
@testable import MinisCore

@Suite("D-TASK-12 verified target file producer")
struct TaskFileArtifact342ProducerTests {
    @Test("real target dispatch preserves distinct canonical task and minted tool identities")
    func verifiedTargetDispatchBindsTaskAndToolReceipt() async throws {
        let root = try rootDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = ParentRuntimeIdentity(sessionID: "source-session342", conversationID: "source-conversation342",
            turnID: "turn-handle:99", taskID: "source-task342", actorID: "test")
        let tasks = AgentTaskStore()
        let metadata = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: "create342",
            action: .new(title: "task", projectID: "project342", workingDirectory: project.path, source: source))
        let task = try tasks.enqueueIdempotent(taskID: "target342", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "task-run342")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let producerSession = "producer-session342"
        let parent = try ParentRuntimeIdentitySeed(sessionID: producerSession, conversationID: producerSession,
            taskID: task.taskID, actorID: "test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []), approvalGate: nil,
            turnController: controller, currentConversationID: producerSession, makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let facts = try minisCoreToolContractLedger(at: root)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: producerSession,
            turnID: handle.turnID, messageID: "target342"), operationID: run.runID, attempt: 1)
        let origin = try #require(try BuiltinToolExecutor.captureTargetTaskOrigin(
            context: context, executionIdentity: identity))
        let receipt = try facts.mint(toolCallID: "write342", toolName: "file_write",
            attemptID: "distinct-tool-attempt342", attemptNumber: 1, executionIdentity: identity,
            targetTaskBinding: origin.binding, targetTaskSource: origin.source)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeLedger = ledger
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: producerSession,
            taskID: task.taskID, runID: run.runID, projectID: "project342", workingDirectory: project.path)
        let output = project.appendingPathComponent("result.md")
        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                try await executor.executeInTargetWorkspace(name: "file_write",
                    input: ["path": output.path, "content": "generated342\n"], binding: binding)
            }
        }
        let fact = try #require(try facts.settle(receipt, status: .succeeded))
        let record = try #require(ledger.records(sessionID: producerSession).first)
        let typed = try #require(record.taskArtifactBinding)
        #expect(typed.taskID == task.taskID && typed.parentID == task.parentID)
        #expect(typed.runID == run.runID && typed.attemptID == tasks.canonicalAttemptID(runID: run.runID))
        #expect(typed.sourceSessionID == source.sessionID && typed.producerSessionID == producerSession)
        #expect(typed.sourceSessionID != typed.producerSessionID)
        #expect(typed.attemptID != receipt.attemptID)
        #expect(record.producerReceiptID == receipt.receiptID && record.producerCompositeKey == receipt.compositeKey)
        #expect(ledger.artifactEvidence(diffID: record.diffID, sessionID: producerSession, fact: fact) != nil)
        #expect(try String(contentsOf: output, encoding: .utf8) == "generated342\n")
    }

    @Test("a foreign run under the same source cannot publish a file or typed artifact")
    func foreignRunCannotProduceArtifact() async throws {
        let root = try rootDirectory()
        let source = ParentRuntimeIdentity(sessionID: "source342", conversationID: "conversation342",
            turnID: "turn-handle:99", taskID: "parent342", actorID: "test")
        let tasks = AgentTaskStore()
        for id in ["target342", "foreign342"] {
            let metadata = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: id,
                action: .new(title: id, projectID: "project342", workingDirectory: root.path, source: source))
            _ = try tasks.enqueueIdempotent(taskID: id, parentID: source.taskID,
                providerID: "offline", modelID: "synthetic", creation: metadata)
            _ = try tasks.startRun(taskID: id, parentID: source.taskID, runID: "run-\(id)")
        }
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = try ParentRuntimeIdentitySeed(sessionID: "producer342", conversationID: "producer342",
            taskID: "target342", actorID: "test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []), approvalGate: nil,
            turnController: controller, currentConversationID: "producer342", makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeLedger = ledger
        let output = root.appendingPathComponent("must-not-exist.md")
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: "producer342",
            taskID: "target342", runID: "run-foreign342", projectID: "project342", workingDirectory: root.path)
        await #expect(throws: ToolExecutorError.self) {
            _ = try await AgentExecutionContext.$current.withValue(context) {
                try await executor.executeInTargetWorkspace(name: "file_write",
                    input: ["path": output.path, "content": "must not write"], binding: binding)
            }
        }
        #expect(ledger.count == 0)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("old Codable file records have no invented task association")
    func legacyRecordHasNoTaskBinding() throws {
        let record = FileChangeRecord(changeID: "old", path: "old.md", kind: .created, diffID: "old-diff",
            insertions: 1, deletions: 0, timestamp: Date(), sessionID: "old-session")
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        payload.removeValue(forKey: "taskArtifactBinding")
        let decoded = try JSONDecoder().decode(FileChangeRecord.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(decoded.taskArtifactBinding == nil && decoded.path == record.path)
    }

    @Test(arguments: ["file_write", "file_edit"])
    func targetWriteEffectKeepsDurableOrigin867(tool: String) async throws {
        actor Approval: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
        }
        struct Origin: Decodable {
            let targetTaskBinding: TaskFileArtifactBinding?
            let targetTaskSource: ParentRuntimeIdentity?
        }
        let root = try rootDirectory()
        let source = ParentRuntimeIdentity(sessionID: "source867", conversationID: "source867",
            turnID: "turn-handle:99", taskID: "parent867", actorID: "owned-test")
        let taskURL = root.appendingPathComponent("tasks867.json")
        let factURL = root.appendingPathComponent("facts867.json")
        let tasks = try AgentTaskStore(persistenceURL: taskURL)
        let metadata = SessionActionCreationMetadata(scopeID: "scope867", idempotencyKey: "create867",
            action: .new(title: "owned", projectID: "project867", workingDirectory: root.path, source: source))
        let task = try tasks.enqueueIdempotent(taskID: "target867", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "run867")
        let session = "producer867"
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: session,
            turnID: 1, messageID: "message867"), operationID: run.runID, attempt: 1)
        let facts = try ToolExecutionFactLedger(persistenceURL: factURL)
        let files = FileChangeLedger(workspaceRoot: root.path)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeLedger = files
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: session,
            taskID: task.taskID, runID: run.runID, projectID: "project867", workingDirectory: root.path)
        let executor = TargetDispatch867(builtin: builtin, binding: binding, factURL: factURL)
        let output = root.appendingPathComponent("effect867.txt")
        try "before867\n".write(to: output, atomically: true, encoding: .utf8)
        // 覆盖已有文件前须先读（用户附件/@ 引用同样登记为已读）；本测试关心的是写入效果的归属，不是先读规则。
        builtin.markFileRead(path: output.path, sessionID: session)
        let input: [String: Any] = tool == "file_write"
            ? ["path": output.path, "content": "after867\n"]
            : ["path": output.path, "old_string": "before867", "new_string": "after867"]
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject:
            ["tool_calls": [["id": "effect867", "name": tool, "input": input]]]), as: UTF8.self)
        let loop = AgentLoop(maxIterations: 3,
            approvalGate: ApprovalGate(policyByTool: [tool: .alwaysAsk], delegate: Approval()),
            turnController: TurnController(), loopDetector: nil, timeout: 30, taskStore: tasks,
            toolExecutionFactLedger: facts)
        let result = try await loop.run(messages: [], systemPrompt: nil,
            provider: MockLLMProvider(responses: [envelope, envelope, "done"]), toolExecutor: executor,
            tools: [AgentToolDefinition(name: tool, description: "owned", parameters: [:], required: [])],
            currentConversationID: session,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
                taskID: task.taskID, actorID: "owned-test"), executionIdentity: identity)
        let feedback = result.messages.filter { $0.role == .user }.map(\.content).joined(separator: "\n")
        print("TASK867_OWNED_FEEDBACK tool=\(tool) root=\(root.path) executed=\(result.toolCallsExecuted) feedback=\(String(feedback.prefix(4096)))")
        #expect(result.toolCallsExecuted == 1)
        #expect(try String(contentsOf: output, encoding: .utf8) == "after867\n")
        #expect(executor.entries == 1 && facts.facts.count == 1 && facts.pendingReceipts.isEmpty)
        let receipt = try #require(executor.receiptBeforeEffect)
        let fact = try #require(facts.facts.first)
        #expect(fact.status == .succeeded && fact.receiptID == receipt.receiptID)
        #expect(fact.executionIdentity == identity && fact.compositeKey == receipt.compositeKey)
        let record = try #require(files.records(sessionID: session).first)
        let expected = try #require(record.taskArtifactBinding)
        #expect(expected.runID == run.runID && expected.taskID == task.taskID)
        #expect(expected.attemptID == tasks.canonicalAttemptID(runID: run.runID))
        #expect(receipt.attemptID == AgentToolExecutionAttemptID.canonical(
            executionIdentity: identity, composerSnapshot: nil, childBoundary: nil))
        #expect(files.artifactEvidence(diffID: record.diffID, sessionID: session, fact: fact) != nil)
        let pendingOrigin = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(receipt))
        let origin = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(fact))
        #expect(pendingOrigin.targetTaskBinding == expected && pendingOrigin.targetTaskSource == source)
        #expect(origin.targetTaskBinding == expected && origin.targetTaskSource == source)
        _ = try tasks.finish(runID: run.runID, outcome: .succeeded)
        _ = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "next867")
        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopened.facts == [fact])
        #expect(reopenedTasks.historicalRunIdentity(runID: run.runID,
            taskID: task.taskID, parentID: task.parentID)?.attemptID == expected.attemptID)
        let persisted = try JSONDecoder().decode(Origin.self,
            from: JSONEncoder().encode(try #require(reopened.facts.first)))
        #expect(persisted.targetTaskBinding == expected && persisted.targetTaskSource == source)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("effect867")) {
            try reopened.mint(toolCallID: fact.toolCallID, toolName: tool, attemptID: fact.attemptID,
                attemptNumber: fact.attemptNumber, executionIdentity: identity)
        }
    }

    @Test(arguments: ["task", "run", "attempt", "producer", "root", "source", "missing", "late-run"])
    func mismatchedTargetOriginCannotWrite867(change: String) async throws {
        let root = try rootDirectory()
        let source = ParentRuntimeIdentity(sessionID: "source867", conversationID: "source867",
            turnID: "turn-handle:99", taskID: "parent867", actorID: "owned-test")
        let tasks = AgentTaskStore()
        let metadata = SessionActionCreationMetadata(scopeID: "scope867", idempotencyKey: "create867",
            action: .new(title: "owned", projectID: "project867", workingDirectory: root.path, source: source))
        let task = try tasks.enqueueIdempotent(taskID: "target867", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "run867")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let session = "producer867"
        let parent = try ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
            taskID: task.taskID, actorID: "owned-test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []), approvalGate: nil,
            turnController: controller, currentConversationID: session, makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: session,
            turnID: handle.turnID, messageID: "message867"), operationID: run.runID, attempt: 1)
        let original = try #require(try BuiltinToolExecutor.captureTargetTaskOrigin(context: context, executionIdentity: identity))
        let altered = TaskFileArtifactBinding(taskID: change == "task" ? "foreign" : original.binding.taskID,
            parentID: original.binding.parentID, runID: change == "run" ? "foreign" : run.runID,
            attemptID: change == "attempt" ? "foreign" : original.binding.attemptID,
            sourceSessionID: original.binding.sourceSessionID,
            producerSessionID: change == "producer" ? "foreign" : session,
            workingDirectory: change == "root" ? root.appendingPathComponent("foreign").path : root.path)
        let otherSource = ParentRuntimeIdentity(sessionID: "foreign", conversationID: "foreign",
            turnID: "turn-handle:99", taskID: source.taskID, actorID: "owned-test")
        let facts = try minisCoreToolContractLedger(at: root)
        let files = FileChangeLedger(workspaceRoot: root.path)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeLedger = files
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: session,
            taskID: task.taskID, runID: run.runID, projectID: "project867", workingDirectory: root.path)
        let output = root.appendingPathComponent("must-not-exist867.txt")
        if ["run", "producer", "source"].contains(change) {
            #expect(throws: ToolExecutionFactLedgerError.invalidCanonicalIdentity) {
                try facts.mint(toolCallID: "effect867", toolName: "file_write", attemptID: "tool867",
                    attemptNumber: 1, executionIdentity: identity, targetTaskBinding: altered,
                    targetTaskSource: change == "source" ? otherSource : source)
            }
            #expect(facts.pendingReceipts.isEmpty)
        } else {
            let receipt = try facts.mint(toolCallID: "effect867", toolName: "file_write", attemptID: "tool867",
                attemptNumber: 1, executionIdentity: identity,
                targetTaskBinding: change == "missing" ? nil : altered,
                targetTaskSource: change == "missing" ? nil : source)
            if change == "late-run" {
                _ = try tasks.finish(runID: run.runID, outcome: .cancelled)
                _ = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "next867")
            }
            await #expect(throws: (any Error).self) {
                _ = try await AgentExecutionContext.$current.withValue(context) {
                    try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                        try await builtin.executeInTargetWorkspace(name: "file_write",
                            input: ["path": output.path, "content": "must not write"], binding: binding)
                    }
                }
            }
            #expect(try facts.settle(receipt, status: .failed)?.status == .failed)
            #expect(facts.facts.allSatisfy { $0.status != .succeeded })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path) && files.count == 0)
    }

    @Test(arguments: ["run", "producer", "source"])
    func alteredPendingTargetOriginCannotReopen867(change: String) throws {
        let root = try rootDirectory()
        let url = root.appendingPathComponent("facts867.json")
        let source = ParentRuntimeIdentity(sessionID: "source867", conversationID: "source867",
            turnID: "turn-handle:99", taskID: "parent867", actorID: "owned-test")
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "producer867",
            turnID: 1, messageID: "message867"), operationID: "run867", attempt: 1)
        let binding = TaskFileArtifactBinding(taskID: "target867", parentID: source.taskID,
            runID: identity.operationID, attemptID: "run867:attempt:1",
            sourceSessionID: source.sessionID, producerSessionID: identity.turn.sessionID,
            workingDirectory: root.path)
        let facts = try ToolExecutionFactLedger(persistenceURL: url)
        _ = try facts.mint(toolCallID: "pending867", toolName: "file_write", attemptID: "tool867",
            attemptNumber: 1, executionIdentity: identity,
            targetTaskBinding: binding, targetTaskSource: source)
        #expect(try ToolExecutionFactLedger(persistenceURL: url).pendingReceipts.count == 1)

        var disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var pending = try #require(disk["pending"] as? [String: [String: Any]])
        let key = try #require(pending.keys.first)
        var receipt = try #require(pending[key])
        var storedBinding = try #require(receipt["targetTaskBinding"] as? [String: Any])
        var storedSource = try #require(receipt["targetTaskSource"] as? [String: Any])
        switch change {
        case "run": storedBinding["runID"] = "foreign"
        case "producer": storedBinding["producerSessionID"] = "foreign"
        case "source":
            storedSource["sessionID"] = "foreign"
            storedSource["conversationID"] = "foreign"
        default: Issue.record("Unexpected target-origin variant \(change)")
        }
        receipt["targetTaskBinding"] = storedBinding
        receipt["targetTaskSource"] = storedSource
        pending[key] = receipt
        disk["pending"] = pending
        try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys]).write(to: url, options: .atomic)

        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: url)
        }
    }

    @Test("target origin survives pending recovery while legacy metadata stays unknown")
    func targetOriginRecoveryAndLegacy867() throws {
        let root = try rootDirectory()
        let url = root.appendingPathComponent("facts867.json")
        let facts = try ToolExecutionFactLedger(persistenceURL: url)
        let source = ParentRuntimeIdentity(sessionID: "source867", conversationID: "source867",
            turnID: "turn-handle:99", taskID: "parent867", actorID: "owned-test")
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "producer867",
            turnID: 17, messageID: "message867"), operationID: "run867", attempt: 2)
        let binding = TaskFileArtifactBinding(taskID: "target867", parentID: source.taskID,
            runID: identity.operationID, attemptID: "canonical867", sourceSessionID: source.sessionID,
            producerSessionID: identity.turn.sessionID, workingDirectory: root.path)
        let receipt = try facts.mint(toolCallID: "pending867", toolName: "file_edit", attemptID: "tool867",
            attemptNumber: 2, executionIdentity: identity, targetTaskBinding: binding, targetTaskSource: source)
        let alteredReceipt = ToolExecutionReceipt(toolCallID: receipt.toolCallID, receiptID: receipt.receiptID,
            toolName: receipt.toolName, attemptID: receipt.attemptID, attemptNumber: receipt.attemptNumber,
            executionIdentity: receipt.executionIdentity, compositeKey: receipt.compositeKey)
        #expect(throws: ToolExecutionFactLedgerError.receiptIdentityMismatch) {
            try facts.settle(alteredReceipt, status: .succeeded)
        }
        #expect(facts.pendingReceipts == [receipt] && facts.facts.isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.pendingReceipts == [receipt])
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try reopened.reconcilePending()
        }
        #expect(reopened.pendingReceipts == [receipt] && reopened.facts.isEmpty)
        #expect(reopened.pendingReceipts.first?.targetTaskBinding == binding)
        #expect(reopened.pendingReceipts.first?.targetTaskSource == source)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("pending867")) {
            try reopened.mint(toolCallID: "pending867", toolName: "file_edit", attemptID: "tool867",
                attemptNumber: 2, executionIdentity: identity)
        }
        let legacy = ToolExecutionFact(toolCallID: "legacy", receiptID: "legacy", toolName: "file_write",
            status: .succeeded, attemptID: "legacy", attemptNumber: 1)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "targetTaskBinding"); object.removeValue(forKey: "targetTaskSource")
        let decoded = try JSONDecoder().decode(ToolExecutionFact.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.targetTaskBinding == nil && decoded.targetTaskSource == nil)
    }

    private func rootDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-file342-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}

// Only the existing App dispatch seam is adapted; all identity admission,
// durable mint/settle, approval, and physical file effects remain production.
private final class TargetDispatch867: ToolExecutor, @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    let binding: TargetWorkspaceBinding
    let factURL: URL
    private(set) var entries = 0
    private(set) var receiptBeforeEffect: ToolExecutionReceipt?
    init(builtin: BuiltinToolExecutor, binding: TargetWorkspaceBinding, factURL: URL) {
        self.builtin = builtin; self.binding = binding; self.factURL = factURL
    }
    func execute(name: String, input: [String: Any]) async throws -> String {
        struct Disk: Decodable { let pending: [String: ToolExecutionReceipt] }
        let receipt = try #require(ToolExecutionReceiptContext.current)
        let disk = try JSONDecoder().decode(Disk.self, from: Data(contentsOf: factURL))
        #expect(disk.pending.values.contains(receipt))
        receiptBeforeEffect = receipt
        entries += 1
        return try await builtin.executeInTargetWorkspace(name: name, input: input, binding: binding)
    }
}
