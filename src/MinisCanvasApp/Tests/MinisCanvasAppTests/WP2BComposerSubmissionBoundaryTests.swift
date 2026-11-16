import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("WP-2B Composer submission boundary")
@MainActor
struct WP2BComposerSubmissionBoundaryTests {
    @Test("Global and sidebar production consumers use the shared submission boundary")
    func productionConsumersUseSharedBoundary() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = appRoot.appendingPathComponent("Sources/MinisCanvasApp")
        let global = try String(
            contentsOf: sourceRoot.appendingPathComponent("GlobalComposerView.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: sourceRoot.appendingPathComponent("ChatSidebarView.swift"),
            encoding: .utf8
        )

        #expect(global.contains("chat.submitComposer()"))
        #expect(sidebar.contains("chat.submitComposer()"))
        #expect(!global.contains("chat.sendDraft()"))
        #expect(!sidebar.contains("chat.sendDraft()"))
    }

    @Test("submission freezes policy identity and input before routing")
    func submissionFreezesSnapshotAtBoundary() throws {
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "wp2b-workspace",
            revision: "wp2b-revision",
            grantEpoch: "wp2b-epoch",
            leaseID: "wp2b-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .autoEdit,
            approvalScope: .session,
            effort: .high,
            bypassModeConfirmed: false
        )
        chat.draftText = "建节点 测试输入"

        var captured: ComposerSubmissionSnapshot?
        chat.onSendCommand = { _, snapshot in
            captured = snapshot
            return true
        }

        chat.submitComposer()
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual,
            approvalScope: .request,
            effort: .low,
            bypassModeConfirmed: true
        )

        let snapshot = try #require(captured)
        #expect(snapshot.mode == .autoEdit)
        #expect(snapshot.approvalScope == .session)
        #expect(snapshot.effort == .high)
        #expect(snapshot.sessionID == chat.activeSessionID?.uuidString)
        #expect(snapshot.turnID == 0)
        #expect(!snapshot.taskID.isEmpty)
        #expect(!snapshot.messageID.isEmpty)
        #expect(snapshot.policyRevision == "wp2b-revision")
        #expect(snapshot.grantEpoch == "wp2b-epoch")
        #expect(snapshot.inputDigest == ComposerToolInput(values: [
            "content": .string("建节点 测试输入"),
            "attachments": .array([])
        ]).digest)
        #expect(chat.messages.last?.id.uuidString == snapshot.messageID)
    }
}

private final class ScheduledMemoryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let heartbeat = DispatchSemaphore(value: 0)
    private var firstRead = true
    private(set) var heartbeatBeforeRelease = false
    private(set) var readEntered = false

    func beforeFactsRead() {
        lock.lock()
        let shouldWait = firstRead
        firstRead = false
        if shouldWait { readEntered = true }
        lock.unlock()
        guard shouldWait else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func observeMainActorWhileReadIsHeld() {
        DispatchQueue.global().async { [self] in
            guard entered.wait(timeout: .now() + 5) == .success else { return }
            Task { @MainActor in self.heartbeat.signal() }
            let observed = heartbeat.wait(timeout: .now() + 2) == .success
            lock.lock()
            heartbeatBeforeRelease = observed
            lock.unlock()
            release.signal()
        }
    }

    func result() -> (entered: Bool, responsive: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (readEntered, heartbeatBeforeRelease)
    }
}

