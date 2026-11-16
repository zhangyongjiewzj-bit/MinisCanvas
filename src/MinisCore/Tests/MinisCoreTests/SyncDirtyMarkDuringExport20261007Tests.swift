import Foundation
import Testing
@testable import MinisCore

/// Holds SyncManager's real MemoryStore.loadFacts consumer after it has read
/// dirtyScopes, without adding a test seam to SyncManager or touching live data.
private final class HeldMemoryFactsRead20261007: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var visits = 0

    var hasEntered: Bool { lock.withLock { entered } }

    func beforeRead() {
        let shouldHold = lock.withLock { () -> Bool in
            visits += 1
            if visits == 1 {
                entered = true
                return true
            }
            return false
        }
        if shouldHold {
            _ = releaseSignal.wait(timeout: .now() + .seconds(5))
        }
    }

    func release() { releaseSignal.signal() }
}

@Suite("D-CONC2 SyncManager export dirty generation", .serialized)
struct SyncDirtyMarkDuringExport20261007Tests {
    @Test("a new mark during export remains dirty for the next snapshot")
    func markAfterSnapshotBeforeClearIsNotLost() async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("sync-dirty-\(UUID().uuidString)", isDirectory: true)
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let core = root.appendingPathComponent("core", isDirectory: true)
        let facts = chat.appendingPathComponent("memory/facts.json")
        try FileManager.default.createDirectory(at: facts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: facts)
        defer { try? FileManager.default.removeItem(at: root) }

        let held = HeldMemoryFactsRead20261007()
        defer { held.release() }
        let memory = MemoryStore(
            directory: chat,
            lifecycleTransactionFaultInjector: nil,
            beforeFactsReadForTesting: held.beforeRead
        )
        let manager = SyncManager(
            sessionStore: SessionStore(directory: chat),
            memoryStore: memory,
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: core)
        )
        #expect(manager.dirtyScopes.isEmpty)

        let first = Task.detached {
            try manager.exportSnapshot(scopes: [.memories])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !held.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard held.hasEntered else {
            first.cancel()
            held.release()
            _ = try? await first.value
            Issue.record("MemoryStore hook never reached: cannot claim this interleaving")
            return
        }

        // The callback is inside loadFacts, which exportSnapshot invokes only
        // after capturing dirtyNow at SyncManager.swift:183. markDirty does not
        // use the persistence fence or the MemoryStore lock held by this read.
        manager.markDirty(.memories)
        #expect(manager.dirtyScopes.contains(.memories))
        held.release()

        let firstData = try await first.value
        let firstEnvelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: firstData)
        #expect(firstEnvelope.manifest.dirtyScopes?.contains(SyncScope.memories.rawValue) != true)

        // A new event after dirtyNow was not exported. It must survive for the
        // next snapshot; a plain clearDirty(selected) loses this generation.
        #expect(manager.dirtyScopes.contains(.memories))
        let secondData = try manager.exportSnapshot(scopes: [.memories])
        let secondEnvelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: secondData)
        #expect(secondEnvelope.manifest.dirtyScopes?.contains(SyncScope.memories.rawValue) == true)
    }

    @Test("a replacement mark of an already dirty scope survives export")
    func replacementMarkOfAlreadyDirtyScopeSurvives() async throws {
        let held = HeldMemoryFactsRead20261007()
        defer { held.release() }
        let (manager, root) = try makeManager(beforeRead: held.beforeRead)
        defer { try? FileManager.default.removeItem(at: root) }
        manager.markDirty(.memories)
        let first = Task.detached { try manager.exportSnapshot(scopes: [.memories]) }
        try await waitForRead(held, first: first)
        manager.markDirty(.memories)
        held.release()
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: await first.value)
        #expect(envelope.manifest.dirtyScopes == [SyncScope.memories.rawValue])
        #expect(manager.dirtyScopes == [.memories])
        let second = try JSONDecoder().decode(SyncSnapshotEnvelope.self,
            from: manager.exportSnapshot(scopes: [.memories]))
        #expect(second.manifest.dirtyScopes == [SyncScope.memories.rawValue])
        #expect(manager.dirtyScopes.isEmpty)
    }

    @Test("normal export clears only captured selected scopes and clean exports stay clean")
    func normalExportClearsOnlyCapturedSelectedScopes() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.markDirty(.memories)
        manager.markDirty(.settings)
        let first = try JSONDecoder().decode(SyncSnapshotEnvelope.self,
            from: manager.exportSnapshot(scopes: [.memories]))
        #expect(first.manifest.dirtyScopes == [SyncScope.memories.rawValue])
        #expect(manager.dirtyScopes == [.settings])
        let second = try JSONDecoder().decode(SyncSnapshotEnvelope.self,
            from: manager.exportSnapshot(scopes: [.memories]))
        #expect(second.manifest.dirtyScopes == nil)
        #expect(manager.dirtyScopes == [.settings])
        manager.clearDirty(.settings)
        #expect(manager.dirtyScopes.isEmpty)
        manager.markDirty(.memories)
        manager.clearAllDirty()
        #expect(manager.dirtyScopes.isEmpty)
    }

    @Test("protected file export preserves a mark arriving after its snapshot")
    func protectedFileExportPreservesNewMark() async throws {
        let held = HeldMemoryFactsRead20261007()
        defer { held.release() }
        let (manager, root) = try makeManager(beforeRead: held.beforeRead)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("synthetic.minissync")
        let protection = SyncSnapshotProtection.password(UUID().uuidString)
        let first = Task.detached {
            try manager.exportSnapshotFile(scopes: [.memories], to: output, protection: protection)
            return Data()
        }
        try await waitForRead(held, first: first)
        manager.markDirty(.memories)
        held.release()
        _ = try await first.value
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(manager.dirtyScopes == [.memories])
        try manager.exportSnapshotFile(scopes: [.memories], to: output, protection: protection)
        #expect(manager.dirtyScopes.isEmpty)
    }

    private func waitForRead(_ held: HeldMemoryFactsRead20261007,
                             first: Task<Data, Error>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !held.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard held.hasEntered else {
            first.cancel()
            held.release()
            _ = try? await first.value
            throw AgentLoopError.timedOut(3)
        }
    }

    private func makeManager(beforeRead: (@Sendable () -> Void)? = nil) throws -> (SyncManager, URL) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("sync-dirty-control-\(UUID().uuidString)", isDirectory: true)
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let core = root.appendingPathComponent("core", isDirectory: true)
        let facts = chat.appendingPathComponent("memory/facts.json")
        try FileManager.default.createDirectory(at: facts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: facts)
        return (SyncManager(
            sessionStore: SessionStore(directory: chat),
            memoryStore: MemoryStore(directory: chat, lifecycleTransactionFaultInjector: nil,
                beforeFactsReadForTesting: beforeRead),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: core)
        ), root)
    }
}
