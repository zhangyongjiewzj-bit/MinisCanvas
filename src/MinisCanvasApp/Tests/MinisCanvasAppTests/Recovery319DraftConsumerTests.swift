import AppKit
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-RECOVERY-02 session draft consumers")
@MainActor
struct Recovery319DraftConsumerTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery319-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func chat(_ root: URL, suite: String) throws -> ChatStore {
        let requiredValue561_1 = UserDefaults(suiteName: suite)
        let defaults561: UserDefaults = try #require(requiredValue561_1)
        return ChatStore(
            preferencesDefaults: defaults561,
            logManager: LogManager(directory: root.appendingPathComponent("logs"))
        )
    }

    private func editor(_ chat: ChatStore) -> ScrollableComposerTextView.Coordinator {
        ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { chat.draftText = $0 }),
            font: .systemFont(ofSize: 13),
            onSend: { Issue.record("An unsent-draft fixture must never send") }
        ).makeCoordinator()
    }

    private func acceptNativeEdit(
        _ text: String, through coordinator: ScrollableComposerTextView.Coordinator
    ) {
        // Exercise the production delegate, without a window, pasteboard,
        // event server, or an assumption that AX visibility delivers this event.
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func nativeField(for chat: ChatStore) -> ScrollableComposerTextView {
        @Bindable var bindableChat = chat
        return ScrollableComposerTextView(
            text: $bindableChat.draftText,
            font: .systemFont(ofSize: 13),
            onSend: { Issue.record("An unsent-draft fixture must never send") },
            draftSessionID: chat.activeSessionID,
            nativeDraft: chat.nativeComposerDraft(),
            onRememberNativeDraft: chat.rememberFocusedNativeDraft
        )
    }

    private struct HostedDraftComposer: View {
        @Bindable var chat: ChatStore

        var body: some View {
            ComposerScrollField(
                text: $chat.draftText,
                font: .systemFont(ofSize: 13),
                placeholder: "Draft",
                onSend: { Issue.record("An unsent-draft fixture must never send") },
                focusSessionID: chat.activeSessionID,
                nativeDraft: chat.nativeComposerDraft(),
                onRememberNativeDraft: chat.rememberFocusedNativeDraft
            )
        }
    }

    @Test("mounted composer keeps committed draft through AppKit editor replacement")
    func hostedComposerSwitchKeepsCommittedDraft() throws {
        let root = try root()
        let suite = "recovery319-hosted-\(UUID().uuidString)"
        let chat = try chat(root, suite: suite)
        let directory = root.appendingPathComponent("draft-store")
        let drafts = DraftStore(directory: directory)
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession()
        chat.attachDraftStore(drafts)
        try #require(chat.applySwitchSession(id: a))
        let aKey = DraftStore.chatDraftKey(sessionID: a)
        let bKey = DraftStore.chatDraftKey(sessionID: b)

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedDraftComposer(chat: chat))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            for key in [aKey, bKey] { drafts.cancelPending(key: key) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func editors(in view: NSView) -> [ComposerPasteAwareTextView] {
            if let editor = view as? ComposerPasteAwareTextView { return [editor] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        func waitForEditor(replacing old: ComposerPasteAwareTextView? = nil) throws -> ComposerPasteAwareTextView {
            func mountedEditor() -> ComposerPasteAwareTextView? {
                host.layoutSubtreeIfNeeded()
                let mounted = editors(in: host)
                guard mounted.count == 1, let editor = mounted.first,
                      editor !== old, editor.window === window, editor.delegate != nil else { return nil }
                if let old, old.window != nil || old.delegate != nil { return nil }
                return editor
            }
            for _ in 0..<12 {
                if let editor = mountedEditor() { return editor }
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            return try #require(mountedEditor())
        }

        let aEditor = try waitForEditor()
        try #require(window.makeFirstResponder(aEditor))
        try #require(window.firstResponder === aEditor)
        aEditor.insertText("A native draft", replacementRange: aEditor.selectedRange())
        try #require(chat.draftText == "A native draft")

        try #require(chat.applySwitchSession(id: b))
        let bEditor = try waitForEditor(replacing: aEditor)
        #expect(bEditor.string.isEmpty)
        #expect(chat.draftText.isEmpty)
        #expect(DraftStore(directory: directory).load(key: aKey) == Data("A native draft".utf8))
        #expect(DraftStore(directory: directory).load(key: bKey) == nil)
        try #require(window.makeFirstResponder(bEditor))
        try #require(window.firstResponder === bEditor)
        bEditor.insertText("B native draft", replacementRange: bEditor.selectedRange())
        try #require(chat.draftText == "B native draft")

        try #require(chat.applySwitchSession(id: a))
        let returnedEditor = try waitForEditor(replacing: bEditor)
        #expect(returnedEditor.string == "A native draft")
        #expect(DraftStore(directory: directory).load(key: bKey) == Data("B native draft".utf8))
        try #require(window.makeFirstResponder(returnedEditor))
        try #require(window.firstResponder === returnedEditor)
        returnedEditor.setSelectedRange(NSRange(location: 0, length: returnedEditor.string.utf16.count))
        returnedEditor.deleteBackward(nil)
        #expect(returnedEditor.string.isEmpty)
        #expect(chat.draftText.isEmpty)
        #expect(DraftStore(directory: directory).load(key: aKey) == nil)
        #expect(DraftStore(directory: directory).load(key: bKey) == Data("B native draft".utf8))
    }

    @Test("a departing editor cannot synchronize another session's draft")
    func departingEditorUpdateCannotEraseAcceptedDraft() async throws {
        let root = try root()
        let suite = "recovery319-departing-update-\(UUID().uuidString)"
        let chat = try chat(root, suite: suite)
        let directory = root.appendingPathComponent("draft-store")
        let drafts = DraftStore(directory: directory)
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession()
        chat.attachDraftStore(drafts)
        defer {
            for id in [a, b] { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: id)) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try #require(chat.applySwitchSession(id: a))
        let accepted = "A accepted before switching"
        chat.draftText = accepted
        let aKey = DraftStore.chatDraftKey(sessionID: a)
        let bKey = DraftStore.chatDraftKey(sessionID: b)
        try #require(drafts.flushNow(key: aKey))
        #expect(DraftStore(directory: directory).load(key: aKey) == Data(accepted.utf8))

        let aField = nativeField(for: chat)
        let aCoordinator = aField.makeCoordinator()
        let aEditor = ComposerPasteAwareTextView(frame: .zero)
        aEditor.string = aField.text
        aEditor.delegate = aCoordinator
        aCoordinator.rememberFocusedDraft(in: aEditor)
        try #require(aEditor.string == accepted)
        try #require(chat.applySwitchSession(id: b))
        #expect(chat.draftText.isEmpty)

        // The old representable can update before its own view is dismantled.
        // Drive the same synchronization entry used by updateNSView.
        aField.synchronizeMountedDraft(in: aEditor, coordinator: aCoordinator)
        #expect(aEditor.string == accepted)
        await aCoordinator.retire(aEditor)?.value
        #expect(chat.draftText.isEmpty)
        let reopened = DraftStore(directory: directory)
        #expect(reopened.load(key: aKey) == Data(accepted.utf8))
        #expect(reopened.load(key: bKey) == nil)
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText == accepted)

        // An empty native snapshot is not itself a clear. Exercise both
        // transition reads while the current store still holds accepted A.
        let emptySnapshotCoordinator = nativeField(for: chat).makeCoordinator()
        let emptySnapshotEditor = ComposerPasteAwareTextView(frame: .zero)
        emptySnapshotEditor.delegate = emptySnapshotCoordinator
        emptySnapshotCoordinator.rememberFocusedDraft(in: emptySnapshotEditor)
        try #require(chat.applySwitchSession(id: b))
        await emptySnapshotCoordinator.retire(emptySnapshotEditor)?.value
        #expect(chat.draftText.isEmpty)
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText == accepted)
        #expect(DraftStore(directory: directory).load(key: aKey) == Data(accepted.utf8))

        // A genuine empty edit from the current editor still clears the draft.
        let currentCoordinator = nativeField(for: chat).makeCoordinator()
        acceptNativeEdit("A will be cleared", through: currentCoordinator)
        try #require(drafts.flushNow(key: aKey))
        acceptNativeEdit("", through: currentCoordinator)
        #expect(chat.draftText.isEmpty)
        #expect(DraftStore(directory: directory).load(key: aKey) == nil)
    }

    @Test("switch flushes the focused native draft before selecting the new session",
          arguments: [false, true])
    func switchFlushesFocusedNativeDraft(lateBeforeNewMount: Bool) async throws {
        let root = try root()
        let suite = "recovery319-preswitch-\(UUID().uuidString)"
        let chat = try chat(root, suite: suite)
        let directory = root.appendingPathComponent("draft-store")
        let drafts = DraftStore(directory: directory)
        let sessionStore = SessionStore(directory: root.appendingPathComponent("session-store"))
        try #require(chat.attachPersistence(sessionStore))
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession()
        chat.attachDraftStore(drafts)
        defer {
            for id in [a, b] { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: id)) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try #require(chat.applySwitchSession(id: a))
        let aCoordinator = nativeField(for: chat).makeCoordinator()
        let aEditor = ComposerPasteAwareTextView(frame: .zero)
        aEditor.string = "A before failed archive"
        aEditor.delegate = aCoordinator
        aCoordinator.rememberFocusedDraft(in: aEditor)
        #expect(chat.draftText.isEmpty)

        try Data("archive directory blocker".utf8).write(
            to: sessionStore.sessionsDirectory.appendingPathComponent("_archive")
        )
        chat.archiveSession(id: a)
        try #require(chat.activeSessionID == a)
        #expect(chat.draftText == "A before failed archive")

        aEditor.delegate = nil
        aEditor.string = "token=syntheticfixture"
        aEditor.delegate = aCoordinator
        chat.archiveSession(id: a)
        try #require(chat.activeSessionID == a)
        let credentialRequest = try #require(chat.credentialBroker.pending)
        #expect(credentialRequest.sessionID == a)
        #expect(aEditor.string == chat.draftText)
        #expect(!aEditor.string.contains("syntheticfixture"))
        chat.archiveSession(id: a)
        #expect(chat.credentialBroker.pending?.id == credentialRequest.id)

        aEditor.delegate = nil
        aEditor.string = "A pending native edit"
        aEditor.delegate = aCoordinator

        try #require(chat.applySwitchSession(id: b))
        #expect(chat.draftText.isEmpty)
        let aKey = DraftStore.chatDraftKey(sessionID: a)
        let bKey = DraftStore.chatDraftKey(sessionID: b)
        let reopened = DraftStore(directory: directory)
        #expect(reopened.load(key: aKey) == Data("A pending native edit".utf8))
        #expect(reopened.load(key: bKey) == nil)

        let oldChange = Notification(name: NSText.didChangeNotification, object: aEditor)
        if lateBeforeNewMount { aCoordinator.textDidChange(oldChange) }
        let bCoordinator = nativeField(for: chat).makeCoordinator()
        if !lateBeforeNewMount { aCoordinator.textDidChange(oldChange) }
        await aCoordinator.retire(aEditor)?.value
        aCoordinator.textDidChange(oldChange)
        #expect(chat.draftText.isEmpty)
        acceptNativeEdit("B independent", through: bCoordinator)
        #expect(chat.draftText == "B independent")
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText == "A pending native edit")
    }

    @Test("a native notification during rebinding belongs to the mounted draft",
          arguments: [false, true])
    func nativeNotificationDuringSessionSwitch(wasAcceptedBeforeSwitch: Bool) throws {
        let root = try root()
        let suite = "recovery319-switch-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let chat = try chat(root, suite: suite)
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession()
        try #require(chat.applySwitchSession(id: a))

        let aField = nativeField(for: chat)
        let coordinator = aField.makeCoordinator()
        let editor = ComposerPasteAwareTextView(frame: .zero)
        editor.string = "abc"
        editor.delegate = coordinator
        let change = Notification(name: NSText.didChangeNotification, object: editor)
        if wasAcceptedBeforeSwitch {
            coordinator.textDidChange(change)
            #expect(chat.draftText == "abc")
        }

        // ChatStore advances the selected session before SwiftUI updates the
        // existing editor. Deliver its old text in that exact interval.
        try #require(chat.applySwitchSession(id: b))
        #expect(chat.draftText.isEmpty)
        coordinator.textDidChange(change)
        #expect(chat.draftText.isEmpty)

        let bField = nativeField(for: chat)
        coordinator.synchronizeDraft(bField.text, sessionID: bField.draftSessionID, in: editor)
        coordinator.parent = bField
        #expect(editor.string.isEmpty)
        editor.delegate = nil
        editor.string = "B native edit"
        editor.delegate = coordinator
        coordinator.textDidChange(change)
        #expect(chat.draftText == "B native edit")

        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText == "abc")
        try #require(chat.applySwitchSession(id: b))
        #expect(chat.draftText == "B native edit")

        // An explicit clear accepted after A was mounted takes precedence
        // over the old native text delivered after leaving A again.
        try #require(chat.applySwitchSession(id: a))
        let staleEditor = nativeField(for: chat).makeCoordinator()
        chat.draftText = ""
        try #require(chat.applySwitchSession(id: b))
        acceptNativeEdit("abc", through: staleEditor)
        #expect(chat.draftText == "B native edit")
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText.isEmpty)

        // A later clear is an accepted edit even if A was already empty.
        let editorMountedOnEmpty = nativeField(for: chat).makeCoordinator()
        chat.draftText = ""
        try #require(chat.applySwitchSession(id: b))
        acceptNativeEdit("abc", through: editorMountedOnEmpty)
        #expect(chat.draftText == "B native edit")
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText.isEmpty)
    }

    @Test("retiring a native editor settles only unmarked text to its departed session",
          arguments: [false, true])
    func retiredEditorCannotWriteIntoNewMount(hasMarkedText: Bool) async throws {
        let root = try root()
        let suite = "recovery319-retire-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let chat = try chat(root, suite: suite)
        let a = try #require(chat.activeSessionID)
        let b = chat.applyNewSession()
        try #require(chat.applySwitchSession(id: a))
        chat.draftText = "A committed"

        let aCoordinator = nativeField(for: chat).makeCoordinator()
        let aEditor = ComposerPasteAwareTextView(frame: .zero)
        aEditor.string = hasMarkedText ? "A committed" : "A committed plus unmarked edit"
        if hasMarkedText {
            aEditor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: aEditor.string.utf16.count, length: 0))
            try #require(aEditor.hasMarkedText())
        }
        aEditor.delegate = aCoordinator

        try #require(chat.applySwitchSession(id: b))
        let bCoordinator = nativeField(for: chat).makeCoordinator()
        let bEditor = ComposerPasteAwareTextView(frame: .zero)
        bEditor.delegate = bCoordinator

        let retirement = aCoordinator.retire(aEditor)
        #expect((retirement == nil) == hasMarkedText)
        #expect(aEditor.delegate == nil)
        #expect(!aEditor.hasMarkedText())
        #expect(chat.draftText.isEmpty)
        aEditor.string = "late text from retired A"
        aCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: aEditor))
        #expect(chat.draftText.isEmpty)

        bEditor.delegate = nil
        bEditor.string = "B native edit"
        bEditor.delegate = bCoordinator
        bCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: bEditor))
        await retirement?.value
        #expect(chat.draftText == "B native edit")
        bEditor.delegate = nil
        bEditor.string = "unaccepted same-session teardown"
        bEditor.delegate = bCoordinator
        #expect(bCoordinator.retire(bEditor) == nil)
        #expect(chat.draftText == "B native edit")

        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText == (hasMarkedText ? "A committed" : "A committed plus unmarked edit"))

        chat.draftText = ""
        let clearCoordinator = nativeField(for: chat).makeCoordinator()
        let clearEditor = ComposerPasteAwareTextView(frame: .zero)
        clearEditor.string = "older unmarked text"
        try #require(chat.applySwitchSession(id: b))
        let pendingRetirement = try #require(clearCoordinator.retire(clearEditor))
        try #require(chat.applySwitchSession(id: a))
        chat.draftText = ""
        try #require(chat.applySwitchSession(id: b))
        await pendingRetirement.value
        #expect(chat.draftText == "B native edit")
        try #require(chat.applySwitchSession(id: a))
        #expect(chat.draftText.isEmpty)
    }

    @Test("accepted native edits recover to their original sessions after both stores reopen")
    func nativeDelegateTwoSessionReopen() throws {
        let root = try root()
        let suite = "recovery319-native-\(UUID().uuidString)"
        let drafts = DraftStore(directory: root.appendingPathComponent("draft-store"))
        drafts.debounceInterval = .seconds(30)
        let first = try chat(root, suite: suite)
        #expect(first.attachPersistence(SessionStore(directory: root.appendingPathComponent("sessions"))))
        first.attachDraftStore(drafts)
        defer {
            for session in first.sessions { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id)) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let a = try #require(first.activeSessionID)
        let delegate = editor(first)
        acceptNativeEdit("A native unsent", through: delegate)
        #expect(first.draftText == "A native unsent")
        let b = first.applyNewSession()
        #expect(first.draftText.isEmpty)
        acceptNativeEdit("B native unsent", through: delegate)
        #expect(first.applySwitchSession(id: a))
        #expect(first.draftText == "A native unsent")
        #expect(first.applySwitchSession(id: b))
        #expect(first.draftText == "B native unsent")
        #expect(drafts.flushAll())

        let reopenedDrafts = DraftStore(directory: drafts.directory)
        reopenedDrafts.debounceInterval = .seconds(30)
        let reopened = try chat(root, suite: suite)
        #expect(reopened.attachPersistence(SessionStore(directory: root.appendingPathComponent("sessions"))))
        reopened.attachDraftStore(reopenedDrafts)
        defer {
            for session in reopened.sessions {
                reopenedDrafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id))
            }
        }
        #expect(reopened.applySwitchSession(id: a))
        #expect(reopened.draftText == "A native unsent")
        #expect(reopened.applySwitchSession(id: b))
        #expect(reopened.draftText == "B native unsent")
    }

    @Test("native visible text without a change notification is not an accepted draft")
    func visibleTextAndAcceptedDraftAreDistinct() throws {
        let root = try root()
        let suite = "recovery319-notification-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let chat = try chat(root, suite: suite)
        let original = try #require(chat.activeSessionID)
        let delegate = editor(chat)
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = "visible only"
        #expect(textView.string == "visible only")
        #expect(chat.draftText.isEmpty)
        let other = chat.applyNewSession()
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText.isEmpty)

        delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(chat.draftText == "visible only")
        #expect(chat.applySwitchSession(id: other))
        #expect(chat.draftText.isEmpty)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText == "visible only")
    }

    @Test("failed short and coalesced long writes retain edits and retry the original key", arguments: [false, true])
    func failedWriteRetainsLatestSessionValue(isLong: Bool) throws {
        let root = try root()
        let suite = "recovery319-write-\(UUID().uuidString)"
        let draftRoot = root.appendingPathComponent("draft-store", isDirectory: true)
        try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true)
        let blocker = draftRoot.appendingPathComponent("drafts")
        try Data("synthetic non-directory".utf8).write(to: blocker)
        let drafts = DraftStore(directory: draftRoot)
        drafts.debounceInterval = .seconds(30)
        let chat = try chat(root, suite: suite)
        chat.attachDraftStore(drafts)
        let original = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: original)
        defer {
            for session in chat.sessions { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id)) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let value = isLong ? String(repeating: "长", count: 2_000) + "latest" : "short latest"
        acceptNativeEdit(value, through: editor(chat))
        let other = chat.applyNewSession()
        #expect(drafts.lastIOError(for: key) == .unsafe)
        #expect(chat.draftText.isEmpty)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText == value)
        #expect(drafts.latestPayload(for: key) == Data(value.utf8))
        #expect(drafts.lastIOError(for: key) == .unsafe)
        #expect(chat.draftPersistenceFeedback != nil)
        #expect(chat.draftPersistenceFeedback?.contains(root.path) == false)

        // Repair only this synthetic fixture. Existing switch/long-draft
        // boundaries must retry; retaining memory is not a successful save.
        try FileManager.default.removeItem(at: blocker)
        #expect(chat.applySwitchSession(id: other))
        #expect(String(data: try #require(drafts.load(key: key)), encoding: .utf8) == value)
        #expect(drafts.lastIOError(for: key) == nil)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText == value)
        #expect(chat.draftPersistenceFeedback == nil)
    }

    @Test("an explicit empty draft survives a failed clear and retries without reviving old disk text")
    func failedClearDoesNotReviveOldDraft() throws {
        let root = try root()
        let suite = "recovery319-clear-\(UUID().uuidString)"
        let drafts = DraftStore(directory: root.appendingPathComponent("draft-store"))
        drafts.debounceInterval = .seconds(30)
        let chat = try chat(root, suite: suite)
        chat.attachDraftStore(drafts)
        let original = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: original)
        defer {
            for session in chat.sessions { drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id)) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        acceptNativeEdit("old persisted text", through: editor(chat))
        #expect(drafts.flushNow(key: key))
        let file = drafts.draftsDirectory.appendingPathComponent("\(key).json")
        let saved = drafts.draftsDirectory.appendingPathComponent("old-fixture.json")
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        acceptNativeEdit("", through: editor(chat))
        #expect(drafts.lastIOError(for: key) == .unsafe)
        let other = chat.applyNewSession()
        #expect(drafts.lastIOError(for: key) == .unsafe)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback != nil)
        #expect(drafts.latestPayload(for: key) == nil)
        #expect(chat.applySwitchSession(id: other))
        #expect(!drafts.hasDraft(key: key))
        #expect(drafts.lastIOError(for: key) == nil)
        #expect(chat.applySwitchSession(id: original))
        #expect(chat.draftPersistenceFeedback == nil)
    }

    @Test("native edits made before draft-store assembly take precedence and become durable")
    func preAssemblyNativeDraftPersists() throws {
        let root = try root()
        let suite = "recovery319-assembly-\(UUID().uuidString)"
        let drafts = DraftStore(directory: root.appendingPathComponent("draft-store"))
        drafts.debounceInterval = .seconds(30)
        let chat = try chat(root, suite: suite)
        let original = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: original)
        defer {
            drafts.cancelPending(key: key)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        drafts.scheduleSave(key: key, payload: Data("older disk text".utf8))
        #expect(drafts.flushNow(key: key))
        acceptNativeEdit("latest before assembly", through: editor(chat))
        chat.attachDraftStore(drafts)
        #expect(chat.draftText == "latest before assembly")
        #expect(drafts.latestPayload(for: key) == Data("latest before assembly".utf8))
        #expect(drafts.flushNow(key: key))
        let reopened = DraftStore(directory: drafts.directory)
        #expect(String(data: try #require(reopened.load(key: key)), encoding: .utf8) == "latest before assembly")
    }
}
