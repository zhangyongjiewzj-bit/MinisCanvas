import AppKit
import SwiftUI
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Goal18 interaction contracts")
@MainActor
struct Goal18InteractionTests {
    @Test func approvalShortcutSafetySurvivesUIChangesAndPersistedReplay() throws {
        let suite = "goal18-approval-shortcuts-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        let customSend = ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(customSend, for: .sendMessage) == nil)
        let before = defaults.data(forKey: "miniscanvas.shortcuts.v1")
        let enterAliases = ["return", " RETURN ", "enter", "KEYPADENTER", "keypad enter", "numpadenter", "numpad enter", "↩", "↵", "⏎", "⌤", "\r", "\n", "\r\n", "\u{3}"]
        for action in [ShortcutAction.approveRequest, .rejectRequest] {
            for modifiers in [ShortcutModifiers.none, .control, .init(shift: true)] {
                #expect(store.setBinding(ShortcutBinding(key: "g", modifiers: modifiers), for: action) == .approvalSafety)
            }
            for alias in enterAliases {
                #expect(ShortcutBinding(key: alias, modifiers: ShortcutModifiers.command).key == "return")
                #expect(store.setBinding(ShortcutBinding(key: alias, modifiers: ShortcutModifiers.command), for: action) == .approvalSafety)
            }
            #expect(store.binding(for: action) == action.defaultBinding)
        }
        #expect(defaults.data(forKey: "miniscanvas.shortcuts.v1") == before)
        #expect(ShortcutConflict.approvalSafety.message.contains("Return/Enter"))
        let recorder = ShortcutRecorderModel(store: store)
        for action in [ShortcutAction.approveRequest, .rejectRequest] {
            recorder.recordingAction = action
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
            recorder.handle(event)
            #expect(recorder.conflictError == .approvalSafety)
            #expect(recorder.recordingAction == nil)
            #expect(store.binding(for: action) == action.defaultBinding)
        }
        #expect(ShortcutBinding.keyName(fromKeyCode: 76, charactersIgnoringModifiers: "\u{3}") == "return")
        #expect(store.setBinding(ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .approveRequest) == nil)
        #expect(ShortcutStore(defaults: defaults).binding(for: .approveRequest).key == "g")
        #expect(store.binding(for: .sendMessage) == customSend)
        var bypassedConstructor = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        bypassedConstructor.key = "\rg"
        #expect(store.setBinding(bypassedConstructor, for: .approveRequest) == nil)
        #expect(store.binding(for: .approveRequest).key == "g")

        // Legacy Codable values bypass constructors. Reopening must discard
        // every illegal approval override, while keeping another action intact.
        for alias in enterAliases + ["g"] {
            var unsafe = ShortcutBinding(key: "g", modifiers: alias == "g" ? ShortcutModifiers.none : .command)
            unsafe.key = alias
            let values = [ShortcutAction.approveRequest.id: unsafe,
                ShortcutAction.rejectRequest.id: unsafe, ShortcutAction.sendMessage.id: customSend]
            defaults.set(try JSONEncoder().encode(values), forKey: "miniscanvas.shortcuts.v1")
            let reopened = ShortcutStore(defaults: defaults)
            #expect(reopened.binding(for: .approveRequest) == ShortcutAction.approveRequest.defaultBinding)
            #expect(reopened.binding(for: .rejectRequest) == ShortcutAction.rejectRequest.defaultBinding)
            #expect(reopened.binding(for: .sendMessage) == customSend)
        }
    }

    @Test func typedApprovalShortcutProposalCannotReplayAnEnterBinding() throws {
        let suite = "goal18-approval-shortcut-replay-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        #expect(store.setBinding(ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command), for: .sendMessage) == nil)
        let profile = "/synthetic/goal18-approval-shortcuts"
        let snapshot = try store.bl6Snapshot(profileID: profile).get()
        for action in [ShortcutAction.approveRequest, .rejectRequest] {
            for (key, command) in [("return", true), ("g", false)] {
                let value: BL6SettingValue = .object(["key": .text(key), "modifiers": .object([
                    "command": .toggle(command), "control": .toggle(false), "option": .toggle(false), "shift": .toggle(false)])])
                let input = BL6SettingsApprovedInput(operation: .apply,
                    changes: ["shortcuts." + action.rawValue: value], expectedRevision: snapshot.revision)
                switch store.prepareBL6Replay(input, profileID: profile) {
                case .failure(.conflict): break
                default: Issue.record("unsafe approval shortcut replay proposal was admitted")
                }
            }
        }
        #expect(try store.bl6Snapshot(profileID: profile).get().revision == snapshot.revision)
    }

