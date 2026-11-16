import Foundation
import Testing
@testable import MinisCore

@Suite("R35/E child lifecycle P0")
struct R35EChildLifecycleP0Tests {
    @Test("production child catalog is an explicit capability intersection")
    func productionChildDoesNotInheritParentTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35e-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.txt")
        try "synthetic child input".write(to: file, atomically: true, encoding: .utf8)

        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(
            capabilities: [.streaming, .tools],
            responses: [r35EToolEnvelope(name: "file_read", path: file.path), "done"]
        )
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let executor = R35EOwnerBoundRecordingExecutor(owner: owner)
        let store = AgentTaskStore()
        let orchestrator = makeR35EOrchestrator(
            provider: provider,
            executor: executor,
            store: store,
            parentTurn: parentTurn,
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.streaming, .tools],
            concreteBuiltinOwner: owner
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "restricted-child",
                    title: "restricted-child",
                    instructions: "read",
                    requiredCapabilities: [.tools],
                    resourceRequest: SubAgentResourceRequest(
                        allowedToolNames: ["file_read"], allowedReadRoots: [root.path]
                    )
                )
            ],
            strategy: .sequential
        )

        let receipt = try #require(store.allReceipts().first)
        let attempt = try #require(store.attempts(runID: receipt.runID).first)
        #expect(reports.first?.result.isSuccess == true, "\(reports.first?.result.error ?? "missing report")")
        #expect(await executor.names == ["file_read"])
        #expect(provider.offeredToolNames == [["file_read"], ["file_read"]])
        #expect(receipt.attemptID == attempt.attemptID)
        #expect(store.events(runID: receipt.runID).map(\.kind) == [.started, .progress, .completed])
    }

    @Test("production dispatch without explicit parent capabilities fails closed")
    func productionCannotRecreateParentCapabilitiesFromProvider() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(capabilities: [.streaming, .tools], responses: ["done"])
        let store = AgentTaskStore()
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: R35EToolExecutor(),
            currentConversationID: "r35e-conversation",
            taskStore: store,
            parentID: "r35e-parent",
            parentRuntimeIdentity: r35EParentIdentity(parentTurn: parentTurn),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: nil,
            parentCapabilities: nil
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "missing-parent-facts",
                    title: "missing-parent-facts",
                    instructions: "must not run"
                )
            ],
            strategy: .sequential
        )

        #expect(reports.first?.result == .failed(error: "PARENT_CAPABILITIES_UNVERIFIED"))
        #expect(provider.callCount == 0)
        let receipt = try #require(store.allReceipts().first)
        #expect(receipt.outcome == .failed(reason: "execution-failed"))
    }

    @Test("production dispatch without a lifecycle ledger fails closed")
    func productionCannotRunWithoutDurableReceiptLedger() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(capabilities: [.streaming], responses: ["done"])
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: R35EToolExecutor(),
            currentConversationID: "r35e-conversation",
            parentID: "r35e-parent",
            parentRuntimeIdentity: r35EParentIdentity(parentTurn: parentTurn),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming]
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "missing-ledger",
                    title: "missing-ledger",
                    instructions: "must not run"
                )
            ],
            strategy: .sequential
        )

        #expect(reports.first?.result == .failed(error: "LIFECYCLE_LEDGER_UNAVAILABLE"))
        #expect(provider.callCount == 0)
    }

    @Test("absolute production deadline rejects a late child writeback")
    func deadlineClosesChildBeforeReceiptSuccess() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(
            capabilities: [.streaming],
            responses: ["late"],
            ignoresCancellation: true,
            responseDelay: 0.25
        )
        let store = AgentTaskStore()
        let orchestrator = makeR35EOrchestrator(
            provider: provider,
            executor: R35EToolExecutor(),
            store: store,
            parentTurn: parentTurn,
            policy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming],
            deadline: Date().addingTimeInterval(0.03)
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "deadline", title: "deadline", instructions: "wait")],
            strategy: .sequential
        )

        #expect(reports.first?.result == .failed(error: "DEADLINE_EXCEEDED"))
        #expect(store.allReceipts().first?.outcome == .failed(reason: "execution-failed"))
    }

    @Test("parent cancellation settles the production receipt and rejects late output")
    func parentCancellationWinsAgainstLateProviderResult() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let signal = R35ECallSignal()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(
            capabilities: [.streaming],
            responses: ["late"],
            signal: signal,
            ignoresCancellation: true,
            responseDelay: 0.25
        )
        let store = AgentTaskStore()
        let orchestrator = makeR35EOrchestrator(
            provider: provider,
            executor: R35EToolExecutor(),
            store: store,
            parentTurn: parentTurn,
            policy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming]
        )

        let work = Task {
            await orchestrator.orchestrate(
                tasks: [SubAgentTask(id: "cancelled", title: "cancelled", instructions: "wait")],
                strategy: .sequential
            )
        }
        await signal.wait()
        await parentTurn.interrupt()
        let reports = await work.value

        #expect(reports.first?.result.isSuccess == false)
        #expect(store.allReceipts().first?.outcome == .cancelled)
    }

    @Test("ended parent turn rejects a late provider result")
    func endedParentTurnWinsAgainstLateProviderResult() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let signal = R35ECallSignal()
        defer { Task { await parentTurn.finish() } }

        let provider = R35EProvider(
            capabilities: [.streaming],
            responses: ["late"],
            signal: signal,
            ignoresCancellation: true,
            responseDelay: 0.25
        )
        let store = AgentTaskStore()
        let orchestrator = makeR35EOrchestrator(
            provider: provider,
            executor: R35EToolExecutor(),
            store: store,
            parentTurn: parentTurn,
            policy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming]
        )

        let work = Task {
            await orchestrator.orchestrate(
                tasks: [SubAgentTask(id: "ended", title: "ended", instructions: "wait")],
                strategy: .sequential
            )
        }
        await signal.wait()
        await parentTurn.finish()
        let reports = await work.value

        #expect(reports.first?.result == .failed(error: "任务已取消"))
        #expect(store.allReceipts().first?.outcome == .cancelled)
    }

    @Test("recovered running child requires review and is never auto-redispatched")
    func recoveryDoesNotRedispatchChild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35e-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("tasks.json")

        let first = try AgentTaskStore(persistenceURL: ledgerURL)
        _ = try first.enqueue(
            taskID: "recover-child",
            parentID: "recover-parent",
            providerID: "provider",
            modelID: "model",
            configurationFingerprint: "fingerprint"
        )
        _ = try first.startRun(
            taskID: "recover-child",
            parentID: "recover-parent",
            runID: "recover-run"
        )

        let recovered = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(recovered.recoveryState(runID: "recover-run") == .needsUserReview)
        #expect(recovered.externalSubmissionDecision(runID: "recover-run") == .needsUserReview)
        #expect(recovered.attempts(runID: "recover-run").count == 1)
        #expect(recovered.allReceipts().isEmpty)
    }
}

