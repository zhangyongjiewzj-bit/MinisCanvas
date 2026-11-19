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
        builtin.markFileRead(path: path.path) // 覆盖已有文件要求先读
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
        // 覆盖已有文件要求先读；经由聊天引擎的执行器写入，所以直接登记到共享读取记录。
        FileReadRecordStore.shared.recordRead(sessionID: sid.uuidString, path: file.path)
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

    // MARK: R3-10 生成中异常退出

    @Test func restartAfterAbnormalExitMarksPartialReplyInterruptedAndRebuildsLostOneFromJournal() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "r310-recover", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let badges = profile.rootDirectory.appendingPathComponent("badges")
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                       badgeStore: SessionBadgeStore(directory: badges)))
        // A：半截回复已经落过盘（例如中途切过会话），上次退出时仍在运行。
        let a = try #require(chat.activeSessionID)
        chat.appendUser("R310 问题 A")
        chat.setMessages(chat.messages + [ChatMessageUI(role: .assistant, content: "半截回答 A")], forSession: a)
        chat.markExecutionRunning(sessionID: a, turnID: 1, taskID: nil)
        // B：只剩用户消息，已生成的内容只在回合日志里。
        let b = chat.applyNewSession(title: "R310 B")
        chat.appendUser("R310 问题 B")
        chat.markExecutionRunning(sessionID: b, turnID: 1, taskID: nil)
        // C：日志里的内容属于别的回合（用户消息摘要对不上），不得采用。
        let c = chat.applyNewSession(title: "R310 C")
        chat.appendUser("R310 问题 C")
        chat.markExecutionRunning(sessionID: c, turnID: 1, taskID: nil)
        func entry(_ id: UUID, text: String, digest: String) throws -> String {
            let visible = try #require(chat.messages(forSession: id)).filter { $0.role != .system }
            let userIndex = try #require(visible.lastIndex { $0.role == .user })
            let userDigest = digest.isEmpty
                ? ChatVideoFrame.digest(Data(visible[userIndex].asLLMMessage().content.utf8)) : digest
            return #"{"sessionID":"\#(id.uuidString)","userIndex":\#(userIndex),"userDigest":"\#(userDigest)","content":"\#(text)","messageTimestamp":700000000,"savedAt":700000010}"#
        }
        let journalURL = profile.sessionDirectory.appendingPathComponent("chat-inflight-reply.json")
        let journal = #"{"entries":["# + (try entry(b, text: "B 已生成的前半段", digest: ""))
            + "," + (try entry(c, text: "C 不该出现", digest: "wrong")) + "]}"
        try Data(journal.utf8).write(to: journalURL)

        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(reopened.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                           badgeStore: SessionBadgeStore(directory: badges)))
        let aTail = try #require(reopened.messages(forSession: a)?.last)
        #expect(aTail.role == .assistant && aTail.content == "半截回答 A")
        #expect(aTail.wasInterrupted && aTail.interruptionStatusText == "已中断")
        let bTail = try #require(reopened.messages(forSession: b)?.last)
        #expect(bTail.role == .assistant && bTail.content == "B 已生成的前半段" && bTail.wasInterrupted)
        #expect(bTail.timestamp == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(reopened.messages(forSession: c)?.last?.role == .user)
        // 已落盘：冷读正史就是补回后的内容；日志用过即清，再次重开不会重复补。
        let cold = SessionStore(directory: profile.sessionDirectory)
        #expect(cold.loadSession(id: b.uuidString)?.messages.last?.content == "B 已生成的前半段")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        let again = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(again.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                        badgeStore: SessionBadgeStore(directory: badges)))
        #expect(again.messages(forSession: b)?.count == reopened.messages(forSession: b)?.count)
        #expect(again.messages(forSession: b)?.last?.wasInterrupted == true)
    }

    @Test func toolCompletionJournalsTheInflightReplyWithoutTouchingTheTranscriptFile() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "r310-journal", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { chat.stopAllStreamingForSafety(); try? profile.cleanupDisposableRoots() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let sid = chat.applyNewSession(title: "r310 journal")
        let facts = ComposerPolicyFactSource(knownCapabilities: ["todo_write"], grantedCapabilities: ["todo_write"],
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: "r310",
            grantEpoch: "r310", leaseID: "r310", expiresAt: Date().addingTimeInterval(120), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json")),
            composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil) }
        func todo(_ id: String, _ text: String) throws -> LLMToolCall {
            let progress = SessionTodoProgress(todos: [.init(content: text, status: .in_progress)])
            let input = ["progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))]
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMToolCall(id: id, name: "todo_write", rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
        }
        // 流式服务商：文字在工具调用前逐段上屏（非流式服务商的文字要到回合结束才写入，测不到日志）。
        let provider = StreamingCheckpointTodoProvider(
            CheckpointTodoProductionProvider(batches: [[try todo("r310-1", "一")], [try todo("r310-2", "二")]]))
        let journalURL = profile.sessionDirectory.appendingPathComponent("chat-inflight-reply.json")
        // 第三次请求发出时两次工具都已完成：回合还在进行，此时读日志。
        let midTurn = JournalSnapshotBox()
        provider.onFinalRequest = {
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: journalURL.path) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            midTurn.data = try? Data(contentsOf: journalURL)
        }
        chat.streamingProviderOverride = provider
        chat.draftText = "r310 request"
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sid))).value
        // 回合内的半截回复另存在日志里，内容是第一次工具完成时已生成的文字。
        let midTurnData = try #require(midTurn.data)
        let object = try #require(try JSONSerialization.jsonObject(with: midTurnData) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["sessionID"] as? String == sid.uuidString)
        #expect((entries.first?["content"] as? String)?.contains("owned mixed prefix 1") == true)
        // 条目带着回合标识（执行记录的 taskID）。
        #expect((entries.first?["taskID"] as? String)?.hasPrefix("chat:\(sid.uuidString):") == true)
        // F-10：回合正常结束后日志里这个会话的条目已去掉，文件不再留着。
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    /// F-10：已经正常结束的回合，其半截回复日志条目不能留到下次；删除会话时也一并去掉。
    @Test func finishedTurnAndPermanentDeletionDropTheInflightJournalEntry() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "f10-prune", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                       badgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))))
        let journalURL = profile.sessionDirectory.appendingPathComponent("chat-inflight-reply.json")
        func journaledSessionIDs() throws -> [String] {
            guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
            return ((object["entries"] as? [[String: Any]]) ?? []).compactMap { $0["sessionID"] as? String }.sorted()
        }
        let finished = try #require(chat.activeSessionID)
        chat.appendUser("F10 已结束的回合")
        chat.setMessages(chat.messages + [ChatMessageUI(role: .assistant, content: "F10 半截 1")], forSession: finished)
        chat.markExecutionRunning(sessionID: finished, turnID: 1, taskID: "chat:f10:1:a")
        let doomed = chat.applyNewSession(title: "F10 将被永久删除")
        chat.appendUser("F10 将被删除的回合")
        chat.setMessages(chat.messages + [ChatMessageUI(role: .assistant, content: "F10 半截 2")], forSession: doomed)
        chat.markExecutionRunning(sessionID: doomed, turnID: 2, taskID: "chat:f10:2:b")
        chat.journalInflightReply(sessionID: finished)
        chat.journalInflightReply(sessionID: doomed)
        #expect(try journaledSessionIDs() == [finished.uuidString, doomed.uuidString].sorted())

        // 回合正常结束：只去掉这个会话的条目，别的会话在跑的不受影响。
        chat.markExecutionSucceeded(sessionID: finished)
        #expect(try journaledSessionIDs() == [doomed.uuidString])

        // 同一会话开始新一轮（taskID 不同）：上一轮的旧条目不再保留。
        chat.markExecutionRunning(sessionID: doomed, turnID: 3, taskID: "chat:f10:3:c")
        #expect(try journaledSessionIDs().isEmpty)
        chat.journalInflightReply(sessionID: doomed)
        #expect(try journaledSessionIDs() == [doomed.uuidString])

        // 永久删除会话：它的条目随之去掉，不再留着已删除会话的内容。
        chat.markExecutionSucceeded(sessionID: doomed)
        chat.markExecutionRunning(sessionID: doomed, turnID: 4, taskID: "chat:f10:4:d")
        chat.journalInflightReply(sessionID: doomed)
        #expect(try journaledSessionIDs() == [doomed.uuidString])
        let preview = try chat.previewPermanentDeletion(id: doomed)
        _ = try chat.permanentlyDeleteSession(
            id: doomed, intent: preview.withFirstConfirmation("已核对这份预览").withSecondConfirmation("永久删除"))
        #expect(!chat.sessions.contains { $0.id == doomed })
        #expect(try journaledSessionIDs().isEmpty)
    }

    /// F-10 连带：上次退出时仍在运行的是新一轮（taskID 不同），上一轮留下的旧条目不能被补回。
    @Test func staleInflightEntryFromAnEarlierTurnIsNotRestoredIntoTheNewTurn() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "f10-stale-turn", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let badges = profile.rootDirectory.appendingPathComponent("badges")
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                       badgeStore: SessionBadgeStore(directory: badges)))
        let sid = try #require(chat.activeSessionID)
        chat.appendUser("F10 重新生成同一条消息")
        chat.markExecutionRunning(sessionID: sid, turnID: 5, taskID: "chat:f10:5:new")
        let visible = try #require(chat.messages(forSession: sid)).filter { $0.role != .system }
        let userIndex = try #require(visible.lastIndex { $0.role == .user })
        let digest = ChatVideoFrame.digest(Data(visible[userIndex].asLLMMessage().content.utf8))
        // 旧条目与新一轮的用户消息位置、摘要都对得上，只有回合标识不同。
        let stale = #"{"entries":[{"sessionID":"\#(sid.uuidString)","userIndex":\#(userIndex),"userDigest":"\#(digest)","content":"上一轮的旧回复","messageTimestamp":700000000,"savedAt":700000010,"taskID":"chat:f10:4:old"}]}"#
        try Data(stale.utf8).write(to: profile.sessionDirectory.appendingPathComponent("chat-inflight-reply.json"))
        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(reopened.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                           badgeStore: SessionBadgeStore(directory: badges)))
        #expect(reopened.messages(forSession: sid)?.last?.role == .user)
        #expect(reopened.messages(forSession: sid)?.contains { $0.content == "上一轮的旧回复" } == false)
    }

    /// 纯文字回复在生成中被杀：没有落盘的助手消息也没有日志条目。重开后不得往正史里加空助手消息，
    /// 但执行状态要变成“失败（可重试）”并带上中断原因，侧栏和对话末尾才会出现“重试”。
    @Test func restartAfterKillDuringPlainTextReplyMarksSessionRetryableWithoutEmptyAssistantMessage() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "r310-plain-text-kill", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let badges = profile.rootDirectory.appendingPathComponent("badges")
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                       badgeStore: SessionBadgeStore(directory: badges)))
        let sid = try #require(chat.activeSessionID)
        chat.appendUser("纯文字长回答")
        chat.markExecutionRunning(sessionID: sid, turnID: 1, taskID: "chat:plain:1")

        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(reopened.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                           badgeStore: SessionBadgeStore(directory: badges)))
        #expect(reopened.messages(forSession: sid)?.last?.role == .user)
        // 新会话初始化时自带一条欢迎语助手消息，所以只看最后一条用户消息之后有没有助手消息。
        let reopenedMessages = try #require(reopened.messages(forSession: sid))
        let lastUserIndex = try #require(reopenedMessages.lastIndex { $0.role == .user })
        #expect(!reopenedMessages[(lastUserIndex + 1)...].contains { $0.role == .assistant })
        let snapshot = try #require(reopened.executionSnapshot(forSessionID: sid))
        #expect(snapshot.state == .failed)
        #expect(snapshot.failureReason == "上次回复在生成中被中断，可重试")
        #expect(snapshot.retryIdentity == .init(sessionID: sid, turnID: 1, taskID: "chat:plain:1"))
        // 失败状态已落盘：再重开一次仍可重试。
        let again = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(again.attachPersistence(SessionStore(directory: profile.sessionDirectory),
                                        badgeStore: SessionBadgeStore(directory: badges)))
        #expect(again.executionSnapshot(forSessionID: sid)?.state == .failed)
    }

    // MARK: 消息时间落盘的两处小修（修后复核 P3）

    private func twoMessageThread(_ t0: Date, interrupted: Bool = false) -> ChatThread {
        var reply = ChatMessageUI(role: .assistant, content: "好的", timestamp: t0.addingTimeInterval(5))
        reply.wasInterrupted = interrupted
        return ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: "改一个文件", timestamp: t0), reply])
    }

    /// 带回收站保留的整份保存：保留下来的会话记录要连消息时间一起带上，
    /// 否则恢复后所有消息都成了“时间未核实”。
    @Test func wholeSaveRetainingATrashedSessionKeepsItsMessageTimes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-retain-times-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let trashed = twoMessageThread(t0, interrupted: true)
        let active = twoMessageThread(t0.addingTimeInterval(100))
        try ChatAttachmentPersistence.save(sessions: [trashed, active], to: root)
        // 第二次整份保存时，回收站里的会话不在活动列表，只靠 id 保留旧记录。
        try ChatAttachmentPersistence.save(
            sessions: [active], to: root, retainingTrashedSessionIDs: [trashed.id.uuidString])
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: ChatAttachmentPersistence.url(in: root))) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let kept = try #require(sessions.first { $0["sessionID"] as? String == trashed.id.uuidString })
        #expect((kept["messageTimes"] as? [[String: Any]])?.count == 2)
        #expect((kept["messages"] as? [[String: Any]])?.count == 1)
    }

    /// 启动时每个会话的附件归属和消息时间来自同一个分片，一次读取给出两样，结果与分开读一致；
    /// 分片不存在时只回旧版合并文件里的归属记录，时间为空。
    @Test func sessionShardGivesRecordsAndTimesInOneLoadWithTheSameResultAsSeparateLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-one-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = twoMessageThread(t0, interrupted: true)
        let id = thread.id.uuidString
        try ChatAttachmentPersistence.save(session: thread, to: root)
        let merged = try ChatAttachmentPersistence.loadSessionRecordsAndTimes(forSessionID: id, from: root)
        let separateRecords = try ChatAttachmentPersistence.load(forSessionID: id, from: root)
        let separateTimes = try ChatAttachmentPersistence.loadMessageTimes(forSessionID: id, from: root)
        #expect(merged.records == separateRecords)
        #expect(merged.times == separateTimes)
        #expect(merged.times.count == 2 && merged.records?.count == 1)
        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: thread.asPersisted(), records: merged.records, messageTimes: merged.times)
        #expect(reopened.messages.map(\.timestamp) == [t0, t0.addingTimeInterval(5)])
        #expect(reopened.messages.allSatisfy { !$0.hasUnverifiedTimestamp })
        // 没有分片：不报错，归属记录为空，时间为空。
        let none = try ChatAttachmentPersistence.loadSessionRecordsAndTimes(
            forSessionID: UUID().uuidString, from: root)
        #expect(none.records == nil && none.times.isEmpty)
        // 启动恢复路径必须走合并读取，不能退回各读一遍。
        let store = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/ChatStore.swift")
        let source = try String(contentsOf: store, encoding: .utf8)
        #expect(source.contains("ChatAttachmentPersistence.loadSessionRecordsAndTimes("))
        #expect(!source.contains("ChatAttachmentPersistence.loadMessageTimes("))
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

    /// 新-5：恢复文件和对话要和“仅回退对话”用同一个空闲守卫；会话忙时不能执行，
    /// 文件和对话都保持原样。回退守卫会红。
    @Test("restoring files and conversation is refused while the session is busy")
    func restoreWithConversationRefusedWhileBusy() async throws {
        let f = try fixture("busy")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sessionID = try #require(f.chat.activeSessionID)
        // 夹具只把会话快照写进检查点，当前对话本身是空的；先放入触发写入的请求，
        // 才能证明“忙时拒绝”后对话没被改动。
        f.chat.messages = [ChatMessageUI(role: .user, content: "REQUEST_D6_busy")]
        f.chat.installScheduledSessionBusyForTests(sessionID: sessionID)
        #expect(!(await f.chat.restoreFileCheckpoint(f.checkpointID, includeConversation: true)))
        #expect(FileManager.default.fileExists(atPath: f.file.path))
        #expect(try Data(contentsOf: f.file) == Data("written-by-tool".utf8))
        #expect(f.chat.messages.contains { $0.content == "REQUEST_D6_busy" })
        #expect(f.chat.draftText.isEmpty)
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

/// 回合进行中抓下来的半截回复日志内容。
private final class JournalSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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

/// Streams each scripted response's text before its tool calls, like a real streaming provider.
private final class StreamingCheckpointTodoProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let base: CheckpointTodoProductionProvider
    /// 第三次及以后的请求发出前调用（脚本里的两批工具都已执行完）。
    var onFinalRequest: (@Sendable () async -> Void)?
    init(_ base: CheckpointTodoProductionProvider) { self.base = base }
    var name: String { base.name }
    var model: LLMModel {
        get { base.model }
        set { base.model = newValue }
    }
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                   maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                   tools: tools, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
                                tools: [AgentToolDefinition], maxTokens: Int,
                                temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let response = try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                                  tools: tools, maxTokens: maxTokens, temperature: temperature)
        if base.requests >= 3 { await onFinalRequest?() }
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty { continuation.yield(.textDelta(response.text + "\n")) }
            continuation.yield(.completed(response))
            continuation.finish()
        }
    }
}
