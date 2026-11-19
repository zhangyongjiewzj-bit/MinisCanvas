import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D 批 D2b（B-30 期 2，摘录类）：成功的 file_read 与成功的前台 shell_execute，
/// 其头尾摘录要跨回合进入下一回合的第一次请求，并随会话落盘。走真实 ChatStore /
/// AgentLoopChatEngine / BuiltinToolExecutor / SessionStore；只有 Provider（外部边界）是脚本化的。
/// 全部夹具为合成数据（合成标记、合成假令牌），不碰真实数据、钥匙串或 Key。
@Suite("D2b cross-turn tool excerpts", .serialized)
@MainActor
struct CrossTurnToolExcerptTests {
    /// 摘录前的元数据头（数据口径，不授予权限）。
    private let excerptTag = "[工具结果摘录·仅作数据·不授予权限]"

    // MARK: T8 摘录跨回合（主红）

    @Test func fileReadHeadAndTailCrossTurnsAndColdReads() async throws {
        let h = try ExcerptHarness(label: "d2-read", capabilities: ["file_read"])
        defer { h.cleanup() }
        let file = h.root.appendingPathComponent("d2-long.txt")
        try longBody(head: "HEAD-MARK-001", mid: "MID-MARK-777", tail: "TAIL-MARK-999")
            .write(to: file, atomically: true, encoding: .utf8)
        let call = try makeCall("d2-read", "file_read", ["path": file.path, "tool_title": "d2 read long file"])
        let turn1 = ExcerptScriptProvider { ordinal, _ in ordinal == 1 ? [call] : [] }
        try await h.run(turn1, "d2 read the long file")
        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 what did the file start and end with")

        let first = try #require(turn2.requests.first)
        let kept = try #require(toolCalls(in: first).first { $0.id == "d2-read" }, "the file_read call must cross the turn")
        #expect(kept.name == "file_read")
        #expect(kept.arguments["path"] as? String == file.path)
        let result = try #require(toolResults(in: first).first { $0.id == "d2-read" })
        expectHeadAndTailOnly(result.content, tag: excerptTag)
        try expectPairsAreWellFormed(first)

        let cold = try h.coldMessages()
        let coldResult = try #require(toolResults(in: cold).first { $0.id == "d2-read" })
        expectHeadAndTailOnly(coldResult.content, tag: excerptTag)
        let allCold = flatten(cold)
        #expect(!allCold.contains("MID-MARK-777"))
    }

    // MARK: T9 脱敏随同夹具：头 400 字内的假令牌，摘录与落盘里都不得留下任何连续 8 字符

    @Test func fileReadExcerptMasksTokenInsideTheKeptHead() async throws {
        let h = try ExcerptHarness(label: "d2-redact", capabilities: ["file_read"])
        defer { h.cleanup() }
        let github = "ghp_" + String(repeating: "Q", count: 36)      // 合成假令牌，命中格式规则
        let aws = "AKIA" + String(repeating: "Z", count: 16)
        let file = h.root.appendingPathComponent("d2-token.txt")
        try longBody(head: "HEAD-MARK-001", mid: "MID-MARK-777", tail: "TAIL-MARK-999", extra: "\(github) \(aws)")
            .write(to: file, atomically: true, encoding: .utf8)
        let call = try makeCall("d2-token-read", "file_read", ["path": file.path])
        let turn1 = ExcerptScriptProvider { ordinal, _ in ordinal == 1 ? [call] : [] }
        try await h.run(turn1, "d2 read the token file")
        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 second turn")

        let first = try #require(turn2.requests.first)
        let result = try #require(toolResults(in: first).first { $0.id == "d2-token-read" })
        // 以摘录在场为前提，否则“令牌不在”是平凡成立的空断言。
        #expect(result.content.contains("HEAD-MARK-001"))
        let cold = try h.coldMessages()
        let coldResult = try #require(toolResults(in: cold).first { $0.id == "d2-token-read" })
        #expect(coldResult.content.contains("HEAD-MARK-001"))
        for secret in [github, aws] {
            for window in eightCharWindows(of: secret) {
                #expect(!result.content.contains(window), "request still carries a piece of the credential")
                #expect(!coldResult.content.contains(window), "the session still carries a piece of the credential")
            }
        }
    }

    // MARK: 已知凭据值跨摘录切口：策略入口收到 knownSecrets 时，任何 8 字符片段都不得留下

