import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-MEMORY-02 / P3-H1（DEV-285）：自动压缩阈值在“下一真实请求”前的消费端。
/// C1（11/9）：触发信号由“累计用量预算占比”改为“下一请求的窗口占用”；
/// 压缩被拒且占用 <95% 照常发送，≥95% 仍拒（用户决定 1101:10）。
///
/// 阈值调整 + 持久化本身已具备（SettingsView → SettingsCenter.autoCompactThreshold
/// → SettingsStore）。本组测试只钉新接线的闸：普通（非显式命令）新一轮请求发起前，
/// ChatStore 必须按持久化阈值判断共享预算占用，达到阈值先经既有
/// `runScheduledCompaction` 安全门；不具有效缩减的旧史必须拒绝且不可在
/// 下次请求绕门。未达阈值 / 阈值非法 / 无阈值事实时行为与此前一致。
/// 普通自然对话的成功压缩仍属 D-COMPACT-01 OPEN，本短 fixture 不代验。
/// 会话标识全部为测试合成（临时 UserDefaults suite + 临时目录 UUID），不触碰
/// 真实凭据。编译与真实用例执行归唯一 PKG（本线不跑 heavy）。

private final class Threshold285Provider: LLMProvider, @unchecked Sendable {
    let name = "Threshold285Fixture"
    var model = LLMModel(id: "threshold285-fixture", displayName: "Threshold 285 fixture",
                         provider: "Threshold285Fixture")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    private let mutex = NSLock()
    private var pending: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation?
    private var streamCalls = 0
    private var summarizeCalls = 0
    private var turnHistory: [LLMMessage] = []
    private var summaryFailure: Error?

    /// Makes the following summary calls throw (nil restores the normal summary).
    func setSummaryFailure(_ error: Error?) { mutex.lock(); summaryFailure = error; mutex.unlock() }
    private func currentSummaryFailure() -> Error? { mutex.lock(); defer { mutex.unlock() }; return summaryFailure }

    func streamCallCount() -> Int { mutex.lock(); defer { mutex.unlock() }; return streamCalls }
    func summarizeCallCount() -> Int { mutex.lock(); defer { mutex.unlock() }; return summarizeCalls }
    func receivedTurn() -> [LLMMessage] { mutex.lock(); defer { mutex.unlock() }; return turnHistory }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        recordSummarizeCall()
        if let failure = currentSummaryFailure() { throw failure }
        return LLMResponse(text: "A synthetic 285 compaction summary", stopReason: "end_turn",
                           usage: LLMUsage(inputTokens: 1, outputTokens: 1))
    }

    /// T1 修复：NSLock 的 lock/unlock 不能直接在 async 上下文使用；把计数突变
    /// 移入非 async 同步辅助方法，从 async 方法调用同步方法合法，计数语义与调用时序不变。
    private func recordSummarizeCall() {
        mutex.lock(); summarizeCalls += 1; mutex.unlock()
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            mutex.lock(); streamCalls += 1; turnHistory = messages; pending = continuation; mutex.unlock()
        }
    }

    func finish() {
        mutex.lock(); let continuation = pending; pending = nil; mutex.unlock()
        continuation?.yield(.text("scheduled result"))
        continuation?.yield(.finished(stopReason: "end_turn"))
        continuation?.finish()
    }
}

