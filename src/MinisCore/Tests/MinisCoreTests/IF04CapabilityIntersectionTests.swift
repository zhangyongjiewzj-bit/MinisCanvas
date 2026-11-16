import Foundation
import Testing
@testable import MinisCore

// IF-04 RED contract tests. These doubles never perform I/O or network calls.

actor IF04CallCounter {
    private(set) var providerCalls = 0
    private(set) var toolCalls = 0
    private(set) var mcpCalls = 0
    private(set) var offeredToolNames: [String] = []

    func providerCall(toolNames: [String] = []) -> Int {
        providerCalls += 1
        offeredToolNames.append(contentsOf: toolNames)
        return providerCalls
    }

    func toolCall() {
        toolCalls += 1
    }

    func mcpCall() {
        mcpCalls += 1
    }
}

final class IF04Provider: LLMProvider, @unchecked Sendable {
    let name = "IF04-memory-provider"
    var model: LLMModel
    let capabilities: Set<ProviderCapability>
    let responseText: String
    let responseAfterFirst: String?
    let counter: IF04CallCounter

    init(
        capabilities: Set<ProviderCapability>,
        responseText: String = "done",
        responseAfterFirst: String? = nil,
        counter: IF04CallCounter = IF04CallCounter()
    ) {
        self.capabilities = capabilities
        self.model = .claudeHaiku45
        self.responseText = responseText
        self.responseAfterFirst = responseAfterFirst
        self.counter = counter
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let call = await counter.providerCall()
        let response = call == 1 ? responseText : (responseAfterFirst ?? responseText)
        return LLMResponse(text: response, stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let call = await counter.providerCall(toolNames: tools.map(\.name))
        let response = call == 1 ? responseText : (responseAfterFirst ?? responseText)
        return LLMResponse(text: response, stopReason: nil, usage: nil)
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

final class IF04BlockingProvider: LLMProvider, @unchecked Sendable {
    let name = "IF04-blocking-provider"
    var model: LLMModel = .claudeHaiku45
    let capabilities: Set<ProviderCapability> = [.streaming]
    let counter: IF04CallCounter

    init(counter: IF04CallCounter) {
        self.counter = counter
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        _ = await counter.providerCall()
        try await Task.sleep(for: .seconds(10))
        return LLMResponse(text: "late", stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        _ = await counter.providerCall(toolNames: tools.map(\.name))
        try await Task.sleep(for: .seconds(10))
        return LLMResponse(text: "late", stopReason: nil, usage: nil)
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

final class IF04ToolExecutor: ToolExecutor, @unchecked Sendable {
    let counter: IF04CallCounter

    init(counter: IF04CallCounter) {
        self.counter = counter
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        await counter.toolCall()
        if name.hasPrefix("mcp_") {
            await counter.mcpCall()
        }
        return "tool-ok"
    }
}

private func if04Envelope(name: String) -> String {
    let object: [String: Any] = [
        "tool_calls": [[
            "id": "if04-call",
            "name": name,
            "input": [String: Any](),
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

struct IF04CapabilityIntersectionTests {
    @Test func intersectionIsParentAndRequestAndPolicy() {
        let result = AgentCapabilityIntersection.resolve(
            parentCapabilities: [.streaming, .tools, .vision],
            requestedCapabilities: [.tools, .audio],
            policyCapabilities: [.tools, .vision]
        )

        #expect(result.grantedCapabilities == [.tools])
        #expect(result.missingCapabilities == [.audio])
        #expect(!result.isAllowed)
    }

    @Test func catalogUnknownAndRecursiveRequestsFailClosed() {
        let catalogLimited = AgentCapabilityIntersection.resolve(
            parentCapabilities: [.tools, .audio],
            requestedCapabilities: [.tools, .audio],
            policyCapabilities: [.tools, .audio],
            catalogCapabilities: [.tools]
        )
        #expect(catalogLimited.grantedCapabilities == [.tools])
        #expect(catalogLimited.missingCapabilities == [.audio])
        #expect(!catalogLimited.isAllowed)

        let unknown = AgentCapabilityIntersection.resolve(
            parentCapabilities: [.tools],
            requestedCapabilityNames: ["tools", "future_capability"],
            policyCapabilities: [.tools]
        )
        #expect(unknown.grantedCapabilities == [.tools])
        #expect(unknown.unknownCapabilities == ["future_capability"])
        #expect(!unknown.isAllowed)

        let recursive = AgentCapabilityIntersection.resolve(
            parentCapabilities: [.tools],
            requestedCapabilities: [.tools],
            policyCapabilities: [.tools],
            requestsOrchestration: true
        )
        #expect(recursive.grantedCapabilities == [.tools])
        #expect(!recursive.isAllowed)
    }

    @Test func childIdentityCarriesImmutableIntersectionSnapshot() throws {
        let parent = ParentRuntimeIdentity(
            sessionID: "session",
            conversationID: "conversation",
            turnID: "turn-handle:4",
            taskID: "parent-task",
            actorID: "parent"
        )
        let snapshot = ParentContextSnapshotV1(
            providerID: "provider",
            modelID: "model",
            configurationFingerprint: "fingerprint",
            conversationID: parent.conversationID
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parent,
            childSessionID: "session:child",
            childTaskID: "child-task",
            scopeID: "scope",
            requestedCapabilities: [.tools],
            parentCapabilities: [.tools, .audio],
            policyCapabilities: [.tools, .audio],
            providerSnapshot: snapshot,
            memoryScopeID: "memory",
            workingDirectory: "/tmp",
            cancelGeneration: 4,
            evidenceRoot: "evidence",
            catalogCapabilities: [.tools]
        )
        let expected = AgentCapabilityIntersection.resolve(
            parentCapabilities: [.tools, .audio],
            requestedCapabilities: [.tools],
            policyCapabilities: [.tools, .audio],
            catalogCapabilities: [.tools]
        )
        #expect(identity.capabilityIntersection == expected)
        #expect(identity.grantedCapabilities == expected.grantedCapabilities)
        #expect(identity.cancelGeneration == 4)
    }

    @Test func decodingRejectsPersistedGrantThatExceedsItsIntersection() throws {
        let parent = ParentRuntimeIdentity(
            sessionID: "session",
            conversationID: "conversation",
            turnID: "turn-handle:1",
            taskID: "parent-task",
            actorID: "parent"
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parent,
            childSessionID: "child-session",
            childTaskID: "child-task",
            scopeID: "scope",
            requestedCapabilities: [.tools],
            parentCapabilities: [.tools],
            policyCapabilities: [],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "provider",
                modelID: "model",
                configurationFingerprint: "fingerprint",
                conversationID: parent.conversationID
            ),
            memoryScopeID: "memory",
            workingDirectory: "/tmp",
            cancelGeneration: 1,
            evidenceRoot: "evidence"
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
        )
        var intersection = try #require(
            object["capabilityIntersection"] as? [String: Any]
        )
        let forgedGrant = [ProviderCapability.tools.rawValue]
        object["grantedCapabilities"] = forgedGrant
        intersection["grantedCapabilities"] = forgedGrant
        intersection["missingCapabilities"] = []
        object["capabilityIntersection"] = intersection
        let forgedSnapshot = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ChildRuntimeIdentity.self, from: forgedSnapshot)
        }
    }

    @Test func providerCapabilityMissingFailsBeforeProviderCall() async {
        let counter = IF04CallCounter()
        let provider = IF04Provider(capabilities: [.streaming], counter: counter)
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .vision],
                allowedToolNames: ["file_read"]
            )
        )
        let task = SubAgentTask(
            id: "vision-required",
            title: "vision",
            instructions: "inspect",
            requiredCapabilities: [.vision]
        )

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)

        #expect(reports[0].result == .failed(error: "CAPABILITY_UNAVAILABLE"))
        #expect(await counter.providerCalls == 0)
        #expect(await counter.toolCalls == 0)
    }

    @Test func policyMissingCapabilityFailsBeforeProviderCall() async {
        let counter = IF04CallCounter()
        let provider = IF04Provider(capabilities: [.streaming, .tools], counter: counter)
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: .denyAll
        )
        let task = SubAgentTask(
            id: "tools-denied",
            title: "tools",
            instructions: "inspect",
            requiredCapabilities: [.tools]
        )

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)

        #expect(reports[0].result == .failed(error: "CAPABILITY_UNAVAILABLE"))
        #expect(await counter.providerCalls == 0)
        #expect(await counter.toolCalls == 0)
    }

