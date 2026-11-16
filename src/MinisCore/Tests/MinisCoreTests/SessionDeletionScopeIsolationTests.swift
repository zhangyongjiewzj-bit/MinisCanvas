import Foundation
import Testing
@testable import MinisCore

/// Lane QODER-DEV-SESSION-DELETE-017 contract tests for D-SESSION-15/16/18.
///
/// Covers the three open scenarios named by the source review:
/// 1. The trash-deletion preview text/scope must equal the real on-disk
///    deletion set (D-SESSION-15).
/// 2. Wrong confirmation phrases must never execute an irreversible
///    deletion, and the recoverable/permanent paths must not be
///    interchangeable (D-SESSION-16).
/// 3. Deleting one session must leave sibling sessions, archived sessions,
///    long-term memory, canvas fixtures and project data byte-stable, and
///    late callbacks for the deleted session must be rejected (D-SESSION-18).
@Suite("Session deletion scope and cross-domain isolation")
struct SessionDeletionScopeIsolationTests {
    private let clock = Date(timeIntervalSince1970: 5_000)

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDeleteScope-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Recursive relative-path → bytes inventory of a directory tree.
    private func inventory(at root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return result }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let childPath = url.resolvingSymlinksInPath().path
            #expect(childPath.hasPrefix(base + "/"), "enumerator escaped the inventoried root: \(childPath)")
            let relative = String(childPath.dropFirst(base.count).dropFirst())
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    private func trashConfirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("我已核对这份预览").withSecondConfirmation("移入回收站")
    }

    // MARK: - D-SESSION-15 preview scope == actual trash cascade

    @Test("trash preview scope matches the exact files the deletion moves")
    func trashPreviewMatchesActualDeletionSet() throws {
        let root = try makeRoot("scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let badgeRoot = try makeRoot("scope-badges")
        defer { try? FileManager.default.removeItem(at: badgeRoot) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: badgeRoot))
        let service = SessionDeletionService(manager: manager)

        let target = try store.createSession(title: "被删除的会话")
        try store.saveMessage(LLMMessage(role: .user, content: "目标消息"), sessionID: target.id)
        let sibling = try store.createSession(title: "保留的会话")
        try store.saveMessage(LLMMessage(role: .user, content: "保留消息"), sessionID: sibling.id)
        let archived = try store.createSession(title: "归档的会话")
        try manager.archive(sessionID: archived.id)

        // Neighbouring domains inside the same data root: long-term memory,
        // canvas payload and a project index fixture.
        let memoryRoot = root.appendingPathComponent("memory-domain", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        let memory = MemoryStore(directory: memoryRoot)
        try memory.addFact("长期记忆必须幸存", sourceSessionID: target.id)
        let canvasURL = root.appendingPathComponent("canvas/canvas-1.json")
        let projectURL = root.appendingPathComponent("projects/project-alpha.json")
        for url in [canvasURL, projectURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(#"{"canvas": "只属于画布域", "id": "c-1"}"#.utf8).write(to: canvasURL)
        try Data(#"{"project": "alpha", "sessions": []}"#.utf8).write(to: projectURL)

        let before = try inventory(at: root)
        let targetBytes = try Data(
            contentsOf: store.sessionsDirectory.appendingPathComponent("\(target.id).json"))

        let preview = try service.preview(sessionID: target.id)
        // The displayed impact scope must describe exactly what happens:
        // one recoverable session, moved into the trash, nothing else.
        #expect(preview.operationType == .delete)
        #expect(preview.targetID == target.id)
        #expect(preview.targetType == "session")
        #expect(preview.targetName == "被删除的会话")
        #expect(preview.reversible)
        #expect(preview.affectedCount == 1)
        #expect(preview.scopeID == "session:\(target.id):active")
        #expect(preview.impactSummary.contains("移入回收站"))
        #expect(preview.impactSummary.contains("恢复"))
        // The summary must not promise a wider cascade than the executor owns.
        for unrelated in ["记忆", "画布", "项目", "其它会话", "所有会话"] {
            #expect(!preview.impactSummary.contains(unrelated),
                    "impactSummary advertises \(unrelated), which the cascade does not touch")
        }

        let intent = trashConfirmed(preview)
        let receipt = try service.delete(intent)
        #expect(receipt.affectedCount == preview.affectedCount)
        #expect(receipt.targetID == target.id)
        #expect(receipt.scopeID == preview.scopeID)
        #expect(receipt.outcome == "deleted")

        // The only filesystem difference inside the whole data root:
        // the target session file left and exactly one trash entry arrived.
        let after = try inventory(at: root)
        let removed = Set(before.keys).subtracting(after.keys)
        let added = Set(after.keys).subtracting(before.keys)
        let unchangedShared = Set(before.keys).intersection(after.keys).allSatisfy { key in
            before[key] == after[key]
        }
        #expect(removed == ["sessions/\(target.id).json"])
        #expect(added == ["sessions/_trash/\(receipt.operationID.uuidString).json",
                          "sessions/_trash/.trash-receipt-\(receipt.operationID.uuidString).json"])
        #expect(unchangedShared)
        #expect(after["sessions/_trash/\(receipt.operationID.uuidString).json"] == targetBytes)
        #expect(after["canvas/canvas-1.json"] == before["canvas/canvas-1.json"])
        #expect(after["projects/project-alpha.json"] == before["projects/project-alpha.json"])

        // Restore brings the exact bytes back and still touches nothing else.
        try service.restore(receipt)
        let restored = try inventory(at: root)
        #expect(restored.keys.filter { $0.hasPrefix("sessions/_trash") }.isEmpty)
        #expect(restored["sessions/\(target.id).json"] == targetBytes)
        #expect(Set(restored.keys) == Set(before.keys))
        #expect(try memory.facts().map(\.text) == ["长期记忆必须幸存"])
        #expect(try Data(contentsOf: canvasURL) == before["canvas/canvas-1.json"])

        // Sibling and archived sessions stay fully usable.
        #expect(store.loadSession(id: sibling.id)?.messages.count == 1)
        #expect(manager.loadSessionIncludingArchived(id: archived.id)?.title == "归档的会话")
    }

    @Test("recoverable deletion groups completed task transcripts with their parent")
    func trashGroupsCompletedTaskTranscripts() throws {
        let root = try makeRoot("task-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: root))
        let parent = try store.createSession(title: "合成父会话")
        let child = try store.forkSession(
            from: parent.id, id: "\(parent.id):child:synthetic-run",
            throughMessageIndex: 0, createdByTaskID: "synthetic-task", createdByRunID: "synthetic-run"
        )
        let grandchild = try store.forkSession(
            from: child.id, id: "\(child.id):child:synthetic-nested-run",
            throughMessageIndex: 0, createdByTaskID: "synthetic-nested-task",
            createdByRunID: "synthetic-nested-run"
        )
        let ordinaryFork = try store.forkSession(from: parent.id)
        let unrelated = try store.createSession(title: "合成独立会话")
        try store.saveMessage(LLMMessage(role: .user, content: "合成子任务对话"), sessionID: child.id)

        let before = try inventory(at: root)
        let grouped = [parent.id, child.id, grandchild.id].map { "sessions/\($0).json" }
        let preserved = [ordinaryFork.id, unrelated.id].map { "sessions/\($0).json" }
        let service = SessionDeletionService(manager: manager, isCompletedTask: { session in
            session.id == child.id && session.createdByTaskID == child.createdByTaskID
                && session.createdByRunID == child.createdByRunID
                || session.id == grandchild.id && session.createdByTaskID == grandchild.createdByTaskID
                && session.createdByRunID == grandchild.createdByRunID
        })
        let preview = try service.preview(sessionID: parent.id, includingCompletedTasks: true)
        #expect(preview.reversible)
        #expect(preview.affectedCount == grouped.count)
        let receipt = try service.delete(trashConfirmed(preview))
        #expect(receipt.affectedCount == grouped.count)
        #expect(try service.trashEntries().map(\.receipt) == [receipt])

        let trashed = try inventory(at: root)
        for path in grouped {
            #expect(trashed[path] == nil, "Expected the active transcript to move: \(path)")
        }
        for path in preserved {
            #expect(trashed[path] == before[path])
        }

        // A single recovery must make the whole lineage readable again.
        try service.restore(receipt)
        let restored = try inventory(at: root)
        for path in grouped + preserved {
            #expect(restored[path] == before[path])
        }
        #expect(Set(store.listSessions().map(\.id)) ==
                Set([parent.id, child.id, grandchild.id, ordinaryFork.id, unrelated.id]))
        #expect(try service.trashEntries().isEmpty)
    }

    // MARK: - D-SESSION-16 exact phrase guards the irreversible path

    @Test("wrong or missing second phrase never permanently deletes a session")
    func permanentDeleteRequiresExactPhrase() throws {
        let root = try makeRoot("phrase")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let session = try store.createSession(title: "口令守卫")
        try store.saveMessage(LLMMessage(role: .user, content: "不可丢的内容"), sessionID: session.id)
        let fileURL = store.sessionsDirectory.appendingPathComponent("\(session.id).json")
        let original = try Data(contentsOf: fileURL)

        let preview = try store.previewDeletion(id: session.id, now: clock, ttl: 60)
        #expect(preview.operationType == .permanentDelete)
        #expect(!preview.reversible)

        let firstOnly = preview.withFirstConfirmation("我已核对")
        #expect(throws: DeletionGateError.secondConfirmationRequired) {
            try store.deleteSession(id: session.id, intent: firstOnly, now: clock)
        }
        let blankSecond = firstOnly.withSecondConfirmation("   ")
        #expect(throws: DeletionGateError.secondConfirmationRequired) {
            try store.deleteSession(id: session.id, intent: blankSecond, now: clock)
        }
        for wrong in [
            "permanently delete",
            "PERMANENT DELETE",
            "PERMANENTLYDELETE",
            "永久删除.",
            "移入回收站",
            "确认删除",
        ] {
            let candidate = firstOnly.withSecondConfirmation(wrong)
            #expect(throws: DeletionGateError.irreversibleRequiresPhrase,
                     "wrong phrase \(wrong.debugDescription) must not delete") {
                try store.deleteSession(id: session.id, intent: candidate, now: clock)
            }
            #expect(try Data(contentsOf: fileURL) == original)
            #expect(store.loadSession(id: session.id)?.messages.count == 1)
        }

        // Positive control: the exact phrase (surrounding whitespace is
        // trimmed by both UI and gate) does perform the permanent deletion
        // without leaving any trash entry.
        let correct = firstOnly.withSecondConfirmation(" 永久删除 ")
        let receipt = try store.deleteSession(id: session.id, intent: correct, now: clock)
        #expect(receipt.targetID == session.id)
        #expect(store.loadSession(id: session.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let trash = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("recoverable and permanent deletion paths cannot be cross-routed")
    func trashAndPermanentPrimitivesRejectForeignIntents() throws {
        let root = try makeRoot("cross")
        defer { try? FileManager.default.removeItem(at: root) }
        let badgeRoot = try makeRoot("cross-badges")
        defer { try? FileManager.default.removeItem(at: badgeRoot) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: badgeRoot))
        let service = SessionDeletionService(manager: manager)

        // A reversible trash intent must never reach the permanent primitive:
        // otherwise the "移入回收站" text would silently destroy the file.
        let inStore = try store.createSession(title: "串线路径-永久原语")
        let storeFile = store.sessionsDirectory.appendingPathComponent("\(inStore.id).json")
        let storeBytes = try Data(contentsOf: storeFile)
        let trashIntent = trashConfirmed(try service.preview(sessionID: inStore.id))
        #expect(throws: DeletionGateError.invalidIntent) {
            try store.deleteSession(id: inStore.id, intent: trashIntent, now: clock)
        }
        #expect(try Data(contentsOf: storeFile) == storeBytes)
        #expect(store.loadSession(id: inStore.id) != nil)
        let trash = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: trash.path))

        // A permanent (永久删除) intent must never be executed by
        // the user-facing recoverable service path.
        let inService = try store.createSession(title: "串线路径-回收站服务")
        let serviceFile = store.sessionsDirectory.appendingPathComponent("\(inService.id).json")
        let serviceBytes = try Data(contentsOf: serviceFile)
        let permanentIntent = try store.previewDeletion(id: inService.id, now: clock, ttl: 60)
            .withFirstConfirmation("我已核对")
            .withSecondConfirmation("永久删除")
        #expect(throws: SessionDeletionError.self) {
            try service.delete(permanentIntent)
        }
        #expect(try Data(contentsOf: serviceFile) == serviceBytes)
        #expect(store.loadSession(id: inService.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: trash.path))

        // The trash path stays usable after both rejected foreign intents,
        // and the consumed ticket cannot be replayed for a second copy.
        let intent = trashConfirmed(try service.preview(sessionID: inService.id))
        let receipt = try service.delete(intent)
        #expect(!FileManager.default.fileExists(atPath: serviceFile.path))
        #expect(throws: SessionManagerError.sessionNotFound(inService.id)) {
            _ = try service.delete(intent)
        }
        // Even if the transcript file reappears, the consumed ticket stays
        // one-shot: the gate refuses a second execution by operationID.
        try serviceBytes.write(to: serviceFile)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            _ = try service.delete(intent)
        }
        #expect(try Data(contentsOf: serviceFile) == serviceBytes)
        let trashFiles = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(trashFiles.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: trash.appendingPathComponent("\(receipt.operationID.uuidString).json").path))
    }

    // MARK: - D-SESSION-18 late callbacks and cross-domain stability

    @Test("after deletion late writes for the deleted session are rejected")
    func deletedSessionRejectsLateCallbacks() throws {
        let root = try makeRoot("late")
        defer { try? FileManager.default.removeItem(at: root) }
        let badgeRoot = try makeRoot("late-badges")
        defer { try? FileManager.default.removeItem(at: badgeRoot) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: badgeRoot))
        let service = SessionDeletionService(manager: manager)

        let doomed = try store.createSession(title: "在途会话")
        let keeper = try store.createSession(title: "幸存会话")
        try store.saveMessage(LLMMessage(role: .user, content: "在途"), sessionID: doomed.id)
        try store.saveMessage(LLMMessage(role: .user, content: "幸存"), sessionID: keeper.id)
        let keeperFile = store.sessionsDirectory.appendingPathComponent("\(keeper.id).json")
        let keeperBefore = try Data(contentsOf: keeperFile)
        let doomedFact = try #require(manager.managerFact(for: doomed.id))
        let inventoryBefore = try inventory(at: root)

        let receipt = try service.delete(trashConfirmed(try service.preview(sessionID: doomed.id)))

        #expect(throws: SessionStoreError.sessionNotFound(doomed.id)) {
            try store.saveMessage(LLMMessage(role: .assistant, content: "迟到的回复"), sessionID: doomed.id)
        }
        #expect(throws: SessionManagerError.self) {
            _ = try manager.requireCurrent(doomedFact)
        }
        // The rejected late writes created nothing: no ghost file, no extra
        // trash entry, and the sibling transcript is byte-identical.
        #expect(try Data(contentsOf: keeperFile) == keeperBefore)
        #expect(store.loadSession(id: doomed.id) == nil)
        let inventoryAfter = try inventory(at: root)
        let changed = Set(inventoryBefore.keys).symmetricDifference(inventoryAfter.keys)
            .union(Set(inventoryBefore.keys).intersection(inventoryAfter.keys).filter { inventoryBefore[$0] != inventoryAfter[$0] })
        #expect(changed == ["sessions/\(doomed.id).json", "sessions/_trash/\(receipt.operationID.uuidString).json",
                            "sessions/_trash/.trash-receipt-\(receipt.operationID.uuidString).json"])
        let trash = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let payloads = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        #expect(payloads == ["\(receipt.operationID.uuidString).json"])
    }
}
