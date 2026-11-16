import Foundation
import Testing
@testable import MinisCanvasApp

/// P3-COMP-02 acceptance clause「发送后可展开卡」— lane 160B regression contract.
///
/// The only clause owned here: after a message that carries a long pasted text
/// is SENT, the pasted-text capsule rendered in the transcript must stay
/// expandable/collapsible by the user, and its expanded payload must not be
/// clipped away.  `reference`/`instruction` separation and the authorization
/// keyword clause belong to accepted lanes 156 and 151 and are not re-litigated.
///
/// Lane finding (see receipt): this is a NO_CHANGE contract, not a fix.  At base
/// `23cf25e00` expansion already lives in durable per-message model state —
/// `PastedTextReferenceCard.isExpanded` (PastedTextDraft.swift:109) drives
/// `renderedMaterial` (:160), `stateLabel` (:162) and `toggleExpanded` (:165-169);
/// `ChatStore.setPastedTextReferenceExpanded` (ChatStore.swift:2830-2852) writes it
/// onto `ChatMessageUI.referenceCard` (ChatStore.swift:208) for the owning session
/// only; and both transcript render sites forward the user click to it
/// (ChatSidebarView.swift:1194-1200 and :2392-2398 → :2102-2130).  The card view
/// holds no `@State`.  These tests pin that chain so a future move of the flag
/// into view-local state, a clipped expanded payload, or a card that disappears
/// on send turns the suite red instead of regressing silently.
@Suite("PastedText capsule expand-after-send contract (160B)")
struct PastedTextCapsuleExpandAfterSend160BTests {

    /// Over the 240-scalar preview bound so the collapsed and expanded payloads
    /// are observably different strings.
    private static let material: String =
        (1...40).map { "第\($0)行 粘贴资料正文内容" }.joined(separator: "\n")

    private static var materialScalarCount: Int {
        material.unicodeScalars.count
    }

    // MARK: - Sent-state behaviour (executable contracts)

