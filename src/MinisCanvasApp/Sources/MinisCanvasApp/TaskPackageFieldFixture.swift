import Foundation
import Darwin
import MinisCore

/// Optional producer for the ordinary packaged-field Task Center journey.
/// Every visible row is written by the BridgeStore-owned canonical ledger.
/// The approval row comes only from a real child tool call waiting in the
/// BridgeStore-owned ApprovalPromptCenter; this fixture never grants it.
enum TaskPackageFieldFixture {
    static let activationArgument = "--task-field-journey"

    static func longSampleTaskIDs(batch: String) -> [String] {
        let rows = (1...31).map {
            String(format: "F-TASK-LONG-%02d-%@", $0, batch)
        }
        let navigation = ["NAV-04", "NAV-02", "NAV-03", "NAV-05"].map {
            "F-TASK-LONG-\($0)-\(batch)"
        }
        return rows + navigation
    }

    static func longNavigationTargetID(batch: String) -> String {
        "F-TASK-LONG-NAV-04-\(batch)"
    }
    private static let markerName = "task-field-fixture-v1.marker"
    private static let markerContents = "TASK_FIELD_FIXTURE_V1\n"

    enum FixtureError: LocalizedError {
        case unsafeRoot, occupiedLedger, invalidMarker, missingParentSession
        case invalidTerminal, missingLiveApproval, missingGoalBinding

        var errorDescription: String? {
            switch self {
            case .unsafeRoot: "任务现场根不是本用户的 0700 隔离目录"
            case .occupiedLedger: "任务账本已有内容且没有夹具标记；拒绝覆盖"
            case .invalidMarker: "任务现场标记无效；拒绝重建任务"
            case .missingParentSession: "会话现场父会话不存在"
            case .invalidTerminal: "受控任务没有形成真实的完成／失败终态"
            case .missingLiveApproval: "受控任务未形成真实待审批绑定"
            case .missingGoalBinding: "受控任务未取得正常生产 Goal 绑定"
            }
        }
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        sessionFieldJourney: Bool,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let count = arguments.filter { $0 == activationArgument }.count
        guard count > 0 else { return false }
        precondition(count == 1, "Task field journey activation must be unique")
        precondition(profile.mode == .packagedField && sessionFieldJourney,
                     "Task field journey requires the session packaged-field profile")
        precondition(environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1",
                     "Task field journey requires the explicit field marker")
        return true
    }

    /// Called only after AppMain has assembled BridgeStore and attached the
    /// same SessionStore used by ContentView. A marked restart never replays
    /// an unfinished worker, approval, or permission request.
    @MainActor
    static func run(
        profile: RuntimeIsolationProfile,
        bridge: BridgeStore,
        sessionStore: SessionStore
    ) async throws {
        var rootInfo = stat()
        guard lstat(profile.rootDirectory.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_mode & 0o777 == 0o700,
              rootInfo.st_uid == geteuid() else {
            throw FixtureError.unsafeRoot
        }
        let marker = profile.minisCanvasDirectory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == markerContents else {
                throw FixtureError.invalidMarker
            }
            return
        }
        let store = bridge.agentTaskStore
        guard store.taskCenterSnapshots().isEmpty else { throw FixtureError.occupiedLedger }
        guard let parent = sessionStore.listSessions().first(where: {
            $0.title == "S1566 琥珀会话"
        }) else { throw FixtureError.missingParentSession }
        guard let secondaryParent = sessionStore.listSessions().first(where: {
            $0.title == "S1566 青松会话" && $0.id != parent.id
        }) else { throw FixtureError.missingParentSession }

        let toolRoot = profile.rootDirectory.appendingPathComponent(
            "task-field-tool", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: toolRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let preview = toolRoot.appendingPathComponent("approval-preview.txt")
        try "TASK2387 synthetic read-only preview\n".write(
            to: preview, atomically: true, encoding: .utf8
        )
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        // The child orchestrator owns an unstructured provider task. Revoking
        // this exact turn on fixture cancellation lets its lifecycle monitor
        // cancel that task and the pending approval before this scope awaits
        // its two structured workers.
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
        // An explicit always-ask override produces a genuine pending request
        // for a bounded read, without offering a file-mutating child tool.
        let gate = ApprovalGate(
            policyByTool: ["file_read": .alwaysAsk],
            delegate: ApprovalPromptDelegate(center: bridge.approvalCenter)
        )
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: parent.id, conversationID: parent.id,
            turnID: "turn-handle:\(turn.turnID)",
            taskID: parent.id, actorID: "task-field-fixture"
        )
        let goal = GoalEnvelope(
            scopeID: "task-field-" + UUID().uuidString,
            allowedCapabilities: ["orchestrate", "file_read"],
            budget: 100, deadline: Date().addingTimeInterval(600),
            autonomyLevel: .l3
        )
        let lease = AutonomyLease(
            goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: goal.createdAt, expiresAt: goal.deadline
        )
        for parentID in [parent.id, secondaryParent.id] {
            guard bridge.taskCenterControlConsumer.installTopLevelTaskGoal(
                taskID: parentID, goal: goal, lease: lease
            ) else { throw FixtureError.missingGoalBinding }
        }
        let batch = UUID().uuidString
        let runningStarted = RunningFieldWorkerSignal()
        let retryCallCounter = CallCounter()
        let retryProvider = ControlledTaskProvider(
            mode: .retryable, outputRoot: toolRoot, runningSignal: runningStarted,
            callCount: retryCallCounter)
        let originalProviderOverride = bridge.chat.streamingProviderOverride
        defer { bridge.chat.streamingProviderOverride = originalProviderOverride }
        let queuedID = "field-task-queued-" + batch
        _ = try store.enqueue(
            taskID: queuedID, parentID: parent.id,
            providerID: "field-controlled", modelID: "synthetic",
            configurationFingerprint: "task-field-v1",
            parentRuntimeIdentity: parentIdentity,
            dispatchHumanTitle: "现场排队任务"
        )
        let navigationFixtureIDs: Set<String> = [
            longNavigationTargetID(batch: batch),
            "F-TASK-LONG-NAV-05-\(batch)"
        ]
        for (index, taskID) in longSampleTaskIDs(batch: batch).enumerated()
            where !navigationFixtureIDs.contains(taskID) {
            let sourceParentID = index.isMultiple(of: 2) ? parent.id : secondaryParent.id
            let sourceIdentity = ParentRuntimeIdentity(
                sessionID: sourceParentID, conversationID: sourceParentID,
                turnID: parentIdentity.turnID,
                taskID: sourceParentID, actorID: "task-field-fixture"
            )
            _ = try store.enqueue(
                taskID: taskID, parentID: sourceParentID,
                providerID: "field-long-sample", modelID: "synthetic",
                configurationFingerprint: "task-field-long-v1",
                parentRuntimeIdentity: sourceIdentity,
                dispatchHumanTitle: "现场排队样本 \(index + 1)"
            )
        }
        // The marker is committed before async dispatch. A crash leaves only
        // canonical recovery/review facts; restart never resumes a tool call.
        try markerContents.write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: marker.path
        )

