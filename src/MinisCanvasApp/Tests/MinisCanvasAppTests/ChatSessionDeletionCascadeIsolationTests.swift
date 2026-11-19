import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Lane QODER-DEV-SESSION-DELETE-017 contract tests for D-SESSION-15/16/18
/// at the production session-management boundary (ChatStore + the deletion
/// confirmation sheet).
@Suite("Chat session deletion cascade isolation")
@MainActor
struct ChatSessionDeletionCascadeIsolationTests {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDeleteCascade-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("我已核对这份预览").withSecondConfirmation("移入回收站")
    }

    @Test("deleting one session moves only its file and keeps sibling drafts and transcripts intact")
    func activeTrashDeleteClearsOnlyTargetSessionState() throws {
        let root = try makeRoot("cascade")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))

        let doomedID = try #require(chat.activeSessionID)
        chat.draftText = "被删会话的草稿"
        chat.appendUser("被删会话的消息")
        let keeperID = chat.applyNewSession(title: "保留会话")
        chat.draftText = "保留会话的草稿"
        // 会话落盘已改为后台合并写入；读磁盘前先把待写内容刷下去。
        chat.flushPendingSessionPersistence()

        let activeURL = store.sessionsDirectory.appendingPathComponent("\(doomedID.uuidString).json")
        let keeperURL = store.sessionsDirectory.appendingPathComponent("\(keeperID.uuidString).json")
        let doomedBefore = try Data(contentsOf: activeURL)
        let keeperBefore = try Data(contentsOf: keeperURL)
        // Neighbouring-domain fixture that must never be touched.
        let canvasURL = root.appendingPathComponent("canvas/canvas-1.json")
        try FileManager.default.createDirectory(
            at: canvasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"canvas":"untouched"}"#.utf8).write(to: canvasURL)

        let preview = try chat.previewCurrentDeletion(id: doomedID)
        #expect(!preview.archived)
        #expect(preview.intent.reversible)
        #expect(preview.intent.affectedCount == 1)
        #expect(chat.sessions.count == 2)

        let receipt = try chat.deleteSession(id: doomedID, intent: confirmed(preview.intent))

        // Disk cascade: exactly the target file moved into the trash; the
        // sibling transcript and the canvas fixture are byte-stable.
        let trashURL = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent("\(receipt.operationID.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: activeURL.path))
        #expect(try Data(contentsOf: trashURL) == doomedBefore)
        #expect(try Data(contentsOf: keeperURL) == keeperBefore)
        #expect(try Data(contentsOf: canvasURL) == Data(#"{"canvas":"untouched"}"#.utf8))

        // UI state cascade: only the deleted session disappears from the
        // list; the surviving session keeps its draft and active pointer.
        #expect(chat.sessions.map(\.id) == [keeperID])
        #expect(chat.activeSessionID == keeperID)
        #expect(chat.draftText == "保留会话的草稿")

        // A fresh session must not inherit the deleted session's draft.
        let freshID = chat.applyNewSession(title: "新会话")
        #expect(chat.draftText == "")
        #expect(chat.applySwitchSession(id: keeperID))
        #expect(chat.draftText == "保留会话的草稿")
        #expect(chat.sessions.count == 2)
        #expect(!chat.sessions.contains(where: { $0.id == doomedID }))
        _ = freshID
    }

    @Test("wrong permanent phrase cannot delete; sheet gates both steps on the bound text")
    func deletionSheetBindsExactConfirmationPhrases() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingParentDirectories(5)
        let sidebar = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
            ),
            encoding: .utf8
        )

        // Two-step confirmation: a first step that only advances after the
        // user typed the exact previewed session name, and a final destructive button gated on the
        // exact phrase bound to the preview's reversibility.
        for contract in [
            "enum Step", "case first", "case second",
            "Button(\"下一步\")",
            ".disabled(firstConfirmation != request.intent.targetName)",
            ".disabled(firstConfirmation != request.intent.targetName || secondConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) != (\"永久删除\"))",
            "role: .destructive",
            "withFirstConfirmation(firstConfirmation)",
            "withSecondConfirmation(secondConfirmation)",
            "case .irreversibleRequiresPhrase",
            "第二确认必须输入 永久删除",
        ] {
            #expect(sidebar.contains(contract), "Missing deletion-confirmation contract: \(contract)")
        }
        let recoverable = try #require(sidebar.range(of: "Button(\"移入回收站\", role: .destructive)"))
        let typed = try #require(sidebar.range(of: "Button(\"下一步\")", range: recoverable.upperBound..<sidebar.endIndex))
        let recoverableButton = sidebar[recoverable.lowerBound..<typed.lowerBound]
        #expect(recoverableButton.contains("withFirstConfirmation(request.intent.targetName)"))
        #expect(recoverableButton.contains("withSecondConfirmation(\"移入回收站\")"))
        #expect(!recoverableButton.contains(".keyboardShortcut"))
        #expect(!sidebar.contains("withFirstConfirmation(\""))
        #expect(!sidebar[typed.lowerBound...].contains("withSecondConfirmation(\""))
    }
}

private extension URL {
    func deletingParentDirectories(_ count: Int) -> URL {
        var url = self
        for _ in 0..<count { url = url.deletingLastPathComponent() }
        return url
    }
}
