import Foundation
import Observation
import Testing
@testable import MinisCanvasApp

@Suite("AF-06 Composer session isolation")
@MainActor
struct AF06ComposerIsolationTests {
    @Test("pending attachments keep stable ownership across a session switch")
    func pendingAttachmentRestoresAfterLateResolution() async throws {
        let chat = ChatStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("af06-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("note.txt")
        try Data("late attachment".utf8).write(to: fileURL)
        let firstSessionID = try #require(chat.activeSessionID)

        chat.addAttachments(urls: [fileURL])
        let attachmentID = try #require(chat.pendingAttachments.first?.id)
        let secondSessionID = chat.applyNewSession(title: "B")
        #expect(chat.activeSessionID == secondSessionID)
        #expect(chat.pendingAttachments.isEmpty)

        try await Task.sleep(for: .milliseconds(150))
        chat.switchSession(id: firstSessionID)
        let restored = try #require(chat.pendingAttachments.first)
        #expect(restored.id == attachmentID)
        #expect(restored.kind == .text)
        #expect(restored.data == Data("late attachment".utf8))
    }

    @Test("files the user attaches count as already read by the model in that session")
    func attachedFilesAreMarkedRead() throws {
        let chat = ChatStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("existing.txt")
        try Data("old".utf8).write(to: fileURL)
        let sessionID = try #require(chat.activeSessionID)
        var marked: [(path: String, session: String)] = []
        chat.fileReadMarker = { path, session in marked.append((path, session)) }

        chat.addAttachments(urls: [fileURL])
        #expect(marked.count == 1)
        #expect(marked.first?.path == fileURL.path)
        #expect(marked.first?.session == sessionID.uuidString)
        // 不是本地文件的地址不登记。
        chat.addAttachments(urls: [try #require(URL(string: "https://example.invalid/a.txt"))])
        #expect(marked.count == 1)
    }

    @Test("editing target is isolated per session and restored on return")
    func editingTargetDoesNotLeakAcrossSessions() throws {
        let chat = ChatStore()
        let firstSessionID = try #require(chat.activeSessionID)
        chat.appendUser("A message")
        let messageID = try #require(chat.messages.first(where: { $0.role == .user })?.id)

        chat.beginEdit(messageID: messageID)
        #expect(chat.isEditingMessage)
        let secondSessionID = chat.applyNewSession(title: "B")
        #expect(chat.activeSessionID == secondSessionID)
        #expect(!chat.isEditingMessage)

        chat.switchSession(id: firstSessionID)
        #expect(chat.isEditingMessage)
        #expect(chat.editingMessageID == messageID)
        #expect(chat.draftText == "A message")
    }

    @Test("draft text is isolated per session without a persistence adapter")
    func draftTextRestoresAfterSessionSwitchWithoutDraftStore() throws {
        let chat = ChatStore()
        let firstSessionID = try #require(chat.activeSessionID)

        chat.draftText = "A draft"
        let secondSessionID = chat.applyNewSession(title: "B")
        #expect(chat.activeSessionID == secondSessionID)
        #expect(chat.draftText.isEmpty)

        chat.draftText = "B draft"
        chat.switchSession(id: firstSessionID)
        #expect(chat.draftText == "A draft")

        chat.switchSession(id: secondSessionID)
        #expect(chat.draftText == "B draft")
    }

    @Test("session action rollback restores draft and pasted capsule state")
    func sessionActionRollbackRestoresComposerState() throws {
        let chat = ChatStore()
        let firstSessionID = try #require(chat.activeSessionID)
        let firstPastedDraft = PastedTextDraft(
            id: UUID(),
            text: "A pasted payload",
            source: .pasteboard
        )

        chat.draftText = "A draft"
        #expect(chat.setPastedTextDraft(firstPastedDraft))
        let rollbackState = chat.captureSessionActionState()

        chat.draftText = "Mutated draft"
        #expect(
            chat.setPastedTextDraft(
                PastedTextDraft(id: UUID(), text: "Mutated pasted payload", source: .typing)
            )
        )
        let secondSessionID = chat.applyNewSession(title: "B")
        chat.draftText = "B draft"
        #expect(
            chat.setPastedTextDraft(
                PastedTextDraft(id: UUID(), text: "B pasted payload", source: .pasteboard)
            )
        )

        chat.restoreSessionActionState(rollbackState)

        #expect(chat.activeSessionID == firstSessionID)
        #expect(!chat.hasSession(secondSessionID))
        #expect(chat.draftText == "A draft")
        #expect(chat.activePastedTextDraft == firstPastedDraft)
    }

    @Test("typing does not notify hasDraft observers except on empty/non-empty switches")
    func hasDraftOnlyChangesOnEmptinessSwitch() {
        let chat = ChatStore()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        func observe() {
            withObservationTracking {
                _ = chat.hasDraft
                _ = chat.hasNonBlankDraft
            } onChange: {
                counter.value += 1
            }
        }
        observe()
        chat.draftText = "/"
        #expect(counter.value == 1)
        #expect(chat.hasDraft && chat.hasNonBlankDraft)
        observe()
        chat.draftText = "/g"
        chat.draftText = "/go"
        #expect(counter.value == 1)
        chat.draftText = ""
        #expect(counter.value == 2)
        #expect(!chat.hasDraft)
    }

    @Test("hasDraft follows the active session when switching")
    func hasDraftFollowsSessionSwitch() throws {
        let chat = ChatStore()
        let firstSessionID = try #require(chat.activeSessionID)
        chat.draftText = "keep me"
        let secondSessionID = chat.applyNewSession(title: "B")
        #expect(chat.activeSessionID == secondSessionID)
        #expect(!chat.hasDraft)
        chat.switchSession(id: firstSessionID)
        #expect(chat.hasDraft)
        #expect(chat.draftText == "keep me")
    }
}
