import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class N14OfflineProvider: LLMProvider, @unchecked Sendable {
    let name = "n14-offline"
    var model = LLMModel(id: "n14-offline", displayName: "N14 Offline", provider: "n14-offline")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        return LLMResponse(text: "N14 offline completion", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("N14 read-only invisible-character presentation")
@MainActor
struct InvisibleComposerReviewTests {
    @Test func inputNoticeDoesNotRewriteOrBlockActualBodyAndCapsuleSubmission() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "n14-display",
            processEnvironment: [:], processArguments: ["InvisibleComposerReviewTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        let provider = configureOfflineTurn(chat, profile: profile)
        let messagesBeforeInput = chat.messages
        let body = "请\u{202E}总结"
        let material = String(repeating: "资料", count: 1_100) + "\u{200B}结尾\u{E0041}"
        let event = ComposerPasteEvent(text: material, bodyBefore: body)
        #expect(PastedTextComposerConsumer.accept(event, in: chat))
        let expected = chat.composeDraftPayload()
        #expect(chat.composerInvisibleCharacterNotice?.contains("3 个") == true)
        #expect(chat.composerInvisibleCharacterNotice?.contains("⟦U+E0041⟧") == true)
        #expect(chat.draftText == body && chat.activePastedTextDraft?.text == material)
        #expect(chat.messages == messagesBeforeInput)
        #expect(provider.requests.isEmpty)
        // One original send intent, without an N14 admission gate or rewrite.
        #expect(await chat.submitComposerAwaitingAdmission())
        try await waitForTurn(chat)
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.last(where: { $0.role == .user })?.content == expected)
        let message = try #require(chat.messages.first(where: { $0.role == .user }))
        #expect(message.content == expected && message.referenceCard?.material == material)
        #expect(chat.composerInvisibleCharacterNotice == nil)
    }

    @Test func noticesDoNotChangeSlashRoutingOrExplicitLiteralPayload() async throws {
        let chat = ChatStore()
        chat.draftText = "/help"
        #expect(chat.setPastedTextDraft(PastedTextDraft(id: UUID(), text: "参考\u{200B}", source: .pasteboard)))
        #expect(chat.composerInvisibleCharacterNotice != nil)
        #expect(await chat.submitComposerAwaitingAdmission())
        #expect(chat.lastComposerCommandReceipt != nil)
        #expect(!chat.messages.contains { $0.role == .user })
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "n14-literal-display",
            processEnvironment: [:], processArguments: ["InvisibleComposerReviewTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let literal = ChatStore()
        #expect(literal.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        let provider = configureOfflineTurn(literal, profile: profile)
        let boundaryLiteral = "/help\u{200B}"
        literal.draftText = boundaryLiteral
        #expect(literal.composerInvisibleCharacterNotice?.contains("1 个") == true)
        #expect(literal.draftText == boundaryLiteral)
        #expect(await literal.submitComposerAwaitingAdmission(literal: true))
        try await waitForTurn(literal)
        #expect(literal.lastComposerCommandReceipt == nil)
        // Existing typed-only sends trim boundary whitespace even in literal
        // mode. Literal intent suppresses command routing; it does not change
        // that prior contract. N14 only observed the unchanged editable draft.
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.last(where: { $0.role == .user })?.content == "/help")
        let interiorLiteral = "/he\u{200B}lp"
        literal.draftText = interiorLiteral
        #expect(literal.composerInvisibleCharacterNotice?.contains("1 个") == true)
        #expect(literal.draftText == interiorLiteral)
        #expect(await literal.submitComposerAwaitingAdmission(literal: true))
        try await waitForTurn(literal)
        #expect(literal.lastComposerCommandReceipt == nil)
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.last(where: { $0.role == .user })?.content == interiorLiteral)
        #expect(literal.messages.filter { $0.role == .user }.map(\.content) == ["/help", interiorLiteral])
    }

    @Test func readOnlyNoticeKeepsEditCancelableAndSessionHistoryUnchanged() throws {
        let chat = ChatStore()
        let session = try #require(chat.activeSessionID)
        let original = ChatMessageUI(role: .user, content: "旧\u{202E}正文")
        chat.messages = [original]
        chat.beginEdit(messageID: original.id)
        #expect(chat.composerInvisibleCharacterNotice?.contains("1 个") == true)
        #expect(chat.isEditingMessage && chat.messages == [original])
        chat.cancelEdit()
        #expect(!chat.isEditingMessage && chat.draftText == original.content)
        chat.newSession()
        chat.draftText = "新会话"
        #expect(chat.composerInvisibleCharacterNotice == nil)
        chat.switchSession(id: session)
        #expect(chat.draftText == original.content && chat.messages == [original])
    }

    @Test func capsuleSaveChangesOnlyExplicitEditorContentAndCancelLeavesOriginal() throws {
        let chat = ChatStore()
        let messagesBeforeEdit = chat.messages
        let session = try #require(chat.activeSessionID)
        let draft = PastedTextDraft(id: UUID(), text: "资料\u{200B}", source: .pasteboard, kind: .instruction)
        #expect(chat.setPastedTextDraft(draft))
        var localEdit = draft
        localEdit.text = "未保存\u{202E}"
        #expect(InvisibleCharacterPolicy.notice(in: [localEdit.text]) != nil)
        chat.clearPastedTextActionFeedback() // Same cancel consumer: no save.
        #expect(chat.activePastedTextDraft == draft)
        #expect(PastedTextComposerConsumer.save(localEdit, expectedSessionID: session,
            expectedDraftID: draft.id, in: chat))
        #expect(chat.activePastedTextDraft == localEdit)
        #expect(chat.composerInvisibleCharacterNotice?.contains("⟦U+202E⟧") == true)
        #expect(chat.messages == messagesBeforeEdit)
    }

    @Test func queueAndRecallKeepExactRawTextAndCapsuleWithoutNewAdmissionGate() {
        let chat = ChatStore()
        let messagesBeforeQueue = chat.messages
        chat.draftText = "正文\u{200B}"
        let capsule = PastedTextDraft(id: UUID(), text: "资料\u{202E}", source: .pasteboard)
        #expect(chat.setPastedTextDraft(capsule))
        #expect(chat.composerInvisibleCharacterNotice?.contains("2 个") == true)
        #expect(chat.enqueueComposer())
        #expect(chat.activeQueuedComposerMessages.first?.text == "正文\u{200B}")
        #expect(chat.activeQueuedComposerMessages.first?.pastedDrafts == [capsule])
        #expect(chat.takeQueuedComposerForEditing())
        #expect(chat.draftText == "正文\u{200B}" && chat.activePastedTextDraft == capsule)
        #expect(chat.messages == messagesBeforeQueue)
    }

    @Test func legitimateLanguageAndEmojiSequencesStayUnmarkedAndControlCountUsesScalars() {
        let legitimate = "中文拼音 e\u{301} می\u{200C}روم क्\u{200D}ष 👩🏽\u{200D}💻 ❤️ "
            + "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
            + "🏴\u{E0030}\u{E0030}\u{E0031}\u{E007F}"
        #expect(InvisibleCharacterPolicy.visible(legitimate) == legitimate)
        #expect(InvisibleCharacterPolicy.notice(in: [legitimate]) == nil)
        let controls = "\u{202E}\u{200B}\u{E0041}"
        #expect(InvisibleCharacterPolicy.count(in: controls) == 3)
        #expect(InvisibleCharacterPolicy.visible(controls) == "⟦U+202E⟧⟦U+200B⟧⟦U+E0041⟧")
    }

    @Test func actualTranscriptMarksVisibleResultButRawExportAndCopyRemainUnchanged() {
        let raw = "file_read result: 左\u{200B}右\u{202E}\u{E0041}"
        let message = ChatMessageUI(role: .tool, content: raw)
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let display = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13,
            redactor: redactor, palette: .light)
        #expect(display.string.contains("左⟦U+200B⟧右⟦U+202E⟧⟦U+E0041⟧"))
        #expect(ChatTranscriptFormatter.accessibilityText([message], redactor: redactor).contains("⟦U+E0041⟧"))
        #expect(message.content == raw && message.asLLMMessage().content == raw && message.displayContent == raw)
        #expect(ChatTranscriptFormatter.plainText([message], redactor: redactor).contains(raw))
        let markdown = SessionMarkdownExport.markdown(title: "N14 synthetic export",
            messages: [message], redactor: redactor)
        #expect(markdown.contains(raw))
        #expect(!markdown.contains("⟦U+200B⟧"))
        let copy = ChatTranscriptCopyProjection(redactedBody: redactor.redact(message.displayContent))
        #expect(copy.message.contains("\u{200B}") && !copy.message.contains("⟦U+200B⟧"))
        let large = ChatMessageUI(role: .tool, content: String(repeating: "x", count: 30_000) + "\u{200B}")
        let hidden = ChatTranscriptFormatter.formattedMessage(large, baseSize: 13, redactor: redactor).string
        #expect(hidden.contains("⟦U+200B⟧") && !hidden.contains(String(repeating: "x", count: 500)))
    }

    @Test func ledgerHasNoNewFieldsAndOnlyAvailableRawDisplayCanProduceMarkers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("n14-ledger-display-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: file)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "n14-synthetic-session", turnID: 1, messageID: "n14-message"),
            operationID: "n14-operation", attempt: 1)
        let receipt = try ledger.mint(toolCallID: "n14-read", toolName: "file_read",
            attemptID: "n14-attempt", attemptNumber: 1, executionIdentity: identity)
        let raw = "PRIVATE_SYNTHETIC_FILE\u{200B}\u{202E}\u{E0041}"
        let summary = ToolOutputSummary.capture(toolName: "file_read", output: raw)
        #expect(summary == .text(bytes: raw.utf8.count, lines: 1))
        _ = try ledger.settle(receipt, status: .succeeded, outputSummary: summary)
        let data = try Data(contentsOf: file)
        let stored = String(decoding: data, as: UTF8.self)
        #expect(!stored.contains("invisibleCharacters") && !stored.contains("codePoints"))
        #expect(!stored.contains("PRIVATE_SYNTHETIC_FILE"))
        let restored = try #require(ToolExecutionFactLedger(persistenceURL: file).facts.first)
        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(restored, eventID: restored.toolCallID,
            eventName: restored.toolName, taskID: "n14-task", expectedAttemptID: restored.attemptID,
            scopeID: "n14-scope"))
        let event = try #require(consumer.toolLifecycleEvents.first)
        // Metrics-only facts cannot reconstruct raw text; do not invent markers.
        #expect(!ToolEventCard.displayModel(for: event).summary.contains("⟦U+"))
        let visible = ChatTranscriptFormatter.formattedMessage(ChatMessageUI(role: .tool, content: raw),
            baseSize: 13, redactor: ChatTranscriptRedactor(secretValues: [])).string
        #expect(visible.contains("⟦U+200B⟧") && visible.contains("⟦U+E0041⟧"))
    }

    private func configureOfflineTurn(_ chat: ChatStore, profile: RuntimeIsolationProfile) -> N14OfflineProvider {
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "n14-policy", grantEpoch: "n14-epoch",
            leaseID: "n14-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:n14")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        let provider = N14OfflineProvider()
        chat.streamingProviderOverride = provider
        return provider
    }

    private func waitForTurn(_ chat: ChatStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.isStreaming && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!chat.isStreaming)
    }
}
