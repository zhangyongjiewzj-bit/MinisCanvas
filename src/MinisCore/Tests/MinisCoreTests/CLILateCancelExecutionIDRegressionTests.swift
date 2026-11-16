import Foundation
import Testing
@testable import MinisCore

@Suite("D-CONC2 completed CLI execution ignores late cancellation", .serialized)
struct CLILateCancelExecutionIDRegressionTests {
    @Test
    func lateCancellationDoesNotPoisonLaterInvocationWithSameExecutionID() async throws {
        let executionID = "late-cancel-\(UUID().uuidString)"
        let task = SubAgentTask(
            id: "same-visible-task", title: "late cancel", instructions: "proof",
            executionID: executionID
        )
        let runner = CodexAgentRunner(binaryPath: "/bin/echo", timeoutSeconds: 3)

        #expect(try await runner.run(task: task) == "exec proof\n")
        await runner.cancel(task: task)
        #expect(try await runner.run(task: task) == "exec proof\n")
    }

    @Test
    func lateCancellationAfterSpawnFailureDoesNotPoisonSameExecutionID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("E23LateSpawnCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // This passes executableExists but makes the production Process.run throw.
        let invalid = directory.appendingPathComponent("invalid-executable")
        try "not an executable format".write(to: invalid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalid.path)

        let task = SubAgentTask(
            id: "same-visible-task", title: "late spawn cancel", instructions: "proof",
            executionID: "late-spawn-cancel-\(UUID().uuidString)"
        )
        let failedRunner = CodexAgentRunner(binaryPath: invalid.path, timeoutSeconds: 3)
        do {
            _ = try await failedRunner.run(task: task)
            Issue.record("invalid executable must fail during Process.run")
            return
        } catch let error as ExternalAgentError {
            guard case .spawnFailed = error else {
                Issue.record("expected spawnFailed, got \(error)")
                return
            }
        }

        // The production cancellation API may arrive after failure cleanup.
        await failedRunner.cancel(task: task)
        let succeedingRunner = CodexAgentRunner(binaryPath: "/bin/echo", timeoutSeconds: 3)
        #expect(try await succeedingRunner.run(task: task) == "exec proof\n")
    }

    @Test
    func unknownExecutionIDStillCancelsBeforeRegistration() async throws {
        let task = SubAgentTask(
            id: "unknown-pre-cancel", title: "unknown pre cancel", instructions: "proof",
            executionID: "unknown-pre-cancel-\(UUID().uuidString)"
        )
        let runner = CodexAgentRunner(binaryPath: "/bin/echo", timeoutSeconds: 3)
        await runner.cancel(task: task)
        await #expect(throws: ExternalAgentError.self) {
            _ = try await runner.run(task: task)
        }
        #expect(try await runner.run(task: task) == "exec proof\n")
    }

    @Test
    func completionHistoryEvictsOldestAfter256DistinctIDs() async throws {
        let runner = CodexAgentRunner(binaryPath: "/bin/echo", timeoutSeconds: 3)
        let prefix = "fifo-\(UUID().uuidString)"
        let oldest = SubAgentTask(
            id: "fifo-oldest", title: "fifo oldest", instructions: "proof",
            executionID: "\(prefix)-0"
        )
        #expect(try await runner.run(task: oldest) == "exec proof\n")
        for index in 1...256 {
            let task = SubAgentTask(
                id: "fifo-\(index)", title: "fifo", instructions: "proof",
                executionID: "\(prefix)-\(index)"
            )
            #expect(try await runner.run(task: task) == "exec proof\n")
        }
        // The first completion is now outside the bounded FIFO. Its late
        // cancel is indistinguishable from pre-cancel and follows that contract.
        await runner.cancel(task: oldest)
        await #expect(throws: ExternalAgentError.self) {
            _ = try await runner.run(task: oldest)
        }
        #expect(try await runner.run(task: oldest) == "exec proof\n")
    }
}
