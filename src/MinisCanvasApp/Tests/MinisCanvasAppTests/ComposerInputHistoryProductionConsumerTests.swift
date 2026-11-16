import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N04 scoped input history production consumers", .serialized)
@MainActor
struct ComposerInputHistoryProductionConsumerTests {
    @Test func queuedDeleteDuringGenerationRemovesOnlyOwnedTargetWithoutDispatch() async throws {
        try #require(NSApplication.shared.isRunning)
        let f = try fixture()
        defer { f.chat.stopAllStreamingForSafety(); try? f.profile.cleanupDisposableRoots() }
        let drafts = DraftStore(directory: f.profile.rootDirectory.appendingPathComponent("queue-drafts"))
        f.chat.attachDraftStore(drafts)
        f.chat.newMessageInterruptsGeneration = { false }
        let engine = CapturingChatEngine()
        engine.streamDelay = .seconds(30)
        f.chat.agentEngine = engine
        f.chat.draftText = "owned active request"
        f.chat.submitComposer()
        for _ in 0..<100 {
            if f.chat.isActiveSessionGenerating && engine.calls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(f.chat.isActiveSessionGenerating && engine.calls.count == 1)
        let session = try #require(f.chat.activeSessionID)
        let identity = try #require(f.chat.executionSnapshot(forSessionID: session)?.executionIdentity)
        let userIDs = f.chat.messages.filter { $0.role == .user }.map(\.id)
        for text in ["queued owned A", "queued owned B", "queued owned C"] {
            f.chat.draftText = text
            try #require(f.chat.enqueueComposer())
        }
        let queued = f.chat.activeQueuedComposerMessages
        try #require(queued.map(\.text) == ["queued owned A", "queued owned B", "queued owned C"])
        try #require(try ComposerQueuePersistence.load(using: drafts) == queued)

        let controller = NSHostingController(rootView: ComposerQueuedMessagesView(chat: f.chat))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("N04-QueuedDelete")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 440))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        let consumer = SettingsNativeInteractionConsumerTests()
        consumer.pumpSettingsRunLoop()
        try #require(window.isVisible && window.isKeyWindow && NSApplication.shared.isActive)
        let disclosure = try #require(NativeConsumerOwnedAX.find(in: window, label: "管理排队消息"))
        try #require(consumer.settingsAXPress(disclosure, in: window))
        consumer.pumpSettingsRunLoop()

