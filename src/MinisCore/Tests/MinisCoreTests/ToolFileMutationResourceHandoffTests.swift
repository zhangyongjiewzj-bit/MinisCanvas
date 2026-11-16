import Foundation
import Testing
@testable import MinisCore

@Suite struct ToolFileMutationResourceHandoffTests {
    enum ProbeError: Error { case expected }

    private func fixture() throws -> (URL, BuiltinToolExecutor, ToolExecutionFactLedger, AgentExecutionIdentity) {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("goal18-resource-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        #expect(root.path.hasPrefix(profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "resource-session", turnID: 1,
            messageID: "resource-message"), operationID: "resource-operation", attempt: 1)
        return (root, BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), ledger, identity)
    }

    private func mint(_ ledger: ToolExecutionFactLedger, identity: AgentExecutionIdentity, call: String) throws -> ToolExecutionReceipt {
        try ledger.mint(toolCallID: call, toolName: "file_write", attemptID: "resource-attempt", attemptNumber: 1,
            executionIdentity: identity)
    }

    private func write(_ executor: BuiltinToolExecutor, target: URL, text: String,
                       receipt: ToolExecutionReceipt, ledger: ToolExecutionFactLedger) async throws -> String {
        try await ToolExecutionReceiptContext.$current.withValue(receipt) {
            try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
                try await executor.execute(name: "file_write", input: ["path": target.path, "content": text, "append": true])
            }
        }
    }

    @Test func exactCallAttachesRealReceiptOnceAndEachLayerBorrowsOnce() throws {
        let (_, _, ledger, identity) = try fixture()
        let key = ToolExecutionCompositeKey(sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
            messageID: identity.turn.messageID, operationID: identity.operationID, attemptID: "resource-attempt",
            attemptNumber: 1, toolCallID: "first")
        let context = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_write", eventSink: { _ in })
        let lease = ToolFileMutationLease(key: "/owned/file", token: UUID(), approvalContext: context)
        let first = try mint(ledger, identity: identity, call: "first")
        let other = try mint(ledger, identity: identity, call: "other")
        #expect(lease.matchesApprovalContext(context))
        let otherContext = ApprovalPresentationContext(compositeKey: other.compositeKey!, executionIdentity: identity,
            toolName: "file_write", eventSink: { _ in })
        #expect(!lease.matchesApprovalContext(otherContext))
        let wrongToolContext = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_delete", eventSink: { _ in })
        #expect(!lease.matchesApprovalContext(wrongToolContext))
        // A resource identity check does not attach a receipt or authorize an effect.
        #expect(!lease.claimBuiltinUse(key: lease.key, receipt: first))
        #expect(!lease.attachReceipt(other))
        let wrongTool = ToolExecutionReceipt(toolCallID: first.toolCallID, receiptID: "wrong-tool",
            toolName: "file_delete", attemptID: first.attemptID, attemptNumber: first.attemptNumber,
            executionIdentity: identity, compositeKey: first.compositeKey)
        #expect(!lease.attachReceipt(wrongTool))
        let wrongIdentity = ToolExecutionReceipt(toolCallID: first.toolCallID, receiptID: "wrong-identity",
            toolName: first.toolName, attemptID: first.attemptID, attemptNumber: first.attemptNumber,
            executionIdentity: AgentExecutionIdentity(turn: identity.turn, operationID: "other-operation", attempt: 1),
            compositeKey: first.compositeKey)
        #expect(!lease.attachReceipt(wrongIdentity))
        #expect(!lease.claimBuiltinUse(key: lease.key, receipt: first))
        #expect(lease.attachReceipt(first))
        #expect(!lease.attachReceipt(first))
        let swappedReceipt = ToolExecutionReceipt(toolCallID: first.toolCallID, receiptID: "swapped-receipt",
            toolName: first.toolName, attemptID: first.attemptID, attemptNumber: first.attemptNumber,
            executionIdentity: identity, compositeKey: first.compositeKey)
        #expect(lease.hasSameCallKey(swappedReceipt))
        #expect(!lease.matchesCall(swappedReceipt))
        #expect(!lease.claimAuthorizationUse(key: lease.key, receipt: swappedReceipt))
        #expect(lease.claimAuthorizationUse(key: lease.key, receipt: first))
        #expect(!lease.claimAuthorizationUse(key: lease.key, receipt: first))
        #expect(lease.claimRecordingUse(key: lease.key, receipt: first))
        #expect(!lease.claimRecordingUse(key: lease.key, receipt: first))
        #expect(lease.claimBuiltinUse(key: lease.key, receipt: first))
        #expect(!lease.claimBuiltinUse(key: lease.key, receipt: first))
        lease.finishBuiltinUse()
        lease.invalidate()
        #expect(!lease.matchesApprovalContext(context))
        #expect(!lease.matchesCall(first))
        _ = try ledger.settle(first, status: .failed)
        _ = try ledger.settle(other, status: .failed)
    }

    @Test func inheritedSiblingReceiptWaitsThenBothRealAppendsAreAttributed() async throws {
        let (root, executor, ledger, identity) = try fixture()
        let target = root.appendingPathComponent("effects.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        let first = try mint(ledger, identity: identity, call: "first")
        let second = try mint(ledger, identity: identity, call: "second")
        let sibling = try await ToolFileMutationScope.withLock(path: target, receipt: first) {
            let inherited = Task {
                try await ToolFileMutationScope.withLock(path: target, receipt: second) {
                    try await write(executor, target: target, text: "B", receipt: second, ledger: ledger)
                }
            }
            let key = PolicyRuntimePathBoundary.foldedForPathComparison(target.path)
            let deadline = ContinuousClock.now + .seconds(2)
            while await ToolFileMutationSerialiser.shared.waitingCount(key: key) == 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await ToolFileMutationSerialiser.shared.waitingCount(key: key) == 1)
            #expect(try String(contentsOf: target, encoding: .utf8) == "seed")
            _ = try await write(executor, target: target, text: "A", receipt: first, ledger: ledger)
            return inherited
        }
        _ = try await sibling.value
        #expect(try String(contentsOf: target, encoding: .utf8) == "seedAB")
        _ = try ledger.settle(first, status: .succeeded)
        _ = try ledger.settle(second, status: .succeeded)
        #expect(ledger.facts.count == 2 && ledger.pendingReceipts.isEmpty)
        #expect(Set(ledger.facts.map(\.receiptID)) == Set([first.receiptID, second.receiptID]))
    }

    @Test func throwingScopeReleasesBeforeFollowingRealWrite() async throws {
        let (root, executor, ledger, identity) = try fixture()
        let target = root.appendingPathComponent("after-throw.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        let receipt = try mint(ledger, identity: identity, call: "throwing")
        do {
            _ = try await ToolFileMutationScope.withLock(path: target, receipt: receipt) { () async throws -> String in
                throw ProbeError.expected
            }
            Issue.record("scope body should throw")
        } catch { #expect(error is ProbeError) }
        _ = try ledger.settle(receipt, status: .failed)
        _ = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "C", "append": true])
        #expect(try String(contentsOf: target, encoding: .utf8) == "seedC")
    }
    @Test func preApprovalResourceNeedsRealReceiptBeforeActualEffect() async throws {
        let (root, executor, ledger, identity) = try fixture()
        let target = root.appendingPathComponent("pre-approval.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        let key = ToolExecutionCompositeKey(sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
            messageID: identity.turn.messageID, operationID: identity.operationID, attemptID: "resource-attempt",
            attemptNumber: 1, toolCallID: "pre-approval")
        let context = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_write", eventSink: { _ in })
        let lease = try await ToolFileMutationScope.acquireForApproval(path: target, context: context)
        do {
            #expect(lease.receipt == nil)
            do {
                _ = try await ToolFileMutationLease.$current.withValue(lease) {
                    try await executor.execute(name: "file_write", input: ["path": target.path, "content": "bad", "append": true])
                }
                Issue.record("a pre-approval resource lock must never authorize a builtin")
            } catch { #expect(error as? ToolExecutionFactLedgerError == .receiptIdentityMismatch) }
            #expect(try String(contentsOf: target, encoding: .utf8) == "seed")
            let receipt = try mint(ledger, identity: identity, call: "pre-approval")
            _ = try await ToolFileMutationLease.$current.withValue(lease) {
                try await ToolFileMutationScope.withLock(path: target, receipt: receipt) {
                    #expect(ToolFileMutationLease.current?.receipt == receipt)
                    #expect(try await ToolFileMutationScope.borrowRecordingIfOwned(path: target, receipt: receipt))
                    return try await write(executor, target: target, text: "A", receipt: receipt, ledger: ledger)
                }
            }
            _ = try ledger.settle(receipt, status: .succeeded)
            await ToolFileMutationScope.release(lease)
        } catch {
            await ToolFileMutationScope.release(lease)
            throw error
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "seedA")
    }

    @Test func releaseWaitsForAlreadyBorrowedActualBuiltinBeforeSuccessorWrite() async throws {
        let (root, executor, ledger, identity) = try fixture()
        let target = root.appendingPathComponent("actual-in-flight.txt")
        try "synthetic delete bytes".write(to: target, atomically: true, encoding: .utf8)
        executor.fileChangeLedger = FileChangeLedger(workspaceRoot: root.path)
        executor.fileChangeSessionID = identity.turn.sessionID
        let receipt = try ledger.mint(toolCallID: "in-flight-delete", toolName: "file_delete",
            attemptID: "resource-attempt", attemptNumber: 1, executionIdentity: identity)
        let key = try #require(receipt.compositeKey)
        let context = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: "file_delete", eventSink: { _ in })
        let lease = try await ToolFileMutationScope.acquireForApproval(path: target, context: context)
        #expect(lease.attachReceipt(receipt))
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        // Entry, invalidation and successor admission retain their original two-second windows.
        // A missing explicit release fails instead of leaving the fixture parked forever.
        let fixtureHoldDeadline = DispatchTime.now() + 6
        defer { proceed.signal() }
        // The blocking synthetic hook must not occupy a cooperative worker.
        @available(macOS 15.0, *)
        final class FixtureTaskExecutor: TaskExecutor, @unchecked Sendable {
            private let queue = DispatchQueue(label: "resource-handoff.actual-builtin")
            func enqueue(_ job: consuming ExecutorJob) {
                let unownedJob = UnownedJob(job)
                let executor = asUnownedTaskExecutor()
                queue.async { unownedJob.runSynchronously(on: executor) }
            }
        }
        let actualOperation: @Sendable () async throws -> String = {
            try await ToolFileMutationLease.$current.withValue(lease) {
                try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                    try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
                        try await FileDeleteRaceFixture.$beforeFinalCheck.withValue({
                            entered.signal()
                            let holdResult = proceed.wait(timeout: fixtureHoldDeadline)
                            #expect(holdResult == .success,
                                "fixture must explicitly release the in-flight builtin within its original phase windows")
                        }) {
                            try await executor.execute(name: "file_delete", input: ["path": target.path])
                        }
                    }
                }
            }
        }
        let actual: Task<String, Error>
        if #available(macOS 15.0, *) {
            actual = Task(executorPreference: FixtureTaskExecutor(), operation: actualOperation)
        } else {
            // Older runtimes execute the original operation and all original
            // assertions; this is not a conditional test skip or weaker gate.
            actual = Task(operation: actualOperation)
        }
        let entryDeadline = DispatchTime.now() + 2
        let entryResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: entryDeadline))
            }
        }
        #expect(entryResult == .success)
        actual.cancel()
        let releasing = Task { await ToolFileMutationScope.release(lease) }
        let deadline = ContinuousClock.now + .seconds(2)
        while lease.matchesCall(receipt) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!lease.matchesCall(receipt))
        #expect(await ToolFileMutationSerialiser.shared.owns(key: lease.key, token: lease.token))
        let successor = Task {
            try await executor.execute(name: "file_write", input: ["path": target.path, "content": "successor"])
        }
        let waitingDeadline = ContinuousClock.now + .seconds(2)
        while await ToolFileMutationSerialiser.shared.waitingCount(key: lease.key) == 0 && ContinuousClock.now < waitingDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await ToolFileMutationSerialiser.shared.waitingCount(key: lease.key) == 1)
        #expect(FileManager.default.fileExists(atPath: target.path))
        proceed.signal()
        let actualResult = await actual.result
        await releasing.value
        _ = try await successor.value
        #expect(try String(contentsOf: target, encoding: .utf8) == "successor")
        switch actualResult {
        case .success: _ = try ledger.settle(receipt, status: .succeeded)
        case .failure: _ = try ledger.settle(receipt, status: .failed)
        }
    }

    @Test func legacyNilCompositeReceiptSwapFailsClosedWithoutSelfDeadlock() async throws {
        let (root, executor, _, _) = try fixture()
        let target = root.appendingPathComponent("legacy-conflict.txt")
        try "seed".write(to: target, atomically: true, encoding: .utf8)
        let first = ToolExecutionReceipt(toolCallID: "legacy-call", receiptID: "first", toolName: "file_write",
            attemptID: "legacy-attempt", attemptNumber: 1)
        let swapped = ToolExecutionReceipt(toolCallID: "legacy-call", receiptID: "swapped", toolName: "file_write",
            attemptID: "legacy-attempt", attemptNumber: 1)
        do {
            _ = try await ToolFileMutationScope.withLock(path: target, receipt: first) {
                try await ToolFileMutationScope.withLock(path: target, receipt: swapped) { () async throws -> String in
                    Issue.record("a conflicting legacy receipt must not enter an inner scope")
                    return "bad"
                }
            }
            Issue.record("receipt conflict must fail closed")
        } catch { #expect(error as? ToolExecutionFactLedgerError == .receiptIdentityMismatch) }
        _ = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "C", "append": true])
        #expect(try String(contentsOf: target, encoding: .utf8) == "seedC")
    }

}
