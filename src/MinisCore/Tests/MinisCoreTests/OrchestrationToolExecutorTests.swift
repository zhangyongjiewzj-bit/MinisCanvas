import Foundation
import Testing
@testable import MinisCore

// NOTE: 本套件运行在 CLT-only toolchain 上，使用 Swift Testing（见 AgentLoopTests.swift 头注释）。
// 运行：cd src/MinisCore && swift test --filter OrchestrationToolExecutorTests


private func oetStructuredResults(_ output: String) throws -> [[String: Any]] {
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(envelope["version"] as? Int == 1)
    return try #require(envelope["results"] as? [[String: Any]])
}

private func oetHasResult(_ output: String, id: String, status: String, index: Int? = nil) throws -> Bool {
    let results = try oetStructuredResults(output)
    if let index {
        guard results.indices.contains(index) else { return false }
        return results[index]["task_id"] as? String == id && results[index]["status"] as? String == status
    }
    return results.contains { $0["task_id"] as? String == id && $0["status"] as? String == status }
}

// MARK: - File-local fixtures（唯一命名，避免与 AgentOrchestratorTests 等全局 fixture 重名）

/// 记录内置子 agent 并发峰值的 actor（唯一命名 OETest*）。
actor OETestProbe {
    private var active = 0
    private(set) var maxActive = 0

    func enter() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func exit() {
        active -= 1
    }
}

/// 集合屏障：前 expected 个到达者互相等待，之后到达者立即通过。
actor OETestBarrier {
    private let expected: Int
    private var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = max(1, expected)
    }

    func arrive() async {
        entered += 1
        if entered >= expected {
            let pending = waiters
            waiters.removeAll()
            for w in pending { w.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

enum OETestFailure: Error {
    case failedTask
}

/// 探针 provider：统计并发 + 可选屏障 + 记录每次收到的 systemPrompt。
/// 返回固定文本，保证内置子 agent 一轮收尾。
final class OETestProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let capabilities: Set<ProviderCapability>
    private let probe: OETestProbe
    private let barrier: OETestBarrier?
    private let responseText: String
    private let lock = NSLock()
    private var _seenSystemPrompts: [String?] = []
    private var _seenUserContents: [String] = []

    var seenSystemPrompts: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return _seenSystemPrompts
    }

    var seenUserContents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _seenUserContents
    }

    init(name: String = "OETest", model: LLMModel = .claudeHaiku45, probe: OETestProbe, barrier: OETestBarrier? = nil, capabilities: Set<ProviderCapability> = [],
         responseText: String = "子任务完成") {
        self.name = name
        self.model = model
        self.capabilities = capabilities
        self.probe = probe
        self.barrier = barrier
        self.responseText = responseText
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await probe.enter()
        if let barrier { await barrier.arrive() }
        recordSystemPrompt(systemPrompt)
        recordUserContent(messages.first(where: { $0.role == .user })?.content ?? "")
        await probe.exit()
        return LLMResponse(text: responseText, stopReason: nil, usage: nil)
    }

    /// 同步记录（NSLock 不能在 async 上下文直接调用，经同步方法转发）。
    private func recordSystemPrompt(_ prompt: String?) {
        lock.lock()
        _seenSystemPrompts.append(prompt)
        lock.unlock()
    }

    private func recordUserContent(_ content: String) {
        lock.lock()
        _seenUserContents.append(content)
        lock.unlock()
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

/// 空工具执行器（内置子 agent 测试不需要真工具）。
final class OETestNoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

/// Catalog observation only; never performs a file/tool/network effect.
private final class OETestCatalogValidator2479: ToolCatalogValidatingExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String]] = []
    private var executions = 0
    var validatedNames: [[String]] { lock.withLock { captured } }
    var executionCount: Int { lock.withLock { executions } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { executions += 1 }
        return "owned2479"
    }
    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        let names = tools.map(\.name)
        lock.withLock { captured.append(names) }
        if names == ["file_write"] { throw ToolExecutorError.unknownTool("file_write") }
    }
}

actor OETestCancellationProbe {
    private(set) var count = 0
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func recordStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func recordCancelled() {
        count += 1
        cancelled = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
}

/// 可注入的 mock 外部 runner：记录收到的任务、可配置输出 / 失败标记。
/// 未显式给 output 时按任务 ID 派生 "OUT-<id>"，便于区分每个任务的成功输出。
final class OETestRunner: ExternalAgentRunner, @unchecked Sendable {
    let name: String
    let output: String?
    let failureMarker: String?
    let capabilities: Set<ProviderCapability>
    let cancellationProbe: OETestCancellationProbe
    let holdUntilCancellation: Bool
    private let lock = NSLock()
    private var _receivedTasks: [SubAgentTask] = []

    var receivedTasks: [SubAgentTask] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedTasks
    }

    var callCount: Int {
        receivedTasks.count
    }

    init(name: String, output: String? = nil, failureMarker: String? = nil, capabilities: Set<ProviderCapability> = [], cancellationProbe: OETestCancellationProbe = OETestCancellationProbe(), holdUntilCancellation: Bool = false) {
        self.name = name
        self.output = output
        self.failureMarker = failureMarker
        self.capabilities = capabilities
        self.cancellationProbe = cancellationProbe
        self.holdUntilCancellation = holdUntilCancellation
    }

    var isAvailable: Bool { true }

    func cancel(task: SubAgentTask) async {
        await cancellationProbe.recordCancelled()
    }

    var cancellationCount: Int {
        get async { await cancellationProbe.count }
    }

    func run(task: SubAgentTask) async throws -> String {
        recordTask(task)
        await cancellationProbe.recordStarted()
        if holdUntilCancellation { await cancellationProbe.waitUntilCancelled() }
        if let marker = failureMarker, task.instructions.contains(marker) {
            throw OETestFailure.failedTask
        }
        return output ?? "OUT-" + task.id
    }

    /// 同步记录（NSLock 不能在 async 上下文直接调用，经同步方法转发）。
    private func recordTask(_ task: SubAgentTask) {
        lock.lock()
        _receivedTasks.append(task)
        lock.unlock()
    }
}

// MARK: - Fixtures

private func oetTaskJSON(
    id: String,
    title: String = "默认标题",
    instructions: String = "默认指令",
    context: String? = nil,
    expectedOutput: String? = nil,
    agent: String? = nil,
    modelBinding: [String: Any]? = nil,
    providerID: String? = "test-provider",
    modelID: String? = "test-model",
    configurationFingerprint: String? = "test-fingerprint",
    profileID: String? = nil,
    baseHost: String? = nil,
    wireAPI: String? = nil,
    reasoningConfiguration: String? = nil,
    // These default fixtures return prose only; v2 omission would inherit tools.
    requiredCapabilities: [String]? = []
) -> [String: Any] {
    var dict: [String: Any] = [
        "id": id,
        "title": title,
        "instructions": instructions,
    ]
    if let context { dict["context"] = context }
    if let expectedOutput { dict["expected_output"] = expectedOutput }
    if let agent { dict["agent"] = agent }
    if let modelBinding { dict["model_binding"] = modelBinding }
    if let requiredCapabilities { dict["required_capabilities"] = requiredCapabilities }
    // V1 fixtures use nested model_binding; inherited fixtures leave all binding IDs nil.
    if agent != nil, modelBinding == nil, providerID != nil || modelID != nil || configurationFingerprint != nil {
        var explicit: [String: Any] = ["kind": "explicit"]
        if let providerID { explicit["provider_id"] = providerID }
        if let modelID { explicit["model_id"] = modelID }
        if let configurationFingerprint { explicit["configuration_fingerprint"] = configurationFingerprint }
        dict["model_binding"] = explicit
    }
    if let profileID { dict["profile_id"] = profileID }
    if let baseHost { dict["base_host"] = baseHost }
    if let wireAPI { dict["wire_api"] = wireAPI }
    if let reasoningConfiguration { dict["reasoning_configuration"] = reasoningConfiguration }
    return dict
}

