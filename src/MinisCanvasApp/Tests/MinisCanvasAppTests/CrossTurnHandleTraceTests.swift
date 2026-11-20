import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D 批 D1（B-30 期 1，句柄类）：普通回合里模型自己产生的小而结构化的工具往来，
/// 下一回合的第一次请求里必须还看得到。走真实 ChatStore / AgentLoopChatEngine /
/// BuiltinToolExecutor / SessionStore；只有 Provider（外部边界）是脚本化的。
/// 全部夹具为合成数据，不碰真实数据、钥匙串或 Key。
@Suite("D1 cross-turn tool handle trace", .serialized)
@MainActor
struct CrossTurnHandleTraceTests {
    // MARK: T1 todo 通路基线（H3 已绿，泛化后必须仍绿）

    @Test func todoPairStillCrossesTurnsAndColdReads() async throws {
        let h = try Harness(label: "d1-todo", capabilities: ["todo_write"])
        defer { h.cleanup() }
        let progress = SessionTodoProgress(todos: [
            .init(content: "d1 synth A", status: .in_progress), .init(content: "d1 synth B", status: .pending)])
        let input: [String: Any] = ["progress": try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))]
        let todoCall = try makeCall("d1-todo-call", "todo_write", input)
        let turn1 = ScriptProvider { ordinal, _ in
            ordinal == 1 ? [todoCall] : []
        }
        try await h.run(turn1, "d1 todo turn one")
        let turn2 = ScriptProvider { _, _ in [] }
        try await h.run(turn2, "d1 todo turn two")

        let first = try #require(turn2.requests.first)
        #expect(callIDs(in: first, named: "todo_write") == ["d1-todo-call"])
        #expect(toolResults(in: first).map(\.id) == ["d1-todo-call"])
        #expect(SessionTodoProgress.latest(in: first) == progress)
        let cold = try h.coldMessages()
        #expect(SessionTodoProgress.latest(in: cold) == progress)
    }

    // MARK: T2 + D-03 后台命令启动句柄与 shell_stop 结果

    @Test func backgroundStartHandleAndStopResultCrossTurns() async throws {
        let h = try Harness(label: "d1-bg", capabilities: ["shell_execute", "shell_stop", "shell_output"])
        defer { h.cleanup() }
        let fifo = h.root.appendingPathComponent("d1-bg-release.fifo")
        try #require(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
        try #require(!fifo.path.contains("'"))
        let command = "cat '\(fifo.path)'"
        let startedID = Box<String>()

        // 回合 1：启动后台命令。task_id 取自回合内的真实工具结果。
        let turn1 = ScriptProvider { ordinal, messages in
            if ordinal == 1 {
                return [try makeCall("d1-bg-start", "shell_execute", [
                    "command": command, "run_in_background": true, "timeout": 20,
                    "cwd": h.root.path, "tool_title": "d1 synth background"])]
            }
            if let result = toolResults(in: messages).first(where: { $0.id == "d1-bg-start" }),
               let id = jsonObject(result.content)?["task_id"] as? String { startedID.set(id) }
            return []
        }
        try await h.run(turn1, "d1 start a background command")
        let taskID = try #require(startedID.get(), "the real executor must have returned a task_id in turn one")

        // 回合 2：第一次请求里必须看得到启动句柄；模型据此（这里直接用回合 1 的真实 id）停止命令。
        let turn2 = ScriptProvider { ordinal, _ in
            ordinal == 1 ? [try makeCall("d1-bg-stop", "shell_stop", ["task_id": taskID])] : []
        }
        try await h.run(turn2, "d1 stop the background command")
        let secondTurnFirst = try #require(turn2.requests.first)
        let startCalls = toolCalls(in: secondTurnFirst).filter { $0.id == "d1-bg-start" }
        #expect(startCalls.count == 1)
        #expect(startCalls.first?.name == "shell_execute")
        let startArguments = try #require(startCalls.first?.arguments)
        #expect(startArguments["run_in_background"] as? Bool == true)
        let preview = try #require(startArguments["command"] as? String)
        #expect(preview.hasPrefix("cat ") && preview.count <= 120)
        #expect(Set(startArguments.keys).isSubset(of: ["command", "run_in_background", "tool_title"]))
        let startResult = try #require(toolResults(in: secondTurnFirst).first { $0.id == "d1-bg-start" })
        let startEnvelope = try #require(jsonObject(startResult.content))
        #expect(startEnvelope["task_id"] as? String == taskID)
        #expect(startEnvelope["background"] as? Bool == true)
        #expect(startEnvelope["note"] == nil)
        try expectPairsAreWellFormed(secondTurnFirst)

        let cold = try h.coldMessages()
        #expect(cold.flatMap(\.toolCalls).filter { $0.id == "d1-bg-start" }.count == 1)
        #expect(cold.filter { $0.role == .tool && $0.toolCallID == "d1-bg-start" }.count == 1)

        // 回合 3：启动对与停止对各一，且是同一个 task_id。
        let turn3 = ScriptProvider { _, _ in [] }
        try await h.run(turn3, "d1 what happened to that command")
        let thirdTurnFirst = try #require(turn3.requests.first)
        let stopResult = try #require(toolResults(in: thirdTurnFirst).first { $0.id == "d1-bg-stop" })
        let stopEnvelope = try #require(jsonObject(stopResult.content))
        #expect(stopEnvelope["task_id"] as? String == taskID)
        #expect(stopEnvelope["note"] == nil)
        #expect(stopEnvelope["stop_requested"] != nil)
        let stopCall = try #require(toolCalls(in: thirdTurnFirst).first { $0.id == "d1-bg-stop" })
        #expect(stopCall.arguments["task_id"] as? String == taskID)
        #expect(toolCalls(in: thirdTurnFirst).filter { $0.id == "d1-bg-start" }.count == 1)
        try expectPairsAreWellFormed(thirdTurnFirst)
    }

    // MARK: 命令预览脱敏：已知凭据值跨第 120 字符时不得留下任何前缀片段

    @Test func backgroundCommandPreviewMasksKnownCredentialCrossingTheCut() throws {
        let secret = "SYNTH-KNOWN-CRED-" + String(repeating: "q7Zx", count: 10)   // 合成值，非真实 Key
        let command = "cat /synthetic/" + String(repeating: "p", count: 85) + " " + secret
        try #require(command.count > 120 && command.count - secret.count < 120)
        let call = try makeCall("d1-redact", "shell_execute", ["command": command, "run_in_background": true])
        let result = #"{"background":true,"max_timeout_seconds":600,"status":"running","task_id":"bg-0a1b2c3d","timeout_seconds":20}"#
        let pair = try #require(CrossTurnToolTracePolicy.transcript(call: call, result: result, knownSecrets: [secret]))
        let kept = try #require(pair.first?.toolCalls.first?.arguments["command"] as? String)
        #expect(kept.hasPrefix("cat /synthetic/") && kept.count <= 120)
        for length in 8...secret.count {
            #expect(!kept.contains(String(secret.prefix(length))), "a \(length)-character prefix of the credential survived")
        }
        let rawArguments = pair.first?.toolCalls.first?.rawArguments ?? ""
        #expect(!rawArguments.contains(String(secret.prefix(8))))
    }

    // MARK: R3-12 后台命令不设时限：启动结果 timeout_seconds 为 null，这一对仍要保留且任务号在内

    @Test func backgroundStartWithoutTimeoutStillKeepsTaskHandle() throws {
        let call = try makeCall("r312-start", "shell_execute", ["command": "sleep 600", "run_in_background": true])
        let result = #"{"background":true,"max_timeout_seconds":600,"note":"x","status":"running","task_id":"bg-0a1b2c3d","timeout_seconds":null}"#
        let pair = try #require(CrossTurnToolTracePolicy.transcript(call: call, result: result, knownSecrets: []))
        let kept = try #require(pair.last?.content.data(using: .utf8))
        let envelope = try #require(try JSONSerialization.jsonObject(with: kept) as? [String: Any])
        #expect(envelope["task_id"] as? String == "bg-0a1b2c3d")
        #expect(envelope["timeout_seconds"] == nil)
        #expect(envelope["max_timeout_seconds"] as? Int == 600)
    }

    // MARK: T3 file_write / file_edit 结果行，正文不留

    @Test func fileWriteAndEditResultLinesCrossTurnsWithoutBody() async throws {
        let h = try Harness(label: "d1-file", capabilities: ["file_write", "file_edit"])
        defer { h.cleanup() }
        let target = h.root.appendingPathComponent("d1-a.txt")
        let writeBody = "SYNTH_BODY_ZZZ_001"
        let oldMarker = "SYNTH_OLD_ZZZ_002"
        let newMarker = "SYNTH_NEW_ZZZ_003"
        let turn1 = ScriptProvider { ordinal, _ in
            switch ordinal {
            case 1: return [try makeCall("d1-write", "file_write", [
                "path": target.path, "content": "\(writeBody) \(oldMarker)", "append": false, "create_dirs": false])]
            case 2: return [try makeCall("d1-edit", "file_edit", [
                "path": target.path, "old_string": oldMarker, "new_string": newMarker, "replace_all": false])]
            default: return []
            }
        }
        try await h.run(turn1, "d1 write then edit")
        try #require(try String(contentsOf: target, encoding: .utf8) == "\(writeBody) \(newMarker)")

        let turn2 = ScriptProvider { _, _ in [] }
        try await h.run(turn2, "d1 which file did you change")
        let first = try #require(turn2.requests.first)
        let calls = toolCalls(in: first)
        #expect(calls.map(\.id).filter { ["d1-write", "d1-edit"].contains($0) } == ["d1-write", "d1-edit"])
        let results = toolResults(in: first)
        let writeResult = try #require(results.first { $0.id == "d1-write" })
        let editResult = try #require(results.first { $0.id == "d1-edit" })
        #expect(writeResult.content.contains(target.lastPathComponent))
        #expect(editResult.content.contains(target.lastPathComponent))
        for call in calls {
            #expect(Set(call.arguments.keys).isSubset(of: ["path", "tool_title", "append", "create_dirs", "replace_all"]))
        }
        try expectPairsAreWellFormed(first)

        // 正文是硬边界：请求与冷读的会话里都不得出现任何正文标记。
        let cold = try h.coldMessages()
        for markers in [writeBody, oldMarker, newMarker] {
            #expect(!flatten(first).contains(markers))
            #expect(!flatten(cold).contains(markers))
        }
        #expect(cold.flatMap(\.toolCalls).map(\.id).filter { ["d1-write", "d1-edit"].contains($0) } == ["d1-write", "d1-edit"])
    }

    // MARK: T4 表外工具整对丢弃，配对完整
    // D2b 起 file_read 与前台 shell_execute 进入摘录规则（见 CrossTurnToolExcerptTests）；这里的“表外”改用 file_grep。

    @Test func toolsOutsideThePolicyDropAsWholePairsAndPairingStaysComplete() async throws {
        let h = try Harness(label: "d1-outside", capabilities: ["file_grep", "file_write"])
        defer { h.cleanup() }
        let searched = h.root.appendingPathComponent("d1-searched.txt")
        try "SYNTH_READ_BODY_ZZZ_004".write(to: searched, atomically: true, encoding: .utf8)
        let written = h.root.appendingPathComponent("d1-b.txt")
        let turn1 = ScriptProvider { ordinal, _ in
            guard ordinal == 1 else { return [] }
            return [
                try makeCall("d1-grep", "file_grep", ["path": h.root.path, "pattern": "SYNTH_READ_BODY_ZZZ"]),
                try makeCall("d1-write-b", "file_write", ["path": written.path, "content": "SYNTH_BODY_ZZZ_005"]),
            ]
        }
        try await h.run(turn1, "d1 search and write in one batch")
        let turn2 = ScriptProvider { _, _ in [] }
        try await h.run(turn2, "d1 second turn")
        let first = try #require(turn2.requests.first)
        #expect(callIDs(in: first, named: "file_write") == ["d1-write-b"])
        #expect(toolResults(in: first).map(\.id).contains("d1-write-b"))
        #expect(!toolCalls(in: first).contains { $0.id == "d1-grep" })
        #expect(!toolResults(in: first).contains { $0.id == "d1-grep" })
        #expect(!flatten(first).contains("SYNTH_READ_BODY_ZZZ_004"))
        try expectPairsAreWellFormed(first)
    }

    // MARK: 反向合同（裁定 A）：同批里排在前面、后面还有未结算兄弟的策略内调用，不进跨回合转录

    @Test func earlierPolicyCallInABatchWithPendingSiblingsIsNotCarried() async throws {
        let h = try Harness(label: "d1-earlier", capabilities: ["file_write", "shell_execute"])
        defer { h.cleanup() }
        let target = h.root.appendingPathComponent("d1-f.txt")
        let turn1 = ScriptProvider { ordinal, _ in
            guard ordinal == 1 else { return [] }
            return [
                try makeCall("d1-early-write", "file_write", ["path": target.path, "content": "SYNTH_BODY_ZZZ_011"]),
                try makeCall("d1-late-shell", "shell_execute", ["command": "echo SYNTH_FG_ZZZ_012", "cwd": h.root.path]),
            ]
        }
        try await h.run(turn1, "d1 write then run in one batch")
        try #require(try String(contentsOf: target, encoding: .utf8) == "SYNTH_BODY_ZZZ_011")
        // UI 不受影响：file_write 的工具卡片已被消费。
        let cardConsumed = h.chat.conversationEvents.contains { $0.toolName == "file_write" && $0.status == .succeeded }
        #expect(cardConsumed)

        let turn2 = ScriptProvider { _, _ in [] }
        try await h.run(turn2, "d1 second turn")
        let first = try #require(turn2.requests.first)
        #expect(!toolCalls(in: first).contains { $0.id == "d1-early-write" })
        #expect(!toolResults(in: first).contains { $0.id == "d1-early-write" })
        try expectPairsAreWellFormed(first)
    }

    // MARK: T5 失败留简要记录（用户 11/20：失败的工具调用也存进对话记录；只留路径与报错，不留写入正文）

    @Test func failedFileEditLeavesACompactFailureTraceWithoutBodies() async throws {
        let h = try Harness(label: "d1-failed", capabilities: ["file_edit"])
        defer { h.cleanup() }
        let target = h.root.appendingPathComponent("d1-c.txt")
        try "SYNTH_PRESENT_ZZZ_007".write(to: target, atomically: true, encoding: .utf8)
        let turn1 = ScriptProvider { ordinal, _ in
            ordinal == 1 ? [try makeCall("d1-bad-edit", "file_edit", [
                "path": target.path, "old_string": "SYNTH_ABSENT_ZZZ_008", "new_string": "SYNTH_NEW_ZZZ_010", "replace_all": false])] : []
        }
        try await h.run(turn1, "d1 edit something that is not there")
        try #require(try String(contentsOf: target, encoding: .utf8) == "SYNTH_PRESENT_ZZZ_007")
        let turn2 = ScriptProvider { _, _ in [] }
        try await h.run(turn2, "d1 second turn")
        let first = try #require(turn2.requests.first)
        let call = try #require(toolCalls(in: first).first { $0.id == "d1-bad-edit" })
        #expect(call.arguments["path"] as? String == target.path)
        #expect(call.arguments["old_string"] == nil)
        #expect(call.arguments["new_string"] == nil)
        let result = try #require(toolResults(in: first).first { $0.id == "d1-bad-edit" })
        #expect(result.content.hasPrefix("[工具执行失败]"))
        #expect(!result.content.contains("SYNTH_NEW_ZZZ_010"))
        let cold = try h.coldMessages()
        #expect(cold.flatMap(\.toolCalls).filter { $0.id == "d1-bad-edit" }.count == 1)
        #expect(!cold.flatMap(\.toolCalls).contains { $0.rawArguments.contains("SYNTH_NEW_ZZZ_010") })
        try expectPairsAreWellFormed(first)
    }

    // MARK: T6 混合编排回合：每个 toolCallID 在落盘转录里恰有一条 tool 消息（守卫）

    @Test func orchestrationTurnKeepsEachToolResultExactlyOnce() async throws {
        let h = try Harness(label: "d1-mixed", capabilities: ["file_write", "orchestrate"], orchestration: true)
        defer { h.cleanup() }
        let target = h.root.appendingPathComponent("d1-d.txt")
        let orchestration: [String: Any] = ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": "[]"]
        let orchestrateCall = try makeCall("d1-orch", "orchestrate", orchestration)
        let turn = ScriptProvider { ordinal, _ in
            switch ordinal {
            case 1: return [orchestrateCall]
            case 2: return [try makeCall("d1-mixed-write", "file_write", ["path": target.path, "content": "SYNTH_BODY_ZZZ_009"])]
            default: return []
            }
        }
        try await h.run(turn, "d1 orchestrate then write")
        let cold = try h.coldMessages()
        let expected = ["d1-orch", "d1-mixed-write"]
        #expect(cold.flatMap(\.toolCalls).map(\.id) == expected)
        #expect(cold.filter { $0.role == .tool }.compactMap(\.toolCallID) == expected)
        #expect(h.chat.messages.map { $0.asLLMMessage() }.flatMap(\.toolCalls).map(\.id) == expected)
    }

    // MARK: T7 UI 不退化：同批里后面的慢命令没结束时，前面 file_write 的生命周期已被消费
    // 假设（审查已查实）：同批只有读工具并行，其余按顺序执行；这里 file_write 排在 shell 前面。

    @Test func fastFileWriteIsConsumedWhileSlowSiblingShellIsStillRunning() async throws {
        let h = try Harness(label: "d1-ui", capabilities: ["file_write", "shell_execute"])
        defer { h.cleanup() }
        let fifo = h.root.appendingPathComponent("d1-ui-hold.fifo")
        try #require(fifo.path.withCString { mkfifo($0, 0o600) } == 0)
        try #require(!fifo.path.contains("'"))
        let target = h.root.appendingPathComponent("d1-e.txt")
        let turn = ScriptProvider { ordinal, _ in
            ordinal == 1 ? [
                try makeCall("d1-ui-write", "file_write", ["path": target.path, "content": "SYNTH_BODY_ZZZ_010"]),
                try makeCall("d1-ui-hold", "shell_execute", [
                    "command": "cat '\(fifo.path)'", "cwd": h.root.path, "timeout": 20]),
            ] : []
        }
        h.chat.streamingProviderOverride = turn
        h.chat.draftText = "d1 fast write beside a slow foreground command"
        h.chat.submitComposer()
        let task = try #require(h.chat.turnTaskForTests(sessionID: h.sid))
        defer { Harness.release(fifo) }

        let deadline = ContinuousClock.now + .seconds(8)
        func writeSucceededInJournal() -> Bool {
            h.chat.conversationEvents.contains { $0.toolName == "file_write" && $0.status == .succeeded }
        }
        while !writeSucceededInJournal() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let consumedWhileSlowSiblingRuns = writeSucceededInJournal()
        Harness.release(fifo)
        await task.value
        #expect(consumedWhileSlowSiblingRuns,
                "file_write must reach the lifecycle journal before the whole tool batch ends")
        #expect(try String(contentsOf: target, encoding: .utf8) == "SYNTH_BODY_ZZZ_010")
    }
}

