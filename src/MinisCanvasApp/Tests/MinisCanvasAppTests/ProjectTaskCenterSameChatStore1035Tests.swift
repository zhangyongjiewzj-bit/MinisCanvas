import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class ProjectTaskCenter1035HeldProvider: LLMProvider, @unchecked Sendable {
    let name = "ProjectTaskCenter1035Synthetic"
    var model = LLMModel(id: "project-taskcenter-1035", displayName: "Owned synthetic", provider: "ProjectTaskCenter1035Synthetic")
    let capabilities: Set<ProviderCapability> = [.streaming]
    private let lock = NSLock()
    private var sourceStreams: [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] = []
    private var targetStreams: [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] = []

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "owned-only", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let isTarget = messages.last?.content.contains("处理合成项目任务1035") == true
        return AsyncThrowingStream { continuation in
            lock.withLock {
                if isTarget { targetStreams.append(continuation) }
                else { sourceStreams.append(continuation) }
            }
        }
    }

    var hasTargetStream: Bool { lock.withLock { !targetStreams.isEmpty } }

    func finishTarget() {
        let streams = lock.withLock { () -> [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] in
            let captured = targetStreams
            targetStreams.removeAll()
            return captured
        }
        for stream in streams {
            stream.yield(.started)
            stream.yield(.text("项目任务已写入合成文件1035"))
            stream.yield(.finished(stopReason: "end_turn"))
            stream.finish()
        }
    }

    func finishAll() {
        let streams = lock.withLock { () -> [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] in
            let captured = sourceStreams + targetStreams
            sourceStreams.removeAll()
            targetStreams.removeAll()
            return captured
        }
        for stream in streams { stream.finish() }
    }
}

private final class ProjectTaskCenter1035ToolProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    var runtimeConfigurationMaterial: String? = "taskcenter1035-owned-native-provider"
    let name = "ProjectTaskCenter1035OwnedToolCalls"
    var model = LLMModel(id: "project-taskcenter-tool-1035", displayName: "Owned tool call", provider: "ProjectTaskCenter1035Synthetic")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private var requestCount = 0

    init(output: URL) throws {
        let arguments: [String: Any] = ["path": output.path,
            "content": "actual owned output 1035\n"]
        let rawArguments = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        responses = [
            LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                toolCalls: [LLMToolCall(id: "file-write-1035", name: "file_write",
                    rawArguments: rawArguments, arguments: arguments)]),
            LLMResponse(text: "项目任务已写入合成文件1035", stopReason: "end_turn", usage: nil)
        ]
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let response = lock.withLock { () -> LLMResponse in
            requestCount += 1
            return responses.isEmpty
                ? LLMResponse(text: "项目任务已写入合成文件1035", stopReason: "end_turn", usage: nil)
                : responses.removeFirst()
        }
        print("TASK1035_OWNED_PROVIDER request=\(actualRequestCount) nativeCalls=\(response.toolCalls.count) text=\(response.text)")
        return response
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    var actualRequestCount: Int { lock.withLock { requestCount } }
}

private actor ProjectTaskCenter1035Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("D-TASK-12 production project-to-task-center source and file navigation 1035", .serialized)
@MainActor
struct ProjectTaskCenterNavigationProduction1035Tests {
    @Test("authorized ordinary project task, real Builtin file, canonical row and cold source remain one identity")
    func authorizedProjectTaskProducesCanonicalNavigation() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "project-taskcenter-1035", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("native-selected-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(sessions))
        chat.restoreSpeedTier(.fast)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID,
            revision: "taskcenter1035-policy", grantEpoch: "taskcenter1035-epoch",
            leaseID: "taskcenter1035-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let provider = ProjectTaskCenter1035HeldProvider()
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety(); provider.finishAll() }

