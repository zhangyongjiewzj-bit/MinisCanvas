import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class ProviderObservationReadThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let mainActorTurn = DispatchSemaphore(value: 0)
    private var value: Bool?
    private var timedOut = false

    func record(_ isMainThread: Bool) {
        lock.lock()
        value = isMainThread
        lock.unlock()
    }

    var mainThreadRead: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func waitForMainActorTurn() {
        Task { @MainActor in self.mainActorTurn.signal() }
        let didTimeOut = mainActorTurn.wait(timeout: .now() + .seconds(2)) == .timedOut
        lock.lock()
        timedOut = didTimeOut
        lock.unlock()
    }

    var mainActorTurnTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

private final class ProviderObservationReadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func waitForReadStart() -> Bool {
        started.wait(timeout: .now() + .seconds(3)) == .success
    }
}

private final class RuntimeSnapshotProvider: LLMProvider, @unchecked Sendable {
    let name = "runtime-snapshot"
    var model = LLMModel(
        id: "runtime-snapshot-model",
        displayName: "Runtime Snapshot",
        provider: "runtime-snapshot"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    private(set) var sendWithoutToolsCount = 0
    private(set) var sendWithToolsCount = 0
    private(set) var streamCount = 0

    var sendCount: Int {
        sendWithoutToolsCount + sendWithToolsCount
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendWithoutToolsCount += 1
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendWithToolsCount += 1
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class R14ThrowingRuntimeProvider: LLMProvider, @unchecked Sendable {
    let name = "runtime-snapshot"
    var model = LLMModel(
        id: "runtime-snapshot-model",
        displayName: "Runtime Snapshot",
        provider: "runtime-snapshot"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw R14OriginalProviderError()
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
        throw R14OriginalProviderError()
    }
}

private struct R14OriginalProviderError: Error, Equatable, LocalizedError {
    var errorDescription: String? { "r14-original-provider-error" }
}

private final class RuntimeRouteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private actor R11ObservationDeliveryProbe {
    private(set) var observations: [ProviderRuntimeRouteObservation] = []

    var count: Int { observations.count }
    var last: ProviderRuntimeRouteObservation? { observations.last }

    func record(_ observation: ProviderRuntimeRouteObservation) {
        observations.append(observation)
    }
}

private final class RuntimeBoundaryMCPBridge: MCPToolBridge, @unchecked Sendable {
    let discoveryCounter: RuntimeRouteCounter
    let callCounter: RuntimeRouteCounter

    init(
        discoveryCounter: RuntimeRouteCounter,
        callCounter: RuntimeRouteCounter
    ) {
        self.discoveryCounter = discoveryCounter
        self.callCounter = callCounter
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        discoveryCounter.increment()
        return []
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        callCounter.increment()
        return "unexpected"
    }
}

private final class RuntimeBoundaryToolExecutor: ToolExecutor, @unchecked Sendable {
    let executionCounter: RuntimeRouteCounter

    init(executionCounter: RuntimeRouteCounter) {
        self.executionCounter = executionCounter
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        executionCounter.increment()
        return "unexpected"
    }
}

private final class RuntimeMCPCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class FrozenRuntimeMCPBridge: MCPToolBridgeInvocationFencing, @unchecked Sendable {
    let tool: MCPBoundTool
    let enabled: Bool
    let response: String
    let recorder: RuntimeMCPCallRecorder
    private let invocationLock = NSLock()
    private var claimedInvocations: Set<MCPToolInvocationIdentity> = []

    init(
        tool: MCPBoundTool,
        enabled: Bool,
        response: String,
        recorder: RuntimeMCPCallRecorder
    ) {
        self.tool = tool
        self.enabled = enabled
        self.response = response
        self.recorder = recorder
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        enabled ? [tool] : []
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        guard enabled, fullName == tool.fullName else {
            throw MCPClientError.toolNotFound(fullName)
        }
        recorder.record(response)
        return response
    }

    func callMCPTool(
        fullName: String,
        arguments: [String: Any]?,
        invocation: MCPToolInvocationIdentity
    ) async throws -> String {
        try claim(invocation)
        return try await callMCPTool(fullName: fullName, arguments: arguments)
    }

    private func claim(_ invocation: MCPToolInvocationIdentity) throws {
        guard invocation.isValid else { throw MCPToolInvocationFenceError.invalidIdentity }
        invocationLock.lock()
        defer { invocationLock.unlock() }
        guard claimedInvocations.insert(invocation).inserted else {
            throw MCPToolInvocationFenceError.duplicate(invocation)
        }
    }
}

private final class MutableRuntimeMCPBridge: MCPToolBridgeTurnSnapshotting, @unchecked Sendable {
    let tool: MCPBoundTool
    let recorder = RuntimeMCPCallRecorder()
    var enabled = true
    var response = "frozen-response"

    init() {
        tool = MCPBoundTool(
            fullName: "mcp_runtime_echo",
            serverID: "runtime",
            tool: MCPTool(
                name: "echo",
                description: "Echo a runtime snapshot value",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")])
                    ])
                ])
        )
            )
    }

    func snapshotForTurn() throws -> any MCPToolBridge {
        FrozenRuntimeMCPBridge(
            tool: tool,
            enabled: enabled,
            response: response,
            recorder: recorder
        )
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        enabled ? [tool] : []
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        guard enabled, fullName == tool.fullName else {
            throw MCPClientError.toolNotFound(fullName)
        }
        recorder.record(response)
        return response
    }
}

private final class RuntimeMCPProvider: LLMProvider, @unchecked Sendable {
    let name = "runtime-mcp"
    var model = LLMModel(id: "runtime-mcp", displayName: "Runtime MCP", provider: "runtime-mcp")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    let requestedToolName: String
    private(set) var receivedToolNames: [[String]] = []
    // Only this synthetic provider's bounded tool feedback, never live provider data.
    private(set) var receivedToolFeedback: [String] = []
    private var callIndex = 0

    init(requestedToolName: String) {
        self.requestedToolName = requestedToolName
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedToolNames.append(tools.map(\.name))
        for message in messages where message.role == .tool {
            if receivedToolFeedback.count < 4 {
                receivedToolFeedback.append(String(message.content.prefix(512)))
            }
        }
        defer { callIndex += 1 }
        if callIndex == 0, tools.contains(where: { $0.name == requestedToolName }) {
            return LLMResponse(
                text: "",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "runtime-mcp-call",
                    name: requestedToolName,
                    rawArguments: "{\"value\":\"hello\"}",
                    arguments: ["value": "hello"]
                )]
            )
        }
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct RuntimeApprovalDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private func runtimePolicyBoundExecutor(
    root: URL,
    mcpBridge: any MCPToolBridge
) -> PolicyEnforcedToolExecutor {
    let builtin = BuiltinToolExecutor(allowedRoot: root, mcpBridge: mcpBridge)
    let now = Date()
    let goal = GoalEnvelope(
        scopeID: "test:unified-turn-runtime",
        allowedCapabilities: builtin.registeredToolNames,
        fileRoots: [root.path],
        budget: 10,
        deadline: now.addingTimeInterval(60),
        concurrencyLimit: 1,
        autonomyLevel: .l1,
        creatorID: "UnifiedTurnRuntimeSnapshotTests",
        createdAt: now
    )
    let lease = AutonomyLease(
        goalID: goal.goalID,
        scopeID: goal.scopeID,
        issuedAt: now,
        expiresAt: goal.deadline
    )
    return PolicyEnforcedToolExecutor(
        base: builtin,
        goal: goal,
        lease: lease,
        capabilityResolver: builtin
    )
}

private func runtimeFilesystemProjection(at root: URL) throws -> [String: String] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return [:] }
    let rootPath = root.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else {
        return [:]
    }

    var projection: [String: String] = [:]
    while let url = enumerator.nextObject() as? URL {
        let standardizedPath = url.standardizedFileURL.path
        let relativePath = standardizedPath.hasPrefix(prefix)
            ? String(standardizedPath.dropFirst(prefix.count))
            : standardizedPath
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            projection[relativePath] = "directory"
        } else {
            projection[relativePath] = "file:\(try Data(contentsOf: url).base64EncodedString())"
        }
    }
    return projection
}

private func runtimeFacts(
    workspaceID: String,
    capabilities: Set<String> = []
) -> ComposerPolicyFactSource {
    ComposerPolicyFactSource(
        knownCapabilities: capabilities,
        grantedCapabilities: capabilities,
        allowedWriteRoots: [],
        workspaceID: workspaceID,
        revision: "runtime-snapshot-revision",
        grantEpoch: "runtime-snapshot-epoch",
        leaseID: "runtime-snapshot-lease",
        expiresAt: Date().addingTimeInterval(60),
        autonomyCeiling: .l3
    )
}

private func runtimeComposerSnapshot(
    turn: AgentTurnIdentity,
    workspaceID: String
) -> ComposerSubmissionSnapshot {
    ComposerSubmissionSnapshot(
        mode: .auto,
        approvalScope: .request,
        effort: .standard,
        sessionID: turn.sessionID,
        turnID: turn.turnID,
        taskID: "task:\(turn.turnID)",
        attemptID: "attempt:\(turn.turnID)",
        messageID: turn.messageID,
        inputDigest: "digest:\(turn.turnID)",
        workspaceID: workspaceID,
        createdAt: Date(),
        policyRevision: "runtime-snapshot-revision",
        grantEpoch: "runtime-snapshot-epoch",
        autonomyCeiling: .l3
    )
}

