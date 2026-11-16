import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("R47 P0 Chat/Canvas boundary")
@MainActor
struct R47ChatCanvasBoundaryP0Tests {
    @Test("cancellation during approval cannot commit a late Canvas mutation")
    func cancellationDuringApprovalHasZeroCanvasCalls() async throws {
        try await assertCancelledApprovalHasZeroCanvasCalls(
            label: "cancellation",
            cancel: { $0.cancel() }
        )
    }

    @Test("timeout during approval cannot commit a late Canvas mutation")
    func timeoutDuringApprovalHasZeroCanvasCalls() async throws {
        try await assertCancelledApprovalHasZeroCanvasCalls(
            label: "timeout",
            cancel: { task in
                try await Task.sleep(for: .milliseconds(10))
                task.cancel()
            }
        )
    }

    @Test("missing approval delegate fails closed before any Canvas mutation")
    func missingApprovalHasZeroCanvasCalls() async throws {
        let target = R47CanvasMutationTargetSpy()
        let facts = R47Fixtures.facts()
        let coordinator = R47Fixtures.coordinator(
            target: target,
            facts: facts,
            approvalGate: nil
        )

        await #expect(throws: ComposerAuthorizationError.approvalRequired("canvas_mutation")) {
            _ = try await coordinator.execute(
                .updateNodeContent(content: "缺审批不得写入", id: UUID()),
                originSessionID: "r47-session"
            )
        }
        #expect(target.mutationCount == 0)
        #expect(coordinator.receipts.isEmpty)
    }

    @Test("missing autonomy ceiling fails before approval or Canvas mutation")
    func missingAutonomyCeilingHasZeroCanvasCalls() async throws {
        let target = R47CanvasMutationTargetSpy()
        let facts = R47Fixtures.facts(autonomyCeiling: nil)
        let coordinator = R47Fixtures.coordinator(
            target: target, facts: facts, approvalGate: nil
        )

        await #expect(throws: ComposerAuthorizationError.autonomyCeilingMissing) {
            _ = try await coordinator.execute(
                .updateNodeContent(content: "缺上限不得写入", id: UUID()),
                originSessionID: "r47-session"
            )
        }
        #expect(target.mutationCount == 0)
        #expect(coordinator.receipts.isEmpty)
    }

    private func assertCancelledApprovalHasZeroCanvasCalls(
        label: String,
        cancel: @escaping @Sendable (Task<CanvasMutationReceipt, Error>) async throws -> Void
    ) async throws {
        let target = R47CanvasMutationTargetSpy()
        let latch = R47ApprovalLatch()
        let facts = R47Fixtures.facts()
        let coordinator = R47Fixtures.coordinator(
            target: target,
            facts: facts,
            approvalGate: ApprovalGate(
                policyByTool: ["canvas_mutation": .alwaysAsk],
                delegate: R47DelayedApprovalDelegate(latch: latch)
            )
        )

        let task = Task { @MainActor in
            do {
                let receipt = try await coordinator.execute(
                    .updateNodeContent(content: "迟到\(label)不得写入", id: UUID()),
                    originSessionID: "r47-session"
                )
                await latch.recordTaskOutcome(.succeeded)
                return receipt
            } catch is CancellationError {
                await latch.recordTaskOutcome(.cancelled)
                throw CancellationError()
            } catch let error as ComposerAuthorizationError {
                await latch.recordTaskOutcome(.authorizationFailure(error))
                throw error
            } catch {
                await latch.recordTaskOutcome(.otherFailure(String(reflecting: error)))
                throw error
            }
        }
        func awaitCoordinatorCompletion() async -> R47ApprovalLatch.TaskOutcome {
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                await latch.timeOutCompletion()
            }
            let outcome = await latch.waitForTaskOutcome()
            watchdog.cancel()
            return outcome
        }
        let requestWatchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            await latch.timeOutRequest()
        }
        let request = await latch.waitUntilRequestedOrTaskFinished()
        requestWatchdog.cancel()
        guard case .requested = request else {
            task.cancel()
            await latch.releaseApproval()
            let outcome = await awaitCoordinatorCompletion()
            #expect(Bool(false), "审批前任务失败或超时：\(request)")
            #expect(outcome != .timedOut, "coordinator 取消后仍未终止")
            #expect(target.mutationCount == 0)
            #expect(coordinator.receipts.isEmpty)
            return
        }
        try await cancel(task)
        await latch.releaseApproval()
        let outcome = await awaitCoordinatorCompletion()
        #expect(outcome == .cancelled, "取消后任务应有界失败：\(outcome)")
        #expect(target.mutationCount == 0)
        #expect(coordinator.receipts.isEmpty)
    }

    @Test("Chat command adapters do not expose a Canvas write path")
    func chatAdaptersRemainReadOnlyAtTheProductionCallSite() throws {
        let bridgeSource = try R47Fixtures.source("BridgeStore.swift")
        let workflowSource = try R47Fixtures.source("WorkflowChatController.swift")
        let slashSource = try R47Fixtures.source("TaskCenterSlashCommandAdapter.swift")

        #expect(bridgeSource.contains("ComposerCanvasCommandExecutor"))
        #expect(bridgeSource.contains("canvasMutationCoordinator.execute"))
        #expect(!workflowSource.contains("CanvasStore"))
        #expect(!workflowSource.contains("canvasMutationCoordinator"))
        #expect(!slashSource.contains("CanvasStore"))
        #expect(!slashSource.contains("CanvasMutationCoordinator"))
        #expect(bridgeSource.contains("resolvedCanvas.onEvent"))
        #expect(bridgeSource.contains(
            "if canvasFeatureLane == .phase4OptIn && allowsLegacyCanvasCommandExecutionForTests {\n            chat.onSendCommand ="
        ))

        let start = try #require(
            bridgeSource.range(of: "private func handleCanvasEvent(_ event: CanvasEvent)")
        )
        let eventBody = bridgeSource[start.lowerBound...]
        let end = eventBody.range(of: "\n}\n\n/// The real bottom")
        let isolatedEventBody = end.map { eventBody[..<$0.lowerBound] } ?? eventBody
        let selectionProjection = try #require(
            isolatedEventBody.range(of: "selectedNodeContext = NodeContextInfo")
        )
        let productionBoundary = try #require(
            isolatedEventBody.range(
                of: "guard allowsLegacyCanvasCommandExecutionForTests else { return }"
            )
        )
        #expect(selectionProjection.lowerBound < productionBoundary.lowerBound)
    }
}

