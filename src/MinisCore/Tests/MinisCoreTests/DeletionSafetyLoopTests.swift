import Foundation
import Testing
@testable import MinisCore

private func deletionTestDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func confirmed(_ intent: OperationIntent, phrase: String = "确认") -> OperationIntent {
    intent.withFirstConfirmation("我已核对预览").withSecondConfirmation(phrase)
}

struct DeletionSafetyLoopTests {
    @Test func previewRequiresTwoConfirmationsAndReceiptFollowsMutation() throws {
        let intent = DeletionGate.preview(
            targetID: "asset-1",
            targetType: "asset",
            targetName: "cover.png",
            affectedCount: 1,
            impactSummary: "移入回收站",
            scopeID: "asset:canvas-a",
            revision: 7,
            fingerprint: DeletionGate.fingerprint("asset-1:v1")
        )
        var performed = false
        #expect(DeletionGate.prepare(intent, currentRevision: 7, currentFingerprint: intent.fingerprint) == .failure(.firstConfirmationRequired))
        #expect(DeletionGate.prepare(intent.withFirstConfirmation("确认"), currentRevision: 7, currentFingerprint: intent.fingerprint) == .failure(.secondConfirmationRequired))

        let receipt = try DeletionGate.execute(
            confirmed(intent),
            currentRevision: 7,
            currentFingerprint: intent.fingerprint
        ) { _ in performed = true }
        #expect(performed)
        #expect(receipt.operationID == intent.operationID)
        #expect(receipt.targetID == intent.targetID)
        #expect(receipt.outcome == "deleted")
    }