private struct SnapshotEngineDelivery {
    let prompt: String
    let executionTurn: AgentTurnIdentity
    let snapshotTurn: AgentTurnIdentity
}

private struct FallbackCompositionDelivery {
    let composerSnapshot: ComposerSubmissionSnapshot
    let executionIdentity: AgentExecutionIdentity
    let turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    let conversationID: String?
    let turnID: Int?
}

private final class RecordingFallbackChatEngine: ChatAgentEngine, @unchecked Sendable {
    private let delegate: FallbackChatEngine
    private let lock = NSLock()
    private var deliveries: [FallbackCompositionDelivery] = []

    init(delegate: FallbackChatEngine) {
        self.delegate = delegate
    }

    var isAvailable: Bool { delegate.isAvailable }

    var recordedDeliveries: [FallbackCompositionDelivery] {
        lock.withLock { deliveries }
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await delegate.streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens
        )
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock {
            deliveries.append(FallbackCompositionDelivery(
                composerSnapshot: composerSnapshot,
                executionIdentity: executionIdentity,
                turnRuntimeSnapshot: turnRuntimeSnapshot,
                conversationID: conversationID,
                turnID: turnID
            ))
        }
        return try await delegate.streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: turnRuntimeSnapshot
        )
    }

    func interrupt() {
        delegate.interrupt()
    }
}

private final class SnapshotPromptRecordingEngine: ChatAgentEngine, @unchecked Sendable {
    let isAvailable = true
    private let lock = NSLock()
    private var deliveries: [SnapshotEngineDelivery] = []

    var recordedDeliveries: [SnapshotEngineDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    private func record(_ delivery: SnapshotEngineDelivery) {
        lock.lock()
        deliveries.append(delivery)
        lock.unlock()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        record(SnapshotEngineDelivery(
            prompt: systemPrompt,
            executionTurn: executionIdentity.turn,
            snapshotTurn: turnRuntimeSnapshot.turn
        ))
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
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
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

private struct LegacyRuntimeSnapshotDroppingEngine: ChatAgentEngine {
    let isAvailable = false

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        _ = try await provider.streamMessage(
            messages: [],
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: 0.7
        )
        return AsyncThrowingStream { $0.finish() }
    }

    func interrupt() {}
}

@Suite("Unified turn runtime snapshot")
@MainActor
struct UnifiedTurnRuntimeSnapshotTests {
    @Test("journal read and decode do not execute on the App actor")
    func providerObservationJournalReadLeavesMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf06-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("provider-runtime-observations-v1.json")
        let older = ProviderRuntimeRouteObservation(
            routeReceiptID: "older", servedProviderID: "synthetic"
        )
        try JSONEncoder().encode([older]).write(to: journal)

        let probe = ProviderObservationReadThreadProbe()
        let bridge = BridgeStore()
        bridge.readProviderRuntimeObservationJournalForTesting = { url in
            probe.record(Thread.isMainThread)
            probe.waitForMainActorTurn()
            return try Data(contentsOf: url)
        }
        await bridge.attachProductionServices(sessionDirectory: root).value

        #expect(probe.mainThreadRead == false)
        #expect(!probe.mainActorTurnTimedOut)
        #expect(bridge.providerRuntimeObservations.map(\.routeReceiptID) == ["older"])
    }

    @Test("new observations remain behind the old journal and survive same-root rebind")
    func providerObservationOldNewOrderingAcrossRebind() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf06-observation-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("provider-runtime-observations-v1.json")
        let old = ProviderRuntimeRouteObservation(routeReceiptID: "old", servedProviderID: "synthetic")
        try JSONEncoder().encode([old]).write(to: journal)

        let bridge = BridgeStore()
        let initial = bridge.attachProductionServices(sessionDirectory: root)
        bridge.recordProviderRuntimeObservation(
            ProviderRuntimeRouteObservation(routeReceiptID: "new", servedProviderID: "synthetic")
        )
        await initial.value
        #expect(bridge.providerRuntimeObservations.map(\.routeReceiptID) == ["old", "new"])
        await bridge.attachProductionServices(sessionDirectory: root).value
        #expect(bridge.providerRuntimeObservations.map(\.routeReceiptID) == ["old", "new"])
        let persisted = try JSONDecoder().decode(
            [ProviderRuntimeRouteObservation].self, from: Data(contentsOf: journal)
        )
        #expect(persisted.map(\.routeReceiptID) == ["old", "new"])
    }

