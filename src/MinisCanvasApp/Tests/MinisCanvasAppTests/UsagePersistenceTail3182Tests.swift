import Foundation
import Darwin
import Testing
@testable import MinisCanvasApp

/// Actual UsageStore owns each durable operation. These tests cancel only the
/// caller waiting for the owned tail, never substitute a persistence executor.
@Suite("Usage persistence owned tail 3182", .serialized)
@MainActor
struct UsagePersistenceTail3182Tests {
    private func fixture() throws -> (UsageStore, String, String) {
        let suite = "com.miniscanvas.task3182.synthetic.\(UUID().uuidString)"
        let key = "task3182.tail.\(UUID().uuidString)"
        let store = UsageStore(domain: .suite(suite), storageKey: key,
                               persistenceLockTimeout: .seconds(3))
        return (store, suite, key)
    }

    private func holdPersistenceLock(_ key: String) throws -> Int32 {
        try FileManager.default.createDirectory(
            atPath: UsageStore.persistenceLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(UsageStore.persistenceLockPath(for: key),
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        return descriptor
    }

    @Test func cancelledWaiterStillJoinsOwnedFIFOAndDoesNotCancelDurableWrites() async throws {
        let (store, suite, key) = try fixture()
        #expect(await store.waitForPersistence())
        let lock = try holdPersistenceLock(key)
        var lockHeld = true
        defer { if lockHeld { _ = flock(lock, LOCK_UN) }; close(lock) }
        store.recordCall(provider: "Synthetic", model: "before-clear", inputTokens: 11, outputTokens: 1)
        store.clear()
        store.recordCall(provider: "Synthetic", model: "after-clear", inputTokens: 23, outputTokens: 7)
        var entered = false
        var returned = false
        let waiter = Task { @MainActor in
            entered = true
            let result = await store.waitForPersistence()
            returned = true
            return result
        }
        while !entered { await Task.yield() }
        waiter.cancel()
        // The real flock prevents the first queued transaction from committing;
        // a canceled caller cannot report a join before the owned tail finishes.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!returned)
        #expect(store.totalCalls == 0)
        #expect(store.lastPersistenceError == nil)
        #expect(flock(lock, LOCK_UN) == 0)
        lockHeld = false
        #expect(await waiter.value)
        #expect(returned)
        #expect(store.totalCalls == 1)
        #expect(store.totalInputTokens == 23)
        #expect(store.totalOutputTokens == 7)
        #expect(store.callHistory.map(\.model) == ["after-clear"])
        #expect(store.persistenceFailureCount == 0)
        let reopened = UsageStore(domain: .suite(suite), storageKey: key)
        #expect(await reopened.waitForPersistence())
        #expect(reopened.callHistory == store.callHistory)
        #expect(reopened.totalCalls == 1)
    }

    @Test func releasedFacadeDoesNotRetainOwnerOrLoseAnAlreadyQueuedDurableOperation() async throws {
        let suite = "com.miniscanvas.task3182.synthetic.\(UUID().uuidString)"
        let key = "task3182.owner.\(UUID().uuidString)"
        var store: UsageStore? = UsageStore(domain: .suite(suite), storageKey: key,
                                            persistenceLockTimeout: .seconds(3))
        #expect(await store!.waitForPersistence())
        let lock = try holdPersistenceLock(key)
        var lockHeld = true
        defer { if lockHeld { _ = flock(lock, LOCK_UN) }; close(lock) }
        weak let retired = store
        store!.recordCall(provider: "Synthetic", model: "retired-owner", inputTokens: 31, outputTokens: 5)
        store = nil
        #expect(retired == nil, "the durable Task must not retain the MainActor facade")
        #expect(flock(lock, LOCK_UN) == 0)
        lockHeld = false
        // Observe only this unique synthetic suite. No production preferences
        // domain, live provider, real account, or keychain is instantiated.
        let defaults = try #require(UserDefaults(suiteName: suite))
        let deadline = ContinuousClock.now + .seconds(3)
        while defaults.data(forKey: key) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(defaults.data(forKey: key) != nil)
        let reopened = UsageStore(domain: .suite(suite), storageKey: key)
        #expect(await reopened.waitForPersistence())
        #expect(reopened.totalCalls == 1)
        #expect(reopened.totalInputTokens == 31)
        #expect(reopened.totalOutputTokens == 5)
        #expect(reopened.callHistory.map(\.model) == ["retired-owner"])
        #expect(retired == nil)
    }
}