    @Test func targetChangeStopsMutationBeforeReceipt() throws {
        let intent = confirmed(DeletionGate.preview(
            targetID: "asset-1", targetType: "asset", targetName: "cover.png",
            affectedCount: 1, impactSummary: "移入回收站", scopeID: "asset:canvas-a",
            revision: 7, fingerprint: "old"
        ))
        var performed = false
        #expect(throws: DeletionGateError.targetChanged) {
            try DeletionGate.execute(intent, currentRevision: 8, currentFingerprint: "new") { _ in performed = true }
        }
        #expect(!performed)
    }

    @Test func sessionDeleteMovesToTrashAndRestores() throws {
        let directory = try deletionTestDirectory("SessionDeletion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
        let session = try store.createSession()
        try store.saveMessage(LLMMessage(role: .user, content: "可恢复内容"), sessionID: session.id)

        let service = SessionDeletionService(manager: manager)
        let receipt = try service.delete(confirmed(service.preview(sessionID: session.id)))
        #expect(store.loadSession(id: session.id) == nil)
        try service.restore(receipt)
        #expect(store.loadSession(id: session.id)?.messages.count == 1)
    }

    @Test func pendingSessionDeleteFailsClosedUntilProvenRecovery() throws {
        let directory = try deletionTestDirectory("SessionDeletionPending")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
        let session = try store.createSession()
        let source = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let operationID = UUID()
        let marker = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent(".session-delete-\(operationID.uuidString).pending.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try Data(contentsOf: source)
        let markerData: [String: Any] = [
            "operationID": operationID.uuidString,
            "targetID": session.id,
            "scopeID": "session:\(session.id):active",
            "sourceLocation": "active",
            "destinationLocation": "trash",
            "payloadDigest": DeletionGate.fingerprint(payload),
            "phase": "prepared"
        ]
        try JSONSerialization.data(withJSONObject: markerData, options: [.sortedKeys]).write(to: marker, options: .atomic)

        let service = SessionDeletionService(manager: manager)
        #expect(throws: SessionDeletionError.recoveryRequired(operationID.uuidString)) {
            try service.preview(sessionID: session.id)
        }
        #expect(try service.recoverPendingTransactions() == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try service.preview(sessionID: session.id).targetID == session.id)
        #expect(try Data(contentsOf: source) == payload)
    }

    @Test func movedSessionDeleteRecoveryPreservesTrashBytes() throws {
        let directory = try deletionTestDirectory("SessionDeletionMoved")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
        let session = try store.createSession()
        let source = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let operationID = UUID()
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let trash = trashDirectory.appendingPathComponent("\(operationID.uuidString).json")
        let marker = trashDirectory.appendingPathComponent(".session-delete-\(operationID.uuidString).pending.json")
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let payload = try Data(contentsOf: source)
        try FileManager.default.moveItem(at: source, to: trash)
        let markerData: [String: Any] = [
            "operationID": operationID.uuidString,
            "targetID": session.id,
            "scopeID": "session:\(session.id):active",
            "sourceLocation": "active",
            "destinationLocation": "trash",
            "payloadDigest": DeletionGate.fingerprint(payload),
            "phase": "moved"
        ]
        try JSONSerialization.data(withJSONObject: markerData, options: [.sortedKeys]).write(to: marker, options: .atomic)

        let service = SessionDeletionService(manager: manager)
        #expect(throws: SessionDeletionError.recoveryRequired(operationID.uuidString)) {
            try service.restore(DeletionReceipt(
                operationID: operationID,
                targetID: session.id,
                scopeID: "session:\(session.id):active",
                affectedCount: 1,
                outcome: "deleted",
                createdAt: Date()
            ))
        }
        #expect(try service.recoverPendingTransactions() == 1)
        #expect(try Data(contentsOf: trash) == payload)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func skillDeleteMovesWholeFolderAndRestores() throws {
        let directory = try deletionTestDirectory("SkillDeletion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkillStore(skillsRoot: directory)
        let skill = try store.importSkill(content: "---\nname: Test Skill\ndescription: demo\n---\nbody")
        let extra = store.skillDirectoryURL(for: skill.id).appendingPathComponent("references/extra.md")
        try FileManager.default.createDirectory(at: extra.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("extra".utf8).write(to: extra)

        let service = SkillDeletionService(store: store)
        let receipt = try service.delete(confirmed(service.preview(skillID: skill.id)))
        #expect(store.allSkills().isEmpty)
        try service.restore(receipt)
        #expect(store.allSkills().map(\.id) == [skill.id])
        #expect(store.readSkillFile(skill.id, relativePath: "references/extra.md") == "extra")
    }

    @Test func skillDeleteSurfacesFilesystemFailure() throws {
        let directory = try deletionTestDirectory("SkillDeletionError")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkillStore(skillsRoot: directory)
        let skill = try store.importSkill(content: "---\nname: Error Skill\n---\nbody")
        let trash = directory.appendingPathComponent(".trash")
        try Data("not a directory".utf8).write(to: trash)
        let service = SkillDeletionService(store: store)

        do {
            _ = try service.delete(confirmed(service.preview(skillID: skill.id)))
            Issue.record("expected the filesystem error to be returned")
        } catch let error as SkillDeletionError {
            guard case .deleteFailed(let message) = error else {
                Issue.record("unexpected skill deletion error: \(error)")
                return
            }
            #expect(!message.isEmpty)
        }
        #expect(store.allSkills().map(\.id) == [skill.id])
    }

    @Test func mcpDeleteIsRecoverableAndFilesystemErrorsAreThrown() throws {
        let directory = try deletionTestDirectory("MCPDeletion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(fileURL: file)
        let server = MCPServer(id: "test", name: "Test", type: .http, url: "https://example.test")
        try manager.addServer(server)

        let receipt = try manager.deleteServer(confirmed(manager.deletionIntent(id: server.id)))
        #expect(manager.server(id: server.id) == nil)
        #expect(manager.trashedServers().map(\.id) == [server.id])
        try manager.restoreServer(id: receipt.targetID)
        #expect(manager.server(id: server.id) == server)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do {
            _ = try manager.removeServer(id: server.id)
            Issue.record("expected MCP persistence error to be returned")
        } catch {
            #expect(!String(describing: error).isEmpty)
        }
        #expect(manager.server(id: server.id) == server)
    }
}
