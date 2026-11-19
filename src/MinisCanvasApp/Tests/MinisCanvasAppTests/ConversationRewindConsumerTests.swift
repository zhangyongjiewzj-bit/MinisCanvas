import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class RewindPlanProvider: LLMProvider, @unchecked Sendable {
    static let previewSentinel = String(repeating: "OWNED_REWIND_PRIVATE_", count: 5)
    let name = "owned-rewind-plan"
    var model = LLMModel(id: "owned-rewind-plan", displayName: "Owned plan", provider: "owned-rewind-plan")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        let prompt = messages.last(where: { $0.role == .user })?.content ?? "owned request"
        return LLMResponse(text: "PLAN_REPLY \(prompt) \(Self.previewSentinel) END_SAFE", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

@Suite("N03 file-free canonical conversation rewind", .serialized)
@MainActor
struct ConversationRewindConsumerTests {
    @Test("ordinary plan turns rewind through the confirmation consumer, then feed the next provider and cold reopen")
    func planRewindFeedsNextRequestAndColdCanonicalWithoutFileCheckpoint() async throws {
        let (profile, chat, store, provider) = try fixture()
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let id = try #require(chat.activeSessionID)
        try await send("OWNED_FIRST_PLAN", chat: chat)
        let first = try #require(store.loadSession(id: id.uuidString))
        let boundary = first.messages.count - 1
        try await send("OWNED_LATER_PLAN_TO_REMOVE", chat: chat)
        let before = try #require(store.loadSession(id: id.uuidString))
        let lastTurn = try #require(chat.lastComposerSubmissionSnapshot)
        let anchors = try chat.conversationRewindAnchors()
        let anchor = try #require(anchors.first { $0.messageIndex == boundary })
        #expect(chat.fileCheckpoints.isEmpty && chat.fileCheckpointStore == nil)
        let selection = chat.composerPolicySelection
        chat.draftText = "OWNED_UNSENT_DRAFT"
        let pendingURL = profile.rootDirectory.appendingPathComponent("owned-unsent.g22fixture")
        try Data("owned pending bytes".utf8).write(to: pendingURL)
        let added = try #require(chat.addAttachments(urls: [pendingURL]).first)
        let preparation = try #require(chat.attachmentPreparationTask(for: added, sessionID: id))
        _ = await preparation.value
        let pending = try #require(chat.pendingAttachments.first { $0.id == added.id })
        #expect(pending.status == .ready)
        // Controlled intent on factory data invokes the exact consumer used
        // by the recovery dialog's destructive confirmation, not setMessages.
        #expect(chat.restoreConversationHistory(anchor))
        let committed = try #require(store.loadSession(id: id.uuidString))
        #expect(committed.id == before.id && committed.projectID == before.projectID)
        #expect(committed.transcriptRevision == before.transcriptRevision + 1)
        #expect(committed.messages == first.messages)
        #expect(chat.messages.filter { $0.role != .system }.map { $0.asLLMMessage() } == first.messages)
        #expect(chat.draftText == "OWNED_UNSENT_DRAFT" && chat.pendingAttachments == [pending])
        #expect(chat.composerPolicySelection == selection && chat.fileCheckpoints.isEmpty)
        let cold = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(cold.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        #expect(cold.messages(forSession: id)?.filter { $0.role != .system }.map { $0.asLLMMessage() }
            == first.messages)
        let file = store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        let stableBytes = try Data(contentsOf: file)
        let late = AgentTurnIdentity(sessionID: id.uuidString, turnID: lastTurn.turnID,
                                     messageID: lastTurn.messageID)
        #expect(chat.updateMessageContent(sessionID: id, messageID: try #require(chat.messages.last?.id),
                                         identity: late, append: "MUST_NOT_REAPPEAR") == false)
        #expect(try Data(contentsOf: file) == stableBytes)
        chat.removePendingAttachment(id: pending.id) // End the owned unsent-attachment check before the next ordinary send.
        try await send("OWNED_AFTER_REWIND", chat: chat)
        let request = try #require(provider.requests.last)
        #expect(Array(request.dropLast()) == first.messages)
        #expect(request.last?.content == "OWNED_AFTER_REWIND")
        #expect(!request.contains { $0.content.contains("OWNED_LATER_PLAN_TO_REMOVE") })
        let nextTurn = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(nextTurn.turnID > lastTurn.turnID)
        #expect(provider.requests.count == 3)
    }

    @Test("stale, foreign and running confirmation attempts leave the canonical source intact")
    func staleForeignAndRunningAnchorsRefuseWithoutReplacingHistory() async throws {
        let (profile, chat, store, _) = try fixture()
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let id = try #require(chat.activeSessionID)
        try await send("OWNED_BOUNDARY", chat: chat)
        try await send("OWNED_TAIL", chat: chat)
        let anchors = try chat.conversationRewindAnchors()
        let anchor = try #require(anchors.last)
        let before = try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json"))
        _ = chat.applyNewSession(title: "owned foreign target")
        #expect(chat.restoreConversationHistory(anchor) == false)
        #expect(try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")) == before)
        #expect(chat.applySwitchSession(id: id))
        chat.draftText = "OWNED_RUNNING_TURN"
        chat.submitComposer()
        let running = try #require(chat.turnTaskForTests(sessionID: id))
        #expect(chat.isActiveSessionGenerating)
        #expect(chat.restoreConversationHistory(anchor) == false)
        await running.value
        let changed = try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json"))
        #expect(chat.restoreConversationHistory(anchor) == false)
        #expect(throws: SessionStoreError.sessionSnapshotConflict(id.uuidString)) {
            _ = try store.rewindConversation(to: anchor)
        }
        #expect(try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")) == changed)
    }

    @Test("safe previews distinguish real adjacent plans without replacing their sealed anchors")
    func safePreviewUsesBoundUIAndRedactsBeforeSixtyCharacterLimit() async throws {
        let (profile, chat, store, _) = try fixture()
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let id = try #require(chat.activeSessionID)
        try await send("FIRST_TARGET", chat: chat)
        let first = try #require(store.loadSession(id: id.uuidString))
        try await send("SECOND_TARGET", chat: chat)
        let second = try #require(store.loadSession(id: id.uuidString))
        try await send("LATER_TAIL", chat: chat)
        let anchors = try chat.conversationRewindAnchors()
        let a = try #require(anchors.first { $0.messageIndex == first.messages.count - 1 })
        let b = try #require(anchors.first { $0.messageIndex == second.messages.count - 1 })
        let redactor = ChatTranscriptRedactor(secretValues: [RewindPlanProvider.previewSentinel])
        let firstDisplay = chat.conversationRewindDisplay(for: a, redactor: redactor)
        let secondDisplay = chat.conversationRewindDisplay(for: b, redactor: redactor)
        #expect(firstDisplay.anchor == a && secondDisplay.anchor == b)
        let firstText = try #require(firstDisplay.preview)
        let secondText = try #require(secondDisplay.preview)
        #expect(firstText.contains("FIRST_TARGET") && secondText.contains("SECOND_TARGET"))
        #expect(firstText != secondText && firstDisplay.timestamp != nil && secondDisplay.timestamp != nil)
        for text in [firstText, secondText] {
            #expect(text.count <= 60 && !text.contains("\n"))
            #expect(!text.contains(RewindPlanProvider.previewSentinel)
                    && !text.contains("OWNED_REWIND_PRIVATE_"))
            // The 105-character secret becomes 105 stars, so END_SAFE is
            // correctly outside the 60-character preview. Clipping first would
            // expose this known prefix instead of the required masked tail.
            #expect(text.hasSuffix(String(repeating: "*", count: 20)))
        }
        let unavailable = chat.conversationRewindDisplay(for: a, redactor: nil)
        #expect(unavailable.preview == nil && unavailable.anchor == a)
        #expect(chat.restoreConversationHistory(firstDisplay.anchor))
        #expect(store.loadSession(id: id.uuidString)?.messages == first.messages)
        #expect(chat.conversationRewindDisplay(for: b, redactor: redactor).preview == nil)
        _ = chat.applyNewSession(title: "owned foreign preview scope")
        #expect(chat.conversationRewindDisplay(for: a, redactor: redactor).preview == nil)
    }

    /// R3-09：两轮对话后才改文件（检查点晚于第二条用户消息），再退出重开。
    private func r309Prepared() async throws -> (profile: RuntimeIsolationProfile, store: SessionStore,
                                                   id: UUID, boundary: Int, root: URL, file: URL) {
        let (profile, chat, store, _) = try fixture()
        defer { chat.stopAllStreamingForSafety() }
        let id = try #require(chat.activeSessionID)
        try await send("R309_FIRST", chat: chat)
        let boundary = try #require(store.loadSession(id: id.uuidString)).messages.count - 1
        try await send("R309_SECOND", chat: chat)
        let root = profile.rootDirectory.appendingPathComponent("r309-files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let file = resolvedRoot.appendingPathComponent("probe.txt")
        let checkpoints = try FileCheckpointStore(
            directory: resolvedRoot.appendingPathComponent("checkpoints", isDirectory: true),
            allowedRoots: [resolvedRoot])
        let snapshot = try #require(chat.sessions.first { $0.id == id })
        let after = Data("written-by-tool".utf8)
        let checkpointID = try checkpoints.begin(path: file, sessionID: id.uuidString, operation: .write,
            expectedAfter: after, conversation: try JSONEncoder().encode(snapshot))
        try after.write(to: file)
        try checkpoints.commit(checkpointID)
        return (profile, store, id, boundary, resolvedRoot, file)
    }

    private func r309ColdStore(_ prepared: (profile: RuntimeIsolationProfile, store: SessionStore,
                                            id: UUID, boundary: Int, root: URL, file: URL)) throws -> ChatStore {
        let cold = ChatStore(preferencesDefaults: prepared.profile.makeUserDefaults(),
                             logManager: prepared.profile.makeLogManager())
        #expect(cold.attachPersistence(SessionStore(directory: prepared.profile.sessionDirectory)))
        cold.fileCheckpointStore = try FileCheckpointStore(
            directory: prepared.root.appendingPathComponent("checkpoints", isDirectory: true),
            allowedRoots: [prepared.root])
        cold.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [prepared.root.path],
            workspaceID: cold.composerWorkspaceID, revision: "r309", grantEpoch: "r309",
            leaseID: "r309", expiresAt: Date().addingTimeInterval(60)))
        #expect(cold.applySwitchSession(id: prepared.id))
        return cold
    }

    @Test("R3-09：重启后回退会话并恢复文件，仍按消息的真实时间找到早于启动时刻的检查点")
    func restartedRewindRestoresFilesChangedAfterTheAnchor() async throws {
        let prepared = try await r309Prepared()
        defer { try? prepared.profile.cleanupDisposableRoots() }
        let cold = try r309ColdStore(prepared)
        #expect(cold.fileCheckpoints.count == 1)
        let anchor = try #require(try cold.conversationRewindAnchors()
            .first { $0.messageIndex == prepared.boundary })
        #expect(await cold.restoreConversationAndFiles(anchor))
        #expect(!FileManager.default.fileExists(atPath: prepared.file.path))
        #expect(cold.checkpointFeedback?.contains("恢复其后改动的 1 个文件") == true)
    }

    @Test("MC4-024：文件已恢复但会话回退写盘失败时，提示明确写出文件已恢复、对话没有回退")
    func fileRestoredButConversationRewindFailureIsStatedInFeedback() async throws {
        let prepared = try await r309Prepared()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                ofItemAtPath: prepared.store.sessionsDirectory.path)
            try? prepared.profile.cleanupDisposableRoots()
        }
        let cold = try r309ColdStore(prepared)
        let anchor = try #require(try cold.conversationRewindAnchors()
            .first { $0.messageIndex == prepared.boundary })
        // 会话文件所在目录不可写：文件恢复（在检查点目录和工作区）照常成功，会话回退写盘失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
            ofItemAtPath: prepared.store.sessionsDirectory.path)
        let ok = await cold.restoreConversationAndFiles(anchor)
        #expect(ok == false)
        #expect(!FileManager.default.fileExists(atPath: prepared.file.path))
        #expect(cold.checkpointFeedback?.contains("个文件恢复到该检查点，但对话没有回退") == true)
    }

    @Test("R3-09：旧数据没有消息时间时，回退会话不谎称没有文件改动，改为提示按检查点逐个恢复")
    func restartedRewindWithoutSavedTimesDoesNotClaimNoFileChanges() async throws {
        let prepared = try await r309Prepared()
        defer { try? prepared.profile.cleanupDisposableRoots() }
        // 还原成升级前的旧文件：去掉消息时间。
        let shard = ChatAttachmentPersistence.sessionSidecarURL(for: prepared.id, in: prepared.store.directory)
        var object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: shard)) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        for index in sessions.indices { sessions[index].removeValue(forKey: "messageTimes") }
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object).write(to: shard)

        let cold = try r309ColdStore(prepared)
        let anchor = try #require(try cold.conversationRewindAnchors()
            .first { $0.messageIndex == prepared.boundary })
        #expect(await cold.restoreConversationAndFiles(anchor))
        #expect(FileManager.default.fileExists(atPath: prepared.file.path))
        #expect(cold.checkpointFeedback?.contains("按检查点逐个恢复") == true)
        #expect(cold.checkpointFeedback?.contains("没有文件改动") == false)
        #expect(cold.fileCheckpoints.count == 1)
    }

    private func send(_ text: String, chat: ChatStore) async throws {
        let id = try #require(chat.activeSessionID)
        chat.draftText = text
        chat.submitComposer()
        let running = try #require(chat.turnTaskForTests(sessionID: id))
        await running.value
        #expect(!chat.isActiveSessionGenerating)
        #expect(chat.activePlanApproval != nil)
    }

    private func fixture() throws -> (RuntimeIsolationProfile, ChatStore, SessionStore, RewindPlanProvider) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "conversation-rewind",
            processEnvironment: [:], processArguments: ["ConversationRewindConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        let store = SessionStore(directory: profile.sessionDirectory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "owned-rewind", grantEpoch: "owned-rewind",
            leaseID: "owned-rewind", expiresAt: .distantFuture, autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection.mode = .plan
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned-rewind")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        let provider = RewindPlanProvider()
        chat.streamingProviderOverride = provider
        return (profile, chat, store, provider)
    }
}