        let targetID = queued[1].id.uuidString
        let rowID = "composer.queue-management.row.\(targetID)"
        let deleteID = "composer.queue-management.delete.\(targetID)"
        var row = try #require(NativeConsumerOwnedAX.findDisplayedText(in: window, exactText: queued[1].text),
            "Owned B text must be present before locating its row")
        for _ in 0..<8 {
            let identifier = NativeConsumerOwnedAX.attribute(row, kAXIdentifierAttribute as CFString) as? String
            if identifier == rowID || NativeConsumerOwnedAX.role(row) == .window { break }
            guard let parent = NativeConsumerOwnedAX.attribute(row, kAXParentAttribute as CFString) else { break }
            row = parent
        }
        try #require((NativeConsumerOwnedAX.attribute(row, kAXIdentifierAttribute as CFString) as? String) == rowID,
            "Owned B text must belong to its identified queue row")

        var nodes = [row]
        var deleteButtons: [AnyObject] = []
        var visited = 0
        while !nodes.isEmpty && visited < 64 {
            let node = nodes.removeFirst()
            visited += 1
            let identifier = NativeConsumerOwnedAX.attribute(node, kAXIdentifierAttribute as CFString) as? String
            if identifier == deleteID && NativeConsumerOwnedAX.role(node) == .button
                && NativeConsumerOwnedAX.label(node) == "删除" {
                deleteButtons.append(node)
            }
            if let children = NativeConsumerOwnedAX.attribute(node, kAXChildrenAttribute as CFString) as? [AnyObject] {
                nodes.append(contentsOf: children)
            }
        }
        try #require(nodes.isEmpty && deleteButtons.count == 1,
            "Owned B row must expose exactly one native delete button")
        let button = try #require(NativeConsumerOwnedAX.element(deleteButtons[0]))
        var actionNames: CFArray?
        let actionStatus = AXUIElementCopyActionNames(button, &actionNames)
        try #require(actionStatus == .success && (actionNames as? [String])?.contains(kAXPressAction as String) == true,
            "Owned B delete button must expose AXPress")
        try #require(NativeConsumerOwnedAX.press(deleteButtons[0]))
        consumer.pumpSettingsRunLoop()

        let remaining = [queued[0], queued[2]]
        #expect(f.chat.activeQueuedComposerMessages.map(\.id) == remaining.map(\.id))
        #expect(try ComposerQueuePersistence.load(using: drafts) == remaining)
        #expect(f.chat.activeSessionID == session && f.chat.isActiveSessionGenerating)
        #expect(f.chat.executionSnapshot(forSessionID: session)?.executionIdentity == identity)
        #expect(engine.calls.count == 1 && f.chat.messages.filter { $0.role == .user }.map(\.id) == userIDs)
        #expect(f.chat.draftText.isEmpty && f.chat.pendingAttachments.isEmpty && f.chat.activePastedTextDrafts.isEmpty)
    }

    @Test func queuedEditDuringGenerationRetractsOnlyOwnedTargetWithoutDispatch() async throws {
        try #require(NSApplication.shared.isRunning)
        let f = try fixture()
        defer { f.chat.stopAllStreamingForSafety(); try? f.profile.cleanupDisposableRoots() }
        let drafts = DraftStore(directory: f.profile.rootDirectory.appendingPathComponent("queue-drafts"))
        f.chat.attachDraftStore(drafts)
        f.chat.newMessageInterruptsGeneration = { false }
        let engine = CapturingChatEngine()
        engine.streamDelay = .seconds(30)
        f.chat.agentEngine = engine
        f.chat.draftText = "owned active request"
        f.chat.submitComposer()
        for _ in 0..<100 {
            if f.chat.isActiveSessionGenerating && engine.calls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(f.chat.isActiveSessionGenerating && engine.calls.count == 1)
        let session = try #require(f.chat.activeSessionID)
        let identity = try #require(f.chat.executionSnapshot(forSessionID: session)?.executionIdentity)
        let snapshot = try #require(f.chat.lastComposerSubmissionSnapshot)
        let selection = f.chat.composerPolicySelection
        let userID = try #require(f.chat.messages.first(where: { $0.role == .user })?.id)
        let userCount = f.chat.messages.filter { $0.role == .user }.count
        f.chat.draftText = "queued owned A"
        #expect(f.chat.enqueueComposer())
        let file = f.profile.rootDirectory.appendingPathComponent("owned-reference.bin")
        try Data("owned attachment".utf8).write(to: file)
        _ = f.chat.addAttachments(urls: [file])
        let paste = PastedTextDraft(id: UUID(), text: "owned queued reference", source: .typing, kind: .reference)
        #expect(f.chat.setPastedTextDraft(paste))
        f.chat.draftText = "queued owned B"
        #expect(f.chat.enqueueComposer())
        f.chat.draftText = "queued owned C"
        #expect(f.chat.enqueueComposer())
        let queued = f.chat.activeQueuedComposerMessages
        try #require(queued.count == 3 && queued[1].attachments.count == 1)
        #expect(queued[1].pastedDrafts == [paste])
        #expect(try ComposerQueuePersistence.load(using: drafts) == queued)

        let controller = NSHostingController(rootView: ComposerQueuedMessagesView(chat: f.chat))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("N04-QueuedEdit")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 440))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        let consumer = SettingsNativeInteractionConsumerTests()
        consumer.pumpSettingsRunLoop()
        try #require(window.isVisible && window.isKeyWindow && NSApplication.shared.isActive)
        let disclosure = try #require(NativeConsumerOwnedAX.find(in: window, label: "管理排队消息"))
        #expect(consumer.settingsAXPress(disclosure, in: window))
        consumer.pumpSettingsRunLoop()

        // Bound the public AX walk to this owned text's ancestors. Never pick
        // an arbitrary edit button from the three queued messages.
        @MainActor func editControl(for text: String) throws -> AnyObject {
            var ancestor: AnyObject = try #require(NativeConsumerOwnedAX.findDisplayedText(in: window, exactText: text))
            for _ in 0..<8 {
                var nodes: [(AnyObject, Int)] = [(ancestor, 0)]
                var edits: [AnyObject] = []
                var visited = 0
                while !nodes.isEmpty && visited < 64 {
                    let (node, depth) = nodes.removeFirst()
                    visited += 1
                    if NativeConsumerOwnedAX.role(node) == .button && NativeConsumerOwnedAX.label(node) == "编辑" {
                        edits.append(node)
                    }
                    if depth < 4, let children = NativeConsumerOwnedAX.attribute(node, kAXChildrenAttribute as CFString) as? [AnyObject] {
                        nodes.append(contentsOf: children.map { ($0, depth + 1) })
                    }
                }
                if nodes.isEmpty && edits.count == 1 { return edits[0] }
                if NativeConsumerOwnedAX.role(ancestor) == .window { break }
                guard let parent = NativeConsumerOwnedAX.attribute(ancestor, kAXParentAttribute as CFString) else { break }
                ancestor = parent
            }
            Issue.record("Owned queued row did not expose exactly one edit button")
            throw CocoaError(.fileReadUnknown)
        }
        let initialEdit = try editControl(for: queued[1].text)
        #expect(NativeConsumerOwnedAX.enabled(initialEdit) == true)
        let sendNext = try #require(NativeConsumerOwnedAX.find(in: window, label: "发送下一条", pressable: true))
        #expect(NativeConsumerOwnedAX.enabled(sendNext) == false)
        f.chat.draftText = "occupied draft"
        consumer.pumpSettingsRunLoop()
        let draftBlocked = try editControl(for: queued[1].text)
        #expect(NativeConsumerOwnedAX.enabled(draftBlocked) == false)
        f.chat.draftText = ""
        _ = f.chat.addAttachments(urls: [file])
        try #require(f.chat.pendingAttachments.count == 1)
        consumer.pumpSettingsRunLoop()
        let attachmentBlocked = try editControl(for: queued[1].text)
        #expect(NativeConsumerOwnedAX.enabled(attachmentBlocked) == false)
        f.chat.clearPendingAttachments()
        #expect(f.chat.setPastedTextDraft(paste))
        consumer.pumpSettingsRunLoop()
        let pasteBlocked = try editControl(for: queued[1].text)
        #expect(NativeConsumerOwnedAX.enabled(pasteBlocked) == false)
        #expect(f.chat.clearPastedTextDraft())
        consumer.pumpSettingsRunLoop()
        let edit = try editControl(for: queued[1].text)
        #expect(NativeConsumerOwnedAX.enabled(edit) == true)
        #expect(consumer.settingsAXPress(edit, in: window))
        #expect(f.chat.draftText == queued[1].text)
        #expect(f.chat.pendingAttachments == queued[1].attachments)
        #expect(f.chat.activePastedTextDrafts == queued[1].pastedDrafts)
        let remaining = [queued[0], queued[2]]
        #expect(f.chat.activeQueuedComposerMessages == remaining)
        #expect(try ComposerQueuePersistence.load(using: drafts) == remaining)
        #expect(f.chat.isActiveSessionGenerating)
        #expect(f.chat.executionSnapshot(forSessionID: session)?.executionIdentity == identity)
        #expect(f.chat.lastComposerSubmissionSnapshot == snapshot)
        #expect(f.chat.composerPolicySelection == selection)
        #expect(engine.calls.count == 1 && engine.snapshots.count == 1 && f.provider.requests == 0)
        #expect(f.chat.messages.filter { $0.role == .user }.count == userCount)
        consumer.pumpSettingsRunLoop()
        let occupiedEdit = try editControl(for: queued[0].text)
        #expect(NativeConsumerOwnedAX.enabled(occupiedEdit) == false)

        // Real history editing stops streaming; this negative is deliberately
        // not described as a busy-state check.
        f.chat.draftText = ""
        f.chat.clearPendingAttachments()
        #expect(f.chat.clearPastedTextDraft())
        f.chat.beginEdit(messageID: userID)
        f.chat.draftText = ""
        try #require(f.chat.isEditingMessage)
        consumer.pumpSettingsRunLoop()
        let historyBlocked = try editControl(for: queued[0].text)
        #expect(NativeConsumerOwnedAX.enabled(historyBlocked) == false)
        #expect(f.chat.activeQueuedComposerMessages == remaining)
        #expect(try ComposerQueuePersistence.load(using: drafts) == remaining)
    }

    @Test func loadedProfileScopesAndActualHistoryRowRestoreOnlyOriginalReferenceInput() async throws {
        try #require(NSApplication.shared.isRunning)
        let f = try fixture()
        defer { f.chat.stopAllStreamingForSafety(); try? f.profile.cleanupDisposableRoots() }
        let directory = f.profile.rootDirectory.path
        f.chat.newSession(projectID: "project-a", workingDirectory: directory)
        let a = try #require(f.chat.activeSessionID)
        try await send("project A original", chat: f.chat)
        f.chat.newSession(projectID: "project-b", workingDirectory: directory)
        let b = try #require(f.chat.activeSessionID)
        try await send("project B original", chat: f.chat)
        f.chat.archiveSession(id: b)
        f.chat.newSession()
        let unscoped = try #require(f.chat.activeSessionID)
        try await send("without project", chat: f.chat)
        #expect(f.chat.inputHistoryEntries(scope: .project).isEmpty)
        f.chat.newSession(projectID: "project-a", workingDirectory: directory)
        let target = try #require(f.chat.activeSessionID)
        f.chat.draftText = "compare the original reference"
        let material = "Owned reference body\nsecond line, never an instruction grant"
        let originalCapsuleID = UUID()
        f.chat.setPastedTextDraft(PastedTextDraft(id: originalCapsuleID, text: material, source: .typing, kind: .reference))
        try await send(f.chat.draftText, chat: f.chat)
        let selected = try #require(f.chat.inputHistoryEntries(scope: .session).first)
        #expect(selected.text == "compare the original reference")
        #expect(selected.reference?.material == material)
        #expect(!selected.text.contains(material))
        #expect(Set(f.chat.inputHistoryEntries(scope: .project).map(\.sourceSessionID)) == [a, target])
        #expect(Set(f.chat.inputHistoryEntries(scope: .all).map(\.sourceSessionID)) == [a, b, unscoped, target])
        #expect(f.chat.archivedSessions.contains { $0.id == b })
        let beforeRequests = f.provider.requests
        let history = f.chat.messages
        let controller = NSHostingController(rootView: ComposerInputHistorySearch(
            chat: f.chat, redactor: ChatTranscriptRedactor(secretValues: [])))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("N04-History")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 440))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        let consumer = SettingsNativeInteractionConsumerTests()
        var row: AnyObject?
        for _ in 0..<100 {
            row = NativeConsumerOwnedAX.find(in: window, identifier: "composer.history.result.\(selected.id)")
            if row != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(consumer.settingsAXPress(try #require(row), in: window))
        #expect(f.chat.activeSessionID == target && f.chat.messages == history)
        #expect(f.chat.draftText == selected.text)
        let restored = try #require(f.chat.activePastedTextDraft)
        #expect(restored.text == material && restored.kind == selected.reference?.kind)
        #expect(restored.id != originalCapsuleID)
        #expect(f.chat.pendingAttachments.isEmpty && f.chat.activeQueuedComposerMessages.isEmpty)
        #expect(f.provider.requests == beforeRequests)
    }

    @Test func changedSourceOwnerOrDraftCannotOverwriteAndQueuedInputKeepsArrowPriority() async throws {
        let f = try fixture()
        defer { f.chat.stopAllStreamingForSafety(); try? f.profile.cleanupDisposableRoots() }
        try await send("first original instruction", chat: f.chat)
        let session = try #require(f.chat.activeSessionID)
        let entry = try #require(f.chat.inputHistoryEntries(scope: .session).first)
        let draft = ComposerEditDraftIdentity.capture(f.chat)
        let owner = try #require(f.chat.sessionStore)
        let foreign = SessionStore(directory: f.profile.rootDirectory.appendingPathComponent("other-owned-sessions"))
        #expect(!f.chat.recallInputHistory(entry, scope: .session, expectedSessionID: session,
            expectedStore: foreign, expectedDraft: draft))
        f.chat.draftText = "new unsent user text"
        #expect(!f.chat.recallInputHistory(entry, scope: .session, expectedSessionID: session,
            expectedStore: owner, expectedDraft: draft))
        #expect(f.chat.draftText == "new unsent user text")
        f.chat.draftText = ""
        try await send("second original instruction", chat: f.chat)
        let freshDraft = ComposerEditDraftIdentity.capture(f.chat)
        let history = f.chat.messages
        #expect(!f.chat.recallInputHistory(entry, scope: .session, expectedSessionID: session,
            expectedStore: owner, expectedDraft: freshDraft))
        #expect(f.chat.draftText.isEmpty && f.chat.messages == history)
        f.chat.draftText = "queued original instruction"
        #expect(f.chat.enqueueComposer())
        let queued = f.chat.activeQueuedComposerMessages
        let current = try #require(f.chat.inputHistoryEntries(scope: .session).first)
        #expect(f.chat.recallInputHistory(current, scope: .session, expectedSessionID: session,
            expectedStore: owner, expectedDraft: ComposerEditDraftIdentity.capture(f.chat)))
        #expect(f.chat.activeQueuedComposerMessages == queued)
        f.chat.draftText = ""
        #expect(f.chat.handleInputHistoryKey(.up))
        #expect(f.chat.draftText == "queued original instruction" && f.chat.activeQueuedComposerMessages.isEmpty)
        #expect(f.chat.messages == history && f.provider.requests == 2)
    }

    @Test func currentRegisteredChordReachesTheMainComposerAndMarkedTextDoesNotOpenHistory() async throws {
        try #require(NSApplication.shared.isRunning)
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "N04-main-history-key",
            processEnvironment: [:], processArguments: ["ComposerInputHistoryProductionConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        let manual = ShortcutBinding(key: "r", modifiers: .commandShift)
        #expect(ShortcutStore(defaults: defaults).binding(for: .inputHistorySearch) == manual)
        // A real old persisted manual mapping must survive introduction of a new default.
        defaults.set(try JSONEncoder().encode([ShortcutAction.focusComposer.id: manual]),
            forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
        let shortcuts = ShortcutStore(defaults: defaults)
        #expect(shortcuts.binding(for: .focusComposer) == manual)
        #expect(shortcuts.binding(for: .inputHistorySearch).isEmpty)
        #expect(shortcuts.setBinding(manual, for: .inputHistorySearch) != nil)
        let custom = ShortcutBinding(key: "h", modifiers: ShortcutModifiers(control: true, shift: true))
        #expect(shortcuts.setBinding(custom, for: .inputHistorySearch) == nil)
        let root = profile.rootDirectory
        let keychain = profile.makeKeychainStore()
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: profile.makeLogManager(), workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: SessionStore(directory: profile.sessionDirectory), canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(), memoryStore: MemoryStore(directory: profile.memoryDirectory),
            commandEnvStore: profile.makeEnvironmentStore(keychain: keychain),
            canonicalMCPManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")),
            canvasFeatureLane: .phase3NonCanvas)
        let controller = NSHostingController(rootView: GlobalComposerView(bridge: bridge, chat: bridge.chat, mainPane: .chat))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("N04-MainComposer")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        func input(in view: NSView) -> ComposerPasteAwareTextView? {
            if let text = view as? ComposerPasteAwareTextView { return text }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        var native: ComposerPasteAwareTextView?
        for _ in 0..<100 {
            native = input(in: controller.view)
            if native != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try #require(native)
        try #require(NSApplication.shared.isActive && window.isKeyWindow,
            "The existing native host must own this active key window before shortcut delivery")
        #expect(text.historySearchBinding == custom)
        try #require(window.makeFirstResponder(text))
        try #require(window.firstResponder === text)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "H", charactersIgnoringModifiers: "H", isARepeat: false, keyCode: 4))
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        window.sendEvent(event)
        SettingsNativeInteractionConsumerTests().pumpSettingsRunLoop()
        #expect(window.attachedSheet == nil)
        text.unmarkText()
        text.string = ""
        let preservedDraft = bridge.chat.draftText
        try #require(NSApplication.shared.isActive && window.isKeyWindow)
        try #require(window.makeFirstResponder(text))
        try #require(window.firstResponder === text)
        window.sendEvent(event)
        for _ in 0..<100 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try #require(window.attachedSheet, "Current registered chord must open the real main Composer history sheet")
        _ = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "composer.history.search"))
        #expect(!bridge.chat.isActiveSessionGenerating && bridge.chat.activeQueuedComposerMessages.isEmpty)
        #expect(bridge.chat.draftText == preservedDraft)
    }

    private func fixture() throws -> (profile: RuntimeIsolationProfile, chat: ChatStore, provider: N04HistoryProvider) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "N04-history",
            processEnvironment: [:], processArguments: ["ComposerInputHistoryProductionConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory),
            badgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "N04-owned", grantEpoch: "N04-owned",
            leaseID: "N04-owned", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection.mode = .plan
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:N04-owned")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil,
                providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box), requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        let provider = N04HistoryProvider()
        chat.streamingProviderOverride = provider
        return (profile, chat, provider)
    }
    private func send(_ text: String, chat: ChatStore) async throws {
        chat.draftText = text
        let session = try #require(chat.activeSessionID)
        chat.submitComposer()
        let turn = try #require(chat.turnTaskForTests(sessionID: session))
        await turn.value
        #expect(chat.messages.last(where: { $0.role == .assistant })?.content == "## 计划\nOwned history answer")
    }
}

private final class N04HistoryProvider: LLMProvider, @unchecked Sendable {
    let name = "N04-owned"
    var model = LLMModel(id: "N04-owned", displayName: "Owned history", provider: "N04-owned")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> LLMResponse {
        lock.withLock { count += 1 }
        return LLMResponse(text: "## 计划\nOwned history answer", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
