import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor MemoryExportBeforeWriteBarrier {
    private var entered = false
    private var entranceWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        for waiter in entranceWaiters { waiter.resume() }
        entranceWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entranceWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("D-CONC2 memory export cancellation")
@MainActor
struct MemoryExportCancellation2261Tests {
    @Test("cancelling the real export before its file write leaves no export")
    func cancellationBeforeWriteDoesNotCreateFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryExport2261-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory, keychain: keychain),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            sessionBadgeStore: SessionBadgeStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)),
            usageStore: UsageStore(domain: .suite("test.task2261.\(UUID().uuidString)"))
        )
        center.memoryScopeProvider = {
            MemoryScope(sessionID: "task2261-session", projectID: "task2261-project")
        }
        _ = try center.provisionMemoryCandidateSubmission()
        #expect(center.addMemoryFact("合成导出事实", category: .lesson))
        let target = directory.appendingPathComponent("exports/cancelled.json")
        let barrier = MemoryExportBeforeWriteBarrier()
        center.memoryExportBeforeWriteForTesting = { await barrier.pause() }

        let operation = Task {
            try await center.exportMemoryFileAsync(format: .json, to: target)
        }
        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()
        switch await operation.result {
        case .success:
            Issue.record("cancelled export unexpectedly completed")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // A normal request still uses the same production writer and read-back.
        center.memoryExportBeforeWriteForTesting = nil
        let normal = directory.appendingPathComponent("exports/normal.json")
        let receipt = try await center.exportMemoryFileAsync(format: .json, to: normal)
        #expect(receipt.byteCount == (try Data(contentsOf: normal)).count)
    }
}
