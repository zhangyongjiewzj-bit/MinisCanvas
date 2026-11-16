import Darwin
import Foundation
import Testing
@testable import MinisCore

private final class SkillInitialReadGate2858: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var reached = false
    private var main = false
    private var timedOut = false
    var entered: Bool { lock.withLock { reached } }
    var enteredOnMain: Bool { lock.withLock { main } }
    var deadlineExpired: Bool { lock.withLock { timedOut } }
    func observe(_ access: SkillStoreFilesystemAccess) {
        guard access == .directoryList else { return }
        let first = lock.withLock {
            if reached { return false }
            reached = true
            main = Thread.isMainThread
            return true
        }
        guard first else { return }
        let expired = releaseSignal.wait(timeout: .now() + .seconds(5)) == .timedOut
        lock.withLock { timedOut = expired }
    }
    func release() { releaseSignal.signal() }
}

@Suite("PERF06 canonical skill bootstrap readiness", .serialized)
@MainActor
struct SkillBootstrapReady2858Tests {
    @Test func firstPhysicalReadAllowsUIPulseThenPreservesAuthorityOnTheSameStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-bootstrap2858-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = SkillStore(skillsRoot: root)
        let content = "---\nname: bootstrap2858\ndescription: Owned synthetic skill\n---\nRetain original skill body.\n"
        let original = try seed.importSkill(content: content)
        let receipt = try #require(seed.lifecycleReceipt(for: original.id))
        let before = try Data(contentsOf: root.appendingPathComponent(original.id).appendingPathComponent("SKILL.md"))
        let receiptsBefore = try Data(contentsOf: seed.lifecycleReceiptsFileURL)
        let gate = SkillInitialReadGate2858()
        let store = SkillStore.startForAppBootstrap(skillsRoot: root, filesystemAccessObserver: { gate.observe($0) })
        defer { gate.release() }
        let entered = await waitUntil { gate.entered }
        #expect(entered, "the real canonical Store initial worker must reach its filesystem boundary")
        guard entered else {
            gate.release()
            await store.waitForInitialLoad()
            Issue.record("initial skill worker did not enter")
            return
        }
        #expect(!gate.enteredOnMain)
        #expect(!store.isInitialLoadComplete)
        #expect(store.skills.isEmpty && store.allSkills().isEmpty)
        #expect(store.rawContent(original.id) == nil)
        #expect(store.readSkillFile(original.id, relativePath: "SKILL.md") == nil)
        #expect(store.lifecycleReceipt(for: original.id) == nil)
        #expect(!store.isInjectable(original))
        #expect(!store.setEnabled(original.id, enabled: false))
        #expect(throws: SkillStoreInitialLoadError.pending) {
            try store.importSkill(content: content)
        }
        let pendingProjection = store.snapshotForTurn()
        #expect(!pendingProjection.isInitialLoadComplete)
        await pendingProjection.waitForInitialLoad()
        #expect(!pendingProjection.isInitialLoadComplete)
        #expect(pendingProjection.captureTurnAuthority().prepareStore() == nil)
        let pendingCapture = store.captureTurnAuthority()
        #expect(pendingCapture.prepareStore() == nil,
                "not-ready must reject turn preparation, not authorize an empty permanent catalog")
        // This heartbeat is on MainActor while the owned physical read remains
        // held. No timer/sleep completion or mock catalog constitutes readiness.
        let cancelledWaiter = Task {
            await store.waitForInitialLoad()
            return Task.isCancelled
        }
        cancelledWaiter.cancel()
        var pulse = false
        await Task { @MainActor in pulse = true; gate.release() }.value
        #expect(await cancelledWaiter.value, "a cancelled consumer cannot cancel or partially publish the canonical initial reader")
        #expect(pulse)
        await store.waitForInitialLoad()
        #expect(!gate.deadlineExpired)
        #expect(store.isInitialLoadComplete)
        #expect(store.allSkills().map(\.id) == [original.id])
        #expect(store.rawContent(original.id) == content)
        #expect(store.lifecycleReceipt(for: original.id) == receipt)
        #expect(!store.matchesTurnAuthority(pendingCapture))
        let currentCapture = store.captureTurnAuthority()
        let prepared = await Task.detached { currentCapture.prepareStore() }.value
        let preparedStore = try #require(prepared)
        #expect(preparedStore.allSkills().map(\.id) == [original.id])
        #expect(preparedStore.rawContent(original.id) == content)
        #expect(store.matchesTurnAuthority(currentCapture))
        #expect(try Data(contentsOf: root.appendingPathComponent(original.id).appendingPathComponent("SKILL.md")) == before)
        #expect(try Data(contentsOf: store.lifecycleReceiptsFileURL) == receiptsBefore)
        let reopened = SkillStore(skillsRoot: root)
        #expect(reopened.isInitialLoadComplete, "the original synchronous initializer contract remains")
        #expect(reopened.allSkills().map(\.id) == [original.id])
        #expect(reopened.lifecycleReceipt(for: original.id) == receipt)
        print("SKILL2858 workerMain=false pulse=true initialCatalogPersisted=true sameCanonicalStore=true actualFrames=NOT_OBSERVED")
    }

    @Test func failedInitialDirectoryReadDoesNotBecomeAnEmptyReadyCatalogAndCanRetry() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-bootstrap-failure2858-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        try Data("owned obstruction".utf8).write(to: root)
        let store = SkillStore.startForAppBootstrap(skillsRoot: root)
        await store.waitForInitialLoad()
        #expect(!store.isInitialLoadComplete)
        #expect(store.captureTurnAuthority().prepareStore() == nil)
        #expect(throws: SkillStoreInitialLoadError.pending) {
            try store.importSkill(content: "---\nname: rejected2858\n---\nNot committed.")
        }
        // Only the owned synthetic obstruction changes. No empty catalog is
        // persisted, and the same instance retries the existing disk reader.
        try FileManager.default.removeItem(at: root)
        let writer = SkillStore(skillsRoot: root)
        let skill = try writer.importSkill(content: "---\nname: retry2858\n---\nRestored original authority.")
        await store.waitForInitialLoad()
        #expect(store.isInitialLoadComplete)
        #expect(store.allSkills().map(\.id) == [skill.id])
        #expect(store.lifecycleReceipt(for: skill.id) == writer.lifecycleReceipt(for: skill.id))
    }

    @Test func boundedOutImportWriterKeepsInitialAuthorityPendingUntilExplicitRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-bootstrap-lock2858-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SkillStore(skillsRoot: root)
        let skill = try writer.importSkill(content: "---\nname: locked2858\n---\nExisting durable skill.")
        let receipt = try #require(writer.lifecycleReceipt(for: skill.id))
        let lockURL = root.appendingPathComponent(skill.id).appendingPathComponent(".skill-import.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let store = SkillStore.startForAppBootstrap(skillsRoot: root)
        let clock = ContinuousClock()
        let start = clock.now
        await store.waitForInitialLoad()
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed >= .seconds(1.8), "initial reader must honor the existing bounded writer wait")
        #expect(elapsed < .seconds(5), "bounded read cannot wait forever on the owned writer")
        #expect(!store.isInitialLoadComplete, "timeout must not convert an omitted existing skill to empty-ready")
        #expect(store.captureTurnAuthority().prepareStore() == nil)
        #expect(!store.setEnabled(skill.id, enabled: false))
        #expect(flock(descriptor, LOCK_UN) == 0)
        await store.waitForInitialLoad()
        #expect(store.isInitialLoadComplete)
        #expect(store.allSkills().map(\.id) == [skill.id])
        #expect(store.lifecycleReceipt(for: skill.id) == receipt)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