private func makeR35EOrchestrator(
    provider: any LLMProvider,
    executor: any ToolExecutor,
    store: AgentTaskStore,
    parentTurn: TurnController.TurnHandle,
    policy: AgentCapabilityPolicy,
    parentCapabilities: Set<ProviderCapability>,
    deadline: Date? = nil,
    concreteBuiltinOwner: BuiltinToolExecutor? = nil
) -> AgentOrchestrator {
    let toolExecutionFactLedger = try! ToolExecutionFactLedger(
        persistenceURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("r35e-tool-facts-\(UUID().uuidString).json")
    )
    return AgentOrchestrator(
        maxIterationsPerTask: 4,
        provider: provider,
        toolExecutor: executor,
        childTimeout: 2,
        deadline: deadline,
        currentConversationID: "r35e-conversation",
        taskStore: store,
        toolExecutionFactLedger: toolExecutionFactLedger,
        parentID: "r35e-parent",
        parentBinding: ParentContextSnapshotV1(
            providerID: provider.name,
            modelID: provider.model.id,
            configurationFingerprint: "r35e-fingerprint",
            conversationID: "r35e-conversation"
        ),
        parentRuntimeIdentity: r35EParentIdentity(parentTurn: parentTurn),
        parentTurnHandle: parentTurn,
        runtimeMode: .production,
        capabilityPolicy: policy,
        parentCapabilities: parentCapabilities,
        parentFileAccessCeiling: concreteBuiltinOwner.map { ChildParentFileAccessCeiling(executor: $0) },
        concreteBuiltinToolExecutorOwner: concreteBuiltinOwner
    )
}