        guard let retryGovernor = bridge.orchestrationChildGovernor else {
            throw FixtureError.missingGoalBinding
        }
        let registerRetry = bridge.taskCenterControlConsumer.makeChildRetryRegistration()
        @Sendable func launch(
            _ mode: ControlledTaskProvider.Mode, _ label: String,
            taskID: String? = nil, sourceParentID: String? = nil,
            executionDeadline: Date? = nil
        ) async -> [SubAgentReport] {
            let launchParentID = sourceParentID ?? parent.id
            let launchIdentity = ParentRuntimeIdentity(
                sessionID: launchParentID, conversationID: launchParentID,
                turnID: parentIdentity.turnID,
                taskID: launchParentID, actorID: mode == .retryable ? "app" : "task-field-fixture"
            )
            let provider = ControlledTaskProvider(
                mode: mode, outputRoot: toolRoot, runningSignal: runningStarted,
                callCount: mode == .retryable ? retryCallCounter : CallCounter()
            )
            let executor = BuiltinToolExecutor(allowedRoot: toolRoot, deniedRoots: [])
            var orchestrator = AgentOrchestrator(
                provider: provider, toolExecutor: executor, approvalGate: gate,
                turnController: mode == .retryable ? controller : nil,
                deadline: executionDeadline ?? goal.deadline, currentConversationID: launchParentID,
                taskStore: store, sessionStore: sessionStore, parentID: launchParentID,
                parentBinding: ParentContextSnapshotV1(
                    providerID: provider.name, modelID: provider.model.id,
                    configurationFingerprint: "task-field-v1", conversationID: launchParentID
                ),
                parentRuntimeIdentity: launchIdentity, parentGoal: goal,
                parentTurnHandle: turn, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(
                    allowedCapabilities: [.streaming, .tools],
                    allowedToolNames: ["file_read"]
                ),
                parentCapabilities: [.streaming, .tools],
                parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: executor),
                concreteBuiltinToolExecutorOwner: executor,
                childGovernor: mode == .retryable ? retryGovernor : nil
            )
            if mode == .retryable {
                orchestrator = orchestrator.withChildRetryRegistration(
                    registerRetry)
            }
            let needsTool = mode == .approval
            let task = SubAgentTask(
                id: taskID ?? "field-task-\(label)-\(batch)",
                title: mode == .retryable ? "现场失败后可重试任务" : "现场\(label)任务",
                instructions: "仅使用合成内容；\(label)",
                requiredCapabilities: needsTool ? [.streaming, .tools] : [.streaming],
                resourceRequest: needsTool ? SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [toolRoot.path]
                ) : nil
            )
            let reports = await orchestrator.orchestrate(
                tasks: [task], strategy: .sequential
            )
            return reports
        }

        let completed = await launch(.completed, "completed")
        // These two long-sample rows are real child runs so the field journey
        // can open child/source/result destinations instead of selecting a
        // permanently queued placeholder.
        let navigationCompleted = await launch(
            .completed, "navigation", taskID: longNavigationTargetID(batch: batch)
        )
        let navigationCompanion = await launch(
            .completed, "navigation-companion", taskID: "F-TASK-LONG-NAV-05-\(batch)",
            sourceParentID: secondaryParent.id
        )
        let failed = await launch(.failed, "failed", sourceParentID: secondaryParent.id)
        // Exercise the real child deadline fence; the original four modes retain
        // their 600-second goal and the running worker's 590-second wait.
        let expiredID = "field-task-expired-" + batch
        let expired = await launch(.expired, "expired", executionDeadline: Date().addingTimeInterval(2))
        let expiredRow = bridge.taskCenterControlConsumer.receiptRows().first {
            $0.taskID == expiredID && $0.parentID == parent.id
        }
        guard expired.count == 1, !expired[0].result.isSuccess,
              let expiredRow, expiredRow.isDeadlineExpired,
              let expiredRunID = expiredRow.runID,
              store.receipt(runID: expiredRunID)?.attemptID == expiredRow.attemptID else {
            throw FixtureError.invalidTerminal
        }
        guard completed.count == 1, completed[0].result.isSuccess,
              navigationCompleted.count == 1, navigationCompleted[0].result.isSuccess,
              navigationCompanion.count == 1, navigationCompanion[0].result.isSuccess,
              failed.count == 1, !failed[0].result.isSuccess,
              store.snapshot(taskID: "field-task-completed-" + batch,
                             parentID: parent.id)?.status == .succeeded,
              store.snapshot(taskID: longNavigationTargetID(batch: batch),
                             parentID: parent.id)?.status == .succeeded,
              store.snapshot(taskID: "F-TASK-LONG-NAV-05-" + batch,
                             parentID: secondaryParent.id)?.status == .succeeded,
              store.snapshot(taskID: "field-task-failed-" + batch,
                             parentID: secondaryParent.id)?.status == .failed else {
            throw FixtureError.invalidTerminal
        }
        // The retry is a later ordinary Task Center user event. Preserve this
        // exact synthetic provider for its fresh parent admission; do not click
        // retry or dispatch another attempt from the fixture.
        bridge.chat.streamingProviderOverride = retryProvider
        let retryable = await launch(.retryable, "retryable")
        let retryableRow = bridge.taskCenterControlConsumer.receiptRows().first {
            $0.taskID == "field-task-retryable-" + batch && $0.parentID == parent.id
        }
        let retryLoopLifecycle = await controller.toolLoopLifecycle
        guard retryable.count == 1, !retryable[0].result.isSuccess,
              await turn.isActive(), !(await turn.isCancelled()),
              retryLoopLifecycle.isCurrent(turn.loopIdentity),
              let retryableRow, retryableRow.lifecycleState == .failed,
              retryableRow.retryAvailable,
              let retryableRunID = retryableRow.runID,
              let retryableReceipt = store.receipt(runID: retryableRunID),
              retryableReceipt.attemptID == retryableRow.attemptID,
              case .failed = retryableReceipt.outcome,
              store.settledFailedChildLaunchIntent(taskID: retryableRow.taskID,
                  originalParentID: parent.id, runID: retryableRunID) != nil else {
            throw FixtureError.invalidTerminal
        }
        // The approval sheet is intentionally left pending, but it is a
        // presentation surface rather than the Task Center contract. Open
        // Task Center first so the field operator can capture the canonical
        // waitingApproval/pendingApproval rows, then dismiss that sheet to
        // inspect the still-pending approval prompt in a second phase. This
        // is field-fixture sequencing only; production approval authority and
        // the pending request remain unchanged.
        bridge.taskCenterOpenIntent = TaskCenterOpenIntent(toolbarOpener: false)
        await Task.yield()

        // Both tasks stay in the production child lifecycle until the UI
        // operator acts or the bounded deadline/cancellation closes them.
        async let running: [SubAgentReport] = launch(.running, "running")
        async let approval: [SubAgentReport] = launch(.approval, "approval")
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: .seconds(30))
        var ready = false
        while clock.now < limit {
            try Task.checkCancellation()
            let rows = bridge.taskCenterControlConsumer.receiptRows()
            let queuedRow = rows.first { $0.taskID == queuedID }
            let runningRow = rows.first { $0.taskID == "field-task-running-" + batch }
            let approvalRow = rows.first { $0.taskID == "field-task-approval-" + batch }
            let runningFact = bridge.taskCenterControlConsumer.project().fact(
                taskID: "field-task-running-" + batch, parentID: parent.id
            )
            let workerStarted = await runningStarted.hasStarted
            if queuedRow?.lifecycleState == .queued,
               runningRow?.lifecycleState == .running,
               runningRow?.cancelAvailable == true,
               workerStarted,
               runningFact?.leaseState == .active,
               runningFact?.isGoalBound == true,
               let approvalRow,
               bridge.taskCenterControlConsumer.approvalNavigation(
                   for: approvalRow,
                   pendingRequest: bridge.approvalCenter.pendingRequest
               ) != nil {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard ready else { throw FixtureError.missingLiveApproval }
        print("TASK2387_FIELD_READY canonical=7 retryable=failed-user-action-required expired=deadline-verified approval=bound taskCenter=preopened running=goal-bound-control-ready long=31+4 navigationTarget=\(longNavigationTargetID(batch: batch)) parent=\(parent.id)")
        _ = await running
        let runningID = "field-task-running-" + batch
        let workerObservedCancellation = await runningStarted.hasObservedCancellation
        if store.snapshot(taskID: runningID, parentID: parent.id)?.status == .cancelled,
           let runID = store.controlSnapshot(taskID: runningID, parentID: parent.id)?.runID,
           store.receipt(runID: runID)?.outcome == .cancelled,
           workerObservedCancellation {
            print("TASK04_FIELD_CANCEL worker=cancel-observed ledger=cancelled late-success=fenced run=\(runID)")
        }
        _ = await approval
        } onCancel: {
            Task { await turn.revoke() }
        }
    }
}