final class ScheduledBoundaryProvider: LLMProvider, @unchecked Sendable {
    static let summaryConstraint = "Compare repair options without changing the title or violating the read-only constraint."
    let name = "ScheduledFixture"
    var model = LLMModel(id: "scheduled-fixture", displayName: "Scheduled fixture", provider: "ScheduledFixture")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    private let mutex = NSLock()
    private var pending: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation?
    private var calls = 0
    private var history: [LLMMessage] = []
    private var prompt: String?
    private var summaryRequests: [[LLMMessage]] = []
    func callCount() -> Int { mutex.lock(); defer { mutex.unlock() }; return calls }
    func received() -> [LLMMessage] { mutex.lock(); defer { mutex.unlock() }; return history }
    func receivedPrompt() -> String? { mutex.lock(); defer { mutex.unlock() }; return prompt }
    func receivedSummaries() -> [[LLMMessage]] { mutex.withLock { summaryRequests } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        mutex.withLock { summaryRequests.append(messages) }
        return LLMResponse(text: Self.summaryConstraint, stopReason: "end_turn", usage: LLMUsage(inputTokens: 1, outputTokens: 1))
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            mutex.lock(); calls += 1; history = messages; prompt = systemPrompt; pending = continuation; mutex.unlock()
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
final class ScheduledTargetFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let persistence: SessionStore
    let targetID = UUID()
    let activeID = UUID()
    let projectID = "scheduled-project"
    let chat: ChatStore
    let ledger: SchedulerTaskStore
    let provider = ScheduledBoundaryProvider()
    var taskID: UUID!
    let original: [LLMMessage]
    var date = Date()
    var runtime: SchedulerTaskRuntime!
    var targetQueryCount = 0
    var effectSubmissionCount = 0
    private(set) var lastSubmissionError: (any Error)?

    init(command: String = "scheduled prompt", compactableHistory: Bool = false,
         projectChildTarget: Bool = false) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("scheduled-target-\(UUID().uuidString)")
        let suiteName = "scheduled-target-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        root = rootURL
        suite = suiteName
        defaults = preferences
        persistence = SessionStore(directory: rootURL.appendingPathComponent("sessions-root"))
        if projectChildTarget {
            original = [LLMMessage(role: .user, content: command)]
        } else if compactableHistory {
            // Distinct assistant observations exercise natural compaction;
            // the older constraints enter the lossy summary and the tail stays exact.
            original = [LLMMessage(role: .user, content: "Goal: compare repairs; keep the title and read-only constraint.")] +
                (0..<8).flatMap { option in [
                    LLMMessage(role: .assistant, content: (0..<20).map { detail in
                        "Option \(option), observation \(detail): cost \(option * 11 + detail), dependency \(detail % 7), and fallback \(option + detail + 2) require comparison."
                    }.joined(separator: " ")),
                    LLMMessage(role: .user, content: "For option \(option), retain dependency \(option + 4)."),
                ] } + [
                    LLMMessage(role: .assistant, content: "Current answer"),
                    LLMMessage(role: .user, content: "Continue in this session"),
                ]
        } else {
            original = (0..<6).map { LLMMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "source-\($0)") }
        }
        chat = ChatStore(preferencesDefaults: preferences, logManager: LogManager(directory: rootURL.appendingPathComponent("logs"), ringCapacity: 20))
        ledger = SchedulerTaskStore(defaults: preferences, occurrenceLedgerURL: rootURL.appendingPathComponent("occurrences.json"))
        _ = try persistence.createSession(id: targetID.uuidString, title: "target", projectID: projectID)
        _ = try persistence.createSession(id: activeID.uuidString, title: "untouched", projectID: "other-project")
        for message in original { try persistence.saveMessage(message, sessionID: targetID.uuidString) }
        #expect(chat.attachPersistence(persistence))
        #expect(chat.applySwitchSession(id: activeID))
        chat.draftText = "untouched active draft"
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "scheduled-policy", grantEpoch: "scheduled-epoch",
            leaseID: "scheduled-lease", expiresAt: date.addingTimeInterval(3600),
            autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        chat.compactionProviderOverride = provider
        #expect(ledger.add(name: "bound", cronExpression: "* * * * *", command: command,
            targetSessionID: targetID, targetProjectID: projectID, targetTurnID: 1) == nil)
        taskID = try #require(ledger.allTasks().first?.id)
        var preview = try #require(ledger.preview(taskID: taskID, now: date))
        let digest = try #require(chat.schedulerSourceAnchorDigest(sessionID: targetID, projectID: projectID, ordinal: 1))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = facts.revision
        #expect(ledger.confirmPreview(preview, actorID: "test-user", scopeID: projectID, policyRevision: facts.revision,
            now: date, sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest, currentPolicyRevision: facts.revision))
        runtime = makeRuntime(ledger)
    }
    func makeRuntime(_ store: SchedulerTaskStore) -> SchedulerTaskRuntime {
        SchedulerTaskRuntime(store: store, now: { [weak self] in self?.date ?? Date() },
            sourceAnchorResolver: { [weak self] session, project, ordinal in
                self?.chat.schedulerSourceAnchorDigest(sessionID: session, projectID: project, ordinal: ordinal)
            }, policyRevisionResolver: { [weak self] in self?.chat.schedulerPolicyRevision() },
            targetDeliveryResolver: { [weak self] occurrence in
                guard let self else { return nil }
                self.targetQueryCount += 1
                return self.chat.scheduledTargetDelivery(for: occurrence)
            },
            submitEffect: { [weak self] context in
                guard let self else { throw CancellationError() }
                self.effectSubmissionCount += 1
                self.lastSubmissionError = nil
                do { return try await self.chat.submitScheduledRequest(context) }
                catch { self.lastSubmissionError = error; throw error }
            })
    }
    /// Capture the actual running producer ledger before its final report.
    /// The independent observation uses the normal terminal-recording API;
    /// the original ChatStore producer alone creates the canonical delivery.
    func terminalObservation(status: SchedulerDeliveryReceipt.Status) throws -> (SchedulerTaskStore, URL) {
        let running = try #require(ledger.latestOccurrence(for: taskID))
        #expect(running.state == .running)
        let owner = try #require(running.leaseOwner)
        let token = try #require(running.leaseToken)
        let url = root.appendingPathComponent("observed-\(UUID().uuidString).json")
        try Data(contentsOf: root.appendingPathComponent("occurrences.json")).write(to: url)
        let observation = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: url)
        #expect(observation.persistenceError == nil)
        #expect(observation.recordDelivery(id: running.id, owner: owner, token: token,
            status: status, detail: "独立终态报告", now: date,
            expectedTaskVersion: running.taskVersion, expectedControlRevision: running.controlRevision,
            executionTurnID: running.executionTurnID, executionMessageID: running.executionMessageID))
        return (observation, url)
    }
    func waitForProvider(count: Int = 1) async throws {
        for _ in 0..<300 {
            if provider.callCount() >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ScheduledTargetFixture.provider", code: 1)
    }
    func waitForTerminal() async throws -> SchedulerOccurrence {
        for _ in 0..<300 {
            if let occurrence = ledger.latestOccurrence(for: taskID), occurrence.state.isTerminal { return occurrence }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ScheduledTargetFixture.terminal", code: 1)
    }
    func cleanup() {
        runtime.stop()
        provider.finish()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

extension WP2BComposerSubmissionBoundaryTests {
    @Test func projectChildMemoryReadDoesNotBlockMainActor() async throws {
        let instruction = "project memory prompt"
        let f = try ScheduledTargetFixture(command: instruction, projectChildTarget: true)
        defer { f.cleanup() }
        // Production App bootstrap resolves the persisted speed tier before
        // admitting a project child; the bare fixture starts with no model.
        f.chat.restoreSpeedTier(.fast)
        let memoryDirectory = f.root.appendingPathComponent("memory-root", isDirectory: true)
        try MemoryStore(directory: memoryDirectory).addFact(
            "project memory is a synthetic scoped fact",
            sourceSessionID: f.targetID.uuidString,
            memoryScope: MemoryScope(sessionID: f.targetID.uuidString, projectID: f.projectID)
        )
        let gate = ScheduledMemoryReadGate()
        f.chat.memoryEnabledProvider = { true }
        f.chat.memoryInjector = MemoryInjector(store: MemoryStore(
            directory: memoryDirectory,
            lifecycleTransactionFaultInjector: nil,
            beforeFactsReadForTesting: { gate.beforeFactsRead() }
        ))
        let taskStore = AgentTaskStore()
        let taskID = "project-memory-task"
        let runID = "project-memory-run"
        _ = try taskStore.enqueue(taskID: taskID, parentID: "project-memory-parent",
            providerID: nil, modelID: nil)
        _ = try taskStore.startRun(taskID: taskID, runID: runID)
        gate.observeMainActorWhileReadIsHeld()

        let target = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
        #expect(target.projectID == f.projectID)
        #expect(target.messages.count == 1)
        #expect(target.messages.first?.role == .user)
        #expect(target.messages.first?.content == instruction)
        #expect(f.chat.sessions.contains(where: { $0.id == f.targetID && $0.projectID == f.projectID }))
        let preflight = f.chat.schedulerProviderPreflight(
            for: try #require(f.ledger.allTasks().first)
        )
        #expect(preflight.isReadyForExecution, "\(preflight.status): \(preflight.detail)")

        let started = f.chat.startProjectTask(
            targetID: f.targetID.uuidString, projectID: f.projectID,
            instruction: instruction, runID: runID, taskStore: taskStore,
            authorization: { true }, onFinished: {}
        )
        #expect(started)
        for _ in 0..<300 {
            if f.provider.callCount() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let observation = gate.result()
        #expect(observation.entered)
        #expect(observation.responsive)
        #expect(f.provider.receivedPrompt()?.contains("synthetic scoped fact") == true)
    }

    @Test func scheduledMemoryReadDoesNotBlockMainActor() async throws {
        let f = try ScheduledTargetFixture(command: "scheduled memory prompt")
        defer { f.cleanup() }
        let memoryDirectory = f.root.appendingPathComponent("memory-root", isDirectory: true)
        let seedingStore = MemoryStore(directory: memoryDirectory)
        try seedingStore.addFact(
            "scheduled memory is a synthetic scoped fact",
            sourceSessionID: f.targetID.uuidString,
            memoryScope: MemoryScope(sessionID: f.targetID.uuidString, projectID: f.projectID)
        )
        let gate = ScheduledMemoryReadGate()
        let observedStore = MemoryStore(
            directory: memoryDirectory,
            lifecycleTransactionFaultInjector: nil,
            beforeFactsReadForTesting: { gate.beforeFactsRead() }
        )
        f.chat.memoryEnabledProvider = { true }
        f.chat.memoryInjector = MemoryInjector(store: observedStore)
        gate.observeMainActorWhileReadIsHeld()

        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider()
        let observation = gate.result()
        #expect(observation.entered)
        #expect(observation.responsive, "the production memory read must leave MainActor runnable")
        #expect(f.provider.receivedPrompt()?.contains("synthetic scoped fact") == true)
    }

    @Test func scheduledPromptUsesPinnedPersistentTargetAndIndependentRepeatedExecution() async throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider()
        #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        #expect(f.provider.received().last?.content == "scheduled prompt")
        f.provider.finish()
        let first = try await f.waitForTerminal()
        #expect(first.state == .succeeded)
        #expect(first.submissionReceipt?.request.targetTurnID == 1)
        #expect(first.submissionReceipt?.executionTurnID != 1)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
        #expect(f.persistence.loadSession(id: f.activeID.uuidString)?.messages.isEmpty == true)
        #expect(SessionStore(directory: f.persistence.directory).loadSession(id: f.targetID.uuidString)?.messages.last?.content == "scheduled result")
        let firstTargetFact = try #require(f.chat.scheduledTargetDelivery(for: first))
        #expect(firstTargetFact.occurrenceID == first.id)
        #expect(firstTargetFact.effectID == first.effectID)
        #expect(firstTargetFact.executionTurnID == first.executionTurnID)
        #expect(firstTargetFact.executionMessageID == first.executionMessageID)
        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: f.root.appendingPathComponent("occurrences.json"))
        let secondRuntime = f.makeRuntime(reopened)
        defer { secondRuntime.stop() }
        secondRuntime.pollNow(at: f.date)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.provider.callCount() == 1)
        f.date = f.date.addingTimeInterval(60)
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider(count: 2)
        f.provider.finish()
        let second = try await f.waitForTerminal()
        #expect(second.state == .succeeded)
        #expect(second.effectID != first.effectID)
        #expect(second.executionTurnID != first.executionTurnID)
        #expect(second.submissionReceipt?.request.targetTurnID == 1)
        let secondTargetFact = try #require(f.chat.scheduledTargetDelivery(for: second))
        #expect(secondTargetFact.occurrenceID == second.id)
        #expect(secondTargetFact.effectID == second.effectID)
    }

    /// D-SCHEDB: two live producers share the production actor and durable
    /// ledger. The provider remains suspended until both poll tasks finish;
    /// the receipt and transcript fact are written only by ChatStore.
    @Test func concurrentProducersDeliverOneCanonicalOccurrenceAcrossReopen() async throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        let competitor = f.makeRuntime(f.ledger)
        defer { competitor.stop() }
        let activeBefore = try #require(f.persistence.loadSession(id: f.activeID.uuidString))

        let firstProducer = Task { @MainActor in
            await Task.yield()
            f.runtime.pollNow(at: f.date)
            try await f.waitForProvider()
            let running = try #require(f.ledger.latestOccurrence(for: f.taskID))
            #expect(running.state == .running)
            return running.id
        }
        let secondProducer = Task { @MainActor in
            await Task.yield()
            competitor.pollNow(at: f.date)
            try await f.waitForProvider()
            let running = try #require(f.ledger.latestOccurrence(for: f.taskID))
            #expect(running.state == .running)
            return running.id
        }
        let producerRows = [try await firstProducer.value, try await secondProducer.value]
        #expect(producerRows.count == 2, "两个真实 producer task 均已起跑并完成 poll")
        let running = try #require(f.ledger.latestOccurrence(for: f.taskID))
        #expect(producerRows == [running.id, running.id])
        #expect(f.ledger.occurrences.count == 1)
        #expect(f.provider.callCount() == 1)
        #expect(f.provider.received().last?.content == "scheduled prompt")
        let targetWhileRunning = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
        #expect(targetWhileRunning.messages == f.original)
        #expect(targetWhileRunning.scheduledTranscriptDeliveries.isEmpty)
        #expect(running.submissionReceipt == nil)
        let identity = try #require(f.ledger.executionIdentity(id: running.id))
        let owner = try #require(running.leaseOwner)
        let token = try #require(running.leaseToken)

        f.provider.finish()
        let done = try await f.waitForTerminal()
        #expect(done.id == running.id && done.state == .succeeded)
        #expect(done.retryOfOccurrenceID == nil)
        #expect(f.ledger.executionIdentity(id: done.id) == identity)
        let receipt = try #require(done.submissionReceipt)
        #expect(receipt.status == .delivered)
        #expect(receipt.request.occurrenceID == identity.occurrenceID)
        #expect(receipt.request.taskID == identity.taskID)
        #expect(receipt.request.taskVersion == identity.taskVersion)
        #expect(receipt.request.effectID == identity.effectID)
        #expect(receipt.request.idempotencyKey == identity.idempotencyKey)
        #expect(receipt.request.sourceTaskID == f.taskID)
        #expect(receipt.request.targetSessionID == f.targetID)
        #expect(receipt.request.targetProjectID == f.projectID)
        #expect(receipt.request.targetTurnID == 1)
        #expect(receipt.request.command == "scheduled prompt")
        #expect(receipt.executionTurnID == done.executionTurnID)
        #expect(receipt.executionMessageID == done.executionMessageID)
        let persistedTarget = try #require(SessionStore(directory: f.persistence.directory)
            .loadSession(id: f.targetID.uuidString))
        #expect(persistedTarget.messages == f.original + [
            LLMMessage(role: .user, content: "scheduled prompt"),
            LLMMessage(role: .assistant, content: "scheduled result"),
        ])
        #expect(persistedTarget.scheduledTranscriptDeliveries.count == 1)
        let fact = try #require(persistedTarget.scheduledTranscriptDeliveries.first)
        #expect(fact == f.chat.scheduledTargetDelivery(for: done))
        #expect(fact.occurrenceID == identity.occurrenceID && fact.effectID == identity.effectID)
        #expect(fact.taskID == identity.taskID && fact.taskVersion == identity.taskVersion)
        #expect(fact.executionTurnID == done.executionTurnID)
        #expect(fact.executionMessageID == done.executionMessageID)
        #expect(f.ledger.occurrences == [done])
        let journal = f.ledger.occurrenceJournal
        #expect(Set(journal.map(\.occurrenceID)) == [done.id])
        #expect(Set(journal.map(\.effectID)) == [identity.effectID])
        #expect(journal.filter { $0.state == .succeeded }.count == 1)
        #expect(journal.last?.state == .succeeded)

        let ledgerURL = f.root.appendingPathComponent("occurrences.json")
        let durableBefore = try Data(contentsOf: ledgerURL)
        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: ledgerURL)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrences == [done])
        #expect(reopened.occurrenceJournal == journal)
        #expect(reopened.executionIdentity(id: done.id) == identity)
        let restart = f.makeRuntime(reopened)
        defer { restart.stop() }
        restart.pollNow(at: f.date)
        competitor.pollNow(at: f.date)
        #expect(!restart.reconcileUnknownOccurrence(id: done.id, now: f.date))
        #expect(!reopened.recordDelivery(id: done.id, owner: owner, token: token,
            status: .delivered, now: f.date, expectedTaskVersion: done.taskVersion,
            expectedControlRevision: done.controlRevision,
            executionTurnID: done.executionTurnID, executionMessageID: done.executionMessageID))
        for _ in 0..<10 { await Task.yield() }
        #expect(f.provider.callCount() == 1)
        #expect(reopened.occurrences == [done])
        #expect(reopened.occurrenceJournal == journal)
        #expect(try Data(contentsOf: ledgerURL) == durableBefore)
        let targetAfterReplay = try #require(SessionStore(directory: f.persistence.directory)
            .loadSession(id: f.targetID.uuidString))
        #expect(targetAfterReplay.messages == persistedTarget.messages)
        #expect(targetAfterReplay.transcriptRevision == persistedTarget.transcriptRevision)
        #expect(targetAfterReplay.scheduledTranscriptDeliveries == [fact])
        let activeAfter = try #require(f.persistence.loadSession(id: f.activeID.uuidString))
        #expect(activeAfter.messages == activeBefore.messages)
        #expect(activeAfter.transcriptRevision == activeBefore.transcriptRevision)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
    }

    @Test func scheduledCancellationRejectsLateProviderOutputWithoutTouchingActiveDraft() async throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider()
        let row = try #require(f.ledger.latestOccurrence(for: f.taskID))
        #expect(f.runtime.cancelOccurrence(id: row.id, expectedTaskVersion: row.taskVersion,
            expectedControlRevision: row.controlRevision, owner: row.leaseOwner, token: row.leaseToken, now: f.date))
        f.provider.finish()
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .cancelled)
        #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
    }

    @Test func scheduledAnchorEditAndArchiveDoNotAcceptLateResults() async throws {
        for archive in [false, true] {
            let f = try ScheduledTargetFixture()
            defer { f.cleanup() }
            f.runtime.pollNow(at: f.date)
            try await f.waitForProvider()
            if archive {
                try SessionManager(store: f.persistence, badgeStore: SessionBadgeStore(directory: f.root.appendingPathComponent("badges")))
                    .archive(sessionID: f.targetID.uuidString)
            } else {
                var changed = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
                changed.messages = [LLMMessage(role: .user, content: "changed anchor")]
                changed.transcriptRevision += 1
                try SessionStore(directory: f.persistence.directory).updateSession(changed)
            }
            f.provider.finish()
            let terminal = try await f.waitForTerminal()
            #expect(terminal.state != .succeeded)
            if archive { #expect(f.persistence.loadSession(id: f.targetID.uuidString) == nil) }
            else { #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages.first?.content == "changed anchor") }
            #expect(f.chat.activeSessionID == f.activeID)
        }
    }

    @Test func scheduledRevocationAndProjectChangeDoNotRelabelACompletedEffect() async throws {
        for revoke in [true, false] {
            let f = try ScheduledTargetFixture()
            defer { f.cleanup() }
            f.runtime.pollNow(at: f.date)
            try await f.waitForProvider()
            if revoke { #expect(f.ledger.revokeAuthorization(f.taskID)) }
            else {
                var changed = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
                changed.projectID = "different-project"
                try f.persistence.updateSession(changed)
            }
            f.provider.finish()
            let terminal = try await f.waitForTerminal()
            #expect(terminal.state != .succeeded)
            #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
            #expect(f.chat.draftText == "untouched active draft")
        }
    }

    @Test func scheduledCompactUsesTheRealCheckpointConsumerAndSameSettingsRuntime() async throws {
        let f = try ScheduledTargetFixture(command: "/compact", compactableHistory: true)
        defer { f.cleanup() }
        var observed: ComposerSubmissionSnapshot?
        f.chat.onComposerCommandPolicy = { _, snapshot in observed = snapshot; return .execute }
        let view = try #require(SchedulerSettingsTab(store: f.ledger, runtime: f.runtime).body as? SchedulerControlSettingsView)
        #expect(view.store === f.ledger)
        #expect(view.runtime === f.runtime)
        f.runtime.pollNow(at: f.date)
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .succeeded)
        #expect(observed?.sessionID == f.targetID.uuidString)
        #expect(observed?.turnID == terminal.executionTurnID)
        let checkpoint = try #require(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        let modelView = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.persistence,
            sessionID: f.targetID.uuidString)
        #expect(modelView == checkpoint.replacementHistory)
        #expect(Compactor.hasMaterialRequestReduction(from: f.original, to: modelView))
        let summaries = f.provider.receivedSummaries()
        try #require(summaries.count == 1 && summaries[0].count == 1)
        let summaryInput = summaries[0][0]
        #expect(summaryInput.role == .user && summaryInput.content.contains("===== 对话记录 ====="))
        #expect(summaryInput.content.contains("Goal: compare repairs; keep the title and read-only constraint."))
        #expect(summaryInput.content.contains("For option 0, retain dependency 4."))
        let recent = Array(f.original.suffix(3))
        for message in recent {
            #expect(!summaryInput.content.contains(message.content))
        }
        let summaryMessage = try #require(modelView.first)
        #expect(summaryMessage.role == .user && summaryMessage.content.hasPrefix("<context-summary>"))
        #expect(summaryMessage.content.contains(ScheduledBoundaryProvider.summaryConstraint))
        #expect(Array(modelView.suffix(3)) == recent)
        #expect(f.provider.callCount() == 0) // compaction never starts a chat stream
        #expect(try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: SessionStore(directory: f.root.appendingPathComponent("sessions-root")),
            sessionID: f.targetID.uuidString) == modelView)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
        #expect(f.persistence.loadSession(id: f.activeID.uuidString)?.messages.isEmpty == true)
    }

    @Test func scheduledShortCompactCannotAttestSuccessWithoutCheckpoint() async throws {
        let f = try ScheduledTargetFixture(command: "/compact")
        defer { f.cleanup() }
        f.chat.onComposerCommandPolicy = { _, _ in .execute }
        f.runtime.pollNow(at: f.date)
        let terminal = try await f.waitForTerminal()
        #expect(terminal.state == .failed)
        #expect(try f.persistence.loadLatestCompactionCheckpoint(sessionID: f.targetID.uuidString) == nil)
        #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        #expect(f.provider.callCount() == 0)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
    }

    @Test func failedTargetQueryPreservesTerminalBytesAcrossObservedDeliveryAndReopen() async throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider()
        let (observation, url) = try f.terminalObservation(status: .failed)
        let failed = try #require(observation.latestOccurrence(for: f.taskID))
        let originalBytes = try Data(contentsOf: url)
        let journal = observation.occurrenceJournal
        let reader = f.makeRuntime(observation)
        defer { reader.stop() }
        let submissions = f.effectSubmissionCount
        let queries = f.targetQueryCount
        #expect(reader.queryTargetDelivery(id: failed.id) == .noMatchingFact(occurrence: failed))
        #expect(f.targetQueryCount == queries + 1, "failed 必须到达真实注册的 ChatStore reader")
        #expect(try Data(contentsOf: url) == originalBytes)

        // No success fact is manufactured: the original scheduled ChatStore
        // turn completes and commits its transcript and delivery together.
        f.provider.finish()
        let delivered = try await f.waitForTerminal()
        #expect(delivered.id == failed.id && delivered.state == .succeeded)
        let fact = try #require(f.chat.scheduledTargetDelivery(for: failed))
        let target = try #require(SessionStore(directory: f.persistence.directory)
            .loadSession(id: f.targetID.uuidString))
        #expect(target.scheduledTranscriptDeliveries == [fact])
        #expect(target.messages == f.original + [LLMMessage(role: .user, content: "scheduled prompt"),
                                                LLMMessage(role: .assistant, content: "scheduled result")])
        #expect(reader.queryTargetDelivery(id: failed.id)
            == .deliveryConflictsWithFailure(occurrence: failed, targetFact: fact))
        #expect(!reader.reconcileUnknownOccurrence(id: failed.id, now: f.date))
        #expect(!observation.reconcileDeliveredOccurrence(id: failed.id, targetFact: fact, now: f.date))
        #expect(reader.retryReconciledOccurrence(id: failed.id,
            expectedControlRevision: failed.controlRevision, proofToken: "no authority", now: f.date) == nil)
        #expect(observation.occurrences == [failed])
        #expect(observation.occurrenceJournal == journal)
        #expect(try Data(contentsOf: url) == originalBytes)

        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: url)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrences == [failed])
        #expect(reopened.occurrenceJournal == journal)
        let reopenedReader = f.makeRuntime(reopened)
        defer { reopenedReader.stop() }
        #expect(reopenedReader.queryTargetDelivery(id: failed.id)
            == .deliveryConflictsWithFailure(occurrence: failed, targetFact: fact))
        reopenedReader.pollNow(at: f.date)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.effectSubmissionCount == submissions)
        #expect(f.provider.callCount() == 1)
        #expect(reopened.occurrences == [failed])
        #expect(reopened.occurrenceJournal == journal)
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test func failedTargetQueryRejectsOtherCanonicalIdentityWithoutNewExecution() async throws {
        let f = try ScheduledTargetFixture(command: "/compact")
        defer { f.cleanup() }
        f.chat.onComposerCommandPolicy = { _, _ in .execute }
        f.runtime.pollNow(at: f.date)
        let failed = try await f.waitForTerminal()
        #expect(failed.state == .failed)
        let ledgerURL = f.root.appendingPathComponent("occurrences.json")
        let failedBytes = try Data(contentsOf: ledgerURL)
        let journal = f.ledger.occurrenceJournal
        let submissions = f.effectSubmissionCount
        let queries = f.targetQueryCount
        #expect(f.runtime.queryTargetDelivery(id: failed.id) == .noMatchingFact(occurrence: failed))
        #expect(f.targetQueryCount == queries + 1)

        // Create a different legitimate scheduled occurrence in the same
        // target. Its actual ChatStore fact must not close this failed one.
        let otherSuite = "\(f.suite)-other-producer"
        let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let otherLedger = SchedulerTaskStore(defaults: otherDefaults,
            occurrenceLedgerURL: f.root.appendingPathComponent("other-occurrences.json"))
        #expect(otherLedger.add(name: "other", cronExpression: "* * * * *", command: "scheduled prompt",
            targetSessionID: f.targetID, targetProjectID: f.projectID, targetTurnID: 1) == nil)
        let otherTaskID = try #require(otherLedger.allTasks().first?.id)
        var preview = try #require(otherLedger.preview(taskID: otherTaskID, now: f.date))
        let digest = try #require(f.chat.schedulerSourceAnchorDigest(sessionID: f.targetID,
            projectID: f.projectID, ordinal: 1))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = f.chat.schedulerPolicyRevision()
        #expect(otherLedger.confirmPreview(preview, actorID: "test-user", scopeID: f.projectID,
            policyRevision: "scheduled-policy", now: f.date, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "scheduled-policy"))
        let producer = f.makeRuntime(otherLedger)
        defer { producer.stop() }
        producer.pollNow(at: f.date)
        try await f.waitForProvider()
        f.provider.finish()
        var other: SchedulerOccurrence?
        for _ in 0..<300 {
            if let row = otherLedger.latestOccurrence(for: otherTaskID), row.state.isTerminal {
                other = row
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let delivered = try #require(other)
        #expect(delivered.state == .succeeded)
        let fact = try #require(f.chat.scheduledTargetDelivery(for: delivered))
        #expect(fact.occurrenceID != failed.id && fact.taskID != failed.taskID)
        #expect(f.chat.scheduledTargetDelivery(for: failed) == nil)
        #expect(f.runtime.queryTargetDelivery(id: failed.id) == .noMatchingFact(occurrence: failed))

        // Defense in depth for a miswired adapter uses the real other fact,
        // never a synthetic delivery or Boolean success handler.
        let miswired = SchedulerTaskRuntime(store: f.ledger,
            targetDeliveryResolver: { _ in fact }, submitEffect: { _ in throw CancellationError() })
        #expect(miswired.queryTargetDelivery(id: failed.id)
            == .identityConflict(occurrence: failed, targetFact: fact))
        #expect(!miswired.reconcileUnknownOccurrence(id: failed.id, now: f.date))
        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: ledgerURL)
        let reader = f.makeRuntime(reopened)
        defer { reader.stop() }
        let submissionsAfterProducer = f.effectSubmissionCount
        let providersAfterProducer = f.provider.callCount()
        #expect(submissionsAfterProducer == submissions + 1)
        #expect(providersAfterProducer == 1)
        #expect(reader.queryTargetDelivery(id: failed.id) == .noMatchingFact(occurrence: failed))
        reader.pollNow(at: f.date)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.effectSubmissionCount == submissionsAfterProducer)
        #expect(f.provider.callCount() == providersAfterProducer)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrences == [failed])
        #expect(reopened.occurrenceJournal == journal)
        #expect(try Data(contentsOf: ledgerURL) == failedBytes)
    }

    @Test func unknownTargetObservationRetainsIdentityFencesAndExplicitConvergence() async throws {
        let f = try ScheduledTargetFixture()
        defer { f.cleanup() }
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider()
        f.provider.finish()
        let first = try await f.waitForTerminal()
        #expect(first.state == .succeeded)
        let wrongFact = try #require(f.chat.scheduledTargetDelivery(for: first))

        f.date = f.date.addingTimeInterval(60)
        f.runtime.pollNow(at: f.date)
        try await f.waitForProvider(count: 2)
        let (observation, url) = try f.terminalObservation(status: .unknown)
        let unknown = try #require(observation.latestOccurrence(for: f.taskID))
        #expect(unknown.id != first.id && unknown.state == .unknown)
        let bytes = try Data(contentsOf: url)
        let journal = observation.occurrenceJournal
        let submissions = f.effectSubmissionCount
        let reader = f.makeRuntime(observation)
        defer { reader.stop() }
        #expect(reader.queryTargetDelivery(id: unknown.id) == .noMatchingFact(occurrence: unknown))
        #expect(!reader.reconcileUnknownOccurrence(id: unknown.id, now: f.date))
        let miswired = SchedulerTaskRuntime(store: observation,
            targetDeliveryResolver: { _ in wrongFact }, submitEffect: { _ in throw CancellationError() })
        #expect(miswired.queryTargetDelivery(id: unknown.id)
            == .identityConflict(occurrence: unknown, targetFact: wrongFact))
        #expect(!miswired.reconcileUnknownOccurrence(id: unknown.id, now: f.date))
        #expect(observation.occurrenceJournal == journal)
        #expect(try Data(contentsOf: url) == bytes)

        f.provider.finish()
        let second = try await f.waitForTerminal()
        #expect(second.id == unknown.id && second.state == .succeeded)
        let fact = try #require(f.chat.scheduledTargetDelivery(for: unknown))
        #expect(reader.queryTargetDelivery(id: unknown.id)
            == .deliveryObserved(occurrence: unknown, targetFact: fact))
        #expect(observation.occurrence(id: unknown.id) == unknown)
        #expect(observation.occurrenceJournal == journal)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(reader.reconcileUnknownOccurrence(id: unknown.id, now: f.date))
        #expect(reader.retryReconciledOccurrence(id: unknown.id,
            expectedControlRevision: unknown.controlRevision, proofToken: "arbitrary", now: f.date) == nil)
        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: url)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrence(id: unknown.id)?.state == .succeeded)
        #expect(reopened.occurrence(id: unknown.id)?.submissionReceipt?.status == .delivered)
        #expect(reopened.occurrences.count == 2)
        #expect(f.effectSubmissionCount == submissions)
        #expect(f.provider.callCount() == 2)
    }

}


