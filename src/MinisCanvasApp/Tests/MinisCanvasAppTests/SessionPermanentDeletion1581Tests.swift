import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Session permanent deletion 1581")
@MainActor
struct SessionPermanentDeletion1581Tests {
    @Test("wrong phrase and changed target preserve bytes; exact fresh intent deletes only its target")
    func irreversibleUIConsumerUsesCoreGate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-permanent-1581-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("合成目标会话")
        chat.newSession()
        let survivorID = try #require(chat.activeSessionID)
        chat.appendUser("合成保留会话")
        let targetURL = store.sessionsDirectory.appendingPathComponent(
            "\(targetID.uuidString).json"
        )
        let survivorURL = store.sessionsDirectory.appendingPathComponent(
            "\(survivorID.uuidString).json"
        )
        let survivorBefore = try Data(contentsOf: survivorURL)

        let ordinary = try chat.previewCurrentDeletion(id: targetID).intent
        #expect(ordinary.reversible)
        #expect(ordinary.operationType == .delete)
        #expect(throws: DeletionGateError.invalidIntent) {
            try chat.permanentlyDeleteSession(
                id: targetID,
                intent: ordinary.withFirstConfirmation("确认")
                    .withSecondConfirmation("移入回收站")
            )
        }

        let stale = try chat.previewPermanentDeletion(id: targetID)
        #expect(stale.operationType == .permanentDelete)
        #expect(!stale.reversible)
        let wrong = stale.withFirstConfirmation("已核对")
            .withSecondConfirmation("PERMANENT DELETE")
        #expect(throws: DeletionGateError.irreversibleRequiresPhrase) {
            try chat.permanentlyDeleteSession(id: targetID, intent: wrong)
        }
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(chat.sessions.contains { $0.id == targetID })

        chat.renameSession(id: targetID, title: "目标状态已变化")
        let staleConfirmed = stale.withFirstConfirmation("已核对")
            .withSecondConfirmation("永久删除")
        #expect(throws: DeletionGateError.targetChanged) {
            try chat.permanentlyDeleteSession(id: targetID, intent: staleConfirmed)
        }
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        let survivorAfterStale = try Data(contentsOf: survivorURL)
        #expect(survivorAfterStale == survivorBefore)

        let fresh = try chat.previewPermanentDeletion(id: targetID)
        let confirmed = fresh.withFirstConfirmation("已核对目标与影响")
            .withSecondConfirmation("永久删除")
        let receipt = try chat.permanentlyDeleteSession(id: targetID, intent: confirmed)
        #expect(receipt.targetID == targetID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        #expect(chat.sessions.contains { $0.id == targetID } == false)
        let survivorAfterDelete = try Data(contentsOf: survivorURL)
        #expect(survivorAfterDelete == survivorBefore)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try chat.permanentlyDeleteSession(id: targetID, intent: confirmed)
        }
    }

    @Test("permanent deletion retires only the target's attachment shard and legacy record")
    func terminalDeletionRetiresOwnedAttachmentMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-permanent-attachments-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let target = ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: "合成目标", attachments: [
                ChatAttachment(kind: .text, fileName: "target.txt", fileType: .text, data: Data("目标附件".utf8))
            ])
        ])
        let sibling = ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: "合成相邻会话", attachments: [
                ChatAttachment(kind: .text, fileName: "sibling.txt", fileType: .text, data: Data("相邻附件".utf8))
            ])
        ])
        try store.updateSession(target.asPersisted())
        try store.updateSession(sibling.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [target, sibling], to: root)
        let legacy = ChatAttachmentPersistence.url(in: root)
        let legacyBefore = try Data(contentsOf: legacy)
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root)))
        chat.renameSession(id: target.id, title: "已有附件的合成目标")
        let targetShard = ChatAttachmentPersistence.sessionSidecarURL(for: target.id, in: root)
        let siblingShard = ChatAttachmentPersistence.sessionSidecarURL(for: sibling.id, in: root)
        let targetBefore = try Data(contentsOf: targetShard)
        let siblingBefore = try Data(contentsOf: siblingShard)

        let reversible = try chat.previewCurrentDeletion(id: target.id).intent
            .withFirstConfirmation("已核对目标")
            .withSecondConfirmation("移入回收站")
        let trashed = try chat.deleteSession(id: target.id, intent: reversible)
        #expect(try Data(contentsOf: targetShard) == targetBefore)
        #expect(try Data(contentsOf: legacy) == legacyBefore)
        try #require(chat.restoreTrashedSession(trashed))

        let confirmed = try chat.previewPermanentDeletion(id: target.id)
            .withFirstConfirmation("已核对目标与影响")
            .withSecondConfirmation("永久删除")
        _ = try chat.permanentlyDeleteSession(id: target.id, intent: confirmed)
        #expect(!FileManager.default.fileExists(atPath: targetShard.path))
        #expect(try ChatAttachmentPersistence.load(forSessionID: target.id.uuidString, from: root) == nil)
        #expect(try ChatAttachmentPersistence.load(from: root) == [
            sibling.id.uuidString: ChatAttachmentPersistence.records(for: sibling).messages
        ])
        #expect(try Data(contentsOf: siblingShard) == siblingBefore)
    }

    @Test("permanent deletion clears owned checkpoint conversations and preserves file recovery")
    func irreversibleDeleteClearsOnlyOwnedCheckpointConversations() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "session-permanent-checkpoint-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root)))
        chat.newSession()
        let parentUUID = try #require(chat.activeSessionID)
        let parentID = parentUUID.uuidString
        chat.newSession()
        let unrelatedID = try #require(chat.activeSessionID).uuidString
        let taskLedger = root.appendingPathComponent("agent-tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: taskLedger)
        chat.attachAgentTaskStore(tasks)
        let task = try tasks.enqueue(taskID: "synthetic-task", parentID: parentID,
            providerID: "offline", modelID: "test", parentContextSnapshotID: "synthetic-parent")
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "synthetic-run")
        let executionID = "synthetic-execution"
        let child = try store.forkSession(
            from: parentID, id: "\(parentID):child:\(executionID)", throughMessageIndex: 0,
            createdByTaskID: task.taskID, createdByRunID: run.runID
        )
        let attemptID = try #require(tasks.canonicalAttemptID(runID: run.runID))
        let locator = ChildTranscriptLocator(childSessionID: child.id, parentSessionID: parentID,
            taskID: task.taskID, parentID: task.parentID, runID: run.runID, attemptID: attemptID,
            childExecutionID: executionID, parentContextSnapshotID: task.parentContextSnapshotID)
        _ = try tasks.bindChildTranscript(locator)
        #expect(throws: SessionDeletionError.self) { try chat.previewPermanentDeletion(id: parentUUID) }
        _ = try tasks.settleChildResult(ChildResultEnvelope(
            taskID: task.taskID, runID: run.runID, attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: executionID,
            outcome: .succeeded, outputDigest: "synthetic-digest", idempotencyKey: "synthetic-result",
            agentType: "codex", childTranscriptLocator: locator
        ))
        chat.attachAgentTaskStore(try AgentTaskStore(persistenceURL: taskLedger))
        let checkpointDirectory = root.appendingPathComponent("file-checkpoints", isDirectory: true)
        let checkpoints = try FileCheckpointStore(directory: checkpointDirectory, allowedRoots: [root])
        let file = root.appendingPathComponent("synthetic.txt")
        let before = Data("合成文件修改前".utf8)
        let after = Data("合成文件修改后".utf8)
        let conversation = Data("合成对话快照".utf8)
        try before.write(to: file)
        let parentCheckpoint = try checkpoints.begin(
            path: file, sessionID: parentID, operation: .edit, expectedAfter: after, conversation: conversation
        )
        let childCheckpoint = try checkpoints.begin(
            path: file, sessionID: child.id, operation: .edit, expectedAfter: after,
            conversation: conversation, parentSessionID: parentID
        )
        let fileOnlyCheckpoint = try checkpoints.begin(
            path: file, sessionID: parentID, operation: .edit, expectedAfter: after
        )
        let unrelatedCheckpoint = try checkpoints.begin(
            path: file, sessionID: unrelatedID, operation: .edit, expectedAfter: after, conversation: conversation
        )
        try after.write(to: file)
        for id in [parentCheckpoint, childCheckpoint, fileOnlyCheckpoint, unrelatedCheckpoint] {
            try checkpoints.commit(id)
        }
        func checkpointBytes(_ id: UUID) throws -> Data {
            try Data(contentsOf: checkpointDirectory.appendingPathComponent("\(id.uuidString).json"))
        }
        let fileOnlyBefore = try checkpointBytes(fileOnlyCheckpoint)
        let unrelatedBefore = try checkpointBytes(unrelatedCheckpoint)
        let preview = try chat.previewPermanentDeletion(id: parentUUID)
        #expect(preview.affectedCount == 2)
        #expect(preview.impactSummary.contains("对话快照"))
        let intent = preview.withFirstConfirmation("已核对目标与影响")
            .withSecondConfirmation("永久删除")
        let receipt = try chat.permanentlyDeleteSession(id: parentUUID, intent: intent)

        #expect(receipt.targetID == parentID)
        #expect(!FileManager.default.fileExists(atPath: store.sessionsDirectory.appendingPathComponent("\(child.id).json").path))
        for id in [parentCheckpoint, childCheckpoint] {
            let record = try JSONDecoder().decode(FileCheckpointStore.Record.self, from: checkpointBytes(id))
            #expect(record.conversation == nil)
            #expect(record.before == before)
        }
        #expect(try checkpointBytes(fileOnlyCheckpoint) == fileOnlyBefore)
        #expect(try checkpointBytes(unrelatedCheckpoint) == unrelatedBefore)
        #expect(try Data(contentsOf: file) == after)
    }

    @Test("startup restores a staged prepared deletion before reading the session list")
    func bootstrapRollsBackPreparedPermanentDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-delete-bootstrap-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let parent = try store.createSession(title: "合成待恢复会话")
        try store.saveMessage(LLMMessage(role: .user, content: "合成待恢复消息"), sessionID: parent.id)
        let survivor = try store.createSession(title: "合成保留会话")
        try store.saveMessage(LLMMessage(role: .user, content: "合成保留消息"), sessionID: survivor.id)
        let parentURL = store.sessionsDirectory.appendingPathComponent("\(parent.id).json")
        let survivorURL = store.sessionsDirectory.appendingPathComponent("\(survivor.id).json")
        let parentBytes = try Data(contentsOf: parentURL)
        let survivorBytes = try Data(contentsOf: survivorURL)
        let operationID = UUID()
        let trash = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let staged = trash.appendingPathComponent("\(operationID.uuidString).json")
        let marker = trash.appendingPathComponent(".session-delete-\(operationID.uuidString).pending.json")
        let markerData: [String: Any] = [
            "operationID": operationID.uuidString,
            "targetID": parent.id,
            "scopeID": "session:\(parent.id):active",
            "sourceLocation": "active",
            "destinationLocation": "trash",
            "payloadDigest": DeletionGate.fingerprint(parentBytes),
            "phase": "prepared",
            "permanent": true
        ]
        try JSONSerialization.data(withJSONObject: markerData, options: .sortedKeys).write(to: marker, options: .atomic)
        try FileManager.default.moveItem(at: parentURL, to: staged)

        let chat = ChatStore()
        try #require(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root)))
        #expect(Set(chat.sessions.map { $0.id.uuidString }) == Set([parent.id, survivor.id]))
        #expect(try Data(contentsOf: parentURL) == parentBytes)
        #expect(try Data(contentsOf: survivorURL) == survivorBytes)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