// MARK: - OrchestrationToolExecutor：opt-in "orchestrate" 工具切片

/// 覆盖 OrchestrationToolExecutor 的边界切片：
/// 精确工具名、field-level JSON 映射、策略、外部路由、输入顺序汇总与错误。
struct OrchestrationToolExecutorTests {

    // MARK: 精确工具名 / opt-in 定义

    @Test func toolNameIsExactlyOrchestrate() {
        #expect(OrchestrationToolExecutor.toolName == "orchestrate")
    }

    @Test func wrongToolNameThrowsUnknownTool() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.unknownTool("shell_execute")) {
            try await executor.execute(name: "shell_execute", input: [:])
        }
    }

    @Test func v1InputRequiresInputVersionAndNestedModelBinding() async throws {
        let runner = OETestRunner(name: "v1-runner")
        let store = AgentTaskStore()
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fingerprint",
            conversationID: "parent-conversation"
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["v1-runner": runner],
            taskStore: store,
            parentID: "parent",
            parentBinding: parent
        )
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        await #expect(throws: ToolExecutorError.missingParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: [
                "tasks": [oetTaskJSON(id: "legacy", agent: "external:v1-runner")]
            ])
        }

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": 1,
            "tasks": [
                oetTaskJSON(id: "inherited", agent: "external:v1-runner", modelBinding: nil, providerID: nil, modelID: nil, configurationFingerprint: nil),
                oetTaskJSON(
                    id: "explicit",
                    agent: "external:v1-runner",
                    modelBinding: [
                        "kind": "explicit",
                        "provider_id": "parent-provider",
                        "model_id": "parent-model",
                        "configuration_fingerprint": "parent-fingerprint"
                    ]
                )
            ]
        ])
        #expect((try oetStructuredResults(output)).count == 2)
        // Parallel orchestration guarantees report/input order, not runner start order.
        // Observe binding through the public task identity, not a scheduling side effect.
        let receivedByID = Dictionary(uniqueKeysWithValues: runner.receivedTasks.map { ($0.id, $0) })
        #expect(receivedByID["inherited"]?.bindingSource == .inherited)
        #expect(receivedByID["explicit"]?.bindingSource == .explicit)
        #expect(receivedByID.values.allSatisfy { $0.providerID == "parent-provider" })
        #expect(receivedByID.values.allSatisfy { $0.modelID == "parent-model" })
        #expect(store.allReceipts().map(\.providerID) == ["parent-provider", "parent-provider"])
        #expect(store.allReceipts().map(\.modelID) == ["parent-model", "parent-model"])
    }

    @Test func inheritedBindingUsesImmutableParentSnapshot() async throws {
        let runner = OETestRunner(name: "snapshot-runner")
        let store = AgentTaskStore()
        let executor = OrchestrationToolExecutor(
            orchestrator: AgentOrchestrator(externalRunners: ["snapshot-runner": runner], taskStore: store)
        )
        var ambientParent = ParentContextSnapshotV1(
            providerID: "provider-before",
            modelID: "model-before",
            configurationFingerprint: "fingerprint-before",
            conversationID: "conversation-before"
        )
        let context = AgentExecutionContextSnapshot(
            provider: OETestProvider(probe: OETestProbe()),
            approvalGate: nil,
            turnController: nil,
            currentConversationID: "conversation-before",
            makeChildBudget: nil,
            deadline: nil,
            taskStore: store,
            parentBinding: ambientParent
        )
        ambientParent = ParentContextSnapshotV1(
            providerID: "provider-after",
            modelID: "model-after",
            configurationFingerprint: "fingerprint-after",
            conversationID: "conversation-after"
        )

        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(
                    id: "snapshot-task",
                    agent: "external:snapshot-runner",
                    providerID: nil,
                    modelID: nil,
                    configurationFingerprint: nil
                )]
            ])
        }

        #expect(runner.receivedTasks.first?.providerID == "provider-before")
        #expect(store.allReceipts().first?.configurationFingerprint == "fingerprint-before")
    }

    @Test func unknownInputVersionAndHalfExplicitNestedBindingFailBeforeDispatch() async {
        let runner = OETestRunner(name: "v1-validation-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(externalRunners: ["v1-validation-runner": runner]))
        await #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": 0, "tasks": []])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": "1", "tasks": []])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("model_binding")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": 1,
                "tasks": [oetTaskJSON(id: "half", agent: "external:v1-validation-runner", modelBinding: [
                    "kind": "explicit", "provider_id": "provider-only"
                ])]
            ])
        }
        #expect(runner.callCount == 0)
    }

    @Test func productionJSONIntegerBridgingAcceptsInt64AndRejectsNonIntegers() async throws {
        let runner = OETestRunner(name: "json-integer-runner")
        let store = AgentTaskStore()
        let parent = ParentContextSnapshotV1(
            providerID: "json-provider",
            modelID: "json-model",
            configurationFingerprint: "json-fingerprint",
            conversationID: "json-conversation"
        )
        let executor = OrchestrationToolExecutor(
            orchestrator: AgentOrchestrator(
                externalRunners: ["json-integer-runner": runner],
                taskStore: store,
                parentID: "json-parent",
                parentBinding: parent
            )
        )
        let task = oetTaskJSON(
            id: "json-task",
            agent: "external:json-integer-runner",
            providerID: nil,
            modelID: nil,
            configurationFingerprint: nil
        )

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": Int64(OrchestrationToolExecutor.inputVersion),
            "tasks": [task],
            "limit": Int64(1),
            "strategy": "parallel_with_limit"
        ])
        #expect((try oetStructuredResults(output)).count == 1)
        #expect(runner.callCount == 1)

        await #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": 1.5,
                "tasks": []
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": true,
                "tasks": []
            ])
        }
        #expect(runner.callCount == 1)
    }

    @Test func versionedSchemaIsRequiredAndUnsupportedVersionsFailClosed() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.missingParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: ["tasks": []])
        }
        await #expect(throws: ToolExecutorError.missingParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: ["schema_version": 1, "tasks": []])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": 99, "tasks": []])
        }
    }

    @Test func v2TaskResourceDeclarationIsImmutableAndV1CannotSmuggleIt() throws {
        let task = oetTaskJSON(id: "scoped", requiredCapabilities: ["tools"])
        var declared = task
        declared["allowed_tool_names"] = ["file_read"]
        declared["allowed_read_roots"] = ["/tmp/scoped"]
        let request = try OrchestrateRequestV1.decode(input: [
            "input_version": 2, "tasks": [declared]
        ], maxTasks: 1)
        #expect(request.tasks[0].resourceRequest == SubAgentResourceRequest(
            allowedToolNames: ["file_read"], allowedReadRoots: ["/tmp/scoped"]
        ))

        #expect(throws: ToolExecutorError.invalidParameter("input_version")) {
            _ = try OrchestrateRequestV1.decode(input: [
                "input_version": 1, "tasks": [declared]
            ], maxTasks: 1)
        }
        let legacy = try OrchestrateRequestV1.decode(input: [
            "input_version": 1, "tasks": [oetTaskJSON(id: "legacy")]
        ], maxTasks: 1)
        #expect(legacy.tasks[0].resourceRequest == nil)
    }

    @Test func v2ResourceArraysStayInsideFrozenRequestBudgets() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        var tooManyTools = oetTaskJSON(id: "too-many", requiredCapabilities: ["tools"])
        tooManyTools["allowed_tool_names"] = (0...32).map { "tool-\($0)" }
        tooManyTools["allowed_read_roots"] = ["/tmp/scoped"]
        await #expect(throws: ToolExecutorError.invalidParameter("allowed_tool_names")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": 2, "tasks": [tooManyTools]
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("instructions")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": 2,
                "tasks": [oetTaskJSON(id: "too-long", instructions: String(repeating: "x", count: 32_769))]
            ])
        }
    }

    @Test func v2WrappedOwnerRejectsPrefixAndSymlinkRootsBeforeDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OETWrappedScope-\(UUID().uuidString)", isDirectory: true)
        let own = directory.appendingPathComponent("own", isDirectory: true)
        let prefixSibling = directory.appendingPathComponent("own-peer", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixSibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = own.appendingPathComponent("linked-peer", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prefixSibling)

        let owner = BuiltinToolExecutor(allowedRoot: own, deniedRoots: [])
        let wrapped = ScopedForwardingExecutor(base: owner)
        let provider = OETestProvider(probe: OETestProbe(), capabilities: [.tools])
        let controller = TurnController()
        let parentHandle = await controller.beginTurn()
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: wrapped,
            turnController: controller,
            taskStore: AgentTaskStore(), parentID: "oet-wrapped-parent",
            parentTurnHandle: parentHandle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools], allowedToolNames: ["file_read"]
            ), parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner
        )
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)
        for (id, root) in [("prefix-sibling", prefixSibling), ("symlink-sibling", link)] {
            var task = oetTaskJSON(id: id, requiredCapabilities: ["tools"])
            task["allowed_tool_names"] = ["file_read"]
            task["allowed_read_roots"] = [root.path]
            let output = try await executor.execute(name: "orchestrate", input: [
                "input_version": 2, "tasks": [task], "strategy": "sequential"
            ])
            #expect(output.contains(id))
            #expect(output.contains("TASK_RESOURCE_SCOPE_INVALID"))
        }
        #expect(provider.seenUserContents.isEmpty)
        #expect(wrapped.invokedNames.isEmpty)
    }

    @Test func compositeBuiltinOwnerProofExecutesOnlyThroughRegisteredBase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OETBoundOwner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "BOUND_COMPOSITE_MARKER_\(UUID().uuidString)"
        let file = directory.appendingPathComponent("fixture.txt")
        try marker.write(to: file, atomically: true, encoding: .utf8)
        let owner = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let foreign = BuiltinToolExecutor(allowedRoot: directory, deniedRoots: [])
        let composite = OrchestrationCompositeToolExecutor(
            base: owner,
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        )
        #expect(composite.currentBuiltinOwner === owner)
        let output = try await executeThroughBoundBuiltinOwner(
            composite, owner: owner, name: "file_read", input: ["path": file.path]
        )
        #expect(output.contains(marker))
        await #expect(throws: ToolExecutorError.resourceScopeInvalid) {
            try await executeThroughBoundBuiltinOwner(
                composite, owner: foreign, name: "file_read", input: ["path": file.path]
            )
        }
    }

    @Test func definitionDeclaresOrchestrateWithTasksRequired() {
        let definition = OrchestrationToolExecutor.makeDefinition()
        #expect(definition.name == "orchestrate")
        #expect(definition.required == ["input_version", "tasks"])
        #expect(definition.parameters.keys.contains("input_version"))
        #expect(definition.parameters.keys.contains("tasks"))
        #expect(definition.parameters.keys.contains("strategy"))
        #expect(definition.parameters.keys.contains("limit"))
        #expect(definition.parameters.keys.contains("system_prompt"))
        #expect(definition.parameters["strategy"]?.enumValues == ["parallel", "sequential", "parallel_with_limit"])
        #expect(definition.parameters["run_in_background"]?.type == .boolean)
        #expect(definition.propertyOrdering == ["input_version", "tasks", "strategy", "limit", "role_preset", "system_prompt", "run_in_background"])
        #expect(definition.parameters["tasks"]?.description.contains("allowed_tool_names") == true)
    }

    /// T-07：后台子任务完成不会自动唤起模型，说明不能再写"会收到通知"，要写清结果随用户下一条消息送达。
    @Test func backgroundDescriptionMatchesActualDeliveryNotAPushNotification() {
        let definition = OrchestrationToolExecutor.makeDefinition()
        #expect(!definition.description.contains("arrives as a notification"))
        #expect(definition.description.contains("next message"))
        let flag = definition.parameters["run_in_background"]?.description ?? ""
        #expect(!flag.contains("with a notification"))
        #expect(flag.contains("next message"))
    }

    @Test func inheritedBindingIsFrozenInExternalTaskAndLedger() async throws {
        let runner = OETestRunner(name: "inherit-runner")
        let store = AgentTaskStore()
        let orchestrator = AgentOrchestrator(externalRunners: ["inherit-runner": runner], taskStore: store, parentID: "parent")
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)
        let context = AgentExecutionContextSnapshot(
            provider: OETestProvider(probe: OETestProbe()), approvalGate: nil, turnController: nil,
            currentConversationID: "conversation", makeChildBudget: nil, deadline: nil, taskStore: store,
            parentBinding: ParentContextSnapshotV1(providerID: "parent-provider", modelID: "parent-model", configurationFingerprint: "parent-fp", conversationID: "conversation")
        )
        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "inherit-task", agent: "external:inherit-runner", providerID: nil, modelID: nil, configurationFingerprint: nil)]
            ])
        }
        let task = try #require(runner.receivedTasks.first)
        #expect(task.providerID == "parent-provider")
        #expect(task.modelID == "parent-model")
        #expect(task.configurationFingerprint == "parent-fp")
        #expect(task.bindingSource == .inherited)
        let snapshot = try #require(store.snapshot(taskID: "inherit-task", parentID: "parent"))
        #expect(snapshot.providerID == "parent-provider")
        #expect(snapshot.modelID == "parent-model")
        #expect(snapshot.parentContextSnapshotID == "binding:parent-provider:parent-model:parent-fp:conversation")
        #expect(store.allReceipts().first?.parentContextSnapshotID == snapshot.parentContextSnapshotID)
    }

    @Test func explicitBindingConflictingWithParentFailsClosedBeforeDispatch() async {
        let runner = OETestRunner(name: "conflict-runner")
        let parent = ParentContextSnapshotV1(
            providerID: "parent-provider",
            modelID: "parent-model",
            configurationFingerprint: "parent-fp",
            conversationID: "conversation"
        )
        let orchestrator = AgentOrchestrator(
            externalRunners: ["conflict-runner": runner],
            parentBinding: parent
        )
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        await #expect(throws: ToolExecutorError.modelModeUnverified) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(
                    id: "conflict-task",
                    agent: "external:conflict-runner",
                    providerID: "other-provider",
                    modelID: "other-model",
                    configurationFingerprint: "other-fp"
                )]
            ])
        }
        #expect(runner.callCount == 0)
    }

    @Test func inheritedBindingWithoutParentContextFailsClosedBeforeDispatch() async {
        let runner = OETestRunner(name: "missing-parent-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(externalRunners: ["missing-parent-runner": runner]))

        await #expect(throws: ToolExecutorError.modelModeUnverified) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "missing-parent-task", agent: "external:missing-parent-runner", providerID: nil, modelID: nil, configurationFingerprint: nil)]
            ])
        }
        #expect(runner.callCount == 0)
    }

    @Test func partialExplicitBindingIsRejectedBeforeDispatch() async {
        let runner = OETestRunner(name: "partial-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(externalRunners: ["partial-runner": runner]))
        await #expect(throws: ToolExecutorError.invalidParameter("model_binding")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "partial-task", agent: "external:partial-runner", providerID: "p", modelID: nil, configurationFingerprint: nil)]
            ])
        }
        #expect(runner.callCount == 0)
    }

    @Test func explicitBindingReachesExternalRunnerWithFingerprint() async throws {
        let runner = OETestRunner(name: "explicit-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator().withExternalRunner(runner))
        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": [oetTaskJSON(id: "explicit-task", agent: "external:explicit-runner", providerID: "provider-explicit", modelID: "model-explicit", configurationFingerprint: "fp-explicit")]
        ])
        let task = try #require(runner.receivedTasks.first)
        #expect(task.providerID == "provider-explicit")
        #expect(task.modelID == "model-explicit")
        #expect(task.configurationFingerprint == "fp-explicit")
        #expect(task.bindingSource == .explicit)
    }

    @Test func explicitBuiltinBindingSelectsVerifiedProvider() async throws {
        let probe = OETestProbe()
        let selected = OETestProvider(name: "selected-provider", probe: probe, capabilities: [.tools])
        let fallback = OETestProvider(name: "fallback-provider", probe: probe, capabilities: [.streaming])
        let task = SubAgentTask(
            id: "selected-task",
            title: "Selected",
            instructions: "use selected",
            providerID: "selected-provider",
            modelID: selected.model.id,
            configurationFingerprint: "selected-fp",
            requiredCapabilities: [.tools],
            bindingSource: .explicit
        )
        let orchestrator = AgentOrchestrator(
            provider: fallback,
            toolExecutor: OETestNoopExecutor(),
            resolveChildProvider: { task, _ in
                task.providerID == "selected-provider" ? selected : fallback
            }
        )
        let reports = await orchestrator.orchestrate(tasks: [task])

        #expect(reports.count == 1)
        #expect(reports[0].result.isSuccess)
        #expect(await probe.maxActive == 1)

        let unverified = AgentOrchestrator(provider: fallback, toolExecutor: OETestNoopExecutor())
        let rejected = await unverified.orchestrate(tasks: [task])
        #expect(rejected.first?.result == .failed(error: "MODEL_MODE_UNVERIFIED"))
    }

    @Test func bindingFieldsReachExternalRunner() async throws {
        let runner = OETestRunner(name: "binding-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator().withExternalRunner(runner))
        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": [oetTaskJSON(
                id: "binding-task",
                agent: "external:binding-runner",
                providerID: "provider-a",
                modelID: "model-a",
                configurationFingerprint: "fp-a",
                profileID: "profile-a",
                baseHost: "api.example.test",
                wireAPI: "responses",
                reasoningConfiguration: "high"
            )]
        ])
        let task = try #require(runner.receivedTasks.first)
        #expect(task.providerID == "provider-a")
        #expect(task.modelID == "model-a")
        #expect(task.profileID == "profile-a")
        #expect(task.baseHost == "api.example.test")
        #expect(task.wireAPI == "responses")
        #expect(task.reasoningConfiguration == "high")
    }

    @Test func optInCatalogAddsOnlyOrchestrationDefinition() {
        let definition = OrchestrationToolExecutor.makeDefinition()
        let defaultNames = Set(AgentToolCatalog.makeTools().map(\.name))
        let optInNames = AgentToolCatalog.makeTools(orchestration: definition).map(\.name)
        #expect(!defaultNames.contains(OrchestrationToolExecutor.toolName))
        #expect(optInNames.filter { $0 == OrchestrationToolExecutor.toolName }.count == 1)
        #expect(!defaultNames.contains(OrchestrationToolExecutor.resultToolName))
        #expect(optInNames.filter { $0 == OrchestrationToolExecutor.resultToolName }.count == 1)
    }

    @Test func compositeRoutesOrchestrateAndDelegatesOtherNames() async throws {
        let base = OETestNoopExecutor()
        let composite = OrchestrationCompositeToolExecutor(
            base: base,
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        )
        let orchestrationOutput = try await composite.execute(
            name: OrchestrationToolExecutor.toolName,
            input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []]
        )
        #expect((try oetStructuredResults(orchestrationOutput)).count == 0)
        #expect(try await composite.execute(name: "unrelated", input: [:]) == "ok")
    }

    @Test func compositeUsesTaskLocalProviderAndInheritedIdentity() async throws {
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe)
        let context = AgentExecutionContextSnapshot(
            provider: provider,
            approvalGate: nil,
            turnController: nil,
            currentConversationID: "parent-conversation",
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(30),
            parentBinding: ParentContextSnapshotV1(providerID: "context-provider", modelID: "context-model", configurationFingerprint: "context-fp", conversationID: "parent-conversation")
        )
        let composite = OrchestrationCompositeToolExecutor(
            base: OETestNoopExecutor(),
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator()),
            makeRuntimeOrchestrator: { context in
                AgentOrchestrator(
                    provider: context.provider,
                    toolExecutor: OETestNoopExecutor(),
                    currentConversationID: context.currentConversationID
                )
            }
        )
        let output = try await AgentExecutionContext.$current.withValue(context) {
            try await composite.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "context-task")]
            ])
        }
        #expect(output.contains("context-task"))
        #expect(provider.seenSystemPrompts.count == 1)
    }

    @Test func compositeAcceptsScopedCatalogWithoutRegisteringOrchestration() throws {
        let base = OETestCatalogValidator2479()
        let composite = OrchestrationCompositeToolExecutor(
            base: base,
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        )
        let noOrchestration = AgentToolCatalog.makeTools()
        #expect(!noOrchestration.contains { $0.name == OrchestrationToolExecutor.toolName })
        try composite.validateToolCatalog(noOrchestration)
        try composite.validateToolCatalog([])
        let scopedRead = noOrchestration.filter { $0.name == "file_read" }
        try #require(scopedRead.count == 1)
        try composite.validateToolCatalog(scopedRead)
        try composite.validateToolCatalog(scopedRead + [OrchestrationToolExecutor.makeDefinition()])
        #expect(base.validatedNames == [noOrchestration.map(\.name), [], ["file_read"], ["file_read"]])
        #expect(base.executionCount == 0)
    }

    @Test func compositeRejectsDuplicateOrchestrationAndKeepsBaseValidation() throws {
        let base = OETestCatalogValidator2479()
        let composite = OrchestrationCompositeToolExecutor(
            base: base,
            orchestration: OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        )
        #expect(throws: ToolExecutorError.invalidParameter("duplicate_orchestration_definition")) {
            try composite.validateToolCatalog([
                OrchestrationToolExecutor.makeDefinition(), OrchestrationToolExecutor.makeDefinition()
            ])
        }
        #expect(base.validatedNames.isEmpty)
        let denied = AgentToolCatalog.makeTools().filter { $0.name == "file_write" }
        try #require(denied.count == 1)
        #expect(throws: ToolExecutorError.unknownTool("file_write")) {
            try composite.validateToolCatalog(denied)
        }
        #expect(base.validatedNames == [["file_write"]])
        #expect(base.executionCount == 0)
    }