extension WP2BComposerSubmissionBoundaryTests {
    @Test("queued v1 reaches its approved persistent target after a separately approved v2 edit",
          arguments: ["unchanged", "anchorChanged", "revoked", "policyChanged", "expired"])
    func queuedV1UsesFrozenSourceBindingAcrossApprovedV2Edit2258(change: String) async throws {
        let f = try ScheduledTargetFixture(command: "old pinned request")
        defer { f.cleanup() }
        let oldTask = try #require(f.ledger.task(id: f.taskID))
        let oldAnchor = try #require(f.chat.schedulerSourceAnchorDigest(
            sessionID: f.targetID, projectID: f.projectID, ordinal: 1))
        #expect(oldTask.sourceAnchorDigest == oldAnchor)
        let queued = try #require(f.ledger.reserveOccurrence(taskID: f.taskID, at: f.date))
        let newProject = "new-approved-project"
        let newID = f.chat.applyNewSession(title: "new target", projectID: newProject)
        let newHistory = (0..<6).map {
            LLMMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "new-target-\($0)")
        }
        #expect(f.persistence.loadSession(id: newID.uuidString) != nil)
        for message in newHistory { try f.persistence.saveMessage(message, sessionID: newID.uuidString) }
        let newCanonical = try #require(f.persistence.loadSession(id: newID.uuidString))
        #expect(f.chat.adoptScheduledCanonicalSession(newCanonical))
        #expect(f.chat.applySwitchSession(id: f.activeID))
        f.chat.draftText = "untouched active draft"
        var edited = oldTask
        edited.command = "new approved request"
        edited.targetSessionID = newID
        edited.targetProjectID = newProject
        edited.targetTurnID = 3
        #expect(f.ledger.update(edited, expectedVersion: oldTask.version) == nil)
        let newAnchor = try #require(f.chat.schedulerSourceAnchorDigest(
            sessionID: newID, projectID: newProject, ordinal: 3))
        #expect(newAnchor != oldAnchor)
        var preview = try #require(f.ledger.preview(taskID: f.taskID, now: f.date))
        preview.observedSourceAnchorDigest = newAnchor
        preview.observedPolicyRevision = "scheduled-policy"
        #expect(f.ledger.confirmPreview(preview, actorID: "new-target-user", scopeID: newProject,
            policyRevision: "scheduled-policy", now: f.date, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: newAnchor, currentPolicyRevision: "scheduled-policy"))
        let newTask = try #require(f.ledger.task(id: f.taskID))
        #expect(newTask.version > oldTask.version)
        #expect(newTask.authorizationVersion > queued.authorizationVersion)
        #expect(newTask.sourceAnchorDigest == newAnchor)
        #expect(queued.authorizationScopeID == f.projectID)
        #expect(queued.authorizationPolicyRevision == "scheduled-policy")
        let reopened = SchedulerTaskStore(defaults: f.defaults,
            occurrenceLedgerURL: f.root.appendingPathComponent("occurrences.json"))
        #expect(reopened.persistenceError == nil)
        #expect(reopened.isOccurrenceAuthorized(queued, now: f.date))
        if change == "anchorChanged" {
            var changed = try #require(f.persistence.loadSession(id: f.targetID.uuidString))
            changed.messages = [LLMMessage(role: .user, content: "changed old source")]
            changed.transcriptRevision += 1
            try f.persistence.updateSession(changed)
        } else if change == "revoked" {
            #expect(reopened.revokeAuthorization(f.taskID))
        } else if change == "policyChanged" || change == "expired" {
            f.chat.configureComposerPolicy(ComposerPolicyFactSource(
                knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
                workspaceID: f.chat.composerWorkspaceID,
                revision: change == "expired" ? "scheduled-policy" : "different-live-policy",
                grantEpoch: "different-epoch", leaseID: "different-lease",
                expiresAt: f.date.addingTimeInterval(change == "expired" ? -1 : 3600), autonomyCeiling: .l1))
        }
        let runtime = f.makeRuntime(reopened)
        defer { runtime.stop() }
        runtime.pollNow(at: f.date)
        for _ in 0..<300 {
            if f.provider.callCount() > 0 || reopened.occurrence(id: queued.id)?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(f.provider.callCount() == (change == "unchanged" ? 1 : 0))
        if change != "unchanged" {
            #expect(reopened.occurrence(id: queued.id)?.state != .succeeded)
            #expect(f.persistence.loadSession(id: newID.uuidString)?.messages == newHistory)
            return
        }
        let oldProviderHistory = f.provider.received()
        #expect(oldProviderHistory == f.original + [LLMMessage(role: .user, content: "old pinned request")])
        f.provider.finish()
        for _ in 0..<300 {
            if reopened.occurrence(id: queued.id)?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let oldDone = try #require(reopened.occurrence(id: queued.id))
        #expect(oldDone.state == .succeeded)
        let receipt = try #require(oldDone.submissionReceipt)
        #expect(receipt.request.taskVersion == oldTask.version)
        #expect(receipt.request.targetSessionID == f.targetID)
        #expect(receipt.request.targetProjectID == f.projectID)
        #expect(receipt.request.targetTurnID == 1)
        #expect(f.chat.scheduledTargetDelivery(for: oldDone)?.occurrenceID == queued.id)
        #expect(f.persistence.loadSession(id: newID.uuidString)?.messages == newHistory)
        f.date = f.date.addingTimeInterval(60)
        runtime.pollNow(at: f.date)
        try await f.waitForProvider(count: 2)
        #expect(f.provider.received() == newHistory + [LLMMessage(role: .user, content: "new approved request")])
        f.provider.finish()
        let newOccurrence = try #require(reopened.latestOccurrence(for: f.taskID))
        for _ in 0..<300 {
            if reopened.occurrence(id: newOccurrence.id)?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let newDone = try #require(reopened.occurrence(id: newOccurrence.id))
        #expect(newDone.state == .succeeded)
        #expect(newDone.taskVersion == newTask.version)
        #expect(newDone.id != queued.id)
        #expect(newDone.effectID != queued.effectID)
        #expect(newDone.retryOfOccurrenceID == nil)
        #expect(newDone.submissionReceipt?.request.targetSessionID == newID)
        #expect(newDone.submissionReceipt?.request.targetTurnID == 3)
        #expect(reopened.occurrence(id: queued.id)?.submissionReceipt == receipt)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
        struct DeliveryEvidence: Encodable {
            let oldDone: SchedulerOccurrence
            let newDone: SchedulerOccurrence
            let approvedOldAnchor: String
            let approvedNewAnchor: String
            let oldProviderHistory: [LLMMessage]
            let newProviderHistory: [LLMMessage]
        }
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let evidence = DeliveryEvidence(oldDone: oldDone, newDone: newDone,
            approvedOldAnchor: oldAnchor, approvedNewAnchor: newAnchor,
            oldProviderHistory: oldProviderHistory, newProviderHistory: f.provider.received())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: formal.rootDirectory.appendingPathComponent(
            "sched2258-provider-delivery-\(queued.id.uuidString).json"))
    }
}


