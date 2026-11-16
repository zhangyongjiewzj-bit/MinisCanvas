import Foundation
import Testing
@testable import MinisCore

private actor M07EffortEffectProbe: ToolExecutor {
    private(set) var executionCount = 0

    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        await recordExecution()
        return "synthetic-effect"
    }

    private func recordExecution() { executionCount += 1 }
}

@Suite("D-POLICY-08 effort changes budget without changing permission")
struct P3AcceptanceM07EffortPermissionIsolationTests {
    @Test func threeEffortsKeepTheSameAllowedAndDeniedToolDecisions() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let allowedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "M07-Effort-\(UUID().uuidString)", isDirectory: true
        )
        let allowedPath = allowedRoot.appendingPathComponent("draft.txt").path
        let outsidePath = allowedRoot.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt").path
        let cases: [(ComposerEffort, Int, Int)] = [
            (.low, 5, 2048), (.standard, 10, 4096), (.high, 15, 6144),
        ]

        for (effort, iterations, tokens) in cases {
            let snapshot = ComposerSubmissionSnapshot(
                mode: .auto,
                approvalScope: .request,
                effort: effort,
                sessionID: "synthetic-session",
                turnID: 1,
                taskID: "synthetic-task",
                workspaceID: "synthetic-workspace",
                createdAt: now,
                policyRevision: "synthetic-policy",
                autonomyCeiling: .l3
            )
            let profile = ComposerEffortExecutionProfile(
                snapshot: snapshot,
                baseMaxIterations: 10,
                baseMaxTokens: 4096
            )
            #expect(profile.maxIterations == iterations)
            #expect(profile.maxTokens == tokens)

            func facts(granted: Set<String>) -> ComposerPolicyFactSource {
                ComposerPolicyFactSource(
                    knownCapabilities: ["file_write"],
                    grantedCapabilities: granted,
                    allowedWriteRoots: [allowedRoot.path],
                    workspaceID: "synthetic-workspace",
                    revision: "synthetic-policy",
                    leaseID: "synthetic-lease",
                    expiresAt: now.addingTimeInterval(600),
                    autonomyCeiling: .l3
                )
            }

            let allowedProbe = M07EffortEffectProbe()
            let allowed = ComposerPolicyEnforcedToolExecutor(
                base: allowedProbe,
                controller: ComposerAuthorizationController(
                    snapshot: snapshot, facts: facts(granted: ["file_write"]), now: { now }
                )
            )
            let result = try await allowed.execute(
                callID: "allowed-\(effort.rawValue)",
                name: "file_write",
                input: ["path": allowedPath, "content": "synthetic"]
            )
            #expect(result == "synthetic-effect")
            #expect(await allowedProbe.executionCount == 1)

            let missingGrantProbe = M07EffortEffectProbe()
            let missingGrant = ComposerPolicyEnforcedToolExecutor(
                base: missingGrantProbe,
                controller: ComposerAuthorizationController(
                    snapshot: snapshot, facts: facts(granted: []), now: { now }
                )
            )
            await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("file_write")) {
                _ = try await missingGrant.execute(
                    callID: "no-grant-\(effort.rawValue)",
                    name: "file_write",
                    input: ["path": allowedPath, "content": "synthetic"]
                )
            }
            #expect(await missingGrantProbe.executionCount == 0)

            let outsideProbe = M07EffortEffectProbe()
            let outside = ComposerPolicyEnforcedToolExecutor(
                base: outsideProbe,
                controller: ComposerAuthorizationController(
                    snapshot: snapshot, facts: facts(granted: ["file_write"]), now: { now }
                )
            )
            await #expect(throws: ComposerAuthorizationError.pathOutsideAllowedRoots(outsidePath)) {
                _ = try await outside.execute(
                    callID: "outside-\(effort.rawValue)",
                    name: "file_write",
                    input: ["path": outsidePath, "content": "synthetic"]
                )
            }
            #expect(await outsideProbe.executionCount == 0)
        }
    }
}