// MARK: - Harness

@MainActor
private final class Harness {
    let profile: RuntimeIsolationProfile
    let root: URL
    let chat: ChatStore
    let sessions: SessionStore
    let sid: UUID

    init(label: String, capabilities: Set<String>, orchestration: Bool = false) throws {
        profile = try RuntimeIsolationProfile.makeIsolatedTest(label: label, canvasRuntimeState: .disabled)
        root = profile.rootDirectory
        chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        sid = chat.applyNewSession(title: label)
        let facts = ComposerPolicyFactSource(knownCapabilities: capabilities, grantedCapabilities: capabilities,
            allowedWriteRoots: [root.path], workspaceID: chat.composerWorkspaceID, revision: label,
            grantEpoch: label, leaseID: label, expiresAt: Date().addingTimeInterval(300), autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeSessionID = sid.uuidString
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        if orchestration {
            let executor = OrchestrationCompositeToolExecutor(base: builtin,
                orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator()))
            chat.agentEngine = AgentLoopChatEngine(toolExecutor: executor,
                orchestrationDefinition: OrchestrationToolExecutor.makeDefinition(),
                toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        } else {
            chat.agentEngine = AgentLoopChatEngine(toolExecutor: builtin,
                toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        }
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil)
        }
    }

    func cleanup() {
        chat.stopAllStreamingForSafety()
        try? profile.cleanupDisposableRoots()
    }

