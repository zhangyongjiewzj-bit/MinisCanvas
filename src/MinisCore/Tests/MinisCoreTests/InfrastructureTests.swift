import Foundation
import Testing
@testable import MinisCore

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - LogManager

struct LogManagerTests {

    @Test func logLevelOrdering() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.debug.rawValue == 0 && LogLevel.error.rawValue == 3)
    }

    @Test func levelFilteringDropsBelowThreshold() throws {
        let dir = try makeTempDir("LogFilter")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = LogManager(directory: dir)
        log.minimumLevel = .info
        log.isFileLoggingEnabled = false // isolate buffer behavior

        log.debug("dropped", category: "Test")
        log.info("kept-info", category: "Test")
        log.warn("kept-warn", category: "Test")
        log.error("kept-error", category: "Test")

        let recent = log.recentLogs()
        #expect(recent.count == 3)
        #expect(recent.map(\.message) == ["kept-error", "kept-warn", "kept-info"]) // newest first
        #expect(recent.allSatisfy { $0.level >= .info })
        #expect(!recent.contains { $0.message == "dropped" })
        #expect(log.shouldLog(.info) && !log.shouldLog(.debug))
    }

    @Test func filePersistenceAppendsEntries() throws {
        let dir = try makeTempDir("LogFile")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = LogManager(directory: dir)
        log.info("hello-world", category: "Persistence")
        log.warn("second-line", category: "Persistence")

        let url = log.logFileURL()
        #expect(url != nil)
        let text = try String(contentsOf: url!, encoding: .utf8)
        #expect(text.contains("hello-world"))
        #expect(text.contains("second-line"))
        #expect(text.contains("[INFO] [Persistence]"))
        #expect(text.contains("[WARN] [Persistence]"))
    }

    @Test func fileRotationCreatesBackup() throws {
        let dir = try makeTempDir("LogRotate")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Tiny max size so a couple of long lines trigger rotation.
        let log = LogManager(directory: dir, maxFileSize: 200)
        for i in 0..<8 {
            log.info("rotation-test-line-\(i) \(String(repeating: "x", count: 40))", category: "Rotate")
        }

        let backup = dir.appendingPathComponent("app.1.log")
        #expect(FileManager.default.fileExists(atPath: backup.path), "rotation should produce app.1.log")
        let backupText = try String(contentsOf: backup, encoding: .utf8)
        // Rotation happened: backup holds at least one full rotated line.
        #expect(backupText.contains("rotation-test-line"))
        // Fresh file must exist too and keep receiving writes after rotation.
        let currentText = try String(contentsOf: log.logFileURL()!, encoding: .utf8)
        #expect(currentText.contains("rotation-test-line"))
    }

    @Test func recentLogsRespectsLimit() throws {
        let dir = try makeTempDir("LogLimit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = LogManager(directory: dir)
        log.isFileLoggingEnabled = false
        for i in 0..<10 { log.info("m\(i)", category: "Test") }

        let limited = log.recentLogs(limit: 3)
        #expect(limited.count == 3)
        #expect(limited.first?.message == "m9") // newest first
        #expect(log.recentLogsText(limit: 2).contains("m9"))
    }
}

// MARK: - SessionBadgeStore

struct SessionBadgeStoreTests {

    @Test func incrementDecrementReset() throws {
        let dir = try makeTempDir("BadgeOps")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionBadgeStore(directory: dir)
        #expect(store.unreadCount(for: "s1") == 0)

        #expect(store.increment(for: "s1") == 1)
        #expect(store.increment(for: "s1") == 2)
        #expect(store.increment(for: "s2") == 1)
        #expect(store.totalUnreadCount() == 3)
        #expect(store.unreadSessionIDs() == ["s1", "s2"])

        #expect(store.decrement(for: "s1") == 1)
        #expect(store.decrement(for: "s1") == 0)
        #expect(store.unreadCount(for: "s1") == 0) // key dropped at 0
        #expect(store.unreadSessionIDs() == ["s2"])

        store.reset(for: "s2")
        #expect(store.unreadCount(for: "s2") == 0)
        #expect(store.totalUnreadCount() == 0)
    }

    @Test func decrementFloorsAtZero() throws {
        let dir = try makeTempDir("BadgeFloor")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionBadgeStore(directory: dir)
        store.increment(for: "s1")
        #expect(store.decrement(for: "s1") == 0)
        #expect(store.decrement(for: "s1") == 0) // no negative
        #expect(store.decrement(for: "never-seen") == 0)
    }

