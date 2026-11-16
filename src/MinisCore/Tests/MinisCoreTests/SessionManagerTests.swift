import Foundation
import Testing
@testable import MinisCore

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-SessionManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Persist a session with a fixed `updatedAt` (for retention tests).
private func persistSession(
    _ store: SessionStore,
    id: String,
    updatedAt: Date,
    messages: Int = 0
) throws {
    let session = ChatSession(
        id: id,
        title: "会话 \(id)",
        createdAt: updatedAt,
        updatedAt: updatedAt,
        messages: (0..<messages).map { LLMMessage(role: .user, content: "消息 \($0)") }
    )
    try store.updateSession(session)
}

private func writePendingSessionMoveMarker(
    in directory: URL,
    operationID: UUID,
    targetID: String,
    sourceLocation: String,
    destinationLocation: String,
    payloadDigest: String,
    phase: String
) throws -> URL {
    let marker = directory.appendingPathComponent(
        ".session-move-\(operationID.uuidString).pending.json"
    )
    let object: [String: String] = [
        "operationID": operationID.uuidString,
        "targetID": targetID,
        "scopeID": "session:\(targetID):\(sourceLocation)",
        "sourceLocation": sourceLocation,
        "destinationLocation": destinationLocation,
        "payloadDigest": payloadDigest,
        "phase": phase
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: marker)
    return marker
}

struct SessionManagerTests {
    @Test("Goal18 session errors provide recovery without storage identity")
    func localizedSessionErrorsHideDiagnosticPayloads() throws {
        let diagnostic = "synthetic-private-session-path"
        let errors: [SessionManagerError] = [.sessionNotFound(diagnostic), .notArchived(diagnostic),
            .alreadyArchived(diagnostic), .duplicateSessionIdentity(diagnostic), .recoveryRequired(diagnostic),
            .invalidRetention(-1), .unresolvableRetentionWindow(days: Int.max)]
        for error in errors {
            let message = try #require(error.errorDescription)
            #expect(!message.contains(diagnostic))
            #expect(message.contains("请"))
            #expect(!message.contains("错误 0"))
        }
    }