    @Test("a delayed old-root load cannot publish after a newer root wins")
    func providerObservationLateOldRootCannotOverwriteNewRoot() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf06-observation-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let oldRoot = parent.appendingPathComponent("old", isDirectory: true)
        let newRoot = parent.appendingPathComponent("new", isDirectory: true)
        for root in [oldRoot, newRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let oldJournal = oldRoot.appendingPathComponent("provider-runtime-observations-v1.json")
        let newJournal = newRoot.appendingPathComponent("provider-runtime-observations-v1.json")
        try JSONEncoder().encode([
            ProviderRuntimeRouteObservation(routeReceiptID: "old-root", servedProviderID: "synthetic")
        ]).write(to: oldJournal)
        let originalOldJournal = try Data(contentsOf: oldJournal)
        try JSONEncoder().encode([
            ProviderRuntimeRouteObservation(routeReceiptID: "new-root", servedProviderID: "synthetic")
        ]).write(to: newJournal)

        let gate = ProviderObservationReadGate()
        let bridge = BridgeStore()
        bridge.readProviderRuntimeObservationJournalForTesting = { url in
            if url == oldJournal {
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + .seconds(3))
            }
            return try Data(contentsOf: url)
        }
        let first = bridge.attachProductionServices(sessionDirectory: oldRoot)
        let didStart = await Task.detached {
            gate.waitForReadStart()
        }.value
        #expect(didStart)
        let second = bridge.attachProductionServices(sessionDirectory: newRoot)
        gate.release.signal()
        await first.value
        await second.value
        #expect(bridge.providerRuntimeObservationPersistenceURL == newJournal)
        #expect(bridge.providerRuntimeObservations.map(\.routeReceiptID) == ["new-root"])
        #expect(try Data(contentsOf: oldJournal) == originalOldJournal)
    }

    @Test("cancelled journal load cannot publish a production binding")
    func providerObservationCancelledLoadDoesNotPublish() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf06-observation-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("provider-runtime-observations-v1.json")
        try JSONEncoder().encode([
            ProviderRuntimeRouteObservation(routeReceiptID: "unpublished", servedProviderID: "synthetic")
        ]).write(to: journal)
        let original = try Data(contentsOf: journal)

        let gate = ProviderObservationReadGate()
        let bridge = BridgeStore()
        bridge.readProviderRuntimeObservationJournalForTesting = { url in
            gate.started.signal()
            _ = gate.release.wait(timeout: .now() + .seconds(3))
            return try Data(contentsOf: url)
        }
        let binding = bridge.attachProductionServices(sessionDirectory: root)
        let didStart = await Task.detached {
            gate.waitForReadStart()
        }.value
        #expect(didStart)
        binding.cancel()
        gate.release.signal()
        await binding.value

        #expect(bridge.providerRuntimeObservationPersistenceURL == nil)
        #expect(bridge.providerRuntimeObservations.isEmpty)
        #expect(try Data(contentsOf: journal) == original)
    }

    @Test("OpenRouter concrete provider name matches its frozen runtime ID")
    func openRouterConcreteProviderBindsToRuntimeID() throws {
        let runtimeID = ProviderType.openRouter.runtimeProviderID
        let provider = try ProviderFactory.shared.makeProvider(
            for: ProviderConfig(
                label: runtimeID,
                providerType: .openRouter
            ),
            requireCredentials: false
        )

        #expect(runtimeID == "OpenRouter")
        #expect(provider.name == runtimeID)
        #expect(provider.model.provider == runtimeID)
    }

    @Test("Anthropic built-in concrete provider binds name and model to runtime ID")
    func anthropicBuiltInConcreteProviderBindsToRuntimeID() throws {
        let provider = try ProviderFactory.shared.makeProvider(
            for: ProviderConfig(
                label: "Anthropic UI label",
                providerType: .anthropic,
                runtimeProviderID: ProviderType.anthropic.runtimeProviderID
            ),
            requireCredentials: false
        )

        #expect(provider.name == ProviderType.anthropic.runtimeProviderID)
        #expect(provider.model.provider == ProviderType.anthropic.runtimeProviderID)
    }

    @Test("Anthropic-compatible custom provider preserves explicit runtime identity")
    func anthropicCustomConcreteProviderBindsToRuntimeID() throws {
        let provider = try ProviderFactory.shared.makeProvider(
            for: ProviderConfig(
                label: "Anthropic proxy label",
                providerType: .anthropic,
                runtimeProviderID: "anthropic-proxy",
                customBaseURL: "https://proxy.invalid",
                apiKey: "test-key"
            )
        )

        #expect(provider.name == "anthropic-proxy")
        #expect(provider.model.provider == "anthropic-proxy")
    }

    @Test("OpenAI Responses concrete provider binds to runtime ID instead of UI label")
    func openAIResponsesConcreteProviderBindsToRuntimeID() throws {
        let provider = try ProviderFactory.shared.makeProvider(
            for: ProviderConfig(
                label: "Responses UI label",
                providerType: .openAIResponses,
                runtimeProviderID: ProviderType.openAIResponses.runtimeProviderID
            ),
            requireCredentials: false
        )

        #expect(provider.name == ProviderType.openAIResponses.runtimeProviderID)
        #expect(provider.model.provider == ProviderType.openAIResponses.runtimeProviderID)
    }

    @Test("explicit custom runtime identity remains canonical for compatible providers")
    func explicitCustomRuntimeIdentityOverridesUILabel() throws {
        let provider = try ProviderFactory.shared.makeProvider(
            for: ProviderConfig(
                label: "Visible label",
                providerType: .openAI,
                runtimeProviderID: "proxy-runtime",
                apiKey: "test-key"
            )
        )

        #expect(provider.name == "proxy-runtime")
        #expect(provider.model.provider == "proxy-runtime")
    }

    @Test("provider route awaits observation delivery before returning its result")
    func routeAwaitsObservationDelivery() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "runtime-snapshot",
            modelID: "runtime-snapshot-model",
            readinessEvidenceID: "r11-await-evidence",
            applyReceiptID: "provider-readiness-apply:r11-await-apply"
        )
        let provider = RuntimeSnapshotProvider()
        let delivery = R11ObservationDeliveryProbe()
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: provider,
            observationSink: { observation in
                await delivery.record(observation)
            }
        )

        _ = try await route.sendMessage(
            messages: [LLMMessage(role: .user, content: "await")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        #expect(await delivery.count == 1)
        #expect(await delivery.last?.routeReceiptID == snapshot.routeReceiptID)
    }

    @Test("provider result survives observation persistence failure")
    func providerResultSurvivesObservationPersistenceFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r11-observation-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(sessionDirectory: root)
        let failingURL = root.appendingPathComponent("journal-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: failingURL, withIntermediateDirectories: true)
        bridge.providerRuntimeObservationPersistenceURL = failingURL
        bridge.recordProviderRuntimeObservation(
            ProviderRuntimeRouteObservation(
                routeReceiptID: "r11-write-failure",
                servedProviderID: "runtime-snapshot"
            )
        )

        #expect(bridge.providerRuntimeObservations.count == 1)
        #expect(bridge.providerRuntimeObservationPersistenceError != nil)
    }

    @Test("persisted observations reload into the next production consumer")
    func persistedObservationsReloadAcrossBridgeInstances() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r11-observation-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = BridgeStore()
        first.attachProductionServices(sessionDirectory: root)
        first.recordProviderRuntimeObservation(
            ProviderRuntimeRouteObservation(
                routeReceiptID: "r11-reload",
                servedProviderID: "runtime-snapshot"
            )
        )

        let restarted = BridgeStore()
        await restarted.attachProductionServices(sessionDirectory: root).value

        #expect(restarted.providerRuntimeObservations.map(\.routeReceiptID) == ["r11-reload"])
        #expect(restarted.providerRuntimeObservationPersistenceError == nil)
    }

    @Test("persisted 80-entry journal reloads exactly its final bounded 64 entries")
    func persistedEightyEntryJournalReloadsFinalSixtyFourEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r14-observation-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = BridgeStore()
        first.attachProductionServices(sessionDirectory: root)
        for index in 0..<80 {
            first.recordProviderRuntimeObservation(
                ProviderRuntimeRouteObservation(
                    routeReceiptID: "r14-restart-\(index)",
                    servedProviderID: "runtime-snapshot"
                )
            )
        }

        let restarted = BridgeStore()
        await restarted.attachProductionServices(sessionDirectory: root).value

        #expect(restarted.providerRuntimeObservations.count == 64)
        #expect(
            restarted.providerRuntimeObservations.map(\.routeReceiptID)
                == (16..<80).map { "r14-restart-\($0)" }
        )
    }

    @Test("awaited observation persistence failure preserves both Provider result and original error")
    func awaitedObservationPersistenceFailurePreservesProviderOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r14-observation-combination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failingURL = root.appendingPathComponent("journal-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: failingURL, withIntermediateDirectories: true)

        let bridge = BridgeStore()
        bridge.attachProductionServices(sessionDirectory: root)
        bridge.providerRuntimeObservationPersistenceURL = failingURL
        let successSnapshot = try ProviderRuntimeSnapshot(
            providerID: "runtime-snapshot",
            modelID: "runtime-snapshot-model",
            readinessEvidenceID: "r14-success-evidence",
            applyReceiptID: "provider-readiness-apply:r14-success-apply"
        )
        let successRoute = try ProviderRuntimeRoute(
            snapshot: successSnapshot,
            primary: RuntimeSnapshotProvider(),
            observationSink: { observation in
                await MainActor.run {
                    bridge.recordProviderRuntimeObservation(observation)
                }
            }
        )
        let success = try await successRoute.sendMessage(
            messages: [LLMMessage(role: .user, content: "success")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        #expect(success.text == "ok")
        #expect(bridge.providerRuntimeObservationPersistenceError != nil)

        let failureSnapshot = try ProviderRuntimeSnapshot(
            providerID: "runtime-snapshot",
            modelID: "runtime-snapshot-model",
            readinessEvidenceID: "r14-failure-evidence",
            applyReceiptID: "provider-readiness-apply:r14-failure-apply"
        )
        let failureRoute = try ProviderRuntimeRoute(
            snapshot: failureSnapshot,
            primary: R14ThrowingRuntimeProvider(),
            observationSink: { observation in
                await MainActor.run {
                    bridge.recordProviderRuntimeObservation(observation)
                }
            }
        )

        do {
            _ = try await failureRoute.sendMessage(
                messages: [LLMMessage(role: .user, content: "failure")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("expected the original Provider error")
        } catch let error as R14OriginalProviderError {
            #expect(error == R14OriginalProviderError())
        } catch {
            Issue.record("unexpected replacement error: \(error)")
        }

        #expect(bridge.providerRuntimeObservations.count == 2)
        #expect(bridge.providerRuntimeObservations.last?.routeReceiptID == failureSnapshot.routeReceiptID)
        #expect(bridge.providerRuntimeObservations.last?.status == .terminalFailure)
        #expect(bridge.providerRuntimeObservationPersistenceError != nil)
    }

    @Test("corrupt observation journal is quarantined before canonical recovery")
    func corruptObservationJournalIsQuarantined() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r11-observation-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("provider-runtime-observations-v1.json")
        try Data("{ definitely not json".utf8).write(to: canonical)

        let bridge = BridgeStore()
        await bridge.attachProductionServices(sessionDirectory: root).value
        bridge.recordProviderRuntimeObservation(
            ProviderRuntimeRouteObservation(
                routeReceiptID: "r11-after-corrupt",
                servedProviderID: "runtime-snapshot"
            )
        )

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("provider-runtime-observations-v1.corrupt-") })
        let recovered = try JSONDecoder().decode(
            [ProviderRuntimeRouteObservation].self,
            from: Data(contentsOf: canonical)
        )
        #expect(recovered.map(\.routeReceiptID) == ["r11-after-corrupt"])
    }

    @Test("observation journal retains only the bounded tail")
    func observationJournalUsesBoundedRetention() {
        let bridge = BridgeStore()
        for index in 0..<80 {
            bridge.recordProviderRuntimeObservation(
                ProviderRuntimeRouteObservation(
                    routeReceiptID: "r11-retention-\(index)",
                    servedProviderID: "runtime-snapshot"
                )
            )
        }

        #expect(bridge.providerRuntimeObservations.count == 64)
        #expect(bridge.providerRuntimeObservations.first?.routeReceiptID == "r11-retention-16")
        #expect(bridge.providerRuntimeObservations.last?.routeReceiptID == "r11-retention-79")
    }

    @Test("required production route failure makes zero provider calls")
    func requiredProductionRouteFailureHasZeroProviderCalls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r11-zero-call-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "r11-zero-call-workspace")
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { _ in
                throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
            },
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "r11-zero-call-session",
            turnID: 1,
            messageID: "assistant:r11-zero-call"
        )
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            ).snapshotForTurn(),
            mcpBridge: nil,
            requiresProviderRuntimeRoute: true
        )

        await #expect(throws: ProviderRuntimeSnapshotError.missingPrimaryProvenance) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "zero call")],
                systemPrompt: "test",
                maxTokens: 32,
                conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: turn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: AgentExecutionIdentity(turn: turn),
                turnRuntimeSnapshot: snapshot
            )
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    // Cross-package focused acceptance also runs these MinisCore selectors:
    // frozenSkillStoreAuxiliaryQueriesPerformZeroLiveFilesystemReads
    // frozenSkillStoreAuxiliaryProjectionDoesNotDriftAfterLiveChanges
    // frozenSkillStoreResnapshotPerformsZeroLiveFilesystemReads
    private func expectAgentLoopIdentityRejectionBeforeSideEffects(
        expectedError: ChatTurnRuntimeSnapshotError,
        executionIdentity: AgentExecutionIdentity?,
        composerSnapshot: ComposerSubmissionSnapshot,
        conversationID: String?,
        turnID: Int?,
        runtimeSnapshotTurn: AgentTurnIdentity? = nil,
        includesRuntimeSnapshot: Bool = true,
        requiresRuntimeSnapshot: Bool = false
    ) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-identity-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let contextCounter = RuntimeRouteCounter()
        let mcpDiscoveryCounter = RuntimeRouteCounter()
        let mcpCallCounter = RuntimeRouteCounter()
        let toolExecutionCounter = RuntimeRouteCounter()
        let mcpBridge = RuntimeBoundaryMCPBridge(
            discoveryCounter: mcpDiscoveryCounter,
            callCounter: mcpCallCounter
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: RuntimeBoundaryToolExecutor(
                executionCounter: toolExecutionCounter
            ),
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            mcpBridge: mcpBridge,
            chatRuntimeDependencies: requiresRuntimeSnapshot
                ? .init(
                    sessionStore: SessionStore(directory: root),
                    memoryStore: MemoryStore(directory: root),
                    skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                    soulStore: SoulStore(directory: root)
                )
                : nil,
            onContextPreparation: {
                contextCounter.increment()
            },
            composerPolicyFacts: runtimeFacts(workspaceID: composerSnapshot.workspaceID)
        )
        let runtimeSnapshot: ChatTurnRuntimeSnapshot?
        if includesRuntimeSnapshot {
            let snapshotTurn: AgentTurnIdentity
            if let runtimeSnapshotTurn {
                snapshotTurn = runtimeSnapshotTurn
            } else if let executionIdentity {
                snapshotTurn = executionIdentity.turn
            } else {
                Issue.record("nil execution identity requires an explicit runtime snapshot turn")
                return
            }
            runtimeSnapshot = ChatTurnRuntimeSnapshot(
                turn: snapshotTurn,
                skillInjector: SkillInjector(
                    store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
                ).snapshotForTurn(),
                mcpBridge: mcpBridge
            )
        } else {
            runtimeSnapshot = nil
        }

        await #expect(throws: expectedError) {
            if let executionIdentity {
                if let runtimeSnapshot {
                    _ = try await engine.streamReply(
                        provider: provider,
                        history: [ChatMessageUI(role: .user, content: "hello")],
                        systemPrompt: "test",
                        maxTokens: 64,
                        conversationID: conversationID,
                        authorizedSessionReadSessionID: nil,
                        authorizedSessionReadScope: nil,
                        turnID: turnID,
                        composerSnapshot: composerSnapshot,
                        executionIdentity: executionIdentity,
                        turnRuntimeSnapshot: runtimeSnapshot
                    )
                } else {
                    _ = try await engine.streamReply(
                        provider: provider,
                        history: [ChatMessageUI(role: .user, content: "hello")],
                        systemPrompt: "test",
                        maxTokens: 64,
                        conversationID: conversationID,
                        authorizedSessionReadSessionID: nil,
                        authorizedSessionReadScope: nil,
                        turnID: turnID,
                        composerSnapshot: composerSnapshot,
                        executionIdentity: executionIdentity
                    )
                }
            } else {
                _ = try await engine.streamReplyInternal(
                    provider: provider,
                    history: [ChatMessageUI(role: .user, content: "hello")],
                    systemPrompt: "test",
                    maxTokens: 64,
                    conversationID: conversationID,
                    authorizedSessionReadSessionID: nil,
                    authorizedSessionReadScope: nil,
                    turnID: turnID,
                    composerSnapshot: composerSnapshot,
                    executionIdentity: nil,
                    turnRuntimeSnapshot: runtimeSnapshot
                )
            }
        }
        #expect(routeCounter.count == 0)
        #expect(provider.sendWithoutToolsCount + provider.sendWithToolsCount == 0)
        #expect(provider.streamCount == 0)
        #expect(contextCounter.count == 0)
        #expect(mcpDiscoveryCounter.count == 0)
        #expect(mcpCallCounter.count == 0)
        #expect(toolExecutionCounter.count == 0)
    }

    private func expectAgentLoopIdentityAcceptanceReachesProvider(
        executionIdentity: AgentExecutionIdentity,
        composerSnapshot: ComposerSubmissionSnapshot,
        conversationID: String?,
        turnID: Int?
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-identity-acceptance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let contextCounter = RuntimeRouteCounter()
        let mcpDiscoveryCounter = RuntimeRouteCounter()
        let mcpCallCounter = RuntimeRouteCounter()
        let toolExecutionCounter = RuntimeRouteCounter()
        let mcpBridge = RuntimeBoundaryMCPBridge(
            discoveryCounter: mcpDiscoveryCounter,
            callCounter: mcpCallCounter
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: RuntimeBoundaryToolExecutor(
                executionCounter: toolExecutionCounter
            ),
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            mcpBridge: mcpBridge,
            onContextPreparation: {
                contextCounter.increment()
            },
            composerPolicyFacts: runtimeFacts(workspaceID: composerSnapshot.workspaceID)
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: executionIdentity.turn,
            skillInjector: SkillInjector(
                store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            ).snapshotForTurn(),
            mcpBridge: mcpBridge
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: conversationID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: runtimeSnapshot
        )
        for try await _ in stream {}

        #expect(routeCounter.count == 1)
        #expect(provider.sendCount == 1)
        #expect(provider.streamCount == 0)
        #expect(contextCounter.count == 0)
        #expect(mcpDiscoveryCounter.count == 1)
        #expect(mcpCallCounter.count == 0)
        #expect(toolExecutionCounter.count == 0)
    }

    @Test("snapshot freezes Skill projection and remains bound to one turn")
    func snapshotFreezesSkillProjection() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills"))
        let skill = try store.importSkill(content: """
        ---
        name: runtime-snapshot-skill
        description: runtime snapshot focused contract
        version: 1
        ---
        frozen runtime body
        """)
        let turn = AgentTurnIdentity(sessionID: "session", turnID: 7, messageID: "message")
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: store).snapshotForTurn(),
            mcpBridge: nil
        )

        store.setEnabled(skill.id, enabled: false)
        let nextSnapshot = ChatTurnRuntimeSnapshot(
            turn: AgentTurnIdentity(sessionID: "session", turnID: 8, messageID: "next"),
            skillInjector: SkillInjector(store: store).snapshotForTurn(),
            mcpBridge: nil
        )

        #expect(snapshot.turn == turn)
        #expect((try #require(snapshot.skillInjector)).buildInjectionFragment(for: "runtime snapshot")?.contains("frozen runtime body") == true)
        #expect(SkillInjector(store: store).buildInjectionFragment(for: "runtime snapshot") == nil)
        #expect((try #require(nextSnapshot.skillInjector)).buildInjectionFragment(for: "runtime snapshot") == nil)
    }

    @Test("Skill snapshot applies shared enablement and preserves cap receipts")
    func skillSnapshotAppliesSharedEnablementAndPreservesReceipts() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-skill-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = SkillStore(skillsRoot: parent.appendingPathComponent("skills"))
        let skill = try store.importSkill(content: """
        ---
        name: runtime-snapshot-receipt
        description: runtime snapshot receipt
        version: 1
        ---
        body exceeds cap
        """)
        let stateURL = parent.appendingPathComponent("skills-enabled.json")
        let injector = SkillInjector(
            store: store,
            maxInjectedSkills: 2,
            minimumScore: 1,
            maxInjectedCharacters: 200,
            maxCharactersPerSkill: 4
        )
        let enabledSnapshot = injector.snapshotForTurn()
        let enabledResult = enabledSnapshot.buildInjection(for: "runtime-snapshot-receipt")

        try JSONEncoder().encode(["app:\(skill.id)": false]).write(
            to: stateURL,
            options: .atomic
        )
        let disabledSnapshot = injector.snapshotForTurn()
        let disabledResult = disabledSnapshot.buildInjection(for: "runtime-snapshot-receipt")

        #expect(enabledSnapshot.maxCharactersPerSkill == 4)
        #expect(enabledResult.fragment == nil)
        #expect(enabledResult.receipts.count == 1)
        #expect(enabledResult.receipts.first?.skillID == skill.id)
        #expect(enabledResult.receipts.first?.omittedReason == "skill_character_budget")
        #expect(!enabledResult.receipts.first!.contentHash.isEmpty)
        #expect(disabledResult.fragment == nil)
        #expect(disabledResult.receipts.isEmpty)
        #expect(
            enabledSnapshot.buildInjection(for: "runtime-snapshot-receipt").receipts.count == 1
        )
    }

    @Test("frozen Skill snapshot rejects every filesystem-backed mutation")
    func frozenSkillStoreRejectsAllMutationEntryPoints() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-skill-read-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let incomingDirectory = parent.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        let incomingFile = incomingDirectory.appendingPathComponent("SKILL.md")
        let firstContent = """
        ---
        name: frozen-mutation-skill
        description: frozen mutation contract
        version: 1
        ---
        original body
        """
        let secondContent = firstContent.replacingOccurrences(
            of: "original body",
            with: "updated body"
        )
        let incomingContent = firstContent.replacingOccurrences(
            of: "frozen-mutation-skill",
            with: "incoming-frozen-skill"
        )
        try incomingContent.write(to: incomingFile, atomically: true, encoding: .utf8)

        let liveStore = SkillStore(skillsRoot: root)
        let skill = try liveStore.importSkill(content: firstContent)
        _ = try liveStore.importSkill(content: secondContent)
        let deleteIntent = try liveStore.previewDeletion(skillID: skill.id)
            .withFirstConfirmation("I reviewed this exact skill")
            .withSecondConfirmation("永久删除")
        let removeAllIntent = try liveStore.previewRemoveAll()
            .withFirstConfirmation("I reviewed every installed skill")
            .withSecondConfirmation("永久删除")
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            _ = try liveStore.deleteSkill(skill.id)
        }
        let frozenStore = liveStore.snapshotForTurn()
        let filesystemBefore = try runtimeFilesystemProjection(at: parent)
        let skillsBefore = frozenStore.allSkills()
        let contentBefore = frozenStore.rawContent(skill.id)
        let receiptBefore = frozenStore.lifecycleReceipt(for: skill.id)

        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.importSkill(from: incomingFile)
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.importSkill(content: incomingContent)
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.importSkillThroughLifecycle(
                content: incomingContent,
                reason: "frozen lifecycle import"
            )
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.approveAndActivateSkill(
                skill.id,
                approval: SkillApproval(approverID: "frozen-test"),
                reason: "must stay frozen"
            )
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.rollbackSkill(skill.id, reason: "must stay frozen")
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.deleteSkill(skill.id)
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.deleteSkill(skill.id, intent: deleteIntent)
        }
        #expect(throws: FrozenProjectionMutationError.readOnly) {
            _ = try frozenStore.removeAll(intent: removeAllIntent)
        }

        frozenStore.reload()
        frozenStore.setEnabled(skill.id, enabled: false)
        frozenStore.removeSkill(skill.id)
        frozenStore.removeAll()

        #expect(try runtimeFilesystemProjection(at: parent) == filesystemBefore)
        #expect(frozenStore.allSkills() == skillsBefore)
        #expect(frozenStore.rawContent(skill.id) == contentBefore)
        #expect(frozenStore.lifecycleReceipt(for: skill.id) == receiptBefore)
        #expect(liveStore.allSkills().map(\.id) == [skill.id])
        #expect(liveStore.rawContent(skill.id) == secondContent)
    }

    @Test("AgentLoop runtime snapshot mismatch fails before route, context, or Provider")
    func agentLoopRuntimeSnapshotIdentityMismatchFailsBeforeRouteContextOrProvider() async {
        let executionTurn = AgentTurnIdentity(
            sessionID: "session",
            turnID: 3,
            messageID: "assistant-message"
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .identityMismatch,
            executionIdentity: AgentExecutionIdentity(
                turn: executionTurn,
                operationID: "operation"
            ),
            composerSnapshot: runtimeComposerSnapshot(
                turn: executionTurn,
                workspaceID: "workspace"
            ),
            conversationID: executionTurn.sessionID,
            turnID: executionTurn.turnID,
            runtimeSnapshotTurn: AgentTurnIdentity(
                sessionID: "other-session",
                turnID: executionTurn.turnID,
                messageID: executionTurn.messageID
            )
        )
    }

    @Test("AgentLoop invalid execution identity fails before route, context, or Provider")
    func agentLoopInvalidExecutionIdentityFailsBeforeRouteContextOrProvider() async {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-invalid-session",
            turnID: 4,
            messageID: "assistant:4"
        )
        let composerSnapshot = runtimeComposerSnapshot(
            turn: turn,
            workspaceID: "runtime-agent-loop-invalid-workspace"
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: " ",
                attempt: 1
            ),
            composerSnapshot: composerSnapshot,
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "operation",
                attempt: -1
            ),
            composerSnapshot: composerSnapshot,
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )
    }

    @Test("AgentLoop snapshot with nil execution identity fails as invalid before side effects")
    func agentLoopSnapshotWithNilExecutionIdentityFailsAsInvalidBeforeRouteContextOrProvider() async {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-nil-identity-session",
            turnID: 5,
            messageID: "assistant:5"
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: nil,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: "runtime-agent-loop-nil-identity-workspace"
            ),
            conversationID: turn.sessionID,
            turnID: turn.turnID,
            runtimeSnapshotTurn: turn
        )
    }

    @Test("AgentLoop negative turn fails before route, context, or Provider")
    func agentLoopNegativeTurnFailsBeforeRouteContextOrProvider() async {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-negative-turn-session",
            turnID: -1,
            messageID: "assistant:-1"
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "runtime-agent-loop-negative-turn-operation"
            ),
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: "runtime-agent-loop-negative-turn-workspace"
            ),
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )
    }

    @Test("AgentLoop zero turn and zero attempt remain valid")
    func agentLoopZeroTurnAndZeroAttemptRemainValid() async throws {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-zero-valid-session",
            turnID: 0,
            messageID: "assistant:0"
        )
        try await expectAgentLoopIdentityAcceptanceReachesProvider(
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "runtime-agent-loop-zero-valid-operation",
                attempt: 0
            ),
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: "runtime-agent-loop-zero-valid-workspace"
            ),
            conversationID: nil,
            turnID: 0
        )
    }

    @Test("AgentLoop nil conversation and turn remain valid")
    func agentLoopNilConversationAndTurnRemainValid() async throws {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-nil-caller-session",
            turnID: 7,
            messageID: "assistant:7"
        )
        try await expectAgentLoopIdentityAcceptanceReachesProvider(
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "runtime-agent-loop-nil-caller-operation",
                attempt: 1
            ),
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: "runtime-agent-loop-nil-caller-workspace"
            ),
            conversationID: nil,
            turnID: nil
        )
    }

    @Test("AgentLoop identity error precedence is deterministic")
    func agentLoopIdentityErrorPrecedenceIsDeterministic() async {
        let invalidTurn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-precedence-session",
            turnID: -1,
            messageID: "assistant:-1"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: invalidTurn,
            operationID: "runtime-agent-loop-precedence-operation",
            attempt: -1
        )
        let composerSnapshot = runtimeComposerSnapshot(
            turn: invalidTurn,
            workspaceID: "runtime-agent-loop-precedence-workspace"
        )

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .missingRequiredSnapshot,
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot,
            conversationID: "runtime-agent-loop-precedence-other-session",
            turnID: 99,
            includesRuntimeSnapshot: false,
            requiresRuntimeSnapshot: true
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .identityMismatch,
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot,
            conversationID: "runtime-agent-loop-precedence-other-session",
            turnID: 99,
            runtimeSnapshotTurn: AgentTurnIdentity(
                sessionID: "runtime-agent-loop-precedence-snapshot-session",
                turnID: invalidTurn.turnID,
                messageID: invalidTurn.messageID
            )
        )
        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: runtimeComposerSnapshot(
                turn: AgentTurnIdentity(
                    sessionID: invalidTurn.sessionID,
                    turnID: invalidTurn.turnID,
                    messageID: "assistant:precedence-other"
                ),
                workspaceID: composerSnapshot.workspaceID
            ),
            conversationID: "runtime-agent-loop-precedence-other-session",
            turnID: 99
        )
    }

    @Test("AgentLoop Composer triple mismatch fails before route, context, or Provider")
    func agentLoopComposerExecutionIdentityMismatchFailsBeforeRouteContextOrProvider() async {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-composer-session",
            turnID: 5,
            messageID: "assistant:5"
        )
        let executionIdentity = AgentExecutionIdentity(turn: turn)

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: runtimeComposerSnapshot(
                turn: AgentTurnIdentity(
                    sessionID: "runtime-agent-loop-other-session",
                    turnID: turn.turnID,
                    messageID: turn.messageID
                ),
                workspaceID: "runtime-agent-loop-composer-workspace"
            ),
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: runtimeComposerSnapshot(
                turn: AgentTurnIdentity(
                    sessionID: turn.sessionID,
                    turnID: turn.turnID + 1,
                    messageID: turn.messageID
                ),
                workspaceID: "runtime-agent-loop-composer-workspace"
            ),
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: runtimeComposerSnapshot(
                turn: AgentTurnIdentity(
                    sessionID: turn.sessionID,
                    turnID: turn.turnID,
                    messageID: "assistant:other"
                ),
                workspaceID: "runtime-agent-loop-composer-workspace"
            ),
            conversationID: turn.sessionID,
            turnID: turn.turnID
        )
    }

    @Test("AgentLoop conversation and turn mismatch fails before route, context, or Provider")
    func agentLoopConversationAndTurnMismatchFailsBeforeRouteContextOrProvider() async {
        let turn = AgentTurnIdentity(
            sessionID: "runtime-agent-loop-conversation-session",
            turnID: 6,
            messageID: "assistant:6"
        )
        let executionIdentity = AgentExecutionIdentity(turn: turn)
        let composerSnapshot = runtimeComposerSnapshot(
            turn: turn,
            workspaceID: "runtime-agent-loop-conversation-workspace"
        )

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot,
            conversationID: "runtime-agent-loop-other-conversation",
            turnID: turn.turnID
        )

        await expectAgentLoopIdentityRejectionBeforeSideEffects(
            expectedError: .invalidExecutionIdentity,
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot,
            conversationID: turn.sessionID,
            turnID: turn.turnID + 1
        )
    }

    @Test("protocol default snapshot witness fails closed instead of dropping snapshot")
    func defaultSnapshotWitnessFailsClosedBeforeProvider() async throws {
        let provider = RuntimeSnapshotProvider()
        let engine: any ChatAgentEngine = LegacyRuntimeSnapshotDroppingEngine()
        let turn = AgentTurnIdentity(
            sessionID: "runtime-default-witness-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let store = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("unified-turn-default-witness-\(UUID().uuidString)", isDirectory: true)
        )
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: store).snapshotForTurn(),
            mcpBridge: nil
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.missingRequiredSnapshot) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: turn,
                    workspaceID: "runtime-default-witness-workspace"
                ),
                executionIdentity: AgentExecutionIdentity(turn: turn),
                turnRuntimeSnapshot: snapshot
            )
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    @Test("fallback existential rejects snapshot identity mismatch before Provider access")
    func fallbackExistentialRejectsSnapshotMismatchBeforeProvider() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let executionTurn = AgentTurnIdentity(
            sessionID: "runtime-fallback-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let snapshotTurn = AgentTurnIdentity(
            sessionID: executionTurn.sessionID,
            turnID: executionTurn.turnID + 1,
            messageID: executionTurn.messageID
        )
        let store = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("unified-turn-fallback-\(UUID().uuidString)", isDirectory: true)
        )
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: snapshotTurn,
            skillInjector: SkillInjector(store: store).snapshotForTurn(),
            mcpBridge: nil
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.identityMismatch) {
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: executionTurn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: executionTurn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: executionTurn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: AgentExecutionIdentity(turn: executionTurn),
                turnRuntimeSnapshot: snapshot
            )
            for try await _ in stream {}
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    @Test("fallback explicit snapshot witness accepts matching identity without MCP access")
    func fallbackExplicitSnapshotWitnessAcceptsMatchWithoutMCPAccess() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-match-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let turn = AgentTurnIdentity(
            sessionID: "runtime-fallback-match-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let store = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("unified-turn-fallback-match-\(UUID().uuidString)", isDirectory: true)
        )
        let liveBridge = MutableRuntimeMCPBridge()
        let scopedBridge = TurnScopedMCPToolBridge(base: liveBridge)
        let runtimeSnapshot = try ProviderRuntimeSnapshot(
            providerID: provider.name,
            modelID: provider.model.id,
            readinessEvidenceID: "runtime-fallback-match-evidence",
            applyReceiptID: "provider-readiness-apply:runtime-fallback-match-apply",
            capabilities: provider.capabilities
        )
        let frozenRoute = try ProviderRuntimeRoute(
            snapshot: runtimeSnapshot,
            primary: provider
        )
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: store).snapshotForTurn(),
            mcpBridge: try scopedBridge.snapshotForTurn(),
            providerRuntimeRoute: frozenRoute,
            requiresProviderRuntimeRoute: true
        )
        liveBridge.response = "live-response"

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: AgentExecutionIdentity(turn: turn),
            turnRuntimeSnapshot: snapshot
        )
        for try await _ in stream {}

        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 1)
        #expect(liveBridge.recorder.calls.isEmpty)
    }

    @Test("fallback explicit execution identity witness rejects session mismatch before Provider access")
    func fallbackExplicitExecutionIdentityWitnessRejectsSessionMismatchBeforeProvider() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-execution-mismatch-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let composerTurn = AgentTurnIdentity(
            sessionID: "runtime-fallback-execution-mismatch-session",
            turnID: 2,
            messageID: "canonical-message:2"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "runtime-fallback-execution-other-session",
                turnID: composerTurn.turnID,
                messageID: composerTurn.messageID
            ),
            operationID: "runtime-fallback-execution-mismatch-operation",
            attempt: 1
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.invalidExecutionIdentity) {
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: executionIdentity.turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: executionIdentity.turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: composerTurn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: executionIdentity
            )
            for try await _ in stream {}
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    @Test("fallback explicit execution identity witness rejects composer mismatch before Provider access")
    func fallbackExplicitExecutionIdentityWitnessRejectsComposerMismatchBeforeProvider() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-message-mismatch-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let composerTurn = AgentTurnIdentity(
            sessionID: "runtime-fallback-message-mismatch-session",
            turnID: 2,
            messageID: "composer-message:2"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: composerTurn.sessionID,
                turnID: composerTurn.turnID,
                messageID: "assistant-message:2"
            ),
            operationID: "runtime-fallback-message-mismatch-operation",
            attempt: 1
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.invalidExecutionIdentity) {
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: executionIdentity.turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: executionIdentity.turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: composerTurn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: executionIdentity
            )
            for try await _ in stream {}
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    @Test("fallback explicit execution identity witness rejects turn mismatch before Provider access")
    func fallbackExplicitExecutionIdentityWitnessRejectsTurnMismatchBeforeProvider() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-turn-mismatch-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let composerTurn = AgentTurnIdentity(
            sessionID: "runtime-fallback-turn-mismatch-session",
            turnID: 2,
            messageID: "canonical-message:2"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: composerTurn.sessionID,
                turnID: 3,
                messageID: composerTurn.messageID
            ),
            operationID: "runtime-fallback-turn-mismatch-operation",
            attempt: 1
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.invalidExecutionIdentity) {
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: executionIdentity.turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: executionIdentity.turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: composerTurn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: executionIdentity
            )
            for try await _ in stream {}
        }
        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    @Test("fallback explicit execution identity witness accepts matching composer identity")
    func fallbackExplicitExecutionIdentityWitnessAcceptsMatchingComposerIdentity() async throws {
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: "runtime-fallback-execution-match-workspace")
        let engine: any ChatAgentEngine = FallbackChatEngine(composerPolicyFacts: facts)
        let turn = AgentTurnIdentity(
            sessionID: "runtime-fallback-execution-match-session",
            turnID: 3,
            messageID: "assistant-message:3"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "runtime-fallback-execution-match-operation",
            attempt: 2
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: executionIdentity
        )
        for try await _ in stream {}

        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 1)
    }

    @Test("ChatStore fallback production path uses Composer execution identity and separate assistant writeback identity")
    func chatStoreFallbackProductionPathUsesComposerExecutionIdentityAndSeparateAssistantWriteback() async throws {
        let chat = ChatStore()
        let provider = RuntimeSnapshotProvider()
        let facts = runtimeFacts(workspaceID: chat.composerWorkspaceID)
        let engine = RecordingFallbackChatEngine(
            delegate: FallbackChatEngine(composerPolicyFacts: facts)
        )
        let skillRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "unified-turn-chat-fallback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: skillRoot) }
        let skillStore = SkillStore(skillsRoot: skillRoot)
        var captureCount = 0
        var capturedFactoryTurn: AgentTurnIdentity?

        chat.configureComposerPolicy(facts)
        chat.agentEngine = engine
        chat.streamingProviderOverride = provider
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            captureCount += 1
            capturedFactoryTurn = turn
            return ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
        }
        chat.draftText = "normal fallback send"

        chat.submitComposer()

        for _ in 0..<100 where provider.streamCount == 0 || chat.isActiveSessionStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.streamCount == 1)
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        let factoryTurn = try #require(capturedFactoryTurn)
        let delivery = try #require(engine.recordedDeliveries.first)
        let userMessage = try #require(chat.messages.last(where: { $0.role == .user }))
        let assistantMessage = try #require(chat.messages.last(where: { $0.role == .assistant }))
        let composerTurn = AgentTurnIdentity(
            sessionID: delivery.composerSnapshot.sessionID,
            turnID: delivery.composerSnapshot.turnID,
            messageID: delivery.composerSnapshot.messageID
        )

        #expect(captureCount == 1)
        #expect(engine.recordedDeliveries.count == 1)
        #expect(userMessage.id.uuidString == snapshot.messageID)
        #expect(assistantMessage.id != userMessage.id)
        #expect(assistantMessage.id.uuidString != snapshot.messageID)
        #expect(factoryTurn.sessionID == snapshot.sessionID)
        #expect(factoryTurn.turnID == snapshot.turnID)
        #expect(factoryTurn.messageID == snapshot.messageID)
        #expect(factoryTurn.sessionID == delivery.composerSnapshot.sessionID)
        #expect(factoryTurn.turnID == delivery.composerSnapshot.turnID)
        #expect(factoryTurn.messageID == delivery.composerSnapshot.messageID)
        #expect(delivery.composerSnapshot.messageID == snapshot.messageID)
        #expect(delivery.executionIdentity.turn == composerTurn)
        #expect(delivery.turnRuntimeSnapshot.turn == composerTurn)
        #expect(delivery.executionIdentity.turn == delivery.turnRuntimeSnapshot.turn)
        #expect(delivery.turnRuntimeSnapshot.mcpBridge == nil)
        #expect(delivery.conversationID == composerTurn.sessionID)
        #expect(delivery.turnID == composerTurn.turnID)
        #expect(provider.sendCount == 0)
        #expect(!chat.isActiveSessionStreaming)
    }

    @Test("ChatStore captures once and delivers the exact frozen turn identity")
    func chatStoreCapturesOnceWithoutLiveSkillFallback() async throws {
        let chat = ChatStore()
        let engine = SnapshotPromptRecordingEngine()
        chat.agentEngine = engine
        chat.streamingProviderOverride = RuntimeSnapshotProvider()
        var captureCount = 0
        var capturedFactoryTurn: AgentTurnIdentity?
        let store = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("unified-turn-chat-\(UUID().uuidString)", isDirectory: true)
        )
        let skill = try store.importSkill(content: """
        ---
        name: runtime-snapshot-skill
        description: runtime snapshot focused contract
        version: 1
        ---
        live-only runtime body
        """)
        store.setEnabled(skill.id, enabled: false)
        chat.skillInjector = { text in
            SkillInjector(store: store).buildInjectionFragment(for: text)
        }
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            captureCount += 1
            capturedFactoryTurn = turn
            let snapshot = ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: store).snapshotForTurn(),
                mcpBridge: nil
            )
            store.setEnabled(skill.id, enabled: true)
            return snapshot
        }
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "runtime-snapshot-revision",
            grantEpoch: "runtime-snapshot-epoch",
            leaseID: "runtime-snapshot-lease",
            expiresAt: Date().addingTimeInterval(60)
        )
        chat.configureComposerPolicy(facts)
        chat.draftText = "runtime-snapshot-skill"
        chat.sendDraft()

        for _ in 0..<100 where engine.recordedDeliveries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(captureCount == 1)
        let factoryTurn = try #require(capturedFactoryTurn)
        let delivery = try #require(engine.recordedDeliveries.first)
        #expect(delivery.executionTurn == factoryTurn)
        #expect(delivery.snapshotTurn == factoryTurn)
        #expect(delivery.executionTurn == delivery.snapshotTurn)
        #expect(!delivery.prompt.contains("live-only runtime body"))
    }

    @Test("context Skill identifiers use the frozen store and refresh next turn")
    func contextSkillIdentifiersFreezeAndRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "runtime-context-session"
        let projectID = "runtime-context-project"
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(
            id: sessionID,
            projectID: projectID,
            projectName: "Runtime",
            workingDirectory: root.path
        )
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let scope = MemoryScope(sessionID: sessionID, projectID: projectID)
        let imported = try skillStore.importSkillThroughLifecycle(
            content: """
            ---
            name: runtime-context-skill
            description: runtime context snapshot
            version: 1
            ---
            frozen context body
            """,
            reason: "runtime context snapshot",
            scope: scope,
            approval: SkillApproval(approverID: "runtime-test", scope: scope)
        )
        let manifestStore = try ContextManifestStore(
            persistenceURL: root.appendingPathComponent("manifests.json")
        )
        let facts = runtimeFacts(workspaceID: "runtime-context-workspace")
        let engine = AgentLoopChatEngine(
            contextManifestStore: manifestStore,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: MemoryStore(directory: root),
                skillStore: skillStore,
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )
        let firstTurn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: 1,
            messageID: "assistant:1"
        )
        let firstSnapshot = ChatTurnRuntimeSnapshot(
            turn: firstTurn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil
        )
        skillStore.setEnabled(imported.skill.id, enabled: false)

        let firstIdentity = AgentExecutionIdentity(turn: firstTurn)
        let firstStream = try await engine.streamReply(
            provider: RuntimeSnapshotProvider(),
            history: [ChatMessageUI(role: .user, content: "runtime context")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: firstTurn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: firstTurn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: firstIdentity,
            turnRuntimeSnapshot: firstSnapshot
        )
        for try await _ in firstStream {}

        let secondTurn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: 2,
            messageID: "assistant:2"
        )
        let secondSnapshot = ChatTurnRuntimeSnapshot(
            turn: secondTurn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil
        )
        let secondIdentity = AgentExecutionIdentity(turn: secondTurn)
        let secondStream = try await engine.streamReply(
            provider: RuntimeSnapshotProvider(),
            history: [ChatMessageUI(role: .user, content: "runtime context")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: secondTurn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: secondTurn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: secondIdentity,
            turnRuntimeSnapshot: secondSnapshot
        )
        for try await _ in secondStream {}

        let firstManifest = try #require(manifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: firstIdentity)))
        let secondManifest = try #require(manifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: secondIdentity)))
        #expect(firstManifest.snapshot.skillIdentifiers == [imported.skill.id])
        #expect(secondManifest.snapshot.skillIdentifiers.isEmpty)
    }

    @Test("MCP discovery and execution share one frozen bridge and refresh next turn")
    func mcpDiscoveryExecutionFreezeAndRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let liveBridge = MutableRuntimeMCPBridge()
        let scopedBridge = TurnScopedMCPToolBridge(base: liveBridge)
        let facts = runtimeFacts(
            workspaceID: "runtime-mcp-workspace",
            capabilities: [liveBridge.tool.fullName]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: runtimePolicyBoundExecutor(root: root, mcpBridge: scopedBridge),
            maxIterations: 3,
            approvalDelegate: RuntimeApprovalDelegate(),
            mcpBridge: scopedBridge,
            toolExecutionFactLedger: ledger,
            composerPolicyFacts: facts
        )
        let firstTurn = AgentTurnIdentity(
            sessionID: "runtime-mcp-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let firstSnapshot = ChatTurnRuntimeSnapshot(
            turn: firstTurn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: try scopedBridge.snapshotForTurn()
        )
        liveBridge.enabled = false
        liveBridge.response = "live-response"
        let firstProvider = RuntimeMCPProvider(requestedToolName: liveBridge.tool.fullName)

        let firstIdentity = AgentExecutionIdentity(turn: firstTurn, attempt: 1)
        let firstStream = try await engine.streamReply(
            provider: firstProvider,
            history: [ChatMessageUI(role: .user, content: "call runtime MCP")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: firstTurn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: firstTurn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: firstTurn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: firstIdentity,
            turnRuntimeSnapshot: firstSnapshot
        )
        var firstStopReasons: [String] = []
        var firstStreamError: (any Error)?
        do {
            for try await event in firstStream {
                if case .done(let reason) = event { firstStopReasons.append(reason.rawValue) }
            }
        } catch { firstStreamError = error }
        let firstFacts = ledger.facts.filter {
            $0.executionIdentity == firstIdentity && $0.toolCallID == "runtime-mcp-call"
        }
        let firstErrorType = firstStreamError.map { String(reflecting: type(of: $0)) } ?? "none"
        let firstErrorDescription = firstStreamError.map { String(String(describing: $0).prefix(512)) } ?? "none"
        // Report the frozen fixture's dispatch capability without manufacturing
        // an invocation receipt or replacing the production executor's fence.
        let frozenBridge = try #require(firstSnapshot.mcpBridge)
        let observedScopedBridge: any MCPToolBridge = scopedBridge
        let unsupportedInvocation = MCPToolBridgeSnapshotError.invocationIdentityUnsupported as NSError
        let firstDiagnostic: [String: Any] = [
            "frozen_bridge_type": String(reflecting: type(of: frozenBridge)),
            "frozen_bridge_invocation_fencing": frozenBridge is any MCPToolBridgeInvocationFencing,
            "scoped_bridge_invocation_fencing": observedScopedBridge is any MCPToolBridgeInvocationFencing,
            "invocation_unsupported_error_domain": unsupportedInvocation.domain,
            "invocation_unsupported_error_code": unsupportedInvocation.code,
            "provider_calls": firstProvider.receivedToolNames.count,
            "stream_done": firstStopReasons,
            "stream_error_type": firstErrorType,
            "stream_error": firstErrorDescription,
            "synthetic_tool_feedback": firstProvider.receivedToolFeedback,
            "receipt_count": firstFacts.count,
            "receipt_ids": firstFacts.map(\.receiptID),
            "receipt_statuses": firstFacts.map { $0.status.rawValue }
        ]
        let diagnosticData = try JSONSerialization.data(withJSONObject: firstDiagnostic, options: [.sortedKeys])
        print("D02_MCP_FIRST_STREAM " + String(decoding: diagnosticData, as: UTF8.self))
        #expect(!firstProvider.receivedToolNames.isEmpty, "D02 MCP provider was never called")
        #expect(firstStreamError == nil, "D02 MCP first stream error type: \(firstErrorType)")
        #expect(!firstStopReasons.isEmpty, "D02 MCP first stream had no done event")
        #expect(firstFacts.count == 1, "D02 MCP first call must retain exactly one terminal ledger receipt")
        #expect(firstFacts.allSatisfy { $0.status == .succeeded },
                "D02 MCP first receipt statuses: \(firstFacts.map { $0.status.rawValue })")
        if let firstStreamError { throw firstStreamError } // Preserve the original throwing-stream contract.

        let secondTurn = AgentTurnIdentity(
            sessionID: firstTurn.sessionID,
            turnID: 2,
            messageID: "assistant:2"
        )
        let secondSnapshot = ChatTurnRuntimeSnapshot(
            turn: secondTurn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: try scopedBridge.snapshotForTurn()
        )
        let secondProvider = RuntimeMCPProvider(requestedToolName: liveBridge.tool.fullName)
        let secondStream = try await engine.streamReply(
            provider: secondProvider,
            history: [ChatMessageUI(role: .user, content: "call runtime MCP")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: secondTurn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: secondTurn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: secondTurn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: AgentExecutionIdentity(turn: secondTurn, attempt: 1),
            turnRuntimeSnapshot: secondSnapshot
        )
        for try await _ in secondStream {}

        #expect(!secondProvider.receivedToolNames.isEmpty, "D02 MCP refresh provider was never called")
        #expect(firstProvider.receivedToolNames.allSatisfy {
            $0.contains(liveBridge.tool.fullName)
        })
        #expect(liveBridge.recorder.calls == ["frozen-response"])
        #expect(secondProvider.receivedToolNames.allSatisfy {
            !$0.contains(liveBridge.tool.fullName)
        })

        // Exercise the fixture's fence separately from the frozen turn recorder.
        let fenceRecorder = RuntimeMCPCallRecorder()
        let fenceBridge = FrozenRuntimeMCPBridge(
            tool: liveBridge.tool, enabled: true, response: "fence-control", recorder: fenceRecorder
        )
        do {
            _ = try await fenceBridge.callMCPTool(
                fullName: liveBridge.tool.fullName, arguments: nil,
                invocation: MCPToolInvocationIdentity(correlationID: "", attemptID: "control")
            )
            Issue.record("Invalid fixture invocation was accepted")
        } catch {
            #expect((error as? MCPToolInvocationFenceError) == .invalidIdentity)
        }
        #expect(fenceRecorder.calls.isEmpty)
        let controlInvocation = MCPToolInvocationIdentity(correlationID: "fence-control", attemptID: "1")
        let controlResponse = try await fenceBridge.callMCPTool(
            fullName: liveBridge.tool.fullName, arguments: nil, invocation: controlInvocation
        )
        #expect(controlResponse == "fence-control")
        do {
            _ = try await fenceBridge.callMCPTool(
                fullName: liveBridge.tool.fullName, arguments: nil, invocation: controlInvocation
            )
            Issue.record("Duplicate fixture invocation was accepted")
        } catch {
            #expect((error as? MCPToolInvocationFenceError) == .duplicate(controlInvocation))
        }
        #expect(fenceRecorder.calls == ["fence-control"])
    }

    @Test("nil MCP snapshot freezes discovery and execution to no MCP")
    func nilMCPSnapshotDoesNotFallBackToLiveBridge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-nil-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let liveBridge = MutableRuntimeMCPBridge()
        let scopedBridge = TurnScopedMCPToolBridge(base: liveBridge)
        let facts = runtimeFacts(
            workspaceID: "runtime-nil-mcp-workspace",
            capabilities: [liveBridge.tool.fullName]
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: runtimePolicyBoundExecutor(root: root, mcpBridge: scopedBridge),
            maxIterations: 3,
            approvalDelegate: RuntimeApprovalDelegate(),
            mcpBridge: scopedBridge,
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "runtime-nil-mcp-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil
        )
        let provider = RuntimeMCPProvider(requestedToolName: liveBridge.tool.fullName)

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "do not call live MCP")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: AgentExecutionIdentity(turn: turn),
            turnRuntimeSnapshot: snapshot
        )
        for try await _ in stream {}

        #expect(provider.receivedToolNames.allSatisfy {
            !$0.contains(liveBridge.tool.fullName)
        })
        #expect(liveBridge.recorder.calls.isEmpty)
    }

    @Test("production engine rejects a missing snapshot before route or Provider")
    func missingSnapshotFailsClosedBeforeProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let facts = runtimeFacts(workspaceID: "runtime-missing-workspace")
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "runtime-missing-session",
            turnID: 1,
            messageID: "assistant:1"
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.missingRequiredSnapshot) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "hello")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: turn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: AgentExecutionIdentity(turn: turn)
            )
        }
        #expect(routeCounter.count == 0)
        #expect(provider.sendCount == 0)
    }

    @Test("production turn route snapshot failure fails closed before route builder or Provider")
    func missingProviderRuntimeRouteFailsClosedBeforeProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-route-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let facts = runtimeFacts(workspaceID: "runtime-route-missing-workspace")
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "runtime-route-missing-session",
            turnID: 1,
            messageID: "assistant:route-missing"
        )
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            ).snapshotForTurn(),
            mcpBridge: nil,
            requiresProviderRuntimeRoute: true
        )

        await #expect(throws: ProviderRuntimeSnapshotError.missingPrimaryProvenance) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "route missing")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turn.turnID,
                composerSnapshot: runtimeComposerSnapshot(
                    turn: turn,
                    workspaceID: facts.workspaceID
                ),
                executionIdentity: AgentExecutionIdentity(turn: turn),
                turnRuntimeSnapshot: snapshot
            )
        }
        #expect(routeCounter.count == 0)
        #expect(provider.sendCount == 0)
    }

    @Test("legacy production overload rejects missing exact runtime snapshot")
    func legacyProductionOverloadRejectsMissingExactRuntimeSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-legacy-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let discoveryCounter = RuntimeRouteCounter()
        let bridge = RuntimeBoundaryMCPBridge(
            discoveryCounter: discoveryCounter,
            callCounter: RuntimeRouteCounter()
        )
        let facts = runtimeFacts(workspaceID: "runtime-legacy-missing-workspace")
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            mcpBridge: bridge,
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.missingRequiredSnapshot) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "legacy")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: "runtime-legacy-missing-session",
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 1
            )
        }
        #expect(routeCounter.count == 0)
        #expect(discoveryCounter.count == 0)
        #expect(provider.sendCount == 0)
    }

    @Test("legacy production overload never admits a non-snapshotting MCP bridge")
    func legacyProductionOverloadNeverAdmitsNonSnapshottingMCPBridge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-legacy-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RuntimeSnapshotProvider()
        let routeCounter = RuntimeRouteCounter()
        let discoveryCounter = RuntimeRouteCounter()
        let baseBridge = RuntimeBoundaryMCPBridge(
            discoveryCounter: discoveryCounter,
            callCounter: RuntimeRouteCounter()
        )
        let scopedBridge = TurnScopedMCPToolBridge(base: baseBridge)
        let facts = runtimeFacts(workspaceID: "runtime-legacy-mcp-workspace")
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { box in
                routeCounter.increment()
                return box
            },
            mcpBridge: scopedBridge,
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.missingRequiredSnapshot) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "legacy MCP")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: "runtime-legacy-mcp-session",
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 1
            )
        }
        #expect(routeCounter.count == 0)
        #expect(discoveryCounter.count == 0)
        #expect(provider.sendCount == 0)
    }

    @Test("turn snapshot admission never returns a live non-snapshotting MCP bridge")
    func turnSnapshotAdmissionNeverReturnsLiveNonSnapshottingMCPBridge() throws {
        let baseBridge = RuntimeBoundaryMCPBridge(
            discoveryCounter: RuntimeRouteCounter(),
            callCounter: RuntimeRouteCounter()
        )
        let scopedBridge = TurnScopedMCPToolBridge(base: baseBridge)

        #expect(throws: MCPToolBridgeSnapshotError.unsupportedBase) {
            _ = try scopedBridge.snapshotForTurn()
        }
    }

    @Test("MCP discovery cannot expand frozen Composer grants")
    func mcpDiscoveryCannotExpandFrozenComposerGrants() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-frozen-grants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let liveBridge = MutableRuntimeMCPBridge()
        let scopedBridge = TurnScopedMCPToolBridge(base: liveBridge)
        let facts = runtimeFacts(workspaceID: "runtime-frozen-grants-workspace")
        let engine = AgentLoopChatEngine(
            toolExecutor: runtimePolicyBoundExecutor(root: root, mcpBridge: scopedBridge),
            maxIterations: 3,
            approvalDelegate: RuntimeApprovalDelegate(),
            mcpBridge: scopedBridge,
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "runtime-frozen-grants-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let snapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: try scopedBridge.snapshotForTurn()
        )
        let provider = RuntimeMCPProvider(requestedToolName: liveBridge.tool.fullName)

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "do not grant runtime MCP")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: AgentExecutionIdentity(turn: turn),
            turnRuntimeSnapshot: snapshot
        )
        for try await _ in stream {}

        #expect(provider.receivedToolNames.contains {
            $0.contains(liveBridge.tool.fullName)
        })
        #expect(liveBridge.recorder.calls.isEmpty)
        #expect(facts.knownCapabilities.isEmpty)
        #expect(facts.grantedCapabilities.isEmpty)
    }

    @Test("production AgentLoop rejects undeclared MCP before executor or approval receipt")
    func productionAgentLoopRejectsUndeclaredMCPBeforeExecutorOrApprovalReceipt() async throws {
        let toolName = "mcp_runtime_echo"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-turn-production-grant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptCount = RuntimeRouteCounter()
        let turn = AgentTurnIdentity(
            sessionID: "runtime-undeclared-mcp-session",
            turnID: 1,
            messageID: "assistant:1"
        )
        let bridge = MutableRuntimeMCPBridge()
        let scopedBridge = TurnScopedMCPToolBridge(base: bridge)
        let facts = runtimeFacts(
            workspaceID: "runtime-undeclared-mcp-workspace",
            capabilities: []
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: runtimePolicyBoundExecutor(root: root, mcpBridge: scopedBridge),
            maxIterations: 3,
            approvalDelegate: RuntimeApprovalDelegate(),
            mcpBridge: scopedBridge,
            composerPolicyFacts: facts,
            onComposerApprovalReceipt: { _ in receiptCount.increment() }
        )
        let provider = RuntimeMCPProvider(requestedToolName: toolName)
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            ).snapshotForTurn(),
            mcpBridge: try scopedBridge.snapshotForTurn()
        )
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "拒绝未声明 MCP")],
            systemPrompt: "test",
            maxTokens: 64,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: runtimeComposerSnapshot(
                turn: turn,
                workspaceID: facts.workspaceID
            ),
            executionIdentity: AgentExecutionIdentity(turn: turn),
            turnRuntimeSnapshot: runtimeSnapshot
        )

        for try await _ in stream {}
        #expect(provider.receivedToolNames.contains {
            $0.contains(toolName)
        })
        #expect(receiptCount.count == 0)
        #expect(bridge.recorder.calls.isEmpty)
    }
}
