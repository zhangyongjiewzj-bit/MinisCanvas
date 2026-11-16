import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// W5-COMPOSER-CMD-POLICY-WIRE-059
// Composer 命令策略钩子生产接线的回归测试：
//   · fail-closed 策略事实评估；
//   · 调度器 lane（scheduler-effect: 命名空间）不挂交互 pending；
//   · 批准/拒绝/超时终态与一次性令牌；
//   · compact 批准经规范 Composer 路径执行并由 ChatStore 清除 pending；
//   · 展示命令消费 + 可见结果投影（不进 transcript、不进 Provider）。

private final class Wiring059CountingProvider: LLMProvider, @unchecked Sendable {
    let name = "wiring-059-test"
    var model = LLMModel(id: "wiring-059-test", displayName: "Wiring 059 Test", provider: "test")
    private(set) var callCount = 0
    private(set) var requests: [[LLMMessage]] = []

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        requests.append(messages)
        return LLMResponse(text: "Preserve the title and the read-only constraint.", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private func makeWiring059Facts(
    workspaceID: String,
    revision: String = "rev-059",
    grantEpoch: String = "epoch-059",
    leaseID: String = "lease-059",
    expiresAt: Date = Date().addingTimeInterval(600),
    revoked: Bool = false,
    autonomyCeiling: AutonomyLevel? = nil
) -> ComposerPolicyFactSource {
    ComposerPolicyFactSource(
        knownCapabilities: [],
        grantedCapabilities: [],
        allowedWriteRoots: [],
        workspaceID: workspaceID,
        revision: revision,
        grantEpoch: grantEpoch,
        leaseID: leaseID,
        expiresAt: expiresAt,
        revoked: revoked,
        autonomyCeiling: autonomyCeiling
    )
}

private func makeWiring059Snapshot(
    taskID: String = "chat:session-059:1:attempt",
    workspaceID: String = "ws-059",
    revision: String = "rev-059",
    grantEpoch: String = "epoch-059"
) -> ComposerSubmissionSnapshot {
    ComposerSubmissionSnapshot(
        mode: .manual,
        approvalScope: .request,
        effort: .standard,
        sessionID: "session-059",
        turnID: 1,
        taskID: taskID,
        workspaceID: workspaceID,
        createdAt: Date(),
        policyRevision: revision,
        grantEpoch: grantEpoch
    )
}

private func makeWiring059Request(
    commandID: String,
    requiresPolicyApproval: Bool
) -> PendingCommandRequest {
    PendingCommandRequest(
        id: UUID(),
        commandID: commandID,
        args: [:],
        requiresPolicyApproval: requiresPolicyApproval
    )
}

/// 与组合根相同形状的接线（ChatStore ↔ Center）。
@MainActor
private func makeWiredWiring059Pair(
    autonomyCeiling: AutonomyLevel? = nil
) -> (ChatStore, ComposerCommandAdjudicationCenter) {
    let chat = ChatStore()
    let center = ComposerCommandAdjudicationCenter()
    chat.configureComposerPolicy(makeWiring059Facts(
        workspaceID: chat.composerWorkspaceID, autonomyCeiling: autonomyCeiling
    ))
    chat.onComposerCommandPolicy = { request, snapshot in
        center.evaluate(
            request: request,
            snapshot: snapshot,
            facts: chat.composerPolicyFacts
        )
    }
    center.canReplayIntoComposer = {
        chat.draftText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chat.pendingAttachments.isEmpty
    }
    center.replaySubmittedCommand = { text in
        chat.draftText = text
        chat.submitComposer()
    }
    return (chat, center)
}

@Suite("Composer command policy wiring (059)")
@MainActor
struct ComposerCommandPolicyWiring059Tests {

    // MARK: - fail-closed 策略评估

    @Test func invalidPolicyFactsFailClosedToReject() {
        let center = ComposerCommandAdjudicationCenter()
        let request = makeWiring059Request(commandID: "compact", requiresPolicyApproval: true)

        // 未装配事实源（.unconfigured：revoked + 过期）
        #expect(center.evaluate(
            request: request,
            snapshot: makeWiring059Snapshot(workspaceID: "unconfigured"),
            facts: .unconfigured
        ) == .reject)

        let workspaceID = "ws-059"
        // 租约过期
        #expect(center.evaluate(
            request: request,
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(
                workspaceID: workspaceID,
                expiresAt: Date().addingTimeInterval(-1)
            )
        ) == .reject)
        // leaseID 为空
        #expect(center.evaluate(
            request: request,
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(workspaceID: workspaceID, leaseID: "")
        ) == .reject)
        // workspace 不匹配
        #expect(center.evaluate(
            request: request,
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(workspaceID: "other-workspace")
        ) == .reject)
        // revision 漂移
        #expect(center.evaluate(
            request: request,
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(workspaceID: workspaceID, revision: "rev-stale")
        ) == .reject)
        #expect(center.pendingAdjudication == nil)
        // 每次非法评估都必须留下可见的拒绝终态与投影（不得静默吞掉）。
        var sawPolicyRejection = false
        if case .some(.rejectedByPolicy(let reason)) = center.lastResolution?.outcome {
            sawPolicyRejection = !reason.isEmpty
        }
        #expect(sawPolicyRejection)
        #expect(center.projection != nil)
    }

    @Test func policyFailureSupersedesUnansweredAdjudication() {
        let center = ComposerCommandAdjudicationCenter()
        let workspaceID = "ws-059"
        let validFacts = makeWiring059Facts(workspaceID: workspaceID)
        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "compact", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: validFacts
        ) == .pending)
        #expect(center.pendingAdjudication != nil)

        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "model", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(workspaceID: workspaceID, revoked: true)
        ) == .reject)
        #expect(center.pendingAdjudication == nil)
        #expect(center.lastResolution?.outcome == .rejectedByPolicy("策略租约已吊销"))
    }

    // MARK: - 调度器 lane

    @Test func scheduledCompactLaneExecutesWithoutInteractivePending() {
        let center = ComposerCommandAdjudicationCenter()
        let workspaceID = "ws-059"
        let facts = makeWiring059Facts(workspaceID: workspaceID)
        let effectID = "scheduler-effect:\(UUID().uuidString.lowercased())"

        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "compact", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(taskID: effectID, workspaceID: workspaceID),
            facts: facts
        ) == .execute)
        #expect(center.pendingAdjudication == nil)

        // 调度 lane 只授权 compact；其它命令 fail-closed，绝不挂成无人消费的 pending。
        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "model", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(taskID: effectID, workspaceID: workspaceID),
            facts: facts
        ) == .reject)
    }

    // MARK: - 批准 → 规范执行闭环

    @Test func approveCompactReplaysThroughCanonicalRouteAndClearsPending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiring-059-compact-success-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID().uuidString
        _ = try store.createSession(id: id)
        let explanation = (0..<40).map { index in
            "Observation \(index): repair cost \(index * 11 + 3), dependency \(index % 7), and alternative \(index + 4) must be compared before deciding."
        }.joined(separator: " ")
        let source: [LLMMessage] = [
            .init(role: .user, content: "Compare repairs. Preserve the title and the read-only constraint."),
            .init(role: .assistant, content: explanation),
            .init(role: .user, content: "Retain the unfinished comparison of alternative B."),
            .init(role: .assistant, content: "The recent option has a distinct inspection."),
            .init(role: .user, content: "Keep that inspection in the comparison."),
            .init(role: .assistant, content: "Ready to continue the same conversation."),
        ]
        for message in source { try store.saveMessage(message, sessionID: id) }
        let (chat, center) = makeWiredWiring059Pair()
        #expect(chat.attachPersistence(store))
        let provider = Wiring059CountingProvider()
        chat.compactionProviderOverride = provider
        let beforeSubmit = chat.messages

        chat.draftText = "/compact"
        chat.submitComposer()

        // 第一段：待批准（生产接线后不再死 pend，而是可见裁决 + 持久回执）。
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(chat.pendingComposerCommand?.commandID == "compact")
        #expect(center.pendingAdjudication?.commandID == "compact")
        #expect(chat.messages == beforeSubmit)
        #expect(provider.callCount == 0)

        // 第二段：用户批准 → 一次性令牌 → 规范 Composer 重放 → ChatStore 执行。
        #expect(center.approveCurrentAdjudication())
        #expect(center.pendingAdjudication == nil)
        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(center.lastResolution?.outcome == .approvedExecuted)

        // Routing/approval alone does not attest compaction success. Await the
        // real checkpoint and verify its derived model view independently.
        for _ in 0..<100 {
            if try store.loadLatestCompactionCheckpoint(sessionID: id) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let checkpoint = try #require(try store.loadLatestCompactionCheckpoint(sessionID: id))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(provider.callCount == 1)
        #expect(chat.messages == beforeSubmit)
        #expect(store.loadSession(id: id)?.messages == source)
        let modelView = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: store, sessionID: id)
        #expect(modelView == checkpoint.replacementHistory)
        #expect(Compactor.hasMaterialRequestReduction(from: source, to: modelView))
        let summaryRequest = try #require(provider.requests.first)
        #expect(summaryRequest.count == 1)
        #expect(summaryRequest.first?.role == .user)
        #expect(summaryRequest.first?.content.contains("===== 对话记录 =====") == true)
        #expect(summaryRequest.first?.content.contains("read-only constraint") == true)
        #expect(modelView.first?.content.contains("Preserve the title and the read-only constraint.") == true)
        #expect(checkpoint.projectionRecentCount == 3)
        #expect(Array(modelView.suffix(3)) == Array(source.suffix(3)))
        #expect(try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: SessionStore(directory: directory), sessionID: id) == modelView)

        // 令牌一次性：再次提交 /compact 必须重新经过批准，不得自动执行。
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication != nil)
        center.denyCurrentAdjudication()
    }

    @Test func keyboardCompactExecutesWithConfirmedBypassWithoutOpeningApproval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiring-059-keyboard-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID().uuidString
        _ = try store.createSession(id: id)
        try store.saveMessage(LLMMessage(role: .user, content: "Short existing context"), sessionID: id)
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        try #require(ProductionCommandRegistryWiring.bind(
            registry: chat.registeredComposerCommandRegistry, chat: chat, center: center
        ))
        try #require(chat.attachPersistence(store))
        try #require(chat.activeSessionID?.uuidString == id)
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))

        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()

        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil)
        #expect(center.pendingAdjudication == nil)
        #expect(chat.messages.last?.content.contains("无需压缩") == true)
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: id) == nil)
    }

    @Test func compactStillRequiresApprovalForOtherOriginsOrModes() {
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        chat.applyNewSession()
        chat.composerPolicySelection.mode = .bypassPermission

        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)

        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.commandID == "compact")
        #expect(center.approveCurrentAdjudication())
        #expect(center.lastResolution?.outcome == .approvedExecuted)
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)

        #expect(chat.submitRegisteredComposerCommand(id: "compact", args: [:]))
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.commandID == "compact")

        chat.composerPolicySelection.mode = .manual
        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.commandID == "compact")
        center.denyCurrentAdjudication()
    }

    @Test func confirmedBypassFromOneSessionDoesNotAuthorizeNativeCommandsInAnother() throws {
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        let first = chat.applyNewSession(title: "Confirmed session")
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))

        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()
        try #require(chat.lastComposerCommandReceipt?.disposition == .execute)

        let second = chat.applyNewSession(title: "Unconfirmed session")
        try #require(first != second && chat.activeSessionID == second)
        try #require(chat.composerPolicySelection.bypassModeConfirmed)
        #expect(!chat.confirmComposerBypass(for: first))
        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()

        #expect(chat.lastComposerCommandReceipt?.sessionID == second.uuidString)
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.sessionID == second.uuidString)
        center.denyCurrentAdjudication()

        try #require(chat.confirmComposerBypass(for: second))
        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(center.pendingAdjudication == nil)
    }

    @Test func revokingBypassRestoresApprovalImmediatelyInTheSameSession() throws {
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        let session = chat.applyNewSession()
        chat.composerPolicySelection.mode = .bypassPermission
        try #require(chat.confirmComposerBypass(for: session))
        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()
        try #require(chat.lastComposerCommandReceipt?.disposition == .execute)

        chat.composerPolicySelection.bypassModeConfirmed = false
        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()

        #expect(chat.activeSessionID == session)
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.sessionID == session.uuidString)
        center.denyCurrentAdjudication()
    }

    @Test func restoredGlobalBypassDoesNotAuthorizeNativeCommands() {
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        chat.applyNewSession()
        chat.restoreComposerPolicy(.init(mode: .bypassPermission, bypassModeConfirmed: true))
        #expect(chat.composerPolicySelection.bypassModeConfirmed)

        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()

        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.commandID == "compact")
        center.denyCurrentAdjudication()
    }

    @Test func keyboardCompactStillRequiresApprovalAfterBypassCeilingFalls() {
        let (chat, center) = makeWiredWiring059Pair(autonomyCeiling: .l3)
        chat.applyNewSession()
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.confirmComposerBypass(for: chat.activeSessionID))
        chat.configureComposerPolicy(makeWiring059Facts(
            workspaceID: chat.composerWorkspaceID, autonomyCeiling: .l2
        ))
        #expect(chat.composerPolicySelection.bypassModeConfirmed)

        chat.draftText = "/compact"
        chat.submitComposerFromKeyboard()

        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication?.commandID == "compact")
        center.denyCurrentAdjudication()
    }

    @Test func approvedShortCompactRefusesWithoutCheckpointAndRequiresNewApproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiring-059-compact-short-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID().uuidString
        _ = try store.createSession(id: id)
        let source = (1...3).map { LLMMessage(role: .assistant, content: "seed \($0)") }
        for message in source { try store.saveMessage(message, sessionID: id) }
        let (chat, center) = makeWiredWiring059Pair()
        #expect(chat.attachPersistence(store))
        let provider = Wiring059CountingProvider()
        chat.compactionProviderOverride = provider
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.approveCurrentAdjudication())
        #expect(chat.pendingComposerCommand == nil)
        #expect(center.lastResolution?.outcome == .approvedExecuted) // route, not checkpoint success
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        for _ in 0..<100 {
            if chat.messages.contains(where: { $0.role == .system && $0.content == "上下文较短，无需压缩。" }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(chat.messages.contains { $0.role == .system && $0.content == "上下文较短，无需压缩。" })
        #expect(provider.callCount == 0)
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: id) == nil)
        #expect(store.loadSession(id: id)?.messages == source)
        #expect(chat.messages.filter { $0.role != .system }.map { $0.asLLMMessage() } == source)

        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(center.pendingAdjudication != nil)
        center.denyCurrentAdjudication()
    }

    @Test func approvalRefusedWhileComposerInputDirtyAndNeverExecuted() {
        let (chat, center) = makeWiredWiring059Pair()
        chat.draftText = "/compact"
        chat.submitComposer()
        #expect(center.pendingAdjudication != nil)

        // 批准时刻输入框已有新草稿：拒绝重放以免覆盖用户输入。
        chat.draftText = "unsent user draft"
        let transcriptBefore = chat.messages
        #expect(!center.approveCurrentAdjudication())
        #expect(center.pendingAdjudication?.commandID == "compact")
        #expect(chat.pendingComposerCommand?.commandID == "compact")
        #expect(chat.messages == transcriptBefore)
        #expect(chat.draftText == "unsent user draft")
    }

    @Test func denyAndExpireTerminalsNeverExecuteTheCommand() {
        let (chat, center) = makeWiredWiring059Pair()
        var replayCount = 0
        center.replaySubmittedCommand = { _ in replayCount += 1 }

        chat.draftText = "/compact hint=second"
        chat.submitComposer()
        #expect(center.pendingAdjudication?.commandID == "compact")
        center.denyCurrentAdjudication()
        #expect(center.lastResolution?.outcome == .deniedByUser)
        #expect(center.pendingAdjudication == nil)
        let expectation561_1 = (center.projection?.text ?? "").contains("已被拒绝")
        #expect(expectation561_1)

        // 超时未答复 → 按拒绝收敛，且之后没有可消费的令牌。
        chat.draftText = "/compact hint=second"
        chat.submitComposer()
        #expect(center.pendingAdjudication?.commandID == "compact")
        center.expireCurrentAdjudication()
        #expect(center.lastResolution?.outcome == .expiredUnanswered)
        let expectation561_2 = (center.projection?.text ?? "").contains("按拒绝处理")
        #expect(expectation561_2)

        chat.draftText = "/compact hint=second"
        chat.submitComposer()
        #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
        #expect(replayCount == 0)
    }

    // /model now opens the desktop model picker immediately. Exercise the
    // canonical settings approval consumer directly, rather than fabricating a
    // Composer slash registration for this App palette command.
    @Test func approveCanonicalSettingsHandsOffWithoutReplay() {
        let center = ComposerCommandAdjudicationCenter()
        var openedSettings = false
        var replayCount = 0
        center.openCanonicalSettings = { openedSettings = true }
        center.replaySubmittedCommand = { _ in replayCount += 1 }
        let decision = center.evaluate(
            request: makeWiring059Request(commandID: "settings.open", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(),
            facts: makeWiring059Facts(workspaceID: "ws-059")
        )
        #expect(decision == .pending)
        #expect(center.pendingAdjudication?.commandID == "settings.open")
        #expect(!openedSettings)
        #expect(center.approveCurrentAdjudication())
        #expect(openedSettings)
        #expect(center.lastResolution?.outcome == .handedToCanonicalSettings)
        #expect(center.pendingAdjudication == nil)
        #expect(replayCount == 0)
        #expect(!center.approveCurrentAdjudication())
        #expect(replayCount == 0)
    }

    @Test func canonicalSettingsHandoffFailsClosedWhenEntryPointMissing() {
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "settings.open", requiresPolicyApproval: true),
            snapshot: makeWiring059Snapshot(),
            facts: makeWiring059Facts(workspaceID: "ws-059")
        ) == .pending)
        let original = center.pendingAdjudication?.id
        #expect(original != nil)
        #expect(!center.approveCurrentAdjudication())
        #expect(center.pendingAdjudication?.id == original)
    }

    // MARK: - 展示命令

    @Test func displayOnlyHelpConsumedWithVisibleProjectionNotTranscript() {
        let (chat, center) = makeWiredWiring059Pair()
        let transcriptBefore = chat.messages

        chat.draftText = "/help"
        chat.submitComposer()

        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.lastComposerCommandReceipt?.commandID == "help")
        #expect(chat.messages == transcriptBefore)
        let projectionText = center.projection?.text ?? ""
        #expect(projectionText.contains("/compact"))
        #expect(projectionText.contains("/model"))
        center.acknowledgeProjection()
        #expect(center.projection == nil)
    }

    @Test func statusProjectionUsesInjectedRuntimeFacts() {
        let center = ComposerCommandAdjudicationCenter()
        let workspaceID = "ws-059"
        center.statusProjection = { _ in "会话：空闲" }
        #expect(center.evaluate(
            request: makeWiring059Request(commandID: "status", requiresPolicyApproval: false),
            snapshot: makeWiring059Snapshot(workspaceID: workspaceID),
            facts: makeWiring059Facts(workspaceID: workspaceID)
        ) == .execute)
        let text = center.projection?.text ?? ""
        #expect(text.contains("会话：空闲"))
        #expect(text.contains("模式：手动审批"))
    }

    // MARK: - 取代语义

    @Test func newerCommandSupersedesUnansweredAdjudication() {
        let (chat, center) = makeWiredWiring059Pair()
        chat.draftText = "/compact"
        chat.submitComposer()
        let firstAdjudicationID = center.pendingAdjudication?.id
        #expect(firstAdjudicationID != nil)

        chat.draftText = "/compact hint=second"
        chat.submitComposer()
        #expect(center.pendingAdjudication?.id != firstAdjudicationID)
        #expect(center.pendingAdjudication?.commandID == "compact")
        // 旧未答复裁决被取代时不得留下任何令牌或可执行残留。
        center.denyCurrentAdjudication()
    }

    // MARK: - 重启恢复

    @Test func restoredPendingCompactReEntersAdjudicationAndApproveExecutes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiring-059-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 第一段：提交 /compact → 生产接线挂裁决 → envelope 持久化 pending。
        let (first, firstCenter) = makeWiredWiring059Pair()
        #expect(first.attachPersistence(SessionStore(directory: directory)))
        first.draftText = "/compact"
        first.submitComposer()
        #expect(firstCenter.pendingAdjudication?.commandID == "compact")
        #expect(first.lastComposerCommandReceipt?.disposition == .pending)

        // 第二段：模拟重启 —— ChatStore 从磁盘恢复 pendingComposerCommand，
        // 裁决层必须重新挂载可见终态（不得回到无人消费的死 pend）。
        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        let restored = try #require(restarted.pendingComposerCommand)
        #expect(restored.commandID == "compact")

        let center = ComposerCommandAdjudicationCenter()
        restarted.configureComposerPolicy(makeWiring059Facts(workspaceID: restarted.composerWorkspaceID))
        restarted.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: restarted.composerPolicyFacts)
        }
        center.canReplayIntoComposer = { restarted.draftText.isEmpty && restarted.pendingAttachments.isEmpty }
        center.replaySubmittedCommand = { text in
            restarted.draftText = text
            restarted.submitComposer()
        }
        // 接线前没有任何裁决可见：
        #expect(center.pendingAdjudication == nil)
        center.adoptRestoredPending(
            restored,
            sessionID: restarted.activeSessionID?.uuidString ?? ""
        )
        #expect(center.pendingAdjudication?.id == restored.id)
        #expect(center.pendingAdjudication?.commandID == "compact")

        // 幂等：同一恢复 ID 重复 adopt 不重置时限、不叠加状态。
        let expiresAt = center.pendingAdjudication?.expiresAt
        center.adoptRestoredPending(restored, sessionID: "")
        #expect(center.pendingAdjudication?.expiresAt == expiresAt)

        // 批准 → 规范重放 → ChatStore 自身 .execute 分支清除 pending。
        // 恢复会话消息数 ≤ keepRecent：compactContext 走「无需压缩」提示，
        // 仍证明命令经过真实执行路径而非静默吞掉。
        #expect(center.approveCurrentAdjudication())
        #expect(restarted.pendingComposerCommand == nil)
        #expect(restarted.lastComposerCommandReceipt?.disposition == .execute)
        #expect(center.lastResolution?.outcome == .approvedExecuted)
        let notice = restarted.messages.last?.content ?? ""
        #expect(notice.contains("无需压缩"))
    }
}
