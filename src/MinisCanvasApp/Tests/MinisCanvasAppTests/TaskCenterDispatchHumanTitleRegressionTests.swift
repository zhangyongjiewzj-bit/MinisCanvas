import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center canonical dispatch human title", .serialized)
@MainActor
struct TaskCenterDispatchHumanTitleRegressionTests {
    @Test(arguments: [true, false])
    func productionDispatchTitleSurvivesPersistenceReload(verifiedParentTurn: Bool) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "task10-dispatch-title", canvasRuntimeState: .disabled)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let parentID = UUID().uuidString
        let ledger = profile.rootDirectory.appendingPathComponent("task-title-ledger.json")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        let business: Result<Void, any Error>
        do {
            _ = try sessions.createSession(id: parentID, title: "标题回链来源")
            let store = try AgentTaskStore(persistenceURL: ledger)
            let source = ParentRuntimeIdentity(sessionID: parentID, conversationID: parentID,
                turnID: "turn-handle:\(turn.turnID)", taskID: parentID, actorID: "title-regression")
            let goal = GoalEnvelope(scopeID: "title-regression", allowedCapabilities: ["orchestrate"],
                budget: 10, deadline: Date().addingTimeInterval(30), autonomyLevel: .l3)
            let provider = DispatchHumanTitleProvider()
            let executor = BuiltinToolExecutor(allowedRoot: profile.rootDirectory, deniedRoots: [])
            let orchestrator = AgentOrchestrator(provider: provider, toolExecutor: executor,
                approvalGate: ApprovalGate(), deadline: goal.deadline,
                currentConversationID: parentID, taskStore: store, sessionStore: sessions,
                parentID: parentID,
                parentBinding: ParentContextSnapshotV1(providerID: provider.name,
                    modelID: provider.model.id, configurationFingerprint: "title-regression",
                    conversationID: parentID),
                parentRuntimeIdentity: source, parentGoal: goal,
                parentTurnHandle: verifiedParentTurn ? turn : nil, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming], allowedToolNames: []),
                parentCapabilities: [.streaming],
                parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: executor),
                concreteBuiltinToolExecutorOwner: executor)
            let taskID = "internal-dispatch-" + UUID().uuidString
            let producerTitle = "整理采购清单，保留原名称"
            let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: taskID,
                title: producerTitle, instructions: "只返回合成完成文本。", requiredCapabilities: [.streaming])],
                strategy: .sequential)
            #expect(reports.count == 1)
            #expect(reports.first?.result.isSuccess == verifiedParentTurn)
            let reopened = try AgentTaskStore(persistenceURL: ledger)
            let record = try #require(reopened.snapshot(taskID: taskID, parentID: parentID))
            #expect(record.dispatchHumanTitle == producerTitle)
            #expect(record.creation == nil)
            let consumer = TaskCenterControlConsumer(store: reopened)
            let row = try #require(consumer.receiptRows().first { $0.taskID == taskID })
            #expect(row.userTitle == nil)
            #expect(consumer.humanDisplayTitle(for: row) == producerTitle)
            #expect(TaskCenterRowLabelFormatter.title(consumer.humanDisplayTitle(for: row), taskID: taskID) == producerTitle)
            #expect(row.sourceSessionID == (verifiedParentTurn ? parentID : nil))
            // A completed record exercises the existing archive snapshot copy.
            if verifiedParentTurn {
                _ = try consumer.applyArchive(TaskCenterArchiveRequest(taskID: taskID, parentID: parentID,
                    actorID: "title-regression", idempotencyKey: "archive-title", action: .archive))
                let archivedStore = try AgentTaskStore(persistenceURL: ledger)
                #expect(archivedStore.snapshot(taskID: taskID, parentID: parentID)?.dispatchHumanTitle == producerTitle)
            }
            business = .success(())
        } catch { business = .failure(error) }
        // Join the exact production turn after orchestrate has returned its report.
        // No yield/timeout is used as a substitute for this actual lifetime boundary.
        await turn.revoke()
        await turn.finish()
        let cleanup: Result<Void, any Error> = Result { try profile.cleanupDisposableRoots() }
        switch (business, cleanup) {
        case (.failure(let original), .failure(let error)):
            throw DispatchHumanTitleTestError.combined(original, error)
        case (.failure(let error), _), (_, .failure(let error)): throw error
        case (.success, .success): break
        }
    }

    @Test func legacyNilTitleStaysUnknownWithoutIdentityFallback() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(taskID: "internal-legacy-title", parentID: "legacy-parent",
            providerID: "synthetic", modelID: "synthetic")
        var payload = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        payload.removeValue(forKey: "dispatchHumanTitle")
        let decoded = try JSONDecoder().decode(AgentTaskSnapshot.self,
            from: JSONSerialization.data(withJSONObject: payload))
        #expect(decoded.dispatchHumanTitle == nil)
        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.userTitle == nil)
        #expect(consumer.humanDisplayTitle(for: row) == nil)
        #expect(TaskCenterRowLabelFormatter.title(consumer.humanDisplayTitle(for: row), taskID: row.taskID) == "未命名任务")
    }

    @Test func collapsedSpokenLabelsKeepInternalIdentityOut() {
        let internalID = "internal-field-task-01234567-89AB-CDEF"
        let unknownTitle = TaskCenterRowLabelFormatter.title(nil, taskID: internalID)
        let suppliedTitle = TaskCenterRowLabelFormatter.title("用户给过的field-task名称", taskID: internalID)
        for title in [unknownTitle, suppliedTitle] {
            let blocked = TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: title, state: .approvalRequired)
            let observation = TaskCenterRowLabelFormatter.observationAccessibilityLabel(title: title, state: .running)
            #expect(!blocked.contains(internalID))
            #expect(!observation.contains(internalID))
            #expect(blocked.contains(title))
            #expect(observation.contains(title))
            for action in [TaskCenterControlAction.pause, .resume, .stop, .cancel, .retry] {
                let label = TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: title, action: action)
                #expect(label.contains(title))
                #expect(!label.contains(internalID))
            }
        }
    }
}

private enum DispatchHumanTitleTestError: Error {
    case combined(any Error, any Error)
}

private struct DispatchHumanTitleProvider: LLMProvider, Sendable {
    let name = "synthetic-dispatch-title"
    var model = LLMModel(id: "synthetic", displayName: "合成标题回归", provider: "synthetic-dispatch-title")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "合成任务已完成。", stopReason: nil, usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