private enum ControlledFieldFailure: Error { case expected, unexpectedToolCatalog }

private final class ControlledTaskProvider: LLMProvider {
    enum Mode: Sendable { case completed, failed, running, approval, expired, retryable }
    let name = "field-controlled"
    var model = LLMModel(id: "synthetic", displayName: "现场受控模型", provider: "field-controlled")
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }
    private let mode: Mode
    private let outputRoot: URL
    private let runningSignal: RunningFieldWorkerSignal
    private let callCount: CallCounter

    init(mode: Mode, outputRoot: URL, runningSignal: RunningFieldWorkerSignal,
         callCount: CallCounter = CallCounter()) {
        self.mode = mode
        self.outputRoot = outputRoot
        self.runningSignal = runningSignal
        self.callCount = callCount
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        switch mode {
        case .completed:
            return LLMResponse(text: "合成任务已完成。", stopReason: nil, usage: nil)
        case .failed:
            throw ControlledFieldFailure.expected
        case .retryable:
            guard await callCount.next() == 2 else { throw ControlledFieldFailure.expected }
            return LLMResponse(text: "合成任务经用户重试后成功。", stopReason: nil, usage: nil)
        case .expired:
            // No tool or permission request: cancellation from the two-second
            // production deadline must win over this bounded provider wait.
            try await Task.sleep(for: .seconds(10))
            return LLMResponse(text: "过期任务不应发布成功。", stopReason: nil, usage: nil)
        case .running:
            await runningSignal.markStarted()
            do {
                try await Task.sleep(for: .seconds(590))
                return LLMResponse(text: "受控等待已结束。", stopReason: nil, usage: nil)
            } catch is CancellationError {
                await runningSignal.markCancellationObserved()
                // The worker returns a late success after the real control
                // cancellation, exercising the production result fence.
                return LLMResponse(text: "晚到的合成成功。", stopReason: nil, usage: nil)
            }
        case .approval:
            guard await callCount.next() == 1 else {
                return LLMResponse(text: "现场请求已裁决。", stopReason: nil, usage: nil)
            }
            let path = outputRoot.appendingPathComponent("approval-preview.txt").path
            let input: [String: Any] = ["path": path]
            let raw = try JSONSerialization.data(withJSONObject: input)
            let call = LLMToolCall(
                id: "field-write-" + UUID().uuidString,
                name: "file_read", rawArguments: String(decoding: raw, as: UTF8.self),
                arguments: input
            )
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call])
        }
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        switch mode {
        case .approval:
            guard tools.map(\.name) == ["file_read"] else {
                throw ControlledFieldFailure.unexpectedToolCatalog
            }
        case .completed, .failed, .running, .expired, .retryable:
            guard tools.isEmpty else {
                throw ControlledFieldFailure.unexpectedToolCatalog
            }
        }
        return try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor CallCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor RunningFieldWorkerSignal {
    private var started = false
    private var cancellationObserved = false

    var hasStarted: Bool { started }
    var hasObservedCancellation: Bool { cancellationObserved }
    func markStarted() { started = true }
    func markCancellationObserved() { cancellationObserved = true }
}
