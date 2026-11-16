import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor BackupExportBeforeDispatchBarrier {
    private var entered = false
    private var entranceWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entranceWaiter?.resume()
        entranceWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entranceWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("D-CONC2 backup export cancellation")
@MainActor
struct BackupExportCancellation2292Tests {
    @Test("a cancelled real backup export does not dispatch the file write")
    func cancelledBeforeDispatchLeavesNoBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExport2292-\(UUID().uuidString)", isDirectory: true)
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
            usageStore: UsageStore(domain: .suite("test.task2292.\(UUID().uuidString)"))
        )
        try center.sessionStore.createSession(id: "synthetic-backup-session", title: "合成备份会话")
        let target = directory.appendingPathComponent("cancelled.minissync")
        let barrier = BackupExportBeforeDispatchBarrier()
        center.backupExportBeforeDispatchForTesting = { await barrier.pause() }

        let operation = Task {
            await center.exportBackupAsync(to: target, protection: .legacy)
        }
        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()
        let result = await operation.value
        #expect(result.isError)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        center.backupExportBeforeDispatchForTesting = nil
        let normal = directory.appendingPathComponent("normal.minissync")
        let normalResult = await center.exportBackupAsync(to: normal, protection: .legacy)
        #expect(!normalResult.isError)
        #expect((try Data(contentsOf: normal)).count > 0)
    }
}
