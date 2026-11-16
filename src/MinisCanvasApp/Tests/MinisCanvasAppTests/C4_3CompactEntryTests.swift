import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class NamedCompactionProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel

    init(_ name: String) {
        self.name = name
        self.model = LLMModel(id: name, displayName: name, provider: name)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: name, stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class CompactionProviderCaptureEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { false }

    private let lock = NSLock()
    private var _providerNames: [String] = []

    var providerNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _providerNames
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        lock.withLock {
            _providerNames.append(provider.name)
        }
        return CompactionResult(
            messages: history.map { $0.asLLMMessage() },
            summary: nil,
            compactedCount: 0,
            refusalReason: .unverifiableInformationLoss
        )
    }
}

// MARK: - C4-3 压缩入口 + 右栏 token 清理 + thread 命令注册
//
// 覆盖（C4 Codex 对照 Top4 / Top5 + P2）：
// ① 压缩入口：引擎 compactContext（两种引擎共用 Compactor 默认实现）
//    + ChatStore.compactContext 的安全拒绝 / 异步入口。自然不同内容的
//      有效摘要与同会话续聊仍是 D-COMPACT-01 OPEN，不能由这些短夹具代验。
// ② 右栏 token 文案：tokenUsageLabel 无 C: 前缀（ContextPanelView 右栏同款，Top5）
// ③ thread 命令注册：ui.chat.compact（新增）/ session.new（新会话）/ ui.chat.stop（打断生成）

@Suite("C4-3 压缩入口与命令补全")
@MainActor
struct C4_3CompactEntryTests {

    // MARK: 测试装配（与 C3_1 同款：临时目录 + 全部后端禁用，不碰真实磁盘）

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("C4-3-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func offlineBackends() -> LocalBackends {
        let configs: [LocalBackendKind: LocalBackendConfig] = Dictionary(
            uniqueKeysWithValues: LocalBackendKind.allCases.map {
                ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
            }
        )
        return LocalBackends(configs: configs)
    }

    private func makeAssembled(_ name: String) throws -> (bridge: BridgeStore, registry: CommandRegistry) {
        let dir = try makeTempDir(name)
        let deps = CommandDependencies(
            env: EnvVarStore(directory: dir),
            log: LogManager(directory: dir),
            backends: offlineBackends(),
            sessions: SessionStore(directory: dir),
            memory: MemoryStore(directory: dir),
            workflows: WorkflowStore(storeDirectory: dir.appendingPathComponent("Workflows", isDirectory: true))
        )
        let bridge = BridgeStore()
        let registry = AppCommandCatalog.makeRegistry(bridge: bridge, dependencies: deps)
        return (bridge, registry)
    }

    /// 聊天：3 问 2 答，外加可能存在的 system 欢迎语。
    private func makeChat() -> ChatStore {
        let chat = ChatStore()
        chat.appendUser("第一条")
        chat.appendAssistant("回复一")
        chat.appendUser("第二条")
        chat.appendAssistant("回复二")
        chat.appendUser("第三条")
        return chat
    }

    // MARK: ① 压缩入口（Top4）

    @Test func engineCompactsHistoryIntoSummaryAndRecentTail() async throws {
        let engine = FallbackChatEngine()
        let history = (1...6).map { ChatMessageUI(role: $0 % 2 == 0 ? .assistant : .user, content: "消息 \($0)") }
        let result = try await engine.compactContext(
            provider: MockProvider.shared, history: history, systemPrompt: "test", keepRecent: 3
        )
        // 旧 3 条折叠成摘要 → 摘要 + 3 条尾
        #expect(result.compactedCount == 3)
        #expect(result.messages.count == 4)
        #expect(result.summary != nil)
        // 摘要消息带 Compactor 的 <context-summary> 信封（LLM 载荷契约）
        #expect(result.messages.first?.content.contains("<context-summary>") == true)
        // 最近消息原样保留
        #expect(result.messages.suffix(3).map(\.content) == history.suffix(3).map(\.content))
    }

    @Test func agentLoopEngineUsesSameCompaction() async throws {
        let engine = AgentLoopChatEngine()
        let history = (1...5).map { ChatMessageUI(role: .user, content: "消息 \($0)") }
        let result = try await engine.compactContext(
            provider: MockProvider.shared, history: history, systemPrompt: "test", keepRecent: 2
        )
        #expect(result.compactedCount == 3)
        #expect(result.messages.count == 3) // 摘要 + 2 条尾
    }