    @Test func toolPolicyDeniesBeforeBaseExecutor() async {
        let counter = IF04CallCounter()
        let provider = IF04Provider(
            capabilities: [.streaming, .tools],
            responseText: if04Envelope(name: "file_read"),
            responseAfterFirst: "done",
            counter: counter
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: []
            )
        )
        let task = SubAgentTask(
            id: "tool-denied",
            title: "tool",
            instructions: "inspect"
        )

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)

        #expect(reports[0].result.isSuccess)
        #expect(await counter.providerCalls == 2)
        #expect(await counter.toolCalls == 0)
        #expect(await counter.mcpCalls == 0)
    }

    @Test func strictPolicyOffersOnlyAllowedChildTools() async {
        let counter = IF04CallCounter()
        let provider = IF04Provider(
            capabilities: [.streaming, .tools],
            counter: counter
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            )
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "catalog", title: "catalog", instructions: "inspect")],
            strategy: .sequential
        )

        #expect(reports[0].result.isSuccess)
        #expect(await counter.offeredToolNames == ["file_read"])
    }

    @Test func mcpPolicyDeniesBeforeMCPExecutor() async {
        let counter = IF04CallCounter()
        let provider = IF04Provider(
            capabilities: [.streaming, .tools],
            responseText: if04Envelope(name: "mcp_local_lookup"),
            responseAfterFirst: "done",
            counter: counter
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            )
        )
        let task = SubAgentTask(
            id: "mcp-denied",
            title: "mcp",
            instructions: "inspect"
        )

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)

        #expect(reports[0].result.isSuccess)
        #expect(await counter.toolCalls == 0)
        #expect(await counter.mcpCalls == 0)
    }

    @Test func inheritedIdentityIsConsistentAcrossTaskRunAndReceipt() async throws {
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            profileID: "parent-profile",
            baseHost: "parent.example.test",
            wireAPI: "responses",
            reasoningConfiguration: "balanced",
            conversationID: "parent-conversation"
        )
        let store = AgentTaskStore()
        let provider = IF04Provider(capabilities: [.streaming])
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: IF04CallCounter()),
            taskStore: store,
            parentID: "parent-agent",
            parentBinding: parent
        )
        let task = SubAgentTask(id: "identity", title: "identity", instructions: "inspect")

        let reports = await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
        let receipt = try #require(store.allReceipts().first)
        let taskSnapshot = try #require(store.taskSnapshot(runID: receipt.runID))
        let attempt = try #require(store.attempts(runID: receipt.runID).first)
        let events = store.events(runID: receipt.runID)

        #expect(reports[0].result.isSuccess)
        #expect(taskSnapshot.taskID == receipt.taskID)
        #expect(attempt.runID == receipt.runID)
        #expect(Set(events.map(\.runID)) == [receipt.runID])
        #expect(taskSnapshot.parentContextSnapshotID == parent.snapshotID)
        #expect(attempt.parentContextSnapshotID == parent.snapshotID)
        #expect(events.allSatisfy { $0.parentContextSnapshotID == parent.snapshotID })
        #expect(receipt.parentContextSnapshotID == parent.snapshotID)
        #expect(taskSnapshot.providerID == parent.providerID)
        #expect(taskSnapshot.modelID == parent.modelID)
    }

    @Test func hardLimitsClampDepthConcurrencyIterationsAndBudget() {
        let orchestrator = AgentOrchestrator(
            defaultMaxConcurrent: 100,
            maxIterationsPerTask: 10_000,
            maxChildDepth: 100,
            maxChildBudgetRequests: 10_000
        )

        #expect(orchestrator.defaultMaxConcurrent == 4)
        #expect(AgentOrchestrator.hardMaxConcurrentChildren == 40)
        #expect(orchestrator.maxIterationsPerTask == AgentOrchestrator.hardMaxIterationsPerTask)
        #expect(orchestrator.maxChildDepth == AgentOrchestrator.hardMaxChildDepth)
        #expect(orchestrator.maxChildBudgetRequests == AgentOrchestrator.hardMaxChildBudgetRequests)
    }

    @Test func depthLimitFailsBeforeProviderCall() async {
        let counter = IF04CallCounter()
        let orchestrator = AgentOrchestrator(
            provider: IF04Provider(capabilities: [.streaming], counter: counter),
            toolExecutor: IF04ToolExecutor(counter: counter),
            childDepth: 1,
            maxChildDepth: 1
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "too-deep", title: "too-deep", instructions: "inspect")],
            strategy: .sequential
        )

        #expect(reports[0].result == .failed(error: "MAX_DEPTH_EXCEEDED"))
        #expect(await counter.providerCalls == 0)
    }

    @Test func childBudgetStopsProviderAtHardRequestCap() async {
        let counter = IF04CallCounter()
        let repeated = if04Envelope(name: "file_read")
        let provider = IF04Provider(
            capabilities: [.streaming, .tools],
            responseText: repeated,
            responseAfterFirst: repeated,
            counter: counter
        )
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: IF04ToolExecutor(counter: counter),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            maxChildBudgetRequests: 2
        )

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "budget", title: "budget", instructions: "inspect")],
            strategy: .sequential
        )

        #expect(reports[0].result.isSuccess == false)
        #expect(await counter.providerCalls <= 2)
        #expect(await counter.toolCalls <= 1)
    }

    @Test func childTimeoutStopsBlockingProvider() async {
        let counter = IF04CallCounter()
        let orchestrator = AgentOrchestrator(
            provider: IF04BlockingProvider(counter: counter),
            toolExecutor: IF04ToolExecutor(counter: counter),
            childTimeout: 0.01
        )
        let started = Date()

        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "timeout", title: "timeout", instructions: "inspect")],
            strategy: .sequential
        )

        #expect(reports[0].result.isSuccess == false)
        let error = reports[0].result.error ?? ""
        #expect(error.contains("timed out") || error.contains("超过时限"))
        #expect(await counter.providerCalls == 1)
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
