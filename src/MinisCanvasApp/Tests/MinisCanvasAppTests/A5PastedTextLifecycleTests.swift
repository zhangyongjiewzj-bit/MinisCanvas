import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("A5 pasted text lifecycle")
struct A5PastedTextLifecycleTests {
    @Test("real paste events use scalar and multiline thresholds, while typing never collapses")
    @MainActor
    func realPasteThresholdsAndTypingSemantics() {
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = "正文"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        var accepted: [ComposerPasteEvent] = []
        var acceptanceDecisions: [Bool] = []
        textView.onPasteEvent = { event in
            // The hook notifies every nonempty paste; the production consumer
            // decides whether it becomes a collapsed reference. Isolate each
            // threshold sample from any previously accepted capsule.
            let handled = PastedTextComposerConsumer.accept(event, in: ChatStore())
            acceptanceDecisions.append(handled)
            if handled { accepted.append(event) }
            return handled
        }

        textView.pasteboardStringProvider = {
            String(repeating: "x", count: PastedTextPolicy.scalarThreshold)
        }
        textView.paste(nil)

        textView.pasteboardStringProvider = {
            String(repeating: "x", count: PastedTextPolicy.scalarThreshold + 1)
        }
        textView.paste(nil)

        textView.pasteboardStringProvider = {
            String(
                repeating: "x",
                count: PastedTextPolicy.lineScalarThreshold - PastedTextPolicy.lineThreshold + 1
            ) + String(repeating: "\n", count: PastedTextPolicy.lineThreshold)
        }
        textView.paste(nil)

        #expect(acceptanceDecisions == [false, true, true])
        #expect(accepted.count == 2)
        #expect(accepted.allSatisfy { PastedTextPolicy.shouldCollapse($0.draft) })

        let typed = PastedTextDraft(
            id: UUID(),
            text: String(repeating: "typed", count: 501),
            source: .typing
        )
        #expect(!PastedTextPolicy.shouldCollapse(typed))
    }

    @Test("pasted capsules remain isolated by session and survive a fresh store")
    @MainActor
    func sessionIsolationAndRestartRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("a5-pasted-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ChatStore()
        let sessionStore = SessionStore(directory: directory)
        first.attachPersistence(sessionStore)
        let firstID = try #require(first.activeSessionID)
        let firstDraft = PastedTextDraft(
            id: UUID(),
            text: "第一会话粘贴内容",
            source: .pasteboard
        )
        #expect(first.setPastedTextDraft(firstDraft))

        let restartedBeforeNewSession = ChatStore()
        restartedBeforeNewSession.attachPersistence(SessionStore(directory: directory))
        #expect(restartedBeforeNewSession.activeSessionID == firstID)
        #expect(restartedBeforeNewSession.activePastedTextDraft == firstDraft)

        let secondID = first.applyNewSession(title: "第二会话")
        let secondDraft = PastedTextDraft(
            id: UUID(),
            text: "第二会话粘贴内容",
            source: .pasteboard
        )
        #expect(first.setPastedTextDraft(secondDraft))
        #expect(first.activePastedTextDraft == secondDraft)

        first.switchSession(id: firstID)
        #expect(first.activePastedTextDraft == firstDraft)
        first.switchSession(id: secondID)
        #expect(first.activePastedTextDraft == secondDraft)

        let restarted = ChatStore()
        restarted.attachPersistence(SessionStore(directory: directory))
        restarted.switchSession(id: firstID)
        #expect(restarted.activePastedTextDraft == firstDraft)
        restarted.switchSession(id: secondID)
        #expect(restarted.activePastedTextDraft == secondDraft)
    }

    @Test("editor contract exposes view, edit, save, cancel, and delete actions")
    func editorContractKeepsSessionGuardAndActions() throws {
        let source = try source(named: "PastedTextCapsuleView.swift")

        for marker in [
            "composer.pasted-text.preview",
            "composer.pasted-text.editor",
            "composer.pasted-text.save",
            "composer.pasted-text.cancel",
            "composer.pasted-text.delete",
            "PastedTextComposerConsumer.save",
            "PastedTextComposerConsumer.remove",
            "expectedSessionID: state.sessionID",
            "expectedDraftID: state.draft.id",
            "composer.pasted-text.feedback"
        ] {
            #expect(source.contains(marker), "missing editor contract: \(marker)")
        }

        #expect(source.contains("Button(action: onPreview)"))
        #expect(source.contains("Button(action: onRemove)"))
    }

    @Test("sending freezes body, separator, and pasted text before clearing the capsule")
    @MainActor
    func sendSnapshotPreservesPayloadOrder() {
        let store = ChatStore()
        let draft = PastedTextDraft(id: UUID(), text: "完整粘贴正文", source: .pasteboard)
        #expect(store.setPastedTextDraft(draft))
        store.draftText = "用户正文"

        store.submitComposer()

        #expect(store.activePastedTextDraft == nil)
        #expect(store.lastPastedTextSubmissionSnapshot?.sessionID == store.activeSessionID)
        #expect(store.lastPastedTextSubmissionSnapshot?.capsuleID == draft.id)
        #expect(
            store.lastPastedTextSubmissionSnapshot?.text
                == "用户正文" + ComposerPayload.pastedTextSeparator + "完整粘贴正文"
        )
        #expect(
            store.messages.last(where: { $0.role == .user })?.content
                == "用户正文" + ComposerPayload.pastedTextSeparator + "完整粘贴正文"
        )
    }

    @Test("failed retry creates a fresh submission snapshot from the sent payload")
    @MainActor
    func failedRetryCreatesFreshSnapshot() throws {
        let store = ChatStore()
        let sessionID = try #require(store.activeSessionID)
        store.appendUser("正文" + ComposerPayload.pastedTextSeparator + "已发送粘贴内容")
        store.markExecutionRunning(sessionID: sessionID, turnID: 4, taskID: "failed-task")
        store.markExecutionFailed(sessionID: sessionID, reason: "provider failed")
        let failedIdentity = try #require(store.sessionList.first?.retryIdentity)

        #expect(store.retryFailedSession(failedIdentity))
        #expect(store.lastComposerSubmissionSnapshot?.sessionID == sessionID.uuidString)
        #expect(store.lastComposerSubmissionSnapshot?.turnID != failedIdentity.turnID)
        #expect(store.lastComposerSubmissionSnapshot?.taskID != failedIdentity.taskID)
        store.stopStreaming()
    }

    private func source(named name: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot
                .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