    @Test("Goal18 unknown network errors do not project raw descriptions")
    func unknownNetworkErrorUsesActionableSafeFallback() {
        let raw = NSError(domain: "fixture.private-domain", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "synthetic-private-network-payload"])
        let zh = NetworkErrorMessages.zhMessage(for: raw)
        let en = NetworkErrorMessages.enMessage(for: raw)
        #expect(zh.contains("E-NET-UNKNOWN") && zh.contains("请"))
        #expect(en.contains("E-NET-UNKNOWN"))
        #expect(!zh.contains("synthetic-private-network-payload"))
        #expect(!en.contains("synthetic-private-network-payload"))
        #expect(NetworkErrorMessages.zhMessage(for: URLError(.timedOut)).contains("超时"))
    }


    // MARK: listWithStats

    @Test func listWithStatsIncludesCountsAndBadges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let badges = SessionBadgeStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: badges)

        let a = try store.createSession()
        let b = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "你好"), sessionID: a.id)
        try store.saveMessage(LLMMessage(role: .user, content: "在吗"), sessionID: a.id)
        try store.saveMessage(LLMMessage(role: .assistant, content: "在的"), sessionID: a.id)
        badges.increment(for: a.id)
        badges.increment(for: a.id)

        let stats = manager.listWithStats()
        #expect(stats.count == 2)

        let statA = try #require(stats.first { $0.id == a.id })
        #expect(statA.messageCount == 3)
        #expect(statA.unreadCount == 2)
        #expect(statA.lastActivityAt == statA.session.updatedAt)

        let statB = try #require(stats.first { $0.id == b.id })
        #expect(statB.messageCount == 0)
        #expect(statB.unreadCount == 0)
    }

    @Test func managerFactRejectsStaleRevisionAfterRestartReentry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        let session = try store.createSession(id: "fact-session")
        let captured = try #require(manager.managerFact(for: session.id))

        try store.saveMessage(
            LLMMessage(role: .user, content: "新一轮输入"),
            sessionID: session.id
        )

        #expect(captured.sessionID == session.id)
        #expect(captured.transcriptRevision == 0)
        #expect(captured.lineageOwner == session.rootSessionID)
        let current = try #require(manager.managerFact(for: session.id))
        #expect(throws: SessionManagerError.staleManagerFact(expected: captured, actual: current)) {
            try manager.requireCurrent(captured)
        }

        #expect(current.transcriptRevision == 1)
        #expect(try manager.requireCurrent(current).transcriptRevision == 1)
    }

    @Test func duplicateActiveAndArchivedIdentityFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        let session = try store.createSession(id: "duplicate-fact")
        let captured = try #require(manager.managerFact(for: session.id))
        try FileManager.default.createDirectory(
            at: manager.archiveDirectory,
            withIntermediateDirectories: true
        )
        let activeURL = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let archiveURL = manager.archiveDirectory.appendingPathComponent("\(session.id).json")
        try FileManager.default.copyItem(at: activeURL, to: archiveURL)

        #expect(manager.loadSessionIncludingArchived(id: session.id) == nil)
        #expect(manager.managerFact(for: session.id) == nil)
        #expect(throws: SessionManagerError.duplicateSessionIdentity(session.id)) {
            try manager.requireCurrent(captured)
        }
    }

    @Test func listWithStatsSortedByRecency() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))

        let a = try store.createSession()
        let b = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "A 的消息"), sessionID: a.id)
        try store.saveMessage(LLMMessage(role: .user, content: "B 的消息"), sessionID: b.id)

        let ids = manager.listWithStats().map(\.id)
        #expect(ids == [b.id, a.id]) // most recently updated first
    }

    // MARK: Archive / Restore

    @Test func archiveMovesSessionOutOfActiveList() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))

        let session = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "内容"), sessionID: session.id)

        try manager.archive(sessionID: session.id)

        #expect(store.loadSession(id: session.id) == nil) // hidden from active list
        #expect(manager.listWithStats().isEmpty)
        #expect(manager.archivedSessions().map(\.id) == [session.id])
        // File physically preserved under _archive/.
        let archivedFile = manager.archiveDirectory.appendingPathComponent("\(session.id).json")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))
    }

    @Test func restoreBringsSessionBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))

        let session = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "保留的消息"), sessionID: session.id)
        try manager.archive(sessionID: session.id)

        try manager.restore(sessionID: session.id)

        let loaded = try #require(store.loadSession(id: session.id))
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages[0].content == "保留的消息")
        #expect(manager.archivedSessions().isEmpty)
    }

    @Test func preparedArchiveMoveFailsClosedUntilProvenRecovery() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        let session = try store.createSession(id: "pending-archive")
        let source = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let data = try Data(contentsOf: source)
        let operationID = UUID()
        let marker = try writePendingSessionMoveMarker(
            in: store.sessionsDirectory,
            operationID: operationID,
            targetID: session.id,
            sourceLocation: "active",
            destinationLocation: "archive",
            payloadDigest: DeletionGate.fingerprint(data),
            phase: "prepared"
        )

        #expect(throws: SessionManagerError.recoveryRequired(operationID.uuidString)) {
            try manager.archive(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try manager.recoverPendingTransactions() == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try manager.archive(sessionID: session.id)
        #expect(manager.archivedSessions().map(\.id) == [session.id])
    }

    @Test func movedArchiveMoveRecoveryPreservesBytesBeforeRestore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        let session = try store.createSession(id: "moved-archive")
        let source = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let destinationDirectory = manager.archiveDirectory
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("\(session.id).json")
        let data = try Data(contentsOf: source)
        try FileManager.default.moveItem(at: source, to: destination)
        let operationID = UUID()
        let marker = try writePendingSessionMoveMarker(
            in: store.sessionsDirectory,
            operationID: operationID,
            targetID: session.id,
            sourceLocation: "active",
            destinationLocation: "archive",
            payloadDigest: DeletionGate.fingerprint(data),
            phase: "moved"
        )

        #expect(throws: SessionManagerError.recoveryRequired(operationID.uuidString)) {
            try manager.restore(sessionID: session.id)
        }
        let beforeRecovery = try Data(contentsOf: destination)
        #expect(try manager.recoverPendingTransactions() == 1)
        #expect(try Data(contentsOf: destination) == beforeRecovery)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try manager.restore(sessionID: session.id)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func archiveErrors() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))

        #expect(throws: SessionManagerError.sessionNotFound("nope")) {
            try manager.archive(sessionID: "nope")
        }
        #expect(throws: SessionManagerError.notArchived("nope")) {
            try manager.restore(sessionID: "nope")
        }

        let session = try store.createSession()
        try manager.archive(sessionID: session.id)
        #expect(throws: SessionManagerError.alreadyArchived(session.id)) {
            try manager.archive(sessionID: session.id)
        }
    }

    // MARK: purgeOld

    @Test func purgeOldDeletesStaleActiveAndArchivedSessions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let badges = SessionBadgeStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: badges)

        let now = Date()
        let stale = now.addingTimeInterval(-30 * 86_400) // 30 days ago
        let fresh = now.addingTimeInterval(-2 * 86_400) // 2 days ago

        // Stale active, fresh active, stale archived, fresh archived.
        try persistSession(store, id: "stale-active", updatedAt: stale, messages: 2)
        try persistSession(store, id: "fresh-active", updatedAt: fresh)
        try persistSession(store, id: "stale-archived", updatedAt: stale)
        try persistSession(store, id: "fresh-archived", updatedAt: fresh)
        try manager.archive(sessionID: "stale-archived")
        try manager.archive(sessionID: "fresh-archived")
        badges.increment(for: "stale-active")

        let removed = try manager.purgeOld(days: 7)

        #expect(removed == 2)
        #expect(store.loadSession(id: "stale-active") == nil)
        #expect(store.loadSession(id: "fresh-active") != nil)
        #expect(manager.archivedSessions().map(\.id) == ["fresh-archived"])
        #expect(badges.unreadCount(for: "stale-active") == 0) // badge cleared
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let trashNames = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        #expect(trashNames.count == 4)
        #expect(trashNames.filter { $0.hasPrefix(".trash-receipt-") }.count == 2)
        #expect(trashNames.filter { !$0.hasPrefix(".") }.count == 2)
    }

    @Test func purgeOldRejectsInvalidRetention() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        try persistSession(store, id: "s1", updatedAt: Date())

        #expect(throws: SessionManagerError.invalidRetention(0)) {
            try manager.purgeOld(days: 0)
        }
        #expect(throws: SessionManagerError.invalidRetention(-3)) {
            try manager.purgeOld(days: -3)
        }
        #expect(store.listSessions().count == 1) // nothing was deleted
    }

    @Test func purgeOldKeepsRecentSessions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: dir))
        let recent = Date().addingTimeInterval(-60)
        try persistSession(store, id: "recent", updatedAt: recent)

        #expect(try manager.purgeOld(days: 30) == 0)
        #expect(store.loadSession(id: "recent") != nil)
    }

    @Test func purgeOldFailsClosedOnUnresolvableRetentionWindow() throws {
        // D-STORAGE-04 supplement: a retention window the calendar cannot
        // resolve must fail closed. Before this guard the cutoff silently
        // degenerated to `Date()`, i.e. "keep nothing", so an unusably large
        // configured window deleted every active and archived session.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let badges = SessionBadgeStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: badges)
        let stale = Date().addingTimeInterval(-30 * 86_400)
        try persistSession(store, id: "stale-active", updatedAt: stale)
        try persistSession(store, id: "stale-archived", updatedAt: stale)
        try manager.archive(sessionID: "stale-archived")

        let unresolvableDays = Int.max
        // Precondition: this window has no cutoff inside the real-world Date
        // domain, which is exactly where the old `?? Date()` fallback
        // silently degraded to "keep nothing".
        if let rawCutoff = Calendar.current.date(byAdding: .day, value: -unresolvableDays, to: Date()) {
            #expect(rawCutoff < Date.distantPast)
        } // nil also counts as unresolvable.
        #expect(throws: SessionManagerError.unresolvableRetentionWindow(days: unresolvableDays)) {
            _ = try manager.purgeOld(days: unresolvableDays)
        }
        // Fail-closed: nothing was deleted, active or archived.
        #expect(store.loadSession(id: "stale-active") != nil)
        #expect(manager.archivedSessions().map(\.id) == ["stale-archived"])
    }

    @Test func purgeOldKeepsFarPastRepresentableWindowAsNoOp() throws {
        // D-STORAGE-04 boundary: an extreme but calendar-representable window
        // resolves to a far-past cutoff and stays a no-op; the fail-closed
        // guard must not reject it.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let badges = SessionBadgeStore(directory: dir)
        let manager = SessionManager(store: store, badgeStore: badges)
        let stale = Date().addingTimeInterval(-30 * 86_400)
        try persistSession(store, id: "stale-active", updatedAt: stale)
        try persistSession(store, id: "stale-archived", updatedAt: stale)
        try manager.archive(sessionID: "stale-archived")

        #expect(try manager.purgeOld(days: 36_500) == 0) // ~100 years
        #expect(store.loadSession(id: "stale-active") != nil)
        #expect(manager.archivedSessions().map(\.id) == ["stale-archived"])
    }

    // MARK: AJ-30 会话归属项目 / 工作目录

    @Test func createSessionWithProjectPersistsFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession(
            projectID: "proj-a", projectName: "MinisCanvas", workingDirectory: "/Users/me/MinisCanvas"
        )
        #expect(session.projectID == "proj-a")
        #expect(session.projectName == "MinisCanvas")
        #expect(session.workingDirectory == "/Users/me/MinisCanvas")

        let loaded = try #require(store.loadSession(id: session.id))
        #expect(loaded.projectID == "proj-a")
        #expect(loaded.projectName == "MinisCanvas")
        #expect(loaded.workingDirectory == "/Users/me/MinisCanvas")
    }

    @Test func chatSessionWithoutProjectFieldsDecodesNil() throws {
        // 旧持久化 JSON（无 project 键）→ 新字段按 nil 解码（向后兼容）。
        let json = """
        {"id":"old-1","title":"旧会话","createdAt":0,"updatedAt":0,"messages":[]}
        """
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.projectID == nil)
        #expect(session.projectName == nil)
        #expect(session.workingDirectory == nil)
        #expect(session.pinned == false)
        #expect(session.unread == false)
    }

    @Test func chatSessionRoundTripPreservesProject() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        try store.createSession(
            projectID: "p1", projectName: "MyApp", workingDirectory: "/tmp/MyApp"
        )
        let s = try #require(store.listSessions().first, "创建会话后应存在可编码的会话")
        // 编码 → 解码 往返
        let data = try JSONEncoder().encode(s)
        let round = try JSONDecoder().decode(ChatSession.self, from: data)
        #expect(round.projectID == "p1")
        #expect(round.projectName == "MyApp")
        #expect(round.workingDirectory == "/tmp/MyApp")
    }
}