    func run(_ provider: ScriptProvider, _ text: String) async throws {
        chat.streamingProviderOverride = provider
        chat.draftText = text
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sid))).value
    }

    func coldMessages() throws -> [LLMMessage] {
        try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString)).messages
    }

    /// 打开写端让被 fifo 挂住的 cat 读到 EOF；没有读者时不阻塞。
    static func release(_ fifo: URL) {
        let fd = fifo.path.withCString { open($0, O_WRONLY | O_NONBLOCK) }
        if fd >= 0 { close(fd) }
    }
}

// MARK: - 脚本化 Provider（外部边界）

private final class ScriptProvider: LLMProvider, @unchecked Sendable {
    let name = "d1-cross-turn-script"
    var model = LLMModel(id: "d1-cross-turn-script", displayName: "D1 script", provider: "d1-cross-turn-script")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    private let script: @Sendable (Int, [LLMMessage]) throws -> [LLMToolCall]

    /// 返回空数组即给出最终文本。ordinal 从 1 起，按本实例收到的请求计。
    init(script: @escaping @Sendable (Int, [LLMMessage]) throws -> [LLMToolCall]) { self.script = script }

    var requests: [[LLMMessage]] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let ordinal = lock.withLock { captured.append(messages); return captured.count }
        let calls = try script(ordinal, messages)
        if calls.isEmpty { return LLMResponse(text: "d1 completed", stopReason: "stop", usage: nil) }
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: calls)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T? { lock.withLock { value } }
}

