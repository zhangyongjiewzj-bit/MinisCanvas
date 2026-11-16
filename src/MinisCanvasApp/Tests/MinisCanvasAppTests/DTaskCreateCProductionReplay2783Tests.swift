import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class TaskCreate2783HeldProvider: LLMProvider, @unchecked Sendable {
    let name = "TaskCreate2783Synthetic"
    var model = LLMModel(id: "taskcreate-2783", displayName: "Synthetic", provider: "TaskCreate2783Synthetic")
    let capabilities: Set<ProviderCapability> = [.streaming]
    private let lock = NSLock()
    private var pending: [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] = []

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "synthetic", stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { pending.append(continuation) }
        }
    }

    func finishAll() {
        let streams = lock.withLock { () -> [AsyncThrowingStream<LLMStreamChunk, Error>.Continuation] in
            let captured = pending
            pending.removeAll()
            return captured
        }
        for stream in streams { stream.finish() }
    }
}

@Suite("D-TASKCREATEC production replay and physical transcript isolation", .serialized)
@MainActor
struct DTaskCreateCProductionReplay2783Tests {
    @Test("one authorized create and its replay survive fresh stores without copying parent history")
    func authorizedDuplicateCreateRestoresOneIsolatedTarget() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "taskcreate-2783", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let projectDirectory = root.appendingPathComponent("native-selected-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionDirectory = profile.sessionDirectory
        let store = SessionStore(directory: sessionDirectory)
        let defaults = profile.makeUserDefaults()
        let chat = ChatStore(preferencesDefaults: defaults, logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        chat.restoreSpeedTier(.fast)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "taskcreate-2783-policy", grantEpoch: "taskcreate-2783-epoch",
            leaseID: "taskcreate-2783-lease", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let provider = TaskCreate2783HeldProvider()
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety(); provider.finishAll() }

        let sourceID = chat.applyNewSession(title: "来源")
        let parentSentinel = String(repeating: "PARENT_ONLY_2783_", count: 512)
        chat.appendUser(parentSentinel)
        let neighborID = chat.applyNewSession(title: "邻会话")
        chat.appendUser("NEIGHBOR_ONLY_2783")
        #expect(chat.applySwitchSession(id: sourceID))
        let neighborFile = sessionDirectory.appendingPathComponent("sessions/\(neighborID.uuidString).json")
        let neighborBefore = try Data(contentsOf: neighborFile)

        let capsule = "APPROVED_CAPSULE_ONLY_2783"
        #expect(chat.setPastedTextDraft(PastedTextDraft(id: UUID(), text: capsule,
            source: .pasteboard, kind: .reference)))
        chat.draftText = "从这次用户消息创建任务"
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.activeExecutionIdentity(for: sourceID) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let active = try #require(chat.activeExecutionIdentity(for: sourceID))
        #expect(active.turn.messageID == snapshot.messageID)
        #expect(chat.isStreaming)

        let taskURL = root.appendingPathComponent("agent-tasks-2783.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        var approvalCount = 0
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: store, taskStore: taskStore,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: root,
            fileAccessExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            approval: { _, preview in
                approvalCount += 1
                #expect(preview.contains(capsule))
                #expect(!preview.contains(parentSentinel))
                return true
            })
        let projectID = try handler.authorizeFolderFromNativePicker(projectDirectory)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, taskID: snapshot.taskID,
            actorID: "taskcreate-2783-owned").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID.uuidString,
            makeChildBudget: nil, deadline: nil, taskStore: taskStore,
            parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let executor = ProjectSessionToolExecutor(handler: handler)
        let idempotencyKey = UUID().uuidString
        let outcomes = try await AgentExecutionContext.$current.withValue(context) {
            let resolved = try await executor.execute(name: ProjectSessionToolContract.projectResolve,
                input: ["input_version": 1, "project_id": projectID])
            let project = try #require(JSONSerialization.jsonObject(with: Data(resolved.utf8))
                as? [String: Any])
            let reference = try #require((project["project"] as? [String: Any])?["workdir_reference"] as? String)
            let input: [String: Any] = [
                "input_version": 1, "source_session_id": sourceID.uuidString,
                "source_turn_id": parent.turnID, "project_id": projectID,
                "workdir_reference": reference, "title": "合成目标任务",
                "initial_task": "处理这份授权资料", "capsule_reference": "source-turn-reference-v1",
                "switch_after_create": false, "idempotency_key": idempotencyKey
            ]
            let first = try await executor.execute(name: ProjectSessionToolContract.sessionCreate, input: input)
            let replay = try await executor.execute(name: ProjectSessionToolContract.sessionCreate, input: input)
            return (first, replay)
        }
        let first = try #require(JSONSerialization.jsonObject(with: Data(outcomes.0.utf8)) as? [String: Any])
        let replay = try #require(JSONSerialization.jsonObject(with: Data(outcomes.1.utf8)) as? [String: Any])
        #expect(first["status"] as? String == "committed")
        #expect(replay["status"] as? String == "committed")
        let targetID = try #require(first["target_session_id"] as? String)
        let taskID = try #require(first["task_id"] as? String)
        let runID = try #require(first["run_id"] as? String)
        #expect(replay["target_session_id"] as? String == targetID)
        #expect(replay["task_id"] as? String == taskID)
        #expect(replay["run_id"] as? String == runID)
        #expect(approvalCount == 1)
        #expect(taskStore.taskCenterSnapshots().filter { $0.taskID == taskID }.count == 1)

        let targetFile = sessionDirectory.appendingPathComponent("sessions/\(targetID).json")
        let targetBytes = try Data(contentsOf: targetFile)
        #expect(targetBytes.range(of: Data(parentSentinel.utf8)) == nil)
        #expect(targetBytes.range(of: Data("NEIGHBOR_ONLY_2783".utf8)) == nil)
        #expect(targetBytes.range(of: Data(capsule.utf8)) != nil)
        #expect(try Data(contentsOf: neighborFile) == neighborBefore)
        let sourceFile = sessionDirectory.appendingPathComponent("sessions/\(sourceID.uuidString).json")
        let sourceAfter = try Data(contentsOf: sourceFile)
        #expect(sourceAfter.range(of: Data(parentSentinel.utf8)) != nil)

        // Reopen actual stores rather than reusing the in-memory handler or chat.
        // A formerly running target is deliberately unavailable on restart;
        // this test checks identity and non-redispatch, not a fabricated success.
        let reopenedSessions = SessionStore(directory: sessionDirectory)
        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedChat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("reopened-logs")))
        #expect(reopenedChat.attachPersistence(reopenedSessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("reopened-badges"))))
        let reopenedHandler = try ProjectSessionAppHandler(chat: reopenedChat,
            sessionStore: reopenedSessions, taskStore: reopenedTasks,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: root,
            fileAccessExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            approval: { _, _ in Issue.record("recovery must not ask for a second approval"); return false })
        reopenedHandler.reconcileRecoveredReservations()
        let targets = reopenedSessions.listSessions().filter { $0.createdByTaskID == taskID }
        #expect(targets.count == 1)
        let target = try #require(targets.first)
        #expect(target.id == targetID)
        #expect(target.taskSourceSessionID == sourceID.uuidString)
        #expect(target.rootSessionID == targetID && target.parentSessionID == nil)
        #expect(target.createdByRunID == runID && target.projectID == projectID)
        #expect(target.messages.count == 1)
        #expect(target.messages[0].content == "处理这份授权资料\n\n用户已批准从本次来源消息转交的资料：\n" + capsule)
        #expect(reopenedTasks.taskCenterSnapshots().filter { $0.taskID == taskID }.count == 1)
        #expect(reopenedTasks.controlSnapshot(taskID: taskID, parentID: snapshot.taskID)?.runID == runID)
        let reopenedSource = try #require(reopenedChat.sessions.first { $0.id == sourceID })
        let backlinks = reopenedSource.messages.compactMap(\.sessionReferenceCard)
            .filter { $0.targetSessionID == targetID && $0.taskID == taskID }
        #expect(backlinks.count == 1)
        #expect(try Data(contentsOf: targetFile) == targetBytes)
        #expect(try Data(contentsOf: sourceFile).range(of: Data(parentSentinel.utf8)) != nil)
        #expect(try Data(contentsOf: neighborFile) == neighborBefore)
    }
}