        let sourceID = chat.applyNewSession(title: "来源会话1035")
        chat.appendUser("原始来源正文1035")
        chat.draftText = "创建一条合成项目任务1035"
        chat.submitComposer()
        let activeDeadline = ContinuousClock.now + .seconds(5)
        while chat.activeExecutionIdentity(for: sourceID) == nil && ContinuousClock.now < activeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(chat.activeExecutionIdentity(for: sourceID) != nil)
        let taskURL = root.appendingPathComponent("agent-tasks-1035.json")
        let tasks = try AgentTaskStore(persistenceURL: taskURL)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        var approvalCount = 0
        let workspaceBindings = ProjectSessionWorkspaceBindings()
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: sessions, taskStore: tasks,
            workspaceBindings: workspaceBindings, directory: root,
            fileAccessExecutor: executor, approval: { _, preview in
                approvalCount += 1
                #expect(preview.contains("处理合成项目任务1035"))
                return true
            })
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        executor.fileChangeLedger = ledger
        let toolFacts = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-facts-1035.json"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let output = project.appendingPathComponent("actual-output-1035.md")
        let targetProvider = try ProjectTaskCenter1035ToolProvider(output: output)
        let now = Date()
        let goal = GoalEnvelope(scopeID: "taskcenter1035-owned",
            allowedCapabilities: ["file_write"], fileRoots: [root.path],
            budget: 100, deadline: now.addingTimeInterval(3600),
            concurrencyLimit: 1, autonomyLevel: .l3,
            creatorID: "TaskCenter1035", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let composite = ProjectSessionCompositeToolExecutor(
            base: executor, builtin: executor, handler: handler,
            workspaceBindings: workspaceBindings)
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: PolicyRuntimeBinding(goal: goal, lease: lease).wrap(composite),
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: ProjectTaskCenter1035Approval()),
            taskStore: tasks, toolExecutionFactLedger: toolFacts,
            composerPolicyFacts: facts)
        chat.streamingProviderOverride = targetProvider
        let projectID = try handler.authorizeFolderFromNativePicker(project)
        let controller = TurnController()
        let turnHandle = await controller.beginTurn()
        defer { Task { await turnHandle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, taskID: snapshot.taskID,
            actorID: "taskcenter1035-owned").makeIdentity(using: turnHandle)
        let context = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID.uuidString,
            makeChildBudget: nil, deadline: nil, taskStore: tasks,
            parentTurnHandle: turnHandle, parentRuntimeIdentity: parent)
        let tools = ProjectSessionToolExecutor(handler: handler)
        let result = try await AgentExecutionContext.$current.withValue(context) {
            let resolved = try await tools.execute(name: ProjectSessionToolContract.projectResolve,
                input: ["input_version": 1, "project_id": projectID])
            let projectRecord = try #require(JSONSerialization.jsonObject(with: Data(resolved.utf8)) as? [String: Any])
            let reference = try #require((projectRecord["project"] as? [String: Any])?["workdir_reference"] as? String)
            return try await tools.execute(name: ProjectSessionToolContract.sessionCreate, input: [
                "input_version": 1, "source_session_id": sourceID.uuidString,
                "source_turn_id": parent.turnID, "project_id": projectID,
                "workdir_reference": reference, "title": "合成业务任务1035",
                "initial_task": "处理合成项目任务1035", "switch_after_create": false,
                "idempotency_key": UUID().uuidString
            ])
        }
        let created = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(created["status"] as? String == "committed")
        let targetID = try #require(created["target_session_id"] as? String)
        let taskID = try #require(created["task_id"] as? String)
        let runID = try #require(created["run_id"] as? String)
        #expect(approvalCount == 1)
        #expect(chat.activeSessionID == sourceID)
        #expect(tasks.controlSnapshot(taskID: taskID, parentID: snapshot.taskID)?.runID == runID)
        let task = try #require(tasks.snapshot(taskID: taskID, parentID: snapshot.taskID))
        #expect(task.sourceSessionID == sourceID.uuidString)

        let consumer = TaskCenterControlConsumer(store: tasks, childTranscriptSessionStore: sessions)
        let runningRow = try #require(consumer.receiptRows().first { $0.taskID == taskID && $0.parentID == snapshot.taskID })
        let sourceLink = try #require(consumer.sourceSessionNavigation(for: runningRow))
        #expect(consumer.sourceTranscript(navigation: sourceLink)?.messages.contains {
            $0.content.contains("原始来源正文1035")
        } == true)
        let projection = BridgeStore(agentTaskStore: tasks).taskCenterGoalProjection(now: .now)
        let goalFact = try #require(projection.fact(taskID: taskID, parentID: snapshot.taskID))
        #expect(goalFact.taskID == runningRow.taskID && goalFact.parentID == runningRow.parentID)
        let stableKey = "\(snapshot.taskID.count):\(snapshot.taskID)\(taskID.count):\(taskID)"
        #expect(Data(stableKey.utf8).base64EncodedString() == runningRow.stableID)

        let factDeadline = ContinuousClock.now + .seconds(15)
        while toolFacts.facts.first(where: { $0.toolCallID == "file-write-1035" }) == nil
              && ContinuousClock.now < factDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let fact = try #require(toolFacts.facts.first {
            $0.toolCallID == "file-write-1035"
        })
        #expect(fact.status == .succeeded)
        let factIdentity = try #require(fact.executionIdentity)
        #expect(factIdentity.operationID == runID)
        #expect(factIdentity.turn.sessionID == targetID)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let terminalDeadline = ContinuousClock.now + .seconds(5)
        while tasks.snapshot(taskID: taskID, parentID: snapshot.taskID)?.status != .succeeded
              && ContinuousClock.now < terminalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tasks.snapshot(taskID: taskID, parentID: snapshot.taskID)?.status == .succeeded)
        #expect(targetProvider.actualRequestCount == 2)
        consumer.bindFileArtifacts(ledger: ledger, facts: toolFacts,
            targetValidator: executor.fileArtifactTargetValidator(),
            projectValidator: { id, path in
                handler.isTaskFileProjectAuthorized(projectID: id, workingDirectory: path)
            })
        let completedRow = try #require(consumer.receiptRows().first { $0.taskID == taskID })
        let resultLink = consumer.resultNavigation(for: completedRow)
        #expect(resultLink != nil)
        if let resultLink {
            let resultDetail = try #require(consumer.resultDetail(navigation: resultLink))
            #expect(resultDetail.statusTitle == "已完成")
            #expect(resultDetail.displayOutput?.contains("项目任务已写入合成文件1035") == true)
        }
        let fileLink = try #require(consumer.fileArtifactNavigations(for: completedRow).first)
        let fileAccess = try #require(consumer.fileArtifactAccess(navigation: fileLink))
        #expect(consumer.fileArtifactPresentationAuthorized(navigation: fileLink, target: output))
        #expect(fileAccess.record.producerReceiptID == fact.receiptID)
        #expect(fileAccess.record.producerCompositeKey == fact.compositeKey)
        #expect(fileLink.binding.taskID == taskID && fileLink.binding.parentID == snapshot.taskID)
        #expect(fileLink.binding.runID == runID && fileLink.binding.producerSessionID == targetID)
        #expect(fileLink.outputSHA256 == AgentFileOutputTargetResolver.generatedFileDigest(output))
        #expect(consumer.sourceTranscript(navigation: sourceLink) != nil)
        var previewText: String?
        let previewResult = AgentFileOutputActionConsumer.performTaskArtifact(
            access: fileAccess,
            validateBinding: { consumer.fileArtifactAccess(navigation: fileLink) == fileAccess },
            authorizeTarget: { consumer.fileArtifactTargetAuthorized(navigation: fileLink, target: $0) },
            intent: .preview, probe: AgentFileOutputTargetResolver.fileSystemProbe,
            digest: { AgentFileOutputTargetResolver.generatedFileDigest($0) },
            open: { _ in Issue.record("unexpected OS open"); return false },
            reveal: { _ in Issue.record("unexpected Finder reveal"); return false },
            copy: { _ in Issue.record("unexpected clipboard"); return false },
            preview: { url in
                let loaded = FilePreview.loadAgentOutput(url: url, workspaceRoot: project,
                    expectedSHA256: fileLink.outputSHA256,
                    validateBinding: { consumer.fileArtifactAccess(navigation: fileLink) == fileAccess },
                    authorizeTarget: { consumer.fileArtifactTargetAuthorized(navigation: fileLink, target: $0) })
                previewText = loaded.text
                return loaded.error == nil
            })
        #expect(previewResult == .completed && previewText == "actual owned output 1035\n")

        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedSessions = SessionStore(directory: profile.sessionDirectory)
        let reopenedConsumer = TaskCenterControlConsumer(store: reopenedTasks,
            childTranscriptSessionStore: reopenedSessions)
        let reopenedRow = try #require(reopenedConsumer.receiptRows().first { $0.taskID == taskID })
        #expect(reopenedRow.parentID == snapshot.taskID && reopenedRow.runID == runID)
        let reopenedSource = try #require(reopenedConsumer.sourceSessionNavigation(for: reopenedRow))
        #expect(reopenedConsumer.sourceTranscript(navigation: reopenedSource) != nil)
        let reopenedResult = reopenedConsumer.resultNavigation(for: reopenedRow)
        #expect(reopenedResult != nil)
        if let reopenedResult {
            #expect(reopenedConsumer.resultDetail(navigation: reopenedResult)?.statusTitle == "已完成")
        }
        let foreignSource = TaskCenterSourceSessionNavigation(taskID: taskID,
            parentID: "foreign-parent", sourceSessionID: sourceID.uuidString,
            runID: runID, attemptID: completedRow.attemptID)
        #expect(consumer.sourceTranscript(navigation: foreignSource) == nil)
        try handler.revokeProject(id: projectID)
        #expect(!consumer.fileArtifactPresentationAuthorized(navigation: fileLink, target: output))
        #expect(await AgentFileOutputActionConsumer.performTaskArtifactInApp(
            navigation: fileLink, consumer: consumer, intent: .preview) == .failed(.unbound))
    }

}
