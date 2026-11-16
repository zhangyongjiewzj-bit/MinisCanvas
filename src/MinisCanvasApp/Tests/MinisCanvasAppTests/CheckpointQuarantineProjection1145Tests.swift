import CryptoKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// The production inspector must preserve a session's corrupt-checkpoint
/// diagnosis after its existing quarantine transaction has completed.
@Suite("D-MEMORY-04 durable quarantine projection")
@MainActor
struct CheckpointQuarantineProjection1145Tests {
    @Test("repeat and cold projection keep the quarantined session blocked while its sibling recovers", arguments: [false, true])
    func repeatAndColdProjection(firstReadThroughResume: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bad = try await fixture.compactedSession("bad")
        let good = try await fixture.compactedSession("good")
        let badSession = try #require(fixture.store.loadSession(id: bad.sessionID))
        let badURL = fixture.store.sessionsDirectory.appendingPathComponent(bad.sessionID + ".json")
        let goodURL = fixture.store.sessionsDirectory.appendingPathComponent(good.sessionID + ".json")
        let sessionBytes = try Data(contentsOf: badURL)
        let goodBytes = try Data(contentsOf: goodURL)
        let chainURL = fixture.store.compactionCheckpointsDirectory.appendingPathComponent("." + bad.checkpointID + ".chain.json")
        let chainBytes = try Data(contentsOf: chainURL)
        let payloadURL = fixture.store.compactionCheckpointsDirectory.appendingPathComponent(bad.checkpointID + ".json")
        let corrupt = Data(#"{"schemaVersion":1}"#.utf8)
        try corrupt.write(to: payloadURL, options: .atomic)

        if firstReadThroughResume {
            #expect(throws: (any Error).self) { try fixture.store.resumeMessages(sessionID: bad.sessionID) }
        } else {
            let first = SessionCompactProjection(sessionID: bad.sessionID, store: fixture.store)
            #expect(first.state == .blocked)
            #expect(first.stateLabel == "检查点校验阻断")
        }
        #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: fixture.store.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        let quarantineURL = try #require(quarantined.first)
        #expect(quarantineURL.lastPathComponent.hasPrefix(bad.checkpointID + "-"))
        #expect(try Data(contentsOf: quarantineURL) == corrupt)
        #expect(SHA256.hash(data: try Data(contentsOf: quarantineURL)) == SHA256.hash(data: corrupt))
        let tombstoneURL = fixture.store.compactionCheckpointsDirectory.appendingPathComponent("." + bad.checkpointID + ".cleanup.tombstone.json")
        let tombstoneBytes = try Data(contentsOf: tombstoneURL)

        let repeated = SessionCompactProjection(sessionID: bad.sessionID, store: fixture.store)
        #expect(repeated.state == .blocked)
        #expect(repeated.stateLabel == "检查点校验阻断")
        #expect(repeated.checkpointID == nil)
        let cold = SessionStore(directory: fixture.store.directory)
        let coldProjection = SessionCompactProjection(sessionID: bad.sessionID, store: cold)
        #expect(coldProjection.state == .blocked)
        #expect(coldProjection.stateLabel == "检查点校验阻断")
        #expect(coldProjection.checkpointID == nil)
        let siblingProjection = SessionCompactProjection(sessionID: good.sessionID, store: cold)
        #expect(siblingProjection.state == .checkpointed)
        #expect(siblingProjection.checkpointID == good.checkpointID)
        #expect(try cold.resumeMessages(sessionID: good.sessionID) == fixture.store.resumeMessages(sessionID: good.sessionID))
        #expect(cold.loadSession(id: bad.sessionID)?.messages == badSession.messages)
        #expect(cold.loadSession(id: bad.sessionID)?.transcriptRevision == badSession.transcriptRevision)
        #expect(try Data(contentsOf: badURL) == sessionBytes)
        #expect(try Data(contentsOf: goodURL) == goodBytes)
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
        #expect(try Data(contentsOf: quarantineURL) == corrupt)
    }

    @Test("a sibling's checkpoint does not turn a never-compacted session into pending validation")
    func neverCompactedSessionIsNotForeignCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let good = try await fixture.compactedSession("good")
        let legacy = try fixture.store.createSession(title: "never compacted")
        try fixture.store.saveMessage(LLMMessage(role: .user, content: "synthetic original"), sessionID: legacy.id)
        let canonical = try #require(fixture.store.loadSession(id: legacy.id))
        let bytesURL = fixture.store.sessionsDirectory.appendingPathComponent(legacy.id + ".json")
        let bytes = try Data(contentsOf: bytesURL)
        let projection = SessionCompactProjection(sessionID: legacy.id, store: fixture.store)
        #expect(projection.state == .noCheckpoint)
        #expect(projection.stateLabel == "暂无压缩检查点")
        #expect(projection.checkpointID == nil)
        #expect(SessionCompactProjection(sessionID: good.sessionID, store: fixture.store).state == .checkpointed)
        #expect(fixture.store.loadSession(id: legacy.id) == canonical)
        #expect(try Data(contentsOf: bytesURL) == bytes)
    }

    @Test("a missing committed payload without quarantine evidence remains blocked")
    func missingPayloadWithoutEvidenceIsBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = try await fixture.compactedSession("missing")
        let url = fixture.store.compactionCheckpointsDirectory.appendingPathComponent(missing.checkpointID + ".json")
        try FileManager.default.removeItem(at: url)
        let projection = SessionCompactProjection(sessionID: missing.sessionID, store: fixture.store)
        #expect(projection.state == .blocked)
        #expect(projection.checkpointID == nil)
    }

    private struct Fixture {
        let root: URL
        let store: SessionStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckpointQuarantine1145-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        }
        func compactedSession(_ title: String) async throws -> CompactionCheckpoint {
            let session = try store.createSession(title: title)
            for index in 1...4 {
                try store.saveMessage(LLMMessage(role: .user, content: "synthetic-\(title)-\(index)"), sessionID: session.id)
            }
            _ = try await store.compactSession(sessionID: session.id, using: Compactor(keepRecentMessages: 1))
            return try #require(try store.loadLatestCompactionCheckpoint(sessionID: session.id))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
