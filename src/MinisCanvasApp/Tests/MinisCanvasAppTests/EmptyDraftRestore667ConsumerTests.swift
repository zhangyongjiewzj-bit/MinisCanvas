import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMPOSER-01 / D-RECOVERY-02 empty recovery is not an edit")
@MainActor
struct EmptyDraftRestore667ConsumerTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let sessions: URL
        let defaults: UserDefaults

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("empty-draft667-\(UUID().uuidString)", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: sessions, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let requiredDefaults = UserDefaults(suiteName: "empty-draft667-\(UUID().uuidString)")
            defaults = try #require(requiredDefaults)
        }

        func chat() -> ChatStore {
            ChatStore(
                preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("logs"))
            )
        }

        func attachPersistence(to chat: ChatStore) -> Bool {
            chat.attachPersistence(
                SessionStore(directory: sessions),
                badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))
            )
        }

        func mode() throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: sessions.path)
            let number: NSNumber = try #require(attributes[.posixPermissions] as? NSNumber)
            return number.intValue & 0o777
        }
    }

    @Test("unmodified startup/switch/reopen remains empty without claiming unsaved changes",
          arguments: [0o700, 0o755])
    func freshEmptyRecoveryIsReadOnly(mode: Int) throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        // Use the real SessionStore consumer with an owned fixture root.
        // Keep the historical mode explicit for deterministic read rejection.
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.sessions.path)
        let owner: UUID = try #require(chat.activeSessionID)
        let originalMessages = chat.messages
        let originalPayload = originalMessages.filter { $0.role != .system }.map { $0.asLLMMessage() }
        let originalHistoryIDs = stableMessageIDs(in: originalPayload)
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        chat.attachDraftStore(drafts)
        chat.attachDraftStore(drafts)
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(drafts.latestPayload(for: key) == nil)
        #expect(try f.mode() == mode)
        #expect(!FileManager.default.fileExists(atPath: drafts.draftsDirectory.path))
        if mode == 0o755 {
            // No guard relaxation: loading this root still really fails.
            #expect(drafts.lastIOError(for: key) == .unsafe)
            #expect(drafts.lastLoadError(for: key) == .decodeFailed)
        } else {
            #expect(drafts.lastIOError(for: key) == nil)
            #expect(drafts.lastLoadError(for: key) == nil)
        }
        let other = chat.applyNewSession()
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(chat.messages == originalMessages)
        #expect(chat.applySwitchSession(id: other))
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback == nil)

        let reopened = f.chat()
        #expect(f.attachPersistence(to: reopened))
        let reopenedDrafts = DraftStore(directory: f.sessions)
        reopened.attachDraftStore(reopenedDrafts)
        #expect(reopened.applySwitchSession(id: owner))
        #expect(reopened.draftText.isEmpty)
        #expect(reopened.draftPersistenceFeedback == nil)
        let reopenedPayload = reopened.messages.map { $0.asLLMMessage() }
        #expect(reopened.activeSessionID == owner)
        #expect(reopened.messages.count == originalPayload.count)
        #expect(reopenedPayload == originalPayload)
        #expect(stableMessageIDs(in: reopenedPayload) == originalHistoryIDs)
        let loadedOwner = SessionStore(directory: f.sessions).loadSession(id: owner.uuidString)
        let persistedOwner: MinisCore.ChatSession = try #require(loadedOwner)
        #expect(persistedOwner.id == owner.uuidString)
        #expect(persistedOwner.messages == originalPayload)
        #expect(stableMessageIDs(in: persistedOwner.messages) == originalHistoryIDs)
        #expect(try f.mode() == mode)
        #expect(!FileManager.default.fileExists(atPath: drafts.draftsDirectory.path))
    }

    private func stableMessageIDs(in messages: [LLMMessage]) -> [String] {
        let locator = SessionHistoryLocator()
        return messages.enumerated().map {
            locator.messageID(for: $0.element, transcriptIndex: $0.offset)
        }
    }

    @Test("an explicit empty edit still exposes a real failed clear and retries at the original boundary")
    func acceptedClearFailureIsNotHidden() throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        let owner: UUID = try #require(chat.activeSessionID)
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        // Owned legacy modes are hardened on mutation; a child symlink is
        // genuinely unsafe for both recovery and an accepted clear.
        let target = f.root.appendingPathComponent("unsafe-clear-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: drafts.draftsDirectory, withDestinationURL: target)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        chat.attachDraftStore(drafts)
        #expect(chat.draftPersistenceFeedback == nil)
        chat.draftText = "" // actual accepted edit, rather than restoration
        #expect(drafts.lastIOError(for: key) == .unsafe)
        #expect(chat.draftPersistenceFeedback != nil)
        let other = chat.applyNewSession()
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback != nil)
        #expect(try f.mode() == 0o700)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drafts.draftsDirectory.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        // Remove only this owned unsafe child, then let the original switch
        // boundary retry the accepted clear without following its target.
        try FileManager.default.removeItem(at: drafts.draftsDirectory)
        #expect(chat.applySwitchSession(id: other))
        #expect(drafts.lastIOError(for: key) == nil)
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(drafts.latestPayload(for: key) == nil)
    }

    @Test("real nonempty writes recover by session and an accepted clear does not revive old disk text")
    func acceptedTextPersistsAndClearStaysAuthoritative() throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let owner: UUID = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        defer {
            for session in chat.sessions {
                drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id))
            }
        }
        chat.draftText = "667 real durable owner text"
        let other = chat.applyNewSession() // real persistence boundary
        let stored: Data = try #require(DraftStore(directory: f.sessions).load(key: key))
        #expect(String(data: stored, encoding: .utf8) == "667 real durable owner text")
        #expect(chat.applySwitchSession(id: owner))
        chat.draftText = ""
        #expect(drafts.lastIOError(for: key) == nil)
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(chat.applySwitchSession(id: other))
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.draftText.isEmpty)
        let reopened = f.chat()
        #expect(f.attachPersistence(to: reopened))
        reopened.attachDraftStore(DraftStore(directory: f.sessions))
        #expect(reopened.applySwitchSession(id: owner))
        #expect(reopened.draftText.isEmpty)
        #expect(reopened.draftPersistenceFeedback == nil)
        #expect(DraftStore(directory: f.sessions).load(key: key) == nil)
    }

    private var referenceMaterial846: String {
        (1...45).map { "846资料\($0)：" + String(repeating: "甲", count: 50) }
            .joined(separator: "\n")
    }

    @Test("a reference-only paste is not an unchanged empty-body clear, and still persists and sends",
          arguments: [0o700, 0o755])
    func referenceOnlyPasteDoesNotClearUnchangedBody846(mode: Int) async throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.sessions.path)
        let owner = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        #expect(chat.draftText.isEmpty && chat.draftPersistenceFeedback == nil)
        let event = ComposerPasteEvent(text: referenceMaterial846, bodyBefore: "")
        #expect(PastedTextComposerConsumer.accept(event, in: chat))
        #expect(chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(drafts.latestPayload(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: drafts.draftsDirectory.path))
        #expect(try f.mode() == mode)
        let capsule = try #require(chat.activePastedTextDraft)
        #expect(capsule.id == event.draft.id && capsule.text == event.text)
        #expect(chat.composeDraftPayload() == event.text)

        // Read the real separately persisted capsule, without claiming that
        // the deliberately unsafe body-draft root became readable or writable.
        let reopened = f.chat()
        #expect(f.attachPersistence(to: reopened))
        reopened.attachDraftStore(DraftStore(directory: f.sessions))
        #expect(reopened.applySwitchSession(id: owner))
        let recovered = try #require(reopened.activePastedTextDraft)
        #expect(recovered == capsule)
        #expect(reopened.draftText.isEmpty && reopened.draftPersistenceFeedback == nil)
        let sibling = chat.applyNewSession()
        #expect(chat.activeSessionID == sibling)
        #expect(chat.activePastedTextDraft == nil && chat.draftText.isEmpty)
        #expect(chat.draftPersistenceFeedback == nil)
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.activePastedTextDraft == capsule && chat.draftPersistenceFeedback == nil)
        #expect(try f.mode() == mode)

        // Reuse the actual 793/397 ordinary Composer → AgentLoop → Mock route.
        // An unconfigured early return must not count as a successful send.
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "owned846-policy",
            grantEpoch: "owned846-epoch", leaseID: "owned846-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: f.root.appendingPathComponent("skills846"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned846")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: f.root),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = MockProvider()
        chat.submitComposer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!chat.isStreaming)
        let user = try #require(chat.messages.last(where: { $0.role == .user }))
        let card = try #require(user.referenceCard)
        let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
        #expect(user.content == event.text)
        #expect(card.material == event.text && card.sessionID == owner)
        #expect(assistant.content.hasPrefix("收到："))
        #expect(!assistant.content.contains(event.text))
        #expect(chat.activePastedTextDraft == nil && chat.draftText.isEmpty)
        // Sending is a real accepted clear. Its original safety/error behavior
        // is intentionally separate from the no-edit paste assertion above.
        if mode == 0o700 {
            #expect(chat.draftPersistenceFeedback == nil)
        }
    }

    @Test("paste that really changes the body to empty retains failed-clear feedback")
    func changedEmptyPasteStillExposesClearFailure846() throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        // Owned legacy modes are hardened on mutation; a child symlink is
        // genuinely unsafe for both recovery and an accepted clear.
        let target = f.root.appendingPathComponent("unsafe-clear-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: drafts.draftsDirectory, withDestinationURL: target)
        chat.attachDraftStore(drafts)
        let owner = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        chat.draftText = "846 accepted body before real clear"
        #expect(drafts.latestPayload(for: key) == Data(chat.draftText.utf8))
        #expect(try f.mode() == 0o700)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drafts.draftsDirectory.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(drafts.lastIOError(for: key) == .unsafe) // rejected child never becomes a trusted drafts descriptor
        let event = ComposerPasteEvent(text: referenceMaterial846, bodyBefore: "")
        #expect(PastedTextComposerConsumer.accept(event, in: chat))
        #expect(chat.draftText.isEmpty)
        #expect(drafts.latestPayload(for: key) == nil)
        #expect(drafts.lastIOError(for: key) == .unsafe)
        #expect(chat.draftPersistenceFeedback != nil)
        #expect(try f.mode() == 0o700)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drafts.draftsDirectory.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let capsule = try #require(chat.activePastedTextDraft)
        #expect(capsule.id == event.draft.id && capsule.text == event.text)
        let reopened = f.chat()
        #expect(f.attachPersistence(to: reopened))
        #expect(reopened.applySwitchSession(id: owner))
        #expect(reopened.activePastedTextDraft == capsule)
    }

    @Test("changed nonempty paste body and full capsule reopen under their exact session")
    func changedNonemptyPastePersistsAndIsolatesSibling846() throws {
        let f = try Fixture()
        let chat = f.chat()
        #expect(f.attachPersistence(to: chat))
        let drafts = DraftStore(directory: f.sessions)
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        defer {
            for session in chat.sessions {
                drafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id))
            }
        }
        let owner = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: owner)
        let event = ComposerPasteEvent(text: referenceMaterial846, bodyBefore: "846 revised current instruction")
        #expect(PastedTextComposerConsumer.accept(event, in: chat))
        #expect(chat.draftText == event.bodyBefore)
        #expect(drafts.latestPayload(for: key) == Data(event.bodyBefore.utf8))
        let capsule = try #require(chat.activePastedTextDraft)
        #expect(capsule.id == event.draft.id && capsule.text == event.text)
        let sibling = chat.applyNewSession() // real flush of the accepted body
        let stored = try #require(DraftStore(directory: f.sessions).load(key: key))
        #expect(String(data: stored, encoding: .utf8) == event.bodyBefore)
        #expect(chat.draftText.isEmpty && chat.activePastedTextDraft == nil)
        let siblingBody = "846 sibling isolated body"
        chat.draftText = siblingBody
        #expect(chat.applySwitchSession(id: owner))
        #expect(chat.draftText == event.bodyBefore && chat.activePastedTextDraft == capsule)
        #expect(chat.draftPersistenceFeedback == nil)
        let siblingKey = DraftStore.chatDraftKey(sessionID: sibling)
        let siblingStored = try #require(DraftStore(directory: f.sessions).load(key: siblingKey))
        #expect(String(data: siblingStored, encoding: .utf8) == siblingBody)
        let reopened = f.chat()
        #expect(f.attachPersistence(to: reopened))
        let reopenedDrafts = DraftStore(directory: f.sessions)
        reopenedDrafts.debounceInterval = .seconds(30)
        reopened.attachDraftStore(reopenedDrafts)
        defer {
            for session in reopened.sessions {
                reopenedDrafts.cancelPending(key: DraftStore.chatDraftKey(sessionID: session.id))
            }
        }
        #expect(reopened.applySwitchSession(id: owner))
        #expect(reopened.draftText == event.bodyBefore && reopened.activePastedTextDraft == capsule)
        #expect(reopened.applySwitchSession(id: sibling))
        #expect(reopened.draftText == siblingBody && reopened.activePastedTextDraft == nil)
        #expect(reopened.draftPersistenceFeedback == nil)
        #expect(chat.activeSessionID == owner && chat.activePastedTextDraft == capsule)
    }
}
