import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N03 plan approval consumer", .serialized)
@MainActor
struct PlanApprovalConsumerTests {
    private func plan(ceiling: AutonomyLevel) throws -> (ChatStore, UUID) {
        let store = ChatStore()
        store.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: store.composerWorkspaceID, revision: "synthetic-plan",
            leaseID: "synthetic-plan", expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: ceiling))
        store.composerPolicySelection.mode = .plan
        store.appendUser("先给出计划")
        store.appendAssistant("## 计划\n1. 阅读文件\n2. 修改并验证")
        let session = try #require(store.activeSessionID)
        let message = try #require(store.messages.last)
        let snapshot = ComposerSubmissionSnapshot(
            mode: .plan, approvalScope: .request, effort: .standard,
            sessionID: session.uuidString, turnID: 1, taskID: "synthetic-plan",
            workspaceID: store.composerWorkspaceID, createdAt: Date(),
            policyRevision: "synthetic-plan", autonomyCeiling: ceiling)
        store.offerCompletedPlan(sessionID: session, messageID: message.id, snapshot: snapshot)
        return (store, message.id)
    }

    @Test func approvalStartsALiteralTurnOnlyAfterAdmission() async throws {
        let (store, id) = try plan(ceiling: .l2)
        defer { store.stopAllStreamingForSafety() }
        let session = try #require(store.activeSessionID)
        let requests = PlanAdmissionRequests()
        store.agentEngine = FallbackChatEngine(composerPolicyFacts: store.composerPolicyFacts)
        store.streamingProviderOverride = PlanAdmissionProvider(requests: requests)
        #expect(await store.resolvePlanApproval(.approveManual, proposalID: id))
        let running = try #require(store.turnTaskForTests(sessionID: session))
        await running.value
        #expect(store.composerPolicySelection.mode == .manual)
        #expect(store.activePlanApproval == nil)
        #expect(await requests.lastUserText == "我批准上述计划，请开始执行。")
    }

    @Test func refusedAdmissionRestoresTheOriginalModeAndPlanCard() async throws {
        let (store, id) = try plan(ceiling: .l2)
        let selection = store.composerPolicySelection
        // The real invalid-effective-settings admission gate rejects this send.
        store.effectiveSettingsSnapshotSource = { nil }
        #expect(await store.resolvePlanApproval(.approveAutoEdit, proposalID: id) == false)
        #expect(store.composerPolicySelection == selection)
        #expect(store.activePlanApproval?.id == id)
        #expect(!store.isActiveSessionGenerating)
    }

    @Test func queuedInputPreventsPlanApprovalWithoutConsumingEitherOwner() async throws {
        let (store, id) = try plan(ceiling: .l2)
        store.draftText = "already queued"
        #expect(store.enqueueComposer())
        #expect(store.planApprovalDisabledReason(for: .manual) != nil)
        #expect(await store.resolvePlanApproval(.approveManual, proposalID: id) == false)
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.activePlanApproval?.id == id)
        #expect(store.activeQueuedComposerMessages.map(\.text) == ["already queued"])
        #expect(store.takeQueuedComposerForEditing())
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish(); store.stopAllStreamingForSafety() }
        let session = try #require(store.activeSessionID)
        store.agentEngine = FallbackChatEngine(composerPolicyFacts: store.composerPolicyFacts)
        store.streamingProviderOverride = PlanAdmissionProvider(requests: PlanAdmissionRequests(),
            entered: entered.continuation, release: release.stream)
        store.draftText = "start actual busy turn"
        store.submitComposer()
        let running = try #require(store.turnTaskForTests(sessionID: session))
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(store.isActiveSessionGenerating)
        #expect(await store.resolvePlanApproval(.approveManual, proposalID: id) == false)
        #expect(store.composerPolicySelection.mode == .plan)
        release.continuation.finish()
        await running.value
    }

    @Test(arguments: [PlanAdmissionProvider.Outcome.success, .failed, .cancelled])
    private func failedOrCancelledRealPlanTurnDoesNotOfferApproval(outcome: PlanAdmissionProvider.Outcome) async throws {
        let store = ChatStore()
        defer { store.stopAllStreamingForSafety() }
        let session = try #require(store.activeSessionID)
        store.configureComposerPolicy(ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: store.composerWorkspaceID, revision: "plan-terminal",
            leaseID: "plan-terminal", expiresAt: Date().addingTimeInterval(60)))
        store.composerPolicySelection.mode = .plan
        store.agentEngine = FallbackChatEngine(composerPolicyFacts: store.composerPolicyFacts)
        store.streamingProviderOverride = PlanAdmissionProvider(requests: PlanAdmissionRequests(),
            outcome: outcome)
        store.draftText = "make a plan"
        store.submitComposer()
        let running = try #require(store.turnTaskForTests(sessionID: session))
        await running.value
        switch outcome {
        case .success:
            let assistant = try #require(store.messages.last(where: { $0.role == .assistant }))
            let approval = try #require(store.activePlanApproval)
            #expect(approval.id == assistant.id)
            #expect(approval.contextMessageID == assistant.id)
            #expect(approval.markdown == assistant.content)
        case .failed, .cancelled:
            #expect(store.activePlanApproval == nil)
        }
        #expect(!store.isActiveSessionGenerating)
    }

    @Test func continueKeepsPlanAndTranscriptWithoutStartingExecution() async throws {
        let (store, messageID) = try plan(ceiling: .l2)
        let history = store.messages
        let submission = store.lastComposerSubmissionSnapshot
        store.draftText = "把验证步骤拆细一些"
        #expect(await store.resolvePlanApproval(.continuePlanning, proposalID: messageID))
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.messages == history)
        #expect(store.lastComposerSubmissionSnapshot == submission)
        #expect(store.draftText == "把验证步骤拆细一些")
        #expect(store.activePlanApproval == nil)
    }

    @Test func selectingModeAboveCeilingKeepsModeUntilConfirmed() throws {
        let (store, messageID) = try plan(ceiling: .l1)
        store.selectInteractiveComposerMode(.autoEdit)
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.activePlanApproval?.id == messageID)
        #expect(store.lastComposerSubmissionSnapshot == nil)
    }

    @Test func ceilingConfirmationRevokesBeforeFailedWriteAndRetainsPlan() async throws {
        let (store, messageID) = try plan(ceiling: .l1)
        let owner = UUID()
        var events: [String] = []
        store.onSessionPermissionContextChanged = { events.append("revoke") }
        store.persistComposerCeiling = { previous, next in
            #expect(previous == .l1)
            #expect(next == .l2)
            events.append("write")
            return false
        }

        await store.requestPlanApproval(.approveAutoEdit, proposalID: messageID, owner: owner)
        #expect(store.composerCeilingRequest?.proposalID == messageID)
        await store.confirmPlanApprovalCeiling(proposalID: messageID, owner: UUID())
        #expect(events.isEmpty)
        await store.confirmPlanApprovalCeiling(proposalID: messageID, owner: owner)
        #expect(events == ["revoke", "write"])
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.activePlanApproval?.id == messageID)
        #expect(store.lastComposerSubmissionSnapshot == nil)
    }

    @Test func lowCeilingDisablesAndRejectsAutoEditWithoutConsumingPlan() async throws {
        let (store, messageID) = try plan(ceiling: .l1)
        let history = store.messages
        #expect(store.planApprovalDisabledReason(for: .autoEdit) != nil)
        #expect(store.planApprovalDisabledReason(for: .manual) == nil)
        #expect(await store.resolvePlanApproval(.approveAutoEdit, proposalID: messageID) == false)
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.activePlanApproval?.id == messageID)
        #expect(store.messages == history)
        #expect(store.lastComposerSubmissionSnapshot == nil)
    }

    @Test func newerUserMessageMakesOldPlanUnapprovableAndKeepsHistory() async throws {
        let (store, messageID) = try plan(ceiling: .l2)
        store.appendUser("计划需要修改，先不要执行")
        let history = store.messages
        #expect(store.activePlanApproval == nil)
        #expect(await store.resolvePlanApproval(.approveManual, proposalID: messageID) == false)
        #expect(store.composerPolicySelection.mode == .plan)
        #expect(store.messages == history)
        #expect(store.messages.contains(where: { $0.id == messageID && $0.content.hasPrefix("## 计划") }))
        #expect(store.lastComposerSubmissionSnapshot == nil)
    }
}

private actor PlanAdmissionRequests {
    private(set) var lastUserText: String?
    func record(_ messages: [LLMMessage]) { lastUserText = messages.last(where: { $0.role == .user })?.content }
}
private struct PlanAdmissionProvider: LLMProvider, Sendable {
    enum Outcome: Sendable { case success, failed, cancelled }
    let requests: PlanAdmissionRequests
    var outcome: Outcome = .success
    var entered: AsyncStream<Void>.Continuation? = nil
    var release: AsyncStream<Void>? = nil
    let name = "Mock"
    var model = LLMModel(id: "mock-echo", displayName: "Offline admission", provider: "Mock")
    let capabilities: Set<ProviderCapability> = [.streaming]
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        throw LLMError.unsupportedCapability(.tools)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await requests.record(messages)
        entered?.yield(())
        if let release {
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            try Task.checkCancellation()
        }
        switch outcome {
        case .failed: throw LLMError.unsupportedCapability(.streaming)
        case .cancelled: throw CancellationError()
        case .success: break
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("execution response"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
