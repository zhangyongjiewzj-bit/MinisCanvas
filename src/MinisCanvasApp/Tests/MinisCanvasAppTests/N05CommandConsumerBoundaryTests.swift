import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N05 transcript export and real summary request consumers")
@MainActor
struct N05CommandConsumerBoundaryTests {
    @Test func copySelectionAndMarkdownExportUseProductionRedactionWithoutTruncatingBodies() throws {
        let secret = "n05-synthetic-private-credential-5276"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let longReply = "older-result " + String(repeating: "preserve visible text. ", count: 320)
            + secret + " end-of-long-reply"
        let messages = [
            ChatMessageUI(role: .user, content: "question " + secret),
            ChatMessageUI(role: .assistant, content: longReply),
            ChatMessageUI(role: .tool, content: "tool receipt " + secret),
            ChatMessageUI(role: .assistant, content: "newer-result " + secret),
            ChatMessageUI(role: .assistant, content: "unfinished", isStreaming: true)
        ]
        let olderCopy = try #require(SessionMarkdownExport.replyText(nth: 2, messages: messages, redactor: redactor))
        #expect(olderCopy.hasPrefix("older-result "))
        #expect(olderCopy.hasSuffix("end-of-long-reply"))
        #expect(olderCopy.count > 4096)
        #expect(!olderCopy.contains(secret))
        let latestCopy = try #require(SessionMarkdownExport.replyText(nth: 1, messages: messages, redactor: redactor))
        #expect(latestCopy.hasPrefix("newer-result "))
        #expect(!latestCopy.contains(secret) && !latestCopy.contains("unfinished"))
        #expect(SessionMarkdownExport.replyText(nth: 0, messages: messages, redactor: redactor) == nil)
        #expect(SessionMarkdownExport.replyText(nth: 3, messages: messages, redactor: redactor) == nil)

        let markdown = SessionMarkdownExport.markdown(title: "export-title " + secret,
            messages: messages, redactor: redactor)
        #expect(markdown.hasPrefix("# export-title "))
        #expect(!markdown.contains(secret))
        #expect(markdown.contains(olderCopy) && markdown.contains(latestCopy))
        #expect(markdown.contains("question") && markdown.contains("tool receipt"))
        #expect(markdown.contains("end-of-long-reply"))
    }

