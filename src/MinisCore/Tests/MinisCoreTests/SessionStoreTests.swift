import Foundation
import Darwin
import CryptoKit
import Testing
@testable import MinisCore

// NOTE: Run on the CLT-only toolchain with the documented flags (see
// threads/B1-fix.log):
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeQuarantineTransactionMarker(
    store: SessionStore,
    checkpoint: CompactionCheckpoint,
    destinationName: String,
    sessionID: String? = nil,
    sessionGeneration: UInt64? = nil,
    payloadURL: URL? = nil
) throws {
    let sourceURL = payloadURL ?? store.compactionCheckpointsDirectory
        .appendingPathComponent("\(checkpoint.checkpointID).json")
    let payload = try Data(contentsOf: sourceURL)
    var info = stat()
    guard Darwin.lstat(sourceURL.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
    var marker: [String: Any] = [
        "schemaVersion": 1,
        "checkpointID": checkpoint.checkpointID,
        "sessionID": sessionID ?? checkpoint.sessionID,
        "sourceTranscriptRevision": checkpoint.sourceTranscriptRevision,
        "resultTranscriptRevision": checkpoint.resultTranscriptRevision,
        "contentDigest": checkpoint.contentDigest,
        "payloadDigest": SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
        "sourceDevice": NSNumber(value: info.st_dev),
        "sourceInode": NSNumber(value: info.st_ino),
        "sourceSize": NSNumber(value: info.st_size),
        "destinationName": destinationName
    ]
    if let sessionGeneration = sessionGeneration
        ?? store.loadSession(id: sessionID ?? checkpoint.sessionID)?.transcriptRevision {
        marker["sessionGeneration"] = NSNumber(value: sessionGeneration)
    }
    let markerURL = store.compactionCheckpointsDirectory
        .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
    try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        .write(to: markerURL, options: .atomic)
}

private func resealCleanupTombstone(_ record: inout [String: Any]) throws {
    let handoffKeys = [
        "checkpointID",
        "sessionID",
        "compactionEpoch",
        "payloadDigest",
        "checkpointChainDigest",
        "checkpointPredecessorDigest",
        "checkpointManifestRootDigest",
        "previousRootDigest",
        "sourceDevice",
        "sourceInode",
        "sourceSize",
        "destinationName",
    ]
    var handoffPayload: [String: Any] = [:]
    for key in handoffKeys {
        if let value = record[key] {
            handoffPayload[key] = value
        }
    }
    let payload = try JSONSerialization.data(
        withJSONObject: handoffPayload,
        options: [.sortedKeys]
    )
    record["handoffSeal"] = SHA256.hash(data: payload)
        .map { String(format: "%02x", $0) }
        .joined()
}

struct SessionStoreTests {

    // MARK: - Create / load

    @Test func createSessionWritesFileAndLoads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()

        #expect(store.loadSession(id: session.id) == session)
        let file = dir.appendingPathComponent("sessions/\(session.id).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func createSessionUniqueIDs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let a = try store.createSession()
        let b = try store.createSession()
        #expect(a.id != b.id)
        #expect(store.listSessions().count == 2)
    }

    @Test func loadMissingSessionReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        #expect(store.loadSession(id: "does-not-exist") == nil)
    }

    @Test func firstCheckpointCreatesSecureDirectoryBeforePreparedTransaction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession(id: "first-checkpoint")
        for index in 1...4 {
            try store.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "first-checkpoint-\(index)"
                ),
                sessionID: session.id
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: store.compactionCheckpointsDirectory.path
        ))

        let source = try #require(store.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "first-checkpoint"
        )
        var checkpointSaveError: Error?
        do {
            try store.saveCompactionCheckpoint(checkpoint)
        } catch {
            checkpointSaveError = error
        }
        let checkpointSaveDiagnostic = store.checkpointSaveDiagnosticState()
        try #require(
            checkpointSaveError == nil,
            "checkpoint-operation=save; checkpoint-persistence-stage=\(store.checkpointPersistenceDiagnosticStage()); checkpoint-save-stage=\(checkpointSaveDiagnostic.stage); checkpoint-candidate-presence=\(checkpointSaveDiagnostic.candidatePresence); checkpoint-payload-mismatch=\(checkpointSaveDiagnostic.payloadMismatch)"
        )

        var directoryInfo = stat()
        #expect(Darwin.lstat(store.compactionCheckpointsDirectory.path, &directoryInfo) == 0)
        #expect((directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR))
        #expect(directoryInfo.st_uid == getuid())
        #expect((directoryInfo.st_mode & mode_t(0o022)) == 0)
        do {
            #expect(try store.loadLatestCompactionCheckpoint(sessionID: session.id) == checkpoint)
        } catch {
            Issue.record("checkpoint-operation=read; checkpoint-read-stage=\(store.checkpointReadDiagnosticStage())")
            throw error
        }
    }

    @Test func checkpointIntegrityIsStableForKeyRichPayloadAcrossStores() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "canonical-checkpoint-integrity")
        for index in 0..<4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "canonical-source-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        var summary = LLMMessage(
            role: .user,
            content: "<context-summary>canonical integrity</context-summary>"
        )
        summary.images = [
            .init(mimeType: "image/png", data: Data([0x89, 0x50, 0x4e, 0x47])),
            .init(mimeType: "image/jpeg", data: Data([0xff, 0xd8, 0xff])),
        ]
        summary.audios = [
            .init(format: "wav", base64Data: "UklGRg=="),
            .init(format: "mp3", base64Data: "SUQz"),
        ]
        var assistant = LLMMessage(role: .assistant, content: "canonical tool calls")
        assistant.toolCalls = [
            LLMToolCall(
                id: "call-z",
                name: "write_file",
                rawArguments: #"{"z":2,"a":1}"#,
                arguments: ["z": 2, "a": 1]
            ),
            LLMToolCall(
                id: "call-a",
                name: "read_file",
                rawArguments: #"{"path":"/tmp/canonical"}"#,
                arguments: ["path": "/tmp/canonical"]
            ),
        ]
        let toolResult = LLMMessage(
            role: .tool,
            content: "canonical result",
            toolCallID: "call-z"
        )
        let replacement = [summary, assistant, toolResult]
        let checkpoint = CompactionCheckpoint(
            checkpointID: "canonical-checkpoint-integrity",
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            resultTranscriptRevision: source.transcriptRevision + 1,
            compactedThroughMessageID: Compactor.stableMessageID(
                source.messages[3],
                transcriptIndex: 3
            ),
            compactedMessageRange: 0..<4,
            summaryMessage: summary,
            replacementHistory: replacement,
            lineage: source.lineageIdentity,
            contentDigest: "",
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456)
        ).withDigest()

        try writer.saveCompactionCheckpoint(checkpoint)
        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        let preparedURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.prepared.json")
        let sessionURL = writer.sessionsDirectory.appendingPathComponent(source.id + ".json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let chainBytes = try Data(contentsOf: chainURL)
        let sessionBytes = try Data(contentsOf: sessionURL)
        let chainRoot = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        let manifestRoot = try #require(chainRoot["manifestRootDigest"] as? String)
        let inventory = try #require(chainRoot["segmentInventory"] as? [String])
        let payloadDigest = try #require(chainRoot["payloadDigest"] as? String)
        let transactionID = try #require(chainRoot["transactionID"] as? String)
        #expect(manifestRoot.count == 64)
        #expect(inventory.count == replacement.count)
        #expect(payloadDigest.count == 64)
        #expect(UUID(uuidString: transactionID) != nil)
        #expect(!FileManager.default.fileExists(atPath: preparedURL.path))

        let secondStore = SessionStore(directory: dir)
        try secondStore.saveCompactionCheckpoint(checkpoint)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(try Data(contentsOf: sessionURL) == sessionBytes)
        #expect(!FileManager.default.fileExists(atPath: preparedURL.path))

        let restarted = SessionStore(directory: dir)
        #expect(try restarted.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
        #expect(try restarted.resumeMessages(sessionID: source.id) == replacement)
        let restored = try #require(restarted.loadSession(id: source.id))
        #expect(restored.messages.map(\.role) == [.user, .assistant, .tool])
        #expect(restored.messages[0].images.map(\.mimeType) == ["image/png", "image/jpeg"])
        #expect(restored.messages[0].audios.map(\.format) == ["wav", "mp3"])
        #expect(restored.messages[1].toolCalls.map(\.id) == ["call-z", "call-a"])
        #expect(restored.messages[1].toolCalls.map(\.rawArguments) == [
            #"{"z":2,"a":1}"#,
            #"{"path":"/tmp/canonical"}"#,
        ])
        #expect(restored.messages[2].toolCallID == "call-z")
    }

    @Test func durableCheckpointRejectsAmbiguousToolArgumentPayloads() async throws {
        let cases = [
            ("malformed", #"{"path":"#),
            ("non-object", #"["path"]"#),
            ("duplicate", #"{"path":"a","path":"b"}"#),
        ]

        for (suffix, rawArguments) in cases {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let writer = SessionStore(directory: dir)
            let session = try writer.createSession(
                id: "checkpoint-tool-arguments-" + suffix
            )
            for index in 1...4 {
                try writer.saveMessage(
                    LLMMessage(
                        role: index.isMultiple(of: 2) ? .assistant : .user,
                        content: "tool-arguments-" + String(index)
                    ),
                    sessionID: session.id
                )
            }
            let source = try #require(writer.loadSession(id: session.id))
            let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
            let checkpoint = try CompactionCheckpoint.make(
                sessionID: source.id,
                sourceTranscriptRevision: source.transcriptRevision,
                sourceMessages: source.messages,
                result: result,
                checkpointID: "checkpoint-tool-arguments-" + suffix
            )

            let poisonedSummary = LLMMessage(
                role: checkpoint.summaryMessage.role,
                content: checkpoint.summaryMessage.content,
                images: checkpoint.summaryMessage.images,
                audios: checkpoint.summaryMessage.audios,
                toolCallID: checkpoint.summaryMessage.toolCallID,
                toolCalls: [LLMToolCall(
                    id: "call-ambiguous-" + suffix,
                    name: "read",
                    rawArguments: rawArguments,
                    arguments: [:]
                )]
            )
            var poisonedHistory = checkpoint.replacementHistory
            poisonedHistory[0] = poisonedSummary
            let poisonedCheckpoint = CompactionCheckpoint(
                schemaVersion: checkpoint.schemaVersion,
                checkpointID: checkpoint.checkpointID,
                sessionID: checkpoint.sessionID,
                sourceTranscriptRevision: checkpoint.sourceTranscriptRevision,
                resultTranscriptRevision: checkpoint.resultTranscriptRevision,
                compactedThroughMessageID: checkpoint.compactedThroughMessageID,
                compactedMessageRange: checkpoint.compactedMessageRange,
                summaryMessage: poisonedSummary,
                replacementHistory: poisonedHistory,
                lineage: checkpoint.lineage,
                contentDigest: "",
                createdAt: checkpoint.createdAt
            ).withDigest()
            try writer.saveCompactionCheckpoint(poisonedCheckpoint)

            let checkpointURL = writer.compactionCheckpointsDirectory
                .appendingPathComponent(checkpoint.checkpointID + ".json")
            let poisonedBytes = try Data(contentsOf: checkpointURL)
            let sessionURL = writer.sessionsDirectory
                .appendingPathComponent(session.id + ".json")
            let sessionBytes = try Data(contentsOf: sessionURL)

            let reader = SessionStore(directory: dir)
            #expect(throws: SessionStoreError.invalidCompactionCheckpoint(
                checkpoint.checkpointID
            )) {
                try reader.loadLatestCompactionCheckpoint(sessionID: session.id)
            }
            #expect(try Data(contentsOf: sessionURL) == sessionBytes)
            #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
            let quarantined = try FileManager.default.contentsOfDirectory(
                at: writer.compactionCheckpointsQuarantineDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            #expect(quarantined.count == 1)
            #expect(try Data(contentsOf: try #require(quarantined.first)) == poisonedBytes)
        }
    }

    // MARK: - Messages

    /// 重试从最后一条用户消息重新开始：其后失败那一轮的工具调用、工具结果、半截回答和错误提示
    /// 都去掉，之前的历史不动；看到的会话与落盘不一致时拒绝。
    @Test func discardOutputAfterLastUserMessageKeepsHistoryAndRejectsStaleSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        let call = LLMToolCall(id: "call-1", name: "file_glob", rawArguments: "{}", arguments: [:])
        let kept = [
            LLMMessage(role: .user, content: "第一问"),
            LLMMessage(role: .assistant, content: "第一答"),
            LLMMessage(role: .user, content: "第二问"),
        ]
        let failed = [
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: "a.txt", toolCallID: "call-1"),
            LLMMessage(role: .assistant, content: "半截回答"),
            LLMMessage(role: .assistant, content: "**错误**：本会话累计用量已达上限"),
        ]
        for message in kept + failed { try store.saveMessage(message, sessionID: session.id) }
        let before = try #require(store.loadSession(id: session.id))

        let committed = try store.discardOutputAfterLastUserMessage(expectedSession: before)
        #expect(committed.messages == kept)
        #expect(committed.transcriptRevision == before.transcriptRevision + 1)
        #expect(SessionStore(directory: dir).loadSession(id: session.id)?.messages == kept)

        // 已经以用户消息结尾、或调用方拿的是旧快照：都拒绝，不改落盘。
        #expect(throws: SessionStoreError.self) { try store.discardOutputAfterLastUserMessage(expectedSession: committed) }
        #expect(throws: SessionStoreError.self) { try store.discardOutputAfterLastUserMessage(expectedSession: before) }
        #expect(store.loadSession(id: session.id) == committed)
    }

    @Test func saveMessageRoundTripsAcrossStoreInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession()

        let user = LLMMessage(role: .user, content: "帮我总结一下这个项目")
        let assistant = LLMMessage(role: .assistant, content: "好的，项目总结如下……")
        try writer.saveMessage(user, sessionID: session.id)
        try writer.saveMessage(assistant, sessionID: session.id)

        // Fresh store instance reads from disk — proves real persistence.
        let reader = SessionStore(directory: dir)
        let loaded = try #require(reader.loadSession(id: session.id))
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[0].role == .user)
        #expect(loaded.messages[0].content == "帮我总结一下这个项目")
        #expect(loaded.messages[1].role == .assistant)
        #expect(loaded.messages[1].content == "好的，项目总结如下……")
        #expect(loaded.updatedAt >= loaded.createdAt)
    }

    @Test func saveMessageToMissingSessionThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.sessionNotFound("nope")) {
            try store.saveMessage(LLMMessage(role: .user, content: "hi"), sessionID: "nope")
        }
    }

    @Test func foreignSessionCheckpointDoesNotBlockOrQuarantineCurrentSession() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        _ = try store.createSession(id: "session-a")
        let sessionB = try store.createSession(id: "session-b")
        for index in 1...4 {
            try store.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: sessionB.id
            )
        }
        let source = try #require(store.loadSession(id: sessionB.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: sessionB.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "session-b-checkpoint"
        )
        try store.saveCompactionCheckpoint(checkpoint)

        let foreignURL = store.compactionCheckpointsDirectory
            .appendingPathComponent("session-a-corrupt.json")
        try Data(
            #"{"schemaVersion":1,"sessionID":"session-a","checkpointID":"session-a-corrupt"}"#.utf8
        ).write(to: foreignURL, options: .atomic)

        let reader = SessionStore(directory: dir)
        #expect(
            try reader.loadLatestCompactionCheckpoint(sessionID: sessionB.id) == checkpoint
        )
        let committed = try #require(reader.loadSession(id: sessionB.id))
        #expect(try reader.resumeMessages(sessionID: sessionB.id) == committed.messages)
        #expect(committed.messages.filter { $0.content.contains("<context-summary>") }.count == 1)
        #expect(
            try reader.loadLatestCompactionCheckpoint(sessionID: sessionB.id) == checkpoint
        )
        #expect(FileManager.default.fileExists(atPath: foreignURL.path))
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("session-a-corrupt")) {
            try reader.resumeMessages(sessionID: "session-a")
        }
        #expect(reader.loadSession(id: "session-a")?.messages.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: foreignURL.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: reader.compactionCheckpointsQuarantineDirectory.path
            )
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func completeForeignCheckpointInjectionDoesNotReplaceCurrentSessionHistory() async throws {
        let sourceRoot = try makeTempDir()
        let targetRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }

        let foreignWriter = SessionStore(directory: sourceRoot)
        let foreign = try foreignWriter.createSession(id: "foreign-session")
        for index in 1...4 {
            try foreignWriter.saveMessage(
                LLMMessage(role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "foreign-message-\(index)"),
                sessionID: foreign.id
            )
        }
        let foreignSource = try #require(foreignWriter.loadSession(id: foreign.id))
        let foreignResult = try await Compactor(keepRecentMessages: 2)
            .compact(messages: foreignSource.messages)
        let foreignCheckpoint = try CompactionCheckpoint.make(
            sessionID: foreign.id,
            sourceTranscriptRevision: foreignSource.transcriptRevision,
            sourceMessages: foreignSource.messages,
            result: foreignResult,
            checkpointID: "complete-foreign-checkpoint"
        )
        try foreignWriter.saveCompactionCheckpoint(foreignCheckpoint)
        let foreignReader = SessionStore(directory: sourceRoot)
        #expect(try foreignReader.loadLatestCompactionCheckpoint(sessionID: foreign.id)
            == foreignCheckpoint)
        let foreignCommitted = try #require(foreignReader.loadSession(id: foreign.id))
        #expect(try foreignReader.resumeMessages(sessionID: foreign.id)
            == foreignCommitted.messages)
        let foreignURL = foreignWriter.compactionCheckpointsDirectory
            .appendingPathComponent("complete-foreign-checkpoint.json")
        let completeForeignBytes = try Data(contentsOf: foreignURL)

        let targetWriter = SessionStore(directory: targetRoot)
        let target = try targetWriter.createSession(id: "target-session")
        for index in 1...4 {
            try targetWriter.saveMessage(
                LLMMessage(role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "target-message-\(index)"),
                sessionID: target.id
            )
        }
        let targetSource = try #require(targetWriter.loadSession(id: target.id))
        let targetResult = try await Compactor(keepRecentMessages: 2)
            .compact(messages: targetSource.messages)
        let targetCheckpoint = try CompactionCheckpoint.make(
            sessionID: target.id,
            sourceTranscriptRevision: targetSource.transcriptRevision,
            sourceMessages: targetSource.messages,
            result: targetResult,
            checkpointID: "target-checkpoint"
        )
        try targetWriter.saveCompactionCheckpoint(targetCheckpoint)
        let beforeTarget = try #require(targetWriter.loadSession(id: target.id))
        let targetSessionURL = targetWriter.sessionsDirectory
            .appendingPathComponent("\(target.id).json")
        let targetCheckpointURL = targetWriter.compactionCheckpointsDirectory
            .appendingPathComponent("\(targetCheckpoint.checkpointID).json")
        let beforeSessionBytes = try Data(contentsOf: targetSessionURL)
        let beforeCheckpointBytes = try Data(contentsOf: targetCheckpointURL)

        let injectedURL = targetWriter.compactionCheckpointsDirectory
            .appendingPathComponent("\(foreignCheckpoint.checkpointID).json")
        try completeForeignBytes.write(to: injectedURL, options: .atomic)
        #expect(try Data(contentsOf: injectedURL) == completeForeignBytes)

        let reader = SessionStore(directory: targetRoot)
        #expect(try reader.resumeMessages(sessionID: target.id) == beforeTarget.messages)
        #expect(reader.loadSession(id: target.id) == beforeTarget)
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: target.id)
            == targetCheckpoint)
        #expect(try Data(contentsOf: targetSessionURL) == beforeSessionBytes)
        #expect(try Data(contentsOf: targetCheckpointURL) == beforeCheckpointBytes)
        #expect(try Data(contentsOf: injectedURL) == completeForeignBytes)
        let quarantine = reader.compactionCheckpointsQuarantineDirectory
        if FileManager.default.fileExists(atPath: quarantine.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).isEmpty)
        }
    }

    @Test func unboundCheckpointFailsClosedWithoutRewritingCurrentSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession(id: "unbound-target")
        try store.saveMessage(
            LLMMessage(role: .user, content: "keep this transcript"),
            sessionID: session.id
        )
        let before = try #require(store.loadSession(id: session.id))
        let sidecar = store.compactionCheckpointsDirectory
            .appendingPathComponent("unbound-checkpoint.json")
        try FileManager.default.createDirectory(
            at: store.compactionCheckpointsDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"schemaVersion":1,"checkpointID":"unbound-checkpoint"}"#.utf8
        ).write(to: sidecar, options: .atomic)

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("unbound-checkpoint")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(reader.loadSession(id: session.id) == before)
        #expect(
            FileManager.default.fileExists(atPath: sidecar.path) == false,
            "quarantine-stage=\(reader.quarantineDiagnosticStage())"
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func checkpointPayloadDirectoryAuthorizationUsesPinnedFilesystemIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.compactionCheckpointsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.compactionCheckpointsQuarantineDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.compactionCheckpointsDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.compactionCheckpointsQuarantineDirectory.path
        )

        let trustedPath = store.compactionCheckpointsDirectory.path
        let aliasPath: String
        if trustedPath.hasPrefix("/private/") {
            aliasPath = String(trustedPath.dropFirst("/private".count))
        } else if trustedPath.hasPrefix("/var/") || trustedPath.hasPrefix("/tmp/") {
            aliasPath = "/private" + trustedPath
        } else {
            aliasPath = trustedPath
        }
        let aliasDescriptor = try store.openSecureCheckpointPayloadDirectoryDescriptor(
            at: URL(fileURLWithPath: aliasPath, isDirectory: true)
        )
        var trustedInfo = stat()
        var aliasInfo = stat()
        #expect(Darwin.lstat(trustedPath, &trustedInfo) == 0)
        #expect(Darwin.fstat(aliasDescriptor, &aliasInfo) == 0)
        #expect(aliasInfo.st_dev == trustedInfo.st_dev)
        #expect(aliasInfo.st_ino == trustedInfo.st_ino)
        _ = Darwin.close(aliasDescriptor)

        let externalDirectory = dir.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: externalDirectory.path
        )
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            let descriptor = try store.openSecureCheckpointPayloadDirectoryDescriptor(
                at: externalDirectory
            )
            _ = Darwin.close(descriptor)
        }

        let displacedDirectory = store.sessionsDirectory.appendingPathComponent(
            "_compaction-checkpoints-displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: store.compactionCheckpointsDirectory,
            to: displacedDirectory
        )
        try FileManager.default.createDirectory(
            at: store.compactionCheckpointsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.compactionCheckpointsDirectory.path
        )
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            let descriptor = try store.openSecureCheckpointPayloadDirectoryDescriptor(
                at: displacedDirectory
            )
            _ = Darwin.close(descriptor)
        }

        let symlink = store.sessionsDirectory.appendingPathComponent(
            "checkpoint-directory-symlink",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: store.compactionCheckpointsDirectory
        )
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            let descriptor = try store.openSecureCheckpointPayloadDirectoryDescriptor(at: symlink)
            _ = Darwin.close(descriptor)
        }
    }

    @Test func checkpointRestartReapsPrivateTemporaryAfterCrashWindow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-recovery")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-recovery"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let orphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".checkpoint-recovery." + UUID().uuidString + ".tmp")
        try Data("partial".utf8).write(to: orphan)

        let reader = SessionStore(directory: dir)
        #expect(try reader.resumeMessages(sessionID: source.id) == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        let restartedReader = SessionStore(directory: dir)
        #expect(try restartedReader.resumeMessages(sessionID: source.id) == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)

        let external = dir.appendingPathComponent("external-temp-evidence.json")
        let externalBytes = Data("retain external temp".utf8)
        try externalBytes.write(to: external, options: .atomic)
        let linkedOrphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".checkpoint-recovery-linked.tmp")
        try FileManager.default.linkItem(at: external, to: linkedOrphan)
        let hardlinkReader = SessionStore(directory: dir)
        #expect(try hardlinkReader.resumeMessages(sessionID: source.id) == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: linkedOrphan.path))
        #expect(try Data(contentsOf: external) == externalBytes)
        try FileManager.default.removeItem(at: linkedOrphan)

        let symlinkTarget = dir.appendingPathComponent("external-symlink-temp.json")
        let symlinkBytes = Data("retain symlink target".utf8)
        try symlinkBytes.write(to: symlinkTarget, options: .atomic)
        let symlinkOrphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".checkpoint-recovery-symlink.tmp")
        try FileManager.default.createSymbolicLink(
            at: symlinkOrphan,
            withDestinationURL: symlinkTarget
        )
        let symlinkReader = SessionStore(directory: dir)
        #expect(try symlinkReader.resumeMessages(sessionID: source.id) == checkpoint.replacementHistory)
        #expect(FileManager.default.fileExists(atPath: symlinkOrphan.path))
        #expect(try Data(contentsOf: symlinkTarget) == symlinkBytes)
        try FileManager.default.removeItem(at: symlinkOrphan)
    }

    @Test func checkpointRecoveryFailsClosedWhenDirectoryCannotBeEnumerated() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-unreadable-directory")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-unreadable-directory"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let committedSession = try #require(writer.loadSession(id: session.id))
        #expect(committedSession.messages == checkpoint.replacementHistory)
        #expect(committedSession.transcriptRevision == checkpoint.resultTranscriptRevision)
        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)

        // A checkpoint directory that cannot be enumerated is not an empty
        // directory. Recovery must stop before it can skip durable state.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: writer.compactionCheckpointsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: writer.compactionCheckpointsDirectory.path
            )
        }

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            try reader.loadLatestCompactionCheckpoint(sessionID: session.id)
        }
        #expect(reader.loadSession(id: session.id) == committedSession)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: writer.compactionCheckpointsDirectory.path
        )
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
    }

    @Test func checkpointRestartRejectsOrphanedReplacementExactlyOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-partial-write")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sourceData = try Data(
            contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
        )
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-partial-write"
        )

        // Simulate a crash after the durable sidecar write but before the
        // session replacement write becomes visible.
        try writer.saveCompactionCheckpoint(checkpoint)
        let orphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + "-orphan.tmp")
        try Data("partial".utf8).write(to: orphan)
        try sourceData.write(
            to: dir.appendingPathComponent("sessions/\(session.id).json"),
            options: .atomic
        )

        let reader = SessionStore(directory: dir)
        #expect(try reader.resumeMessages(sessionID: session.id) == source.messages)
        #expect(try reader.resumeMessages(sessionID: session.id) == source.messages)
        // The committed chain record remains as historical evidence after the
        // orphan payload is durably quarantined. It must not turn a legitimate
        // empty active payload set into a recovery failure.
        #expect(try reader.loadLatestCompactionCheckpoint(sessionID: session.id) == nil)
        let retained = try #require(reader.loadSession(id: session.id))
        #expect(retained.transcriptRevision == source.transcriptRevision)
        #expect(retained.messages == source.messages)
        #expect(retained.messages.filter { $0.content.contains("<context-summary>") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            ) == false
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func failedCheckpointQuarantineKeepsSidecarForRestartRetry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-quarantine-retry")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sourceData = try Data(
            contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
        )
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-quarantine-retry"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        try sourceData.write(
            to: dir.appendingPathComponent("sessions/\(session.id).json"),
            options: .atomic
        )
        let orphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + "-orphan.tmp")
        try Data("partial".utf8).write(to: orphan)

        // A non-directory at the quarantine destination makes the rename
        // fail. The sidecar must remain available for a later restart retry.
        try Data("quarantine-blocker".utf8).write(
            to: writer.compactionCheckpointsQuarantineDirectory,
            options: .atomic
        )
        let failedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try failedReader.resumeMessages(sessionID: session.id)
        }
        #expect(failedReader.loadSession(id: session.id) == source)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            )
        )
        // Lock acquisition still bounds and removes the orphan temp before
        // attempting the failed quarantine.
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)

        try FileManager.default.removeItem(at: writer.compactionCheckpointsQuarantineDirectory)
        let retryReader = SessionStore(directory: dir)
        #expect(try retryReader.resumeMessages(sessionID: session.id) == source.messages)
        let restartReader = SessionStore(directory: dir)
        #expect(try restartReader.resumeMessages(sessionID: session.id) == source.messages)
        let retained = try #require(restartReader.loadSession(id: session.id))
        #expect(retained.transcriptRevision == source.transcriptRevision)
        #expect(retained.messages == source.messages)
        #expect(retained.messages.filter { $0.content.contains("<context-summary>") }.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            ) == false
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: restartReader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        let receiptURL = try #require(quarantined.first)
        let receiptAttributes = try FileManager.default.attributesOfItem(
            atPath: receiptURL.path
        )
        #expect((receiptAttributes[.type] as? FileAttributeType) == .typeRegular)
        #expect(
            (receiptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        let receipt = try Data(contentsOf: receiptURL)
        #expect(try JSONDecoder().decode(CompactionCheckpoint.self, from: receipt) == checkpoint)
    }

    @Test func concurrentCheckpointRestartQuarantinesOrphanOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-concurrent-recovery")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sourceData = try Data(
            contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
        )
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-concurrent-recovery"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        try sourceData.write(
            to: dir.appendingPathComponent("sessions/\(session.id).json"),
            options: .atomic
        )
        let orphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + "-orphan.tmp")
        try Data("partial".utf8).write(to: orphan)

        let readers = [SessionStore(directory: dir), SessionStore(directory: dir)]
        let results = try await withThrowingTaskGroup(of: [LLMMessage].self) { group in
            for reader in readers {
                group.addTask {
                    try reader.resumeMessages(sessionID: session.id)
                }
            }
            var values: [[LLMMessage]] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0 == source.messages })
        let retained = try #require(SessionStore(directory: dir).loadSession(id: session.id))
        #expect(retained.transcriptRevision == source.transcriptRevision)
        #expect(retained.messages.filter { $0.content.contains("<context-summary>") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            ) == false
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func checkpointQuarantineTransactionRecoversAfterMoveCrash() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-transaction-recovery")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sourceData = try Data(
            contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
        )
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-transaction-recovery"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        try sourceData.write(
            to: dir.appendingPathComponent("sessions/\(session.id).json"),
            options: .atomic
        )
        let destinationName = "\(checkpoint.checkpointID)-recovery.json"
        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: destinationName
        )
        let destinationURL = writer.compactionCheckpointsQuarantineDirectory
            .appendingPathComponent(destinationName)
        try FileManager.default.createDirectory(
            at: writer.compactionCheckpointsQuarantineDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: writer.compactionCheckpointsDirectory
                .appendingPathComponent("\(checkpoint.checkpointID).json"),
            to: destinationURL
        )
        let orphan = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + "-orphan.tmp")
        try Data("partial".utf8).write(to: orphan)

        let reader = SessionStore(directory: dir)
        #expect(try reader.resumeMessages(sessionID: session.id) == source.messages)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            ) == false
        )
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json").path
            ) == false
        )
        #expect(try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)
        let restartReader = SessionStore(directory: dir)
        #expect(try restartReader.resumeMessages(sessionID: session.id) == source.messages)
        let retained = try #require(restartReader.loadSession(id: session.id))
        #expect(retained.transcriptRevision == source.transcriptRevision)
        #expect(retained.messages.filter { $0.content.contains("<context-summary>") }.isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: restartReader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.map(\.lastPathComponent) == [destinationName])

        // Simulate a crash after marker cleanup but before the parent
        // directory fsync: the destination receipt survives and the marker is
        // left behind. Recovery must clear only that marker, never move again.
        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: destinationName,
            payloadURL: destinationURL
        )
        let finalReader = SessionStore(directory: dir)
        #expect(try finalReader.resumeMessages(sessionID: session.id) == source.messages)
        #expect(try finalReader.resumeMessages(sessionID: session.id) == source.messages)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json").path
            ) == false
        )
        let receiptsAfterRetry = try FileManager.default.contentsOfDirectory(
            at: finalReader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(receiptsAfterRetry.map(\.lastPathComponent) == [destinationName])
    }

    @Test func corruptQuarantineTransactionFailsClosedWithoutMovingCheckpoint() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-transaction-marker")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-transaction-marker"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        try Data("truncated-marker".utf8).write(to: markerURL, options: .atomic)

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            )
        )
        let retained = try #require(reader.loadSession(id: session.id))
        #expect(retained.transcriptRevision == checkpoint.resultTranscriptRevision)
        #expect(retained.messages.filter { $0.content.contains("<context-summary>") }.count == 1)

        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: "wrong-session.json",
            sessionID: "another-session"
        )
        let wrongSessionReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try wrongSessionReader.resumeMessages(sessionID: session.id)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            )
        )
    }

    @Test func mismatchedQuarantineReceiptRemainsEvidenceAndFailsClosed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-receipt-binding")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-receipt-binding"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        let foreignName = "foreign-receipt.json"
        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: foreignName
        )
        let foreignURL = writer.compactionCheckpointsQuarantineDirectory
            .appendingPathComponent(foreignName)
        try FileManager.default.createDirectory(
            at: writer.compactionCheckpointsQuarantineDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: writer.compactionCheckpointsDirectory
                .appendingPathComponent("\(checkpoint.checkpointID).json"),
            to: foreignURL
        )

        let wrongIDReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try wrongIDReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: foreignURL.path))
        #expect(
            try #require(wrongIDReader.loadSession(id: session.id)).messages
                == checkpoint.replacementHistory
        )

        let validName = "\(checkpoint.checkpointID)-recovery.json"
        let validURL = writer.compactionCheckpointsQuarantineDirectory
            .appendingPathComponent(validName)
        try FileManager.default.moveItem(at: foreignURL, to: validURL)
        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: validName,
            payloadURL: validURL
        )
        let externalReceiptURL = dir.appendingPathComponent("external-receipt.json")
        let externalReceiptBytes = Data("external-receipt-evidence".utf8)
        try externalReceiptBytes.write(to: externalReceiptURL, options: .atomic)
        try FileManager.default.removeItem(at: validURL)
        try FileManager.default.createSymbolicLink(
            at: validURL,
            withDestinationURL: externalReceiptURL
        )
        let symlinkReceiptReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try symlinkReceiptReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: validURL.path))
        #expect(try Data(contentsOf: externalReceiptURL) == externalReceiptBytes)
        try FileManager.default.removeItem(at: validURL)
        try Data("tampered receipt".utf8).write(to: validURL, options: .atomic)
        let retainedMarkerBytes = try Data(contentsOf: markerURL)
        let retainedReceiptBytes = try Data(contentsOf: validURL)

        let wrongDigestReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try wrongDigestReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: validURL.path))
        #expect(try Data(contentsOf: markerURL) == retainedMarkerBytes)
        #expect(try Data(contentsOf: validURL) == retainedReceiptBytes)
        #expect(
            try #require(wrongDigestReader.loadSession(id: session.id)).messages
                == checkpoint.replacementHistory
        )
        let retryReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try retryReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: validURL.path))
        #expect(try Data(contentsOf: markerURL) == retainedMarkerBytes)
        #expect(try Data(contentsOf: validURL) == retainedReceiptBytes)

        let independentSession = try writer.createSession(id: "checkpoint-independent-session")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "independent-\(index)"
                ),
                sessionID: independentSession.id
            )
        }
        let independentSource = try #require(writer.loadSession(id: independentSession.id))
        let independentResult = try await Compactor(keepRecentMessages: 2)
            .compact(messages: independentSource.messages)
        let independentCheckpoint = try CompactionCheckpoint.make(
            sessionID: independentSource.id,
            sourceTranscriptRevision: independentSource.transcriptRevision,
            sourceMessages: independentSource.messages,
            result: independentResult,
            checkpointID: "checkpoint-independent"
        )
        try writer.saveCompactionCheckpoint(independentCheckpoint)
        let independentReader = SessionStore(directory: dir)
        #expect(
            try independentReader.resumeMessages(sessionID: independentSession.id)
                == independentCheckpoint.replacementHistory
        )
    }

    @Test func nonCanonicalQuarantineReceiptNamesFailClosedInPlace() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-receipt-paths")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-receipt-paths"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        let sourceURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        let invalidNames = [
            "../escape.json",
            ".\(checkpoint.checkpointID)-hidden.json",
            "\(checkpoint.checkpointID)-e\u{301}.json"
        ]
        for invalidName in invalidNames {
            try writeQuarantineTransactionMarker(
                store: writer,
                checkpoint: checkpoint,
                destinationName: invalidName
            )
            let reader = SessionStore(directory: dir)
            #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
                try reader.resumeMessages(sessionID: session.id)
            }
            #expect(FileManager.default.fileExists(atPath: sourceURL.path))
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }
        let escapedURL = dir.deletingLastPathComponent().appendingPathComponent("escape.json")
        #expect(FileManager.default.fileExists(atPath: escapedURL.path) == false)
        let committedSession = try #require(writer.loadSession(id: session.id))
        #expect(committedSession.messages == checkpoint.replacementHistory)
        #expect(committedSession.transcriptRevision == checkpoint.resultTranscriptRevision)
        try FileManager.default.removeItem(at: markerURL)

        let unicodeCheckpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-\u{00E9}"
        )
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(unicodeCheckpoint.checkpointID)) {
            try writer.saveCompactionCheckpoint(unicodeCheckpoint)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let oversizedCheckpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: String(repeating: "x", count: 129)
        )
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(oversizedCheckpoint.checkpointID)) {
            try writer.saveCompactionCheckpoint(oversizedCheckpoint)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test func replacementAndStaleQuarantineMarkersRequireRecovery() async throws {
        let replacementDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: replacementDir) }

        let replacementWriter = SessionStore(directory: replacementDir)
        let replacementSession = try replacementWriter.createSession(id: "checkpoint-replaced-sidecar")
        for index in 1...4 {
            try replacementWriter.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "replacement-" + String(index)
                ),
                sessionID: replacementSession.id
            )
        }
        let replacementSource = try #require(replacementWriter.loadSession(id: replacementSession.id))
        let replacementResult = try await Compactor(keepRecentMessages: 2)
            .compact(messages: replacementSource.messages)
        let replacementCheckpoint = try CompactionCheckpoint.make(
            sessionID: replacementSource.id,
            sourceTranscriptRevision: replacementSource.transcriptRevision,
            sourceMessages: replacementSource.messages,
            result: replacementResult,
            checkpointID: "checkpoint-replaced-sidecar"
        )
        try replacementWriter.saveCompactionCheckpoint(replacementCheckpoint)

        let replacementURL = replacementWriter.compactionCheckpointsDirectory
            .appendingPathComponent(replacementCheckpoint.checkpointID + ".json")
        let originalSidecarBytes = try Data(contentsOf: replacementURL)
        let markerURL = replacementWriter.compactionCheckpointsDirectory
            .appendingPathComponent("." + replacementCheckpoint.checkpointID + ".quarantine.txn.json")
        try writeQuarantineTransactionMarker(
            store: replacementWriter,
            checkpoint: replacementCheckpoint,
            destinationName: replacementCheckpoint.checkpointID + "-replacement.json"
        )
        try originalSidecarBytes.write(to: replacementURL, options: .atomic)
        let retainedMarkerBytes = try Data(contentsOf: markerURL)

        let replacementReader = SessionStore(directory: replacementDir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(replacementCheckpoint.checkpointID)) {
            try replacementReader.resumeMessages(sessionID: replacementSession.id)
        }
        #expect(try Data(contentsOf: replacementURL) == originalSidecarBytes)
        #expect(try Data(contentsOf: markerURL) == retainedMarkerBytes)

        let staleDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: staleDir) }

        let staleWriter = SessionStore(directory: staleDir)
        let staleSession = try staleWriter.createSession(id: "checkpoint-stale-generation")
        for index in 1...4 {
            try staleWriter.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "stale-" + String(index)
                ),
                sessionID: staleSession.id
            )
        }
        let staleSource = try #require(staleWriter.loadSession(id: staleSession.id))
        let staleResult = try await Compactor(keepRecentMessages: 2)
            .compact(messages: staleSource.messages)
        let staleCheckpoint = try CompactionCheckpoint.make(
            sessionID: staleSource.id,
            sourceTranscriptRevision: staleSource.transcriptRevision,
            sourceMessages: staleSource.messages,
            result: staleResult,
            checkpointID: "checkpoint-stale-generation"
        )
        try staleWriter.saveCompactionCheckpoint(staleCheckpoint)
        let staleURL = staleWriter.compactionCheckpointsDirectory
            .appendingPathComponent(staleCheckpoint.checkpointID + ".json")
        let staleSidecarBytes = try Data(contentsOf: staleURL)
        let staleMarkerURL = staleWriter.compactionCheckpointsDirectory
            .appendingPathComponent("." + staleCheckpoint.checkpointID + ".quarantine.txn.json")
        try writeQuarantineTransactionMarker(
            store: staleWriter,
            checkpoint: staleCheckpoint,
            destinationName: staleCheckpoint.checkpointID + "-stale.json"
        )
        let newGenerationMessage = LLMMessage(role: .user, content: "new generation")
        try staleWriter.saveMessage(
            newGenerationMessage,
            sessionID: staleSession.id
        )
        let staleMarkerBytes = try Data(contentsOf: staleMarkerURL)

        let staleReader = SessionStore(directory: staleDir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(staleCheckpoint.checkpointID)) {
            try staleReader.resumeMessages(sessionID: staleSession.id)
        }
        #expect(try Data(contentsOf: staleURL) == staleSidecarBytes)
        #expect(try Data(contentsOf: staleMarkerURL) == staleMarkerBytes)
        let retainedSession = try #require(staleReader.loadSession(id: staleSession.id))
        #expect(retainedSession.transcriptRevision == staleCheckpoint.resultTranscriptRevision + 1)
        #expect(retainedSession.messages == staleCheckpoint.replacementHistory + [newGenerationMessage])
    }

    @Test func checkpointChainRejectsFutureForkAndBrokenPreviousDigest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-chain")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "chain-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-chain-first"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let checkpointDirectoryAttributes = try FileManager.default.attributesOfItem(
            atPath: writer.compactionCheckpointsDirectory.path
        )
        #expect(
            (checkpointDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        )
        #expect(try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)

        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        var checkpointInfo = stat()
        #expect(Darwin.lstat(checkpointURL.path, &checkpointInfo) == 0)
        #expect(checkpointInfo.st_nlink == 1)
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let chainBytes = try Data(contentsOf: chainURL)
        let compactedSession = try #require(writer.loadSession(id: session.id))
        try FileManager.default.removeItem(at: checkpointURL)
        let missingPayloadReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(
            checkpoint.checkpointID
        )) {
            try missingPayloadReader.resumeMessages(sessionID: session.id)
        }
        #expect(missingPayloadReader.loadSession(id: session.id) == compactedSession)
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        try checkpointBytes.write(to: checkpointURL, options: .atomic)
        let externalChainURL = dir.appendingPathComponent("external-chain.json")
        try Data("external chain target".utf8).write(to: externalChainURL)
        try FileManager.default.removeItem(at: chainURL)
        try FileManager.default.createSymbolicLink(
            at: chainURL,
            withDestinationURL: externalChainURL
        )
        let symlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try symlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try symlinkReader.loadLatestCompactionCheckpoint(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: externalChainURL) == Data("external chain target".utf8))
        try FileManager.default.removeItem(at: chainURL)
        try chainBytes.write(to: chainURL, options: .atomic)
        var chainInfo = stat()
        #expect(Darwin.lstat(chainURL.path, &chainInfo) == 0)
        #expect((chainInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG))
        #expect(chainInfo.st_nlink == 1)
        #expect((chainInfo.st_mode & mode_t(0o022)) == 0)

        try FileManager.default.removeItem(at: chainURL)
        try FileManager.default.linkItem(at: externalChainURL, to: chainURL)
        let hardlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try hardlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: externalChainURL) == Data("external chain target".utf8))
        try FileManager.default.removeItem(at: chainURL)
        try chainBytes.write(to: chainURL, options: .atomic)

        var replacementHistory = checkpoint.replacementHistory
        replacementHistory.append(LLMMessage(role: .assistant, content: "payload replacement"))
        let replacementCheckpoint = CompactionCheckpoint(
            schemaVersion: checkpoint.schemaVersion,
            checkpointID: checkpoint.checkpointID,
            sessionID: checkpoint.sessionID,
            sourceTranscriptRevision: checkpoint.sourceTranscriptRevision,
            resultTranscriptRevision: checkpoint.resultTranscriptRevision,
            compactedThroughMessageID: checkpoint.compactedThroughMessageID,
            compactedMessageRange: checkpoint.compactedMessageRange,
            summaryMessage: checkpoint.summaryMessage,
            replacementHistory: replacementHistory,
            lineage: checkpoint.lineage,
            contentDigest: "",
            createdAt: checkpoint.createdAt
        ).withDigest()
        let replacementBytes = try JSONEncoder().encode(replacementCheckpoint)
        try replacementBytes.write(to: checkpointURL, options: .atomic)
        let replacementReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try replacementReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(try Data(contentsOf: checkpointURL) == replacementBytes)
        try checkpointBytes.write(to: checkpointURL, options: .atomic)

        var payloadDigestRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        payloadDigestRecord["payloadDigest"] = String(repeating: "0", count: 64)
        let payloadDigestBytes = try JSONSerialization.data(
            withJSONObject: payloadDigestRecord,
            options: [.sortedKeys]
        )
        try payloadDigestBytes.write(to: chainURL, options: .atomic)
        let payloadDigestReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.self) {
            try payloadDigestReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == payloadDigestBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var staleEpochRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        staleEpochRecord["compactionEpoch"] = NSNumber(value: checkpoint.sourceTranscriptRevision)
        let staleEpochBytes = try JSONSerialization.data(
            withJSONObject: staleEpochRecord,
            options: [.sortedKeys]
        )
        try staleEpochBytes.write(to: chainURL, options: .atomic)
        let staleEpochReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try staleEpochReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == staleEpochBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var stalePredecessorRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        stalePredecessorRecord["epochPredecessorDigest"] = String(repeating: "0", count: 64)
        let stalePredecessorBytes = try JSONSerialization.data(
            withJSONObject: stalePredecessorRecord,
            options: [.sortedKeys]
        )
        try stalePredecessorBytes.write(to: chainURL, options: .atomic)
        let stalePredecessorReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try stalePredecessorReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == stalePredecessorBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var missingSegmentRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        var missingInventory = try #require(
            missingSegmentRecord["segmentInventory"] as? [String]
        )
        missingInventory.removeLast()
        missingSegmentRecord["segmentInventory"] = missingInventory
        let missingSegmentBytes = try JSONSerialization.data(
            withJSONObject: missingSegmentRecord,
            options: [.sortedKeys]
        )
        try missingSegmentBytes.write(to: chainURL, options: .atomic)
        let missingSegmentReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try missingSegmentReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == missingSegmentBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var overflowManifestRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        overflowManifestRecord["segmentAggregateBytes"] = NSNumber(value: 4 * 1024 * 1024 + 1)
        let overflowManifestBytes = try JSONSerialization.data(
            withJSONObject: overflowManifestRecord,
            options: [.sortedKeys]
        )
        try overflowManifestBytes.write(to: chainURL, options: .atomic)
        let overflowManifestReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try overflowManifestReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == overflowManifestBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        let forkJSON = try #require(String(data: chainBytes, encoding: .utf8))
            .replacingOccurrences(
                of: "\"checkpointID\":\"\(checkpoint.checkpointID)\"",
                with: "\"checkpointID\":\"checkpoint-chain-fork\""
            )
            .replacingOccurrences(
                of: "\"scopeCheckpointID\":\"\(checkpoint.checkpointID)\"",
                with: "\"scopeCheckpointID\":\"checkpoint-chain-fork\""
            )
        let forkBytes = try #require(forkJSON.data(using: .utf8))
        let forkURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".checkpoint-chain-fork.chain.json")
        try forkBytes.write(to: forkURL, options: .atomic)
        let forkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.self) {
            try forkReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == chainBytes)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: forkURL) == forkBytes)
        try FileManager.default.removeItem(at: forkURL)

        var unknownKeyRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        unknownKeyRecord["unknownField"] = true
        let unknownKeyBytes = try JSONSerialization.data(
            withJSONObject: unknownKeyRecord,
            options: [.sortedKeys]
        )
        try unknownKeyBytes.write(to: chainURL, options: .atomic)
        let unknownKeyReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try unknownKeyReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == unknownKeyBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var confusableKeyRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        confusableKeyRecord["schemaVersion\u{0430}"] = 1
        let confusableKeyBytes = try JSONSerialization.data(
            withJSONObject: confusableKeyRecord,
            options: [.sortedKeys]
        )
        try confusableKeyBytes.write(to: chainURL, options: .atomic)
        let confusableKeyReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try confusableKeyReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == confusableKeyBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        let canonicalChainJSON = try #require(String(data: chainBytes, encoding: .utf8))
        let duplicateKeyJSON = canonicalChainJSON.replacingOccurrences(
            of: "\"schemaVersion\":1",
            with: "\"schemaVersion\":1,\"schemaVersion\":1"
        )
        let duplicateKeyBytes = try #require(duplicateKeyJSON.data(using: .utf8))
        try duplicateKeyBytes.write(to: chainURL, options: .atomic)
        let duplicateKeyReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try duplicateKeyReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == duplicateKeyBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var oversizedChainBytes = chainBytes
        oversizedChainBytes.append(Data(repeating: 0x20, count: 64 * 1024))
        try oversizedChainBytes.write(to: chainURL, options: .atomic)
        let oversizedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try oversizedReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == oversizedChainBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var futureRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        futureRecord["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: futureRecord, options: [.sortedKeys])
            .write(to: chainURL, options: .atomic)
        let futureChainBytes = try Data(contentsOf: chainURL)
        let futureReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try futureReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == futureChainBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        let secondSource = try #require(writer.loadSession(id: session.id))
        let secondResult = try await Compactor(keepRecentMessages: 1)
            .compact(messages: secondSource.messages)
        let secondCheckpoint = try CompactionCheckpoint.make(
            sessionID: secondSource.id,
            sourceTranscriptRevision: secondSource.transcriptRevision,
            sourceMessages: secondSource.messages,
            result: secondResult,
            checkpointID: "checkpoint-chain-second"
        )
        try writer.saveCompactionCheckpoint(secondCheckpoint)
        let secondURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(secondCheckpoint.checkpointID + ".json")
        let secondChainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + secondCheckpoint.checkpointID + ".chain.json")
        let secondBytes = try Data(contentsOf: secondURL)
        let secondChainBytes = try Data(contentsOf: secondChainURL)
        try writer.saveCompactionCheckpoint(secondCheckpoint)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        #expect(try Data(contentsOf: secondChainURL) == secondChainBytes)
        var brokenChain = try #require(
            JSONSerialization.jsonObject(with: secondChainBytes) as? [String: Any]
        )
        brokenChain["previousDigest"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: brokenChain, options: [.sortedKeys])
            .write(to: secondChainURL, options: .atomic)
        let brokenChainBytes = try Data(contentsOf: secondChainURL)

        let brokenReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(secondCheckpoint.checkpointID)) {
            try brokenReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        #expect(try Data(contentsOf: secondChainURL) == brokenChainBytes)
        try secondChainBytes.write(to: secondChainURL, options: .atomic)

        let duplicate = CompactionCheckpoint(
            checkpointID: "checkpoint-chain-duplicate",
            sessionID: secondCheckpoint.sessionID,
            sourceTranscriptRevision: secondCheckpoint.sourceTranscriptRevision,
            resultTranscriptRevision: secondCheckpoint.resultTranscriptRevision,
            compactedThroughMessageID: secondCheckpoint.compactedThroughMessageID,
            compactedMessageRange: secondCheckpoint.compactedMessageRange,
            summaryMessage: secondCheckpoint.summaryMessage,
            replacementHistory: secondCheckpoint.replacementHistory,
            lineage: secondCheckpoint.lineage,
            contentDigest: "",
            createdAt: secondCheckpoint.createdAt
        ).withDigest()
        let duplicateURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(duplicate.checkpointID + ".json")
        let duplicateBytes = try JSONEncoder().encode(duplicate)
        try duplicateBytes.write(to: duplicateURL, options: .atomic)

        let duplicateReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(duplicate.checkpointID)) {
            try duplicateReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        #expect(try Data(contentsOf: duplicateURL) == duplicateBytes)
    }

    @Test func checkpointChainRejectsSegmentGenerationReplayAndDivergentPredecessor() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-segment-cas")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "segment-cas-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-segment-cas"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let chainBytes = try Data(contentsOf: chainURL)

        var replayRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        var replayGenerations = try #require(
            replayRecord["segmentGenerations"] as? [NSNumber]
        )
        #expect(!replayGenerations.isEmpty)
        replayGenerations[0] = NSNumber(value: checkpoint.sourceTranscriptRevision)
        replayRecord["segmentGenerations"] = replayGenerations
        let replayBytes = try JSONSerialization.data(
            withJSONObject: replayRecord,
            options: [.sortedKeys]
        )
        try replayBytes.write(to: chainURL, options: .atomic)
        let replayReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try replayReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == replayBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var partialRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        var partialGenerations = try #require(
            partialRecord["segmentGenerations"] as? [NSNumber]
        )
        #expect(partialGenerations.count > 1)
        partialGenerations.removeLast()
        partialRecord["segmentGenerations"] = partialGenerations
        let partialBytes = try JSONSerialization.data(
            withJSONObject: partialRecord,
            options: [.sortedKeys]
        )
        try partialBytes.write(to: chainURL, options: .atomic)
        let partialReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try partialReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == partialBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var divergentRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        var divergentPredecessors = try #require(
            divergentRecord["segmentPredecessorDigests"] as? [Any]
        )
        #expect(divergentPredecessors.count > 1)
        divergentPredecessors[1] = String(repeating: "0", count: 64)
        divergentRecord["segmentPredecessorDigests"] = divergentPredecessors
        let divergentBytes = try JSONSerialization.data(
            withJSONObject: divergentRecord,
            options: [.sortedKeys]
        )
        try divergentBytes.write(to: chainURL, options: .atomic)
        let divergentReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try divergentReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == divergentBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        var nonEmptyFirstRecord = try #require(
            JSONSerialization.jsonObject(with: chainBytes) as? [String: Any]
        )
        var nonEmptyFirstPredecessors = try #require(
            nonEmptyFirstRecord["segmentPredecessorDigests"] as? [Any]
        )
        #expect(!nonEmptyFirstPredecessors.isEmpty)
        nonEmptyFirstPredecessors[0] = String(repeating: "0", count: 64)
        nonEmptyFirstRecord["segmentPredecessorDigests"] = nonEmptyFirstPredecessors
        let nonEmptyFirstManifest: [String: Any] = [
            "segmentInventory": try #require(nonEmptyFirstRecord["segmentInventory"]),
            "segmentSizes": try #require(nonEmptyFirstRecord["segmentSizes"]),
            "aggregateBytes": try #require(nonEmptyFirstRecord["segmentAggregateBytes"]),
            "segmentGenerations": try #require(nonEmptyFirstRecord["segmentGenerations"]),
            "segmentPredecessorDigests": nonEmptyFirstPredecessors,
        ]
        let nonEmptyFirstManifestData = try JSONSerialization.data(
            withJSONObject: nonEmptyFirstManifest,
            options: [.sortedKeys]
        )
        nonEmptyFirstRecord["manifestRootDigest"] = SHA256.hash(
            data: nonEmptyFirstManifestData
        ).map { String(format: "%02x", $0) }.joined()
        let nonEmptyFirstBytes = try JSONSerialization.data(
            withJSONObject: nonEmptyFirstRecord,
            options: [.sortedKeys]
        )
        try nonEmptyFirstBytes.write(to: chainURL, options: .atomic)
        let nonEmptyFirstReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try nonEmptyFirstReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == nonEmptyFirstBytes)
        try chainBytes.write(to: chainURL, options: .atomic)

        let validReader = SessionStore(directory: dir)
        _ = try validReader.resumeMessages(sessionID: session.id)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: chainURL) == chainBytes)
    }

    @Test func checkpointCleanupTombstoneFencesResurrectionAndIdentityRecreate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-cleanup-tombstone")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "cleanup-tombstone-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sessionURL = writer.sessionsDirectory.appendingPathComponent(source.id + ".json")
        let sourceSessionBytes = try Data(contentsOf: sessionURL)
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-cleanup-tombstone"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let chainBytes = try Data(contentsOf: chainURL)
        try sourceSessionBytes.write(to: sessionURL, options: .atomic)
        let orphanedSession = try #require(writer.loadSession(id: session.id))
        #expect(orphanedSession.transcriptRevision == checkpoint.sourceTranscriptRevision)
        #expect(orphanedSession.messages == source.messages)

        #expect(try writer.resumeMessages(sessionID: session.id) == source.messages)
        #expect(try Data(contentsOf: sessionURL) == sourceSessionBytes)
        #expect(try Data(contentsOf: chainURL) == chainBytes)

        let tombstoneURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).cleanup.tombstone.json")
        let tombstoneBytes = try Data(contentsOf: tombstoneURL)
        let tombstoneAttributes = try FileManager.default.attributesOfItem(
            atPath: tombstoneURL.path
        )
        #expect(
            (tombstoneAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        var tombstoneInfo = stat()
        #expect(Darwin.lstat(tombstoneURL.path, &tombstoneInfo) == 0)
        #expect(tombstoneInfo.st_nlink == 1)
        #expect(try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)
        var tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        let originalHandoffSeal = try #require(tombstoneRecord["handoffSeal"] as? String)
        var pristineResealedTombstone = tombstoneRecord
        try resealCleanupTombstone(&pristineResealedTombstone)
        #expect(pristineResealedTombstone["handoffSeal"] as? String == originalHandoffSeal)
        let destinationName = try #require(
            tombstoneRecord["destinationName"] as? String
        )
        let destinationURL = writer.compactionCheckpointsQuarantineDirectory
            .appendingPathComponent(destinationName)
        let destinationBytes = try Data(contentsOf: destinationURL)
        let destinationAttributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        #expect(
            (destinationAttributes[.type] as? FileAttributeType) == .typeRegular
        )
        #expect(
            (destinationAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        let quarantineDirectoryAttributes = try FileManager.default.attributesOfItem(
            atPath: writer.compactionCheckpointsQuarantineDirectory.path
        )
        #expect(
            (quarantineDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        )
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        let validReader = SessionStore(directory: dir)
        _ = try validReader.resumeMessages(sessionID: session.id)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        #expect(try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        let rolledEpoch = checkpoint.resultTranscriptRevision + 1
        tombstoneRecord["compactionEpoch"] = NSNumber(value: rolledEpoch)
        tombstoneRecord["resultTranscriptRevision"] = NSNumber(value: rolledEpoch)
        try resealCleanupTombstone(&tombstoneRecord)
        let rolledEpochTombstoneBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try rolledEpochTombstoneBytes.write(to: tombstoneURL, options: .atomic)
        let rolledEpochReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try rolledEpochReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == rolledEpochTombstoneBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["compactionEpoch"] = NSNumber(
            value: checkpoint.sourceTranscriptRevision
        )
        tombstoneRecord["resultTranscriptRevision"] = NSNumber(
            value: checkpoint.sourceTranscriptRevision
        )
        try resealCleanupTombstone(&tombstoneRecord)
        let staleEpochTombstoneBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try staleEpochTombstoneBytes.write(to: tombstoneURL, options: .atomic)
        let staleEpochReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try staleEpochReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == staleEpochTombstoneBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["previousRootDigest"] = String(repeating: "0", count: 64)
        try resealCleanupTombstone(&tombstoneRecord)
        let previousRootSubstitutionBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try previousRootSubstitutionBytes.write(to: tombstoneURL, options: .atomic)
        let previousRootReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try previousRootReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == previousRootSubstitutionBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["checkpointManifestRootDigest"] = String(repeating: "0", count: 64)
        try resealCleanupTombstone(&tombstoneRecord)
        let manifestRootSubstitutionBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try manifestRootSubstitutionBytes.write(to: tombstoneURL, options: .atomic)
        let manifestRootReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try manifestRootReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == manifestRootSubstitutionBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["checkpointPredecessorDigest"] = String(repeating: "0", count: 64)
        try resealCleanupTombstone(&tombstoneRecord)
        let checkpointPredecessorSubstitutionBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try checkpointPredecessorSubstitutionBytes.write(to: tombstoneURL, options: .atomic)
        let checkpointPredecessorReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try checkpointPredecessorReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == checkpointPredecessorSubstitutionBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["handoffSeal"] = String(repeating: "0", count: 64)
        let handoffSealSubstitutionBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try handoffSealSubstitutionBytes.write(to: tombstoneURL, options: .atomic)
        let handoffSealReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try handoffSealReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == handoffSealSubstitutionBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["sessionGeneration"] = NSNumber(
            value: source.transcriptRevision + 1
        )
        try resealCleanupTombstone(&tombstoneRecord)
        let futureGenerationTombstoneBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try futureGenerationTombstoneBytes.write(to: tombstoneURL, options: .atomic)
        let futureGenerationReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try futureGenerationReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == futureGenerationTombstoneBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["checkpointChainDigest"] = String(repeating: "0", count: 64)
        try resealCleanupTombstone(&tombstoneRecord)
        let successorSubstitutionBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try successorSubstitutionBytes.write(to: tombstoneURL, options: .atomic)
        let successorSubstitutionReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try successorSubstitutionReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == successorSubstitutionBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        try checkpointBytes.write(to: checkpointURL, options: .atomic)
        let resurrectionReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try resurrectionReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
        try FileManager.default.removeItem(at: checkpointURL)

        tombstoneRecord = try #require(
            JSONSerialization.jsonObject(with: tombstoneBytes) as? [String: Any]
        )
        tombstoneRecord["payloadDigest"] = String(repeating: "0", count: 64)
        try resealCleanupTombstone(&tombstoneRecord)
        let substitutedTombstoneBytes = try JSONSerialization.data(
            withJSONObject: tombstoneRecord,
            options: [.sortedKeys]
        )
        try substitutedTombstoneBytes.write(to: tombstoneURL, options: .atomic)
        let substitutedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try substitutedReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: tombstoneURL) == substitutedTombstoneBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        try tombstoneBytes.write(to: tombstoneURL, options: .atomic)

        let hardlinkSourceURL = dir.appendingPathComponent(
            "cleanup-tombstone-hardlink-source.json"
        )
        try checkpointBytes.write(to: hardlinkSourceURL, options: .atomic)
        try FileManager.default.linkItem(at: hardlinkSourceURL, to: checkpointURL)
        var hardlinkDestinationInfo = stat()
        #expect(Darwin.lstat(destinationURL.path, &hardlinkDestinationInfo) == 0)
        #expect(hardlinkDestinationInfo.st_nlink == 1)
        let hardlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try hardlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        #expect(try Data(contentsOf: hardlinkSourceURL) == checkpointBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
        try FileManager.default.removeItem(at: checkpointURL)

        let externalURL = dir.appendingPathComponent("cleanup-tombstone-external.json")
        let externalBytes = Data("external checkpoint target".utf8)
        try externalBytes.write(to: externalURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: checkpointURL,
            withDestinationURL: externalURL
        )
        let symlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try symlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
        try FileManager.default.removeItem(at: checkpointURL)

        let finalReader = SessionStore(directory: dir)
        _ = try finalReader.resumeMessages(sessionID: session.id)
        #expect(try Data(contentsOf: tombstoneURL) == tombstoneBytes)
    }

    @Test func checkpointSymlinkIsRejectedWithoutTouchingExternalTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-symlink-sidecar")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "symlink-sidecar-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-symlink-sidecar"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        try FileManager.default.removeItem(at: checkpointURL)
        let externalURL = dir.appendingPathComponent("external-sidecar.json")
        let externalBytes = Data("external-sidecar-evidence".utf8)
        try externalBytes.write(to: externalURL, options: .atomic)
        try FileManager.default.createSymbolicLink(at: checkpointURL, withDestinationURL: externalURL)

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try reader.loadLatestCompactionCheckpoint(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path))
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        #expect(!FileManager.default.fileExists(
            atPath: writer.compactionCheckpointsQuarantineDirectory.path
        ))
    }

    @Test func checkpointRootSymlinkFailsClosedWithoutTouchingTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-root-symlink")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "root-symlink-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-root-symlink"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointRoot = writer.compactionCheckpointsDirectory
        let realCheckpointRoot = dir.appendingPathComponent("_real-checkpoints")
        let checkpointURL = realCheckpointRoot
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let checkpointBytes = try Data(contentsOf: checkpointRoot
            .appendingPathComponent(checkpoint.checkpointID + ".json"))
        try FileManager.default.moveItem(at: checkpointRoot, to: realCheckpointRoot)
        try FileManager.default.createSymbolicLink(
            at: checkpointRoot,
            withDestinationURL: realCheckpointRoot
        )
        defer {
            try? FileManager.default.removeItem(at: checkpointRoot)
            try? FileManager.default.moveItem(at: realCheckpointRoot, to: checkpointRoot)
        }

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            try reader.loadLatestCompactionCheckpoint(sessionID: session.id)
        }
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
    }

    @Test func checkpointChainPreparedRecoveryRequiresCommittedSuccessor() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-chain-phases")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "phase-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-chain-phases"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        let checkpointURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(checkpoint.checkpointID + ".json")
        let chainURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.json")
        let preparedURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("." + checkpoint.checkpointID + ".chain.prepared.json")
        let checkpointBytes = try Data(contentsOf: checkpointURL)
        let committedBytes = try Data(contentsOf: chainURL)
        let sessionURL = writer.sessionsDirectory
            .appendingPathComponent("\(session.id).json")
        let committedSessionBytes = try Data(contentsOf: sessionURL)
        let committedMessages = try #require(writer.loadSession(id: session.id)).messages

        let committedJSON = try #require(String(data: committedBytes, encoding: .utf8))
        let committedRecord = try #require(
            JSONSerialization.jsonObject(with: committedBytes) as? [String: Any]
        )
        let transactionID = try #require(committedRecord["transactionID"] as? String)
        let preparedJSON = committedJSON.replacingOccurrences(
            of: "\"phase\":\"committed\"",
            with: "\"phase\":\"prepared\""
        )
        let preparedBytes = try #require(preparedJSON.data(using: .utf8))
        try FileManager.default.removeItem(at: chainURL)
        try preparedBytes.write(to: preparedURL, options: .atomic)

        let preparedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try preparedReader.resumeMessages(sessionID: session.id)
        }
        #expect(preparedReader.loadSession(id: session.id)?.messages
            == writer.loadSession(id: session.id)?.messages)
        #expect(FileManager.default.fileExists(atPath: chainURL.path) == false)
        #expect(try Data(contentsOf: preparedURL) == preparedBytes)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)

        let unknownPhaseJSON = committedJSON.replacingOccurrences(
            of: "\"phase\":\"committed\"",
            with: "\"phase\":\"future\""
        )
        let unknownPhaseBytes = try #require(unknownPhaseJSON.data(using: .utf8))
        try preparedBytes.write(to: preparedURL, options: .atomic)
        try unknownPhaseBytes.write(to: chainURL, options: .atomic)
        let unknownPhaseReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try unknownPhaseReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == unknownPhaseBytes)
        #expect(try Data(contentsOf: preparedURL) == preparedBytes)
        try FileManager.default.removeItem(at: chainURL)
        try committedBytes.write(to: chainURL, options: .atomic)

        let mismatchedTransactionJSON = preparedJSON.replacingOccurrences(
            of: "\"transactionID\":\"\(transactionID)\"",
            with: "\"transactionID\":\"00000000-0000-4000-8000-000000000000\""
        )
        let mismatchedTransactionBytes = try #require(
            mismatchedTransactionJSON.data(using: .utf8)
        )
        try mismatchedTransactionBytes.write(to: preparedURL, options: .atomic)
        let mismatchedTransactionReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try mismatchedTransactionReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == committedBytes)
        #expect(try Data(contentsOf: preparedURL) == mismatchedTransactionBytes)
        try preparedBytes.write(to: preparedURL, options: .atomic)

        try FileManager.default.removeItem(at: preparedURL)
        let mismatchedScopeJSON = committedJSON.replacingOccurrences(
            of: "\"scopeSessionID\":\"\(session.id)\"",
            with: "\"scopeSessionID\":\"other-session\""
        )
        let mismatchedScopeBytes = try #require(mismatchedScopeJSON.data(using: .utf8))
        try mismatchedScopeBytes.write(to: chainURL, options: .atomic)
        let mismatchedScopeReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try mismatchedScopeReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == mismatchedScopeBytes)
        #expect(try Data(contentsOf: sessionURL) == committedSessionBytes)
        #expect(mismatchedScopeReader.loadSession(id: session.id)?.messages == committedMessages)
        try FileManager.default.removeItem(at: chainURL)
        try committedBytes.write(to: chainURL, options: .atomic)

        let crossSessionJSON = committedJSON.replacingOccurrences(
            of: "\"sessionID\":\"\(session.id)\"",
            with: "\"sessionID\":\"other-session\""
        )
        let crossSessionBytes = try #require(crossSessionJSON.data(using: .utf8))
        try crossSessionBytes.write(to: chainURL, options: .atomic)
        let crossSessionReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try crossSessionReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == crossSessionBytes)
        #expect(try Data(contentsOf: sessionURL) == committedSessionBytes)
        #expect(crossSessionReader.loadSession(id: session.id)?.messages == committedMessages)
        try FileManager.default.removeItem(at: chainURL)
        try committedBytes.write(to: chainURL, options: .atomic)

        let externalCandidateURL = dir.appendingPathComponent("external-chain-candidate.json")
        try Data("external candidate".utf8).write(to: externalCandidateURL)
        try FileManager.default.createSymbolicLink(
            at: preparedURL,
            withDestinationURL: externalCandidateURL
        )
        let symlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try symlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == committedBytes)
        #expect(try Data(contentsOf: externalCandidateURL) == Data("external candidate".utf8))
        try FileManager.default.removeItem(at: preparedURL)

        let externalLinkedCandidateURL = dir.appendingPathComponent(
            "external-linked-chain-candidate.json"
        )
        let externalLinkedBytes = Data("external linked candidate".utf8)
        try externalLinkedBytes.write(to: externalLinkedCandidateURL, options: .atomic)
        try FileManager.default.linkItem(
            at: externalLinkedCandidateURL,
            to: preparedURL
        )
        let hardlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try hardlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: preparedURL.path))
        var hardlinkInfo = stat()
        #expect(Darwin.lstat(preparedURL.path, &hardlinkInfo) == 0)
        #expect(hardlinkInfo.st_nlink == 2)
        #expect(try Data(contentsOf: externalLinkedCandidateURL) == externalLinkedBytes)
        try FileManager.default.removeItem(at: preparedURL)

        let stalePreparedJSON = preparedJSON.replacingOccurrences(
            of: "\"resultTranscriptRevision\":\(checkpoint.resultTranscriptRevision)",
            with: "\"resultTranscriptRevision\":\(checkpoint.sourceTranscriptRevision)"
        )
        let stalePreparedBytes = try #require(stalePreparedJSON.data(using: .utf8))
        try stalePreparedBytes.write(to: preparedURL, options: .atomic)
        let staleReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try staleReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: chainURL) == committedBytes)
        #expect(try Data(contentsOf: preparedURL) == stalePreparedBytes)
        try FileManager.default.removeItem(at: preparedURL)

        try FileManager.default.removeItem(at: chainURL)
        let missingReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)) {
            try missingReader.resumeMessages(sessionID: session.id)
        }
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
        try committedBytes.write(to: chainURL, options: .atomic)

        let committedReader = SessionStore(directory: dir)
        #expect(try Data(contentsOf: sessionURL) == committedSessionBytes)
        #expect(committedReader.loadSession(id: session.id)?.messages == committedMessages)
        #expect(try committedReader.resumeMessages(sessionID: session.id) == committedMessages)
        #expect(try committedReader.resumeMessages(sessionID: session.id) == committedMessages)
        #expect(try Data(contentsOf: chainURL) == committedBytes)
        #expect(try Data(contentsOf: checkpointURL) == checkpointBytes)
    }

    @Test func quarantineCapacityOverflowFailsClosedWithoutPartialReceipt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-quarantine-capacity")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-quarantine-capacity"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let sourceURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        try Data("truncated".utf8).write(to: sourceURL, options: .atomic)

        let quarantineDirectory = writer.compactionCheckpointsQuarantineDirectory
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        for index in 0..<512 {
            try Data([0]).write(
                to: quarantineDirectory.appendingPathComponent("receipt-\(index).json")
            )
        }
        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        let countLimitedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try countLimitedReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).count == 512)

        for entry in try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try FileManager.default.removeItem(at: entry)
        }
        let oversizedReceipt = quarantineDirectory.appendingPathComponent("receipt-oversized.json")
        try Data().write(to: oversizedReceipt)
        let oversizedHandle = try FileHandle(forWritingTo: oversizedReceipt)
        try oversizedHandle.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1))
        try oversizedHandle.close()

        let byteLimitedReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try byteLimitedReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: oversizedReceipt.path))
    }

    @Test func quarantineCapacityRejectsExternalAndNonRegularEntries() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-quarantine-entries")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-quarantine-entries"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let sourceURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        let quarantineDirectory = writer.compactionCheckpointsQuarantineDirectory
        let externalDirectory = dir.deletingLastPathComponent()
            .appendingPathComponent("MinisCore-quarantine-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDirectory) }
        let externalPayload = externalDirectory.appendingPathComponent("payload.json")
        try Data("keep external".utf8).write(to: externalPayload)

        try FileManager.default.createSymbolicLink(
            at: quarantineDirectory,
            withDestinationURL: externalDirectory
        )
        let symlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try symlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: externalPayload.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        try FileManager.default.removeItem(at: quarantineDirectory)
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        let hardlink = quarantineDirectory.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: externalPayload, to: hardlink)
        let hardlinkReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try hardlinkReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: externalPayload.path))
        #expect(FileManager.default.fileExists(atPath: hardlink.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        try FileManager.default.removeItem(at: hardlink)

        let nestedDirectory = quarantineDirectory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let directoryReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try directoryReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: nestedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        let retainedSession = try #require(directoryReader.loadSession(id: session.id))
        #expect(retainedSession.messages == checkpoint.replacementHistory)
        #expect(retainedSession.transcriptRevision == checkpoint.resultTranscriptRevision)
    }

    @Test func quarantineOwnershipAndPermissionsFailClosed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "checkpoint-quarantine-permissions")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "checkpoint-quarantine-permissions"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let sourceURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        try Data("truncated".utf8).write(to: sourceURL, options: .atomic)
        let markerURL = writer.compactionCheckpointsDirectory
            .appendingPathComponent(".\(checkpoint.checkpointID).quarantine.txn.json")
        let quarantineDirectory = writer.compactionCheckpointsQuarantineDirectory
        try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: quarantineDirectory.path
        )
        let rootReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try rootReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: quarantineDirectory.path
        )
        let receipt = quarantineDirectory.appendingPathComponent("receipt.json")
        try Data("untrusted".utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: receipt.path)
        let entryReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try entryReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path) == false)
        #expect(try Data(contentsOf: receipt) == Data("untrusted".utf8))
        let retainedSession = try #require(entryReader.loadSession(id: session.id))
        #expect(retainedSession.messages == checkpoint.replacementHistory)
        #expect(retainedSession.transcriptRevision == checkpoint.resultTranscriptRevision)

        try FileManager.default.removeItem(at: receipt)
        try writeQuarantineTransactionMarker(
            store: writer,
            checkpoint: checkpoint,
            destinationName: "\(checkpoint.checkpointID)-mode-drift.json"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: quarantineDirectory.path
        )
        let moveReader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")) {
            try moveReader.resumeMessages(sessionID: session.id)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test func staleCheckpointAgainstNewerTranscriptFailsClosedAndQuarantines() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "stale-checkpoint")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "stale-checkpoint"
        )
        try writer.saveCompactionCheckpoint(checkpoint)

        // Simulate a newer transcript written after this checkpoint. It no
        // longer carries the checkpoint replacement prefix, so applying the
        // old sidecar would overwrite newer conversation state.
        var newer = try #require(writer.loadSession(id: source.id))
        newer.messages = [
            LLMMessage(role: .user, content: "newer transcript")
        ]
        newer.transcriptRevision = checkpoint.resultTranscriptRevision + 1
        try writer.updateSession(newer)

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.compactionCheckpointBoundaryMismatch(checkpoint.checkpointID)) {
            try reader.resumeMessages(sessionID: source.id)
        }
        #expect(reader.loadSession(id: source.id) == newer)
        let checkpointPath = reader.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        #expect(FileManager.default.fileExists(atPath: checkpointPath.path) == false)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
    }

    @Test func truncatedCheckpointQuarantineIsPrivateAndResumeHasNoDuplicateSummary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "private-truncated")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "private-truncated"
        )
        try writer.saveCompactionCheckpoint(checkpoint)
        let committed = try #require(writer.loadSession(id: session.id))

        let checkpointPath = writer.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        let truncatedData = Data(#"{"schemaVersion":1,"sessionID":"private-truncated""#.utf8)
        try truncatedData
            .write(to: checkpointPath, options: .atomic)

        let reader = SessionStore(directory: dir)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try reader.resumeMessages(sessionID: session.id)
        }
        #expect(reader.loadSession(id: session.id) == committed)
        #expect(try reader.resumeMessages(sessionID: session.id) == committed.messages)
        #expect(FileManager.default.fileExists(atPath: checkpointPath.path) == false)

        var directoryInfo = stat()
        #expect(
            Darwin.lstat(
                reader.compactionCheckpointsQuarantineDirectory.path,
                &directoryInfo
            ) == 0
        )
        #expect((directoryInfo.st_mode & mode_t(0o077)) == 0)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: reader.compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: try #require(quarantined.first)) == truncatedData)
    }

    @Test func failedCheckpointCommitKeepsOldRevisionAndCleansTemporaryTail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "failed-checkpoint-commit")
        for index in 1...4 {
            try writer.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-" + String(index)
                ),
                sessionID: session.id
            )
        }
        let source = try #require(writer.loadSession(id: session.id))
        let sourceData = try Data(
            contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
        )
        let result = try await Compactor(keepRecentMessages: 2).compact(messages: source.messages)
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: source.id,
            sourceTranscriptRevision: source.transcriptRevision,
            sourceMessages: source.messages,
            result: result,
            checkpointID: "failed-checkpoint-commit"
        )

        // Keep the checkpoint directory writable while making the parent
        // session directory reject the later atomic session replacement.
        try FileManager.default.createDirectory(
            at: writer.compactionCheckpointsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: writer.compactionCheckpointsDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: writer.sessionsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: writer.sessionsDirectory.path
            )
        }

        #expect(throws: Error.self) {
            try writer.saveCompactionCheckpoint(checkpoint)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: writer.sessionsDirectory.path
        )
        #expect(
            try Data(
                contentsOf: dir.appendingPathComponent("sessions/\(session.id).json")
            ) == sourceData
        )
        #expect(writer.loadSession(id: session.id) == source)
        #expect(try writer.resumeMessages(sessionID: session.id) == source.messages)
        #expect(
            FileManager.default.fileExists(
                atPath: writer.compactionCheckpointsDirectory
                    .appendingPathComponent("\(checkpoint.checkpointID).json").path
            ) == false
        )
        let checkpointFiles = try FileManager.default.contentsOfDirectory(
            at: writer.compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        #expect(checkpointFiles.filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)
    }

    // MARK: - Title auto-generation

    @Test func titleAutoGeneratedFromFirstUserMessage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        #expect(session.title.isEmpty)

        try store.saveMessage(LLMMessage(role: .user, content: "帮我写一个 Swift 的 JSON 解析器"), sessionID: session.id)
        #expect(store.loadSession(id: session.id)?.title == "帮我写一个 Swift 的 JSON 解析器")
    }

    @Test func titleNotSetByAssistantFirstMessage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        try store.saveMessage(LLMMessage(role: .assistant, content: "你好，有什么可以帮你？"), sessionID: session.id)
        #expect(store.loadSession(id: session.id)?.title.isEmpty == true)
    }

    @Test func titleTruncatedTo30Chars() throws {
        let long = String(repeating: "很长的标题内容", count: 10)
        let title = SessionStore.makeTitle(from: long)
        #expect(title.count == 31) // 30 chars + ellipsis
        #expect(title.hasSuffix("…"))

        #expect(SessionStore.makeTitle(from: "   \n  ") == "New Session")
        #expect(SessionStore.makeTitle(from: "短标题") == "短标题")
    }

    // MARK: - List / rename / delete

    @Test func listSessionsSortedByUpdatedAtDesc() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let a = try store.createSession()
        let b = try store.createSession()
        let c = try store.createSession()

        try store.saveMessage(LLMMessage(role: .user, content: "第一句 A"), sessionID: a.id)
        try store.saveMessage(LLMMessage(role: .user, content: "第一句 C"), sessionID: c.id)
        try store.saveMessage(LLMMessage(role: .user, content: "第一句 B"), sessionID: b.id)

        let ids = store.listSessions().map(\.id)
        #expect(ids == [b.id, c.id, a.id])
    }

    @Test func renameSessionUpdatesTitle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        try store.renameSession(id: session.id, title: "改过的标题")

        let loaded = try #require(store.loadSession(id: session.id))
        #expect(loaded.title == "改过的标题")
        #expect(loaded.updatedAt >= session.updatedAt)
        #expect(store.listSessions().count == 1) // still a single file
    }

    @Test func deleteSessionRemovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "内容"), sessionID: session.id)

        let intent = try store.previewDeletion(id: session.id)
            .withFirstConfirmation("I reviewed this exact session")
            .withSecondConfirmation("永久删除")
        try store.deleteSession(id: session.id, intent: intent)
        #expect(store.loadSession(id: session.id) == nil)
        #expect(store.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions/\(session.id).json").path))
        // SessionStore is the confirmed permanent-delete primitive. The
        // user-recoverable path is SessionDeletionService and owns _trash.
        let trash = dir.appendingPathComponent("sessions/_trash", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: trash.path))
    }

    @Test func deleteWithoutIntentFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try store.deleteSession(id: "missing")
        }
    }

    // MARK: - Codable round-trip of LLMMessage attachments

    @Test func llmMessageCodableRoundTripWithAttachments() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        let session = try store.createSession()
        var msg = LLMMessage(role: .user, content: "看图说话")
        msg.images = [.init(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
        msg.audios = [.init(format: "wav", base64Data: "UklGRg==")]
        msg.toolCallID = "call-recovery-1"
        msg.toolCalls = [
            LLMToolCall(
                id: "call-recovery-1",
                name: "file_read",
                rawArguments: "{\"path\":\"/tmp/a\"}",
                arguments: ["path": "/tmp/a"]
            )
        ]
        try store.saveMessage(msg, sessionID: session.id)

        let loaded = try #require(store.loadSession(id: session.id))
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages[0] == msg)
        #expect(loaded.transcriptRevision == 1)
        #expect(loaded.messages[0].images.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(loaded.messages[0].audios.first?.base64Data == "UklGRg==")
        #expect(loaded.messages[0].toolCallID == "call-recovery-1")
        #expect(loaded.messages[0].toolCalls.first?.openAIDict["id"] as? String == "call-recovery-1")
    }

    // MARK: - AJ-29 pinned / unread

    @Test func uiProjectionCannotRollBackAnotherStoresCommittedTranscript() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let uiStore = SessionStore(directory: dir)
        let stale = try uiStore.createSession(title: "synthetic UI")
        let writer = SessionStore(directory: dir)
        try writer.saveMessage(LLMMessage(role: .assistant, content: "synthetic committed reply"),
            sessionID: stale.id)
        let committed = try #require(writer.loadSession(id: stale.id))
        let file = dir.appendingPathComponent("sessions/\(stale.id).json")
        let bytes = try Data(contentsOf: file)

        #expect(try !uiStore.updateSessionUnlessTranscriptIsNewer(stale))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(SessionStore(directory: dir).loadSession(id: stale.id) == committed)
    }

    @Test func uiProjectionAllowsEqualRevisionMetadataChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = SessionStore(directory: dir)
        let initial = try writer.createSession(title: "synthetic metadata")
        var metadata = initial
        metadata.pinned = true
        metadata.unread = true

        #expect(try writer.updateSessionUnlessTranscriptIsNewer(metadata))
        let loaded = try #require(SessionStore(directory: dir).loadSession(id: initial.id))
        #expect(loaded == metadata)
        #expect(loaded.transcriptRevision == initial.transcriptRevision)
        #expect(loaded.messages == initial.messages)
    }

    @Test func explicitUpdateRetainsOlderRevisionRestoreSemantics() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = SessionStore(directory: dir)
        let original = try writer.createSession(title: "synthetic restore")
        try writer.saveMessage(LLMMessage(role: .assistant, content: "synthetic newer reply"),
            sessionID: original.id)
        #expect(try !writer.updateSessionUnlessTranscriptIsNewer(original))

        try writer.updateSession(original)
        #expect(SessionStore(directory: dir).loadSession(id: original.id) == original)
    }

    @Test func pinnedUnreadPersistAcrossStoreInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = SessionStore(directory: dir)
        let session = try writer.createSession(id: "aj29-test", title: "置顶会话")
        var updated = session
        updated.pinned = true
        updated.unread = true
        try writer.updateSession(updated)

        // Fresh store instance reads from disk — proves real persistence.
        let reader = SessionStore(directory: dir)
        let loaded = try #require(reader.loadSession(id: "aj29-test"))
        #expect(loaded.pinned == true)
        #expect(loaded.unread == true)
    }

    @Test func oldPayloadWithoutPinnedUnreadDefaultsToFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧格式 JSON（无 pinned/unread 键）→ 解码回落 false，不崩。
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        let old = """
        {"id":"legacy","title":"旧会话","createdAt":0,"updatedAt":0,"messages":[]}
        """
        try Data(old.utf8).write(
            to: dir.appendingPathComponent("sessions/legacy.json"),
            options: .atomic
        )
        let store = SessionStore(directory: dir)
        let loaded = try #require(store.loadSession(id: "legacy"))
        #expect(loaded.pinned == false)
        #expect(loaded.unread == false)
        #expect(loaded.title == "旧会话")
    }
}