    @Test func ineffectiveContextKeepsCanonicalMessagesAndShowsRefusal() async {
        let chat = makeChat()
        let original = chat.messages.filter { $0.role != .system }

        await chat.runCompaction(history: chat.messages, keepRecent: 3)

        #expect(chat.messages.filter { $0.role != .system } == original)
        #expect(chat.messages.last?.role == .system)
        #expect(chat.messages.last?.content.contains("不会明显减少模型上下文") == true)
        #expect(!chat.messages.contains { $0.content.contains("🪄 已压缩上下文") })
    }

    @Test func shortContextIsLeftUntouched() async {
        let chat = ChatStore()
        chat.appendUser("只有一条")
        let before = chat.messages
        await chat.runCompaction(history: chat.messages, keepRecent: 3)
        // 原消息原样保留（仅追加一条「无需压缩」提示，system 角色不计入）
        #expect(chat.messages.filter { $0.role != .system } == before)
        #expect(chat.messages.last?.content == "上下文较短，无需压缩。")
        #expect(chat.compactionPresentation?.message == chat.messages.last?.content)
    }

    @Test func compactContextEntryRunsAsync() async throws {
        let chat = makeChat()
        let original = chat.messages.filter { $0.role != .system }
        chat.compactContext(keepRecent: 3)
        // The short source cannot clear the reduction gate. Wait for the
        // actual asynchronous refusal, not an old UI-replacement success hint.
        var waited: TimeInterval = 0
        while !chat.messages.contains(where: { $0.content.contains("不会明显减少模型上下文") }) && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(chat.messages.last?.content.contains("不会明显减少模型上下文") == true)
        #expect(chat.messages.filter { $0.role != .system } == original)
    }

    @Test func compactionKeepsProviderBoundToCapturedSessionAcrossSwitch() async throws {
        let chat = makeChat()
        let engine = CompactionProviderCaptureEngine()
        chat.agentEngine = engine
        let providerA = NamedCompactionProvider("provider-A")
        let providerB = NamedCompactionProvider("provider-B")
        chat.compactionProviderOverride = providerA
        let sessionA = try #require(chat.activeSessionID)
        let originalA = try #require(chat.messages(forSession: sessionA))

        chat.compactContext(keepRecent: 3)
        // No await between launch and switch: the scheduled compaction task
        // must observe the provider captured for A, not the later B override.
        chat.compactionProviderOverride = providerB
        let sessionB = chat.applyNewSession()
        let originalB = try #require(chat.messages(forSession: sessionB))

        // The engine records its provider before ChatStore checks the result.
        // Wait for the source session's actual refusal, then verify that the
        // background operation did not even append a notice to B.
        var waited: TimeInterval = 0
        while waited < 5 {
            let refused = chat.messages(forSession: sessionA)?.contains(where: {
                $0.role == .system && $0.content.hasPrefix("没有可压缩的旧内容")
            }) == true
            if refused { break }
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }

        let sourceNotice = chat.messages(forSession: sessionA)?.last?.content ?? "missing notice"
        #expect(sourceNotice.contains("没有可压缩的旧内容"), Comment(rawValue: sourceNotice))
        #expect(engine.providerNames == ["provider-A"])
        #expect(chat.activeSessionID == sessionB)
        // This mock explicitly refuses an unverifiable projection. Capturing
        // A's provider cannot authorize replacing either session's history.
        #expect(Array((chat.messages(forSession: sessionA) ?? []).prefix(originalA.count)) == originalA)
        #expect(chat.messages(forSession: sessionA)?.count == originalA.count + 1)
        #expect(chat.messages(forSession: sessionB) == originalB)
    }

    @Test func noChangeCompactionNoticeStaysWithSourceSession() async throws {
        let chat = makeChat()
        let sessionA = try #require(chat.activeSessionID)
        let originalA = try #require(chat.messages(forSession: sessionA))
        let revisionA = try #require(chat.transcriptRevision(forSession: sessionA))
        let sessionB = chat.applyNewSession()
        let originalB = try #require(chat.messages(forSession: sessionB))

        await chat.runCompaction(history: originalA.filter { $0.role != .system },
            keepRecent: originalA.count, sessionID: sessionA,
            expectedTranscriptRevision: revisionA)

        #expect(chat.messages(forSession: sessionA)?.last?.content == "上下文较短，无需压缩。")
        #expect(chat.messages(forSession: sessionB) == originalB)
    }

