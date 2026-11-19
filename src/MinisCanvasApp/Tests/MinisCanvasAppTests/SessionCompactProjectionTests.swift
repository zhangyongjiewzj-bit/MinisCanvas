import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Session compact projection")
struct SessionCompactProjectionTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCanvas-SessionCompactProjection-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test
    func projectionShowsCheckpointRevisionAndLineage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "root")
        for index in 1...4 {
            try store.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: "root"
            )
        }
        let child = try store.forkSession(
            from: "root",
            id: "child",
            throughMessageIndex: 2
        )
        _ = try await store.compactSession(
            sessionID: child.id,
            using: Compactor(keepRecentMessages: 1)
        )

        let projection = SessionCompactProjection(
            sessionID: child.id,
            store: store
        )
        #expect(projection.state == .checkpointed)
        #expect(projection.rootSessionID == "root")
        #expect(projection.parentSessionID == "root")
        #expect(projection.forkedThroughRevision == 4)
        #expect(projection.sourceRevision != nil)
        #expect(projection.resultRevision != nil)
    }

    @Test
    func corruptCheckpointProjectsBlockedWithoutRepair() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "session")
        for index in 1...4 {
            try store.saveMessage(
                LLMMessage(role: .user, content: "message-\(index)"),
                sessionID: "session"
            )
        }
        _ = try await store.compactSession(
            sessionID: "session",
            using: Compactor(keepRecentMessages: 1)
        )
        let checkpoint = try #require(try store.loadLatestCompactionCheckpoint(sessionID: "session"))
        let checkpointURL = store.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        try Data(#"{"schemaVersion":1}"#.utf8)
            .write(to: checkpointURL, options: .atomic)

        let projection = SessionCompactProjection(
            sessionID: "session",
            store: store
        )
        #expect(projection.state == .blocked)
        #expect(projection.checkpointID == nil)
    }
    /// MC4-044：存储已装配但会话还没落盘，与“存储服务没装配”显示不同。
    @Test
    func unsavedSessionIsDistinctFromUnassembledStore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let notSaved = SessionCompactProjection(sessionID: UUID().uuidString, store: store)
        #expect(notSaved.state == .sessionNotSaved)
        #expect(notSaved.stateLabel != "持久化未装配")
        let noStore = SessionCompactProjection(sessionID: UUID().uuidString, store: nil)
        #expect(noStore.state == .unavailable)
        #expect(noStore.stateLabel == "持久化未装配")
    }

    @Test
    func ordinaryRevisionChangesWithoutCheckpointDoNotProjectCorruption() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var session = try store.createSession(id: "ordinary")
        session.messages = [LLMMessage(role: .user, content: "普通会话")]
        session.transcriptRevision = 8
        try store.updateSession(session)
        let sessionURL = store.sessionsDirectory.appendingPathComponent("ordinary.json")
        let originalBytes = try Data(contentsOf: sessionURL)

        #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)
        let projection = SessionCompactProjection(sessionID: session.id, store: store)
        #expect(projection.state == .noCheckpoint)
        #expect(projection.checkpointID == nil)
        #expect(projection.stateLabel == "暂无压缩检查点")
        #expect(try Data(contentsOf: sessionURL) == originalBytes)
    }

    @Test
    func retainedChainWithoutRequiredPayloadIsBlockedWithoutRewritingSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "missing-payload")
        for index in 1...4 {
            try store.saveMessage(LLMMessage(role: .user, content: "message-\(index)"),
                                  sessionID: "missing-payload")
        }
        _ = try await store.compactSession(sessionID: "missing-payload",
                                           using: Compactor(keepRecentMessages: 1))
        let checkpoint = try #require(try store.loadLatestCompactionCheckpoint(sessionID: "missing-payload"))
        let payload = store.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chain = store.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        #expect(FileManager.default.fileExists(atPath: chain.path))
        let chainBytes = try Data(contentsOf: chain)
        let sessionURL = store.sessionsDirectory.appendingPathComponent("missing-payload.json")
        let sessionBytes = try Data(contentsOf: sessionURL)
        try FileManager.default.removeItem(at: payload)

        // The canonical owner now distinguishes a missing required payload
        // from a fully validated cleanup tombstone. The App must consume the
        // thrown recovery requirement without rewriting retained evidence.
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try store.loadLatestCompactionCheckpoint(sessionID: "missing-payload")
        }
        let projection = SessionCompactProjection(sessionID: "missing-payload", store: store)
        #expect(projection.state == .blocked)
        #expect(projection.stateLabel == "检查点校验阻断")
        #expect(projection.checkpointID == nil)
        #expect(try Data(contentsOf: sessionURL) == sessionBytes)
        #expect(try Data(contentsOf: chain) == chainBytes)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
    }

}
