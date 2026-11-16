import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Pasted text production consumers")
@MainActor
struct PastedTextProductionConsumerTests {
    @Test("shared consumer keeps long paste outside the editable body")
    func sharedConsumerSeparatesBodyAndPayload() {
        let store = ChatStore()
        let event = ComposerPasteEvent(
            text: String(repeating: "长", count: 2_001),
            bodyBefore: "补充正文"
        )

        #expect(PastedTextComposerConsumer.accept(event, in: store))
        #expect(store.draftText == "补充正文")
        #expect(store.activePastedTextDraft?.id == event.draft.id)
        #expect(store.composeDraftPayload() == "补充正文\n\n[Pasted text]\n" + event.text)
        #expect(GlobalComposer.canSend(
            draftText: "",
            pendingAttachmentCount: 0,
            hasPastedText: true
        ))
    }

    @Test("ordinary Composer keeps local Mock's long-reference acknowledgement bounded")
    func ordinaryComposerMockDoesNotExpandTheReferenceAgain() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "paste793-mock", processEnvironment: [:],
            processArguments: ["PastedTextTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        let sessionID = try #require(chat.activeSessionID)
        let material = (1...45).map { "793资料\($0)：这是完整合成参考材料，必须保留引用全文，不能再次平铺整个材料。" }
            .joined(separator: "\n")
        let event = ComposerPasteEvent(text: material, bodyBefore: "只总结参考材料")
        #expect(PastedTextComposerConsumer.accept(event, in: chat))
        let provider = MockProvider()
        // Same lawful Provider route/policy assembly as the existing 541/397
        // ordinary-turn consumers, rather than accepting a startup error as
        // evidence that an unconfigured ChatStore called Mock.
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "owned793-policy",
            grantEpoch: "owned793-epoch", leaseID: "owned793-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills793"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned793")
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: try! ProviderRuntimeRoute(snapshot: snapshot, primary: box),
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        chat.submitComposer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!chat.isStreaming)
        let user = try #require(chat.messages.last(where: { $0.role == .user }))
        let card = try #require(user.referenceCard)
        let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
        #expect(user.content == "只总结参考材料" + ComposerPayload.pastedTextSeparator + material)
        #expect(card.material == material && card.sessionID == sessionID && !card.isExpanded)
        #expect(assistant.content.hasPrefix("收到："))
        #expect(!assistant.content.contains(material))
        #expect(!assistant.content.contains("793资料45"))
        #expect(assistant.content.split(separator: "\n").count < 20)
        #expect(chat.setPastedTextReferenceExpanded(messageID: user.id, expanded: true))
        #expect(chat.messages.first(where: { $0.id == user.id })?.referenceCard?.renderedMaterial == material)
        let short = try await MockProvider().sendMessage(
            messages: [LLMMessage(role: .user, content: "短指令原样回显")],
            systemPrompt: nil, maxTokens: 512, temperature: nil)
        #expect(short.text.contains("收到：短指令原样回显"))
    }

    @Test("short paste is left to the native text view and does not erase an existing capsule")
    func shortPasteFallsBackWithoutClearingCapsule() {
        let store = ChatStore()
        let longEvent = ComposerPasteEvent(
            text: String(repeating: "长", count: 2_001),
            bodyBefore: "正文"
        )
        let shortEvent = ComposerPasteEvent(text: "短", bodyBefore: "正文")

        #expect(PastedTextComposerConsumer.accept(longEvent, in: store))
        #expect(!PastedTextComposerConsumer.accept(shortEvent, in: store))
        #expect(store.activePastedTextDraft?.id == longEvent.draft.id)
        #expect(store.draftText == "正文")
    }

    @Test("production views share the capsule and editor contract")
    func productionViewsUseSharedRenderingAndAXActions() throws {
        let global = try source(named: "GlobalComposerView.swift")
        let sidebar = try source(named: "ChatSidebarView.swift")
        let capsule = try source(named: "PastedTextCapsuleView.swift")
        let pasteBridge = try source(named: "ScrollableComposerTextView.swift")

        #expect(global.contains("PastedTextCapsuleView("))
        #expect(sidebar.contains("PastedTextCapsuleView("))
        #expect(global.contains("PastedTextComposerConsumer.accept"))
        #expect(sidebar.contains("PastedTextComposerConsumer.accept"))
        #expect(global.contains("PastedTextComposerConsumer.remove"))
        #expect(sidebar.contains("PastedTextComposerConsumer.remove"))
        #expect(capsule.contains("PastedTextComposerConsumer.save"))
        #expect(capsule.contains("PastedTextComposerConsumer.remove"))
        #expect(global.contains("composer.pasted-text.feedback"))
        #expect(sidebar.contains("composer.pasted-text.feedback"))
        #expect(capsule.contains("composer.pasted-text.feedback"))
        #expect(capsule.contains("composer.pasted-text.preview"))
        #expect(capsule.contains("composer.pasted-text.remove"))
        #expect(capsule.contains("composer.pasted-text.editor"))
        #expect(capsule.contains("composer.pasted-text.cancel"))
        #expect(capsule.contains("composer.pasted-text.delete"))
        #expect(capsule.contains("composer.pasted-text.save"))
        #expect(global.contains("composer.send"))
        #expect(sidebar.contains("composer.send"))
        // Every native paste must reach the broker callback, including short
        // credentials. Only the shared consumer decides whether to collapse.
        #expect(pasteBridge.contains("if onPasteEvent?(event) == true"))
        #expect(capsule.contains("guard PastedTextPolicy.shouldCollapse(event.draft)"))
        #expect(!capsule.contains("Text(draft.text)"))
    }

    @Test("shared consumer keeps reference text out of session-read intent")
    func referenceDoesNotTriggerSessionReadIntent() {
        let reference = PastedTextDraft(
            id: UUID(),
            text: "参考：session_read target messages",
            source: .pasteboard
        )
        let instruction = PastedTextDraft(
            id: UUID(),
            text: "session_read target messages",
            source: .pasteboard,
            kind: .instruction
        )

        #expect(
            PastedTextComposerConsumer.intentInput(
                body: "总结资料",
                pastedText: reference
            ) == "总结资料"
        )
        #expect(
            PastedTextComposerConsumer.intentInput(body: "执行", pastedText: instruction)
                .contains(ComposerPayload.pastedInstructionSeparator)
        )
    }

    @Test("consumer snapshot retains full post-send reference payload")
    func consumerSnapshotRetainsFullPayload() {
        let reference = PastedTextDraft(
            id: UUID(),
            text: String(repeating: "全文-", count: 700),
            source: .pasteboard
        )
        let sessionID = UUID()
        let snapshot = PastedTextComposerConsumer.submissionSnapshot(
            capsuleID: reference.id,
            sessionID: sessionID,
            body: "正文",
            pastedText: reference
        )

        #expect(snapshot.capsuleID == reference.id)
        #expect(snapshot.sessionID == sessionID)
        #expect(snapshot.fullText == "正文" + ComposerPayload.pastedTextSeparator + reference.text)
        #expect(snapshot.fullText.hasSuffix(reference.text))
    }

    @Test("ChatStore keeps reference material out of command and session-read routing")
    func chatStoreReferenceRoutingBoundaryIsWired() throws {
        let store = try source(named: "ChatStore.swift")

        #expect(store.contains("pastedDraft?.kind != .reference"))
        #expect(store.contains("sessionReadText: intentText"))
        #expect(store.contains("referenceCard: pastedSubmission?.referenceCard"))
    }

    @Test("reference cards preserve 50k/100k material and expansion through real persistence")
    func referenceCardsSurviveCanonicalReopen() throws {
        for count in [50_000, 100_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-reopen-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(directory: root)
            let chat = ChatStore()
            #expect(chat.attachPersistence(store))
            let sessionID = try #require(chat.activeSessionID)
            let material = " \n" + String(repeating: "文", count: count) + "\n  "
            let draft = PastedTextDraft(id: UUID(), text: material, source: .pasteboard, kind: .reference)
            let submission = PastedTextSubmissionSnapshot(capsuleID: draft.id, sessionID: sessionID, body: " \t解释材料 \n", pastedText: draft)
            chat.appendUser(submission.fullText, referenceCard: submission.referenceCard)
            let message = try #require(chat.messages.last(where: { $0.role == .user }))
            #expect(chat.setPastedTextReferenceExpanded(messageID: message.id, expanded: true))
            let reopened = ChatStore()
            #expect(reopened.attachPersistence(SessionStore(directory: root)))
            let restored = try #require(reopened.messages.last(where: { $0.role == .user }))
            #expect(restored.content == submission.fullText)
            #expect(restored.referenceCard?.material == material)
            #expect(restored.referenceCard?.instruction == "解释材料")
            #expect(restored.referenceCard?.kind == .reference)
            #expect(restored.referenceCard?.isExpanded == true)
            #expect(restored.referenceCard?.sessionID == sessionID)
        }
    }

    @Test("attachment sidecar capacity is isolated across reopened sessions")
    func referenceCardCapacityIsIsolatedAcrossReopenedSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-capacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        try #require(chat.attachPersistence(SessionStore(directory: root)))
        let firstID = try #require(chat.activeSessionID)
        // Each ASCII material is about 4 MiB. Together they exceed the shared
        // 8 MiB envelope before JSON metadata, while either one fits alone.
        let materialBytes = 4 * 1024 * 1024 + 1024
        let firstDraft = PastedTextDraft(
            id: UUID(), text: String(repeating: "a", count: materialBytes), source: .pasteboard
        )
        let first = PastedTextSubmissionSnapshot(
            capsuleID: firstDraft.id, sessionID: firstID, body: "第一份资料", pastedText: firstDraft
        )
        let firstCard = try #require(first.referenceCard)
        chat.appendUser(first.fullText, referenceCard: firstCard)

        let writer = ChatStore()
        try #require(writer.attachPersistence(SessionStore(directory: root)))
        let firstSaved = try #require(writer.messages(forSession: firstID)?.last(where: { $0.role == .user }))
        let firstCardWasSaved = firstSaved.referenceCard == firstCard
        try #require(firstCardWasSaved)

        writer.newSession()
        let secondID = try #require(writer.activeSessionID)
        try #require(secondID != firstID)
        let secondDraft = PastedTextDraft(
            id: UUID(), text: String(repeating: "b", count: materialBytes), source: .pasteboard
        )
        let second = PastedTextSubmissionSnapshot(
            capsuleID: secondDraft.id, sessionID: secondID, body: "第二份资料", pastedText: secondDraft
        )
        let secondCard = try #require(second.referenceCard)
        let attachment = ChatAttachment(
            kind: .text, fileName: "second.txt", fileType: .text, data: Data("新增附件".utf8)
        )
        writer.appendUser(second.fullText, attachments: [attachment], referenceCard: secondCard)

        let reopened = ChatStore()
        try #require(reopened.attachPersistence(SessionStore(directory: root)))
        let firstMessage = try #require(reopened.messages(forSession: firstID)?.last(where: { $0.role == .user }))
        let firstCardSurvived = firstMessage.referenceCard == firstCard
        #expect(firstCardSurvived)
        #expect(firstMessage.attachments.isEmpty)

        let secondMessage = try #require(reopened.messages(forSession: secondID)?.last(where: { $0.role == .user }))
        let secondTranscriptSurvived = secondMessage.content == second.fullText
        let secondCardSurvived = secondMessage.referenceCard == secondCard
        #expect(secondTranscriptSurvived)
        #expect(secondCardSurvived)
        #expect(secondMessage.attachments == [attachment])
    }

    @Test("one oversized session warns without blocking another session's attachment")
    func attachmentOverflowWarningIsScopedToItsSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-capacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        try #require(chat.attachPersistence(SessionStore(directory: root)))
        let firstID = try #require(chat.activeSessionID)
        let first = ChatAttachment(kind: .text, fileName: "first.txt", fileType: .text, data: Data("原附件".utf8))
        chat.appendUser("保留原附件", attachments: [first])

        // Base64 encoding alone exceeds the 8 MiB sidecar limit.
        let oversized = ChatAttachment(
            kind: .file, fileName: "oversized.bin", fileType: .unknown,
            data: Data(repeating: 0x41, count: 6_300_000)
        )
        chat.appendUser("超出容量的附件", attachments: [oversized])
        #expect(chat.sessionPersistenceNotice?.contains("附件") == true)
        #expect(chat.messages.last?.attachments.first?.id == oversized.id)

        chat.newSession()
        let secondID = try #require(chat.activeSessionID)
        try #require(secondID != firstID)
        let second = ChatAttachment(kind: .text, fileName: "second.txt", fileType: .text, data: Data("其他会话".utf8))
        chat.appendUser("保存其他会话的附件", attachments: [second])
        #expect(chat.sessionPersistenceNotice == nil)

        let reopened = ChatStore()
        try #require(reopened.attachPersistence(SessionStore(directory: root)))
        let firstMessages = try #require(reopened.messages(forSession: firstID))
        #expect(firstMessages.first(where: { $0.content == "保留原附件" })?.attachments == [first])
        #expect(firstMessages.last?.content == "超出容量的附件")
        #expect(reopened.messages(forSession: secondID)?.last?.attachments == [second])
    }

    @Test("reference metadata rejects stale bindings and keeps legacy transcript readable")
    func referenceMetadataRequiresExactBinding() throws {
        let sessionID = UUID()
        let draft = PastedTextDraft(id: UUID(), text: "完整资料", source: .pasteboard, kind: .instruction)
        let submission = PastedTextSubmissionSnapshot(capsuleID: draft.id, sessionID: sessionID, body: "操作", pastedText: draft)
        let thread = ChatThread(id: sessionID, messages: [ChatMessageUI(role: .user, content: submission.fullText, referenceCard: submission.referenceCard)])
        let persisted = thread.asPersisted()
        let records = ChatAttachmentPersistence.records(for: thread).messages
        let record = try #require(records.first)
        let wrongIndex = ChatAttachmentPersistence.MessageRecord(
            messageIndex: 42, contentDigest: record.contentDigest,
            attachments: record.attachments, referenceCard: record.referenceCard
        )
        #expect(ChatAttachmentPersistence.restoreAttachments(from: persisted, records: [wrongIndex]).messages.first?.referenceCard == nil)
        #expect(ChatAttachmentPersistence.restoreAttachments(from: persisted, records: records).messages.first?.referenceCard == submission.referenceCard)
        #expect(ChatAttachmentPersistence.restoreAttachments(from: persisted, records: nil).messages.first?.referenceCard == nil)
        #expect(ChatAttachmentPersistence.restoreAttachments(from: persisted, records: records + records).messages.first?.referenceCard == nil)
        let wrongSession = ChatSession(id: UUID().uuidString, messages: persisted.messages)
        #expect(ChatAttachmentPersistence.restoreAttachments(from: wrongSession, records: records).messages.first?.referenceCard == nil)
        var edited = persisted
        edited.messages[0] = LLMMessage(role: .user, content: "已改写")
        #expect(ChatAttachmentPersistence.restoreAttachments(from: edited, records: records).messages.first?.referenceCard == nil)
        var staleRecords = records
        staleRecords[0].referenceCard = PastedTextReferenceCard(id: draft.id, sessionID: sessionID, instruction: "不同指令", material: "不同资料")
        #expect(ChatAttachmentPersistence.restoreAttachments(from: persisted, records: staleRecords).messages.first?.referenceCard == nil)

        // A known attachment suffix may follow the entire pasted material.
        // Recomposition uses only frozen attachment values, never their paths.
        let textAttachment = ChatAttachment(kind: .text, fileName: "owned-context.md",
            fileType: .markdown, data: Data("owned attachment text".utf8))
        let fileAttachment = ChatAttachment(kind: .file, fileName: "owned-reference.bin",
            fileType: .unknown, size: 23, fileURL: "/owned-synthetic/no-read/reference.bin")
        let attachments = [textAttachment, fileAttachment]
        let composed = ChatStore.composeUserContent(text: submission.fullText, attachments: attachments)
        let composedThread = ChatThread(id: sessionID, messages: [
            ChatMessageUI(role: .user, content: composed, attachments: attachments,
                          referenceCard: submission.referenceCard)
        ])
        let composedPersisted = composedThread.asPersisted()
        let composedRecord = try #require(ChatAttachmentPersistence.records(for: composedThread).messages.first)
        #expect(composedRecord.referenceCard == submission.referenceCard)
        #expect(ChatAttachmentPersistence.restoreAttachments(from: composedPersisted,
            records: [composedRecord]).messages.first?.referenceCard == submission.referenceCard)
        // The unchanged canonical content digest must not authorize removing
        // a different, reordered, absent or edited attachment tail.
        for mismatchedAttachments in [[], [fileAttachment, textAttachment], [textAttachment],
            [ChatAttachment(kind: .text, fileName: "wrong.md", fileType: .markdown,
                            data: Data("owned attachment text".utf8)), fileAttachment]] {
            let mismatch = ChatAttachmentPersistence.MessageRecord(
                messageIndex: composedRecord.messageIndex,
                contentDigest: composedRecord.contentDigest,
                attachments: mismatchedAttachments, referenceCard: composedRecord.referenceCard)
            #expect(ChatAttachmentPersistence.restoreAttachments(from: composedPersisted,
                records: [mismatch]).messages.first?.referenceCard == nil)
        }
        let extraTail = ChatThread(id: sessionID, messages: [
            ChatMessageUI(role: .user, content: composed + "\nunknown extra tail",
                          attachments: attachments, referenceCard: submission.referenceCard)
        ])
        let extraRecord = try #require(ChatAttachmentPersistence.records(for: extraTail).messages.first)
        #expect(extraRecord.referenceCard == nil)
        #expect(extraTail.messages.first?.content == composed + "\nunknown extra tail")
    }

    @Test("session-read intent is no longer restored from the sidecar")
    func sessionReadIntentIsDroppedOnReopenAndLegacyData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trusted-intent-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let intent = "授权只读查看会话 trusted-target，读取消息"
        let thread = ChatThread(
            id: sessionID,
            messages: [
                ChatMessageUI(
                    role: .user,
                    content: intent,
                    trustedSessionReadIntent: intent
                ),
            ]
        )
        let store = SessionStore(directory: root)
        try store.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: root)))
        let restored = try #require(reopened.messages.last(where: { $0.role == .user }))
        #expect(restored.trustedSessionReadIntent == nil)
    }

    @Test("future and corrupt sidecar bytes survive ordinary transcript writes")
    func invalidReferenceSidecarIsPreserved() throws {
        for bytes in [Data("{bad".utf8), Data(#"{"schemaVersion":999,"sessions":[]}"#.utf8)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-invalid-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sidecar = ChatAttachmentPersistence.url(in: root)
            try bytes.write(to: sidecar)
            let chat = ChatStore()
            #expect(chat.attachPersistence(SessionStore(directory: root)))
            chat.appendUser("普通转录仍可保存")
            #expect(try Data(contentsOf: sidecar) == bytes)
            #expect(SessionStore(directory: root).listSessions().contains { $0.messages.contains { $0.content == "普通转录仍可保存" } })
        }
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
