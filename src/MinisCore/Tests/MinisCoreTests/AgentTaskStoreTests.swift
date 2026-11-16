import Foundation
import Testing
@testable import MinisCore

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}


private final class InitializationRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var firstReleased = false
    private var secondEnteredBeforeFirstRelease = false
    let firstEntered = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)

    func waitForRecovery() {
        lock.lock()
        callCount += 1
        let call = callCount
        if call == 2, !firstReleased {
            secondEnteredBeforeFirstRelease = true
        }
        lock.unlock()
        if call == 1 {
            firstEntered.signal()
            releaseFirst.wait()
        } else if call == 2 {
            secondEntered.signal()
            releaseSecond.wait()
        }
    }

    func allowFirst() {
        lock.lock()
        firstReleased = true
        lock.unlock()
        releaseFirst.signal()
    }

    func allowSecond() {
        releaseSecond.signal()
    }

    func violated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return secondEnteredBeforeFirstRelease
    }
}

@Suite("AgentTaskStore", .serialized)
struct AgentTaskStoreTests {
    @Test func retainedBackgroundOwnerAndCompletionRaceUseTheExistingLifecycle() async {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        #expect(await handle.retainForBackground())
        await handle.finish()
        #expect(await handle.isActive())
        let race = ChildOrchestrationRace()
        #expect(race.resolve(.movedToBackground))
        #expect(!race.resolve(.finished([])))
        let outcome = await race.wait()
        if case .movedToBackground = outcome { } else { Issue.record("background branch must retain ownership") }
        await handle.releaseBackground()
        #expect(!(await handle.isActive()))
        #expect(!(await handle.retainForBackground()))
    }

    private func makePersistentStore(_ name: String) throws -> (AgentTaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        return (try AgentTaskStore(persistenceURL: persistenceURL), persistenceURL)
    }

    private func obstruct(_ persistenceURL: URL) throws {
        try? FileManager.default.removeItem(at: persistenceURL)
        try FileManager.default.createDirectory(at: persistenceURL, withIntermediateDirectories: false)
    }

    private func restore(_ persistenceURL: URL) throws {
        try FileManager.default.removeItem(at: persistenceURL)
    }

    private func expectNoTemporaryFile(at persistenceURL: URL) {
        #expect(!FileManager.default.fileExists(atPath: persistenceURL.appendingPathExtension("tmp").path))
    }

    @Test func initializationRecoveryRechecksDurableLedgerInsidePersistenceLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-init-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        let temporaryURL = persistenceURL.appendingPathExtension("tmp")
        defer {
            AgentTaskStore.setInitializationRecoveryTestHook(for: persistenceURL, nil)
            try? FileManager.default.removeItem(at: directory)
        }

        let seed = try AgentTaskStore(persistenceURL: persistenceURL)
        _ = try seed.enqueue(taskID: "seed-task", parentID: "root", providerID: nil, modelID: nil)
        try Data("incomplete-ledger".utf8).write(to: temporaryURL)
        AgentTaskStore.setInitializationRecoveryTestHook(for: persistenceURL) {
            try? FileManager.default.removeItem(at: persistenceURL)
        }

        do {
            _ = try AgentTaskStore(persistenceURL: persistenceURL)
            Issue.record("initialization must fail closed after durable ledger disappears inside recovery lock")
        } catch let error as AgentTaskStoreError {
            guard case .persistenceRecoveryFailed(let diagnostic) = error else {
                Issue.record("unexpected initialization error: \(error)")
                return
            }
            #expect(diagnostic.reason == "durable-ledger-missing")
        }
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test func concurrentInitializationsSerializeRecoveryBeforeReadingLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-init-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer {
            AgentTaskStore.setInitializationRecoveryTestHook(for: persistenceURL, nil)
            try? FileManager.default.removeItem(at: directory)
        }