    @Test func resumePickerSelectionSwitchesToTheRetainedConversation() throws {
        let chat = ChatStore()
        let previous = try #require(chat.activeSessionID)
        chat.appendUser("retained conversation marker")
        chat.newSession()
        let current = try #require(chat.activeSessionID)
        #expect(current != previous)
        let consumer = N05DesktopCommandConsumer(chat: chat,
            openSettings: { _ in Issue.record("Resume must not open settings") },
            openModelPicker: { Issue.record("Resume must not open model picker") },
            openContext: { Issue.record("Resume must not open context") },
            openDoctor: { Issue.record("Resume must not open diagnostics") },
            enterPlanMode: { _ in Issue.record("Resume must not enter plan mode"); return false },
            redactor: { ChatTranscriptRedactor(secretValues: []) })
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
            effort: .standard, sessionID: current.uuidString, turnID: 1,
            taskID: "n05-resume", workspaceID: chat.composerWorkspaceID,
            createdAt: Date(), policyRevision: "n05-resume")
        _ = try consumer.execute(PendingCommandRequest(id: UUID(), commandID: "resume",
            requiresPolicyApproval: false), snapshot: snapshot)
        #expect(consumer.presentation == .resume)
        consumer.resume(previous)
        #expect(consumer.presentation == nil && chat.activeSessionID == previous)
        #expect(chat.messages.contains { $0.content == "retained conversation marker" })
        #expect(chat.sessions.contains { $0.id == current })
    }

    @Test func manualCompactResultFollowsDurableAdoptionWithoutChangingHistory() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("compact-result") { root async throws -> Void in
            let store = SessionStore(directory: root.appendingPathComponent("sessions"))
            let chat = ChatStore()
            defer { chat.stopAllStreamingForSafety() }
            try #require(chat.attachPersistence(store))
            let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
                allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
                revision: "compact-result", leaseID: "compact-result",
                expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
            chat.configureComposerPolicy(facts)
            chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
            let session = try #require(chat.activeSessionID)
            for index in 0..<4 {
                chat.appendUser("preserve original request \(index)")
                chat.appendAssistant("historical assistant explanation \(index): "
                    + String(repeating: "The decision remains reversible and the evidence is retained. ", count: 220))
            }
            let source = chat.messages
            let before = try #require(store.loadSession(id: session.uuidString))
            let provider = N05SummaryRequestProvider()
            await chat.runCompaction(history: source.filter { $0.role != .system }, keepRecent: 3,
                sessionID: session, expectedTranscriptRevision: before.transcriptRevision,
                providerBox: LLMProviderBox(value: provider))
            let result = try #require(chat.compactionPresentation)
            #expect(result.sessionID == session && result.state == .succeeded)
            #expect(result.message == "上下文已压缩")
            let committed = try #require(store.loadSession(id: session.uuidString))
            let availability = try store.compactionCheckpointAvailability(sessionID: session.uuidString)
            guard case .available(let checkpoint) = availability else {
                Issue.record("Successful feedback requires the real committed checkpoint")
                return
            }
            #expect(committed.transcriptRevision == checkpoint.resultTranscriptRevision)
            #expect(chat.transcriptRevision(forSession: session) == committed.transcriptRevision)
            #expect(committed.messages == before.messages && chat.messages == source)
            #expect(try ChatSessionBridge.resumeCanonicalMessages(sessionStore: store,
                sessionID: session.uuidString) == checkpoint.replacementHistory)
            #expect(provider.calls.count == 1)
            let next = chat.applyNewSession()
            #expect(next != session && chat.compactionPresentation?.sessionID != next)
            // The new request supersedes the prior token; an old completion cannot replace it.
            let current = chat.beginCompactionPresentation(sessionID: next)
            chat.finishCompactionPresentation(requestID: result.requestID, sessionID: session, state: .failed)
            #expect(chat.compactionPresentation?.requestID == current)
            #expect(chat.compactionPresentation?.state == .pending)
        }
    }

    @Test func manualCompactHintReachesTheActualSummaryProviderRequest() async throws {
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "n05-summary", leaseID: "n05-summary",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let session = try #require(chat.activeSessionID)
        for index in 0..<4 {
            chat.appendUser("preserve original request \(index)")
            chat.appendAssistant("historical assistant explanation \(index): "
                + String(repeating: "The decision remains reversible and the evidence is retained. ", count: 220))
        }
        let source = chat.messages.filter { $0.role != .system }
        let revision = chat.transcriptRevision(forSession: session)
        let provider = N05SummaryRequestProvider()
        let hint = "prioritize model selection and the rollback decision"
        await chat.runCompaction(history: source, keepRecent: 3, sessionID: session,
            expectedTranscriptRevision: revision, providerBox: LLMProviderBox(value: provider), hint: hint)
        let call = try #require(provider.calls.first)
        #expect(provider.calls.count == 1)
        #expect(call.systemPrompt?.contains(hint) == true)
        #expect(call.messages.contains { $0.content.contains("historical assistant explanation") })
        // A summary request must never replace the user-visible original transcript.
        #expect(chat.messages.filter { $0.role != .system } == source)
        let next = ChatMessageUI(role: .user, content: "Continue from the retained decision.")
        let projected = chat.providerHistoryApplyingTransientCompaction(source + [next], sessionID: session)
        #expect(projected.count < source.count + 1)
        #expect(projected.last == next)
        #expect(projected.contains { $0.content.contains("<context-summary>") })
        #expect(chat.messages.filter { $0.role != .system } == source)
        var edited = source
        edited[0].content += " Updated after compaction."
        #expect(chat.providerHistoryApplyingTransientCompaction(edited, sessionID: session) == edited)
    }
}

