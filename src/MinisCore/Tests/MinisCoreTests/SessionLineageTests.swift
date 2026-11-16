import Foundation
import Testing
@testable import MinisCore

@Suite("H3 SessionStore lineage")
struct SessionLineageTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCore-SessionLineage-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFormalDirectory() throws -> URL {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let url = formal.rootDirectory.appendingPathComponent(
            "session-lineage-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ session: ChatSession, into directory: URL) throws {
        let sessionsDirectory = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(
            to: sessionsDirectory.appendingPathComponent("\(session.id).json"),
            options: .atomic
        )
    }

    @Test
    func legacyPayloadDecodesAsItsOwnRoot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let sessionsDirectory = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let legacy = """
        {"id":"legacy","title":"Legacy","createdAt":0,"updatedAt":0,"messages":[]}
        """
        try Data(legacy.utf8).write(
            to: sessionsDirectory.appendingPathComponent("legacy.json"),
            options: .atomic
        )

        let decoded = try #require(store.loadSession(id: "legacy"))
        #expect(decoded.lineageVersion == ChatSession.currentLineageVersion)
        #expect(decoded.rootSessionID == "legacy")
        #expect(decoded.parentSessionID == nil)
        #expect(decoded.forkedFromSessionID == nil)
        #expect(decoded.forkedThroughTranscriptRevision == nil)
        #expect(decoded.forkedThroughMessageID == nil)
    }

    @Test
    func forkPersistsFrozenBoundaryAndLineageMetadata() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let parent = try store.createSession(
            id: "parent",
            title: "Parent",
            projectID: "project",
            projectName: "Project",
            workingDirectory: "/tmp/project"
        )
        try store.saveMessage(
            LLMMessage(role: .user, content: "one"),
            sessionID: parent.id
        )
        try store.saveMessage(
            LLMMessage(role: .assistant, content: "two"),
            sessionID: parent.id
        )
        let source = try #require(store.loadSession(id: parent.id))

        let child = try store.forkSession(
            from: source.id,
            id: "child",
            title: "Child",
            throughMessageIndex: 1,
            createdByTaskID: "task-1",
            createdByRunID: "run-1"
        )
        #expect(child.messages == [source.messages[0]])
        #expect(child.transcriptRevision == 1)
        #expect(child.rootSessionID == source.rootSessionID)
        #expect(child.parentSessionID == source.id)
        #expect(child.forkedFromSessionID == source.id)
        #expect(child.forkedThroughTranscriptRevision == source.transcriptRevision)
        #expect(
            child.forkedThroughMessageID
                == Compactor.stableMessageID(source.messages[0], transcriptIndex: 0)
        )
        #expect(child.createdByTaskID == "task-1")
        #expect(child.createdByRunID == "run-1")
        #expect(child.projectID == source.projectID)
        #expect(child.workingDirectory == source.workingDirectory)

        try store.saveMessage(
            LLMMessage(role: .user, content: "parent later"),
            sessionID: source.id
        )
        let reader = SessionStore(directory: directory)
        let reloaded = try #require(reader.loadSession(id: child.id))
        #expect(reloaded.messages == [source.messages[0]])
        #expect(reloaded.forkedThroughTranscriptRevision == source.transcriptRevision)
    }

    @Test
    func lineageQueriesReturnStableBreadthFirstResultsAfterRestart() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        _ = try writer.createSession(id: "root")
        _ = try writer.forkSession(from: "root", id: "child-b")
        _ = try writer.forkSession(from: "root", id: "child-a")
        _ = try writer.forkSession(from: "child-a", id: "grandchild")

        let reader = SessionStore(directory: directory)
        #expect(try reader.children(of: "root").map(\.id) == ["child-a", "child-b"])
        #expect(
            try reader.descendants(of: "root").map(\.id)
                == ["child-a", "child-b", "grandchild"]
        )
        #expect(
            try reader.descendants(of: "root", maxDepth: 1).map(\.id)
                == ["child-a", "child-b"]
        )
        #expect(throws: Error.self) {
            try reader.descendants(of: "root", maxDepth: -1)
        }
    }

    @Test
    func managerFactRejectsForeignLineageOwnerOnReentry() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "root")
        let child = try store.forkSession(from: "root", id: "child")
        let manager = SessionManager(
            store: store,
            badgeStore: SessionBadgeStore(directory: directory)
        )
        let current = try #require(manager.managerFact(for: child.id))
        let foreignLineage = SessionLineageIdentity(
            lineageVersion: current.lineageIdentity.lineageVersion,
            rootSessionID: "foreign-root",
            parentSessionID: current.lineageIdentity.parentSessionID,
            forkedFromSessionID: current.lineageIdentity.forkedFromSessionID,
            forkedThroughTranscriptRevision:
                current.lineageIdentity.forkedThroughTranscriptRevision,
            forkedThroughMessageID: current.lineageIdentity.forkedThroughMessageID
        )
        let stale = SessionManagerFact(
            sessionID: child.id,
            transcriptRevision: current.transcriptRevision,
            lineageIdentity: foreignLineage
        )

        #expect(stale.lineageOwner == "foreign-root")
        #expect(stale.stableID != current.stableID)
        #expect(throws: SessionManagerError.staleManagerFact(expected: stale, actual: current)) {
            try manager.requireCurrent(stale)
        }
        #expect(try manager.requireCurrent(current).lineageIdentity == child.lineageIdentity)
    }

    @Test
    func registryRebindKeepsChildSessionIdentityExact() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "root")
        let child = try store.forkSession(from: "root", id: "child")
        let registry = LLMSessionRegistry()
        let first = registry.register(
            providerID: "provider-a",
            sessionID: child.id,
            sessionToken: "old-token"
        )
        let rebound = registry.register(
            providerID: "provider-a",
            sessionID: child.id,
            sessionToken: "new-token"
        )

        #expect(first.stableID != rebound.stableID)
        #expect(!registry.accepts(first))
        #expect(registry.accepts(rebound))
        #expect(registry.isActive(providerID: "provider-a", sessionID: child.id))
    }

    @Test
    func badgeProjectionRejectsForeignOwnerAndLateTerminalAfterRestart() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let badges = SessionBadgeStore(directory: directory)
        let firstTime = Date()
        let ownerA = SessionBadgeStore.SessionIdentity(
            sessionID: "child",
            turnID: 1,
            taskID: "task-a",
            providerID: "provider-a",
            lineageOwner: "root-a",
            transcriptRevision: 1
        )
        let ownerB = SessionBadgeStore.SessionIdentity(
            sessionID: "child",
            turnID: 1,
            taskID: "task-b",
            providerID: "provider-b",
            lineageOwner: "root-b",
            transcriptRevision: 1
        )
        #expect(
            badges.project(
                identity: ownerA,
                status: .running,
                updatedAt: firstTime
            ) != nil
        )
        let newerRevision = SessionBadgeStore.SessionIdentity(
            sessionID: "child",
            turnID: 1,
            taskID: "task-a",
            providerID: "provider-a",
            lineageOwner: "root-a",
            transcriptRevision: 2
        )
        #expect(
            badges.project(
                identity: newerRevision,
                status: .idle,
                updatedAt: firstTime.addingTimeInterval(0.5)
            ) != nil
        )
        #expect(
            badges.project(
                identity: ownerA,
                status: .failed,
                updatedAt: firstTime.addingTimeInterval(1)
            ) == nil
        )
        #expect(
            badges.project(
                identity: ownerB,
                status: .failed,
                updatedAt: firstTime.addingTimeInterval(1)
            ) == nil
        )

        let restarted = SessionBadgeStore(directory: directory)
        #expect(restarted.snapshot(for: "child")?.identity == newerRevision)
        restarted.reset(for: "child")
        let reloadedAfterReset = SessionBadgeStore(directory: directory)
        #expect(
            reloadedAfterReset.project(
                identity: ownerA,
                status: .failed,
                updatedAt: firstTime.addingTimeInterval(2)
            ) == nil
        )
        let freshTime = Date().addingTimeInterval(1)
        #expect(
            reloadedAfterReset.project(
                identity: ownerB,
                status: .idle,
                updatedAt: freshTime
            ) != nil
        )
        #expect(SessionBadgeStore(directory: directory).snapshot(for: "child")?.identity == ownerB)
    }

    @Test
    func corruptPersistedLineageFailsClosed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "root")
        let child = try store.forkSession(from: "root", id: "child")

        var missingParent = child
        missingParent.parentSessionID = "missing"
        missingParent.forkedFromSessionID = "missing"
        #expect(throws: Error.self) {
            try store.updateSession(missingParent)
        }

        var selfParent = child
        selfParent.parentSessionID = child.id
        selfParent.forkedFromSessionID = child.id
        #expect(throws: Error.self) {
            try store.updateSession(selfParent)
        }

        var wrongRoot = child
        wrongRoot.rootSessionID = "foreign-root"
        #expect(throws: Error.self) {
            try store.updateSession(wrongRoot)
        }

        var cycleA = child
        cycleA.parentSessionID = child.id
        cycleA.forkedFromSessionID = child.id
        try write(cycleA, into: directory)
        #expect(store.loadSession(id: child.id) == nil)
    }

    @Test
    func indirectLineageCycleCannotBeWrittenOrConsumedAfterRestart() throws {
        let directory = try makeFormalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try writer.createSession(id: "root", projectID: "project", workingDirectory: project.path)
        let a = try writer.forkSession(from: "root", id: "a")
        _ = try writer.forkSession(from: "a", id: "b")
        _ = try writer.forkSession(from: "b", id: "c")
        let sessionURL = directory.appendingPathComponent("sessions/a.json")
        let before = try Data(contentsOf: sessionURL)

        var cyclic = a
        cyclic.parentSessionID = "c"
        cyclic.forkedFromSessionID = "c"
        #expect(throws: Error.self) { try writer.updateSession(cyclic) }
        #expect(try Data(contentsOf: sessionURL) == before)

        // A parseable on-disk mutation models an old or external writer. The
        // fresh canonical reader must reject the entire A -> C -> B -> A chain.
        try write(cyclic, into: directory)
        let reader = SessionStore(directory: directory)
        #expect(reader.loadSession(id: "root") != nil)
        for id in ["a", "b", "c"] {
            #expect(reader.loadSession(id: id) == nil)
        }
        #expect(reader.listSessions().map(\.id) == ["root"])
        #expect(throws: Error.self) { try reader.descendants(of: "root") }
        #expect(SessionManager(store: reader, badgeStore: SessionBadgeStore(directory: directory))
            .managerFact(for: "b") == nil)
    }

    @Test
    func foreignProjectInLineageCannotBeWrittenOrConsumedAfterRestart() throws {
        let directory = try makeFormalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionStore(directory: directory)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try writer.createSession(id: "root", projectID: "project", workingDirectory: project.path)
        let child = try writer.forkSession(from: "root", id: "child")
        _ = try writer.forkSession(from: "child", id: "grandchild")
        let sessionURL = directory.appendingPathComponent("sessions/child.json")
        let before = try Data(contentsOf: sessionURL)

        var foreign = child
        foreign.projectID = "other-project"
        #expect(throws: Error.self) { try writer.updateSession(foreign) }
        #expect(try Data(contentsOf: sessionURL) == before)

        try write(foreign, into: directory)
        let reader = SessionStore(directory: directory)
        #expect(reader.loadSession(id: "root") != nil)
        #expect(reader.loadSession(id: "child") == nil)
        #expect(reader.loadSession(id: "grandchild") == nil)
        #expect(reader.listSessions().map(\.id) == ["root"])
        #expect(throws: Error.self) { try reader.descendants(of: "root") }
        #expect(SessionManager(store: reader, badgeStore: SessionBadgeStore(directory: directory))
            .managerFact(for: "grandchild") == nil)
    }

    @Test
    func compactionCheckpointCarriesSessionLineage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        _ = try store.createSession(id: "root")
        for index in 1...3 {
            try store.saveMessage(
                LLMMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "root-\(index)"
                ),
                sessionID: "root"
            )
        }
        _ = try store.forkSession(from: "root", id: "child", throughMessageIndex: 2)
        try store.saveMessage(
            LLMMessage(role: .user, content: "child-tail"),
            sessionID: "child"
        )

        let checkpoint = try #require(
            await store.compactSession(
                sessionID: "child",
                using: Compactor(keepRecentMessages: 1)
            )
        )
        let child = try #require(store.loadSession(id: "child"))
        #expect(checkpoint.lineage == child.lineageIdentity)
        #expect(checkpoint.hasValidDigest)
        #expect(try store.loadLatestCompactionCheckpoint(sessionID: "child") == checkpoint)
    }
}