private final class SessionCASOutcomeBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = "pending"
    func set(_ value: String) { mutex.lock(); self.value = value; mutex.unlock() }
    func get() -> String { mutex.lock(); defer { mutex.unlock() }; return value }
}

private struct SessionCASRaceFacts: Sendable {
    let sameLock: Bool
    let didStart: Bool
    let stayedBlocked: Bool
    let mutation: Result<Void, Error>
    let completed: Bool
    let outcome: String?
    let lastContent: String?
    let activeMissing: Bool
}

struct SessionTranscriptCompareAndCommitTests {
    @Test func successfulCommitIsVisibleToAnotherInstanceAndReopen() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let initial = try store.createSession(title: "target", projectID: "project")
        let messages = [LLMMessage(role: .user, content: "source"), LLMMessage(role: .assistant, content: "result")]
        let committed = try store.compareAndCommitTranscript(sessionID: initial.id, projectID: "project",
            expectedRevision: initial.transcriptRevision, expectedMessages: initial.messages,
            replacementMessages: messages)
        #expect(committed.transcriptRevision == initial.transcriptRevision + 1)
        #expect(SessionStore(directory: root).loadSession(id: initial.id) == committed)
        #expect(throws: SessionStoreError.sessionSnapshotConflict(initial.id)) {
            try store.compareAndCommitTranscript(sessionID: initial.id, projectID: "project",
                expectedRevision: initial.transcriptRevision, expectedMessages: initial.messages,
                replacementMessages: [])
        }
    }

    @Test func competingStoreMutationIsObservedInsideTheSharedCommitBoundary() async throws {
        try await race(mutation: "append")
    }
    @Test func archiveMoveCannotRaceACommitIntoRecreatingTheActiveFile() async throws {
        try await race(mutation: "archive")
    }
    @Test func trashMoveCannotRaceACommitIntoRecreatingTheDeletedFile() async throws {
        try await race(mutation: "trash")
    }
    private func race(mutation: String) async throws {
        let root = try await runBlockingTestWork { try makeTempDir() }
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = try await runBlockingTestWork {
            let first = SessionStore(directory: root)
            let second = SessionStore(directory: root)
            let manager = SessionManager(store: second, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")))
            let original = try first.createSession(title: "race", projectID: "project")
            let sameLock = first.persistenceLock === second.persistenceLock
            let started = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            let outcome = SessionCASOutcomeBox()
            first.persistenceLock.lock()
            DispatchQueue.global().async {
                started.signal()
                do {
                    _ = try second.compareAndCommitTranscript(sessionID: original.id, projectID: "project",
                        expectedRevision: original.transcriptRevision, expectedMessages: original.messages,
                        replacementMessages: [LLMMessage(role: .assistant, content: "late")])
                    outcome.set("unexpected commit")
                } catch SessionStoreError.sessionSnapshotConflict { outcome.set("conflict") }
                catch SessionStoreError.sessionNotFound { outcome.set("missing") }
                catch { outcome.set("other error") }
                done.signal()
            }
            let didStart = started.wait(timeout: .now() + 2) == .success
            let stayedBlocked = done.wait(timeout: .now() + 0.05) == .timedOut
            do {
                switch mutation {
                case "archive": try manager.archive(sessionID: original.id)
                case "trash":
                    let deletion = SessionDeletionService(manager: manager)
                    let intent = try deletion.preview(sessionID: original.id)
                        .withFirstConfirmation("test").withSecondConfirmation("test")
                    _ = try deletion.delete(intent)
                default: try first.saveMessage(LLMMessage(role: .user, content: "newer"), sessionID: original.id)
                }
            } catch {
                first.persistenceLock.unlock()
                _ = done.wait(timeout: .now() + 2)
                return SessionCASRaceFacts(sameLock: sameLock, didStart: didStart, stayedBlocked: stayedBlocked,
                    mutation: .failure(error), completed: false, outcome: nil, lastContent: nil, activeMissing: false)
            }
            first.persistenceLock.unlock()
            let completed = done.wait(timeout: .now() + 2) == .success
            let observedOutcome = outcome.get()
            let final = first.loadSession(id: original.id)
            return SessionCASRaceFacts(sameLock: sameLock, didStart: didStart, stayedBlocked: stayedBlocked,
                mutation: .success(()), completed: completed, outcome: observedOutcome,
                lastContent: final?.messages.last?.content, activeMissing: final == nil)
        }
        #expect(facts.sameLock)
        #expect(facts.didStart)
        #expect(facts.stayedBlocked)
        try facts.mutation.get()
        #expect(facts.completed)
        #expect(facts.outcome == (mutation == "append" ? "conflict" : "missing"))
        if mutation == "append" {
            #expect(facts.lastContent == "newer")
        } else {
            #expect(facts.activeMissing)
        }
    }

    @Test func projectChangeAndRealWriteFailureDoNotPublishTheReplacement() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let initial = try store.createSession(title: "write failure", projectID: "project")
        let file = store.sessionsDirectory.appendingPathComponent(initial.id + ".json")
        let before = try Data(contentsOf: file)
        #expect(throws: SessionStoreError.sessionTargetMismatch(initial.id)) {
            try store.compareAndCommitTranscript(sessionID: initial.id, projectID: "wrong",
                expectedRevision: initial.transcriptRevision, expectedMessages: [], replacementMessages: [])
        }
        #expect(chmod(store.sessionsDirectory.path, 0o555) == 0)
        defer { _ = chmod(store.sessionsDirectory.path, 0o700) }
        #expect(throws: (any Error).self) {
            try store.compareAndCommitTranscript(sessionID: initial.id, projectID: "project",
                expectedRevision: initial.transcriptRevision, expectedMessages: [],
                replacementMessages: [LLMMessage(role: .assistant, content: "must not publish")])
        }
        #expect(try Data(contentsOf: file) == before)
    }
}
