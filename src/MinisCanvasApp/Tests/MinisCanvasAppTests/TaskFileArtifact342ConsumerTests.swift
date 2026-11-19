import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Core's producer suite drives the verified native tool dispatch. These App
/// fixtures drive the real canonical task/fact ledgers without ActionRecords.
struct TaskFileArtifact342Fixture {
    let root: URL
    let project: URL
    let file: URL
    let tasks: AgentTaskStore
    let ledger: FileChangeLedger
    let facts: ToolExecutionFactLedger
    let executor: BuiltinToolExecutor
    let consumer: TaskCenterControlConsumer
    let task: AgentTaskSnapshot
    let run: AgentRunSnapshot
    let record: FileChangeRecord
    let receipt: ToolExecutionReceipt

    init(taskOutcome: AgentTaskOutcome = .succeeded, toolStatus: ToolExecutionStatus = .succeeded,
         capacity: Int = 512, typed: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("task-artifact342-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        project = root.appendingPathComponent("project", isDirectory: true)
        let restricted = project.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        file = restricted.appendingPathComponent("result.md")
        let content = "synthetic generated file342\n"
        try Data(content.utf8).write(to: file)
        tasks = AgentTaskStore()
        let source = ParentRuntimeIdentity(sessionID: UUID().uuidString, conversationID: "source-conversation342",
            turnID: "turn-handle:9", taskID: "parent342", actorID: "test")
        let metadata = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: "create342",
            action: .new(title: "target", projectID: "project342", workingDirectory: project.path, source: source))
        task = try tasks.enqueueIdempotent(taskID: "target342", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: metadata).snapshot
        run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "task-run342")
        facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "producer-session342", turnID: 1,
            messageID: "message342"), operationID: "operation342", attempt: 1)
        receipt = try facts.mint(toolCallID: "write342", toolName: "file_write",
            attemptID: "tool-attempt342", attemptNumber: 1, executionIdentity: identity)
        ledger = FileChangeLedger(workspaceRoot: root.path, capacity: capacity)
        let binding = TaskFileArtifactBinding(taskID: task.taskID, parentID: task.parentID,
            runID: run.runID, attemptID: "\(run.runID):attempt:1", sourceSessionID: source.sessionID,
            producerSessionID: "producer-session342", workingDirectory: project.path)
        record = try ledger.register(sessionID: binding.producerSessionID, path: file.path, kind: .created,
            oldContent: "", newContent: content, producerReceipt: receipt, verifiedOutputContent: content,
            taskArtifactBinding: typed ? binding : nil)
        _ = try facts.settle(receipt, status: toolStatus)
        _ = try tasks.finish(runID: run.runID, outcome: taskOutcome)
        executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        consumer = TaskCenterControlConsumer(store: tasks)
        consumer.bindFileArtifacts(ledger: ledger, facts: facts,
            targetValidator: self.executor.fileArtifactTargetValidator(), projectValidator: { _, _ in true })
    }

    func navigation() throws -> TaskCenterFileArtifactNavigation {
        let row = try #require(consumer.receiptRows().first { $0.taskID == task.taskID })
        return try #require(consumer.fileArtifactNavigations(for: row).first)
    }
}