    @Test func deletedCompactionSourceCannotNotifyActiveSession() async throws {
        let chat = makeChat()
        chat.agentEngine = CompactionProviderCaptureEngine()
        let provider = NamedCompactionProvider("provider-A")
        let sessionA = try #require(chat.activeSessionID)
        let originalA = try #require(chat.messages(forSession: sessionA))
        let historyA = originalA.filter { $0.role != .system }
        let revisionA = try #require(chat.transcriptRevision(forSession: sessionA))
        let sessionB = chat.applyNewSession()
        let originalB = try #require(chat.messages(forSession: sessionB))
        let intent = try chat.previewDeletion(id: sessionA)
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteSession(id: sessionA, intent: intent)

        await chat.runCompaction(history: historyA, keepRecent: 3,
            sessionID: sessionA, expectedTranscriptRevision: revisionA,
            providerBox: LLMProviderBox(value: provider))

        #expect(chat.messages(forSession: sessionA) == nil)
        #expect(chat.activeSessionID == sessionB)
        #expect(chat.messages(forSession: sessionB) == originalB)
    }

    @Test func staleCompactionRefusalCannotAppendToChangedSession() async throws {
        let chat = makeChat()
        chat.agentEngine = CompactionProviderCaptureEngine()
        let sessionA = try #require(chat.activeSessionID)
        let originalA = try #require(chat.messages(forSession: sessionA))
        let historyA = originalA.filter { $0.role != .system }
        let oldRevision = try #require(chat.transcriptRevision(forSession: sessionA))
        chat.appendUser("A 的后续新消息")
        let changedA = try #require(chat.messages(forSession: sessionA))
        let sessionB = chat.applyNewSession()
        let originalB = try #require(chat.messages(forSession: sessionB))

        await chat.runCompaction(history: historyA, keepRecent: 3,
            sessionID: sessionA, expectedTranscriptRevision: oldRevision,
            providerBox: LLMProviderBox(value: NamedCompactionProvider("provider-A")))

        #expect(chat.messages(forSession: sessionA) == changedA)
        #expect(chat.messages(forSession: sessionB) == originalB)
    }

    // MARK: ② 右栏 token 文案（Top5：去 C: 前缀）

    @Test func tokenLabelMatchesU1Copy() {
        let label = ChatStore.tokenUsageLabel(used: 1_200, cap: 100_000)
        #expect(label == "已用 1.2k / 100k tokens")
        #expect(!label.contains("C:"))
        // ContextPanelView 右栏与主路径同款（U1 tokenUsageLabel）
        let chat = ChatStore()
        chat.recordTokens(500)
        let panelLabel = ChatStore.tokenUsageLabel(used: chat.budgetUsedTokens, cap: chat.budgetCapTokens)
        #expect(panelLabel.hasPrefix("已用"))
        #expect(panelLabel.hasSuffix("tokens"))
        #expect(!panelLabel.contains("C:"))
    }

    // MARK: ③ thread 命令注册（P2）