private func r35EParentIdentity(parentTurn: TurnController.TurnHandle) -> ParentRuntimeIdentity {
    ParentRuntimeIdentity(
        sessionID: "r35e-session",
        conversationID: "r35e-conversation",
        turnID: "turn-handle:\(parentTurn.turnID)",
        taskID: "r35e-parent",
        actorID: "r35e-test"
    )
}

private func r35EToolEnvelope(name: String, path: String) -> String {
    let object: [String: Any] = [
        "tool_calls": [[
            "id": "r35e-call",
            "name": name,
            "input": ["path": path]
        ]]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private actor R35ECallSignal {
    private var called = false
    private var waiter: CheckedContinuation<Void, Never>?

    func mark() {
        called = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if called { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class R35EToolExecutor: ToolExecutor, @unchecked Sendable {
    private let probe = R35EToolNameProbe()

    var names: [String] {
        get async { await probe.names }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        await probe.record(name)
        return "tool-ok"
    }
}

/// Records only a real effect forwarded through the exact parent builtin owner.
private final class R35EOwnerBoundRecordingExecutor: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    private let owner: BuiltinToolExecutor
    private let probe = R35EToolNameProbe()

    init(owner: BuiltinToolExecutor) { self.owner = owner }

    var currentBuiltinOwner: BuiltinToolExecutor? { owner }
    var names: [String] { get async { await probe.names } }

    func executeBoundToBuiltinOwner(
        _ expectedOwner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard expectedOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        let output = try await owner.executeBoundToBuiltinOwner(expectedOwner, name: name, input: input)
        await probe.record(name)
        return output
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.resourceScopeInvalid
    }
}

private actor R35EToolNameProbe {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}

private final class R35EProvider: LLMProvider, @unchecked Sendable {
    let name = "r35e-provider"
    var model = LLMModel(id: "r35e-model", displayName: "R35E", provider: "r35e-provider")
    let capabilities: Set<ProviderCapability>

    private let state = R35EProviderState()
    private var responses: [String]
    private let ignoresCancellation: Bool
    private let responseDelay: TimeInterval
    private let signal: R35ECallSignal?

    init(
        capabilities: Set<ProviderCapability>,
        responses: [String],
        signal: R35ECallSignal? = nil,
        ignoresCancellation: Bool = false,
        responseDelay: TimeInterval = 0
    ) {
        self.capabilities = capabilities
        self.responses = responses
        self.signal = signal
        self.ignoresCancellation = ignoresCancellation
        self.responseDelay = responseDelay
    }

    var callCount: Int {
        state.callCount
    }

    var offeredToolNames: [[String]] {
        state.offeredToolNames
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await send(toolNames: [])
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await send(toolNames: tools.map(\.name))
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func send(toolNames: [String]) async throws -> LLMResponse {
        let response: String
        response = state.record(toolNames: toolNames, response: responses.isEmpty ? "done" : responses.removeFirst())
        await signal?.mark()
        if responseDelay > 0 {
            if ignoresCancellation {
                try? await Task.sleep(for: .seconds(responseDelay))
            } else {
                try await Task.sleep(for: .seconds(responseDelay))
            }
        }
        return LLMResponse(text: response, stopReason: nil, usage: nil)
    }
}

private final class R35EProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _offeredToolNames: [[String]] = []

    var callCount: Int {
        withLock { _callCount }
    }

    var offeredToolNames: [[String]] {
        withLock { _offeredToolNames }
    }

    func record(toolNames: [String], response: String) -> String {
        withLock {
            _callCount += 1
            _offeredToolNames.append(toolNames)
            return response
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