@MainActor
struct ConversationGoalOwnerTests {
    @Test func goalDurationDisplayRoundsToAtMostOneFractionalDigit() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(ConversationGoalBudgetDraft.goalBudgetMinutesText(0.799651, locale: locale) == "0.8")
        #expect(ConversationGoalBudgetDraft.goalBudgetMinutesText(2, locale: locale) == "2")
        let seconds = 0.799651 * 60
        let budget = try #require(ConversationGoalState.Budget(durationLimitSeconds: seconds))
        var draft = ConversationGoalBudgetDraft(budget)
        #expect(draft.minutes == "0.8")
        draft.turns = "31"
        let unchanged = try draft.limits()
        #expect(unchanged.durationSeconds == seconds)
        draft.minutes = "1.2"
        let edited = try draft.limits()
        #expect(edited.durationSeconds == 72)
    }

    @Test func unavailableReviewSettlesOnlyTheExactOwnedPendingRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        let id = UUID()
        _ = try store.createSession(id: id.uuidString)
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        try #require(chat.applySwitchSession(id: id))
        let goal = try chat.startConversationGoal(sessionID: id, objective: "Review the draft")
        let pending = try store.recordConversationGoalReport(sessionID: id, goalID: goal.id,
                                                             report: .completion(evidence: ["Reviewed draft"]))
        let reviewID = try #require(pending.reviewID)
        let execution = AgentExecutionIdentity(turn: .init(sessionID: id.uuidString, turnID: 1, messageID: "test"),
                                               operationID: "synthetic-goal-review")
        let wrong = ManualConversationGoalUpdate.CompletionReceipt(sessionID: id, goalID: goal.id,
            reviewID: UUID(), executionIdentity: execution, toolReceiptID: "owned")
        chat.settleUnavailableGoalReview(wrong, sessionID: id, executionIdentity: execution)
        #expect(store.loadSession(id: id.uuidString)?.goal == pending)
        let exact = ManualConversationGoalUpdate.CompletionReceipt(sessionID: id, goalID: goal.id,
            reviewID: reviewID, executionIdentity: execution, toolReceiptID: "owned")
        chat.settleUnavailableGoalReview(exact, sessionID: id, executionIdentity: execution)
        chat.settleUnavailableGoalReview(exact, sessionID: id, executionIdentity: execution)
        let saved = try #require(store.loadSession(id: id.uuidString)?.goal)
        #expect(saved.status == .active)
        #expect(saved.lastReview?.outcome == .unavailable)
        #expect(saved.consecutiveRetryableFailures == 1)
        #expect(chat.conversationGoal(for: id) == saved)
        let next = try store.recordConversationGoalReport(sessionID: id, goalID: goal.id,
                                                          report: .completion(evidence: ["Revised draft"]))
        let nextID = try #require(next.reviewID)
        chat.settleUnavailableGoalReview(exact, sessionID: id, executionIdentity: execution, outcome: .cancelled)
        #expect(store.loadSession(id: id.uuidString)?.goal == next)
        let nextReceipt = ManualConversationGoalUpdate.CompletionReceipt(sessionID: id, goalID: goal.id,
            reviewID: nextID, executionIdentity: execution, toolReceiptID: "owned-next")
        chat.settleUnavailableGoalReview(nextReceipt, sessionID: id, executionIdentity: execution, outcome: .cancelled)
        #expect(store.loadSession(id: id.uuidString)?.goal?.lastReview?.outcome == .cancelled)
    }

    @Test func manualGoalUpdateReportsRequiredFieldsWithoutAcceptingInvalidInput() throws {
        let cases: [([String: Any], String)] = [
            (["action": "blocked"], "blocked 需要且只需要 reason"),
            (["action": "complete", "summary": "Unexpected"], "complete 需要且只需要 evidence（命名证据项）"),
            (["action": "blocker", "reason": "Missing draft"], "blocker 需要 summary、reason、options、user_action")
        ]
        for (input, expected) in cases {
            do {
                _ = try ManualConversationGoalUpdate.parse(input)
                Issue.record("Invalid goal update was accepted")
            } catch ToolExecutorError.invalidParameter(let hint) {
                #expect(hint == expected)
            }
        }
    }

    @Test func manualGoalReportValidatesAndWritesOnlyTheBoundGoal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID()
        _ = try store.createSession(id: id.uuidString)
        let goal = try store.startConversationGoal(sessionID: id, objective: "Review the draft")
        let blocker = try ManualConversationGoalUpdate.parse([
            "action": "blocker", "summary": "Draft missing", "reason": "No copy attached",
            "options": ["Attach": "Attach a draft"], "user_action": "Provide the draft"
        ])
        #expect(throws: SessionStore.ConversationGoalError.self) {
            try store.recordConversationGoalReport(sessionID: id, goalID: UUID(), report: blocker)
        }
        #expect(store.loadSession(id: id.uuidString)?.goal == goal)
        let active = try store.recordConversationGoalReport(sessionID: id, goalID: goal.id, report: blocker)
        #expect(active.status == .active)
        #expect(active != goal)
        #expect(throws: ToolExecutorError.self) {
            try ManualConversationGoalUpdate.parse(["action": "complete", "evidence": ["Draft": 42]])
        }
        let report = try ManualConversationGoalUpdate.parse([
            "action": "complete", "evidence": ["Draft": "Reviewed"]
        ])
        let pending = try store.recordConversationGoalReport(sessionID: id, goalID: goal.id, report: report)
        #expect(pending.status == .awaitingReview)
        #expect(pending.reviewID != nil)
        #expect(store.loadSession(id: id.uuidString)?.goal == pending)
    }

    @Test func budgetEditorRejectsInvalidLimitsAndPausesOwnedGoalBelowUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        let id = UUID()
        _ = try store.createSession(id: id.uuidString)
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        try #require(chat.applySwitchSession(id: id))
        let goal = try chat.startConversationGoal(sessionID: id, objective: "Review the draft")
        let measured = try store.recordConversationGoalTurn(sessionID: id, goalID: goal.id,
            durationSeconds: 90, reportedTokens: 20, outcome: .completed)
        var draft = ConversationGoalBudgetDraft(goal.budget)
        draft.minutes = "1e308"
        #expect(throws: ConversationGoalBudgetDraft.InvalidInput.duration) {
            try chat.updateConversationGoalBudget(sessionID: id, goalID: goal.id, draft: draft)
        }
        #expect(store.loadSession(id: id.uuidString)?.goal == measured)
        draft.minutes = ""
        draft.tokens = "15"
        #expect(throws: SessionStore.ConversationGoalError.unavailable) {
            try chat.updateConversationGoalBudget(sessionID: id, goalID: UUID(), draft: draft)
        }
        let updated = try chat.updateConversationGoalBudget(sessionID: id, goalID: goal.id, draft: draft)
        #expect(updated.budget.usedTurns == 1)
        #expect(updated.budget.usedTokens == 20)
        #expect(updated.budget.usedDurationSeconds == 90)
        #expect(updated.budget.durationLimitSeconds == nil)
        #expect(updated.budget.tokenLimit == 15)
        #expect(updated.status == .paused)
        #expect(updated.budgetPauseReason == .tokens)
        #expect(store.loadSession(id: id.uuidString)?.goal == updated)
        #expect(chat.conversationGoal(for: id) == updated)
    }

    @Test func coldAttachPausesOwnedGoalUntilExplicitResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        let id = UUID()
        var session = try store.createSession(id: id.uuidString)
        session.messages = [LLMMessage(role: .user, content: "Keep this transcript")]
        try store.updateSession(session)
        let goal = try store.startConversationGoal(sessionID: id, objective: "Review the draft")
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        try #require(chat.applySwitchSession(id: id))
        #expect(chat.conversationGoal(for: id)?.status == .paused)
        #expect(store.loadSession(id: id.uuidString)?.messages == session.messages)
        #expect(chat.conversationGoal(for: UUID()) == nil)
        let resumed = try chat.controlConversationGoal(sessionID: id, goalID: goal.id, action: .resume)
        #expect(resumed.status == .active)
        let stopped = try chat.controlConversationGoal(sessionID: id, goalID: goal.id, action: .stop)
        #expect(stopped.status == .stopped)
    }

    @Test func coldPauseWriteFailureLeavesOtherGoalsAndTranscriptAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        let store = SessionStore(directory: directory)
        let failing = UUID()
        let healthy = UUID()
        for id in [failing, healthy] {
            var session = try store.createSession(id: id.uuidString)
            session.messages = [LLMMessage(role: .user, content: "Keep this transcript")]
            try store.updateSession(session)
            _ = try store.startConversationGoal(sessionID: id, objective: "Review the draft")
        }
        // An immutable owned file still decodes and lists, but cannot be replaced.
        let file = store.sessionsDirectory.appendingPathComponent(failing.uuidString + ".json")
        let result = file.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        try #require(result == 0)
        defer { _ = file.path.withCString { chflags($0, 0) } }
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        #expect(chat.sessions.contains { $0.id == failing })
        #expect(store.loadSession(id: failing.uuidString)?.goal?.status == .active)
        #expect(store.loadSession(id: healthy.uuidString)?.goal?.status == .paused)
        #expect(store.loadSession(id: failing.uuidString)?.messages.first?.content == "Keep this transcript")
        try #require(chat.applySwitchSession(id: failing))
        #expect(chat.conversationGoal(for: failing) == nil)
    }
}