// MARK: - 请求内容读取

private func makeCall(_ id: String, _ name: String, _ input: [String: Any]) throws -> LLMToolCall {
    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return LLMToolCall(id: id, name: name, rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
}

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func toolCalls(in messages: [LLMMessage]) -> [LLMToolCall] {
    messages.flatMap(\.toolCalls)
}

private func callIDs(in messages: [LLMMessage], named name: String) -> [String] {
    toolCalls(in: messages).filter { $0.name == name }.map(\.id)
}

/// `.tool` 角色消息按 toolCallID 取；其余消息取其内容分片里的 tool_result。
private func toolResults(in messages: [LLMMessage]) -> [(id: String, content: String)] {
    var found: [(id: String, content: String)] = []
    for message in messages {
        if message.role == .tool, let id = message.toolCallID {
            found.append((id, message.content))
        } else {
            for part in message.toAgentContentParts() {
                if case .toolResult(let id, _, let content, _, _, _, _, _) = part { found.append((id, content)) }
            }
        }
    }
    return found
}

/// 请求里每个 tool 结果都有更早的、ID 相同的 assistant 调用；每个调用至多一条结果。
private func expectPairsAreWellFormed(_ messages: [LLMMessage], sourceLocation: SourceLocation = #_sourceLocation) throws {
    var seenCalls = Set<String>()
    var answered = Set<String>()
    for message in messages {
        for call in message.toolCalls { seenCalls.insert(call.id) }
        if message.role == .tool, let id = message.toolCallID {
            #expect(seenCalls.contains(id), "tool result \(id) has no earlier assistant call", sourceLocation: sourceLocation)
            #expect(answered.insert(id).inserted, "tool result \(id) appears twice", sourceLocation: sourceLocation)
        }
    }
    for id in seenCalls {
        #expect(answered.contains(id), "assistant call \(id) has no result", sourceLocation: sourceLocation)
    }
}

/// 把消息里所有可能携带正文的文本拼成一个串，供“正文不留”断言使用。
private func flatten(_ messages: [LLMMessage]) -> String {
    messages.map { message in
        ([message.content] + message.toolCalls.map(\.rawArguments)).joined(separator: "\n")
    }.joined(separator: "\n")
}
