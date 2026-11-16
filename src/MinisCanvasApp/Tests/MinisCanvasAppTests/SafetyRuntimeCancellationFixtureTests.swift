import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor BlockingApprovalDelegate: ApprovalDelegate {
    private var requested = false
    private var released = false

    enum WaitError: Error {
        case operationEnded(String)
        case timedOut
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requested = true
        while !released {
            await Task.yield()
        }
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }

    func waitUntilRequested(
        orOperationEnds operation: ApprovalOperationState,
        timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !requested {
            try Task.checkCancellation()
            if let ending = await operation.ending {
                throw WaitError.operationEnded(ending)
            }
            guard ContinuousClock.now < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        released = true
    }
}

private actor ApprovalOperationState {
    private(set) var ending: String?

    func record(_ ending: String) {
        self.ending = ending
    }
}

@Suite("L04 safety runtime cancellation fixtures")
@MainActor
struct SafetyRuntimeCancellationFixtureTests {
    private func makeCenter() -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "L04SafetyFixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        return (center, directory)
    }

    @Test("optional background cancellation preserves checkpoint and forced recovery")
    func optionalBackgroundCancellationPreservesCheckpoint() throws {
        let (center, directory) = makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = BridgeStore()

        bridge.dispatchCanvasMutation(.autoLayout)
        center.setSafeMode(true)
        let receipt = bridge.updateSafetyRuntimeSnapshot(center.safetyRuntimeSnapshot)

        #expect(center.optionalModulesDisabled)
        #expect(receipt.generation == 1)
        #expect(receipt.cancelledOptionalWorkIDs == ["canvas.mutation"])
        #expect(receipt.retainedCheckpointIDs == ["canvas-draft-generation-1"])
        #expect(bridge.safetyRuntimeSnapshot == center.safetyRuntimeSnapshot)
        #expect(!bridge.isSafetyFeatureEnabled(.canvas))
        #expect(bridge.isSafetyFeatureEnabled(.chat))
        #expect(bridge.isSafetyFeatureEnabled(.backup))
        #expect(bridge.isSafetyFeatureEnabled(.recovery))
        #expect(bridge.safetyRuntimeSnapshot.safeModeEnabled)
        #expect(!bridge.safetyRuntimeSnapshot.killSwitchEnabled)
    }

    @Test("replaying Safe Mode snapshot does not duplicate cancellation")
    func replayingSafeModeSnapshotDoesNotDuplicateCancellation() throws {
        let (center, directory) = makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = BridgeStore()

        bridge.dispatchCanvasMutation(.autoLayout)
        center.enableSafeMode()
        let first = bridge.updateSafetyRuntimeSnapshot(center.safetyRuntimeSnapshot)
        let replay = bridge.updateSafetyRuntimeSnapshot(center.safetyRuntimeSnapshot)

        #expect(first == replay)
        #expect(bridge.safetyRuntimeGeneration == 1)
        #expect(bridge.safetyRuntimeCancellationRequests == 1)
        #expect(bridge.safetyRuntimeCheckpointRequests == 1)
        #expect(first.cancelledOptionalWorkIDs == ["canvas.mutation"])
        #expect(first.retainedCheckpointIDs == ["canvas-draft-generation-1"])
    }

    @Test("delete then restart preserves the safety tombstone")
    func deleteThenRestartPreservesSafetyTombstone() throws {
        let (center, directory) = makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }

        center.engageKillSwitch()
        let restarted = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        let bridge = BridgeStore()
        let receipt = bridge.updateSafetyRuntimeSnapshot(restarted.safetyRuntimeSnapshot)

        #expect(receipt.generation == 1)
        #expect(bridge.safetyRuntimeSnapshot == restarted.safetyRuntimeSnapshot)
        #expect(restarted.killSwitchEnabled)
        #expect(restarted.optionalModulesDisabled)
        #expect(!bridge.isSafetyFeatureEnabled(.canvas))
        #expect(bridge.isSafetyFeatureEnabled(.chat))
        #expect(bridge.isSafetyFeatureEnabled(.backup))
        #expect(bridge.isSafetyFeatureEnabled(.recovery))
    }

    @Test("kill and restart reject a late callback from the prior generation")
    func killRestartRejectsLateCallback() async throws {
        let (center, directory) = makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let approval = BlockingApprovalDelegate()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "l11-safety-workspace",
            revision: "l11-safety-revision",
            grantEpoch: "l11-safety-epoch",
            leaseID: "l11-safety-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l1
        )
        let coordinator = CanvasMutationCoordinator(
            target: CanvasStore(),
            facts: facts,
            approvalGate: ApprovalGate(
                policyByTool: ["canvas_mutation": .alwaysAsk],
                delegate: approval
            ),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .manual,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "l11-safety-session",
                    turnID: 1,
                    taskID: "l11-safety-task",
                    attemptID: "l11-safety-attempt",
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: facts.workspaceID,
                    createdAt: Date(),
                    policyRevision: facts.revision,
                    grantEpoch: facts.grantEpoch,
                    autonomyCeiling: facts.autonomyCeiling
                )
            }
        )
        let bridge = BridgeStore(canvasMutationCoordinator: coordinator)
        let operationState = ApprovalOperationState()
        let operation = Task { @MainActor in
            do {
                let receipt = try await bridge.executeCanvasMutation(
                    .resetStatuses,
                    originSessionID: "l11-safety-session"
                )
                await operationState.record("completed before approval")
                return receipt
            } catch {
                await operationState.record("\(type(of: error)): \(error)")
                throw error
            }
        }
        do {
            try await approval.waitUntilRequested(orOperationEnds: operationState)
        } catch {
            operation.cancel()
            await approval.release()
            _ = await operation.result
            Issue.record("fixture never reached approval: \(error)")
            return
        }

        center.engageKillSwitch()
        let transition = bridge.updateSafetyRuntimeSnapshot(center.safetyRuntimeSnapshot)
        #expect(transition.generation == 1)
        #expect(!bridge.isSafetyFeatureEnabled(.canvas))
        #expect(bridge.isSafetyFeatureEnabled(.chat))

        await approval.release()
        do {
            _ = try await operation.value
            Issue.record("A callback captured before the kill switch must be rejected")
        } catch let error as SafetyRuntimeAdmissionError {
            #expect(error == .staleRuntime(.canvas))
        } catch {
            Issue.record("Unexpected late callback error: \(error)")
        }
        #expect(bridge.lastSafetyRuntimeTransitionReceipt.lateCallbackRejected)
    }
}