@MainActor
private final class Threshold285Fixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let persistence: SessionStore
    let targetID = UUID()
    let activeID = UUID()
    let projectID = "threshold285-project"
    let chat: ChatStore
    let ledger: SchedulerTaskStore
    let provider = Threshold285Provider()
    let facts: ComposerPolicyFactSource
    var taskID: UUID!
    let original: [LLMMessage]
    var date = Date()
    var runtime: SchedulerTaskRuntime!
    var submissionErrors: [UUID: String] = [:]

    /// `compressible: true` gives a long plain-text history whose summary really
    /// shrinks the request. The short default history is still summarized by the
    /// model (one summary call) but cannot clear the material-reduction gate, so it is refused.
    init(command: String = "scheduled prompt", compressible: Bool = false) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threshold285-\(UUID().uuidString)")
        let suiteName = "threshold285-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        root = rootURL
        suite = suiteName
        defaults = preferences
        persistence = SessionStore(directory: rootURL.appendingPathComponent("sessions-root"))
        let padding = String(repeating: " plain narrative filler for a compressible history.", count: 12)
        original = (0..<(compressible ? 30 : 6)).map {
            LLMMessage(role: $0.isMultiple(of: 2) ? .user : .assistant,
                       content: compressible ? "source-\($0)\(padding)" : "source-\($0)")
        }
        chat = ChatStore(preferencesDefaults: preferences,
                         logManager: LogManager(directory: rootURL.appendingPathComponent("logs"),
                                                ringCapacity: 20))
        ledger = SchedulerTaskStore(defaults: preferences,
                                    occurrenceLedgerURL: rootURL.appendingPathComponent("occurrences.json"))
        _ = try persistence.createSession(id: targetID.uuidString, title: "target", projectID: projectID)
        _ = try persistence.createSession(id: activeID.uuidString, title: "untouched", projectID: "other-project")
        for message in original { try persistence.saveMessage(message, sessionID: targetID.uuidString) }
        #expect(chat.attachPersistence(persistence))
        #expect(chat.applySwitchSession(id: activeID))
        chat.draftText = "untouched active draft"
        facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "threshold285-policy", grantEpoch: "threshold285-epoch",
            leaseID: "threshold285-lease", expiresAt: date.addingTimeInterval(60 * 60))
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        taskID = try Self.register(ledger: ledger, chat: chat, command: command,
            targetID: targetID, projectID: projectID, ordinal: 1, facts: facts, now: date)
        runtime = makeRuntime(ledger)
    }

    /// 注册并确认一个锚定到当前规范转录的任务，返回新任务 ID。
    static func register(ledger: SchedulerTaskStore, chat: ChatStore, command: String,
        targetID: UUID, projectID: String, ordinal: Int,
        facts: ComposerPolicyFactSource, now: Date) throws -> UUID {
        let before = Set(ledger.allTasks().map(\.id))
        #expect(ledger.add(name: "threshold285-\(UUID().uuidString)", cronExpression: "* * * * *",
            command: command, targetSessionID: targetID, targetProjectID: projectID,
            targetTurnID: ordinal) == nil)
        let added = ledger.allTasks().filter { !before.contains($0.id) }
        let taskID = try #require(added.count == 1 ? added.first?.id : nil)
        var preview = try #require(ledger.preview(taskID: taskID, now: now))
        let digest = try #require(chat.schedulerSourceAnchorDigest(
            sessionID: targetID, projectID: projectID, ordinal: ordinal))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = facts.revision
        #expect(ledger.confirmPreview(preview, actorID: "test-user", scopeID: projectID,
            policyRevision: facts.revision, now: now, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: facts.revision))
        return taskID
    }

    /// 阈值经由既有装配入口进入 ChatStore（configureBudget(from:) 的入参即
    /// 持久化 AppSettings.agent 快照）。测试直接构造同样的持久化值。
    func configurePersistedThreshold(_ value: Double) {
        var agent = AgentSettings.default
        agent.autoCompactThreshold = value
        chat.configureBudget(from: agent)
    }

    func installLiveProjectionThreshold(_ value: Double) {
        chat.effectiveSettingsSnapshotSource = {
            BL6EffectiveSettingsSnapshot(catalogRevision: "threshold285-live",
                values: ["agent.auto-compact-threshold": .decimal(value)])
        }
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let injector = SkillInjector(store: skillStore)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil
            )
        }
    }

    /// C1: the scheduled turn's trigger is the window occupancy of the target
    /// session's next request (user decisions 2130 / 1101:9), no longer the
    /// cumulative-usage budget. Records what the last request would have
    /// reported: `tokens` of a 100_000-token window (60_000 = 60%, 97_000 = 97%).
    func recordOccupancy(_ tokens: Int) {
        chat.recordWindowOccupancy(
            sessionID: targetID, providerID: provider.name, modelID: provider.model.id,
            sentMessageCount: original.count, inputTokens: tokens, windowTokens: 100_000)
    }

    func makeRuntime(_ store: SchedulerTaskStore) -> SchedulerTaskRuntime {
        SchedulerTaskRuntime(store: store, now: { [weak self] in self?.date ?? Date() },
            sourceAnchorResolver: { [weak self] session, project, ordinal in
                self?.chat.schedulerSourceAnchorDigest(sessionID: session, projectID: project, ordinal: ordinal)
            }, policyRevisionResolver: { [weak self] in self?.chat.schedulerPolicyRevision() },
            submitEffect: { [weak self] context in
                guard let self else { throw CancellationError() }
                do {
                    return try await self.chat.submitScheduledRequest(context)
                } catch {
                    self.submissionErrors[context.request.occurrenceID] = String(reflecting: error)
                    throw error
                }
            })
    }

    func waitForStream(count: Int = 1, taskID: UUID? = nil) async throws {
        for _ in 0..<300 {
            if provider.streamCallCount() >= count { return }
            if let id = taskID ?? self.taskID,
               let occurrence = ledger.latestOccurrence(for: id), occurrence.state.isTerminal {
                throw NSError(domain: "Threshold285Fixture.stream", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: diagnostic(occurrence)])
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "Threshold285Fixture.stream", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                diagnostic((taskID ?? self.taskID).flatMap { ledger.latestOccurrence(for: $0) })])
    }

    func diagnostic(_ occurrence: SchedulerOccurrence?) -> String {
        guard let occurrence else { return "no occurrence; no stream" }
        return "terminal=\(occurrence.state.rawValue); delivery=\(occurrence.deliveryReceipt?.detail ?? "none"); sourceError=\(submissionErrors[occurrence.id] ?? "none")"
    }

    func waitForTerminal(taskID: UUID? = nil) async throws -> SchedulerOccurrence {
        // T2 修复：显式处理 nil（不做 force-unwrap）；nil 时沿用本 fixture 域错误风格抛出。
        guard let id = taskID ?? self.taskID else {
            throw NSError(domain: "Threshold285Fixture.terminal", code: 2)
        }
        for _ in 0..<300 {
            if let occurrence = ledger.latestOccurrence(for: id), occurrence.state.isTerminal { return occurrence }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "Threshold285Fixture.terminal", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                diagnostic(ledger.latestOccurrence(for: id))])
    }

    func cleanup() {
        runtime.stop()
        provider.finish()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("D-MEMORY-02 auto-compaction threshold consumer")
@MainActor
struct AutoCompactionThresholdConsumer285Tests {
    /// This short, distinct history is summarized by the model (one summary call)
    /// but the summary cannot materially shrink the request. At the hard block
    /// (>= 95% of the window) reaching the threshold must still refuse before a
    /// real request rather than discard the original transcript or claim a
    /// compacted turn. (Old trigger: shared budget 60k/100k.)
    @Test func thresholdReachedAtHardBlockRefusesIneffectiveHistoryBeforeRealRequest() async throws {
        let f = try Threshold285Fixture()
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.5)
        f.recordOccupancy(97_000)  // 97% of the window: above the 95% hard block
        f.runtime.pollNow(at: f.date)
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .failed)
        #expect(f.submissionErrors[terminal.id]?.contains("noMeaningfulReduction") == true)
        #expect(f.provider.streamCallCount() == 0)
        #expect(f.provider.summarizeCallCount() == 1)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
        let session = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
        #expect(session.messages == f.original)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
        #expect(f.persistence.loadSession(id: f.activeID.uuidString)?.messages.isEmpty == true)
    }

    /// C3 (user decision 1101:10, 11/9 contract change). Old: threshold reached on
    /// this history -> refusal -> occurrence failed, stream 0 (the test above's
    /// assertions at 60% budget). New: below the 95% hard block the Compactor's
    /// refusal no longer stops the scheduled request; it is sent with the
    /// original, uncompacted history.
    @Test func thresholdReachedBelowHardBlockStillSendsAfterRefusal() async throws {
        let f = try Threshold285Fixture()
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.5)
        f.recordOccupancy(60_000)  // 60%: above the 50% threshold, below the hard block
        f.runtime.pollNow(at: f.date)
        try await f.waitForStream()
        // One summary attempt that cannot materially shrink the request.
        #expect(f.provider.summarizeCallCount() == 1)
        #expect(f.provider.receivedTurn().contains { $0.content == "source-0" })
        f.provider.finish()
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .succeeded)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
        let session = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
        #expect(session.messages == f.original + [
            LLMMessage(role: .user, content: "scheduled prompt"),
            LLMMessage(role: .assistant, content: "scheduled result"),
        ])
    }

    /// 未达阈值：完全不压缩，行为与此前一致（不越权顺手压缩）。
    @Test func belowThresholdDoesNotCompact() async throws {
        let f = try Threshold285Fixture()
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.95)
        f.recordOccupancy(60_000)  // 0.6 < 0.95
        f.runtime.pollNow(at: f.date)
        try await f.waitForStream()
        #expect(f.provider.summarizeCallCount() == 0)
        #expect(f.provider.receivedTurn().contains { $0.content == "source-0" })
        f.provider.finish()
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .succeeded)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
        let session = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
        #expect(session.messages == f.original + [
            LLMMessage(role: .user, content: "scheduled prompt"),
            LLMMessage(role: .assistant, content: "scheduled result"),
        ])
    }

    /// 同一窗口占用（60%，低于 95% 硬线），只改阈值：0.5 必须发起压缩尝试，0.9 不得发起。
    /// 用可压缩的长历史，尝试以摘要调用数观察（C3 之后 <95% 的被拒尝试对外无产物差异，
    /// 所以不能只看终态）。
    @Test func adjustedThresholdChangesTriggering() async throws {
        for (threshold, expectAttempt) in [(0.5, true), (0.9, false)] {
            let f = try Threshold285Fixture(compressible: true)
            defer { f.cleanup() }
            f.configurePersistedThreshold(threshold)
            f.recordOccupancy(60_000)
            f.runtime.pollNow(at: f.date)
            try await f.waitForStream()
            f.provider.finish()
            let terminal = try await f.waitForTerminal()
            #expect(terminal.state == .succeeded)
            if expectAttempt {
                #expect(f.provider.summarizeCallCount() >= 1, "threshold \(threshold) at 60% must attempt compaction")
            } else {
                #expect(f.provider.summarizeCallCount() == 0, "threshold \(threshold) at 60% must not attempt compaction")
            }
        }
    }

    /// 下一真实请求优先读取实时生效投影（与提交栅栏同源）：装配期副本 0.5 在 60% 占用上
    /// 会发起压缩（见上一条），实时有效阈值 0.9 覆盖它后不得发起，证明消费端不是常量或陈旧副本。
    @Test func liveEffectiveProjectionOverridesAssembledCopyAtRequestTime() async throws {
        let f = try Threshold285Fixture(compressible: true)
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.5)
        f.installLiveProjectionThreshold(0.9)
        f.recordOccupancy(60_000)
        f.runtime.pollNow(at: f.date)
        try await f.waitForStream()
        #expect(f.provider.summarizeCallCount() == 0)
        f.provider.finish()
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .succeeded)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
    }

    /// 压缩因 Provider 错误抛出（非"被拒"）时，该转录版本不得算作已判定：同一版本上的下一次
    /// 发送仍要发起压缩。（旧：判定标记在尝试前就置位，错误后同版本直接跳过压缩。）
    @Test func compactionThatThrewDoesNotMarkTheTranscriptVersionJudged() async throws {
        let f = try Threshold285Fixture(compressible: true)
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.5)
        f.recordOccupancy(60_000)  // 60%: compaction is attempted, and the window is not full
        f.provider.setSummaryFailure(URLError(.timedOut))
        f.runtime.pollNow(at: f.date)
        let first = try await f.waitForTerminal()
        #expect(first.state == .failed)
        #expect(f.provider.summarizeCallCount() >= 1)
        #expect(f.provider.streamCallCount() == 0)
        let attemptsAfterFirst = f.provider.summarizeCallCount()
        // Same session, same transcript version (nothing was written), working summarizer.
        f.provider.setSummaryFailure(nil)
        f.ledger.setEnabled(f.taskID, enabled: false)
        let secondTaskID = try Threshold285Fixture.register(ledger: f.ledger, chat: f.chat,
            command: "follow-up prompt", targetID: f.targetID, projectID: f.projectID,
            ordinal: 1, facts: f.facts, now: f.date.addingTimeInterval(60))
        f.date = f.date.addingTimeInterval(60)
        f.runtime.pollNow(at: f.date)
        try await f.waitForStream(taskID: secondTaskID)
        #expect(f.provider.summarizeCallCount() > attemptsAfterFirst,
            "the failed attempt must not make the same version skip compaction")
    }

    /// 非法阈值（≤0）与从未配置阈值都不构成触发事实：宁可维持旧行为，
    /// 也不回退到任何常量默认。
    @Test func invalidOrMissingThresholdNeverTriggers() async throws {
        let f = try Threshold285Fixture()
        defer { f.cleanup() }
        f.configurePersistedThreshold(0)
        f.recordOccupancy(97_000)
        f.runtime.pollNow(at: f.date)
        try await f.waitForStream()
        f.provider.finish()
        #expect(f.provider.summarizeCallCount() == 0)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
        // 从未 configureBudget 的第二段账期同样无阈值事实。
        let g = try Threshold285Fixture(command: "second scheduled prompt")
        defer { g.cleanup() }
        g.recordOccupancy(97_000)
        g.runtime.pollNow(at: g.date)
        try await g.waitForStream()
        g.provider.finish()
        #expect(g.provider.summarizeCallCount() == 0)
        #expect(try g.persistence.loadLatestCompactionCheckpoint(sessionID: g.targetID.uuidString) == nil)
    }

    /// A failed safety check is not a successful compaction. A later scheduled
    /// request on the same transcript version at >= 95% of the window must still be
    /// refused; it cannot stream the uncompressed history. C1 contract change: the
    /// second request is no longer refused by a second compaction attempt (the version
    /// was already judged, no churn) but by the window gate itself, `contextWindowFull`
    /// (old: `noMeaningfulReduction` again, from a repeated attempt).
    @Test func failedCompactionDoesNotBypassThresholdOnNextRequest() async throws {
        let f = try Threshold285Fixture()
        defer { f.cleanup() }
        f.configurePersistedThreshold(0.5)
        f.recordOccupancy(97_000)
        f.runtime.pollNow(at: f.date)
        let first = try await f.waitForTerminal()
        #expect(first.state == .failed)
        #expect(f.submissionErrors[first.id]?.contains("noMeaningfulReduction") == true)
        #expect(f.provider.streamCallCount() == 0)
        // Pause only the first synthetic schedule. Keep the same session,
        // source anchor and shared budget for a distinct second occurrence.
        f.ledger.setEnabled(f.taskID, enabled: false)
        let secondTaskID = try Threshold285Fixture.register(ledger: f.ledger, chat: f.chat,
            command: "follow-up prompt", targetID: f.targetID, projectID: f.projectID,
            ordinal: 1, facts: f.facts, now: f.date.addingTimeInterval(60))
        f.date = f.date.addingTimeInterval(60)
        f.runtime.pollNow(at: f.date)
        let second = try await f.waitForTerminal(taskID: secondTaskID)
        #expect(second.state == .failed)
        #expect(f.submissionErrors[second.id]?.contains("contextWindowFull") == true)
        #expect(f.provider.streamCallCount() == 0)
        #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
    }
}
