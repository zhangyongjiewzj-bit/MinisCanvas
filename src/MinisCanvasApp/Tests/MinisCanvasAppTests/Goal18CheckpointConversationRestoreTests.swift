import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D-6：恢复文件和对话后，触发那次写入的用户请求回到输入框，不留在对话里被下一轮重做。
@Suite("Goal18 checkpoint conversation restore returns the request", .serialized)
@MainActor
struct Goal18CheckpointConversationRestoreTests {
    @Test func nativeRestoreOfAnOutsideCheckpointRequiresCurrentConfirmedBypass() async throws {
        let f = try fixture("outside-bypass")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("g19-checkpoint-outside-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside); try? FileManager.default.removeItem(at: f.root) }
        let chat = f.chat
        let sessionID = try #require(chat.activeSessionID).uuidString
        let path = outside.appendingPathComponent("outside.txt")
        try Data("before".utf8).write(to: path)
        let store = try #require(chat.fileCheckpointStore)
        let builtin = BuiltinToolExecutor(allowedRoot: f.root, deniedRoots: [])
        builtin.fileCheckpointsEnabled = true
        builtin.fileCheckpointStore = store
        builtin.fileChangeSessionID = sessionID
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [f.root.path], workspaceID: chat.composerWorkspaceID,
            revision: "outside-restore", grantEpoch: "outside-restore", leaseID: "outside-restore",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let snapshot = ComposerSubmissionSnapshot(mode: .bypassPermission, approvalScope: .request, effort: .standard,
            sessionID: sessionID, turnID: 1, taskID: "outside-write", messageID: "outside-write",
            workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch, bypassModeConfirmed: true, autonomyCeiling: .l3)
        let executor = ComposerPolicyEnforcedToolExecutor(base: builtin,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts))
        _ = try await executor.execute(name: "file_write", input: ["path": path.path, "content": "after"])
        let id = try #require(chat.fileCheckpoints.first(where: { $0.path == path.path })?.id)
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        #expect(!(await chat.restoreFileCheckpoint(id, includeConversation: false)))
        #expect(try Data(contentsOf: path) == Data("after".utf8))
        chat.composerPolicySelection = .init(mode: .bypassPermission, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: true)
        #expect(await chat.restoreFileCheckpoint(id, includeConversation: false))
        #expect(try Data(contentsOf: path) == Data("before".utf8))
    }

