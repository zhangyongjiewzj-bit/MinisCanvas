import Foundation
import CanvasCore
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("SESSION-08/18 分组恢复与精准删除消费者")
@MainActor
struct Session521GroupAndDeletionConsumerTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session521-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("有效目录中悬空的活动成员归零，只改目标 membership 并跨重挂载可见")
    func orphanMembershipRepairsOnlyItsCanonicalRecord() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "session521.groups.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let survivingGroup = ChatStore.ChatGroup(name: "保留组 B")
        let deletedGroupID = UUID()
        defaults.set(try JSONEncoder().encode([survivingGroup]), forKey: "chat.userGroups")
        let store = SessionStore(directory: directory)
        var orphan = try store.createSession(title: "旧组 A 的活动会话", projectID: "owned-project")
        orphan.groupID = deletedGroupID.uuidString
        orphan.messages = [
            LLMMessage(role: .assistant, content: "owned system"),
            LLMMessage(role: .user, content: "owned message", images: [
                .init(mimeType: "image/png", data: Data([1, 2, 3]))
            ], audios: [.init(format: "wav", base64Data: "AQID")]),
            LLMMessage(role: .tool, content: "owned result", toolCallID: "owned-call")
        ]
        orphan.transcriptRevision = 7
        try store.updateSession(orphan)
        var keeper = try store.createSession(title: "保留组 B 的会话")
        // UUID spelling alone must not invalidate a known membership.
        keeper.groupID = survivingGroup.id.uuidString.lowercased()
        try store.updateSession(keeper)
        let keeperURL = store.sessionsDirectory.appendingPathComponent("\(keeper.id).json")
        let keeperBytes = try Data(contentsOf: keeperURL)

        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        var expected = orphan
        expected.groupID = nil
        #expect(store.loadSession(id: orphan.id) == expected)
        #expect(store.loadSession(id: keeper.id) == keeper)
        #expect(try Data(contentsOf: keeperURL) == keeperBytes)
        let orphanID = try #require(UUID(uuidString: orphan.id))
        let restored = try #require(chat.sessions.first { $0.id == orphanID })
        #expect(restored.groupID == nil)
        let projectGroup = try #require(chat.sessionGroups.first { $0.kind == .project("owned-project") })
        #expect(projectGroup.items.map(\.session.id) == [orphanID])
        let customGroup = try #require(chat.sessionGroups.first { $0.kind == .custom(survivingGroup.id) })
        #expect(customGroup.items.map(\.session.id.uuidString) == [keeper.id])
        let repairedURL = store.sessionsDirectory.appendingPathComponent("\(orphan.id).json")
        let repairedBytes = try Data(contentsOf: repairedURL)
        let reopened = ChatStore(preferencesDefaults: defaults)
        #expect(reopened.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        #expect(reopened.sessionGroups.flatMap(\.items).filter { $0.session.id == orphanID }.count == 1)
        #expect(try Data(contentsOf: repairedURL) == repairedBytes)
        #expect(try Data(contentsOf: keeperURL) == keeperBytes)
    }

    @Test("快照后同 canonical writer 的新正文与成员改派不会被分组修复覆盖", arguments: [false, true])
    func groupRepairPreservesInterveningCanonicalWrites(reassigned: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let writer = SessionStore(directory: directory.appendingPathComponent("."))
        let removedGroupID = UUID()
        let currentGroupID = UUID()
        var initial = try store.createSession(title: "owned initial")
        initial.groupID = removedGroupID.uuidString
        try store.updateSession(initial)
        // This is exactly the old App list snapshot, before the separate writer.
        let snapshot = try #require(store.listSessions().first { $0.id == initial.id })
        let observedGroupID = try #require(snapshot.groupID)
        let appended = LLMMessage(role: .assistant, content: "owned latest payload",
                                  images: [.init(mimeType: "image/png", data: Data([5, 2, 1]))],
                                  audios: [.init(format: "wav", base64Data: "BQIB")],
                                  toolCalls: [.init(id: "owned-tool", name: "owned-function",
                                                   rawArguments: "{}", arguments: [:])])
        // Deterministic ordering, with actual supported writes and no time race.
        try writer.saveMessage(appended, sessionID: snapshot.id)
        try writer.renameSession(id: snapshot.id, title: "owned newer title")
        var latest = try #require(writer.loadSession(id: snapshot.id))
        latest.pinned = true
        latest.modelID = "owned-new-model"
        if reassigned { latest.groupID = currentGroupID.uuidString }
        try writer.updateSession(latest)
        let canonicalLatest = try #require(writer.loadSession(id: snapshot.id))
        #expect(canonicalLatest.messages == [appended])
        #expect(canonicalLatest.transcriptRevision > snapshot.transcriptRevision)
        #expect(canonicalLatest.title != snapshot.title)
        let url = store.sessionsDirectory.appendingPathComponent("\(snapshot.id).json")
        let latestBytes = try Data(contentsOf: url)

        let repaired = try store.clearOrphanedGroupMembership(
            sessionID: snapshot.id,
            expectedGroupID: observedGroupID,
            knownGroupIDs: [currentGroupID]
        )
        var expected = canonicalLatest
        if !reassigned { expected.groupID = nil }
        // Whole canonical equality guards every field, including all media/tool
        // payload, revision, timestamps, model, pin and the latest membership.
        #expect(repaired == expected)
        #expect(store.loadSession(id: snapshot.id) == expected)
        #expect(writer.loadSession(id: snapshot.id) == expected)
        if reassigned { #expect(try Data(contentsOf: url) == latestBytes) }
        let repairedBytes = try Data(contentsOf: url)
        let repeated = try store.clearOrphanedGroupMembership(
            sessionID: snapshot.id,
            expectedGroupID: expected.groupID ?? observedGroupID,
            knownGroupIDs: [currentGroupID]
        )
        #expect(repeated == expected)
        #expect(try Data(contentsOf: url) == repairedBytes)
        let reopened = SessionStore(directory: directory)
        #expect(reopened.loadSession(id: snapshot.id) == expected)
    }

    @Test("锁内分组修复在写入和 no-op 前拒绝错 ID 与未来或损坏 lineage", arguments: [
        "wrongID-write", "wrongID-noop", "future-write", "future-noop", "invalid-noop"
    ])
    func groupRepairRejectsInvalidCanonicalIdentity(scenario: String) throws {
        // Retain this owned fixture; rejection must not delete/quarantine files.
        let directory = try root()
        let store = SessionStore(directory: directory)
        let requested = try store.createSession(title: "owned requested")
        let foreign = try store.createSession(title: "owned foreign")
        let knownGroupID = UUID()
        let absentGroupID = UUID()
        let noOp = scenario.hasSuffix("noop")
        var malformed = scenario.hasPrefix("wrongID") ? foreign : requested
        malformed.groupID = (noOp ? knownGroupID : absentGroupID).uuidString
        let expectedError: SessionStoreError
        if scenario.hasPrefix("wrongID") {
            expectedError = .sessionTargetMismatch(requested.id)
        } else {
            expectedError = .invalidSessionLineage(requested.id)
            if scenario.hasPrefix("future") {
                malformed.lineageVersion = MinisCore.ChatSession.currentLineageVersion + 1
            } else {
                malformed.rootSessionID = foreign.id
            }
        }
        let requestedURL = store.sessionsDirectory.appendingPathComponent("\(requested.id).json")
        let foreignURL = store.sessionsDirectory.appendingPathComponent("\(foreign.id).json")
        let foreignBytes = try Data(contentsOf: foreignURL)
        let malformedBytes = try JSONEncoder().encode(malformed)
        // Synthetic filename/payload discrepancy or invalid canonical metadata.
        try malformedBytes.write(to: requestedURL, options: .atomic)
        let filenamesBefore = try FileManager.default.contentsOfDirectory(atPath: store.sessionsDirectory.path).sorted()
        let observedGroupID = try #require(malformed.groupID)
        #expect(throws: expectedError) {
            try store.clearOrphanedGroupMembership(
                sessionID: requested.id,
                expectedGroupID: observedGroupID,
                knownGroupIDs: [knownGroupID]
            )
        }
        #expect(try Data(contentsOf: requestedURL) == malformedBytes)
        #expect(try Data(contentsOf: foreignURL) == foreignBytes)
        #expect(store.loadSession(id: foreign.id) == foreign)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.sessionsDirectory.path).sorted() == filenamesBefore)
    }

    @Test("未知目录保留原成员字段与磁盘字节，仍显示活动会话", arguments: [false, true])
    func unavailableCatalogDoesNotRewriteOrHideMembers(corrupt: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "session521.unknown.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalogBytes = Data("not a group catalog".utf8)
        if corrupt { defaults.set(catalogBytes, forKey: "chat.userGroups") }
        let store = SessionStore(directory: directory)
        var session = try store.createSession(title: "目录未知的会话")
        let groupID = UUID()
        session.groupID = groupID.uuidString
        try store.updateSession(session)
        let url = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let before = try Data(contentsOf: url)
        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        let id = try #require(UUID(uuidString: session.id))
        let restored = try #require(chat.sessions.first { $0.id == id })
        #expect(restored.groupID == groupID)
        #expect(chat.sessionGroups.flatMap(\.items).filter { $0.session.id == id }.count == 1)
        #expect(store.loadSession(id: session.id) == session)
        #expect(try Data(contentsOf: url) == before)
        #expect(defaults.data(forKey: "chat.userGroups") == (corrupt ? catalogBytes : nil))
    }

    @Test("A 改名、成员移到 B、删除 A 后重挂载只解除 A 的成员")
    func groupMoveAndDeletionPersistIndependently() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "session521.move.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(directory: directory)
        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        let firstID = try #require(chat.activeSessionID)
        chat.appendUser("owned first")
        let secondID = chat.applyNewSession(title: "owned second")
        let a = try #require(chat.createGroup(named: "A"))
        let b = try #require(chat.createGroup(named: "B"))
        chat.moveSession(firstID, toGroup: a.id)
        chat.moveSession(secondID, toGroup: a.id)
        chat.renameGroup(id: a.id, to: "已改名 A")
        chat.renameGroup(id: a.id, to: " \n ")
        #expect(chat.groups.first { $0.id == a.id }?.name == "已改名 A")
        chat.moveSession(secondID, toGroup: b.id)
        let movedURL = store.sessionsDirectory.appendingPathComponent("\(secondID.uuidString).json")
        let movedBytes = try Data(contentsOf: movedURL)
        chat.deleteGroup(id: a.id)
        let reopened = ChatStore(preferencesDefaults: defaults)
        #expect(reopened.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        #expect(reopened.groups.map(\.id) == [b.id])
        let first = try #require(reopened.sessions.first { $0.id == firstID })
        let second = try #require(reopened.sessions.first { $0.id == secondID })
        #expect(first.groupID == nil)
        #expect(second.groupID == b.id)
        let members = try #require(reopened.sessionGroups.first { $0.kind == .custom(b.id) })
        #expect(members.items.map(\.session.id) == [secondID])
        #expect(reopened.sessionGroups.flatMap(\.items).filter { $0.session.id == firstID }.count == 1)
        #expect(try Data(contentsOf: movedURL) == movedBytes)
    }

    @Test("精准删除不改其它会话与真实项目、记忆、画布存储消费者")
    func exactDeletionPreservesForeignDomainConsumers() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "session521.delete.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(directory: directory)
        let doomed = try store.createSession(title: "owned doomed")
        let projectDirectory = directory.appendingPathComponent("owned-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let registry = try ProjectSessionGrantRegistry(directory: directory)
        let projectID = try registry.registerNativeSelection(projectDirectory, displayName: "owned project")
        let project = try registry.resolve(id: projectID)
        let keeper = try store.createSession(title: "owned keeper", projectID: projectID,
                                            projectName: "owned project", workingDirectory: projectDirectory.path)
        let memory = MemoryStore(directory: directory)
        let doomedFact = try memory.addFact("owned retained fact", sourceSessionID: doomed.id)
        let keeperFact = try memory.addFact("owned sibling fact", sourceSessionID: keeper.id)
        let drafts = DraftStore(directory: directory)
        let node = CanvasNode(type: "text", title: "owned canvas node")
        let draft = CanvasDraft(graph: NodeGraph(nodes: [node]), savedAt: Date(timeIntervalSince1970: 521))
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let urls = [
            store.sessionsDirectory.appendingPathComponent("\(keeper.id).json"),
            directory.appendingPathComponent("project-session-grants-v1.json"),
            memory.fileURL,
            drafts.draftsDirectory.appendingPathComponent("canvas.json")
        ]
        let before = try urls.map { try Data(contentsOf: $0) }
        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: directory)))
        let doomedID = try #require(UUID(uuidString: doomed.id))
        let keeperID = try #require(UUID(uuidString: keeper.id))
        #expect(chat.applySwitchSession(id: keeperID))
        chat.draftText = "owned keeper draft"
        let preview = try chat.previewCurrentDeletion(id: doomedID)
        #expect(!preview.archived)
        #expect(preview.intent.affectedCount == 1)
        #expect(preview.intent.targetID == doomed.id)
        #expect(preview.intent.scopeID == "session:\(doomed.id):active")
        #expect(preview.intent.reversible)
        let intent = preview.intent.withFirstConfirmation("已核对精准预览")
            .withSecondConfirmation("移入回收站")
        let receipt = try chat.deleteSession(id: doomedID, intent: intent)
        #expect(store.loadSession(id: doomed.id) == nil)
        #expect(store.loadSession(id: keeper.id) == keeper)
        #expect(chat.sessions.map(\.id) == [keeperID])
        #expect(chat.activeSessionID == keeperID)
        #expect(chat.draftText == "owned keeper draft")
        let trashURL = store.sessionsDirectory.appendingPathComponent("_trash")
            .appendingPathComponent("\(receipt.operationID.uuidString).json")
        let moved = try JSONDecoder().decode(MinisCore.ChatSession.self, from: Data(contentsOf: trashURL))
        #expect(moved == doomed)
        #expect(try urls.map { try Data(contentsOf: $0) } == before)
        let reopenedProjects = try ProjectSessionGrantRegistry(directory: directory)
        #expect(try reopenedProjects.resolve(id: projectID) == project)
        #expect(try reopenedProjects.directory(for: project) == projectDirectory.resolvingSymlinksInPath().standardizedFileURL)
        let facts = try MemoryStore(directory: directory).loadFacts()
        #expect(Set(facts.map(\.id)) == Set([doomedFact.id, keeperFact.id]))
        #expect(facts.first { $0.id == doomedFact.id } == doomedFact)
        #expect(facts.first { $0.id == keeperFact.id } == keeperFact)
        let payload = try #require(DraftStore(directory: directory).load(key: DraftStore.canvasKey))
        #expect(try JSONDecoder().decode(CanvasDraft.self, from: payload) == draft)
        let restoredCanvas = CanvasStore(
            videoTaskStore: VideoTaskStore(directory: directory.appendingPathComponent("owned-video")),
            artifactStore: ArtifactStore(directory: directory.appendingPathComponent("owned-artifacts")),
            preferencesDefaults: defaults
        )
        restoredCanvas.attachDraftStore(DraftStore(directory: directory))
        let recoverable = try #require(restoredCanvas.recoverableCanvasDraft())
        #expect(recoverable == draft)
        #expect(restoredCanvas.restoreCanvas(from: recoverable))
        #expect(restoredCanvas.graph.nodes.map(\.id) == [node.id])
        let restoredNode = try #require(restoredCanvas.graph.node(id: node.id))
        #expect(restoredNode.title == node.title)
        #expect(try urls.map { try Data(contentsOf: $0) } == before)
    }
}
