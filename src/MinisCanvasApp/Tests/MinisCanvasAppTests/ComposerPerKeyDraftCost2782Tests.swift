import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-PERF-05 actual per-key native draft consumer")
@MainActor
struct ComposerPerKeyDraftCost2782Tests {
    private struct CostSample {
        var textStorageMutation = Duration.zero
        var appKitStringRead = Duration.zero
        var productionDelegate = Duration.zero
        var edits = 0
    }

    /// The mutation is one character in NSTextStorage. The two observations
    /// around it are kept separate: NSTextView.string may itself bridge/copy
    /// AppKit storage, while the delegate additionally runs the App binding.
    /// Wall time is diagnostic only; it is not a CPU or allocation oracle.
    private func typeKeys(
        _ count: Int,
        in editor: ComposerPasteAwareTextView,
        through delegate: ScrollableComposerTextView.Coordinator,
        chat: ChatStore
    ) throws -> CostSample {
        let clock = ContinuousClock()
        var sample = CostSample()
        for _ in 0..<count {
            let storage = try #require(editor.textStorage)
            let mutationStart = clock.now
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "z")
            sample.textStorageMutation += mutationStart.duration(to: clock.now)

            let readStart = clock.now
            let appKitValue = editor.string
            sample.appKitStringRead += readStart.duration(to: clock.now)

            let delegateStart = clock.now
            delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            sample.productionDelegate += delegateStart.duration(to: clock.now)
            #expect(chat.draftText == appKitValue)
            sample.edits += 1
        }
        return sample
    }

    @Test("50k and 100k drafts use real one-key storage edits, switch flush and quit flush")
    func perKeyDelegateKeepsOneTimerPerBurstAndPersistsBothSessions() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("perf2782-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "perf2782-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let firstSession = try #require(chat.activeSessionID)
        chat.appendAssistant("unchanged synthetic transcript")
        let history = chat.messages
        let revision = chat.transcriptRevision(forSession: firstSession)
        let firstKey = DraftStore.chatDraftKey(sessionID: firstSession)
        var sessionNotifications = 0
        chat.onSessionsChanged = { sessionNotifications += 1 }

        let delegate = ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { chat.draftText = $0 }),
            font: .systemFont(ofSize: 13),
            onSend: { Issue.record("per-key fixture must not send") }
        ).makeCoordinator()
        let firstEditor = ComposerPasteAwareTextView(frame: .zero)
        firstEditor.string = String(repeating: "a", count: 50_000)
        let first = try typeKeys(32, in: firstEditor, through: delegate, chat: chat)
        let firstDraft = firstEditor.string
        #expect(first.edits == 32 && firstDraft.utf8.count == 50_032)
        #expect(chat.messages == history && chat.transcriptRevision(forSession: firstSession) == revision)
        #expect(sessionNotifications == 0)
        #expect(drafts.latestPayload(for: firstKey) == nil)
        #expect(chat.longDraftTimerCreationCount == 1 && chat.longDraftEncodingCount == 0)

        chat.newSession() // Production switch boundary synchronously flushes A.
        let secondSession = try #require(chat.activeSessionID)
        #expect(secondSession != firstSession && chat.draftText.isEmpty)
        #expect(drafts.load(key: firstKey) == Data(firstDraft.utf8))
        #expect(chat.longDraftEncodingCount == 1)

        let secondEditor = ComposerPasteAwareTextView(frame: .zero)
        secondEditor.string = String(repeating: "b", count: 100_000)
        let second = try typeKeys(32, in: secondEditor, through: delegate, chat: chat)
        let secondDraft = secondEditor.string
        let secondKey = DraftStore.chatDraftKey(sessionID: secondSession)
        #expect(second.edits == 32 && secondDraft.utf8.count == 100_032)
        #expect(drafts.latestPayload(for: secondKey) == nil)
        #expect(chat.longDraftTimerCreationCount == 2 && chat.longDraftEncodingCount == 1)

        chat.switchSession(id: firstSession) // Production switch boundary flushes B.
        #expect(chat.draftText == firstDraft)
        #expect(chat.messages == history && chat.transcriptRevision(forSession: firstSession) == revision)
        #expect(drafts.load(key: secondKey) == Data(secondDraft.utf8))
        #expect(chat.longDraftEncodingCount == 2)
        chat.switchSession(id: secondSession)
        #expect(chat.draftText == secondDraft)

        // A final unsaved keystroke exercises the App quit seam, not another
        // direct DraftStore write. Reopen bytes from the owned on-disk store.
        let final = try typeKeys(1, in: secondEditor, through: delegate, chat: chat)
        let finalDraft = secondEditor.string
        #expect(final.edits == 1 && chat.longDraftTimerCreationCount == 3)
        #expect(chat.longDraftEncodingCount == 2)
        #expect(chat.flushPendingDraftForTermination())
        #expect(chat.longDraftEncodingCount == 3)
        let reopened = DraftStore(directory: root.appendingPathComponent("drafts"))
        #expect(reopened.load(key: firstKey) == Data(firstDraft.utf8))
        #expect(reopened.load(key: secondKey) == Data(finalDraft.utf8))

        print("PERF2782_NATIVE_KEY edits=65 bytes=50032/100033 "
              + "appkit_mutation=\(first.textStorageMutation + second.textStorageMutation + final.textStorageMutation) "
              + "appkit_string_read=\(first.appKitStringRead + second.appKitStringRead + final.appKitStringRead) "
              + "delegate_including_appkit_bridge=\(first.productionDelegate + second.productionDelegate + final.productionDelegate) "
              + "timer=\(chat.longDraftTimerCreationCount) encode=\(chat.longDraftEncodingCount) "
              + "CPU=NOT_MEASURED alloc=NOT_MEASURED SwiftTask_total=NOT_MEASURED window=NONE")
    }
}
