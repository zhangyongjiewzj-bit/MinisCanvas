import Foundation
import Testing
@testable import MinisCore

@Suite struct BackgroundShellPersistenceTests {
    @Test func splitCredentialIsRedactedBeforePersistenceAndCursorReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackgroundShellRegistry(storageRoot: root)
        let id = try registry.reserve(command: "echo synthetic-secret", sessionID: "owner", timeoutSeconds: 30,
            knownSecrets: ["synthetic-secret"])
        registry.appendOutput(id: id, isStdout: true, chunk: Data("synthetic-".utf8))
        registry.appendOutput(id: id, isStdout: true, chunk: Data("secret\nnext\n".utf8))
        let output = try #require(registry.readOutput(id: id, sessionID: "owner", offset: 0))
        #expect(!output.stdout.contains("synthetic-secret"))
        #expect(output.stdout.hasSuffix("next\n"))
        #expect(output.nextOffset == output.stdout.utf8.count)
        #expect(try Data(contentsOf: root.appendingPathComponent(id + ".log")) == Data(output.stdout.utf8))
        #expect(registry.readOutput(id: id, sessionID: "other", offset: 0) == nil)
        #expect(registry.readOutput(id: id, sessionID: "owner", offset: output.nextOffset)?.stdout == "")

        // The earlier chunks only flushed once. Deliver two subsequent chunks
        // through the pipe reader's production consumer after Data was drained.
        registry.appendOutput(id: id, isStdout: true, chunk: Data("G22_START\n".utf8))
        let first = try #require(registry.readOutput(id: id, sessionID: "owner", offset: output.nextOffset))
        #expect(first.stdout == "G22_START\n")
        registry.appendOutput(id: id, isStdout: true, chunk: Data("G22_DONE\nfinal-tail".utf8))
        let second = try #require(registry.readOutput(id: id, sessionID: "owner", offset: first.nextOffset))
        #expect(second.stdout == "G22_DONE\n")

        // Use the real monitor's final drain, rather than exposing a flush
        // hook: an empty owned shell exits and commits the unterminated tail.
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let shell = try owner.spawnShell(command: ":", currentDirectory: root)
        let attached = try registry.attach(id: id, shell: shell)
        try #require(attached != nil)
        await registry.waitUntilFinished(ids: [id], waitSeconds: 5)
        #expect(registry.snapshot(id: id)?.state == .exited)
        #expect(registry.snapshot(id: id)?.exitCode == 0)
        let final = try #require(registry.readOutput(id: id, sessionID: "owner", offset: second.nextOffset))
        #expect(final.stdout == "final-tail")
        #expect(final.nextOffset == output.nextOffset + "G22_START\nG22_DONE\nfinal-tail".utf8.count)
        let complete = try #require(registry.readOutput(id: id, sessionID: "owner", offset: 0))
        #expect(complete.stdout == output.stdout + "G22_START\nG22_DONE\nfinal-tail")
        #expect(!complete.stdout.contains("synthetic-secret"))
        #expect(try Data(contentsOf: root.appendingPathComponent(id + ".log")) == Data(complete.stdout.utf8))
    }

    @Test func oneCorruptRecordDoesNotBlockRecoveryOfTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = BackgroundShellPersistence(root: root)
        let good = BackgroundShellSnapshot(
            id: "bg-good0001", sessionID: "owner", commandPreview: "echo ok", state: .exited,
            exitCode: 0, processID: 1, startedAt: Date(), endedAt: Date(), timeoutSeconds: 30,
            stdoutBytes: 0, stderrBytes: 0, endNote: nil)
        try persistence.write(.init(snapshot: good, processStart: nil))
        let bad = root.appendingPathComponent("bg-bad00001.json")
        try Data("{not json".utf8).write(to: bad)
        let records = try persistence.records()
        #expect(records.map(\.snapshot.id) == ["bg-good0001"])
        // 损坏文件原样保留，不被删除。
        #expect(FileManager.default.fileExists(atPath: bad.path))
    }

    @Test func persistedOutputPagesPreserveUTF8AcrossTheReadLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackgroundShellRegistry(storageRoot: root)
        let id = try registry.reserve(command: "synthetic pagination", sessionID: "owner", timeoutSeconds: 30)
        let pageLimit = 128 * 1024
        let prefix = String(repeating: "a", count: pageLimit - 1)
        let suffix = "🧭边界\n"
        let bytes = Data((prefix + suffix).utf8)
        registry.appendOutput(id: id, isStdout: true, chunk: bytes)

        let first = try #require(registry.readOutput(id: id, sessionID: "owner", offset: 0))
        #expect(first.readError == nil)
        #expect(first.stdout == prefix)
        #expect(first.nextOffset == pageLimit - 1)
        #expect(first.moreAvailable)
        #expect(registry.readOutput(id: id, sessionID: "other", offset: first.nextOffset) == nil)

        let second = try #require(registry.readOutput(id: id, sessionID: "owner", offset: first.nextOffset))
        #expect(second.readError == nil)
        #expect(second.stdout == suffix)
        #expect(Data((first.stdout + second.stdout).utf8) == bytes)
        #expect(second.nextOffset == bytes.count)
        #expect(!second.moreAvailable)

        let end = try #require(registry.readOutput(id: id, sessionID: "owner", offset: second.nextOffset))
        #expect(end.readError == nil)
        #expect(end.stdout.isEmpty && !end.moreAvailable)
        #expect(end.nextOffset == second.nextOffset)
    }

    @Test func fullRegistryRejectsBeforeStartingAnotherJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackgroundShellRegistry(storageRoot: root, maximumRunning: 1)
        _ = try registry.reserve(command: "synthetic", sessionID: "owner", timeoutSeconds: 30)
        #expect(throws: BackgroundShellError.tooManyRunning(limit: 1)) {
            _ = try registry.reserve(command: "synthetic", sessionID: "owner", timeoutSeconds: 30)
        }
    }

    @Test func stopRequestsRemainBoundToOwningSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackgroundShellRegistry(storageRoot: root)
        let id = try registry.reserve(command: "synthetic", sessionID: "owner", timeoutSeconds: 30)
        #expect(!registry.stop(id: id, reason: .model, sessionID: "other"))
        #expect(registry.events().isEmpty)
        #expect(registry.stop(id: id, reason: .model, sessionID: "owner"))
        #expect(registry.events().last?.reason == .model)
    }

    @Test func restartMarksUnmatchedOwnershipInterruptedAndRetainsOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = BackgroundShellPersistence(root: root)
        let snapshot = BackgroundShellSnapshot(id: "bg-synthetic", sessionID: "owner", commandPreview: "synthetic",
            state: .running, exitCode: nil, processID: 0, startedAt: Date(), endedAt: nil,
            timeoutSeconds: 30, stdoutBytes: 5, stderrBytes: 0, endNote: nil)
        try persistence.write(.init(snapshot: snapshot, processStart: nil))
        try persistence.append("done\n", id: snapshot.id)
        let registry = BackgroundShellRegistry(storageRoot: root)
        #expect(try registry.recoverInterruptedJobs() == 0)
        #expect(registry.snapshot(id: snapshot.id)?.state == .interrupted)
        #expect(registry.readOutput(id: snapshot.id, sessionID: "owner", offset: 0)?.stdout == "done\n")
    }
}