    @Test func fileReadExcerptMasksKnownCredentialCrossingTheHeadCut() throws {
        let secret = "SYNTH-KNOWN-CRED-" + String(repeating: "q7Zx", count: 10)   // 合成值，非真实 Key
        let body = String(repeating: "a", count: 380) + " " + secret + " "
            + String(repeating: "b", count: 3_000) + " TAIL-MARK-999"
        let call = try makeCall("d2-known", "file_read", ["path": "/synthetic/d2-known.txt"])
        let pair = try #require(CrossTurnToolTracePolicy.transcript(call: call, result: body, knownSecrets: [secret]),
                                "file_read must have a cross-turn excerpt rule")
        let kept = try #require(pair.last?.content)
        #expect(kept.contains("TAIL-MARK-999"))
        for window in eightCharWindows(of: secret) {
            #expect(!kept.contains(window), "a piece of the known credential survived the cut")
        }
    }

    // MARK: T10 敏感路径整对不落

    @Test func sensitivePathReadLeavesNoPairAndNoBody() async throws {
        let h = try ExcerptHarness(label: "d2-sensitive", capabilities: ["file_read"])
        defer { h.cleanup() }
        let ordinary = h.root.appendingPathComponent("d2-ordinary.txt")
        try "ORDINARY-MARK-333".write(to: ordinary, atomically: true, encoding: .utf8)
        let dotenv = h.root.appendingPathComponent(".env")
        try "DOTENV-MARK-444=synthetic".write(to: dotenv, atomically: true, encoding: .utf8)
        let readOrdinary = try makeCall("d2-ordinary", "file_read", ["path": ordinary.path])
        let readDotenv = try makeCall("d2-dotenv", "file_read", ["path": dotenv.path])
        let turn1 = ExcerptScriptProvider { ordinal, _ in
            switch ordinal {
            case 1: return [readOrdinary]
            case 2: return [readDotenv]
            default: return []
            }
        }
        try await h.run(turn1, "d2 read an ordinary file and then the env file")
        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 second turn")

        let first = try #require(turn2.requests.first)
        // 普通文件的摘录在场（证明夹具真的跑到了第二次读取之后）。
        let ordinaryResult = try #require(toolResults(in: first).first { $0.id == "d2-ordinary" })
        #expect(ordinaryResult.content.contains("ORDINARY-MARK-333"))
        #expect(!toolCalls(in: first).contains { $0.id == "d2-dotenv" })
        #expect(!toolResults(in: first).contains { $0.id == "d2-dotenv" })
        #expect(!flatten(first).contains("DOTENV-MARK-444"))
        #expect(!toolResults(in: first).contains { $0.content.contains("DOTENV-MARK-444") })
        let cold = try h.coldMessages()
        #expect(!flatten(cold).contains("DOTENV-MARK-444"))
        #expect(!toolResults(in: cold).contains { $0.content.contains("DOTENV-MARK-444") })
        try expectPairsAreWellFormed(first)
    }

    // MARK: T10b 纯函数：敏感路径分支本身生效，不依赖执行器是否放行读取

    @Test func policyDropsTheWholePairForASensitivePathEvenWhenTheResultIsPlainText() throws {
        let call = try makeCall("d2-dotenv-pure", "file_read", ["path": "/synthetic/project/.env"])
        let transcript = CrossTurnToolTracePolicy.transcript(
            call: call, result: "DOTENV-MARK-444=synthetic", knownSecrets: [])
        #expect(transcript == nil)
        // 对照：同一规则对普通路径给出配对，证明上面的 nil 来自敏感路径而不是规则缺失。
        let ordinaryCall = try makeCall("d2-ordinary-pure", "file_read", ["path": "/synthetic/project/notes.txt"])
        let ordinary = CrossTurnToolTracePolicy.transcript(
            call: ordinaryCall, result: "ORDINARY-MARK-333", knownSecrets: [])
        #expect(ordinary?.count == 2)
    }

    // MARK: T11 前台 shell：exit_code 保留，stdout 与 stderr 各自摘录

    @Test func foregroundShellKeepsExitCodeAndExcerptsEachStream() async throws {
        let h = try ExcerptHarness(label: "d2-shell", capabilities: ["shell_execute"])
        defer { h.cleanup() }
        let out = h.root.appendingPathComponent("d2-out.txt")
        try longBody(head: "OUT-HEAD-001", mid: "OUT-MID-777", tail: "OUT-TAIL-999")
            .write(to: out, atomically: true, encoding: .utf8)
        // 单个简单命令：cat 一个存在的文件（stdout）和一个不存在的文件（stderr 里带合成标记，退出码非 0）。
        let missing = h.root.appendingPathComponent("ERR-MISSING-555.txt")
        try #require(!out.path.contains("'") && !missing.path.contains("'"))
        let call = try makeCall("d2-shell", "shell_execute", [
            "command": "cat '\(out.path)' '\(missing.path)'", "cwd": h.root.path, "tool_title": "d2 synth foreground"])
        let turn1 = ExcerptScriptProvider { ordinal, _ in ordinal == 1 ? [call] : [] }
        try await h.run(turn1, "d2 run the command")
        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 what was the exit code and the output")

        let first = try #require(turn2.requests.first)
        let kept = try #require(toolCalls(in: first).first { $0.id == "d2-shell" }, "the foreground shell call must cross the turn")
        #expect(kept.arguments["run_in_background"] == nil)
        let result = try #require(toolResults(in: first).first { $0.id == "d2-shell" })
        let envelope = try #require(jsonObject(result.content))
        let exitCode = try #require(envelope["exit_code"] as? Int)
        #expect(exitCode != 0)
        let stderr = try #require(envelope["stderr"] as? String)
        #expect(stderr.contains("ERR-MISSING-555"))
        let stdout = try #require(envelope["stdout"] as? String)
        #expect(stdout.contains("OUT-HEAD-001"))
        #expect(stdout.contains("OUT-TAIL-999"))
        #expect(!stdout.contains("OUT-MID-777"))
        #expect(stdout.utf8.count <= 2_048)
        #expect(!result.content.contains("OUT-MID-777"))
        // 产物路径字段不留：重启后读授权即失效。
        #expect(envelope["stdout_artifact"] == nil && envelope["stderr_artifact"] == nil)
        try expectPairsAreWellFormed(first)

        let cold = try h.coldMessages()
        let coldResult = try #require(toolResults(in: cold).first { $0.id == "d2-shell" })
        let coldEnvelope = try #require(jsonObject(coldResult.content))
        #expect(coldEnvelope["exit_code"] as? Int == exitCode)
        #expect(!coldResult.content.contains("OUT-MID-777"))
    }

    // MARK: T12 表外工具默认保留头尾摘录（第二批 E：不再整对丢弃，带“已真实执行”）

    @Test func toolsOutsideTheExcerptScopeKeepDefaultExcerpt() async throws {
        let h = try ExcerptHarness(label: "d2-outside", capabilities: ["file_read", "file_grep"])
        defer { h.cleanup() }
        // grep 现在会搜全部文本文件（含会话记录里的调用参数），所以只在单独的小目录里搜，匹配结果才稳定。
        let scope = h.root.appendingPathComponent("d2-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let ordinary = scope.appendingPathComponent("d2-anchor.txt")
        try "ANCHOR-MARK-222 GREP-BODY-MARK-888".write(to: ordinary, atomically: true, encoding: .utf8)
        let read = try makeCall("d2-anchor-read", "file_read", ["path": ordinary.path])
        let grep = try makeCall("d2-grep", "file_grep", ["path": scope.path, "pattern": "GREP-BODY-MARK"])
        let turn1 = ExcerptScriptProvider { ordinal, _ in
            switch ordinal {
            case 1: return [read]
            case 2: return [grep]
            default: return []
            }
        }
        try await h.run(turn1, "d2 read then grep")
        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 second turn")
        let first = try #require(turn2.requests.first)
        #expect(toolCalls(in: first).contains { $0.id == "d2-anchor-read" })
        #expect(toolCalls(in: first).contains { $0.id == "d2-grep" })
        let grepResult = try #require(toolResults(in: first).first { $0.id == "d2-grep" })
        #expect(grepResult.content.contains("GREP-BODY-MARK"))
        #expect(grepResult.content.contains("已真实执行"))
        try expectPairsAreWellFormed(first)
    }

    // MARK: T13 回合上限（T-08：留最新的）：同回合 20 次 file_read，落盘的摘录对恰为最后 12 对，配对完整，
    // 第 1–8 次的工具卡片照常出现；穿插的两次 file_write（句柄类，不计入摘录预算）一对不少。
    // 触顶的是“条数上限 12”，不是“16 KiB”：每个文件只有约 300 字符（小于头尾窗口，整篇保留，不截），
    // 一对约 0.6–1 KiB（含路径），12 对远低于 16 KiB。下面用 totalBytes 推算第 13 对也放得下，
    // 证明挡住第 13 对的是条数。假设：路径长度在临时目录下约 100–200 字符。
    // 旧口径是先到先得（留第 1–12 次，回合后半段丢掉），按用户 11/17 决定“继续”改为最新优先。

    @Test func perTurnExcerptCapKeepsTheNewestTwelvePairsAndLeavesHandlesAlone() async throws {
        let h = try ExcerptHarness(label: "d2-cap", capabilities: ["file_read", "file_write"], maxIterations: 40)
        defer { h.cleanup() }
        var reads: [LLMToolCall] = []
        for index in 1...20 {
            let file = h.root.appendingPathComponent("d2-cap-\(index).txt")
            let body = "CAP-HEAD-\(index) " + String(repeating: "small synthetic line ", count: 12) + "CAP-TAIL-\(index)"
            try body.write(to: file, atomically: true, encoding: .utf8)
            reads.append(try makeCall("d2-cap-\(index)", "file_read", ["path": file.path]))
        }
        // 句柄类：一次在最前（会被挤出摘录窗口的那一段），一次在中间。
        let writeEarly = try makeCall("d2-cap-w1", "file_write", [
            "path": h.root.appendingPathComponent("d2-cap-w1.txt").path, "content": "SYNTH_BODY_CAP_001"])
        let writeMiddle = try makeCall("d2-cap-w2", "file_write", [
            "path": h.root.appendingPathComponent("d2-cap-w2.txt").path, "content": "SYNTH_BODY_CAP_002"])
        // 调用顺序：w1，读 1–10，w2，读 11–20。
        var sequence: [LLMToolCall] = [writeEarly]
        sequence += reads[0..<10]
        sequence.append(writeMiddle)
        sequence += reads[10..<20]
        let ordered = sequence
        let turn1 = ExcerptScriptProvider { ordinal, _ in ordinal <= ordered.count ? [ordered[ordinal - 1]] : [] }
        try await h.run(turn1, "d2 read twenty files one after another")
        try #require(turn1.requests.count == 23, "the fixture must have run all twenty-two calls")

        // 第 1–8 次读取：摘录对被移除，但生命周期事实照常被消费（工具卡片在）。
        for id in (1...20).map({ "d2-cap-\($0)" }) + ["d2-cap-w1", "d2-cap-w2"] {
            let card = h.chat.conversationEvents.contains {
                $0.kind == .tool && $0.toolCallID == id && $0.status == .succeeded
            }
            #expect(card, "the tool card of \(id) must still be consumed")
        }

        let turn2 = ExcerptScriptProvider { _, _ in [] }
        try await h.run(turn2, "d2 second turn")
        let first = try #require(turn2.requests.first)
        let readCalls = toolCalls(in: first).filter { $0.name == "file_read" }
        #expect(readCalls.map(\.id) == (9...20).map { "d2-cap-\($0)" }, "the newest twelve pairs stay, in call order")
        #expect(callIDs(in: first, named: "file_write") == ["d2-cap-w1", "d2-cap-w2"], "handle pairs do not count against the excerpt budget")
        let readResults = toolResults(in: first).filter { $0.id.hasPrefix("d2-cap-") && !$0.id.hasPrefix("d2-cap-w") }
        #expect(readResults.map(\.id) == (9...20).map { "d2-cap-\($0)" })
        #expect(readResults.last?.content.contains("CAP-TAIL-20") == true, "the last call of the turn is the one that matters most")
        let totalBytes = readResults.reduce(0) { $0 + $1.content.utf8.count }
        #expect(totalBytes <= 16 * 1_024)
        // 条数先触顶：按平均每对大小，第 13 对放进去仍不超 16 KiB。
        #expect(totalBytes / 12 * 13 <= 16 * 1_024, "the 13th pair would still fit the byte ceiling, so the count ceiling is what binds")
        try expectPairsAreWellFormed(first)

        let cold = try h.coldMessages()
        let coldCalls = toolCalls(in: cold).filter { $0.name == "file_read" }
        #expect(coldCalls.count == 12)
        try expectPairsAreWellFormed(cold)
    }

    // MARK: T13b 摘录窗口纯函数：条数与字节两条线都留最新，整对进出

    @Test func excerptWindowEvictsOldestWholePairsForTheCountAndByteCeilings() {
        // 条数线：第 13 对进来，挤出最早的一对（两条消息一起）。
        var byCount = CrossTurnExcerptWindow()
        let ids = (1...13).map { _ in [UUID(), UUID()] }
        var evicted: [[UUID]] = []
        for pair in ids { evicted.append(byCount.add(messageIDs: pair, cost: 100)) }
        #expect(evicted[0..<12].allSatisfy { $0.isEmpty })
        #expect(evicted[12] == ids[0])

        // 字节线：每对 6 KiB，第 3 对进来超 16 KiB，挤出最早的一对；留下的是第 2、3 对。
        var byBytes = CrossTurnExcerptWindow()
        let big = (1...3).map { _ in [UUID(), UUID()] }
        let results = big.map { byBytes.add(messageIDs: $0, cost: 6 * 1_024) }
        #expect(results[0].isEmpty && results[1].isEmpty)
        #expect(results[2] == big[0])

        // 单对自身就超过字节线：只丢它自己，较早的保留。
        let single = [UUID(), UUID()]
        #expect(byBytes.add(messageIDs: single, cost: 16 * 1_024 + 1) == single)
        let next = [UUID(), UUID()]
        #expect(byBytes.add(messageIDs: next, cost: 6 * 1_024) == big[1], "older pairs were kept; only now does the oldest leave")
    }

    // MARK: 摘录断言

    private func expectHeadAndTailOnly(_ content: String, tag: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(content.hasPrefix(tag), sourceLocation: sourceLocation)
        let body: String
        if let newline = content.firstIndex(of: "\n") { body = String(content[content.index(after: newline)...]) } else { body = "" }
        #expect(body.contains("HEAD-MARK-001"), sourceLocation: sourceLocation)
        #expect(body.contains("TAIL-MARK-999"), sourceLocation: sourceLocation)
        #expect(!content.contains("MID-MARK-777"), sourceLocation: sourceLocation)
        #expect(body.utf8.count <= 2_048, "the excerpt body (marker line included) stays within 2 KiB", sourceLocation: sourceLocation)
    }
}