    @Test func registryRegistersThreadCommands() async throws {
        let (bridge, registry) = try makeAssembled("thread-cmds")
        let registeredIDs = registry.allCommands().map(\.id)
        let ids = Set(registeredIDs)
        // 压缩上下文（C4-3 新增）
        #expect(ids.contains("ui.chat.compact"))
        let legacy = try #require(registry.command(id: "ui.chat.compact"))
        #expect(legacy.id == "ui.chat.compact")
        #expect(legacy.aliases.contains("compact"))
        #expect(registeredIDs.filter { $0 == "ui.chat.compact" }.count == 1)

        // 294 adds the Composer canonical definition to this same registry.
        // Direct IDs take precedence over the older UI spec's alias. Keep the
        // approved UI command available; do not route slash input around its
        // separate pending-request / approval consumer merely to satisfy C4-3.
        let canonical = try #require(registry.command(id: "compact"))
        #expect(canonical.id == "compact")
        #expect(registeredIDs.filter { $0 == "compact" }.count == 1)
        #expect(canonical.requiresConfirmation)
        #expect(CommandRegistry.composerMetadata(for: "compact")?.risk == .medium)
        #expect(CommandRegistry.composerMetadata(for: "compact")?.requiresPolicyApproval == true)
        let parser = CommandParser()
        #expect(parser.parse("/ui.chat.compact", registry: registry).command?.id == legacy.id)
        for input in ["/compact", "/压缩", "/压缩上下文"] {
            let parsed = parser.parse(input, registry: registry)
            #expect(parsed.command?.id == canonical.id)
            #expect(parsed.intentDisposition == .authorizationRequired)
            let requestID = UUID()
            let pending = try registry.validatedComposerPendingRequest(
                for: parsed, requestID: requestID
            ).get()
            #expect(pending.id == requestID)
            #expect(pending.commandID == canonical.id)
            #expect(pending.requiresPolicyApproval)
        }

        let menu = AppCommandMenuBuilder.sections(registry: registry, display: [:])
            .flatMap(\.commands)
        let legacyMenu = try #require(menu.first { $0.id == legacy.id })
        let composerMenu = try #require(menu.first { $0.id == canonical.id })
        #expect(legacyMenu.isEnabled)
        // N05 (0f77569, approved by the 0737 R1 receipt) exposes the
        // canonical compact consumer in the shared menu. Availability does
        // not bypass the pending/confirmation contract checked below.
        #expect(composerMenu.isEnabled)
        #expect(composerMenu.disabledReason == nil)

        // Looking up canonical compact never grants direct execution. The
        // unchanged async test below exercises the real legacy UI producer's
        // dispatch and safe-refusal consumer; here pin the canonical gate.
        let transcript = bridge.chat.messages
        let priorPending = bridge.chat.pendingComposerCommand
        let priorReceipt = bridge.chat.lastComposerCommandReceipt
        await #expect(throws: CommandExecutionError.confirmationRequired("compact")) {
            try await registry.execute(id: "compact")
        }
        #expect(bridge.chat.messages == transcript)
        #expect(bridge.chat.pendingComposerCommand == priorPending)
        #expect(bridge.chat.lastComposerCommandReceipt == priorReceipt)
        // 新会话 / 打断生成（既有命令，面板一并可用）
        #expect(ids.contains("session.new"))
        #expect(ids.contains("ui.chat.stop"))
        // 中文关键字可命中压缩命令
        let hits = registry.search("压缩上下文", limit: 10)
        #expect(hits.contains { $0.id == "ui.chat.compact" })
    }

    @Test func compactCommandRejectsSessionSwitchBeforeDispatch() async throws {
        let (bridge, _) = try makeAssembled("compact-stale-session")
        let chat = bridge.chat
        chat.newSession()
        let sourceID = try #require(chat.activeSessionID)
        for index in 1...4 { chat.appendUser("原会话消息 \(index)") }
        let sourceMessages = chat.messages.map(\.id)

        chat.newSession()
        let otherID = try #require(chat.activeSessionID)
        try #require(otherID != sourceID)
        for index in 1...4 { chat.appendUser("另一会话消息 \(index)") }
        let otherMessages = chat.messages.map(\.id)
        chat.switchSession(id: sourceID)
        try #require(chat.activeSessionID == sourceID)

        let sequence = bridge.commandTaskRegistrationSequence
        bridge.runCommand(id: "ui.chat.compact") { succeeded in
            #expect(!succeeded)
        }
        chat.switchSession(id: otherID)
        try #require(chat.activeSessionID == otherID)
        let tasks = try #require(bridge.commandTaskSnapshot(after: sequence))
        try #require(tasks.count == 1)
        await tasks[0].value

        #expect(chat.messages.map(\.id) == otherMessages)
        #expect(!chat.requiresCompactionConfirmation)
        #expect(chat.compactionPresentation == nil)

        chat.switchSession(id: sourceID)
        #expect(chat.activeSessionID == sourceID)
        #expect(chat.messages.dropLast().map(\.id) == sourceMessages)
        #expect(chat.messages.last?.content.contains("压缩操作所属会话已切换或不可用") == true)
        #expect(!chat.requiresCompactionConfirmation)
        #expect(chat.compactionPresentation == nil)
    }

    @Test func compactCommandDispatchesButCannotClaimIneffectiveCompaction() async throws {
        let (bridge, registry) = try makeAssembled("compact-exec")
        bridge.chat.appendUser("一")
        bridge.chat.appendAssistant("回复一")
        bridge.chat.appendUser("二")
        bridge.chat.appendAssistant("回复二")
        bridge.chat.appendUser("三")
        let original = bridge.chat.messages.filter { $0.role != .system }

        let result = try await registry.execute(id: "ui.chat.compact")
        #expect(result.ok)
        // `result.ok` is a dispatch receipt. The asynchronous safe refusal
        // must remain visible and must not erase the canonical transcript.
        var waited: TimeInterval = 0
        while !bridge.chat.messages.contains(where: { $0.content.contains("不会明显减少模型上下文") }) && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(bridge.chat.messages.last?.content.contains("不会明显减少模型上下文") == true)
        #expect(bridge.chat.messages.filter { $0.role != .system } == original)
        let presentation = try #require(bridge.chat.compactionPresentation)
        #expect(presentation.state != .failed)
        #expect(bridge.chat.messages.last?.content == "当前对话压缩后不会明显减少模型上下文，未压缩。")
        #expect(presentation.message == bridge.chat.messages.last?.content)
    }
}