@Test func defaultCatalogRemainsOptIn() {
        // 本切片是 opt-in：默认工具目录不得注册 orchestrate（不改 AgentToolCatalog 默认列表）。
        let names = AgentToolCatalog.makeTools().map(\.name)
        #expect(!names.contains("orchestrate"))
    }

    // MARK: field-level JSON 映射 — 输入错误

    @Test func missingTasksThrowsMissingParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.missingParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion])
        }
        await #expect(throws: ToolExecutorError.missingParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "strategy": "sequential"])
        }
    }

    @Test func nonArrayTasksThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": "不是数组"])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": 42])
        }
    }

    @Test func taskMissingRequiredFieldsThrowMissingParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.missingParameter("id")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["title": "T", "instructions": "I"]],
            ])
        }
        await #expect(throws: ToolExecutorError.missingParameter("title")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "instructions": "I"]],
            ])
        }
        await #expect(throws: ToolExecutorError.missingParameter("instructions")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T"]],
            ])
        }
    }

    @Test func taskFieldWrongTypeThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("id")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": 42, "title": "T", "instructions": "I"]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("instructions")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": 7]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("context")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": "I", "context": 3.14]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("expected_output")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": "I", "expected_output": false]],
            ])
        }
    }

    @Test func invalidAgentThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("agent")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1", agent: "hybrid")],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("agent")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1", agent: "external:")],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("agent")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1", agent: "42")],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("agent")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": "I", "agent": 42]],
            ])
        }
    }

    @Test func emptyRequiredStringFieldsThrowInvalidParameter() async {
        // 字段存在但为空（含纯空白）＝ invalidParameter：空 id 会让报告/汇总失去对应关系。
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("id")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "", "title": "T", "instructions": "I"]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("title")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "", "instructions": "I"]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("instructions")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": ""]],
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("instructions")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [["id": "t1", "title": "T", "instructions": "   "]],
            ])
        }
    }

    @Test func wrongTypedSystemPromptThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("system_prompt")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
                "system_prompt": 42,
            ])
        }
    }

    // MARK: field-level JSON 映射 — 内置任务执行与汇总

    @Test func builtinIterationLimitReturnsPartialFeedbackWithoutToolPayload() async throws {
        let provider = OETestProvider(probe: OETestProbe(), capabilities: [.tools],
            responseText: #"{"tool_calls":[{"id":"partial-call","name":"file_read","input":{"path":"unsettled-tool-payload"}}]}"#)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 1)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)
        let capture = OrchestrationTerminalCapture()
        let output = try await OrchestrationTerminalContext.$current.withValue(capture) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "limit", requiredCapabilities: ["tools"])],
                "strategy": "sequential"
            ])
        }

        #expect(try oetHasResult(output, id: "limit", status: "partial"))
        #expect(output.contains("没有已结算的可见正文"))
        #expect(!output.contains("unsettled-tool-payload"))
        #expect(await capture.takeAndFreeze()?.allSucceeded == false)
    }

    @Test func builtinTasksMapFieldsAndSummarizeInInputOrder() async throws {
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [
                oetTaskJSON(id: "t1", title: "任务一", instructions: "执行指令一", context: "背景一", expectedOutput: "产出一"),
                oetTaskJSON(id: "t2", title: "任务二", instructions: "执行指令二"),
            ],
            "strategy": "sequential",
        ])

        #expect((try oetStructuredResults(output)).count == 2)
        #expect(try oetHasResult(output, id: "t1", status: "succeeded", index: 0))
        #expect(try oetHasResult(output, id: "t2", status: "succeeded", index: 1))
        #expect(output.contains("子任务完成"), "内置子 agent 的 provider 输出应出现在汇总预览中")
        let first = try #require(output.range(of: "\"task_id\":\"t1\""))
        let second = try #require(output.range(of: "\"task_id\":\"t2\""))
        #expect(first.lowerBound < second.lowerBound, "汇总必须保持输入顺序")
        // 指令作为内置子 agent 首条 user 消息 → provider 收到 2 次调用。
        #expect(provider.seenSystemPrompts.count == 2)
    }

    @Test func childContextAndExpectedOutputAreForwardedToBuiltinPrompt() async throws {
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": [oetTaskJSON(
                id: "context-forwarded",
                instructions: "Do the work",
                context: "Parent facts",
                expectedOutput: "A concise result"
            )]
        ])

        let content = try #require(provider.seenUserContents.first)
        #expect(content.contains("Parent context:\nParent facts"))
        #expect(content.contains("Do the work"))
        #expect(content.contains("Expected output:\nA concise result"))
    }

    @Test func systemPromptIsForwardedToBuiltinChildren() async throws {
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
            "system_prompt": "SHARED-SYSTEM-CTX",
        ])

        #expect(provider.seenSystemPrompts == [AgentOrchestrator.childSafetyPrompt + "\n\n" + "SHARED-SYSTEM-CTX"])
    }

    @Test func emptyTasksReturnsEmptySummary() async throws {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        let output = try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []])
        #expect((try oetStructuredResults(output)).count == 0)
    }

    // MARK: 外部路由

    @Test func externalRoutingDispatchesToNamedRunner() async throws {
        let runner = OETestRunner(name: "oet-probe", output: "EXTERNAL-OUT-T1")
        let orchestrator = AgentOrchestrator().withExternalRunner(runner)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [
                oetTaskJSON(
                    id: "t1",
                    instructions: "跑外部命令",
                    context: "项目背景",
                    expectedOutput: "一段产出",
                    agent: "external:oet-probe"
                ),
            ],
        ])

        #expect(runner.callCount == 1)
        let task = try #require(runner.receivedTasks.first)
        #expect(task.id == "t1")
        #expect(task.title == "默认标题")
        #expect(task.instructions == "跑外部命令")
        #expect(task.context == "项目背景")
        #expect(task.expectedOutput == "一段产出")
        #expect(task.agentType == .external(name: "oet-probe"))
        #expect(try oetHasResult(output, id: "t1", status: "succeeded", index: 0))
        #expect(output.contains("EXTERNAL-OUT-T1"))
    }

    @Test func externalRoutingUnknownRunnerIsIsolatedFailureInOrder() async throws {
        let goodRunner = OETestRunner(name: "oet-good", output: "GOOD-OUT")
        let orchestrator = AgentOrchestrator().withExternalRunner(goodRunner)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [
                oetTaskJSON(id: "t1", instructions: "好任务", agent: "external:oet-good"),
                oetTaskJSON(id: "t2", instructions: "幽灵任务", agent: "external:ghost"),
            ],
            "strategy": "sequential",
        ])

        #expect(try oetHasResult(output, id: "t1", status: "succeeded", index: 0))
        #expect(output.contains("GOOD-OUT"))
        #expect(try oetHasResult(output, id: "t2", status: "failed", index: 1))
        #expect(output.contains("未知外部子 agent 'ghost'"))
        let first = try #require(output.range(of: "\"task_id\":\"t1\""))
        let second = try #require(output.range(of: "\"task_id\":\"t2\""))
        #expect(first.lowerBound < second.lowerBound, "失败隔离后仍保持输入顺序")
    }

    @Test func requiredCapabilityIsDecodedAndMissingExternalCapabilityFailsBeforeDispatch() async throws {
        let runner = OETestRunner(name: "text-only", capabilities: [.streaming])
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator().withExternalRunner(runner))
        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": [oetTaskJSON(id: "vision-task", agent: "external:text-only", requiredCapabilities: ["vision"])]
        ])
        #expect(try oetHasResult(output, id: "vision-task", status: "failed", index: 0))
        #expect(output.contains("CAPABILITY_UNAVAILABLE"))
        #expect(runner.callCount == 0)
    }

    @Test func unknownRequiredCapabilityIsRejectedAtInputBoundary() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("required_capabilities")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "unknown-capability", requiredCapabilities: ["telepathy"])]
            ])
        }
    }

    @Test func externalRunnerFailureIsIsolatedAndSummarized() async throws {
        let runner = OETestRunner(name: "oet-fail", failureMarker: "坏指令")
        let orchestrator = AgentOrchestrator().withExternalRunner(runner)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let output = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [
                oetTaskJSON(id: "t1", instructions: "坏指令触发失败", agent: "external:oet-fail"),
                oetTaskJSON(id: "t2", instructions: "正常任务", agent: "external:oet-fail"),
            ],
            "strategy": "sequential",
        ])

        #expect(try oetHasResult(output, id: "t1", status: "failed", index: 0))
        #expect(try oetHasResult(output, id: "t2", status: "succeeded", index: 1))
        #expect(output.contains("OUT-t2"))
        #expect(!output.contains("OUT-t1"), "失败任务的输出不应出现在汇总中")
        #expect(runner.callCount == 2, "失败隔离：t1 失败不阻塞 t2 执行")
        let first = try #require(output.range(of: "\"task_id\":\"t1\""))
        let second = try #require(output.range(of: "\"task_id\":\"t2\""))
        #expect(first.lowerBound < second.lowerBound, "失败后仍保持输入顺序")
    }

    // MARK: 策略

    @Test func strategyDefaultsToParallel() async throws {
        let probe = OETestProbe()
        let barrier = OETestBarrier(expected: 4)
        let provider = OETestProvider(probe: probe, barrier: barrier)
        let orchestrator = AgentOrchestrator(defaultMaxConcurrent: 4, maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": ["a", "b", "c", "d"].map { oetTaskJSON(id: $0) },
        ])

        #expect(await probe.maxActive == 4, "缺省 strategy 应为 .parallel，4 个任务同时在飞")
    }

    @Test func strategySequentialRunsOneTaskAtATime() async throws {
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": ["a", "b", "c"].map { oetTaskJSON(id: $0) },
            "strategy": "sequential",
        ])

        #expect(await probe.maxActive == 1, "sequential 策略并发峰值应为 1")
    }

    @Test func strategyParallelWithLimitAppliesLimit() async throws {
        let probe = OETestProbe()
        let barrier = OETestBarrier(expected: 2)
        let provider = OETestProvider(probe: probe, barrier: barrier)
        let orchestrator = AgentOrchestrator(defaultMaxConcurrent: 4, maxIterationsPerTask: 2)
            .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": ["a", "b", "c", "d"].map { oetTaskJSON(id: $0) },
            "strategy": "parallel_with_limit",
            "limit": 2,
        ])

        #expect(await probe.maxActive == 2, "parallel_with_limit 应施加并发上限 2")
    }

    @Test func parallelWithLimitMissingLimitThrowsMissingParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.missingParameter("limit")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
                "strategy": "parallel_with_limit",
            ])
        }
    }

    @Test func parallelWithLimitInvalidLimitThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("limit")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
                "strategy": "parallel_with_limit",
                "limit": "two",
            ])
        }
    }

    @Test func optInExecutionRecordsTaskRunEventsAndReceipt() async throws {
        let store = AgentTaskStore()
        let runner = OETestRunner(name: "ledger-runner", output: "LEDGER-OUT")
        let orchestrator = AgentOrchestrator(taskStore: store, parentID: "parent-turn")
            .withExternalRunner(runner)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        _ = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "ledger-task", agent: "external:ledger-runner", providerID: "ledger-provider", modelID: "ledger-model", configurationFingerprint: "ledger-fp")],
        ])

        let snapshot = try #require(store.snapshot(taskID: "ledger-task"))
        #expect(snapshot.parentID == "parent-turn")
        #expect(snapshot.status == .succeeded)
        #expect(snapshot.providerID == "ledger-provider")
        #expect(snapshot.modelID == "ledger-model")
        #expect(snapshot.configurationFingerprint == "ledger-fp")
        #expect(snapshot.routeReceiptID == "route:ledger-provider:ledger-model:ledger-fp")
        #expect(store.allReceipts().count == 1)
        #expect(store.allReceipts()[0].configurationFingerprint == "ledger-fp")
        #expect(store.events(runID: store.allReceipts()[0].runID).map(\.kind) == [.started, .completed])
    }

    @Test func lifecycleRecordsFailureAndCancellationOutcomes() async throws {
        let failureStore = AgentTaskStore()
        let failingRunner = OETestRunner(name: "failure-runner", failureMarker: "ledger-fail")
        let failingOrchestrator = AgentOrchestrator(taskStore: failureStore, parentID: "failure-parent")
            .withExternalRunner(failingRunner)
        let failingExecutor = OrchestrationToolExecutor(orchestrator: failingOrchestrator)
        _ = try await failingExecutor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "failed-task", instructions: "ledger-fail", agent: "external:failure-runner")],
        ])
        let failedSnapshot = try #require(failureStore.snapshot(taskID: "failed-task"))
        #expect(failedSnapshot.status == .failed)
        let failedReceipt = try #require(failureStore.allReceipts().first)
        if case .failed(let reason) = failedReceipt.outcome {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("expected a failed receipt")
        }
        #expect(failureStore.events(runID: failedReceipt.runID).map(\.kind) == [.started, .failed])

        let cancellationLedgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OETPreDispatchCancellation2519-\(UUID().uuidString).json")
        let cancelStore = try AgentTaskStore(persistenceURL: cancellationLedgerURL)
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        await parentTurn.interrupt()
        let cancelRunner = OETestRunner(name: "cancel-runner")
        let cancelOrchestrator = AgentOrchestrator(
            turnController: controller,
            taskStore: cancelStore,
            parentID: "cancel-parent"
        ).withExternalRunner(cancelRunner)
        let cancelExecutor = OrchestrationToolExecutor(orchestrator: cancelOrchestrator)
        let cancellationOutput = try await cancelExecutor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "cancelled-task", agent: "external:cancel-runner")],
            "strategy": "sequential",
        ])
        // Sequential legacy admission reaches the canonical run initialization
        // before the parent-cancellation check. No runner dispatch is required
        // for the already-created attempt to retain its cancelled receipt.
        #expect(try oetHasResult(cancellationOutput, id: "cancelled-task", status: "failed", index: 0))
        #expect(cancellationOutput.contains("任务已取消"))
        #expect(cancelRunner.callCount == 0)
        let cancelledSnapshot = try #require(cancelStore.snapshot(taskID: "cancelled-task"))
        #expect(cancelledSnapshot.parentID == "cancel-parent")
        #expect(cancelledSnapshot.status == .cancelled)
        #expect(cancelStore.taskCenterSnapshots() == [cancelledSnapshot])
        #expect(cancelStore.allReceipts().count == 1)
        let cancelledReceipt = try #require(cancelStore.allReceipts().first)
        #expect(cancelledReceipt.taskID == cancelledSnapshot.taskID)
        #expect(cancelledReceipt.outcome == .cancelled)
        let attempt = try #require(cancelStore.attempts(runID: cancelledReceipt.runID).first)
        #expect(attempt.attemptID == cancelledReceipt.attemptID)
        #expect(attempt.status == .cancelled)
        let events = cancelStore.events(runID: cancelledReceipt.runID)
        #expect(events.map(\.kind) == [.started, .cancelled])
        // Store terminal settlement owns the canonical event detail.
        #expect(events.last?.detail == "cancelled")
        #expect(events.allSatisfy { $0.runID == cancelledReceipt.runID })
        let reopened = try AgentTaskStore(persistenceURL: cancellationLedgerURL)
        #expect(reopened.snapshot(taskID: "cancelled-task") == cancelledSnapshot)
        #expect(reopened.allReceipts() == [cancelledReceipt])
        #expect(reopened.events(runID: cancelledReceipt.runID) == events)
        await parentTurn.finish()
    }

    @Test func interruptedParentWaitingForAdmissionCreatesNoChild2519() async throws {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let heldRequest = ChildLaunchRequestID()
        let held = await governor.requestLaunch(sessionID: "held-budget2519", requestID: heldRequest)
        guard case .admitted = held else {
            Issue.record("expected the test's explicit budget reservation")
            return
        }
        defer {
            Task { await governor.releaseLaunch(sessionID: "held-budget2519", requestID: heldRequest) }
        }
        let store = AgentTaskStore()
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        await parentTurn.interrupt()
        let runner = OETestRunner(name: "unlaunched-runner2519")
        let orchestrator = AgentOrchestrator(
            turnController: controller,
            taskStore: store,
            parentID: "unlaunched-parent2519",
            childGovernor: governor
        ).withExternalRunner(runner)
        let output = try await OrchestrationToolExecutor(orchestrator: orchestrator).execute(
            name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "unlaunched-task2519", agent: "external:unlaunched-runner2519")],
                "strategy": "parallel",
            ]
        )
        // The occupied hard-one budget makes admission wait: unlike a free
        // local permit racing its cancellation monitor, no run can be created.
        #expect(output.contains("GLOBAL_CHILD_BUDGET_CANCELLED"))
        #expect(runner.callCount == 0)
        #expect(store.snapshot(taskID: "unlaunched-task2519") == nil)
        #expect(store.taskCenterSnapshots().isEmpty)
        #expect(store.allReceipts().isEmpty)
        let checkpoint = await governor.checkpoint()
        #expect(checkpoint.globalActive == 1)
        #expect(checkpoint.queuedSessions.isEmpty)
        await governor.releaseLaunch(sessionID: "held-budget2519", requestID: heldRequest)
        let released = await governor.checkpoint()
        #expect(released.globalActive == 0)
        await parentTurn.finish()
    }

    @Test func activeExternalRunnerReceivesParentCancellationAndSettlesCancelled() async throws {
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OETActiveCancellation2479-\(UUID().uuidString).json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let probe = OETestCancellationProbe()
        let runner = OETestRunner(
            name: "active-cancel-runner",
            cancellationProbe: probe,
            holdUntilCancellation: true
        )
        let orchestrator = AgentOrchestrator(
            turnController: controller,
            taskStore: store,
            parentID: "active-cancel-parent"
        ).withExternalRunner(runner)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)
        let invocation = Task {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "active-cancel-task", agent: "external:active-cancel-runner")],
            ])
        }

        await probe.waitUntilStarted()
        #expect(store.snapshot(taskID: "active-cancel-task")?.status == .running)
        #expect(runner.callCount == 1)
        await parentTurn.interrupt()
        await probe.waitUntilCancelled()
        let output = try await invocation.value

        #expect(try oetHasResult(output, id: "active-cancel-task", status: "failed", index: 0))
        #expect(output.contains("任务已取消"))
        #expect(await runner.cancellationCount == 1)
        let cancelledSnapshot = try #require(store.snapshot(taskID: "active-cancel-task"))
        #expect(cancelledSnapshot.parentID == "active-cancel-parent")
        #expect(cancelledSnapshot.status == .cancelled)
        #expect(store.allReceipts().count == 1)
        let cancelledReceipt = try #require(store.allReceipts().first)
        #expect(cancelledReceipt.taskID == cancelledSnapshot.taskID)
        #expect(cancelledReceipt.outcome == .cancelled)
        let attempt = try #require(store.attempts(runID: cancelledReceipt.runID).first)
        #expect(attempt.attemptID == cancelledReceipt.attemptID)
        #expect(attempt.status == .cancelled)
        let events = store.events(runID: cancelledReceipt.runID)
        #expect(events.map(\.kind) == [.started, .cancelled])
        #expect(events.allSatisfy { $0.runID == cancelledReceipt.runID })
        // Reopen the actual durable ledger; no test-side terminal mutation.
        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reopened.snapshot(taskID: "active-cancel-task") == cancelledSnapshot)
        #expect(reopened.allReceipts() == [cancelledReceipt])
        #expect(reopened.events(runID: cancelledReceipt.runID) == events)
        await parentTurn.finish()
    }

    @Test func duplicateTaskIDsAreRejectedBeforeDispatch() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "duplicate"), oetTaskJSON(id: "duplicate")],
            ])
        }
    }

    @Test func emptyTasksRemainCompatible() async throws {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        let summary = try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []])
        #expect((try oetStructuredResults(summary)).isEmpty)
    }

    @Test func fortyTasksWithExplicitFortyLimitReachTheGovernedTool() async throws {
        let selection = try ChildConcurrencySelection(userSelected: 40, recommended: 40, effective: 40)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 40))
        let runner = OETestRunner(name: "forty-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(
            childConcurrencySelection: selection,
            externalRunners: [runner.name: runner],
            childGovernor: governor
        ))
        let tasks = (1...40).map { oetTaskJSON(id: "task-\($0)", agent: "external:forty-runner") }

        let summary = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": tasks,
            "strategy": "parallel_with_limit",
            "limit": Int64(40),
        ])

        let results = try oetStructuredResults(summary)
        #expect(results.count == 40)
        #expect(results.first?["task_id"] as? String == "task-1")
        #expect(results.last?["task_id"] as? String == "task-40")
        #expect(results.allSatisfy { $0["status"] as? String == "succeeded" })
        #expect(runner.callCount == 40)
    }

    @Test func fortyLimitCannotOverrideLowerLiveSelectionWithModelSuppliedCapacity() async throws {
        let selection = try ChildConcurrencySelection(userSelected: 2, recommended: 2, effective: 2)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 40))
        let probe = OETestProbe()
        let provider = OETestProvider(probe: probe, barrier: OETestBarrier(expected: 2))
        let orchestrator = AgentOrchestrator(
            childConcurrencySelection: selection,
            maxIterationsPerTask: 2,
            childGovernor: governor
        ).withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        let summary = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": (1...4).map { oetTaskJSON(id: "low-\($0)") },
            "strategy": "parallel_with_limit",
            "limit": 40,
            "child_concurrency": ["selected": 40, "recommended": 40, "effective": 40],
        ])

        #expect((try oetStructuredResults(summary)).count == 4)
        #expect(await probe.maxActive == 2)
    }

    @Test func fortyTaskInputStillHonorsGovernorKillSwitch() async throws {
        let selection = try ChildConcurrencySelection(userSelected: 40, recommended: 40, effective: 40)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 40))
        await governor.engageKillSwitch()
        let runner = OETestRunner(name: "stopped-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(
            childConcurrencySelection: selection,
            externalRunners: [runner.name: runner],
            childGovernor: governor
        ))

        let summary = try await executor.execute(name: "orchestrate", input: [
            "input_version": OrchestrationToolExecutor.inputVersion,
            "tasks": (1...40).map { oetTaskJSON(id: "stopped-\($0)", agent: "external:stopped-runner") },
            "strategy": "parallel_with_limit",
            "limit": 40,
        ])

        #expect((try oetStructuredResults(summary)).count == 40)
        #expect(summary.contains("GLOBAL_CHILD_BUDGET_KILL_SWITCH"))
        #expect(runner.callCount == 0)
    }

    @Test func fortyOneTasksAreRejectedBeforeDispatch() async {
        let runner = OETestRunner(name: "overflow-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(externalRunners: [runner.name: runner]))
        let tasks = (1...41).map { oetTaskJSON(id: "t\($0)", agent: "external:overflow-runner") }
        await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": tasks])
        }
        #expect(runner.callCount == 0)
    }

    @Test func fortyOneParallelLimitIsRejectedBeforeDispatch() async {
        let runner = OETestRunner(name: "limit-overflow-runner")
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(externalRunners: [runner.name: runner]))
        await #expect(throws: ToolExecutorError.invalidParameter("limit")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1", agent: "external:limit-overflow-runner")],
                "strategy": "parallel_with_limit",
                "limit": 41,
            ])
        }
        #expect(runner.callCount == 0)
    }

    @Test func invalidStrategyThrowsInvalidParameter() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        await #expect(throws: ToolExecutorError.invalidParameter("strategy")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
                "strategy": "chaos",
            ])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("strategy")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": [oetTaskJSON(id: "t1")],
                "strategy": 42,
            ])
        }
    }
}