    @Test func modifiedReturnBindingsDoNotOverlapApprovalOrIME() {
        #expect(ComposerModifiedReturnAction.resolve(keyCode: 36, flags: .command, hasMarkedText: false) == .send)
        #expect(ComposerModifiedReturnAction.resolve(keyCode: 36, flags: [.command, .shift], hasMarkedText: false) == .interruptAndSend)
        let editingFlags: [NSEvent.ModifierFlags] = [[], .option, [.command, .option], [.command, .control]]
        for flags in editingFlags {
            #expect(ComposerModifiedReturnAction.resolve(keyCode: 36, flags: flags, hasMarkedText: false) == nil)
        }
        #expect(ComposerModifiedReturnAction.resolve(keyCode: 36, flags: [.command, .shift], hasMarkedText: true) == nil)
        #expect(ShortcutAction.approveRequest.defaultBinding == ShortcutBinding(key: "y", modifiers: ShortcutModifiers.command))
        #expect(ShortcutAction.rejectRequest.defaultBinding == ShortcutBinding(key: "y", modifiers: ShortcutModifiers.commandShift))
        #expect(ShortcutAction.sendMessage.defaultBinding == ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command))
        #expect(ShortcutAction.composerMode.defaultBinding == ShortcutBinding(key: "m", modifiers: ShortcutModifiers.commandShift))
        let mode = ShortcutAction.composerMode.defaultBinding
        #expect(!ShortcutAction.allCases.contains { $0 != .composerMode && $0.defaultBinding == mode })
    }

    @Test func nativeModifiedReturnCallsOnlyItsOwner() throws {
        let view = ComposerPasteAwareTextView(frame: .zero)
        var sends = 0, interrupts = 0
        view.onCommandReturn = { sends += 1 }
        view.onInterruptAndSend = { interrupts += 1 }
        let submitFlags: [NSEvent.ModifierFlags] = [.command, [.command, .shift]]
        for flags in submitFlags {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            view.keyDown(with: event)
        }
        #expect(sends == 1)
        #expect(interrupts == 1)
    }

