import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
@Suite("Task Center status icon producer and asset consumer")
struct TaskCenterRowIconProjection2271Tests {
    @Test("receipt status wins over the fact with Keyline semantics and unresolved fallbacks")
    func receiptPrecedenceAndFallback() {
        let completed = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .completed, taskStatus: .failed
        )
        #expect(completed.systemName == "checkmark.circle")
        #expect(completed.semantic?.icon == .success)
        if case .some(.success) = completed.semantic?.state {} else {
            Issue.record("completed task must use the success token")
        }

        let failed = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .failed, taskStatus: .succeeded
        )
        #expect(failed.semantic?.icon == .warning)
        if case .some(.danger) = failed.semantic?.state {} else {
            Issue.record("failed task must use the danger token")
        }

        let cancelled = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .cancelled, taskStatus: .running
        )
        #expect(cancelled.semantic?.icon == .cancel)
        if case .some(.disabled) = cancelled.semantic?.state {} else {
            Issue.record("cancelled task must retain its disabled semantics")
        }
        let input = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .inputRequired, taskStatus: .running
        )
        #expect(input.semantic?.icon == .help)

        let running = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .running, taskStatus: .succeeded
        )
        #expect(running.systemName == "arrow.triangle.2.circlepath")
        #expect(running.semantic?.icon == .spinner)
        if case .some(.active) = running.semantic?.state {} else {
            Issue.record("running task must retain its active semantics")
        }
        let approval = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: .approvalRequired, taskStatus: .failed
        )
        #expect(approval.systemName == "hand.raised.circle")
        #expect(approval.semantic?.icon == .handOpen)
        let stale = TaskCenterRowIconProjection.make(
            isStale: true, lifecycleState: .completed, taskStatus: .succeeded
        )
        #expect(stale.systemName == "clock.badge.exclamationmark")
        #expect(stale.semantic?.icon == nil)

        let factOnly = TaskCenterRowIconProjection.make(
            isStale: false, lifecycleState: nil, taskStatus: .succeeded
        )
        #expect(factOnly.semantic?.icon == .success)
    }

    @Test("the selected status semantics resolve bundled Keyline layers")
    func selectedAssetsResolve() {
        for icon: MinisIcon in [.success, .warning, .close, .cancel, .help, .spinner] {
            #expect(MinisIconView.renderSource(for: icon) == .keyline)
        }
    }
}
