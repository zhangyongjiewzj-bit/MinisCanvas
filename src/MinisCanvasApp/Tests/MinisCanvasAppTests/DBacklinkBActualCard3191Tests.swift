import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class Backlink3191HeldProvider: LLMProvider, @unchecked Sendable {
    let name = "Backlink3191Synthetic"
    var model = LLMModel(id: "backlink-3191", displayName: "Synthetic", provider: "Backlink3191Synthetic")
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

@Suite("D-BACKLINKB actual App-authored card failure clicks", .serialized)
@MainActor
struct DBacklinkBActualCard3191Tests {
    enum UnreachableTarget: String, Sendable, CaseIterable {
        case deleted, revoked, staleBookmark
    }

    @Test(arguments: UnreachableTarget.allCases)
    func actualCardClickRejectsChangedTarget(_ failure: UnreachableTarget) async throws {
        let switchAfterCreate = false
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "backlink-3191", processEnvironment: [:],
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
            revision: "backlink-3191-policy", grantEpoch: "backlink-3191-epoch",
            leaseID: "backlink-3191-lease", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let provider = Backlink3191HeldProvider()
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety(); provider.finishAll() }

        let sourceID = chat.applyNewSession(title: "来源")
        let parentSentinel = String(repeating: "PARENT_ONLY_3191_", count: 512)
        chat.appendUser(parentSentinel)
        let neighborID = chat.applyNewSession(title: "邻会话")
        chat.appendUser("NEIGHBOR_ONLY_3191")
        #expect(chat.applySwitchSession(id: sourceID))
        let neighborFile = sessionDirectory.appendingPathComponent("sessions/\(neighborID.uuidString).json")
        let neighborBefore = try Data(contentsOf: neighborFile)

        let capsule = "APPROVED_CAPSULE_ONLY_3191"
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

        let taskURL = root.appendingPathComponent("agent-tasks-3191.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        var approvalCount = 0
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: store, taskStore: taskStore,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: sessionDirectory,
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
            actorID: "backlink-3191-owned").makeIdentity(using: handle)
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
                "switch_after_create": switchAfterCreate, "idempotency_key": idempotencyKey
            ]
            let first = try await executor.execute(name: ProjectSessionToolContract.sessionCreate, input: input)
            let replay = try await executor.execute(name: ProjectSessionToolContract.sessionCreate, input: input)
            return (first, replay)
        }
        let first = try #require(JSONSerialization.jsonObject(with: Data(outcomes.0.utf8)) as? [String: Any])
        let replay = try #require(JSONSerialization.jsonObject(with: Data(outcomes.1.utf8)) as? [String: Any])
        #expect(first["status"] as? String == "committed")
        #expect(first["did_switch"] as? Bool == switchAfterCreate)
        #expect(chat.activeSessionID == (switchAfterCreate ? UUID(uuidString: first["target_session_id"] as? String ?? "") : sourceID))
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
        #expect(targetBytes.range(of: Data("NEIGHBOR_ONLY_3191".utf8)) == nil)
        #expect(targetBytes.range(of: Data(capsule.utf8)) != nil)
        #expect(try Data(contentsOf: neighborFile) == neighborBefore)
        let sourceFile = sessionDirectory.appendingPathComponent("sessions/\(sourceID.uuidString).json")
        let sourceAfter = try Data(contentsOf: sourceFile)
        #expect(sourceAfter.range(of: Data(parentSentinel.utf8)) != nil)

        // Fresh production App composition consumes the actual App-authored card.
        // No manual target/session/card writes occur in this test.
        let reopenedSessions = SessionStore(directory: sessionDirectory)
        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedBridge = BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("reopened-logs")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("reopened-badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("reopened-documents")),
            canvasRuntimeState: .disabled,
            agentTaskStore: reopenedTasks, canvasFeatureLane: .phase3NonCanvas
        )
        _ = reopenedBridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled)
        let reopenedHandler = try #require(reopenedBridge.productionProjectSessionHandler)
        let source = try #require(reopenedBridge.chat.sessions.first { $0.id == sourceID })
        let cards = source.messages.compactMap(\.sessionReferenceCard)
            .filter { $0.targetSessionID == targetID && $0.taskID == taskID }
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.sourceSessionID == sourceID.uuidString && card.runID == runID)
        #expect(reopenedBridge.chat.canOpenSourceCard(card))
        let target = try #require(reopenedSessions.loadSession(id: targetID))
        #expect(target.projectID == projectID && target.createdByTaskID == taskID)
        #expect(target.createdByRunID == runID && target.taskSourceSessionID == sourceID.uuidString)
        #expect(reopenedTasks.taskCenterSnapshots().filter { $0.taskID == taskID }.count == 1)
        #expect(reopenedBridge.chat.applySwitchSession(id: sourceID))
        // Positive control uses the very card written by the production tool.
        #expect(reopenedBridge.chat.openSourceCard(card))
        #expect(reopenedBridge.chat.activeSessionID?.uuidString == targetID)
        #expect(reopenedBridge.chat.applySwitchSession(id: sourceID))
        reopenedBridge.chat.draftText = "保留来源草稿-3191"
        let draftBefore = reopenedBridge.chat.draftText
        let sourceProjectionBefore = try #require(reopenedBridge.chat.sessions.first { $0.id == sourceID })
        let sourceBytesBeforeFailure = try Data(contentsOf: sourceFile)
        let neighborBytesBeforeFailure = try Data(contentsOf: neighborFile)

        switch failure {
        case .deleted:
            let preview = try reopenedSessions.previewDeletion(id: targetID)
            let intent = preview.withFirstConfirmation("已核对这份预览")
                .withSecondConfirmation("永久删除")
            _ = try reopenedSessions.deleteSession(id: targetID, intent: intent)
            // Keep the stale in-memory projection: the click must read canonical.
            #expect(reopenedBridge.chat.sessions.contains { $0.id.uuidString == targetID })
            #expect(reopenedSessions.loadSession(id: targetID) == nil)
        case .revoked:
            try reopenedHandler.revokeProject(id: projectID)
            #expect(!reopenedHandler.isProjectAvailable(id: projectID))
        case .staleBookmark:
            try FileManager.default.moveItem(at: projectDirectory,
                to: root.appendingPathComponent("moved-project-3191", isDirectory: true))
            #expect(!reopenedHandler.isProjectAvailable(id: projectID))
        }

        // Exercise the production click, not just its availability projection.
        #expect(!reopenedBridge.chat.openSourceCard(card))
        #expect(!reopenedBridge.chat.canOpenSourceCard(card))
        #expect(reopenedBridge.chat.activeSessionID == sourceID)
        #expect(reopenedBridge.chat.draftText == draftBefore)
        let sourceProjectionAfter = try #require(reopenedBridge.chat.sessions.first { $0.id == sourceID })
        #expect(sourceProjectionAfter.asPersisted() == sourceProjectionBefore.asPersisted())
        #expect(try Data(contentsOf: sourceFile) == sourceBytesBeforeFailure)
        #expect(try Data(contentsOf: neighborFile) == neighborBytesBeforeFailure)
        #expect(reopenedTasks.taskCenterSnapshots().filter { $0.taskID == taskID }.count == 1)
        #expect(sourceProjectionAfter.messages.compactMap(\.sessionReferenceCard)
            .filter { $0.taskID == taskID }.count == 1)
        if failure == .deleted {
            #expect(reopenedSessions.loadSession(id: targetID) == nil)
            #expect(!FileManager.default.fileExists(atPath: targetFile.path))
        } else {
            #expect(try Data(contentsOf: targetFile) == targetBytes)
        }
    }
}
