import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class Backlink0400HeldProvider: LLMProvider, @unchecked Sendable {
    let name = "Backlink0400Synthetic"
    var model = LLMModel(id: "backlink-0400", displayName: "Synthetic", provider: "Backlink0400Synthetic")
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

@Suite("D-BACKLINKB cold App-authored unavailable target consumer", .serialized)
@MainActor
struct BacklinkUnavailable0400Tests {
    enum Invalidation: String, Sendable, CaseIterable {
        case deleted, revoked, staleBookmark
    }

    @Test(arguments: Invalidation.allCases)
    func coldReopenRejectsOriginalCardAndCopiedLink(_ invalidation: Invalidation) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "backlink-0400", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let projectDirectory = root.appendingPathComponent("owned-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let sessionDirectory = profile.sessionDirectory
        let store = SessionStore(directory: sessionDirectory)
        let defaults = profile.makeUserDefaults()
        let chat = ChatStore(preferencesDefaults: defaults, logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        chat.restoreSpeedTier(.fast)
        let policy = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "backlink-0400-policy", grantEpoch: "backlink-0400-epoch",
            leaseID: "backlink-0400-lease", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(policy)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: policy)
        let provider = Backlink0400HeldProvider()
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety(); provider.finishAll() }

        let sourceID = chat.applyNewSession(title: "owned source")
        let capsule = "OWNED_CAPSULE_0400"
        #expect(chat.setPastedTextDraft(PastedTextDraft(id: UUID(), text: capsule,
            source: .pasteboard, kind: .reference)))
        chat.draftText = "create an owned project task"
        chat.submitComposer()
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.activeExecutionIdentity(for: sourceID) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let submission = try #require(chat.lastComposerSubmissionSnapshot)
        let active = try #require(chat.activeExecutionIdentity(for: sourceID))
        #expect(active.turn.messageID == submission.messageID)

        let taskURL = root.appendingPathComponent("owned-agent-tasks.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        let handler = try ProjectSessionAppHandler(chat: chat, sessionStore: store, taskStore: taskStore,
            workspaceBindings: ProjectSessionWorkspaceBindings(), directory: sessionDirectory,
            fileAccessExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            approval: { _, preview in
                #expect(preview.contains(capsule))
                return true
            })
        let projectID = try handler.authorizeFolderFromNativePicker(projectDirectory)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, taskID: submission.taskID,
            actorID: "backlink-0400-owned").makeIdentity(using: handle)
        let context = AgentExecutionContextSnapshot(provider: provider, approvalGate: nil,
            turnController: controller, currentConversationID: sourceID.uuidString,
            makeChildBudget: nil, deadline: nil, taskStore: taskStore,
            parentTurnHandle: handle, parentRuntimeIdentity: parent)
        let executor = ProjectSessionToolExecutor(handler: handler)
        let creation = try await AgentExecutionContext.$current.withValue(context) {
            let resolved = try await executor.execute(name: ProjectSessionToolContract.projectResolve,
                input: ["input_version": 1, "project_id": projectID])
            let project = try #require(JSONSerialization.jsonObject(with: Data(resolved.utf8))
                as? [String: Any])
            let reference = try #require((project["project"] as? [String: Any])?["workdir_reference"] as? String)
            return try await executor.execute(name: ProjectSessionToolContract.sessionCreate,
                input: ["input_version": 1, "source_session_id": sourceID.uuidString,
                    "source_turn_id": parent.turnID, "project_id": projectID,
                    "workdir_reference": reference, "title": "owned target",
                    "initial_task": "use approved capsule", "capsule_reference": "source-turn-reference-v1",
                    "switch_after_create": false, "idempotency_key": UUID().uuidString])
        }
        let committed = try #require(JSONSerialization.jsonObject(with: Data(creation.utf8)) as? [String: Any])
        #expect(committed["status"] as? String == "committed")
        #expect(committed["did_switch"] as? Bool == false)
        #expect(chat.activeSessionID == sourceID)
        let targetID = try #require(committed["target_session_id"] as? String)
        let taskID = try #require(committed["task_id"] as? String)
        let sourceFile = sessionDirectory.appendingPathComponent("sessions/\(sourceID.uuidString).json")
        let originalCard = try #require(chat.sessions.first(where: { $0.id == sourceID })?
            .messages.compactMap(\.sessionReferenceCard).first { $0.targetSessionID == targetID })
        #expect(originalCard.status == .running)
        let copiedLink = try #require(originalCard.deepLink)
        #expect(DeepLinkRouter.parse(url: copiedLink) == .openSession(id: targetID))

        switch invalidation {
        case .deleted:
            let preview = try store.previewDeletion(id: targetID)
            let intent = preview.withFirstConfirmation("已核对这份预览")
                .withSecondConfirmation("永久删除")
            _ = try store.deleteSession(id: targetID, intent: intent)
            #expect(store.loadSession(id: targetID) == nil)
        case .revoked:
            try handler.revokeProject(id: projectID)
            #expect(!handler.isProjectAvailable(id: projectID))
        case .staleBookmark:
            try FileManager.default.moveItem(at: projectDirectory,
                to: root.appendingPathComponent("moved-owned-project", isDirectory: true))
            #expect(!handler.isProjectAvailable(id: projectID))
        }
        let sourceBeforeCold = try Data(contentsOf: sourceFile)

        // A new App composition must consume the persisted original card and
        // re-check the canonical target/grant. No test-created replacement card.
        let reopenedBridge = BridgeStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("reopened-logs")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("reopened-badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("reopened-documents")),
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: taskURL),
            canvasFeatureLane: .phase3NonCanvas)
        _ = reopenedBridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled)
        // R3-10：源会话的回合在“退出”时仍在运行，冷启动会把它最后一条助手回复标成已中断并落盘一次；
        // 之后点卡片、走复制链接都不得再改动源会话文件。
        #expect(try Data(contentsOf: sourceFile) != sourceBeforeCold)
        let sourceAfterRecovery = try Data(contentsOf: sourceFile)
        #expect(reopenedBridge.chat.applySwitchSession(id: sourceID))
        let coldCard = try #require(reopenedBridge.chat.sessions.first(where: { $0.id == sourceID })?
            .messages.compactMap(\.sessionReferenceCard).first { $0.id == originalCard.id })
        #expect(coldCard.id == originalCard.id)
        #expect(coldCard.sourceSessionID == originalCard.sourceSessionID)
        #expect(coldCard.targetSessionID == originalCard.targetSessionID)
        #expect(coldCard.taskID == originalCard.taskID)
        #expect(coldCard.runID == originalCard.runID)
        #expect(coldCard.projectID == originalCard.projectID)
        #expect(coldCard.projectTitle == originalCard.projectTitle)
        #expect(coldCard.title == originalCard.title)
        #expect(coldCard.createdAt == originalCard.createdAt)
        #expect(coldCard.status == .unavailable)
        #expect(!reopenedBridge.chat.canOpenSourceCard(coldCard))
        #expect(!reopenedBridge.chat.openSourceCard(coldCard))
        #expect(reopenedBridge.chat.activeSessionID == sourceID)
        #expect(try Data(contentsOf: sourceFile) == sourceAfterRecovery)
        DeepLinkHandler(bridge: reopenedBridge).handle(try #require(DeepLinkRouter.parse(url: copiedLink)))
        #expect(reopenedBridge.chat.activeSessionID == sourceID)
        #expect(reopenedBridge.chat.sessions.first(where: { $0.id == sourceID })?
            .messages.compactMap(\.sessionReferenceCard).filter { $0.taskID == taskID }.count == 1)
        if invalidation == .deleted {
            #expect(SessionStore(directory: sessionDirectory).loadSession(id: targetID) == nil)
        }
    }
}
