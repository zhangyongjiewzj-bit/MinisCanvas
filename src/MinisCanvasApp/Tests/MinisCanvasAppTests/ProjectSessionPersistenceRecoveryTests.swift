import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("24C target lineage and backlink recovery")
@MainActor
struct ProjectSessionPersistenceRecoveryTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-session-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("App conversion preserves existing Core fork and task lineage")
    func fullCoreLineageRoundTrips() {
        let rootID = UUID().uuidString
        let parentID = UUID().uuidString
        let core = MinisCore.ChatSession(id: UUID().uuidString, title: "分支任务",
            projectID: "project-1", rootSessionID: rootID, parentSessionID: parentID,
            forkedFromSessionID: parentID, forkedThroughTranscriptRevision: 3,
            forkedThroughMessageID: UUID().uuidString,
            createdByTaskID: "task-1", createdByRunID: "run-1")
        #expect(core.asThread().asPersisted() == core)
    }

    @Test("cross-project task preserves source and backlink without claiming fork ancestry")
    func nonSwitchingTargetUsesCanonicalStore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sourceID = chat.applyNewSession(title: "原会话")
        chat.appendUser("这段来源历史不应复制到新任务。")
        let sourceBefore = try #require(store.loadSession(id: sourceID.uuidString))
        let targetID = UUID().uuidString
        let project = ProjectSessionAuthorizedProject(projectID: "picked-project",
            displayName: "测试项目", workdirReference: "grant:picked-project:revision")
        try chat.createProjectTarget(id: targetID, title: "新任务", sourceID: sourceID.uuidString,
            project: project, directory: root, taskID: "task-1", runID: "run-1")

        #expect(chat.activeSessionID == sourceID)
        let target = try #require(store.loadSession(id: targetID))
        #expect(target.taskSourceSessionID == sourceID.uuidString)
        #expect(target.parentSessionID == nil)
        #expect(target.rootSessionID == targetID)
        #expect(target.forkedFromSessionID == nil)
        #expect(target.projectID == project.projectID)
        #expect(target.workingDirectory == root.path)
        #expect(store.loadSession(id: sourceID.uuidString) == sourceBefore)
        #expect(target.createdByTaskID == "task-1")
        #expect(target.createdByRunID == "run-1")
        #expect(target.messages.isEmpty)
        // An exact replay is idempotent; a different source or directory must
        // never borrow the existing task's provenance.
        try chat.createProjectTarget(id: targetID, title: "新任务", sourceID: sourceID.uuidString,
            project: project, directory: root, taskID: "task-1", runID: "run-1")
        #expect(throws: ProjectSessionAppError.conflictingReplay) {
            try chat.createProjectTarget(id: targetID, title: "新任务", sourceID: targetID,
                project: project, directory: root, taskID: "task-1", runID: "run-1")
        }
        #expect(throws: ProjectSessionAppError.conflictingReplay) {
            try chat.createProjectTarget(id: targetID, title: "新任务", sourceID: sourceID.uuidString,
                project: project, directory: root.appendingPathComponent("other"),
                taskID: "task-1", runID: "run-1")
        }
        try chat.enqueueProjectTaskInstruction("执行任务", targetID: targetID, projectID: project.projectID)
        let oneInstruction = try #require(store.loadSession(id: targetID))
        try chat.enqueueProjectTaskInstruction("执行任务", targetID: targetID, projectID: project.projectID)
        #expect(store.loadSession(id: targetID)?.transcriptRevision == oneInstruction.transcriptRevision)
        #expect(store.loadSession(id: targetID)?.messages.count == 1)
        #expect(throws: ProjectSessionAppError.self) {
            try chat.enqueueProjectTaskInstruction("篡改任务", targetID: targetID, projectID: project.projectID)
        }

        let card = SessionReferenceCard(id: UUID().uuidString,
            sourceSessionID: sourceID.uuidString, targetSessionID: targetID,
            taskID: "task-1", runID: "run-1", projectID: project.projectID,
            projectTitle: project.displayName, title: "新任务", createdAt: Date(), status: .running)
        try chat.appendSourceCard(card)
        #expect(chat.hasSourceCard(card.id, sourceID: sourceID.uuidString))

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: root)))
        #expect(restarted.sessions.contains(where: { $0.id.uuidString == targetID
            && $0.taskSourceSessionID == sourceID.uuidString
            && $0.parentSessionID == nil && $0.rootSessionID == targetID }))
        #expect(restarted.hasSourceCard(card.id, sourceID: sourceID.uuidString))
    }

    @Test("a changed transcript cannot inherit the App-owned source card")
    func cardDigestFencesRecovery() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let card = SessionReferenceCard(id: UUID().uuidString,
            sourceSessionID: sourceID.uuidString, targetSessionID: UUID().uuidString,
            taskID: "task-1", runID: "run-1", projectID: "project-1",
            projectTitle: "项目", title: "任务", createdAt: Date(), status: .running)
        let source = ChatThread(id: sourceID, title: "原会话", messages: [
            ChatMessageUI(role: .assistant, content: "已登记新任务。", sessionReferenceCard: card)
        ])
        try ChatAttachmentPersistence.save(sessions: [source], to: root)
        let records = try ChatAttachmentPersistence.load(from: root)
        let canonical = source.asPersisted()
        let restored = ChatAttachmentPersistence.restoreAttachments(
            from: canonical, records: records[sourceID.uuidString])
        #expect(restored.messages.first?.sessionReferenceCard == card)
        #expect(canonical.messages.first?.content == "已登记新任务。")

        var changed = canonical
        changed.messages = [LLMMessage(role: .assistant, content: "不同的消息")]
        let fenced = ChatAttachmentPersistence.restoreAttachments(
            from: changed, records: records[sourceID.uuidString])
        #expect(fenced.messages.first?.sessionReferenceCard == nil)
    }

    @Test("only an exact current-turn reference may enter the target instruction")
    func capsuleTransferIsBoundedAndExplicit() throws {
        let sourceID = UUID().uuidString
        let chat = ChatStore()
        let source = ParentRuntimeIdentity(sessionID: sourceID,
            conversationID: sourceID, turnID: "turn-handle:1",
            taskID: "task-source", actorID: "app")
        #expect(try chat.currentProjectCapsule(source: source, reference: nil) == nil)
        #expect(throws: ProjectSessionAppError.self) {
            _ = try chat.currentProjectCapsule(source: source, reference: "unapproved-card-id")
        }
        let capsule = ProjectSessionCapsuleSnapshot(sourceMessageID: UUID().uuidString,
            cardID: UUID().uuidString, material: "仅这段资料", digest: "pinned-digest")
        #expect(try ProjectSessionAppHandler.targetInstruction("执行任务", capsule: capsule)
            == "执行任务\n\n用户已批准从本次来源消息转交的资料：\n仅这段资料")
        #expect(throws: ProjectSessionAppError.self) {
            _ = try ProjectSessionAppHandler.targetInstruction(
                String(repeating: "x", count: 32_000), capsule: capsule)
        }
    }
}