    @Test("a sent paste carries a session-owned card that starts collapsed and keeps the payload out of the bubble")
    @MainActor
    func sendAttachesCollapsedCard() throws {
        let store = ChatStore()
        let capsuleID = UUID()
        #expect(store.setPastedTextDraft(
            PastedTextDraft(id: capsuleID, text: Self.material, source: .pasteboard)
        ))
        store.draftText = "总结这份资料"
        store.sendDraft()

        let sent = try #require(store.messages.first { $0.role == .user })
        let card = try #require(sent.referenceCard)
        #expect(card.id == capsuleID)
        #expect(card.sessionID == store.activeSessionID)
        #expect(card.kind == .reference)
        #expect(card.material == Self.material)
        #expect(card.characterCount == Self.materialScalarCount)
        #expect(card.lineCount == 40)
        // Post-send the card starts folded; the bubble shows only the typed body,
        // so the material is reachable exactly through the expand control.
        #expect(card.isExpanded == false)
        #expect(sent.displayContent == "总结这份资料")
        #expect(!sent.displayContent.contains(Self.material))
        #expect(store.activePastedTextDraft == nil)
        #expect(store.lastPastedTextSubmissionSnapshot?.referenceCard?.id == capsuleID)
    }

    @Test("expanding the sent card reveals the whole payload and collapsing bounds it again")
    @MainActor
    func toggleRevealsFullPayload() throws {
        let store = self.sentStore(body: "总结这份资料")
        let sent = try #require(store.messages.first { $0.role == .user })
        let messageID = sent.id
        let collapsedCard = try #require(sent.referenceCard)
        #expect(collapsedCard.renderedMaterial == collapsedCard.preview)
        #expect(collapsedCard.preview.unicodeScalars.count == PastedTextReferenceCard.previewScalarLimit)
        #expect(collapsedCard.stateLabel == "资料已收起")

        #expect(store.setPastedTextReferenceExpanded(messageID: messageID, expanded: true))
        let expandedCard = try #require(
            store.messages.first { $0.role == .user }?.referenceCard
        )
        #expect(expandedCard.isExpanded)
        // The expanded payload is the complete material, not a bounded prefix.
        #expect(expandedCard.renderedMaterial == Self.material)
        #expect(expandedCard.renderedMaterial.unicodeScalars.count > PastedTextReferenceCard.previewScalarLimit)
        #expect(expandedCard.stateLabel == "资料已展开")

        #expect(store.setPastedTextReferenceExpanded(messageID: messageID, expanded: false))
        let reCollapsed = try #require(
            store.messages.first { $0.role == .user }?.referenceCard
        )
        #expect(!reCollapsed.isExpanded)
        #expect(reCollapsed.renderedMaterial == collapsedCard.preview)
        // The material itself is never mutated by an expand/collapse cycle.
        #expect(reCollapsed.material == Self.material)
    }

    @Test("the sent card stays expandable across a session switch because its state is model-owned")
    @MainActor
    func expansionSurvivesSessionRoundTrip() throws {
        let store = self.sentStore(body: "总结这份资料")
        let sent = try #require(store.messages.first { $0.role == .user })
        let messageID = sent.id
        let homeSessionID = try #require(store.activeSessionID)
        #expect(store.setPastedTextReferenceExpanded(
            messageID: messageID, expanded: true, sessionID: homeSessionID
        ))

        store.newSession()
        // A foreign session may not toggle this card (the control is fenced, not
        // removed): the click returns false and leaves the flag untouched.
        #expect(!store.setPastedTextReferenceExpanded(
            messageID: messageID, expanded: false, sessionID: homeSessionID
        ))
        store.switchSession(id: homeSessionID)
        let restored = try #require(
            store.messages.first { $0.role == .user }?.referenceCard
        )
        #expect(restored.isExpanded)
        #expect(restored.renderedMaterial == Self.material)
        #expect(store.setPastedTextReferenceExpanded(
            messageID: messageID, expanded: false, sessionID: homeSessionID
        ))
        #expect(
            store.messages.first { $0.role == .user }?.referenceCard?.isExpanded == false
        )
    }

    @Test("an idempotent or unknown toggle never fabricates an expanded card")
    @MainActor
    func toggleFailClosed() throws {
        let store = self.sentStore(body: "总结这份资料")
        let sent = try #require(store.messages.first { $0.role == .user })
        let homeSessionID = try #require(store.activeSessionID)
        // Same-state toggle is a no-op success (the label must not flip twice).
        #expect(store.setPastedTextReferenceExpanded(
            messageID: sent.id, expanded: false, sessionID: homeSessionID
        ))
        #expect(
            store.messages.first { $0.role == .user }?.referenceCard?.isExpanded == false
        )
        // Unknown message and foreign session both fail closed.
        #expect(!store.setPastedTextReferenceExpanded(
            messageID: UUID(), expanded: true, sessionID: homeSessionID
        ))
        #expect(!store.setPastedTextReferenceExpanded(
            messageID: sent.id, expanded: true, sessionID: UUID()
        ))
        #expect(
            store.messages.first { $0.role == .user }?.referenceCard?.isExpanded == false
        )
    }

    // MARK: - Source contracts (static, no view hosting)

    @Test("the transcript card view drives expansion from the model, not from view state")
    func cardViewHasNoLocalExpansionState() throws {
        let source = try source(named: "PastedTextCapsuleView.swift")
        let card = try #require(
            source.components(separatedBy: "struct PastedTextReferenceCardView").last
        )
        #expect(!card.contains("@State"))
        #expect(card.contains("let card: PastedTextReferenceCard"))
        #expect(card.contains("let isSessionCurrent: Bool"))
        #expect(card.contains("let onToggle: () -> Void"))
        #expect(card.contains(#"Button(card.isExpanded ? "收起\(cardKindLabel)" : "展开\(cardKindLabel)", action: onToggle)"#))
        #expect(card.contains(#".accessibilityIdentifier("chat.pasted-reference-card.toggle.\(cardIdentity)")"#))
        // Expanded content must not stay line-bounded; collapse is the only clamp.
        #expect(card.contains(".lineLimit(card.isExpanded ? nil : 4)"))
        #expect(card.contains(".disabled(!isSessionCurrent)"))
        #expect(!card.contains(".disabled(true)"))
    }

    @Test("the card projection derives its bounded and full payloads from one material field")
    func cardProjectionIsMaterialBacked() throws {
        let source = try source(named: "PastedTextDraft.swift")
        #expect(source.contains("var isExpanded: Bool"))
        #expect(source.contains("var renderedMaterial: String { isExpanded ? material : preview }"))
        #expect(source.contains(#"var stateLabel: String { isExpanded ? "资料已展开" : "资料已收起" }"#))
        #expect(source.contains("mutating func toggleExpanded(expectedSessionID: UUID) -> Bool"))
        #expect(source.contains("case id, sessionID, instruction, material, kind, isExpanded"))
    }

    @Test("both transcript render sites forward the expand click to the owning session")
    func transcriptSitesWireTheToggle() throws {
        let source = try source(named: "ChatSidebarView.swift")
        #expect(source.contains("PastedTextReferenceCardView("))
        #expect(source.contains("isSessionCurrent: card.sessionID == sessionID"))
        #expect(source.contains("onToggleReferenceCard?(message.id, !card.isExpanded)"))
        // ChatMainView and CompanionChatView each hand the click to ChatStore.
        #expect(source.components(separatedBy: "chat.setPastedTextReferenceExpanded(").count == 3)
        #expect(source.contains("messagesWithCards"))
        #expect(source.contains(#".accessibilityIdentifier("chat.pasted-reference-card.list")"#))
        // The composer capsule stays a pre-send surface; the sent card is the
        // transcript projection, so the two never render the same paste twice.
        #expect(source.contains("ForEach(chat.activePastedTextDrafts) { draft in"))
        let global = try self.source(named: "GlobalComposerView.swift")
        #expect(global.contains("PastedTextCapsuleView("))
        #expect(global.contains("ForEach(chat.activePastedTextDrafts) { draft in"))
        #expect(!global.contains("PastedTextReferenceCardView("))
    }

    // MARK: - Helpers

    /// One production send through the Composer boundary, which is the exact
    /// moment the clause is about (the card must live on the far side of it).
    @MainActor
    private func sentStore(body: String) -> ChatStore {
        let store = ChatStore()
        _ = store.setPastedTextDraft(
            PastedTextDraft(id: UUID(), text: Self.material, source: .pasteboard)
        )
        store.draftText = body
        store.sendDraft()
        return store
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