    @Test func successfulTodoSurvivesCanonicalColdReadHeldTurnStopAndFileConversationRestore() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "todo-canonical-restore", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let sid = chat.applyNewSession(title: "owned todo checkpoint")
        let file = root.appendingPathComponent("owned-checkpoint.txt")
        let before = Data("owned before".utf8)
        try before.write(to: file)
        let checkpoints = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"), allowedRoots: [root])
        chat.fileCheckpointStore = checkpoints
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileCheckpointStore = checkpoints
        builtin.fileCheckpointsEnabled = true
        builtin.fileChangeSessionID = sid.uuidString
        let facts = ComposerPolicyFactSource(knownCapabilities: ["todo_write", "file_write"],
            grantedCapabilities: ["todo_write", "file_write"], allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "owned-todo", grantEpoch: "owned-todo",
            leaseID: "owned-todo", expiresAt: Date().addingTimeInterval(120), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: builtin,
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil) }
        let a = SessionTodoProgress(todos: [.init(content: "owned A", status: .in_progress), .init(content: "owned B", status: .pending)])
        let c = SessionTodoProgress(todos: [.init(content: "owned A", status: .completed), .init(content: "owned B", status: .in_progress)])
        func progressInput(_ progress: SessionTodoProgress) throws -> [String: Any] {
            ["progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))]
        }
        func submit(_ provider: CheckpointTodoProductionProvider, text: String) throws -> Task<Void, Never> {
            chat.streamingProviderOverride = provider
            chat.draftText = text
            chat.submitComposer()
            return try #require(chat.turnTaskForTests(sessionID: sid))
        }
        let aProvider = CheckpointTodoProductionProvider(tool: "todo_write", input: try progressInput(a))
        await (try submit(aProvider, text: "owned todo A")).value
        #expect(aProvider.requests == 2)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == a)
        let coldA = try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString))
        #expect(SessionTodoProgress.latest(in: coldA.messages) == a)
        let aCalls = coldA.messages.flatMap(\.toolCalls).filter { $0.name == SessionTodoProgress.toolName }
        #expect(aCalls.count == 1)
        #expect(coldA.messages.filter { $0.role == .tool && $0.toolCallID == aCalls.first?.id }.count == 1)

        let bProvider = CheckpointTodoProductionProvider(tool: "file_write", input: [
            "path": file.path, "content": "owned after", "append": false, "create_dirs": false])
        await (try submit(bProvider, text: "owned write B")).value
        #expect(bProvider.requests == 2)
        #expect(try Data(contentsOf: file) == Data("owned after".utf8))
        let checkpoint = try #require(chat.fileCheckpoints.first { $0.path == file.standardizedFileURL.path })
        #expect(checkpoint.hasConversation)

        let cProvider = CheckpointTodoProductionProvider(tool: "todo_write", input: try progressInput(c), holdAfterTool: true)
        let held = try submit(cProvider, text: "owned todo C then hold")
        let deadline = ContinuousClock.now + .seconds(5)
        while (cProvider.requests < 2 || SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) != c)
                && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cProvider.requests == 2 && chat.isActiveSessionGenerating)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == c)
        let coldC = try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString))
        #expect(SessionTodoProgress.latest(in: coldC.messages) == c)
        chat.stopStreaming()
        await held.value
        #expect(!chat.isActiveSessionGenerating)
        #expect(await chat.restoreFileCheckpoint(checkpoint.id, includeConversation: true))
        #expect(try Data(contentsOf: file) == before)
        #expect(chat.draftText == "owned write B")
        #expect(!chat.messages.contains { $0.content == "owned write B" || $0.content == "owned todo C then hold" })
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == a)
        let restored = try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString))
        #expect(SessionTodoProgress.latest(in: restored.messages) == a)
        chat.draftText = ""
        let followup = CheckpointTodoProductionProvider()
        await (try submit(followup, text: "owned ordinary followup")).value
        #expect(followup.requests == 1)
        #expect(try Data(contentsOf: file) == before)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == a)
        #expect(SessionTodoProgress.latest(in: try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString)).messages) == a)

        // A real failed tool and assistant-only JSON may not publish a new checklist.
        let invalid = CheckpointTodoProductionProvider(tool: "todo_write", input: ["progress": ["todos": [["content": "invalid", "status": "not-a-status"]]]])
        await (try submit(invalid, text: "owned invalid todo")).value
        #expect(invalid.requests == 2)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == a)
        let spoof = CheckpointTodoProductionProvider(finalText: String(decoding: try JSONEncoder().encode(c), as: UTF8.self))
        await (try submit(spoof, text: "owned untrusted JSON text")).value
        #expect(spoof.requests == 1)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == a)
    }

    @Test func mixedOrchestrationAndTodoBatchesKeepCanonicalOrderWithoutDuplicates() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "todo-mixed-canonical", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let sid = chat.applyNewSession(title: "owned mixed tools")
        let facts = ComposerPolicyFactSource(knownCapabilities: ["todo_write", "orchestrate"],
            grantedCapabilities: ["todo_write", "orchestrate"], allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "owned-mixed", grantEpoch: "owned-mixed",
            leaseID: "owned-mixed", expiresAt: Date().addingTimeInterval(120), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let executor = OrchestrationCompositeToolExecutor(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator()))
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor,
            orchestrationDefinition: OrchestrationToolExecutor.makeDefinition(),
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil) }
        func call(_ id: String, _ name: String, _ input: [String: Any]) throws -> LLMToolCall {
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMToolCall(id: id, name: name, rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
        }
        let first = SessionTodoProgress(todos: [.init(content: "owned first", status: .in_progress)])
        let last = SessionTodoProgress(todos: [.init(content: "owned last", status: .pending)])
        let orchestration = ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": "[]"] as [String: Any]
        let batches = [
            [try call("owned-orchestration-1", "orchestrate", orchestration),
             try call("owned-orchestration-2", "orchestrate", orchestration)],
            [try call("owned-todo-1", "todo_write", ["progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))]),
             try call("owned-todo-2", "todo_write", ["progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(last))])]
        ]
        let provider = CheckpointTodoProductionProvider(batches: batches)
        chat.streamingProviderOverride = provider
        chat.draftText = "owned mixed request"
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sid))).value
        #expect(provider.requests == 3)
        let cold = try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString))
        let expected = batches.flatMap { $0 }.map(\.id)
        #expect(cold.messages.flatMap(\.toolCalls).map(\.id) == expected)
        #expect(cold.messages.filter { $0.role == .tool }.compactMap(\.toolCallID) == expected)
        #expect(cold.messages.filter { $0.role == .assistant && $0.content == "owned mixed prefix 1" }.count == 1)
        #expect(cold.messages.filter { $0.role == .assistant && $0.content == "owned mixed prefix 2" }.count == 1)
        #expect(SessionTodoProgress.latest(in: cold.messages) == last)
        #expect(SessionTodoProgress.latest(in: chat.messages.map { $0.asLLMMessage() }) == last)
    }

    private struct Fixture {
        let root: URL
        let chat: ChatStore
        let file: URL
        let checkpointID: UUID
    }

    private func fixture(_ label: String, lastMessages: [ChatMessageUI]? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g18-d6-\(label)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let chat = ChatStore()
        chat.newSession(projectID: "d6-\(label)")
        let sessionID = try #require(chat.activeSessionID)
        var snapshot = try #require(chat.sessions.first { $0.id == sessionID })
        snapshot.messages = lastMessages ?? [ChatMessageUI(role: .user, content: "REQUEST_D6_\(label)")]
        let store = try FileCheckpointStore(
            directory: root.appendingPathComponent("checkpoints", isDirectory: true), allowedRoots: [root])
        let file = root.appendingPathComponent("probe.txt")
        let after = Data("written-by-tool".utf8)
        let id = try store.begin(path: file, sessionID: sessionID.uuidString, operation: .write,
            expectedAfter: after, conversation: try JSONEncoder().encode(snapshot))
        try after.write(to: file)
        try store.commit(id)
        chat.fileCheckpointStore = store
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "d6-\(label)", grantEpoch: "d6-\(label)",
            leaseID: "d6-\(label)", expiresAt: Date().addingTimeInterval(60)))
        return Fixture(root: root, chat: chat, file: file, checkpointID: id)
    }

    @Test("the triggering request returns to an empty composer and leaves the transcript")
    func requestReturnsToComposer() async throws {
        let f = try fixture("empty")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let currentSession = try #require(f.chat.sessions.first { $0.id == f.chat.activeSessionID })
        #expect(await f.chat.restoreFileCheckpoint(f.checkpointID, includeConversation: true))
        #expect(f.chat.sessions.first { $0.id == currentSession.id }?.createdAt == currentSession.createdAt)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        #expect(!f.chat.messages.contains { $0.content == "REQUEST_D6_empty" })
        #expect(f.chat.draftText == "REQUEST_D6_empty")
        #expect(f.chat.checkpointFeedback?.contains("放回输入框") == true)
    }

    @Test("an existing draft is kept while the request still leaves the transcript")
    func existingDraftIsKept() async throws {
        let f = try fixture("draft")
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.chat.draftText = "KEEP_MY_DRAFT"
        #expect(await f.chat.restoreFileCheckpoint(f.checkpointID, includeConversation: true))
        #expect(!f.chat.messages.contains { $0.content == "REQUEST_D6_draft" })
        #expect(f.chat.draftText == "KEEP_MY_DRAFT")
        #expect(f.chat.checkpointFeedback?.contains("未覆盖") == true)
    }

    @Test("attachments of the returned request come back with it")
    func attachmentsReturn() async throws {
        let attachment = ChatAttachment(kind: .text, fileName: "notes.txt", fileType: .text,
            data: Data("附件内容".utf8), originalTextCharacterCount: 4)
        let f = try fixture("attach", lastMessages: [
            ChatMessageUI(role: .user, content: "REQUEST_D6_attach", attachments: [attachment])])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(await f.chat.restoreFileCheckpoint(f.checkpointID, includeConversation: true))
        #expect(f.chat.draftText == "REQUEST_D6_attach")
        #expect(f.chat.pendingAttachments.map(\.id) == [attachment.id])
    }

    @Test("a snapshot that does not end with a user request is restored unchanged")
    func nonUserTailUnchanged() async throws {
        let f = try fixture("tail", lastMessages: [
            ChatMessageUI(role: .user, content: "EARLIER_D6"),
            ChatMessageUI(role: .assistant, content: "ANSWER_D6")])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(await f.chat.restoreFileCheckpoint(f.checkpointID, includeConversation: true))
        #expect(f.chat.messages.map(\.content) == ["EARLIER_D6", "ANSWER_D6"])
        #expect(f.chat.draftText.isEmpty)
        #expect(f.chat.checkpointFeedback == "文件和对话已恢复。")
    }
}

