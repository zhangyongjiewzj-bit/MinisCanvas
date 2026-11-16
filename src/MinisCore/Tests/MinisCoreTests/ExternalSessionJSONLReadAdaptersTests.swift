import Foundation
import Testing
@testable import MinisCore

@Suite("External JSONL readers use only synthetic explicit roots")
struct ExternalSessionJSONLReadAdaptersTests {
    private static let codexID = "12345678-1234-1234-1234-123456789abc"
    private static let claudeID = "87654321-4321-4321-4321-cba987654321"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-EXT770-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func grant(_ ledger: ExternalSessionAuthorizationLedgerV1,
                              source: ExternalSessionSourceID, profile: ExternalSessionProfileID,
                              target: ExternalSessionReadTargetV1,
                              scopes: Set<ExternalSessionReadScopeV1>) async throws -> ExternalSessionReadGrantV1 {
        try await ledger.issueReadGrant(authorizationID: ExternalSessionAuthorizationID(rawValue: UUID().uuidString),
            sourceID: source, profileID: profile, target: target, scopes: scopes,
            issuedAt: now.addingTimeInterval(-10), lifetime: 100)
    }

    @Test func codexDiscoversReadsAndStopsAfterRevocation() async throws {
        let root = try Self.root("codex")
        let day = root.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl")
        let jsonl = """
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(Self.codexID)","cwd":"/synthetic/project","cli_version":"0.160.0"}}
        {"timestamp":"2026-10-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic hello"}]}}
        {"timestamp":"2026-10-01T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"synthetic hello"}}
        {"timestamp":"2026-10-01T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"synthetic reply"}]}}
        {"timestamp":"2026-10-01T00:00:02Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","content":[{"type":"Text","text":"synthetic reply"}]}}}
        {"timestamp":"2026-10-01T00:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(jsonl.utf8).write(to: file)
        let source = ExternalSessionSourceID(rawValue: "synthetic-codex")
        let profile = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        #expect(adapter.source.kind == .codex)
        #expect(adapter.source.capabilities == [.readMetadata, .readMessages, .status])
        let metadata = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        let list = try await adapter.listThreads(query: ExternalSessionThreadQueryV1(sourceID: source, limit: 10), readGrant: metadata)
        #expect(list.threads.count == 1)
        #expect(list.threads.first?.threadID.rawValue == Self.codexID)
        #expect(list.threads.first?.projectID?.rawValue.hasPrefix("cwd-sha256:") == true)
        let transcript = try await Self.grant(ledger, source: source, profile: profile,
            target: .thread(ExternalSessionThreadID(rawValue: Self.codexID)), scopes: [.messages, .status])
        let request = ExternalSessionReadRequestV1(sourceID: source,
            threadID: ExternalSessionThreadID(rawValue: Self.codexID), limit: 10)
        let page = try await adapter.read(request: request, readGrant: transcript)
        #expect(page.events.map(\.payload.summary) == ["synthetic hello", "synthetic reply"])
        #expect(page.events.allSatisfy { !$0.sourceRef.contains(root.path) })
        let status = try await adapter.status(target: ExternalSessionStatusTargetV1(sourceID: source,
            threadID: ExternalSessionThreadID(rawValue: Self.codexID)), readGrant: transcript)
        #expect(status.threadStatus == .completed)
        await ledger.revoke(sourceID: source, profileID: profile)
        await #expect(throws: ExternalSessionJSONLReadError.grantNotActive) {
            try await adapter.read(request: request, readGrant: transcript)
        }
    }

    @Test func claudeReadsVersionedJSONLAndRejectsWrongSourceBeforeIO() async throws {
        let root = try Self.root("claude")
        let project = root.appendingPathComponent("-synthetic-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("\(Self.claudeID).jsonl")
        let jsonl = """
        {"type":"user","sessionId":"\(Self.claudeID)","cwd":"/synthetic/project","version":"2.1.0","timestamp":"2026-10-01T00:00:00Z","message":{"role":"user","content":"synthetic question"}}
        {"type":"assistant","sessionId":"\(Self.claudeID)","cwd":"/synthetic/project","version":"2.1.0","timestamp":"2026-10-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"synthetic answer"}]}}
        """
        try Data(jsonl.utf8).write(to: file)
        let source = ExternalSessionSourceID(rawValue: "synthetic-claude")
        let profile = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionClaudeCodeReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        #expect(adapter.source.kind == .claudeCode)
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata, .messages])
        let list = try await adapter.listThreads(query: ExternalSessionThreadQueryV1(sourceID: source, limit: 10), readGrant: grant)
        #expect(list.threads.count == 1)
        let page = try await adapter.read(request: ExternalSessionReadRequestV1(sourceID: source,
            threadID: ExternalSessionThreadID(rawValue: Self.claudeID), limit: 10), readGrant: grant)
        #expect(page.events.map(\.payload.summary) == ["synthetic question", "synthetic answer"])
        await #expect(throws: ExternalSessionJSONLReadError.sourceMismatch) {
            try await adapter.listThreads(query: ExternalSessionThreadQueryV1(
                sourceID: ExternalSessionSourceID(rawValue: "other"), limit: 10), readGrant: grant)
        }
    }

    @Test func unsupportedVersionFailsClosed() async throws {
        let root = try Self.root("unsupported")
        let file = root.appendingPathComponent("rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(Self.codexID)\",\"cwd\":\"/synthetic\",\"cli_version\":\"99.0\"}}\n".utf8).write(to: file)
        let source = ExternalSessionSourceID(rawValue: "unsupported-codex")
        let profile = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        await #expect(throws: ExternalSessionJSONLReadError.unsupportedFormat) {
            try await adapter.listThreads(query: ExternalSessionThreadQueryV1(sourceID: source, limit: 10), readGrant: grant)
        }
    }

    @Test func missingRootDoesNotAdvertiseReadCapability() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-EXT770-absent-\(UUID().uuidString)", isDirectory: true)
        let adapter = ExternalSessionCodexRolloutReadAdapter(
            sourceID: ExternalSessionSourceID(rawValue: "absent-codex"),
            profileID: ExternalSessionProfileID(rawValue: "synthetic-profile"),
            hostID: "synthetic-host", rootURL: root,
            authorizationLedger: ExternalSessionAuthorizationLedgerV1())
        #expect(adapter.source.authState == .unavailable)
        #expect(adapter.source.capabilities.isEmpty)
    }

    @Test func projectGrantReadsOnlyMatchingThreadAndLongMessageContinuesByChunk() async throws {
        let root = try Self.root("project-chunks")
        let file = root.appendingPathComponent("rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl")
        let longText = String(repeating: "甲", count: 1_100)
        let jsonl = """
        {"type":"session_meta","payload":{"id":"\(Self.codexID)","cwd":"/synthetic/project","cli_version":"0.160.0"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(longText)"}]}}
        """
        try Data(jsonl.utf8).write(to: file)
        let source = ExternalSessionSourceID(rawValue: "project-codex")
        let profile = ExternalSessionProfileID(rawValue: "project-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        let metadata = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        let list = try await adapter.listThreads(query: ExternalSessionThreadQueryV1(sourceID: source, limit: 10), readGrant: metadata)
        let projectID = try #require(list.threads.first?.projectID)
        let threadID = ExternalSessionThreadID(rawValue: Self.codexID)
        // A sibling with an unsupported format must never be opened by a
        // target-specific project or thread read.
        let sibling = root.appendingPathComponent("rollout-2026-10-01T00-00-01-\(Self.claudeID).jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(Self.claudeID)\",\"cwd\":\"/other\",\"cli_version\":\"99.0\"}}\n".utf8)
            .write(to: sibling)
        #expect(try await adapter.contains(threadID: threadID, projectID: projectID))
        #expect(try await !adapter.contains(threadID: threadID,
            projectID: ExternalSessionProjectID(rawValue: "another-project")))
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .project(projectID), scopes: [.messages])
        var cursor = ExternalSessionCursorV1.beginning
        var collected = ""
        var indices: [UInt32] = []
        for _ in 0..<10 {
            let page = try await adapter.read(request: ExternalSessionReadRequestV1(
                sourceID: source, threadID: threadID, cursor: cursor, limit: 1), readGrant: grant)
            let chunk = try #require(page.messageChunks.first)
            #expect(chunk.text.count <= ExternalSessionMessageChunkV1.maximumCharacters)
            #expect(chunk.text.utf8.count <= ExternalSessionMessageChunkV1.maximumUTF8Bytes)
            collected += chunk.text
            indices.append(chunk.chunkIndex)
            if let next = page.nextCursor { cursor = next } else {
                #expect(chunk.isLastChunk)
                break
            }
        }
        #expect(collected == longText)
        #expect(indices == [0, 1, 2])
        let wrongGrant = try await Self.grant(ledger, source: source, profile: profile,
            target: .project(ExternalSessionProjectID(rawValue: "another-project")), scopes: [.messages])
        await #expect(throws: ExternalSessionJSONLReadError.targetMismatch) {
            try await adapter.read(request: ExternalSessionReadRequestV1(
                sourceID: source, threadID: threadID, limit: 1), readGrant: wrongGrant)
        }
        let projectListGrant = try await Self.grant(ledger, source: source, profile: profile,
            target: .project(projectID), scopes: [.metadata])
        await #expect(throws: ExternalSessionJSONLReadError.unsupportedProjectListing) {
            try await adapter.listThreads(query: ExternalSessionThreadQueryV1(
                sourceID: source, projectID: projectID, limit: 10), readGrant: projectListGrant)
        }
    }

    @Test func replacedOwnedFileCannotCrossProjectOrThreadGrant() async throws {
        let root = try Self.root("replaced-file")
        let file = root.appendingPathComponent("rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl")
        func fixture(id: String, cwd: String, body: String) -> Data {
            Data("""
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"\(cwd)","cli_version":"0.160.0"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"\(body)"}}
            """.utf8)
        }
        try fixture(id: Self.codexID, cwd: "/synthetic/project-a", body: "allowed-body")
            .write(to: file)
        let source = ExternalSessionSourceID(rawValue: "replacement-codex")
        let profile = ExternalSessionProfileID(rawValue: "replacement-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        let sourceGrant = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        let listed = try await adapter.listThreads(query: ExternalSessionThreadQueryV1(
            sourceID: source, limit: 10), readGrant: sourceGrant)
        let projectA = try #require(listed.threads.first?.projectID)
        let projectGrant = try await Self.grant(ledger, source: source, profile: profile,
            target: .project(projectA), scopes: [.messages])
        let threadID = ExternalSessionThreadID(rawValue: Self.codexID)
        let request = ExternalSessionReadRequestV1(sourceID: source, threadID: threadID, limit: 10)
        // Atomic replacement changes the inode after discovery. Neither a
        // different project nor a mismatched header may yield the new body.
        try fixture(id: Self.codexID, cwd: "/synthetic/project-b", body: "forbidden-project-body")
            .write(to: file, options: .atomic)
        await #expect(throws: ExternalSessionJSONLReadError.targetMismatch) {
            try await adapter.read(request: request, readGrant: projectGrant)
        }
        let threadGrant = try await Self.grant(ledger, source: source, profile: profile,
            target: .thread(threadID), scopes: [.messages])
        try fixture(id: Self.claudeID, cwd: "/synthetic/project-a", body: "forbidden-thread-body")
            .write(to: file, options: .atomic)
        await #expect(throws: ExternalSessionJSONLReadError.unknownThread) {
            try await adapter.read(request: request, readGrant: threadGrant)
        }
    }

    @Test func grantExpiryAfterLedgerAwaitStopsBeforeFileRead() async throws {
        final class ClockState: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func time() -> Date {
                lock.lock()
                defer { lock.unlock() }
                calls += 1
                return SelfTime.now.addingTimeInterval(calls >= 4 ? 200 : 0)
            }
        }
        let root = try Self.root("post-await-expiry")
        let clock = ClockState()
        let source = ExternalSessionSourceID(rawValue: "expiring-codex")
        let profile = ExternalSessionProfileID(rawValue: "expiring-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger,
            clock: { clock.time() })
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        await #expect(throws: ExternalSessionJSONLReadError.grantNotActive) {
            try await adapter.listThreads(query: ExternalSessionThreadQueryV1(
                sourceID: source, limit: 10), readGrant: grant)
        }
    }

    @Test func continuationRejectsChangedTranscriptSnapshot() async throws {
        let root = try Self.root("changed-cursor")
        let file = root.appendingPathComponent("rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl")
        func fixture(_ body: String) -> Data {
            Data("""
            {"type":"session_meta","payload":{"id":"\(Self.codexID)","cwd":"/synthetic/cursor","cli_version":"0.160.0"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"\(body)"}}
            """.utf8)
        }
        try fixture(String(repeating: "甲", count: 1_100)).write(to: file)
        let source = ExternalSessionSourceID(rawValue: "changed-cursor-codex")
        let profile = ExternalSessionProfileID(rawValue: "changed-cursor-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        let threadID = ExternalSessionThreadID(rawValue: Self.codexID)
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .thread(threadID), scopes: [.messages])
        let first = try await adapter.read(request: ExternalSessionReadRequestV1(
            sourceID: source, threadID: threadID, limit: 1), readGrant: grant)
        let continuation = try #require(first.nextCursor)
        try fixture(String(repeating: "乙", count: 1_100)).write(to: file, options: .atomic)
        await #expect(throws: ExternalSessionJSONLReadError.invalidCursor) {
            try await adapter.read(request: ExternalSessionReadRequestV1(
                sourceID: source, threadID: threadID, cursor: continuation, limit: 1), readGrant: grant)
        }
    }

    @Test func replacementPhysicalRootCannotReuseRegistration() async throws {
        let root = try Self.root("root-identity")
        let filename = "rollout-2026-10-01T00-00-00-\(Self.codexID).jsonl"
        let fixture = Data("""
        {"type":"session_meta","payload":{"id":"\(Self.codexID)","cwd":"/synthetic/root","cli_version":"0.160.0"}}
        """.utf8)
        try fixture.write(to: root.appendingPathComponent(filename))
        let source = ExternalSessionSourceID(rawValue: "root-identity-codex")
        let profile = ExternalSessionProfileID(rawValue: "root-identity-profile")
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapter = ExternalSessionCodexRolloutReadAdapter(sourceID: source, profileID: profile,
            hostID: "synthetic-host", rootURL: root, authorizationLedger: ledger, clock: { Self.now })
        let grant = try await Self.grant(ledger, source: source, profile: profile,
            target: .source(source), scopes: [.metadata])
        let moved = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture.write(to: root.appendingPathComponent(filename))
        await #expect(throws: ExternalSessionJSONLReadError.unsafeRoot) {
            try await adapter.listThreads(query: ExternalSessionThreadQueryV1(
                sourceID: source, limit: 10), readGrant: grant)
        }
    }
}

private enum SelfTime {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
}