extension WP2BComposerSubmissionBoundaryTests {
    @Test("legacy missing source binding may reuse only its exact current definition", arguments: [false, true])
    func legacySourceBindingNeverComesFromAnotherDefinition2258(editedDefinition: Bool) async throws {
        let f = try ScheduledTargetFixture(command: "legacy approved request")
        defer { f.cleanup() }
        let task = try #require(f.ledger.task(id: f.taskID))
        let queued = try #require(f.ledger.reserveOccurrence(taskID: f.taskID, at: f.date))
        if editedDefinition {
            var edited = task
            edited.command = "new separately approved request"
            #expect(f.ledger.update(edited, expectedVersion: task.version) == nil)
            let digest = try #require(task.sourceAnchorDigest)
            var preview = try #require(f.ledger.preview(taskID: f.taskID, now: f.date))
            preview.observedSourceAnchorDigest = digest
            preview.observedPolicyRevision = "scheduled-policy"
            #expect(f.ledger.confirmPreview(preview, actorID: "explicit-new-version-user",
                scopeID: f.projectID, policyRevision: "scheduled-policy", now: f.date,
                sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest,
                currentPolicyRevision: "scheduled-policy"))
        }
        let url = f.root.appendingPathComponent("occurrences.json")
        let raw = try Data(contentsOf: url)
        var envelope = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var rows = try #require(envelope["occurrences"] as? [[String: Any]])
        #expect(rows.count == 1)
        rows[0].removeValue(forKey: "sourceAnchorDigest")
        envelope["occurrences"] = rows
        let legacyData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try legacyData.write(to: url)
        let reopened = SchedulerTaskStore(defaults: f.defaults, occurrenceLedgerURL: url)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.isOccurrenceAuthorized(queued, now: f.date))
        let runtime = f.makeRuntime(reopened)
        defer { runtime.stop() }
        runtime.pollNow(at: f.date)
        for _ in 0..<300 {
            if f.provider.callCount() > 0 || reopened.occurrence(id: queued.id)?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(f.provider.callCount() == (editedDefinition ? 0 : 1))
        if editedDefinition {
            #expect(reopened.occurrence(id: queued.id)?.state == .failed)
            #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        } else {
            #expect(f.provider.received().last?.content == "legacy approved request")
            f.provider.finish()
            for _ in 0..<300 {
                if reopened.occurrence(id: queued.id)?.state.isTerminal == true { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(reopened.occurrence(id: queued.id)?.state == .succeeded)
        }
    }
}

@Suite("N-1 scheduled project hook binding", .serialized)
@MainActor
struct ScheduledProjectHookBindingTests {
    @Test("a scheduled target resolves project guards without a prior interactive turn")
    func scheduledRunBindsProjectHookWithoutPriorInteractiveTurn() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let project = formal.temporaryDirectory.appendingPathComponent(
            "n1-project-" + UUID().uuidString, isDirectory: true)
        let fixture = try ScheduledTargetFixture()
        let previouslyInstalled = HookRuntime.installed
        defer {
            fixture.cleanup()
            HookRuntime.install(previouslyInstalled)
            try? FileManager.default.removeItem(at: project)
        }
        let hookFile = project.appendingPathComponent(HookConfigStore.projectRelativePath)
        try FileManager.default.createDirectory(at: hookFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(HookConfigurationFile(hooks: [HookDefinition(
            id: "scheduled-project-guard", event: .preToolUse, command: "exit 2")]))
            .write(to: hookFile)
        // Qualify the same trusted-root reader used by scheduled prompt
        // preparation before attributing any failure to hook registration.
        let projectType = try? FileManager.default.attributesOfItem(atPath: project.path)[.type]
        do {
            _ = try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: project)
        } catch {
            try #require(Bool(false),
                "Trusted fixture root: \(project.path); directoryURL=\(project.hasDirectoryPath); components=\(project.pathComponents); type=\(String(describing: projectType)); error=\(error)")
        }
        let hooks = HookRuntime(store: HookConfigStore(
            directory: fixture.root.appendingPathComponent("hook-state")), environment: { [:] })
        HookRuntime.install(hooks)
        let projectID = fixture.projectID
        fixture.chat.trustedProjectRootProvider = { scope in
            scope.projectID == projectID ? project : nil
        }

        // Exercise the actual scheduler -> ChatStore target route. The test
        // never primes HookRuntime with beginTurn or a session registration.
        // Match production bootstrap: a bare ChatStore has no default
        // Provider/model selection, even with a transport fixture installed.
        fixture.chat.restoreSpeedTier(.fast)
        let task = try #require(fixture.ledger.allTasks().first)
        let preflight = fixture.chat.schedulerProviderPreflight(for: task, now: fixture.date)
        try #require(preflight.isReadyForExecution, "\(preflight.status): \(preflight.detail)")
        fixture.runtime.pollNow(at: fixture.date)
        let occurrence = try #require(fixture.ledger.latestOccurrence(for: fixture.taskID))
        try #require(occurrence.state == .running,
            "The actual scheduler must own a running lease before testing its hooks")
        do { try await fixture.waitForProvider() }
        catch {
            // This one-attempt regression keeps the actual public admission
            // error; other shared-fixture retry behavior stays unchanged.
            if let submissionError = fixture.lastSubmissionError { throw submissionError }
            throw error
        }
        let invocation = ComposerHookInvocation(callID: "scheduled-guard-probe",
            capability: "file_write",
            input: try ComposerToolInput(["path": project.appendingPathComponent("owned.txt").path]),
            identityDigest: "scheduled-guard-identity", sessionID: fixture.targetID.uuidString)
        let decision = try await hooks.preToolUse(invocation)
        #expect(decision.hasDecision && decision.verdict == .deny)
        #expect(decision.invocationIdentityDigest == invocation.identityDigest)
        fixture.provider.finish()
        let terminal = try await fixture.waitForTerminal()
        #expect(terminal.state == .succeeded)
    }
}