private final class CheckpointTodoProductionProvider: LLMProvider, @unchecked Sendable {
    let name = "owned-checkpoint-todo"
    var model = LLMModel(id: "owned-checkpoint-todo", displayName: "Owned checkpoint", provider: "owned-checkpoint-todo")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var count = 0
    private let batches: [[LLMToolCall]]
    private let holdAfterTool: Bool
    private let finalText: String
    var requests: Int { lock.withLock { count } }
    init(tool: String? = nil, input: [String: Any] = [:], holdAfterTool: Bool = false, finalText: String = "owned completed") {
        self.holdAfterTool = holdAfterTool; self.finalText = finalText
        if let tool {
            let data = try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            batches = [[LLMToolCall(id: UUID().uuidString, name: tool,
                rawArguments: String(decoding: data, as: UTF8.self), arguments: input)]]
        } else { batches = [] }
    }
    init(batches: [[LLMToolCall]]) {
        self.batches = batches; holdAfterTool = false; finalText = "owned completed"
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let ordinal = lock.withLock { count += 1; return count }
        if ordinal <= batches.count {
            let text = batches.count > 1 ? "owned mixed prefix \(ordinal)" : ""
            return LLMResponse(text: text, stopReason: "tool_calls", usage: nil, toolCalls: batches[ordinal - 1])
        }
        if holdAfterTool { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        return LLMResponse(text: finalText, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