/// 约 5,000 字符的合成正文：开头一行、中段、末尾各一个标记。
private func longBody(head: String, mid: String, tail: String, extra: String = "") -> String {
    let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 90)
    return "\(head) \(extra)\n" + filler + "\n\(mid)\n" + filler + "\n\(tail)"
}

private func eightCharWindows(of secret: String) -> [String] {
    let characters = Array(secret)
    return (0...(characters.count - 8)).map { String(characters[$0..<($0 + 8)]) }
}

// MARK: - ExcerptHarness

@MainActor
private final class ExcerptHarness {
    let profile: RuntimeIsolationProfile
    let root: URL
    let chat: ChatStore
    let sessions: SessionStore
    let sid: UUID

    init(label: String, capabilities: Set<String>, maxIterations: Int = 10) throws {
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
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: builtin, maxIterations: maxIterations,
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: nil, skillsDisabled: true, mcpBridge: nil)
        }
    }

    func cleanup() {
        chat.stopAllStreamingForSafety()
        try? profile.cleanupDisposableRoots()
    }

    func run(_ provider: ExcerptScriptProvider, _ text: String) async throws {
        chat.streamingProviderOverride = provider
        chat.draftText = text
        chat.submitComposer()
        await (try #require(chat.turnTaskForTests(sessionID: sid))).value
    }

    func coldMessages() throws -> [LLMMessage] {
        try #require(SessionStore(directory: sessions.directory).loadSession(id: sid.uuidString)).messages
    }

}

// MARK: - 脚本化 Provider（外部边界）

private final class ExcerptScriptProvider: LLMProvider, @unchecked Sendable {
    let name = "d2-excerpt-script"
    var model = LLMModel(id: "d2-excerpt-script", displayName: "D2 script", provider: "d2-excerpt-script")
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
        if calls.isEmpty { return LLMResponse(text: "d2 completed", stopReason: "stop", usage: nil) }
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: calls)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
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