        let seed = try AgentTaskStore(persistenceURL: persistenceURL)
        _ = try seed.enqueue(taskID: "seed-task", parentID: "root", providerID: nil, modelID: nil)
        let gate = InitializationRecoveryGate()
        AgentTaskStore.setInitializationRecoveryTestHook(for: persistenceURL) { gate.waitForRecovery() }

        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let firstResult = LockedResult<Result<AgentTaskStore, Error>>()
        let secondResult = LockedResult<Result<AgentTaskStore, Error>>()
        Task.detached {
            firstStarted.signal()
            do { firstResult.store(.success(try AgentTaskStore(persistenceURL: persistenceURL))) }
            catch { firstResult.store(.failure(error)) }
            firstFinished.signal()
        }
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)
        #expect(gate.firstEntered.wait(timeout: .now() + 1) == .success)

        Task.detached {
            secondStarted.signal()
            do { secondResult.store(.success(try AgentTaskStore(persistenceURL: persistenceURL))) }
            catch { secondResult.store(.failure(error)) }
            secondFinished.signal()
        }
        #expect(secondStarted.wait(timeout: .now() + 1) == .success)
        #expect(gate.secondEntered.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(!gate.violated())

        gate.allowFirst()
        #expect(gate.secondEntered.wait(timeout: .now() + 1) == .success)
        gate.allowSecond()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        guard case .success(let firstStore)? = firstResult.load(), case .success(let secondStore)? = secondResult.load() else {
            Issue.record("both initializations must succeed after serialized recovery")
            return
        }
        #expect(firstStore.snapshot(taskID: "seed-task", parentID: "root")?.status == .queued)
        #expect(secondStore.snapshot(taskID: "seed-task", parentID: "root")?.status == .queued)
    }

    @Test func initializationWaitsForExternalProcessPersistenceLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-init-process-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        let lockURL = persistenceURL.appendingPathExtension("lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = try AgentTaskStore(persistenceURL: persistenceURL)
        _ = try seed.enqueue(taskID: "seed-task", parentID: "root", providerID: nil, modelID: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl, os, sys; fd=os.open(sys.argv[1], os.O_CREAT|os.O_RDWR, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); print('ready', flush=True); sys.stdin.read(); fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)", lockURL.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        let ready = output.fileHandleForReading.readData(ofLength: 6)
        #expect(String(data: ready, encoding: .utf8) == "ready\n")

        let finished = DispatchSemaphore(value: 0)
        let result = LockedResult<Result<AgentTaskStore, Error>>()
        Task.detached {
            do { result.store(.success(try AgentTaskStore(persistenceURL: persistenceURL))) }
            catch { result.store(.failure(error)) }
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)

        input.fileHandleForWriting.write(Data("release\n".utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        guard case .success(let recovered)? = result.load() else {
            Issue.record("initialization must complete after external persistence lock release")
            return
        }
        #expect(recovered.snapshot(taskID: "seed-task", parentID: "root")?.status == .queued)
    }

    @Test func externalDeletionFailsClosedInsteadOfRecreatingFromMemory() throws {
        let (store, persistenceURL) = try makePersistentStore("external-deletion")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "existing-task", parentID: "root", providerID: nil, modelID: nil)
        try FileManager.default.removeItem(at: persistenceURL)

        #expect(throws: AgentTaskStoreError.staleWriter) {
            _ = try store.enqueue(taskID: "new-task", parentID: "root", providerID: nil, modelID: nil)
        }
        #expect(store.snapshot(taskID: "existing-task", parentID: "root")?.status == .queued)
        #expect(store.snapshot(taskID: "new-task", parentID: "root") == nil)
    }

    @Test func staleWriterFailsClosedInsteadOfOverwritingAnotherStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-stale-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try AgentTaskStore(persistenceURL: persistenceURL)
        let second = try AgentTaskStore(persistenceURL: persistenceURL)
        _ = try first.enqueue(taskID: "first-task", parentID: "root", providerID: nil, modelID: nil)

        #expect(throws: AgentTaskStoreError.staleWriter) {
            _ = try second.enqueue(taskID: "second-task", parentID: "root", providerID: nil, modelID: nil)
        }
        #expect(try AgentTaskStore(persistenceURL: persistenceURL).snapshot(taskID: "first-task", parentID: "root")?.status == .queued)
        #expect(try AgentTaskStore(persistenceURL: persistenceURL).snapshot(taskID: "second-task", parentID: "root") == nil)
    }

    @Test func concurrentInstancesAllowOneCommitAndRejectTheStaleWriter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-concurrent-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try AgentTaskStore(persistenceURL: persistenceURL)
        let second = try AgentTaskStore(persistenceURL: persistenceURL)
        let results = await withTaskGroup(of: Result<String, Error>.self, returning: [Result<String, Error>].self) { group in
            group.addTask {
                do {
                    _ = try first.enqueue(taskID: "concurrent-first", parentID: "root", providerID: nil, modelID: nil)
                    return .success("first")
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    _ = try second.enqueue(taskID: "concurrent-second", parentID: "root", providerID: nil, modelID: nil)
                    return .success("second")
                } catch {
                    return .failure(error)
                }
            }
            var collected: [Result<String, Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.filter { if case .success = $0 { return true }; return false }.count == 1)
        #expect(results.contains { if case .failure(let error) = $0 { return (error as? AgentTaskStoreError) == .staleWriter }; return false })
        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reloaded.snapshot(taskID: "concurrent-first", parentID: "root") != nil || reloaded.snapshot(taskID: "concurrent-second", parentID: "root") != nil)
    }

    @Test func staleWriterDiagnosticIdentifiesConcurrentMutationWithoutPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-stale-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try AgentTaskStore(persistenceURL: persistenceURL)
        let second = try AgentTaskStore(persistenceURL: persistenceURL)
        _ = try first.enqueue(taskID: "first", parentID: "root", providerID: nil, modelID: nil)

        #expect(throws: AgentTaskStoreError.staleWriter) {
            _ = try second.enqueue(taskID: "second", parentID: "root", providerID: nil, modelID: nil)
        }
        let diagnostic = try #require(second.persistenceDiagnostics())
        #expect(diagnostic.operation == "persist")
        #expect(diagnostic.reason == "stale-writer")
        #expect(!diagnostic.message.contains(persistenceURL.path))
    }

    @Test func persistenceFailureSurfacesActionableDiagnosticWithoutLeakingPath() throws {
        let (store, persistenceURL) = try makePersistentStore("diagnostic")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        try obstruct(persistenceURL)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try store.enqueue(taskID: "diagnostic-task", parentID: "root", providerID: nil, modelID: nil)
        }
        let diagnostic = try #require(store.persistenceDiagnostics())
        #expect(diagnostic.operation == "persist")
        #expect(diagnostic.reason == "destination-is-directory")
        #expect(!diagnostic.message.contains(persistenceURL.path))
    }

    @Test func failedEnqueuePersistenceRollsBackAndRetrySucceeds() throws {
        let (store, persistenceURL) = try makePersistentStore("enqueue")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        try obstruct(persistenceURL)

        #expect(throws: (any Error).self) {
            _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        }
        #expect(store.snapshot(taskID: "task", parentID: "root") == nil)
        expectNoTemporaryFile(at: persistenceURL)

        try restore(persistenceURL)
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        #expect(store.snapshot(taskID: "task", parentID: "root")?.status == .queued)
    }

    @Test func failedStartRunPersistenceRollsBackAndRetrySucceeds() throws {
        let (store, persistenceURL) = try makePersistentStore("start")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        try obstruct(persistenceURL)

        #expect(throws: (any Error).self) {
            _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        }
        #expect(store.snapshot(taskID: "task", parentID: "root")?.status == .queued)
        #expect(store.attempts(runID: "run").isEmpty)
        expectNoTemporaryFile(at: persistenceURL)

        try restore(persistenceURL)
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        #expect(store.snapshot(taskID: "task", parentID: "root")?.status == .running)
        #expect(store.attempts(runID: "run").count == 1)
    }

    @Test func failedAppendEventPersistenceRollsBackAndRetrySucceeds() throws {
        let (store, persistenceURL) = try makePersistentStore("event")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        try obstruct(persistenceURL)

        #expect(throws: (any Error).self) {
            _ = try store.appendEvent(runID: "run", kind: .progress, detail: "ignored")
        }
        #expect(store.events(runID: "run").isEmpty)
        expectNoTemporaryFile(at: persistenceURL)

        try restore(persistenceURL)
        let event = try store.appendEvent(runID: "run", kind: .progress, detail: "ignored")
        #expect(event.sequence == 1)
    }

    @Test func failedFinishPersistenceRollsBackAndRetrySucceeds() throws {
        let (store, persistenceURL) = try makePersistentStore("finish")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        try obstruct(persistenceURL)

        #expect(throws: (any Error).self) {
            _ = try store.finish(runID: "run", outcome: .succeeded)
        }
        #expect(store.snapshot(taskID: "task", parentID: "root")?.status == .running)
        #expect(store.attempts(runID: "run").first?.status == .running)
        #expect(store.events(runID: "run").isEmpty)
        #expect(store.allReceipts().isEmpty)
        expectNoTemporaryFile(at: persistenceURL)

        try restore(persistenceURL)
        _ = try store.finish(runID: "run", eventKind: .completed, detail: "ignored", outcome: .succeeded)
        #expect(store.snapshot(taskID: "task", parentID: "root")?.status == .succeeded)
        #expect(store.events(runID: "run").map(\.kind) == [.completed])
        #expect(store.allReceipts().count == 1)
    }

    @Test func persistentStoreReloadsExistingCompletedState() throws {
        let (store, persistenceURL) = try makePersistentStore("reload")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        _ = try store.appendEvent(runID: "run", kind: .progress, detail: "private detail")
        _ = try store.finish(runID: "run", outcome: .succeeded)

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)

        #expect(reloaded.snapshot(taskID: "task", parentID: "root")?.status == .succeeded)
        #expect(reloaded.attempts(runID: "run").first?.status == .succeeded)
        #expect(reloaded.events(runID: "run").map(\.detail) == ["progress", "completed"])
        #expect(reloaded.allReceipts().map(\.runID) == ["run"])
    }

    @Test(arguments: ["gap", "duplicate", "reversed", "zero", "negative", "huge", "unknown-kind"])
    func persistedEventContractRejectsParseableCorruption(_ corruption: String) throws {
        let (store, url) = try makePersistentStore("event-contract-\(corruption)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        _ = try store.appendEvent(runID: "run", kind: .progress, detail: "private")
        _ = try store.finish(runID: "run", outcome: .succeeded)
        #expect(store.events(runID: "run").map(\.sequence) == [1, 2])

        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var state = try #require(envelope["state"] as? [String: Any])
        var events = try #require(state["events"] as? [String: [[String: Any]]])
        var runEvents = try #require(events["run"])
        switch corruption {
        case "gap": runEvents[1]["sequence"] = 3
        case "duplicate": runEvents[1]["sequence"] = 1
        case "reversed": runEvents.reverse()
        case "zero": runEvents[0]["sequence"] = 0
        case "negative": runEvents[0]["sequence"] = -1
        case "huge": runEvents[1]["sequence"] = Int.max
        case "unknown-kind": runEvents[0]["kind"] = "unrecognized-required-event"
        default: Issue.record("Unknown corruption fixture"); return
        }
        events["run"] = runEvents
        state["events"] = events
        envelope["state"] = state
        let corrupted = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try corrupted.write(to: url)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == corrupted)
        expectNoTemporaryFile(at: url)
    }

    @Test(arguments: [0, 1, 2])
    func existingEventVersionsReopenWithoutRepeatingSettlement(_ version: Int) throws {
        let (store, url) = try makePersistentStore("event-version-\(version)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        _ = try store.appendEvent(runID: "run", kind: .started, detail: "private")
        _ = try store.appendEvent(runID: "run", kind: .progress, detail: "private")
        let receipt = try store.finish(runID: "run", outcome: .succeeded)
        let originalEvents = store.events(runID: "run")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        envelope["schemaVersion"] = version
        let payload = version == 0 ? try #require(envelope["state"] as? [String: Any]) : envelope
        try JSONSerialization.data(withJSONObject: payload).write(to: url)

        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.events(runID: "run") == originalEvents)
        #expect(reopened.events(runID: "run").map(\.sequence) == [1, 2, 3])
        #expect(reopened.allReceipts() == [receipt])
        #expect(reopened.taskCenterProjection().counts.succeeded == 1)
        #expect(reopened.externalSubmissionDecision(runID: "run") == .settled)
        #expect(throws: AgentTaskStoreError.runClosed) {
            _ = try reopened.appendEvent(runID: "run", kind: .progress, detail: "must not resume")
        }
        #expect(try AgentTaskStore(persistenceURL: url).allReceipts() == [receipt])
    }

    @Test func legacyUnversionedPayloadMigratesAndRewritesCurrentSchema() throws {
        let (store, persistenceURL) = try makePersistentStore("legacy")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "legacy-task", parentID: "root", providerID: nil, modelID: nil)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any])
        let legacyState = try #require(envelope["state"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: legacyState).write(to: persistenceURL)

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)

        #expect(reloaded.snapshot(taskID: "legacy-task", parentID: "root")?.status == .queued)
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any])
        #expect(migrated["schemaVersion"] as? Int == 4)
        #expect(migrated["state"] != nil)
    }

    @Test func unsupportedFutureSchemaIsRejected() throws {
        let (store, persistenceURL) = try makePersistentStore("future")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: nil, modelID: nil)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any])
        envelope["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: envelope).write(to: persistenceURL)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: persistenceURL)
        }
    }

    @Test func ordinaryChildStartupRollsBackRunCollisionAndCanRetryAfterReopen() async throws {
        let (store, persistenceURL) = try makePersistentStore("child-startup-collision")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let parent = "owned-parent"
        let existingTask = "existing-child"
        let occupiedRun = "occupied-run"
        _ = try store.enqueue(taskID: existingTask, parentID: parent, providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: existingTask, parentID: parent, runID: occupiedRun)
        let child = SubAgentTask(id: "new-child", title: "Owned child", instructions: "Return an owned result")

        await #expect(throws: AgentTaskStoreError.duplicateRun) {
            try await store.publishInitialChildRun(
                task: child, executionTask: child, parentID: parent, runID: occupiedRun,
                routeReceiptID: nil, parentRuntimeIdentity: nil, childRuntimeIdentity: nil,
                parentGoal: nil, launchIntentID: nil, capabilityDenied: false
            )
        }

        let reopened = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reopened.snapshot(taskID: child.id, parentID: parent) == nil)
        #expect(reopened.controlSnapshot(taskID: child.id, parentID: parent) == nil)
        #expect(reopened.taskSnapshot(runID: occupiedRun)?.taskID == existingTask)
        #expect(reopened.events(runID: occupiedRun).isEmpty)

        let retryRun = "retry-run"
        try await reopened.publishInitialChildRun(
            task: child, executionTask: child, parentID: parent, runID: retryRun,
            routeReceiptID: nil, parentRuntimeIdentity: nil, childRuntimeIdentity: nil,
            parentGoal: nil, launchIntentID: nil, capabilityDenied: false
        )

        let recovered = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(recovered.taskSnapshot(runID: retryRun)?.taskID == child.id)
        #expect(recovered.controlSnapshot(taskID: child.id, parentID: parent)?.runID == retryRun)
        #expect(recovered.events(runID: retryRun).map(\.kind) == [.started])
        #expect(recovered.taskSnapshot(runID: occupiedRun)?.taskID == existingTask)
    }

    @Test func diskFullFaultRollsBackMutationAndReportsActionableDiagnostic() throws {
        let (store, persistenceURL) = try makePersistentStore("disk-full")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        let faultedStore = try AgentTaskStore(persistenceURL: persistenceURL, persistenceFault: .diskFull)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try faultedStore.enqueue(taskID: "disk-full-task", parentID: "root", providerID: nil, modelID: nil)
        }
        #expect(faultedStore.snapshot(taskID: "disk-full-task", parentID: "root") == nil)
        let diagnostic = try #require(faultedStore.persistenceDiagnostics())
        #expect(diagnostic.operation == "persist")
        #expect(diagnostic.reason == "disk-full")
        #expect(!diagnostic.message.contains(persistenceURL.path))
        #expect(!FileManager.default.fileExists(atPath: persistenceURL.appendingPathExtension("tmp").path))
        #expect(store.snapshot(taskID: "disk-full-task", parentID: "root") == nil)
    }

    @Test func crashLeftoverTemporaryFileIsIgnoredAndReportedWithoutCorruptingLedger() throws {
        let (store, persistenceURL) = try makePersistentStore("crash-leftover")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "durable-task", parentID: "root", providerID: nil, modelID: nil)

        let temporaryURL = persistenceURL.appendingPathExtension("tmp")
        try Data(#"{\"schemaVersion\":"#.utf8).write(to: temporaryURL)

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reloaded.snapshot(taskID: "durable-task", parentID: "root")?.status == .queued)
        let diagnostic = try #require(reloaded.persistenceDiagnostics())
        #expect(diagnostic.operation == "recover")
        #expect(diagnostic.reason == "orphaned-temporary-file")
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test func orphanedTemporaryFileWithoutDurableLedgerFailsClosedAndPreservesEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskStoreTests-orphan-without-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        let temporaryURL = persistenceURL.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryData = Data("incomplete-ledger".utf8)
        try temporaryData.write(to: temporaryURL)

        do {
            _ = try AgentTaskStore(persistenceURL: persistenceURL)
            Issue.record("missing durable ledger must fail closed")
        } catch let error as AgentTaskStoreError {
            guard case .persistenceRecoveryFailed(let diagnostic) = error else {
                Issue.record("unexpected persistence recovery error: \(error)")
                return
            }
            #expect(diagnostic.operation == "recover")
            #expect(diagnostic.reason == "durable-ledger-missing")
            #expect(!diagnostic.message.contains(directory.path))
        }
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: persistenceURL.path))
    }

    @Test func recoveredRunningRunNeedsUserReviewWithoutReceiptOrRedispatch() throws {
        let (store, persistenceURL) = try makePersistentStore("recovery")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "task", parentID: "root", runID: "run")
        #expect(store.recoveryState(runID: "run") == nil)

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)

        #expect(reloaded.recoveryState(runID: "run") == .needsUserReview)
        #expect(reloaded.snapshot(taskID: "task", parentID: "root")?.status == .running)
        #expect(reloaded.attempts(runID: "run").count == 1)
        #expect(reloaded.allReceipts().isEmpty)
        #expect(reloaded.events(runID: "run").isEmpty)
    }

    @Test func queuedRunningAndTerminalSettlementSurviveRestartWithoutDuplicateReceipt() throws {
        let (store, persistenceURL) = try makePersistentStore("lifecycle-restart")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(
            taskID: "lifecycle-task",
            parentID: "root",
            providerID: "provider",
            modelID: "model",
            configurationFingerprint: "fingerprint"
        )

        let queued = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(queued.snapshot(taskID: "lifecycle-task", parentID: "root")?.status == .queued)

        _ = try queued.startRun(
            taskID: "lifecycle-task",
            parentID: "root",
            runID: "lifecycle-run"
        )
        let running = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(running.snapshot(taskID: "lifecycle-task", parentID: "root")?.status == .running)
        #expect(running.recoveryState(runID: "lifecycle-run") == .needsUserReview)

        let receipt = try running.finish(runID: "lifecycle-run", outcome: .cancelled)
        let terminal = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(terminal.snapshot(taskID: "lifecycle-task", parentID: "root")?.status == .cancelled)
        #expect(terminal.allReceipts() == [receipt])
        #expect(terminal.events(runID: "lifecycle-run").map(\.kind) == [.cancelled])

        let late = try terminal.finish(runID: "lifecycle-run", outcome: .succeeded)
        #expect(late == receipt)
        #expect(terminal.allReceipts() == [receipt])
        #expect(terminal.events(runID: "lifecycle-run").map(\.kind) == [.cancelled])
    }

    @Test func taskRunEventReceiptLifecycleIsAuditable() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "task-1", parentID: "root", providerID: "p1", modelID: "m1",
            configurationFingerprint: "fp-1"
        )
        let run = try store.startRun(taskID: task.taskID, runID: "run-1")
        let event = try store.appendEvent(runID: run.runID, kind: .started, detail: "started")
        let receipt = try store.finish(runID: run.runID, outcome: .succeeded)
        #expect(task.status == .queued)
        #expect(run.status == .running)
        #expect(event.sequence == 1)
        #expect(receipt.runID == "run-1")
        #expect(receipt.attemptID == "run-1:attempt:1")
        #expect(store.attempts(runID: "run-1").map(\.attemptID) == ["run-1:attempt:1"])
        #expect(store.attempts(runID: "run-1").first?.status == .succeeded)
        #expect(store.snapshot(taskID: "task-1")?.status == .succeeded)
        #expect(store.snapshot(taskID: "task-1")?.configurationFingerprint == "fp-1")
        #expect(store.attempts(runID: "run-1").first?.configurationFingerprint == "fp-1")
        #expect(receipt.providerID == "p1")
        #expect(receipt.modelID == "m1")
        #expect(receipt.configurationFingerprint == "fp-1")
    }

    @Test func taskSnapshotRetainsCapabilityRouteReceiptLink() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "task-route", parentID: "root", providerID: "p1", modelID: "m1", routeReceiptID: "route-receipt-1")
        #expect(task.routeReceiptID == "route-receipt-1")
        #expect(store.snapshot(taskID: "task-route")?.routeReceiptID == "route-receipt-1")
    }

    @Test func duplicateRunAndLateEventAreRejected() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "task-2", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task-2", runID: "run-2")
        _ = try store.appendEvent(runID: "run-2", kind: .started, detail: "started")
        #expect(throws: AgentTaskStoreError.duplicateRun) { _ = try store.startRun(taskID: "task-2", runID: "run-2") }
        _ = try store.finish(runID: "run-2", eventKind: .cancelled, detail: "cancelled", outcome: .cancelled)
        #expect(throws: AgentTaskStoreError.runClosed) { _ = try store.appendEvent(runID: "run-2", kind: .started, detail: "late") }
        let receipt = try store.finish(runID: "run-2", eventKind: .completed, detail: "late", outcome: .succeeded)
        #expect(receipt.outcome == .cancelled)
        #expect(store.events(runID: "run-2").map(\.kind) == [
            .started,
            .cancelled,
        ])
    }

    @Test func lateTerminalFromOldRunCannotMutateNewRun() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "retry-late-task", parentID: "root", providerID: nil, modelID: nil)
        let firstRun = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "retry-late-run-1")
        _ = try store.finish(runID: firstRun.runID, outcome: .failed(reason: "first attempt"))

        let secondRun = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "retry-late-run-2"
        )
        _ = try store.appendEvent(runID: secondRun.runID, kind: .started, detail: "retry dispatched")

        let late = try store.finish(runID: firstRun.runID, outcome: .succeeded)

        #expect(late.outcome == .failed(reason: "execution-failed"))
        #expect(store.events(runID: firstRun.runID).map(\.kind) == [.failed])
        #expect(store.events(runID: secondRun.runID).map(\.kind) == [.started])
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .running)
        #expect(store.attempts(runID: secondRun.runID).first?.status == .running)
        #expect(store.allReceipts().map(\.runID) == [firstRun.runID])
    }

    @Test func secondRunCannotStartWhilePriorRunIsStillRunning() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "task-running", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task-running", parentID: "root", runID: "run-first")

        #expect(throws: AgentTaskStoreError.taskAlreadyRunning) {
            _ = try store.startRun(taskID: "task-running", parentID: "root", runID: "run-second")
        }
        #expect(store.snapshot(taskID: "task-running", parentID: "root")?.status == .running)
        #expect(store.attempts(runID: "run-second").isEmpty)
        #expect(store.allReceipts().isEmpty)
    }

    @Test func sameTaskIDCanExistUnderDifferentParents() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "shared", parentID: "parent-a", providerID: "p1", modelID: "m1")
        _ = try store.enqueue(taskID: "shared", parentID: "parent-b", providerID: "p2", modelID: "m2")
        _ = try store.startRun(taskID: "shared", parentID: "parent-a", runID: "run-a")
        _ = try store.startRun(taskID: "shared", parentID: "parent-b", runID: "run-b")
        #expect(store.snapshot(taskID: "shared", parentID: "parent-a")?.providerID == "p1")
        #expect(store.snapshot(taskID: "shared", parentID: "parent-b")?.providerID == "p2")
    }

    @Test func terminalLifecycleRedactsFailureDetails() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "secret-task", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "secret-task", runID: "secret-run")
        let receipt = try store.finish(
            runID: "secret-run",
            eventKind: .failed,
            detail: "provider token=super-secret",
            outcome: .failed(reason: "provider token=super-secret")
        )
        #expect(receipt.outcome == .failed(reason: "execution-failed"))
        #expect(store.events(runID: "secret-run").last?.detail == "execution-failed")
        #expect(!store.events(runID: "secret-run").map(\.detail).joined().contains("super-secret"))
    }

    @Test func untrustedEventDetailsAreRedactedToCategories() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "redact-events", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "redact-events", runID: "redact-run")

        let progress = try store.appendEvent(
            runID: "redact-run",
            kind: .progress,
            detail: "prompt=/Users/private/secret-token=abc"
        )
        #expect(progress.detail == "progress")

        let approval = try store.appendEvent(
            runID: "redact-run",
            kind: .approvalRequired,
            detail: "tool arguments contain bearer-secret"
        )
        #expect(approval.detail == "approval-required")

        _ = try store.finish(
            runID: "redact-run",
            eventKind: .failed,
            detail: "full transcript and api_key=secret",
            outcome: .failed(reason: "provider response at /private/secret")
        )
        #expect(store.events(runID: "redact-run").map(\.detail) == ["progress", "approval-required", "execution-failed"])
        #expect(store.allReceipts().first?.outcome == .failed(reason: "execution-failed"))
    }

    @Test func outcomeOnlyFinishWritesMatchingTerminalEvent() throws {
        let cases: [(AgentTaskOutcome, AgentTaskEventKind, AgentTaskStatus)] = [
            (.succeeded, .completed, .succeeded),
            (.failed(reason: "private failure"), .failed, .failed),
            (.cancelled, .cancelled, .cancelled)
        ]

        for (index, testCase) in cases.enumerated() {
            let store = AgentTaskStore()
            let taskID = "outcome-only-task-\(index)"
            let runID = "outcome-only-run-\(index)"
            _ = try store.enqueue(taskID: taskID, parentID: "root", providerID: nil, modelID: nil)
            _ = try store.startRun(taskID: taskID, parentID: "root", runID: runID)

            _ = try store.finish(runID: runID, outcome: testCase.0)

            #expect(store.events(runID: runID).map(\.kind) == [testCase.1])
            #expect(store.allReceipts().map(\.runID) == [runID])
            #expect(store.snapshot(taskID: taskID, parentID: "root")?.status == testCase.2)
            #expect(store.attempts(runID: runID).first?.status == testCase.2)
        }
    }

    @Test func externalSubmissionIdentityIsStableAcrossReload() throws {
        let (store, persistenceURL) = try makePersistentStore("submission-identity")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "identity-task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "identity-task", parentID: "root", runID: "identity-run")

        let first = try #require(store.externalSubmissionIdentity(runID: "identity-run"))
        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)
        let second = try #require(reloaded.externalSubmissionIdentity(runID: "identity-run"))

        #expect(first == second)
        #expect(first.taskID == "identity-task")
        #expect(first.runID == "identity-run")
        #expect(first.attemptID == "identity-run:attempt:1")
        #expect(first.idempotencyKey == second.idempotencyKey)
    }

    @Test func unknownExternalSubmissionPersistenceFailureRollsBackMarker() throws {
        let (store, persistenceURL) = try makePersistentStore("submission-unknown-rollback")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "rollback-task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "rollback-task", parentID: "root", runID: "rollback-run")
        try obstruct(persistenceURL)

        #expect(throws: (any Error).self) {
            try store.markExternalSubmissionUnknown(runID: "rollback-run")
        }
        #expect(store.events(runID: "rollback-run").isEmpty)
        #expect(store.externalSubmissionDecision(runID: "rollback-run") == .notSubmitted)
        expectNoTemporaryFile(at: persistenceURL)

        try restore(persistenceURL)
        try store.markExternalSubmissionUnknown(runID: "rollback-run")
        #expect(store.externalSubmissionDecision(runID: "rollback-run") == .needsUserReview)
        #expect(store.events(runID: "rollback-run").map(\.kind) == [.submissionUnknown])
    }

    @Test func unknownExternalSubmissionPersistsReviewAndDoesNotDuplicateMarker() throws {
        let (store, persistenceURL) = try makePersistentStore("submission-unknown")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
        _ = try store.enqueue(taskID: "unknown-task", parentID: "root", providerID: "provider", modelID: "model")
        _ = try store.startRun(taskID: "unknown-task", parentID: "root", runID: "unknown-run")

        try store.markExternalSubmissionUnknown(runID: "unknown-run")
        try store.markExternalSubmissionUnknown(runID: "unknown-run")

        #expect(store.externalSubmissionDecision(runID: "unknown-run") == .needsUserReview)
        #expect(store.recoveryState(runID: "unknown-run") == .needsUserReview)
        #expect(store.events(runID: "unknown-run").map(\.kind) == [.submissionUnknown])

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reloaded.externalSubmissionDecision(runID: "unknown-run") == .needsUserReview)
        #expect(reloaded.recoveryState(runID: "unknown-run") == .needsUserReview)
        #expect(reloaded.events(runID: "unknown-run").map(\.kind) == [.submissionUnknown])
    }

    @Test func idempotentFinishReturnsSameReceipt() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "task-3", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "task-3", runID: "run-3")
        let first = try store.finish(runID: "run-3", outcome: .failed(reason: "x"))
        let second = try store.finish(runID: "run-3", outcome: .failed(reason: "x"))
        #expect(first == second)
        #expect(store.events(runID: "run-3").map(\.kind) == [.failed])
        #expect(store.allReceipts().map(\.runID) == ["run-3"])
    }

    @Test func queuedTaskCanBeAbortedWithoutCreatingRunOrReceipt() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "queued-task", parentID: "root", providerID: "p", modelID: "m")

        try store.abortQueued(taskID: "queued-task", parentID: "root", reason: "setup-failed")

        #expect(store.snapshot(taskID: "queued-task", parentID: "root")?.status == .failed)
        #expect(store.allReceipts().isEmpty)
        #expect(throws: AgentTaskStoreError.unknownTask) {
            try store.abortQueued(taskID: "missing", parentID: "root")
        }
    }

    @Test func receiptsUseCompletionOrderRatherThanDictionaryOrder() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "first", parentID: "root", providerID: "p", modelID: "m")
        _ = try store.enqueue(taskID: "second", parentID: "root", providerID: "p", modelID: "m")
        _ = try store.startRun(taskID: "first", parentID: "root", runID: "run-first")
        _ = try store.startRun(taskID: "second", parentID: "root", runID: "run-second")
        _ = try store.finish(runID: "run-second", outcome: .succeeded)
        _ = try store.finish(runID: "run-first", outcome: .succeeded)
        #expect(store.allReceipts().map(\.runID) == ["run-second", "run-first"])
    }

    @Test func runningTaskInitializationAbortClosesRunEventAndReceipt() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "running-task", parentID: "root", providerID: "p", modelID: "m")
        _ = try store.startRun(taskID: "running-task", parentID: "root", runID: "running-run")

        let receipt = try store.abortRunInitialization(runID: "running-run", reason: "setup-failed")

        #expect(receipt.outcome == .failed(reason: "execution-failed"))
        #expect(store.snapshot(taskID: "running-task", parentID: "root")?.status == .failed)
        #expect(store.events(runID: "running-run").map(\.kind) == [.failed])
        #expect(store.attempts(runID: "running-run").first?.status == .failed)
    }

    @Test func appendEventRejectsTerminalKindWithoutReceiptMutation() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "terminal-task", parentID: "root", providerID: "p", modelID: "m")
        _ = try store.startRun(taskID: "terminal-task", parentID: "root", runID: "terminal-run")

        #expect(throws: AgentTaskStoreError.terminalEventRequiresSettlement) {
            _ = try store.appendEvent(runID: "terminal-run", kind: .completed, detail: "completed")
        }
        #expect(store.events(runID: "terminal-run").isEmpty)
        #expect(store.allReceipts().isEmpty)
        #expect(store.snapshot(taskID: "terminal-task", parentID: "root")?.status == .running)
        #expect(store.attempts(runID: "terminal-run").first?.status == .running)

        _ = try store.finish(runID: "terminal-run", eventKind: .completed, detail: "completed", outcome: .succeeded)
        #expect(store.events(runID: "terminal-run").map(\.kind) == [.completed])
        #expect(store.allReceipts().map(\.runID) == ["terminal-run"])
    }

    @Test func terminalSettlementRejectsMismatchedEventAndOutcomeWithoutMutation() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "mismatch-task", parentID: "root", providerID: "p", modelID: "m")
        _ = try store.startRun(taskID: "mismatch-task", parentID: "root", runID: "mismatch-run")

        #expect(throws: AgentTaskStoreError.invalidTerminalSettlement) {
            _ = try store.finish(
                runID: "mismatch-run",
                eventKind: .completed,
                detail: "mismatch",
                outcome: .failed(reason: "failure")
            )
        }
        #expect(store.events(runID: "mismatch-run").isEmpty)
        #expect(store.allReceipts().isEmpty)
        #expect(store.snapshot(taskID: "mismatch-task", parentID: "root")?.status == .running)
        #expect(store.attempts(runID: "mismatch-run").first?.status == .running)

        _ = try store.finish(
            runID: "mismatch-run",
            eventKind: .failed,
            detail: "failure",
            outcome: .failed(reason: "failure")
        )
        #expect(store.events(runID: "mismatch-run").map(\.kind) == [.failed])
        #expect(store.allReceipts().map(\.runID) == ["mismatch-run"])
    }


    @Test func taskCenterProjectionAggregatesExistingSnapshotsAndBindings() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "queued", parentID: "root", providerID: "p2", modelID: "m2", routeReceiptID: "r2")
        _ = try store.enqueue(taskID: "running", parentID: "root", providerID: "p1", modelID: "m1", routeReceiptID: "r1")
        _ = try store.startRun(taskID: "running", parentID: "root", runID: "running-run")
        _ = try store.enqueue(taskID: "succeeded", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "succeeded", parentID: "root", runID: "succeeded-run")
        _ = try store.finish(runID: "succeeded-run", outcome: .succeeded)
        _ = try store.enqueue(taskID: "failed", parentID: "root", providerID: "p1", modelID: "m1", routeReceiptID: "r1")
        _ = try store.startRun(taskID: "failed", parentID: "root", runID: "failed-run")
        _ = try store.finish(runID: "failed-run", outcome: .failed(reason: "failure"))
        _ = try store.enqueue(taskID: "cancelled", parentID: "root", providerID: nil, modelID: nil)
        _ = try store.startRun(taskID: "cancelled", parentID: "root", runID: "cancelled-run")
        _ = try store.finish(runID: "cancelled-run", outcome: .cancelled)

        let projection = store.taskCenterProjection()
        #expect(projection.counts.queued == 1)
        #expect(projection.counts.running == 1)
        #expect(projection.counts.succeeded == 1)
        #expect(projection.counts.failed == 1)
        #expect(projection.counts.cancelled == 1)
        #expect(projection.counts.total == 5)
        #expect(projection.bindings == [
            TaskCenterProjection.RouteBinding(providerID: "p1", modelID: "m1", routeReceiptID: "r1"),
            TaskCenterProjection.RouteBinding(providerID: "p2", modelID: "m2", routeReceiptID: "r2")
        ])
    }

    @Test func taskCenterProjectionEmptyStoreIsReadOnlyAndReplayable() {
        let store = AgentTaskStore()
        let first = store.taskCenterProjection()
        let second = store.taskCenterProjection()
        #expect(first == second)
        #expect(first.counts.total == 0)
        #expect(first.bindings.isEmpty)
    }

    @Test func childResultEnvelopeBindsCanonicalReceiptAndSurvivesReload() throws {
        let (store, persistenceURL) = try makePersistentStore("child-result-envelope")
        defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }

        let task = try store.enqueue(
            taskID: "child-task",
            parentID: "parent-task",
            providerID: "provider",
            modelID: "model",
            parentContextSnapshotID: "parent-snapshot"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "child-run"
        )
        let attempt = try #require(store.attempts(runID: run.runID).first)
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attempt.attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "child-execution-1",
            outcome: .succeeded,
            resultDigest: "sha256:child-result",
            evidenceRefs: ["evidence://child-result"]
        )

        let receipt = try store.settleChildResult(envelope)
        #expect(receipt.childResultEnvelope == envelope)
        #expect(try store.settleChildResult(envelope) == receipt)
        #expect(store.childResultEnvelope(taskID: task.taskID, runID: run.runID) == envelope)

        let reloaded = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reloaded.childResultEnvelope(runID: run.runID) == envelope)
        #expect(reloaded.childResultReceipt(idempotencyKey: envelope.idempotencyKey) == receipt)
    }

    @Test func publicFailureTextDoesNotQualifyStringBasedSettlement() throws {
        let reasons = [
            "执行校验未通过（PROJECT:targetUnavailable），本次请求未完成。",
            "执行校验未通过（CHAT-RUNTIME:missingRequiredSnapshot），本次请求未完成。",
            "public-failure:project-target-unavailable",
            "执行校验未通过（PROJECT:targetUnavailable），本次请求未完成。 token=super-secret"
        ]
        for (index, reason) in reasons.enumerated() {
            let store = AgentTaskStore()
            let runID = "string-run-\(index)"
            _ = try store.enqueue(taskID: "task", parentID: "parent", providerID: nil, modelID: nil)
            _ = try store.startRun(taskID: "task", runID: runID)
            let receipt = try store.finish(runID: runID, eventKind: .failed,
                detail: AgentTaskPublicFailureCategory.projectTargetUnavailable.rawValue, outcome: .failed(reason: reason))
            #expect(receipt.outcome == .failed(reason: "execution-failed"))
            #expect(store.events(runID: runID).last?.detail == "execution-failed")
            #expect(store.publicFailureCategory(for: receipt) == nil)
        }
    }

    @Test func typedPublicFailureSurvivesReopenOnlyWithItsCanonicalTerminalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-safe-category-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let cases: [(AgentTaskPublicFailureCategory, String)] = [
            (.projectTargetUnavailable, "执行校验未通过（PROJECT:targetUnavailable），本次请求未完成。"),
            (.chatRuntimeMissingRequiredSnapshot, "执行校验未通过（CHAT-RUNTIME:missingRequiredSnapshot），本次请求未完成。")
        ]
        var receipts: [AgentTaskReceipt] = []
        for (index, pair) in cases.enumerated() {
            let taskID = "typed-task-\(index)", runID = "typed-run-\(index)"
            _ = try store.enqueue(taskID: taskID, parentID: "parent", providerID: nil, modelID: nil)
            _ = try store.startRun(taskID: taskID, runID: runID)
            let receipt = try store.finish(runID: runID, failureCategory: pair.0)
            #expect(receipt.outcome == .failed(reason: pair.1))
            #expect(store.publicFailureCategory(for: receipt) == pair.0)
            #expect(store.events(runID: runID).last?.kind == .failed)
            #expect(store.events(runID: runID).last?.detail == pair.0.rawValue)
            let count = store.events(runID: runID).count
            let duplicate = try store.finish(runID: runID,
                failureCategory: pair.0 == .projectTargetUnavailable ? .chatRuntimeMissingRequiredSnapshot : .projectTargetUnavailable)
            #expect(duplicate == receipt && store.events(runID: runID).count == count)
            let foreign = AgentTaskReceipt(taskID: "other-owner", runID: receipt.runID,
                parentContextSnapshotID: receipt.parentContextSnapshotID, attemptID: receipt.attemptID,
                providerID: receipt.providerID, modelID: receipt.modelID,
                configurationFingerprint: receipt.configurationFingerprint, outcome: receipt.outcome)
            #expect(store.publicFailureCategory(for: foreign) == nil)
            receipts.append(receipt)
        }
        let encoded = try Data(contentsOf: url)
        let serializedCandidate = String(data: encoded, encoding: .utf8)
        let serialized = try #require(serializedCandidate)
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.allReceipts() == receipts)
        for (index, pair) in cases.enumerated() {
            #expect(reopened.publicFailureCategory(for: receipts[index]) == pair.0)
        }
        // Existing fields only: an unknown category or mismatched fixed message
        // cannot be recovered as a typed public failure, even with the same run.
        let unknownURL = root.appendingPathComponent("unknown.json")
        try #require(serialized.contains(AgentTaskPublicFailureCategory.projectTargetUnavailable.rawValue))
        try serialized.replacingOccurrences(of: AgentTaskPublicFailureCategory.projectTargetUnavailable.rawValue,
            with: "public-failure:unknown").write(to: unknownURL, atomically: true, encoding: .utf8)
        let unknownStore = try AgentTaskStore(persistenceURL: unknownURL)
        let unknownReceipt = try #require(unknownStore.allReceipts().first)
        #expect(unknownStore.publicFailureCategory(for: unknownReceipt) == nil)
        let mismatchURL = root.appendingPathComponent("mismatch.json")
        try #require(serialized.contains(cases[0].1))
        try serialized.replacingOccurrences(of: cases[0].1, with: cases[1].1)
            .write(to: mismatchURL, atomically: true, encoding: .utf8)
        let mismatchStore = try AgentTaskStore(persistenceURL: mismatchURL)
        let mismatchReceipt = try #require(mismatchStore.allReceipts().first)
        #expect(mismatchStore.publicFailureCategory(for: mismatchReceipt) == nil)
    }

}