private final class N05SummaryRequestProvider: LLMProvider, @unchecked Sendable {
    struct Call: Sendable {
        let messages: [LLMMessage]
        let systemPrompt: String?
    }
    let name = "Mock"
    var model = LLMModel(id: "mock-echo", displayName: "Synthetic local summarizer", provider: "Mock")
    private let lock = NSLock()
    private var captured: [Call] = []
    var calls: [Call] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(Call(messages: messages, systemPrompt: systemPrompt)) }
        return LLMResponse(text: "Historical explanation: preserve the decision and rollback evidence.",
            stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("Manual compaction must use the summary request, not a new dialogue stream")
        throw LLMError.unsupportedCapability(.streaming)
    }
}

@Suite("Session Markdown optional safe tool summary consumer")
@MainActor
struct SessionMarkdownToolSummaryConsumerTests {
    @Test func actualExporterWritesDefaultBodyAndOptInSafeSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n11-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "n11-synthetic-private-secret"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])
        let messages = [ChatMessageUI(role: .system, content: "合法系统正文"),
                        ChatMessageUI(role: .user, content: "问题 " + secret),
                        ChatMessageUI(role: .assistant, content: "```swift\nprint(1)\n```"),
                        ChatMessageUI(role: .tool, content: "合法工具正文 " + secret)]
        let identityCandidate = MinisCore.ConversationEventIdentity(sessionID: "private-session-id",
            turnID: "private-turn-id", taskID: "private-task-id", attempt: 1, scopeID: "private-scope-id")
        let identity = try #require(identityCandidate)
        func event(kind: MinisCore.ConversationEventKind, name: String, elapsed: Int?) -> MinisCore.ConversationEvent {
            MinisCore.ConversationEvent(id: "private-event-id", identity: identity, sequence: 1,
                occurredAt: Date(), kind: kind, status: .succeeded,
                summary: "raw-summary " + secret, toolName: name,
                toolTargetDisplay: "private-target", toolCallID: "private-call-id",
                approvalIdentityDigest: "private-approval-digest", receiptID: "private-receipt-id",
                elapsedMilliseconds: elapsed)
        }
        let events = [event(kind: .tool, name: "file_write", elapsed: 125),
                      event(kind: .tool, name: "untrusted-tool-name-" + secret, elapsed: nil),
                      event(kind: .approval, name: "shell_execute", elapsed: 99)]
        let body = SessionMarkdownExport.markdown(title: "会话", messages: messages, redactor: redactor)
        #expect(body == SessionMarkdownExport.markdown(title: "会话", messages: messages,
            redactor: redactor, includeToolSummary: false, events: events))
        #expect(body.contains("```swift\nprint(1)\n```"))
        #expect(!body.contains("工具摘要"))
        #expect(body.contains("合法工具正文"))
        let expectedBody = "# 会话\n\n" + messages.map { message in
            let role = message.role == .user ? "用户" : message.role == .assistant ? "助手" : message.role == .system ? "系统" : "工具"
            return "## \(role)\n\n" + redactor.redactVisibleConversationBody(message.content)
        }.joined(separator: "\n\n---\n\n") + "\n"
        #expect(body == expectedBody)
        let included = SessionMarkdownExport.markdown(title: "会话", messages: messages,
            redactor: redactor, includeToolSummary: true, events: events)
        #expect(included.hasPrefix(body))
        #expect(included.contains("写入文件：完成；耗时 125 ms"))
        #expect(included.contains("工具调用：完成；耗时 未记录"))
        #expect(!included.contains("执行命令"))
        for output in [body, included] {
            for forbidden in [secret, "raw-summary", "private-", "untrusted-tool-name"] {
                #expect(!output.contains(forbidden))
            }
        }
        let destination = root.appendingPathComponent("会话.md")
        try SessionMarkdownExport.write(markdown: body, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == body)
        try SessionMarkdownExport.write(markdown: included, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == included)
    }

    @Test func optInWithoutRecordedToolsDoesNotInventExecutionOrDuration() {
        let markdown = SessionMarkdownExport.markdown(title: "空工具", messages: [],
            redactor: ChatTranscriptRedactor(secretValues: []), includeToolSummary: true)
        #expect(markdown.contains("暂无工具记录。"))
        #expect(!markdown.contains("0 ms"))
    }
}
