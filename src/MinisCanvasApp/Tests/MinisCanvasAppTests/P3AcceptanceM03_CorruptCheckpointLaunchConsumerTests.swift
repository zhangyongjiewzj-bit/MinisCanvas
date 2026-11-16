import CryptoKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-MEMORY-04: reconstruct the App's session owner and inspector projection
/// over a synthetic corrupt checkpoint. A real signed App process relaunch and
/// visible inspector journey remain separate L06 evidence.
@Suite("D-MEMORY-04 checkpoint recovery at the App consumer boundary")
@MainActor
struct P3AcceptanceM03_CorruptCheckpointLaunchConsumerTests {
    @Test("fresh ChatStore keeps the transcript and projects checkpoint validation as blocked")
    func reconstructedSessionShowsBlockedCheckpointWithoutRewritingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "P3AcceptanceM03-CorruptCheckpoint-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "P3AcceptanceM03.CorruptCheckpoint.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let sessionID = UUID()
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let writer = SessionStore(directory: sessionDirectory)
        _ = try writer.createSession(id: sessionID.uuidString, title: "synthetic checkpoint")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(role: .user, content: "synthetic-history-\(index)"),
                sessionID: sessionID.uuidString
            )
        }
        _ = try await writer.compactSession(
            sessionID: sessionID.uuidString,
            using: Compactor(keepRecentMessages: 1)
        )
        let committed = try #require(writer.loadSession(id: sessionID.uuidString))
        let checkpoint = try #require(try writer.loadLatestCompactionCheckpoint(
            sessionID: sessionID.uuidString
        ))
        let sessionURL = writer.sessionsDirectory.appendingPathComponent(
            sessionID.uuidString + ".json"
        )
        let committedBytes = try Data(contentsOf: sessionURL)
        let checkpointURL = writer.compactionCheckpointsDirectory.appendingPathComponent(
            checkpoint.checkpointID + ".json"
        )
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: checkpointURL, options: .atomic)
        let corruptBytes = try Data(contentsOf: checkpointURL)
        let chainURL = writer.compactionCheckpointsDirectory.appendingPathComponent(
            "." + checkpoint.checkpointID + ".chain.json"
        )
        let chainBytes = try Data(contentsOf: chainURL)

        // Fresh App-owned ChatStore and SessionStore use only this fixture's
        // explicit roots. attachPersistence is the actual launch consumer.
        let reader = SessionStore(directory: sessionDirectory)
        let chat = ChatStore(
            providerReadinessStore: ProviderReadinessStore(
                directory: root.appendingPathComponent("readiness")
            ),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
        )
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.attachPersistence(reader, badgeStore: SessionBadgeStore(
            directory: root.appendingPathComponent("badges")
        )))
        #expect(reader !== writer)
        #expect(chat.sessionManager?.store === reader)
        #expect(chat.activeSessionID == sessionID)
        #expect(chat.messages(forSession: sessionID)?.count == committed.messages.count)
        #expect(chat.messages(forSession: sessionID)?.map { $0.asLLMMessage() } == committed.messages)

        // ContentView's production inspector constructs this same projection
        // from chat.sessionManager?.store, rather than a test-only store.
        let projection = SessionCompactProjection(
            sessionID: chat.activeSessionID?.uuidString,
            store: chat.sessionManager?.store
        )
        #expect(projection.state == .blocked)
        #expect(projection.stateLabel == "检查点校验阻断")
        #expect(projection.checkpointID == nil)
        #expect(try Data(contentsOf: sessionURL) == committedBytes)
        // Validation removes the invalid active payload through the existing
        // quarantine contract; its exact bytes remain in this owned directory.
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
        let quarantineDirectory = reader.compactionCheckpointsQuarantineDirectory
        #expect(quarantineDirectory.isFileURL)
        #expect(quarantineDirectory.pathComponents == reader.sessionsDirectory
            .appendingPathComponent("_compaction-checkpoints-quarantine").pathComponents)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        let quarantineURL = try #require(quarantined.first)
        #expect(quarantineURL.lastPathComponent.hasPrefix(checkpoint.checkpointID + "-"))
        #expect(quarantineURL.pathExtension == "json")
        let quarantinedBytes = try Data(contentsOf: quarantineURL)
        #expect(quarantinedBytes == corruptBytes)
        #expect(SHA256.hash(data: quarantinedBytes) == SHA256.hash(data: corruptBytes))
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(reader.loadSession(id: sessionID.uuidString)?.messages == committed.messages)
        #expect(reader.loadSession(id: sessionID.uuidString)?.transcriptRevision == committed.transcriptRevision)
    }
}