extension OrchestrationToolExecutorTests {
    @Test func orchestrateJSONStringTasksMatchNativeArrayBuiltinDispatch() async throws {
        #expect(OrchestrationToolExecutor.makeDefinition().parameters["tasks"]?.type == .string)
        for version in [1, OrchestrationToolExecutor.inputVersion] {
            var task = oetTaskJSON(id: "schema-shaped-task", title: "Synthetic child",
                instructions: "Return a synthetic completion only", agent: "builtin",
                providerID: nil, modelID: nil, configurationFingerprint: nil)
            if version == 2 { task["allowed_tool_names"] = [String]() }
            let tasks = [task]
            let encoded = try JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys])
            let string = try #require(String(data: encoded, encoding: .utf8))
            var seenInputs: [[String]] = []
            for representation in [tasks as Any, string as Any] {
                let provider = OETestProvider(probe: OETestProbe())
                let orchestrator = AgentOrchestrator(maxIterationsPerTask: 2)
                    .withBuiltinExecution(provider: provider, toolExecutor: OETestNoopExecutor())
                let executor = OrchestrationToolExecutor(orchestrator: orchestrator)
                let output = try await executor.execute(name: "orchestrate", input: [
                    "input_version": version, "tasks": representation, "strategy": "sequential"
                ])
                #expect((try oetStructuredResults(output)).count == 1)
                #expect(try oetHasResult(output, id: "schema-shaped-task", status: "succeeded"))
                #expect(provider.seenUserContents.count == 1)
                seenInputs.append(provider.seenUserContents)
            }
            #expect(seenInputs[0] == seenInputs[1])
        }
    }

    @Test func orchestrateJSONStringTasksRejectMalformedAndObjectShapes() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        for raw in ["[", "{}", "[1]", "null", "\"not-an-array\""] {
            await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
                try await executor.execute(name: "orchestrate", input: [
                    "input_version": OrchestrationToolExecutor.inputVersion, "tasks": raw
                ])
            }
        }
    }

    @Test func orchestrateJSONStringTasksPreserveDuplicateAndItemValidation() async throws {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        let duplicate = [oetTaskJSON(id: "duplicate"), oetTaskJSON(id: "duplicate")]
        let encoded = try JSONSerialization.data(withJSONObject: duplicate)
        let string = try #require(String(data: encoded, encoding: .utf8))
        await #expect(throws: ToolExecutorError.invalidParameter("tasks")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion, "tasks": string
            ])
        }
        await #expect(throws: ToolExecutorError.missingParameter("title")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": "[{\"id\":\"item\",\"instructions\":\"synthetic\"}]"
            ])
        }
    }

    @Test func orchestrateJSONStringTasksCheckFullOriginalArgumentBytesBeforeDecode() async {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        // tasks alone fits 256KiB and decodes to an empty array. The complete
        // arguments exceed that bound; normalization must not discard bytes.
        await #expect(throws: ToolExecutorError.invalidParameter("input")) {
            try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "tasks": String(repeating: " ", count: 260_000) + "[]",
                "system_prompt": String(repeating: "x", count: 4096)
            ])
        }
    }

    @Test func orchestrateJSONStringTasksKeepEmptyArrayCompatibility() async throws {
        let executor = OrchestrationToolExecutor(orchestrator: AgentOrchestrator())
        for tasks in [[Any]() as Any, "[]" as Any] {
            let output = try await executor.execute(name: "orchestrate", input: [
                "input_version": OrchestrationToolExecutor.inputVersion, "tasks": tasks
            ])
            #expect((try oetStructuredResults(output)).isEmpty)
        }
    }
}