private enum R47Fixtures {
    static func facts(autonomyCeiling: AutonomyLevel? = .l1) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "r47-workspace",
            revision: "r47-revision",
            grantEpoch: "r47-epoch",
            leaseID: "r47-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: autonomyCeiling
        )
    }

    static func source(_ fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("MinisCanvasApp/Sources/MinisCanvasApp")
                .appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    @MainActor
    static func coordinator(
        target: any CanvasMutationTarget,
        facts: ComposerPolicyFactSource,
        approvalGate: ApprovalGate?
    ) -> CanvasMutationCoordinator {
        CanvasMutationCoordinator(
            target: target,
            facts: facts,
            grants: ComposerApprovalGrantStore(),
            approvalGate: approvalGate,
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .manual,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "r47-session",
                    turnID: 1,
                    taskID: "r47-task:\(request.id.uuidString)",
                    attemptID: request.id.uuidString,
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: facts.workspaceID,
                    createdAt: Date(),
                    policyRevision: facts.revision,
                    grantEpoch: facts.grantEpoch,
                    autonomyCeiling: facts.autonomyCeiling
                )
            },
            originSessionIDProvider: { "r47-session" }
        )
    }
}

private actor R47ApprovalLatch {
    enum TaskOutcome: Equatable, Sendable {
        case succeeded
        case cancelled
        case authorizationFailure(ComposerAuthorizationError)
        case otherFailure(String)
        case timedOut
    }

    enum RequestOutcome: Sendable {
        case requested
        case taskFinished(TaskOutcome)
        case timedOut
    }

    private var requested = false
    private var released = false
    private var requestTimedOut = false
    private var requestWaiter: CheckedContinuation<RequestOutcome, Never>?
    private var taskOutcome: TaskOutcome?
    private var completionTimedOut = false
    private var completionWaiter: CheckedContinuation<TaskOutcome, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilRequestedOrTaskFinished() async -> RequestOutcome {
        if requested { return .requested }
        if let taskOutcome { return .taskFinished(taskOutcome) }
        if requestTimedOut { return .timedOut }
        return await withCheckedContinuation { requestWaiter = $0 }
    }

    func timeOutRequest() {
        guard !requested, taskOutcome == nil else { return }
        requestTimedOut = true
        requestWaiter?.resume(returning: .timedOut)
        requestWaiter = nil
    }

    func recordTaskOutcome(_ outcome: TaskOutcome) {
        taskOutcome = outcome
        if !requested {
            requestWaiter?.resume(returning: .taskFinished(outcome))
            requestWaiter = nil
        }
        completionWaiter?.resume(returning: outcome)
        completionWaiter = nil
    }

    func waitForTaskOutcome() async -> TaskOutcome {
        if let taskOutcome { return taskOutcome }
        if completionTimedOut { return .timedOut }
        return await withCheckedContinuation { completionWaiter = $0 }
    }

    func timeOutCompletion() {
        guard taskOutcome == nil else { return }
        completionTimedOut = true
        completionWaiter?.resume(returning: .timedOut)
        completionWaiter = nil
    }

    func waitForApproval() async {
        requested = true
        requestWaiter?.resume(returning: .requested)
        requestWaiter = nil
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseApproval() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private struct R47DelayedApprovalDelegate: ApprovalDelegate {
    let latch: R47ApprovalLatch

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await latch.waitForApproval()
        return ApprovalDecision(
            approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
    }
}

@MainActor
private final class R47CanvasMutationTargetSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var mutationCount = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        mutationCount += 1
        return nil
    }

    func runGraph(from _: Set<UUID>?) { mutationCount += 1 }
    func autoLayout() { mutationCount += 1 }
    func resetStatuses() { mutationCount += 1 }

    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool {
        mutationCount += 1
        return true
    }

    func removeNode(id _: UUID) { mutationCount += 1 }

    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        mutationCount += 1
        return true
    }
}