    @Test func nativeMarkedEscapeFinishesCompositionBeforeOtherComposerActions() throws {
        var draft = "保留草稿", sends = 0, stops = 0, commands = 0
        var field = ScrollableComposerTextView(text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13), onSend: { sends += 1 })
        field.onStop = { stops += 1; return true }
        field.onCommandKey = { _ in commands += 1; return true }
        let coordinator = field.makeCoordinator()
        coordinator.onCommandKey = field.onCommandKey
        let input = ComposerPasteAwareTextView(frame: .zero)
        input.delegate = coordinator
        input.string = draft
        input.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(input.hasMarkedText())
        let composed = input.string
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        input.keyDown(with: escape)
        #expect(!input.hasMarkedText())
        #expect(input.string == composed && draft == composed)
        #expect(sends == 0 && stops == 0 && commands == 0)
    }

    @Test func composingReturnAndEscapeDoNotSubmitOrRewriteDraft() {
        var draft = "保留草稿", sends = 0, stops = 0
        var field = ScrollableComposerTextView(text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13), onSend: { sends += 1 })
        field.onStop = { stops += 1; return true }
        let coordinator = field.makeCoordinator()
        let text = ComposerPasteAwareTextView(frame: .zero)
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        #expect(!coordinator.textView(text, doCommandBy: NSSelectorFromString("insertNewline:")))
        #expect(sends == 0 && stops == 0)
        text.unmarkText()
        #expect(coordinator.textView(text, doCommandBy: NSSelectorFromString("cancelOperation:")))
        #expect(stops == 1 && sends == 0)
        #expect(draft == "保留草稿")
    }

    @Test func imeRefreshPreservesCompositionAndSessionSwitchDoesNotCommitIntoNextDraft() {
        let first = UUID(), second = UUID()
        var bindingWrites = 0
        var field = ScrollableComposerTextView(text: Binding(get: { "原草稿" }, set: { _ in bindingWrites += 1 }),
            font: .systemFont(ofSize: 13), onSend: {})
        field.draftSessionID = first
        let coordinator = field.makeCoordinator()
        let text = ComposerPasteAwareTextView(frame: .zero)
        text.delegate = coordinator
        text.setMarkedText("输入法候选", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let composed = text.string
        let writesBeforeSynchronization = bindingWrites
        coordinator.synchronizeDraft("原草稿", sessionID: first, in: text)
        #expect(text.hasMarkedText())
        #expect(text.string == composed)
        coordinator.synchronizeDraft("第二会话草稿", sessionID: second, in: text)
        #expect(!text.hasMarkedText())
        #expect(text.string == "第二会话草稿")
        #expect(bindingWrites == writesBeforeSynchronization)
    }

    @Test func copyKeepsMessageAndEachCodeBlockExact() {
        let body = "说明\n```swift\n  let x = 1  \n\tprint(x)\n```\n后文\n```text\n第二块\n```"
        let copy = ChatTranscriptCopyProjection(redactedBody: body)
        #expect(copy.message == body)
        #expect(copy.codeBlocks == ["  let x = 1  \n\tprint(x)", "第二块"])
        #expect(ChatTranscriptCopyProjection(redactedBody: "没有代码").codeBlocks.isEmpty)
    }

    @Test func modesUseExistingCoreCeilingAndNeverEnableUnknownFacts() {
        let disabled = ComposerTaskMode.allCases.filter { !ComposerModeAvailability.isEnabled($0, ceiling: .l1) }
        #expect(Set(disabled) == Set([.autoEdit, .auto, .bypassPermission]))
        #expect(ComposerTaskMode.allCases.allSatisfy { !ComposerModeAvailability.isEnabled($0, ceiling: nil) })
        let explanation = ComposerModeAvailability.explanation(.auto, ceiling: .l1)
        #expect(explanation.contains("权限上限") && !explanation.contains("L3"))
    }

    @Test func explicitPersistedInterruptChoiceSurvivesNewQueueDefault() throws {
        #expect(!AgentSettings.default.newMessageInterruptsGeneration)
        var existing = AgentSettings.default
        existing.newMessageInterruptsGeneration = true
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(existing))
        #expect(decoded.newMessageInterruptsGeneration)
    }

    @Test func interruptionAndRangeMetadataNeverEnterPersistedBody() {
        var message = ChatMessageUI(role: .assistant, content: "模型正文")
        message.wasInterrupted = true
        #expect(ChatTranscriptFormatter.persistedEntries([message]).first?.text == "模型正文")
        let displayed = ChatTranscriptFormatter.attributedString([message]).string
        #expect(displayed.contains("已中断"))
        #expect(ChatTranscriptFormatter.accessibilityText([message]).contains("已中断"))
        #expect(ChatTranscriptFormatter.plainText([message]).contains("已中断") == false)
        message.content = ""
        #expect(ChatTranscriptFormatter.accessibilityText([message]).contains("已中断"))
        let text = ChatAttachment(kind: .text, fileName: "long.txt", fileType: .text,
            data: Data("前缀".utf8), originalTextCharacterCount: 4)
        let ranged = ChatMessageUI(role: .user, content: "原始消息", attachments: [text])
        #expect(ChatTranscriptFormatter.attributedString([ranged]).string.contains("已发送前"))
        #expect(ChatTranscriptFormatter.persistedEntries([ranged]).first?.text.contains("已发送前") == false)
    }

    @Test func checkpointEntryDefaultsOnAndPreservesExplicitOff() throws {
        #expect(AgentSettings.default.fileCheckpointsEnabled)
        var saved = AgentSettings.default
        saved.fileCheckpointsEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: encoded).fileCheckpointsEnabled == false)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "fileCheckpointsEnabled")
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.fileCheckpointsEnabled)
    }

    /// E2：后台任务完成后自动续跑默认开；显式关闭会保存；旧 JSON 没有这个字段时按默认开。
    @Test func backgroundAutoContinueDefaultsOnAndPreservesExplicitOff() throws {
        #expect(AgentSettings.default.backgroundAutoContinueEnabled)
        var saved = AgentSettings.default
        saved.backgroundAutoContinueEnabled = false
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: encoded).backgroundAutoContinueEnabled == false)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "backgroundAutoContinueEnabled")
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.backgroundAutoContinueEnabled)
    }

    @Test func toolEventKindsUseKeylineWithoutChangingTheirSemanticLabels() throws {
        let candidateIdentity: MinisCore.ConversationEventIdentity? = MinisCore.ConversationEventIdentity(
            sessionID: "test-session", turnID: "1", taskID: "test-task", attempt: 1, scopeID: "test-scope")
        let identity = try #require(candidateIdentity)
        let kinds: [(MinisCore.ConversationEventKind, MinisIcon, String)] = [
            (.thinking, .activity, "思考"), (.stop, .stop, "停止"),
            (.duration, .schedule, "耗时"), (.model, .server, "模型"),
            (.tool, .command, "工具"), (.approval, .success, "审批"), (.task, .task, "任务")
        ]
        for (kind, icon, label) in kinds {
            let event = MinisCore.ConversationEvent(id: kind.rawValue, identity: identity,
                sequence: 1, occurredAt: Date(), kind: kind, status: .succeeded, summary: "原始事件正文")
            #expect(ToolEventCard.semanticIcon(for: kind) == icon)
            let display = ToolEventCard.displayModel(for: event)
            #expect(display.kind == label)
            #expect(display.accessibilityLabel.contains(label))
        }
    }

    @Test func toolFailureUsesActionableCopyAndRefusalRemainsNeutral() throws {
        let candidateIdentity: MinisCore.ConversationEventIdentity? = MinisCore.ConversationEventIdentity(
            sessionID: "test-session", turnID: "1", taskID: "test-task", attempt: 1, scopeID: "test-scope")
        let identity = try #require(candidateIdentity)
        let failed = MinisCore.ConversationEvent(id: "failed", identity: identity, sequence: 1, occurredAt: Date(),
            kind: .tool, status: .failed, summary: "diagnostic only", toolName: "file_write",
            toolTargetDisplay: "output.md", errorCategory: .tool)
        let failure = ToolEventCard.displayModel(for: failed)
        #expect(failure.summary.contains("请查看结果详情后重试"))  // 11/16 工具失败提示写明阶段与下一步
        #expect(failure.errorCategory == nil)
        #expect(!failure.accessibilityLabel.contains("错误 tool"))
        let denied = MinisCore.ConversationEvent(id: "denied", identity: identity, sequence: 2, occurredAt: Date(),
            kind: .approval, status: .failed, summary: "safe", toolName: "file_write",
            approvalDecision: .denied, errorCategory: .authorization)
        let refusal = ToolEventCard.displayModel(for: denied)
        #expect(refusal.status == "已拒绝")
        #expect(!refusal.summary.contains("权限不足"))
    }

    @Test func toolTargetIsStructuredBoundedAndOldEventsDecode() throws {
        let candidateIdentity: MinisCore.ConversationEventIdentity? = MinisCore.ConversationEventIdentity(
            sessionID: "test-session", turnID: "1", taskID: "test-task", attempt: 1, scopeID: "test-scope")
        let identity = try #require(candidateIdentity)
        let event = MinisCore.ConversationEvent(id: "event", identity: identity, sequence: 1, occurredAt: Date(),
            kind: .tool, status: .succeeded, summary: "raw text must not be used as a target",
            toolName: "file_write", toolTargetDisplay: "report.md", elapsedMilliseconds: 600)
        let card = ToolEventCard.displayModel(for: event)
        #expect(card.summary.contains("report.md"))
        #expect(card.status == "完成")
        #expect(!card.accessibilityLabel.contains("Provider 未标识"))
        let protected = MinisCore.ConversationEvent(id: "protected", identity: identity, sequence: 2, occurredAt: Date(),
            kind: .tool, status: .succeeded, summary: "safe", toolName: "shell_execute",
            toolTargetDisplay: "syntheticOpaqueTargetValue", knownSecrets: ["syntheticOpaqueTargetValue"])
        #expect(protected.toolTargetDisplay?.contains("syntheticOpaqueTargetValue") == false)
        let long = MinisCore.ConversationEvent(id: "long", identity: identity, sequence: 3, occurredAt: Date(),
            kind: .tool, status: .succeeded, summary: "safe", toolTargetDisplay: String(repeating: "x", count: 400))
        #expect(long.toolTargetDisplay?.count == 120)
        let encodedEvent = try JSONEncoder().encode(event)
        let legacyObject = try JSONSerialization.jsonObject(with: encodedEvent)
        var legacy = try #require(legacyObject as? [String: Any])
        legacy.removeValue(forKey: "toolTargetDisplay")
        let restored = try JSONDecoder().decode(MinisCore.ConversationEvent.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.toolTargetDisplay == nil)
    }
    @Test func inspectorCapNoticeDistinguishes39From40AndLoadedPages() {
        #expect(ChatInspectorListPresentation.summary(count: 39, limit: 40, unit: "项") == "39 项")
        #expect(ChatInspectorListPresentation.summary(count: 40, limit: 40, unit: "项") == "最近 40 项（上限）")
        #expect(ChatInspectorListPresentation.summary(count: 80, limit: 40, unit: "条") == "80 条")
        let path = ChatInspectorListPresentation.pathParts("/project/Sources/Feature/output.swift")
        #expect(path.fileName == "output.swift")
        #expect(path.parent == "…/Sources/Feature")
    }

    @Test func userBrowserAddressActionsRejectOtherSchemesAndMissingHost() throws {
        #expect(UserBrowserAddressAction.allowedURL(URL(string: "https://example.invalid/page")) != nil)
        #expect(UserBrowserAddressAction.allowedURL(URL(string: "http://example.invalid/")) != nil)
        #expect(UserBrowserAddressAction.allowedURL(URL(string: "file:///tmp/example.html")) == nil)
        #expect(UserBrowserAddressAction.allowedURL(URL(string: "about:blank")) == nil)
        #expect(UserBrowserAddressAction.allowedURL(URL(string: "javascript:alert(1)")) == nil)
        #expect(UserBrowserAddressAction.allowedURL(nil) == nil)
    }

    @Test func editingConfirmationBindsWholeDraftAndSourceSession() {
        let session = UUID()
        let empty = ComposerEditDraftIdentity(sessionID: session, text: "", attachments: [], pastedDrafts: [], editingMessageID: nil)
        #expect(!empty.needsConfirmation)
        let text = ComposerEditDraftIdentity(sessionID: session, text: " ", attachments: [], pastedDrafts: [], editingMessageID: nil)
        #expect(text.needsConfirmation)
        let other = ComposerEditDraftIdentity(sessionID: UUID(), text: " ", attachments: [], pastedDrafts: [], editingMessageID: nil)
        #expect(text != other)
        let changed = ComposerEditDraftIdentity(sessionID: session, text: "changed", attachments: [], pastedDrafts: [], editingMessageID: nil)
        #expect(text != changed)
        let attachment = ChatAttachment(kind: .file, fileName: "draft.bin", fileType: .unknown)
        let files = ComposerEditDraftIdentity(sessionID: session, text: "", attachments: [attachment], pastedDrafts: [], editingMessageID: nil)
        #expect(files.needsConfirmation)
        #expect(files != empty)
        let capsule = PastedTextDraft(id: UUID(), text: "capsule", source: .pasteboard)
        let pasted = ComposerEditDraftIdentity(sessionID: session, text: "", attachments: [], pastedDrafts: [capsule], editingMessageID: nil)
        #expect(pasted.needsConfirmation)
        #expect(pasted != empty)
    }

    @Test @MainActor func authorizationFeedbackExpiryUsesInjectedClockAndPreservesReplacement() async {
        var shown: String? = "first"
        var advanced = false
        await ChatAuthorizationFeedbackExpiry.waitToClear(expected: "first", sleep: { advanced = true },
            current: { shown }, clear: { shown = nil })
        #expect(advanced)
        #expect(shown == nil)
        shown = "first"
        await ChatAuthorizationFeedbackExpiry.waitToClear(expected: "first", sleep: { shown = "replacement" },
            current: { shown }, clear: { shown = nil })
        #expect(shown == "replacement")
        await ChatAuthorizationFeedbackExpiry.waitToClear(expected: "replacement", sleep: { throw CancellationError() },
            current: { shown }, clear: { shown = nil })
        #expect(shown == "replacement")
    }

    @Test("A folder becomes a path reference, never read as bytes", arguments: [false, true])
    func directoryAttachmentIsPathReference(hinted: Bool) async throws {
        let (chat, provider, root) = try smallP1AttachmentFixture(vision: false)
        defer { chat.stopAllStreamingForSafety() }
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory.path, isDirectory: hinted)
        let staged = chat.addAttachments(urls: [url])
        let attachment = try #require(staged.first)
        if !hinted {
            let owner = try #require(chat.activeSessionID)
            if let preparation = chat.attachmentPreparationTask(for: attachment, sessionID: owner) {
                _ = await preparation.value
            }
        }
        let current = try #require(chat.pendingAttachments.first)
        #expect(chat.pendingAttachments.count == 1)
        #expect(current.status == .ready && current.kind == .file)
        #expect(current.mimeType == ChatStore.directoryAttachmentMimeType)
        #expect(ChatStore.composeUserContent(text: "", attachments: [current]).contains("这是目录"))
        #expect(provider.calls.isEmpty)
    }

    @Test("Attachment failures distinguish encoding, byte limit and unreadable file", arguments: ["encoding", "size", "missing"])
    func attachmentFailureReason(kind: String) async throws {
        let (chat, provider, root) = try smallP1AttachmentFixture(vision: false)
        defer { chat.stopAllStreamingForSafety() }
        let url = root.appendingPathComponent(kind == "size" ? "oversized.png" : "invalid.txt")
        let expected: String
        switch kind {
        case "encoding":
            try Data([0xff, 0xff, 0xfe]).write(to: url)
            expected = "UTF-8"
        case "size":
            try Data(repeating: 0, count: ChatStore.maxBinaryAttachmentBytes + 1).write(to: url)
            expected = "自动转换失败"  // 超过 25 MB 的图片先尝试转码；全零字节不是可解码图片，转码失败
        default: expected = "无法读取"
        }
        _ = chat.addAttachments(urls: [url])
        try await waitForSmallP1Attachment { chat.pendingAttachments.first?.status == .failed }
        let failed = try #require(chat.pendingAttachments.first)
        #expect(failed.failureReason?.contains(expected) == true)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(provider.calls.isEmpty)
    }

    @Test("Unsupported media explains an actionable alternative from the real model gate")
    func unsupportedMediaReasonProvidesRecovery() async throws {
        let (chat, _, root) = try smallP1AttachmentFixture(vision: false)
        defer { chat.stopAllStreamingForSafety() }
        let url = root.appendingPathComponent("image.png")
        try smallP1AttachmentPNG().write(to: url)
        _ = chat.addAttachments(urls: [url])
        try await waitForSmallP1Attachment { chat.pendingAttachments.first?.kind == .image }
        let attachment = try #require(chat.pendingAttachments.first)
        let projected = try #require(chat.composerMediaReadinessSnapshot.attachment(id: attachment.id))
        #expect(projected.readiness == .unsupported)
        #expect(projected.reason.contains("移除附件"))
        #expect(!chat.canSubmitComposerAttachments)
    }

    @Test("source card status uses Chinese display while preserving canonical serialization", arguments: [
        ("running", "运行中"), ("succeeded", "已完成"), ("failed", "失败"), ("unavailable", "不可用")
    ])
    func sourceCardStatusDisplayPreservesCanonicalValue(_ rawValue: String, _ displayTitle: String) throws {
        let status = try #require(SessionReferenceCard.Status(rawValue: rawValue))
        #expect(status.displayTitle == displayTitle)
        let encoded = try JSONEncoder().encode(status)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(rawValue)\"")
        #expect(try JSONDecoder().decode(SessionReferenceCard.Status.self, from: encoded) == status)
    }

    @Test("危险确认展示参数、先脱敏再限长，不改执行命令")
    func confirmationPreviewKeepsArgumentsWithoutLeakingSecret() throws {
        let secret = "sk-" + String(repeating: "a", count: 40)
        let raw = "curl --header 'Authorization: Bearer \(secret)' --output report.json https://example.invalid/api"
        let command = try #require(TerminalGuard.parse(raw))
        #expect(command.confirmationPreview.contains("--output report.json"))
        #expect(command.confirmationPreview.contains("https://example.invalid/api"))
        #expect(!command.confirmationPreview.contains(secret))
        #expect(command.raw == raw)
        #expect(command.args.contains("--header"))
        let long = try #require(TerminalGuard.parse("rm -- " + String(repeating: "x", count: 5000)))
        #expect(long.confirmationPreview.count <= 4096)
        #expect(long.confirmationPreview.hasSuffix("…"))
        #expect(long.raw.count > 4096)
    }


    @Test func directorySuggestionsNeverEvaluateProductionHomeForDisposableProfiles() {
        let syntheticRoot = URL(fileURLWithPath: "/synthetic/isolated-S32", isDirectory: true)
        for mode in [RuntimeIsolationProfile.Mode.isolatedTest, .packagedField, .blocked] {
            var productionHomeReads = 0
            let suggestions = ExternalSessionAuthorizationComposition.directorySelectionSuggestions(
                mode: mode, profileRoot: syntheticRoot,
                productionHome: {
                    productionHomeReads += 1
                    return URL(fileURLWithPath: "/must-not-be-used")
                })
            #expect(productionHomeReads == 0)
            #expect(suggestions.codex == syntheticRoot)
            #expect(suggestions.claudeCode == syntheticRoot)
        }
        let suggestions = ExternalSessionAuthorizationComposition.directorySelectionSuggestions(
            mode: .production, profileRoot: syntheticRoot,
            productionHome: { URL(fileURLWithPath: "/synthetic/home-S32", isDirectory: true) })
        #expect(suggestions.codex.path == "/synthetic/home-S32/.codex/sessions")
        #expect(suggestions.claudeCode.path == "/synthetic/home-S32/.claude/projects")
    }

    @Test func schedulerRecordLabelsCoverEveryCurrentOccurrenceAndReceiptState() {
        let states: [(SchedulerOccurrenceState, String)] = [
            (.triggered, "待调度"), (.waitingApproval, "等待授权"), (.authorized, "已授权"),
            (.admitted, "已接纳"), (.dispatched, "已派发"), (.leased, "已取得执行租约"),
            (.running, "执行中"), (.succeeded, "已完成"), (.failed, "执行失败"),
            (.cancelled, "已取消"), (.unknown, "结果未知"), (.unknownReconciled, "未知结果已核对"),
            (.retryRequested, "已请求重试"), (.aborted, "已终止")
        ]
        for (state, label) in states {
            #expect(SchedulerSlashObservation.userFacingState(for: state) == label)
        }
        #expect(SchedulerSlashObservation.userFacingDeliveryStatus(.delivered) == "已投递")
        #expect(SchedulerSlashObservation.userFacingDeliveryStatus(.failed) == "投递失败")
        #expect(SchedulerSlashObservation.userFacingDeliveryStatus(.unknown) == "投递结果未知")
    }

    @Test func schedulerConfirmationFailureDistinguishesExpiryTargetAndChangedConditions() {
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        #expect(SchedulerConfirmationFeedback.failureMessage(
            previewExpiresAt: now, hasValidTarget: true, now: now).contains("预览已过期"))
        #expect(SchedulerConfirmationFeedback.failureMessage(
            previewExpiresAt: now.addingTimeInterval(1), hasValidTarget: false, now: now).contains("不完整"))
        #expect(SchedulerConfirmationFeedback.failureMessage(
            previewExpiresAt: now.addingTimeInterval(1), hasValidTarget: true, now: now).contains("授权条件已变化"))
    }


    @Test func settingsNavigationPreservesTranscriptAndLateResultsCannotReplaceNextReceipt() async throws {
        // The two original 1050 consumers share one owned real Bridge here:
        // navigation has no chat turn; old App completions cannot settle the next turn.
        try #require(KeychainStore.isTesting)
        let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = paths.rootDirectory.appendingPathComponent("goal18-settings-open-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let suite = "goal18-settings-open-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: UUID().uuidString, title: "Synthetic settings navigation")
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        let chat = bridge.chat
        #expect(chat.attachPersistence(sessions))
        let center = ComposerCommandAdjudicationCenter()
        #expect(ProductionCommandRegistryWiring.bind(bridge: bridge, center: center))
        let provider = Goal18SmallP1AttachmentProvider(vision: false)
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        var effects = 0
        var openedTabs: [String?] = []
        bridge.deepLinkHandler.onOpenSettings = { tab in effects += 1; openedTabs.append(tab) }
        let originalMessages = chat.messages
        let originalSession = try #require(chat.activeSessionID)
        let updatedAt = chat.sessions.first { $0.id == originalSession }?.updatedAt
        bridge.activateCommandRow(id: "settings.open")
        let menuDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while effects == 0, ContinuousClock.now < menuDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(effects == 1 && openedTabs.count == 1 && openedTabs.allSatisfy { $0 == nil })
        #expect(chat.lastComposerCommandReceipt == nil)
        #expect(chat.messages == originalMessages && provider.calls.isEmpty)
        #expect(chat.sessions.first { $0.id == originalSession }?.updatedAt == updatedAt)

        let originalDispatch = try #require(chat.onRegisteredNonComposerSlashCommand)
        var dispatches = 0
        var firstResult: Bool?
        var heldCompletion: (@MainActor @Sendable (Bool) -> Void)?
        chat.onRegisteredNonComposerSlashCommand = { id, args, completion in
            dispatches += 1
            let occurrence = dispatches
            return originalDispatch(id, args) { succeeded in
                if occurrence == 1 {
                    firstResult = succeeded
                    heldCompletion = completion
                } else {
                    completion(succeeded)
                    completion(false)
                }
            }
        }
        let row = try #require(ComposerSlashCommandMenu.entries(matching: "/settings.open",
            registry: bridge.commandRegistry).first { $0.id == "settings.open" })
        #expect(row.shouldSendOnAccept && row.routedCommand?.id == "settings.open")
        chat.draftText = "/" + row.completionCommand.id
        chat.submitComposer()
        let firstSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let firstReceipt = try #require(chat.lastComposerCommandReceipt)
        #expect(firstReceipt.disposition == .pending)
        #expect(firstReceipt.commandID == "settings.open" && firstReceipt.sessionID == originalSession.uuidString)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while firstResult == nil, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstSucceeded = try #require(firstResult as Bool?)
        let held = try #require(heldCompletion)
        #expect(firstSucceeded && effects == 2 && dispatches == 1)
        #expect(chat.messages == originalMessages && provider.calls.isEmpty)
        #expect(chat.lastComposerCommandReceipt == firstReceipt)
        let nextSession = chat.applyNewSession(title: "Synthetic next settings navigation")
        #expect(nextSession != originalSession)
        let nextMessages = chat.messages
        chat.draftText = "/settings.open"
        chat.submitComposer()
        let nextSnapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let nextDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.lastComposerCommandReceipt?.disposition != .execute,
              ContinuousClock.now < nextDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let receipt = try #require(chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute && effects == 3 && dispatches == 2)
        #expect(openedTabs.allSatisfy { $0 == nil } && chat.messages == nextMessages)
        #expect(receipt.commandID == "settings.open" && receipt.args == [:])
        #expect(receipt.requestID != firstReceipt.requestID && receipt.sessionID == nextSession.uuidString)
        #expect(receipt.turnID == nextSnapshot.turnID && receipt.taskID == nextSnapshot.taskID)
        #expect(receipt.attemptID == nextSnapshot.attemptID && receipt.taskID != firstSnapshot.taskID)
        let stateURL = sessions.directory.appendingPathComponent("chat-composer-command-state.json")
        let settledBytes = try Data(contentsOf: stateURL)
        held(firstSucceeded)
        held(false)
        #expect(chat.lastComposerCommandReceipt == receipt)
        #expect(try Data(contentsOf: stateURL) == settledBytes)
        #expect(effects == 3 && dispatches == 2)
        #expect(chat.pendingComposerCommand == nil && center.pendingAdjudication == nil)
        #expect(chat.messages.filter { $0.role == .user }.isEmpty && provider.calls.isEmpty)
        #expect(!chat.hasStreamingTasksForSafety)
        #expect(sessions.loadSession(id: originalSession.uuidString)?.messages.isEmpty == true)
        #expect(sessions.loadSession(id: nextSession.uuidString)?.messages.isEmpty == true)
        chat.draftText = "/settings.reset"
        chat.submitComposer()
        await Task.yield()
        #expect(chat.draftText == "/settings.reset")
        #expect(chat.composerCommandValidationFailure?.message.contains("确认") == true)
        #expect(chat.lastComposerCommandReceipt == receipt && effects == 3)
        #expect(chat.messages.filter { $0.role == .user }.isEmpty && provider.calls.isEmpty)
    }

    private func smallP1AttachmentFixture(vision: Bool) throws -> (ChatStore, Goal18SmallP1AttachmentProvider, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-smallP1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "goal18-smallP1-" + UUID().uuidString))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "goal18-smallP1",
            grantEpoch: "synthetic", leaseID: "synthetic", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:goal18-smallP1")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        let provider = Goal18SmallP1AttachmentProvider(vision: vision)
        chat.streamingProviderOverride = provider
        return (chat, provider, root)
    }

    private func waitForSmallP1Attachment(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Goal18 attachment classification did not finish")
    }

    private func smallP1AttachmentPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(.red, atX: x, y: y) } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

}

private final class Goal18SmallP1AttachmentProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedModel: LLMModel
    private var recorded: [[LLMMessage]] = []
    let name = "goal18-smallP1-offline"
    var model: LLMModel {
        get { lock.withLock { storedModel } }
        set { lock.withLock { storedModel = newValue } }
    }
    var calls: [[LLMMessage]] { lock.withLock { recorded } }
    var capabilities: Set<ProviderCapability> { [.tools] }
    init(vision: Bool) {
        storedModel = LLMModel(id: vision ? "goal18-vision" : "goal18-text",
            displayName: "Synthetic attachment model", provider: "goal18-smallP1-offline",
            modalityOverride: vision ? .fullMultimodalInput : .textOnly)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        lock.withLock { recorded.append(messages) }
        return LLMResponse(text: "synthetic-final", stopReason: "end_turn", usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw MediaVideoExtractionFailure.unreadableSource
    }
}