@Suite("D-TASK-12 typed file artifact consumer")
struct TaskFileArtifact342ConsumerTests {
    @Test("verified project file_write reaches task preview while the active parent draft and history stay unchanged")
    @MainActor
    func targetProducerThroughAppPreviewPreservesParent() async throws {
        let f = try TaskFileArtifact342Fixture()
        let source = try #require(f.task.creation?.source)
        let sourceID = try #require(UUID(uuidString: source.sessionID))
        let activeID = UUID()
        let sessions = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sourceID.uuidString, projectID: "source-project342")
        _ = try sessions.createSession(id: activeID.uuidString, projectID: "active-project342")
        try sessions.saveMessage(LLMMessage(role: .user, content: "source history342"), sessionID: sourceID.uuidString)
        try sessions.saveMessage(LLMMessage(role: .assistant, content: "active history342"), sessionID: activeID.uuidString)
        let defaults = try #require(UserDefaults(suiteName: "task-artifact342-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: LogManager(directory: f.root.appendingPathComponent("logs")))
        #expect(chat.attachPersistence(sessions))
        #expect(chat.applySwitchSession(id: activeID))
        chat.draftText = "parent unsent342"
        let parentMessages = chat.messages
        let sourceBefore = try #require(sessions.loadSession(id: sourceID.uuidString))
        let activeBefore = try #require(sessions.loadSession(id: activeID.uuidString))
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: sessions, taskStore: f.tasks,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: f.root.appendingPathComponent("project-grants"),
            fileAccessExecutor: f.executor, approval: { _, _ in false })
        let projectID = try handler.authorizeFolderFromNativePicker(f.project)
        f.consumer.bindFileArtifacts(ledger: f.ledger, facts: f.facts,
            targetValidator: f.executor.fileArtifactTargetValidator(),
            projectValidator: { projectID, directory in
                handler.isTaskFileProjectAuthorized(projectID: projectID, workingDirectory: directory)
            })
        let creation = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: "e2e-create342",
            action: .new(title: "e2e", projectID: projectID, workingDirectory: f.project.path, source: source))
        let task = try f.tasks.enqueueIdempotent(taskID: "e2e-target342", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: creation).snapshot
        let run = try f.tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "e2e-run342")
        let output = f.project.appendingPathComponent("actual-e2e.md")
        let receipt = try await Self.produceTarget(root: f.root, project: f.project, source: source,
            task: task, run: run, projectID: projectID, tasks: f.tasks, ledger: f.ledger, facts: f.facts)
        _ = try f.facts.settle(receipt, status: .succeeded)
        _ = try f.tasks.finish(runID: run.runID, outcome: .succeeded)
        let row = try #require(f.consumer.receiptRows().first { $0.taskID == task.taskID })
        let navigation = try #require(f.consumer.fileArtifactNavigations(for: row).first)
        let access = try #require(f.consumer.fileArtifactAccess(navigation: navigation))
        #expect(f.consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
        #expect(access.record.producerReceiptID == receipt.receiptID)
        #expect(access.record.producerCompositeKey == receipt.compositeKey)
        var previewText: String?
        let result = AgentFileOutputActionConsumer.performTaskArtifact(
            access: access, validateBinding: { [consumer = f.consumer] in consumer.fileArtifactAccess(navigation: navigation) == access },
            authorizeTarget: { [consumer = f.consumer] in consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) },
            intent: .preview, probe: AgentFileOutputTargetResolver.fileSystemProbe,
            digest: { AgentFileOutputTargetResolver.generatedFileDigest($0) },
            open: { _ in Issue.record("unexpected OS open"); return false },
            reveal: { _ in Issue.record("unexpected Finder open"); return false },
            copy: { _ in Issue.record("unexpected clipboard"); return false },
            preview: { url in
                let loaded = FilePreview.loadAgentOutput(url: url, workspaceRoot: f.project,
                    expectedSHA256: navigation.outputSHA256,
                    validateBinding: { [consumer = f.consumer] in consumer.fileArtifactAccess(navigation: navigation) == access },
                    authorizeTarget: { [consumer = f.consumer] in consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) })
                previewText = loaded.text
                return loaded.error == nil
            }
        )
        #expect(result == .completed && previewText == "actual dispatch342\n")
        #expect(chat.activeSessionID == activeID && chat.draftText == "parent unsent342")
        #expect(chat.messages == parentMessages)
        #expect(sessions.loadSession(id: sourceID.uuidString) == sourceBefore)
        #expect(sessions.loadSession(id: activeID.uuidString) == activeBefore)
        // The completed run and Home-style allowed root do not replace the
        // current native project grant. A verified cached preview must hide,
        // and the real in-App entry must stop at the common intent guard.
        // Preview intent keeps this negative test free of OS effects even if
        // the guard regresses. Other intents use the same tested guard.
        try handler.revokeProject(id: projectID)
        #expect(f.consumer.fileArtifactAccess(navigation: navigation) == access)
        #expect(f.consumer.fileArtifactTargetAuthorized(navigation: navigation, target: output))
        #expect(!f.consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
        let revoked = await AgentFileOutputActionConsumer.performTaskArtifactInApp(
            navigation: navigation, consumer: f.consumer, intent: .preview)
        #expect(revoked == .failed(.unbound))
        #expect(chat.activeSessionID == activeID && chat.draftText == "parent unsent342")
    }

    @Test("admitted generic child writes reach preview; changed bytes and replacement native grants invalidate it",
          arguments: ["preview", "relative", "changed", "regrant"])
    @MainActor
    func genericChildArtifactConsumer(scenario: String) async throws {
        let f = try TaskFileArtifact342Fixture()
        let sessions = SessionStore(directory: f.root.appendingPathComponent("generic-sessions"))
        let sourceID = UUID()
        _ = try sessions.createSession(id: sourceID.uuidString)
        let defaults = try #require(UserDefaults(suiteName: "task12-generic-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: f.root.appendingPathComponent("generic-logs")))
        try #require(chat.attachPersistence(sessions))
        try #require(chat.applySwitchSession(id: sourceID))
        chat.draftText = "parent draft remains here"
        let parentMessages = chat.messages
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: sessions, taskStore: f.tasks,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: f.root.appendingPathComponent("generic-grants"),
            fileAccessExecutor: f.executor, approval: { _, _ in false })
        let projectID = try handler.authorizeFolderFromNativePicker(f.project)
        f.executor.fileChangeLedger = f.ledger
        f.executor.taskArtifactProjectResolver = { directory in
            handler.taskArtifactProjectID(workingDirectory: directory)
        }
        f.consumer.bindFileArtifacts(ledger: f.ledger, facts: f.facts,
            targetValidator: f.executor.fileArtifactTargetValidator(), projectValidator: { projectID, directory in
                handler.isTaskFileProjectAuthorized(projectID: projectID, workingDirectory: directory)
            }, grantCurrent: { projectID, producedAt in
                handler.isTaskFileGrantCurrent(projectID: projectID, producedAt: producedAt)
            })
        let output = f.project.appendingPathComponent("generic-child.txt")
        try await Self.produceGenericChild(executor: f.executor, project: f.project, output: output,
            sourceSessionID: sourceID.uuidString, sessions: sessions, tasks: f.tasks, facts: f.facts,
            relativePath: scenario == "relative")
        let task = try #require(f.tasks.taskCenterSnapshots().first { $0.taskID == "generic-child342" })
        #expect(task.creation == nil && task.status == .succeeded)
        let row = try #require(f.consumer.receiptRows().first { $0.taskID == task.taskID })
        let navigation = try #require(f.consumer.fileArtifactNavigations(for: row).first)
        let access = try #require(f.consumer.fileArtifactAccess(navigation: navigation))
        let locator = try #require(task.childTranscriptLocator)
        let fact = try #require(f.facts.fact(compositeKey: navigation.producerCompositeKey,
            receiptID: navigation.producerReceiptID))
        #expect(navigation.binding.projectID == projectID)
        #expect(navigation.binding.runID == locator.runID && navigation.binding.attemptID == locator.attemptID)
        #expect(fact.targetTaskBinding == nil && fact.targetTaskSource == nil)
        #expect(fact.executionIdentity?.operationID == task.childRuntimeIdentity?.generationID)
        #expect(f.tasks.historicalRunIdentity(runID: locator.runID, taskID: task.taskID,
            parentID: task.parentID)?.attemptID == locator.attemptID)
        try #require(f.consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
        if scenario == "regrant" {
            try handler.revokeProject(id: projectID)
            let replacement = try handler.authorizeFolderFromNativePicker(f.project)
            // 同一文件夹重新授权复用原项目；旧导航绑定因授权版本更新而失效。
            #expect(replacement == projectID)
            #expect(handler.isTaskFileProjectAuthorized(projectID: replacement, workingDirectory: f.project.path))
            #expect(!f.consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
            #expect(await AgentFileOutputActionConsumer.performTaskArtifactInApp(
                navigation: navigation, consumer: f.consumer, intent: .preview) == .failed(.unbound))
        } else {
            if scenario == "changed" { try Data("replacement bytes".utf8).write(to: output) }
            let preview = FilePreview.loadAgentOutput(url: output, workspaceRoot: f.project,
                expectedSHA256: navigation.outputSHA256,
                validateBinding: { [consumer = f.consumer] in consumer.fileArtifactAccess(navigation: navigation) == access },
                authorizeTarget: { [consumer = f.consumer] in consumer.fileArtifactTargetAuthorized(navigation: navigation, target: $0) })
            if scenario == "changed" {
                #expect(preview.text == nil && preview.error == AgentFileOutputFailure.stale.message)
            } else {
                #expect(preview.error == nil && preview.text == "generic child real bytes\n")
                #expect(f.consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
            }
        }
        #expect(chat.activeSessionID == sourceID && chat.draftText == "parent draft remains here")
        #expect(chat.messages == parentMessages)
    }

    nonisolated private static func produceGenericChild(executor: BuiltinToolExecutor, project: URL, output: URL,
        sourceSessionID: String, sessions: SessionStore, tasks: AgentTaskStore,
        facts: ToolExecutionFactLedger, relativePath: Bool = false) async throws {
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "generic-write342", "name": "file_write",
            "input": ["path": relativePath ? output.lastPathComponent : output.path,
                      "content": "generic child real bytes\n"]
        ]]]), as: UTF8.self)
        let provider = TaskFile342ChildProvider(firstReply: envelope)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: sourceSessionID, conversationID: sourceSessionID,
            taskID: "generic-parent342", actorID: "test").makeIdentity(using: handle)
        let goal = GoalEnvelope(scopeID: "generic-artifact342", allowedCapabilities: ["file_write"],
            fileRoots: [project.path], budget: 20, deadline: Date().addingTimeInterval(60), autonomyLevel: .l3)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: Date(), expiresAt: goal.deadline)
        let policy = PolicyEnforcedToolExecutor(base: executor, goal: goal, lease: lease,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        let composer = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: sourceSessionID, turnID: handle.turnID, taskID: parent.taskID,
            attemptID: "generic-parent-attempt342", messageID: parent.taskID,
            workspaceID: "generic-workspace342", createdAt: lease.issuedAt,
            policyRevision: "generic-revision342", grantEpoch: "generic-epoch342",
            bypassModeConfirmed: false, autonomyCeiling: .l3)
        let composerFacts = ComposerPolicyFactSource(knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"], allowedWriteRoots: [project.path],
            workspaceID: composer.workspaceID, revision: composer.policyRevision,
            grantEpoch: composer.grantEpoch, leaseID: lease.leaseID.uuidString,
            expiresAt: lease.expiresAt, autonomyCeiling: .l3)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3, provider: provider, toolExecutor: policy,
            approvalGate: ApprovalGate(policyByTool: ["file_write": .alwaysAsk], delegate: TaskFile342ChildApproval()),
            turnController: controller, makeLoopDetector: { nil }, childTimeout: 30, deadline: goal.deadline,
            currentConversationID: sourceSessionID,
            taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: facts,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_write"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: executor),
            parentWorkingDirectory: project.path, childMutationsEnabled: true,
            parentComposerSnapshot: composer, parentComposerFacts: composerFacts,
            concreteBuiltinToolExecutorOwner: executor, requiresPolicyRuntime: true)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "generic-child342", title: "Real child",
            instructions: "write the synthetic result", requiredCapabilities: [.tools])], strategy: .sequential)
        #expect(reports.count == 1)
        try #require(reports.first?.result == .succeeded(output: "child finished"))
        #expect(try String(contentsOf: output, encoding: .utf8) == "generic child real bytes\n")
    }

    @Test("ordinary records accept direct and symlink roots but never a symlink escaping the root",
          arguments: ["direct", "symlink", "escape"])
    func ordinaryLedgerKeepsSymlinkRootWrites(mode: String) async throws {
        let f = try TaskFileArtifact342Fixture()
        if mode == "escape" {
            let outside = f.root.appendingPathComponent("outside-project.txt")
            try Data("outside unchanged".utf8).write(to: outside)
            let link = f.project.appendingPathComponent("escaping-link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let ledger = FileChangeLedger(workspaceRoot: f.project.path)
            #expect(throws: FileChangeLedger.RegistrationError.outOfBounds(link.path)) {
                _ = try ledger.register(sessionID: "ordinary-symlink342", path: link.path,
                    kind: .modified, oldContent: "outside unchanged", newContent: "not registered")
            }
            #expect(ledger.records(sessionID: "ordinary-symlink342").isEmpty)
            #expect(try String(contentsOf: outside, encoding: .utf8) == "outside unchanged")
            return
        }
        let selectedRoot: URL
        if mode == "symlink" {
            selectedRoot = f.root.appendingPathComponent("selected-project-link")
            try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: f.project)
        } else { selectedRoot = f.project }
        let ledger = FileChangeLedger(workspaceRoot: selectedRoot.path)
        let executor = BuiltinToolExecutor(allowedRoot: selectedRoot, deniedRoots: [])
        executor.fileChangeLedger = ledger
        executor.fileChangeSessionID = "ordinary-symlink342"
        let result = try await executor.execute(name: "file_write", input: [
            "path": selectedRoot.appendingPathComponent("ordinary.txt").path,
            "content": "ordinary real bytes"
        ])
        let record = try #require(ledger.records(sessionID: "ordinary-symlink342").first)
        #expect(result.contains("[diffID:\(record.diffID)]"))
        #expect(record.path == "ordinary.txt" && record.taskArtifactBinding == nil)
        #expect(try String(contentsOf: f.project.appendingPathComponent("ordinary.txt"), encoding: .utf8)
            == "ordinary real bytes")
    }

    /// Mutable native executor stays wholly inside the nonisolated producer
    /// invocation; only the existing Sendable ledgers and immutable identities
    /// cross from the main-actor parent fixture.
    nonisolated private static func produceTarget(root: URL, project: URL, source: ParentRuntimeIdentity,
        task: AgentTaskSnapshot, run: AgentRunSnapshot, projectID: String,
        tasks: AgentTaskStore, ledger: FileChangeLedger, facts: ToolExecutionFactLedger) async throws -> ToolExecutionReceipt {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let producerSession = "producer-session342"
        let parent = try ParentRuntimeIdentitySeed(sessionID: producerSession, conversationID: producerSession,
            taskID: task.taskID, actorID: "test").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: TaskFile342UnusedProvider(), approvalGate: nil,
            turnController: controller, currentConversationID: producerSession, makeChildBudget: nil, deadline: nil,
            taskStore: tasks, parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: producerSession, turnID: handle.turnID,
            messageID: "e2e-message342"), operationID: run.runID, attempt: 1)
        let origin = try #require(try BuiltinToolExecutor.captureTargetTaskOrigin(
            context: context, executionIdentity: identity))
        let receipt = try facts.mint(toolCallID: "e2e-write342", toolName: "file_write",
            attemptID: "e2e-tool-attempt342", attemptNumber: 1, executionIdentity: identity,
            targetTaskBinding: origin.binding, targetTaskSource: origin.source)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeLedger = ledger
        let binding = TargetWorkspaceBinding(source: source, targetSessionID: producerSession, taskID: task.taskID,
            runID: run.runID, projectID: projectID, workingDirectory: project.path)
        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                try await executor.executeInTargetWorkspace(name: "file_write",
                    input: ["path": project.appendingPathComponent("actual-e2e.md").path, "content": "actual dispatch342\n"], binding: binding)
            }
        }
        return receipt
    }

    @Test("same producer session is insufficient to borrow another canonical task file")
    func taskFileIdentityIsExactAndReadOnly() throws {
        let f = try TaskFileArtifact342Fixture()
        let source = try #require(f.task.creation?.source)
        let creation = SessionActionCreationMetadata(scopeID: "scope342", idempotencyKey: "other-create342",
            action: .new(title: "other", projectID: "project342", workingDirectory: f.project.path, source: source))
        let otherTask = try f.tasks.enqueueIdempotent(taskID: "other-task342", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: creation).snapshot
        let otherRun = try f.tasks.startRun(taskID: otherTask.taskID, parentID: otherTask.parentID, runID: "other-run342")
        _ = try f.tasks.finish(runID: otherRun.runID, outcome: .succeeded)
        let otherIdentity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "producer-session342",
            turnID: 2, messageID: "other-message342"), operationID: "other-operation342", attempt: 1)
        let otherReceipt = try f.facts.mint(toolCallID: "other-write342", toolName: "file_write",
            attemptID: "other-tool-attempt342", attemptNumber: 1, executionIdentity: otherIdentity)
        let otherBinding = TaskFileArtifactBinding(taskID: otherTask.taskID, parentID: otherTask.parentID,
            runID: otherRun.runID, attemptID: "\(otherRun.runID):attempt:1", sourceSessionID: source.sessionID,
            producerSessionID: "producer-session342", workingDirectory: f.project.path)
        _ = try f.ledger.register(sessionID: otherBinding.producerSessionID,
            path: f.project.appendingPathComponent("other.md").path, kind: .created, oldContent: "", newContent: "other",
            producerReceipt: otherReceipt, verifiedOutputContent: "other", taskArtifactBinding: otherBinding)
        _ = try f.facts.settle(otherReceipt, status: .succeeded)
        let before = f.tasks.taskCenterSnapshots()
        let rows = f.consumer.receiptRows()
        let ownRow = try #require(rows.first { $0.taskID == f.task.taskID })
        #expect(f.consumer.fileArtifactNavigations(for: ownRow).map(\.diffID) == [f.record.diffID])
        let navigation = try f.navigation()
        #expect(navigation.binding.sourceSessionID != navigation.binding.producerSessionID)
        #expect(navigation.binding.attemptID != navigation.producerCompositeKey.attemptID)
        #expect(f.consumer.fileArtifactAccess(navigation: navigation)?.record == f.record)
        let binding = TaskFileArtifactBinding(taskID: "other-task342", parentID: navigation.binding.parentID,
            runID: navigation.binding.runID, attemptID: navigation.binding.attemptID,
            sourceSessionID: navigation.binding.sourceSessionID, producerSessionID: navigation.binding.producerSessionID,
            workingDirectory: navigation.binding.workingDirectory)
        let foreign = TaskCenterFileArtifactNavigation(binding: binding, diffID: navigation.diffID,
            producerReceiptID: navigation.producerReceiptID, producerCompositeKey: navigation.producerCompositeKey,
            outputSHA256: navigation.outputSHA256, displayName: navigation.displayName)
        #expect(f.consumer.fileArtifactAccess(navigation: foreign) == nil)
        #expect(f.tasks.taskCenterSnapshots() == before)
        #expect(f.facts.fact(compositeKey: navigation.producerCompositeKey, receiptID: "foreign-receipt342") == nil)
    }

    @Test("failed and cancelled tool terminal facts never become file destinations", arguments: [ToolExecutionStatus.failed, .cancelled])
    func failedToolResultDoesNotOpen(status: ToolExecutionStatus) throws {
        let f = try TaskFileArtifact342Fixture(toolStatus: status)
        let row = try #require(f.consumer.receiptRows().first)
        #expect(f.consumer.fileArtifactNavigations(for: row).isEmpty)
    }

    @Test("failed or cancelled task results cannot borrow a successful tool result", arguments: [AgentTaskOutcome.failed(reason: "synthetic"), .cancelled])
    func unsuccessfulTaskDoesNotOpen(outcome: AgentTaskOutcome) throws {
        let f = try TaskFileArtifact342Fixture(taskOutcome: outcome)
        let row = try #require(f.consumer.receiptRows().first)
        #expect(f.consumer.fileArtifactNavigations(for: row).isEmpty)
    }

    @Test("a new canonical run invalidates previously opened file even in the same task and session")
    func laterRunRejectsPreviousFile() throws {
        let f = try TaskFileArtifact342Fixture()
        let navigation = try f.navigation()
        _ = try f.tasks.startRun(taskID: f.task.taskID, parentID: f.task.parentID, runID: "later-run342")
        _ = try f.tasks.finish(runID: "later-run342", outcome: .succeeded)
        #expect(f.consumer.fileArtifactAccess(navigation: navigation) == nil)
        let row = try #require(f.consumer.receiptRows().first { $0.runID == "later-run342" })
        #expect(f.consumer.fileArtifactNavigations(for: row).isEmpty)
    }

    @Test("legacy, FIFO eviction, and replacement authority cannot reconstruct missing file facts")
    func unavailableRecordsFailClosed() throws {
        let legacy = try TaskFileArtifact342Fixture(typed: false)
        let legacyRow = try #require(legacy.consumer.receiptRows().first)
        #expect(legacy.consumer.fileArtifactNavigations(for: legacyRow).isEmpty)
        let f = try TaskFileArtifact342Fixture(capacity: 1)
        let navigation = try f.navigation()
        _ = try f.ledger.register(sessionID: "other-session", path: f.project.appendingPathComponent("other.md").path,
            kind: .created, oldContent: "", newContent: "other")
        #expect(f.consumer.fileArtifactAccess(navigation: navigation) == nil)
        let empty = FileChangeLedger(workspaceRoot: f.root.path)
        f.consumer.bindFileArtifacts(ledger: empty, facts: f.facts,
            targetValidator: f.executor.fileArtifactTargetValidator(), projectValidator: { _, _ in true })
        #expect(f.consumer.fileArtifactAccess(navigation: navigation) == nil)
    }

    @Test("identical bytes rewritten by another real receipt cannot keep the old destination")
    func sameDiffReplacedProducerRejectsOldLink() throws {
        let f = try TaskFileArtifact342Fixture()
        let old = try f.navigation()
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: old.binding.producerSessionID,
            turnID: 2, messageID: "replacement-message342"), operationID: "replacement-operation342", attempt: 1)
        let receipt = try f.facts.mint(toolCallID: "replacement-write342", toolName: "file_write",
            attemptID: "replacement-tool-attempt342", attemptNumber: 1, executionIdentity: identity)
        let content = try String(contentsOf: f.file, encoding: .utf8)
        let replaced = try f.ledger.register(sessionID: old.binding.producerSessionID, path: f.file.path,
            kind: .modified, oldContent: content, newContent: content, producerReceipt: receipt,
            verifiedOutputContent: content, taskArtifactBinding: old.binding)
        _ = try f.facts.settle(receipt, status: .succeeded)
        #expect(replaced.diffID == old.diffID)
        #expect(f.consumer.fileArtifactAccess(navigation: old) == nil)
        #expect(try f.navigation().producerReceiptID == receipt.receiptID)
    }
}

private enum TaskFile342ProviderError: Error { case unexpectedCall }
private actor TaskFile342ChildApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
            bindingDigest: request.identityDigest)
    }
}
private struct TaskFile342ChildProvider: LLMProvider, Sendable {
    let name = "generic-artifact342"
    var model = LLMModel(id: "generic342", displayName: "Generic342", provider: "generic-artifact342")
    let capabilities: Set<ProviderCapability> = [.tools]
    let firstReply: String
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: messages.count == 1 ? firstReply : "child finished", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw TaskFile342ProviderError.unexpectedCall
    }
}
private struct TaskFile342UnusedProvider: LLMProvider, Sendable {
    let name = "offline342"
    var model = LLMModel(id: "synthetic342", displayName: "synthetic342", provider: "offline342")
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        throw TaskFile342ProviderError.unexpectedCall
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw TaskFile342ProviderError.unexpectedCall
    }
}