    @Test func persistenceAcrossInstances() throws {
        let dir = try makeTempDir("BadgePersist")
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionBadgeStore(directory: dir)
        writer.increment(for: "s1")
        writer.increment(for: "s1")
        writer.increment(for: "s2")

        let reader = SessionBadgeStore(directory: dir)
        #expect(reader.unreadCount(for: "s1") == 2)
        #expect(reader.unreadCount(for: "s2") == 1)
        #expect(reader.totalUnreadCount() == 3)

        // badges.json must exist on disk.
        let file = dir.appendingPathComponent("badges.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Reset persists too.
        reader.reset(for: "s1")
        let reader2 = SessionBadgeStore(directory: dir)
        #expect(reader2.unreadCount(for: "s1") == 0)
        #expect(reader2.unreadCount(for: "s2") == 1)
    }

    @Test func concurrentPersistCannotReplaceNewerSnapshotWithOlderOne() async throws {
        let dir = try await runBlockingTestWork { try makeTempDir("BadgePersistOrdering") }
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstSnapshot = DispatchSemaphore(value: 0)
        let laterSnapshot = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let claimFirst = DispatchSemaphore(value: 1)
        defer { claimFirst.signal() }
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let store = SessionBadgeStore(directory: dir, beforePersistenceWrite: {
            if claimFirst.wait(timeout: .now()) == .success {
                firstSnapshot.signal()
                _ = releaseFirst.wait(timeout: .now() + 10)
            } else {
                laterSnapshot.signal()
            }
        })

        DispatchQueue.global().async {
            _ = store.increment(for: "same-session")
            firstDone.signal()
        }
        let capturedFirst = try await runBlockingTestWork {
            firstSnapshot.wait(timeout: .now() + 5) == .success
        }
        guard capturedFirst else {
            releaseFirst.signal()
            Issue.record("first persisted snapshot was not captured")
            return
        }
        DispatchQueue.global().async {
            _ = store.increment(for: "same-session")
            secondDone.signal()
        }

        // The second mutation is in memory before the first write is released.
        let inMemoryCount = try await runBlockingTestWork {
            let deadline = Date().addingTimeInterval(5)
            while store.unreadCount(for: "same-session") != 2 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return store.unreadCount(for: "same-session")
        }
        #expect(inMemoryCount == 2)
        let overtookFirstWrite = try await runBlockingTestWork {
            laterSnapshot.wait(timeout: .now() + 2) == .success
        }
        let secondCompletedBeforeRelease = try await runBlockingTestWork {
            overtookFirstWrite && secondDone.wait(timeout: .now() + 5) == .success
        }
        releaseFirst.signal()
        let firstCompleted = try await runBlockingTestWork {
            firstDone.wait(timeout: .now() + 5) == .success
        }
        #expect(firstCompleted)
        if !secondCompletedBeforeRelease {
            let secondCompleted = try await runBlockingTestWork {
                secondDone.wait(timeout: .now() + 5) == .success
            }
            #expect(secondCompleted)
        }

        #expect(!overtookFirstWrite, "a later snapshot must not write before the earlier replacement finishes")
        let persistedCount = try await runBlockingTestWork {
            SessionBadgeStore(directory: dir).unreadCount(for: "same-session")
        }
        #expect(persistedCount == 2)
    }
}

// MARK: - LLMSessionRegistry

struct LLMSessionRegistryTests {

    @Test func registerAndActiveSessions() {
        let registry = LLMSessionRegistry()
        registry.register(providerID: "openai", sessionToken: "tok-a")
        registry.register(providerID: "anthropic", sessionToken: "tok-b")

        #expect(registry.count() == 2)
        #expect(registry.isActive(providerID: "openai"))
        #expect(registry.sessionToken(for: "openai") == "tok-a")
        #expect(registry.sessionToken(for: "anthropic") == "tok-b")
        #expect(registry.sessionToken(for: "missing") == nil)

        let active = registry.activeSessions()
        #expect(active.count == 2)
        #expect(active.map(\.providerID).sorted() == ["anthropic", "openai"])
        #expect(active.map(\.sessionToken).sorted() == ["tok-a", "tok-b"])
    }

    @Test func reregisterReplacesToken() {
        let registry = LLMSessionRegistry()
        registry.register(providerID: "openai", sessionToken: "old")
        registry.register(providerID: "openai", sessionToken: "new")

        #expect(registry.count() == 1) // replaced, not duplicated
        #expect(registry.sessionToken(for: "openai") == "new")
    }

    @Test func invalidateRemovesSession() {
        let registry = LLMSessionRegistry()
        registry.register(providerID: "openai", sessionToken: "tok-a")
        registry.register(providerID: "anthropic", sessionToken: "tok-b")

        registry.invalidate(providerID: "openai")
        #expect(registry.count() == 1)
        #expect(!registry.isActive(providerID: "openai"))
        #expect(registry.sessionToken(for: "openai") == nil)
        #expect(registry.activeSessions().map(\.providerID) == ["anthropic"])

        registry.invalidateAll()
        #expect(registry.count() == 0)
        #expect(registry.activeSessions().isEmpty)
    }
}

// MARK: - NetworkMonitor

struct NetworkMonitorTests {

    @Test func notStartedReportsDeterministicDefaults() {
        let monitor = NetworkMonitor()
        // No path callbacks before start(): defaults regardless of real network.
        #expect(!monitor.isStarted())
        #expect(!monitor.isConnected())
        #expect(!monitor.isExpensive())
    }

    @Test func startStopSmoke() {
        let monitor = NetworkMonitor()
        monitor.start()
        #expect(monitor.isStarted())
        // Do NOT assert real connectivity state — only that it's a valid Bool.
        _ = monitor.isConnected()
        _ = monitor.isExpensive()
        monitor.stop()
        #expect(!monitor.isStarted())
        monitor.stop() // idempotent, no crash
    }
}
