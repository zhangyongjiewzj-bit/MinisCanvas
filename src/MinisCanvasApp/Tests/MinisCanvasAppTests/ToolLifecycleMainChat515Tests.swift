import AppKit
import CryptoKit
import Darwin
import ApplicationServices
import SwiftUI
import os
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

enum Tool515Case: String, Sendable, CaseIterable {
    case readSuccess, shellFailure, mcpCancellation
    var name: String {
        switch self {
        case .readSuccess: "file_read"
        case .shellFailure: "shell_execute"
        case .mcpCancellation: "mcp_private_sample_query"
        }
    }
    var title: String {
        switch self {
        case .readSuccess: "读取文件"
        case .shellFailure: "执行命令"
        case .mcpCancellation: "MCP 工具调用"
        }
    }
    var terminal: ToolExecutionStatus {
        switch self {
        case .readSuccess: .succeeded
        case .shellFailure: .failed
        case .mcpCancellation: .cancelled
        }
    }
}

// The Core test target's MockLLMProvider is not linked into App tests.
// Keep the same canned FIFO responses at this fixture's actual provider boundary.
private final class Tool515Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "Mock"
    var model = LLMModel.claudeHaiku45
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = nil
    private let lock = NSLock()
    private var responses: [String]
    private var nativeResponses: [LLMResponse]?
    private var requestCount = 0
    var receivedRequestCount: Int { lock.withLock { requestCount } }
    init(responses: [String]) { self.responses = responses }
    init(nativeResponses: [LLMResponse]) { responses = []; self.nativeResponses = nativeResponses }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock {
            requestCount += 1
            if var queued = nativeResponses {
                let response = queued.isEmpty ? LLMResponse(text: "", stopReason: nil, usage: nil) : queued.removeFirst()
                nativeResponses = queued
                return response
            }
            let text = responses.isEmpty ? "" : responses.removeFirst()
            return LLMResponse(text: text, stopReason: nil, usage: nil)
        }
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class Tool515Executor: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    let sample: Tool515Case
    private let lock = NSLock()
    private var storedNames: [String] = []
    private let failureDetail: String
    private let builtin: BuiltinToolExecutor?
    private var readsReleased = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    init(sample: Tool515Case, failureDetail: String = "synthetic SECRET_SAMPLE515",
         builtin: BuiltinToolExecutor? = nil) {
        self.sample = sample; self.failureDetail = failureDetail; self.builtin = builtin
    }
    var currentBuiltinOwner: BuiltinToolExecutor? { builtin }
    var heldReadCount: Int { lock.withLock { readWaiters.count } }
    func releaseReads() {
        let waiters = lock.withLock {
            readsReleased = true
            defer { readWaiters.removeAll() }
            return readWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func holdRead() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let released = lock.withLock {
                    if readsReleased { return true }
                    readWaiters.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }, onCancel: { self.releaseReads() })
    }
    func executeBoundToBuiltinOwner(_ owner: BuiltinToolExecutor, name: String,
                                   input: [String: Any]) async throws -> String {
        guard builtin === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input)
    }
    var executedNames: [String] { lock.withLock { storedNames } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { storedNames.append(name) }
        switch sample {
        case .readSuccess:
            if let builtin {
                await holdRead()
                try Task.checkCancellation()
                return try await builtin.execute(name: name, input: input)
            }
            return "synthetic output SECRET_SAMPLE515"
        case .shellFailure: throw ToolExecutorError.invalidParameter(failureDetail)
        case .mcpCancellation: throw CancellationError()
        }
    }
}

// Approve only the exact request produced by the existing bound gate. The
// synthetic executor below has no file/shell/MCP effects; no policy is bypassed.
private actor Tool550ApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    private(set) var receipts: [ApprovalReceipt] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
                                requestID: request.requestID, bindingDigest: request.identityDigest)
    }
    func record(_ receipt: ApprovalReceipt) { receipts.append(receipt) }
}

private struct Tool515PermissionPretender: ToolExecutor {
    let cancelled: Bool
    func execute(name: String, input: [String: Any]) async throws -> String {
        if cancelled { throw CancellationError() }
        throw ToolExecutorError.permissionDenied("synthetic non-native refusal")
    }
}

private final class Tool515Phases: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolExecutionPhaseFact] = []
    func record(_ phase: ToolExecutionPhaseFact) {
        lock.lock(); defer { lock.unlock() }
        stored.append(phase)
    }
    var values: [ToolExecutionPhaseFact] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@MainActor
private final class Tool515Source {
    let consumer: ToolLifecycleConsumer
    var sessionID: String
    init(consumer: ToolLifecycleConsumer, sessionID: String) {
        self.consumer = consumer; self.sessionID = sessionID
    }
    func read() -> [MinisCore.ConversationEvent] {
        consumer.readOnlyProjection.events.filter {
            $0.identity.sessionID == sessionID && ($0.kind == .tool || $0.kind == .approval)
        }
    }
}

@Suite("D-TOOL-16/17 real dispatch facts reach mounted main-chat cards")
@MainActor
struct ToolLifecycleMainChat515Tests {
    @Test func persistentFileWriteSourceReachesTheCompletedNativeCardAndRevocationDoesNotReuseIt() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("persistent-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let path = project.appendingPathComponent("note.txt")
        let input: [String: Any] = ["path": path.path, "content": "owned card bytes"]
        let rules = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"),
            homeDirectory: "/nonexistent-owned-home")
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [project.path], workspaceID: "persistent-card-workspace",
            revision: "persistent-card-policy", grantEpoch: "persistent-card-epoch", leaseID: "persistent-card-lease",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        let rule = try #require(rules.makeRule(capability: "file_write", input: input, facts: facts))
        try #require(rules.add(rule))
        let receipts = OSAllocatedUnfairLock(initialState: [ComposerApprovalReceipt]())
        let consumer = ToolLifecycleConsumer()
        var completed: [MinisCore.ConversationEvent] = []
        for index in 0..<2 {
            if index == 1 { try #require(rules.remove(id: rule.id)) }
            let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
                sessionID: "persistent-card-session", turnID: index, taskID: "persistent-card-task-\(index)",
                attemptID: "persistent-card-attempt-\(index)", messageID: "persistent-card-message-\(index)",
                workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
                autonomyCeiling: .l3)
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: snapshot.sessionID, turnID: index, messageID: snapshot.messageID),
                operationID: "persistent-card-operation-\(index)", attempt: 1)
            let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
            let center = ApprovalPromptCenter()
            let callingExecutor = ComposerPolicyEnforcedToolExecutor(base: owner,
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts,
                    grants: ComposerApprovalGrantStore(persistentRules: rules)),
                approvalGate: ApprovalGate(policy: .alwaysAsk, delegate: ApprovalPromptDelegate(center: center)),
                onApprovalReceipt: { receipt in receipts.withLock { $0.append(receipt) } })
            let call = try JSONSerialization.data(withJSONObject: ["tool_calls": [
                ["id": "persistent-card-call-\(index)", "name": "file_write", "input": input]
            ]])
            let provider = Tool515Provider(responses: [String(decoding: call, as: UTF8.self), "done"])
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts-\(index).json"))
            let loop = AgentLoop(maxIterations: 2, loopDetector: nil, toolExecutionFactLedger: ledger)
            let running = Task<AgentLoopResult, Error> {
                try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: callingExecutor, tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
                    currentConversationID: snapshot.sessionID, composerSnapshot: snapshot, executionIdentity: identity)
            }
            defer { center.stopGeneration(); running.cancel() }
            if index == 1 {
                for _ in 0..<100 where center.pendingRequest == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(center.pendingRequest?.toolName == "file_write")
                center.resolve(approved: true, reason: "owned explicit approval", confirmed: true)
            }
            let result = try await running.value
            let expectedAttempt = try #require(AgentToolExecutionAttemptID.canonical(
                executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil))
            try #require(expectedAttempt == snapshot.attemptID)
            let fact = try #require(result.toolExecutionFacts.first { $0.toolName == "file_write" })
            try #require(await consumer.ingestToolExecutionFact(fact, eventID: fact.toolCallID,
                eventName: fact.toolName, taskID: snapshot.taskID, expectedAttemptID: expectedAttempt,
                scopeID: facts.workspaceID))
            let event = try #require(consumer.events.first { $0.id == fact.receiptID && $0.toolCompositeKey == fact.compositeKey && $0.toolCallID == fact.toolCallID })
            completed.append(event)
            let display = ToolEventCard.displayModel(for: event, approvalReceipts: receipts.withLock { $0 })
            if index == 0 {
                #expect(fact.status == .succeeded)
                #expect(try String(contentsOf: path, encoding: .utf8) == "owned card bytes")
                #expect(display.automaticExecutionNotice == "已按持久批准规则自动执行")
            } else {
                #expect(fact.status == .succeeded)
                #expect(display.automaticExecutionNotice == nil)
                #expect(receipts.withLock { $0.last?.persistentRuleID == nil })
            }
        }
        #expect(ToolEventCard.displayModel(for: completed[0],
            approvalReceipts: receipts.withLock { $0 }).automaticExecutionNotice == "已按持久批准规则自动执行")
        let lease = NativeTestHostLifecycle.begin("PersistentRuleCard")
        let controller = NSHostingController(rootView: VStack {
            ForEach(completed) { event in
                ToolEventCard(event: event, approvalReceipts: receipts.withLock { $0 })
                    .accessibilityIdentifier("chat-tool-event-\(event.id)")
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        SettingsNativeInteractionConsumerTests().pumpSettingsRunLoop()
        for (index, event) in completed.enumerated() {
            try await expectCard(eventID: event.id, title: "写入文件", status: "完成", in: window)
            let card = try #require(NativeConsumerOwnedAX.find(in: window,
                identifier: "chat-tool-event-\(event.id)"))
            #expect(NativeConsumerOwnedAX.role(card) == .button)
            let label = try #require(NativeConsumerOwnedAX.label(card))
            #expect(label.contains("已按持久批准规则自动执行") == (index == 0))
        }
    }

    @Test(arguments: ["skill_create", "skill_update", "skill_delete"])
    func persistentSkillSourceReachesTheCompletedNativeCardAndRevocationDoesNotReuseIt(name: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("persistent-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let store = SkillStore(skillsRoot: project.appendingPathComponent("skills"))
        let old = "---\nname: owned-card-skill\ndescription: owned card fixture\nversion: 1.0.0\n---\nold owned bytes"
        let replacement = "---\nname: owned-card-skill\ndescription: owned card fixture\nversion: 2.0.0\n---\nnew owned bytes"
        let maintenance = SkillMaintenanceTool(store: store, deletion: { intent in
            try store.deleteSkill(intent.targetID, intent: intent)
        })
        let rules = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"),
            homeDirectory: "/nonexistent-owned-home")
        let facts = ComposerPolicyFactSource(knownCapabilities: SkillMaintenanceTool.names, grantedCapabilities: SkillMaintenanceTool.names,
            allowedWriteRoots: [project.path], workspaceID: "persistent-card-workspace",
            revision: "persistent-card-policy", grantEpoch: "persistent-card-epoch", leaseID: "persistent-card-lease",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l3)
        let rule = try #require(rules.makeSkillBypassRule(capability: name, facts: facts))
        try #require(rules.add(rule))
        let receipts = OSAllocatedUnfairLock(initialState: [ComposerApprovalReceipt]())
        let consumer = ToolLifecycleConsumer()
        var completed: [MinisCore.ConversationEvent] = []
        for index in 0..<2 {
            if index == 1 { try #require(rules.remove(id: rule.id)) }
            // Re-establish only this owned target so each real mutation has a valid reviewed baseline.
            if name == "skill_create" {
                if store.rawContent("owned-card-skill") != nil {
                    let intent = try store.previewDeletion(skillID: "owned-card-skill")
                        .withFirstConfirmation("owned reset").withSecondConfirmation("owned reset")
                    _ = try store.deleteSkill("owned-card-skill", intent: intent)
                }
            } else {
                _ = try store.importSkillThroughLifecycle(content: old, source: .file,
                    reason: "owned baseline", approval: SkillApproval(approverID: "owned-reviewer"))
            }
            var input: [String: Any] = ["skillID": "owned-card-skill"]
            if name != "skill_create" { input["expectedContentHash"] = SkillManifest.hash(old) }
            if name != "skill_delete" { input["content"] = replacement }
            let snapshot = ComposerSubmissionSnapshot(mode: index == 0 ? .bypassPermission : .manual, approvalScope: .request, effort: .standard,
                sessionID: "persistent-card-session", turnID: index, taskID: "persistent-card-task-\(index)",
                attemptID: "persistent-card-attempt-\(index)", messageID: "persistent-card-message-\(index)",
                workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
                bypassModeConfirmed: index == 0, autonomyCeiling: .l3)
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: snapshot.sessionID, turnID: index, messageID: snapshot.messageID),
                operationID: "persistent-card-operation-\(index)", attempt: 1)
            let owner = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [], skillMaintenance: maintenance)
            let center = ApprovalPromptCenter()
            let callingExecutor = ComposerPolicyEnforcedToolExecutor(base: owner,
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts,
                    grants: ComposerApprovalGrantStore(persistentRules: rules), liveSkillBypassConfirmed: { index == 0 }),
                approvalGate: ApprovalGate(policy: .alwaysAsk, delegate: ApprovalPromptDelegate(center: center)),
                skillMaintenance: maintenance,
                onApprovalReceipt: { receipt in receipts.withLock { $0.append(receipt) } })
            let arguments = try JSONSerialization.data(withJSONObject: input)
            let call = LLMToolCall(id: "persistent-card-call-\(index)", name: name,
                rawArguments: String(decoding: arguments, as: UTF8.self), arguments: input)
            let provider = Tool515Provider(nativeResponses: [
                LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [call]),
                LLMResponse(text: "done", stopReason: nil, usage: nil)
            ])
            let targets = ToolTargetDisplayStore()
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts-\(index).json"))
            let loop = AgentLoop(maxIterations: 2, loopDetector: nil, toolExecutionFactLedger: ledger)
            let running = Task<AgentLoopResult, Error> {
                try await loop.run(messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: callingExecutor, tools: SkillMaintenanceTool.definitions().filter { $0.name == name },
                    currentConversationID: snapshot.sessionID, composerSnapshot: snapshot, executionIdentity: identity,
                    onMessage: { _, message in
                        for call in message.toolCalls { targets.record(call) }
                    })
            }
            defer { center.stopGeneration(); running.cancel() }
            if index == 1 {
                for _ in 0..<100 where center.pendingRequest == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(center.pendingRequest?.toolName == name)
                center.resolve(approved: true, reason: "owned explicit approval", confirmed: true)
            }
            let result = try await running.value
            let expectedAttempt = try #require(AgentToolExecutionAttemptID.canonical(
                executionIdentity: identity, composerSnapshot: snapshot, childBoundary: nil))
            try #require(expectedAttempt == snapshot.attemptID)
            let fact = try #require(result.toolExecutionFacts.first { $0.toolName == name })
            try #require(await consumer.ingestToolExecutionFact(fact, eventID: fact.toolCallID,
                eventName: fact.toolName, taskID: snapshot.taskID, expectedAttemptID: expectedAttempt,
                scopeID: facts.workspaceID,
                toolTargetDisplay: targets.display(for: fact.toolCallID)))
            let event = try #require(consumer.events.first { $0.id == fact.receiptID && $0.toolCompositeKey == fact.compositeKey && $0.toolCallID == fact.toolCallID })
            completed.append(event)
            #expect(store.rawContent("owned-card-skill") == (name == "skill_delete" ? nil : replacement))
            #expect(event.toolTargetDisplay == "owned-card-skill")
            let display = ToolEventCard.displayModel(for: event, approvalReceipts: receipts.withLock { $0 })
            if index == 0 {
                #expect(fact.status == .succeeded)
                #expect(display.automaticExecutionNotice == "已按持久批准规则自动执行")
            } else {
                #expect(fact.status == .succeeded)
                #expect(display.automaticExecutionNotice == nil)
                #expect(receipts.withLock { $0.last?.persistentRuleID == nil })
            }
        }
        #expect(ToolEventCard.displayModel(for: completed[0],
            approvalReceipts: receipts.withLock { $0 }).automaticExecutionNotice == "已按持久批准规则自动执行")
        let lease = NativeTestHostLifecycle.begin("PersistentRuleCard")
        let controller = NSHostingController(rootView: VStack {
            ForEach(completed) { event in
                ToolEventCard(event: event, approvalReceipts: receipts.withLock { $0 })
                    .accessibilityIdentifier("chat-tool-event-\(event.id)")
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        SettingsNativeInteractionConsumerTests().pumpSettingsRunLoop()
        for (index, event) in completed.enumerated() {
            try await expectCard(eventID: event.id, title: name == "skill_create" ? "创建技能" : name == "skill_update" ? "修改技能" : "删除技能", status: "完成", in: window)
            let card = try #require(NativeConsumerOwnedAX.find(in: window,
                identifier: "chat-tool-event-\(event.id)"))
            #expect(NativeConsumerOwnedAX.role(card) == .button)
            let label = try #require(NativeConsumerOwnedAX.label(card))
            #expect(label.contains("owned-card-skill"))
            #expect(label.contains("已按持久批准规则自动执行") == (index == 0))
        }
    }

    @Test func actualConcurrentReadPhasesReachTheExistingNativeBatchNode() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("n15-native-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("read.txt")
        try "N15 actual owned output".write(to: path, atomically: true, encoding: .utf8)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let consumer = try ToolLifecycleConsumer(persistenceURL: root.appendingPathComponent("events.json"))
        let session = UUID()
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: session.uuidString,
            turnID: 1, messageID: "n15-native-message"), operationID: "n15-native-operation", attempt: 1)
        let calls: [[String: Any]] = ["n15-native-a", "n15-native-b", "n15-native-c"].map {
            ["id": $0, "name": "file_read", "input": ["path": path.path]]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["tool_calls": calls])
        let provider = Tool515Provider(responses: [String(decoding: payload, as: UTF8.self), "done"])
        let executor = Tool515Executor(sample: .readSuccess, builtin: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []))
        let phases = Tool515Phases()
        var loop = AgentLoop(maxIterations: 2, loopDetector: nil, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phases.record($0) }
        let executionLoop = loop
        let catalog = AgentToolCatalog.makeTools().filter { $0.name == "file_read" }
        let running = Task {
            try await executionLoop.run(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: executor, tools: catalog, executionIdentity: identity)
        }
        do {
        let deadline = Task { try await Task.sleep(for: .seconds(8)); executor.releaseReads(); running.cancel() }
        defer { deadline.cancel(); executor.releaseReads(); running.cancel() }
        for _ in 0..<200 {
            if executor.heldReadCount == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(executor.heldReadCount == 3)
        #expect(provider.receivedRequestCount == 1)
        let livePhases = phases.values
        #expect(livePhases.filter { $0.phase == .running }.count == 3)
        for phase in livePhases {
            #expect(await consumer.ingestToolExecutionPhase(phase, eventID: phase.compositeKey.toolCallID,
                eventName: phase.toolName, taskID: "n15-native-task",
                expectedAttemptID: phase.compositeKey.attemptID, scopeID: "n15-owned-scope"))
        }
        let live = consumer.readOnlyProjection.events
        let first = try #require(live.first { $0.status == .running })
        #expect(ToolEventCard.concurrentRunningCount(for: first, events: live) == 3)
        let firstKey = try #require(first.toolCompositeKey)
        for (foreignSession, foreignOperation) in [(UUID().uuidString, firstKey.operationID), (firstKey.sessionID, "other-operation")] {
            let foreignIdentityCandidate: MinisCore.ConversationEventIdentity? = .init(sessionID: foreignSession,
                turnID: String(firstKey.turnID), taskID: "foreign-child", attempt: firstKey.attemptNumber, scopeID: "n15-owned-scope")
            let foreignIdentity = try #require(foreignIdentityCandidate)
            let foreignKey = ToolExecutionCompositeKey(sessionID: foreignSession, turnID: firstKey.turnID,
                messageID: "foreign-message", operationID: foreignOperation, attemptID: firstKey.attemptID,
                attemptNumber: firstKey.attemptNumber, toolCallID: "foreign-call")
            // Negative input only; the positive cohort above comes from the
            // actual Loop's phases and constrained Builtin dispatch.
            let foreign = MinisCore.ConversationEvent(id: foreignKey.rawValue, identity: foreignIdentity,
                sequence: 999, occurredAt: Date(), kind: .tool, status: .running,
                summary: "foreign", toolName: "file_read", toolCallID: foreignKey.toolCallID, toolCompositeKey: foreignKey)
            #expect(ToolEventCard.concurrentRunningCount(for: first, events: live + live + [foreign]) == 3)
        }
        let lease = NativeTestHostLifecycle.begin("N15ActualBatch515")
        let controller = NSHostingController(rootView: ChatTranscriptToolNode(group: .init(id: "n15-batch", events: live))
            .frame(width: 720, height: 260))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("N15ActualBatch515-" + UUID().uuidString)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        try await expectCard(eventID: first.id, title: "读取文件", status: "进行中", expandGroup: true, in: window)
        let node = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-turn-n15-batch"))
        #expect(NativeConsumerOwnedAX.label(node)?.contains("同时 3 项") == true)
        executor.releaseReads()
        let result = try await running.value
        #expect(provider.receivedRequestCount == 2)
        #expect(result.toolExecutionFacts.count == 3 && result.toolExecutionFacts.allSatisfy { $0.status == .succeeded && $0.elapsedMilliseconds != nil })
        for fact in result.toolExecutionFacts {
            let key = try #require(fact.compositeKey)
            #expect(await consumer.ingestToolExecutionFact(fact, eventID: fact.toolCallID,
                eventName: fact.toolName, taskID: "n15-native-task", expectedAttemptID: key.attemptID, scopeID: "n15-owned-scope"))
        }
        let completed = consumer.readOnlyProjection.events
        #expect(ToolEventCard.concurrentRunningCount(for: first, events: completed + live) == 0)
        for phase in livePhases {
            #expect(!(await consumer.ingestToolExecutionPhase(phase, eventID: phase.compositeKey.toolCallID,
                eventName: phase.toolName, taskID: "n15-native-task", expectedAttemptID: phase.compositeKey.attemptID, scopeID: "n15-owned-scope")))
        }
        #expect(consumer.readOnlyProjection.events.allSatisfy { $0.status.isTerminal })
        let owner = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
        await owner.cancelAndDrainForApplicationExit()
        } catch {
            executor.releaseReads()
            running.cancel()
            _ = try? await running.value
            let owner = await ToolExecutionOwnershipRegistry.shared.ownership(for: executor)
            await owner.cancelAndDrainForApplicationExit()
            throw error
        }
    }

    @Test("native read refusal reaches the existing card only after its exact durable settlement",
          arguments: ["native", "sameNameNonNative", "forgedMCP", "cancelled", "preflightDenied"])
    func nativeReadRefusalFeedbackKeepsIdentityAndLegacyJournal(sample: String) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("native-read-feedback-\(UUID().uuidString)")
        let file = root.appendingPathComponent("permission.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { _ = chmod(file.path, mode_t(0o600)); try? FileManager.default.removeItem(at: root) }
        let original = Data("owned permission fixture".utf8)
        try original.write(to: file)
        try #require(chmod(file.path, mode_t(0o600)) == 0)
        var before = stat()
        try #require(lstat(file.path, &before) == 0 && before.st_uid == geteuid())
        try #require(chmod(file.path, mode_t(0o000)) == 0)
        let factURL = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: factURL)
        let consumerURL = root.appendingPathComponent("events.json")
        let consumer = try ToolLifecycleConsumer(persistenceURL: consumerURL)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "native-read-session", turnID: 1, messageID: "native-read-message"),
            operationID: "native-read-operation", attempt: 1)
        let name = sample == "forgedMCP" ? "mcp_synthetic_read" : "file_read"
        let input: [String: Any] = ["path": file.path]
        // This fixture uses Core ApprovalGate, not Composer's enum-valued input digest.
        // Independently encode its one known field; never copy the observed request hash.
        try #require(file.path.unicodeScalars.allSatisfy {
            (0x20...0x7e).contains($0.value) && $0.value != 0x22 && $0.value != 0x5c
        })
        let expectedPayload = Data(("{\"path\":\"" + file.path + "\"}").utf8)
        let expectedInput = SHA256.hash(data: expectedPayload).map { String(format: "%02x", $0) }.joined()
        let object: [String: Any] = ["tool_calls": [["id": "native-read-call", "name": name, "input": input]]]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let approvals = Tool550ApprovalDelegate()
        let gate = ApprovalGate(policyByTool: [name: sample == "preflightDenied" ? .deny : .alwaysAsk],
                                delegate: approvals)
        var loop = AgentLoop(maxIterations: 2, approvalGate: gate,
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        let accumulator = TurnToolCallAccumulator()
        defer { accumulator.closeSettlementObservations() }
        let feedbackStream = AsyncStream<(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)>.makeStream()
        loop.onToolExecutionPhase = { phase in
            accumulator.observeSettlement(for: phase, ledger: ledger) { fact, feedback in
                // Reading the durable state here also exercises the original lock-free delivery boundary.
                #expect(ledger.facts.contains(fact))
                feedbackStream.continuation.yield((fact, feedback))
            }
        }
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let executor: any ToolExecutor
        switch sample {
        case "sameNameNonNative", "cancelled":
            executor = Tool515PermissionPretender(cancelled: sample == "cancelled")
        case "forgedMCP":
            executor = Tool515Executor(sample: .shellFailure,
                failureDetail: "{\"reason\":\"builtinFileReadPermissionDenied\"} 读取被拒绝：没有访问此文件的权限")
        default: executor = builtin
        }
        let tool = AgentToolDefinition(name: name, description: "owned read fixture", parameters: [:], required: [])
        let outcome = await loop.runOutcome(messages: [], systemPrompt: nil,
            provider: Tool515Provider(responses: [response, "done"]),
            toolExecutor: ConcurrentToolLimitingExecutor(base: executor, maxConcurrent: 1), tools: [tool],
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "native-read-task", actorID: "owned-test"),
            executionIdentity: identity)
        feedbackStream.continuation.finish()
        var delivered: [(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)] = []
        for await value in feedbackStream.stream { delivered.append(value) }
        if sample == "preflightDenied" {
            #expect(delivered.isEmpty && ledger.facts.isEmpty && outcome.toolExecutionFacts.isEmpty)
        } else {
            let fact = try #require(outcome.toolExecutionFacts.only)
            #expect(fact.status == (sample == "cancelled" ? .cancelled : .failed))
            #expect(delivered.count == 1 && delivered.first?.0 == fact)
            let feedback = delivered.first?.1
            #expect((feedback != nil) == (sample == "native"))
            if let feedback {
                #expect(feedback.compositeKey == fact.compositeKey && feedback.receiptID == fact.receiptID)
                #expect(feedback.executionIdentity == identity && feedback.reason == .builtinFileReadPermissionDenied)
                let request = try #require(await approvals.requests.first)
                #expect(request.toolName == name)
                #expect(request.inputDigest == expectedInput && request.callID == fact.toolCallID)
                #expect(request.sessionID == identity.turn.sessionID && request.attemptID == fact.attemptID)
            }
            let key = try #require(fact.compositeKey)
            #expect(await consumer.ingestToolExecutionFact(fact, eventID: key.toolCallID,
                eventName: name, taskID: "native-read-task", expectedAttemptID: key.attemptID,
                scopeID: "owned-scope", liveFailureFeedback: feedback))
            let event = try #require(consumer.readOnlyProjection.events.only)
            let card = ToolEventCard.displayModel(for: event)
            #expect(card.summary.contains("读取被拒绝：没有访问此文件的权限") == (sample == "native"))
            #expect(card.status == (sample == "cancelled" ? "已取消" : "失败"))
            #expect(!card.summary.contains(file.path) && !card.summary.contains("builtinFileReadPermissionDenied"))
            #expect(!(await consumer.ingestToolExecutionFact(fact, eventID: key.toolCallID,
                eventName: name, taskID: "native-read-task", expectedAttemptID: key.attemptID,
                scopeID: "owned-scope", liveFailureFeedback: feedback)))
            let cold = try ToolLifecycleConsumer(persistenceURL: consumerURL)
            #expect(cold.readOnlyProjection.events == consumer.readOnlyProjection.events)
            let coldEvent = try #require(cold.readOnlyProjection.events.only)
            #expect(ToolEventCard.displayModel(for: coldEvent) == card)
            #expect(!accumulator.claimForwarding(fact))
            if let feedback {
                let foreignIdentity = AgentExecutionIdentity(turn: identity.turn,
                    operationID: "foreign-operation", attempt: 1)
                let receipt = try ledger.mint(toolCallID: "foreign-call", toolName: "file_read",
                    attemptID: "foreign-attempt", attemptNumber: 1, executionIdentity: foreignIdentity)
                let foreign = try #require(try ledger.settle(receipt, status: .failed, elapsedMilliseconds: 1))
                let foreignKey = try #require(foreign.compositeKey)
                let foreignConsumer = ToolLifecycleConsumer()
                #expect(await foreignConsumer.ingestToolExecutionFact(foreign, eventID: foreignKey.toolCallID,
                    eventName: "file_read", taskID: "foreign-task", expectedAttemptID: foreignKey.attemptID,
                    scopeID: "owned-scope", liveFailureFeedback: feedback))
                let foreignEvent = try #require(foreignConsumer.readOnlyProjection.events.only)
                #expect(!ToolEventCard.displayModel(for: foreignEvent).summary.contains("读取被拒绝"))
            }
            let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
            #expect(reopened.facts.contains(fact))
            let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: factURL)) as? [String: Any])
            #expect(raw["schemaVersion"] as? Int == 6)
            let rawFacts = try #require(raw["facts"] as? [String: [String: Any]])
            #expect(rawFacts.values.allSatisfy { $0["liveFailureFeedback"] == nil && $0["liveFailureReason"] == nil })
        }
        try #require(chmod(file.path, mode_t(0o600)) == 0)
        var after = stat()
        #expect(lstat(file.path, &after) == 0 && after.st_uid == before.st_uid
            && after.st_dev == before.st_dev && after.st_ino == before.st_ino
            && (after.st_mode & mode_t(0o777)) == 0o600)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("native shell timeout facts retain timeout through the production event consumer",
          arguments: ["nativeTimeout", "ordinaryFailure", "forgedMCPText"])
    func nativeTimeoutAndUntrustedFailureTextKeepDistinctCards(sample: String) async throws {
        let profileCandidate = RuntimeIsolationProfile.formalTestProfileForDefaultConsumer()
        let profile = try #require(profileCandidate)
        let root = profile.rootDirectory.appendingPathComponent("tool-timeout-category-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let consumer = try ToolLifecycleConsumer(persistenceURL: root.appendingPathComponent("events.json"))
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "timeout-session", turnID: 1, messageID: "timeout-message"),
            operationID: "timeout-operation", attempt: 1)
        let name = sample == "forgedMCPText" ? "mcp_private_sample_query"
            : sample == "ordinaryFailure" ? "file_read" : "shell_execute"
        let input: [String: Any] = sample == "ordinaryFailure"
            ? ["path": root.appendingPathComponent("missing.txt").path]
            : ["command": "printf START; sleep 2; printf LATE", "timeout": 0.1]
        let envelope: [String: Any] = ["tool_calls": [["id": "typed-timeout-call", "name": name, "input": input]]]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let approvals = Tool550ApprovalDelegate()
        let loop = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(policyByTool: [name: .alwaysAsk], delegate: approvals),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let executor: any ToolExecutor = sample == "forgedMCPText"
            ? Tool515Executor(sample: .shellFailure,
                failureDetail: "shellTimeout timed_out=true {\"failureCategory\":\"timeout\"}") : builtin
        let tool = AgentToolDefinition(name: name, description: "owned timeout fixture", parameters: [:], required: [])
        let outcome = await loop.runOutcome(messages: [], systemPrompt: nil,
            provider: Tool515Provider(responses: [response, "done"]),
            toolExecutor: ConcurrentToolLimitingExecutor(base: executor, maxConcurrent: 4), tools: [tool],
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "timeout-task", actorID: "owned-test"),
            executionIdentity: identity)
        #expect(outcome.failure == nil && outcome.result != nil)
        let fact = try #require(outcome.toolExecutionFacts.only)
        #expect(fact.status == .failed && fact.executionIdentity == identity)
        #expect(fact.failureCategory == (sample == "nativeTimeout" ? .timeout : nil))
        #expect(ledger.facts == [fact] && ledger.pendingReceipts.isEmpty)
        let key = try #require(fact.compositeKey)
        #expect(await consumer.ingestToolExecutionFact(fact, eventID: key.toolCallID,
            eventName: name, taskID: "timeout-task", expectedAttemptID: key.attemptID, scopeID: "owned-scope"))
        let event = try #require(consumer.readOnlyProjection.events.only)
        #expect(event.errorCategory == (sample == "nativeTimeout" ? .timeout : .tool))
        let card = ToolEventCard.displayModel(for: event)
        #expect(card.status == (sample == "nativeTimeout" ? "超时" : "失败"))
        #expect(card.elapsed != "未记录")
        #expect(!card.summary.contains("timed_out") && !card.summary.contains("failureCategory"))
    }

    @Test("producer-owned queued/running/terminal and safe expandable details reproject in one host",
          arguments: Tool515Case.allCases)
    func dispatchedFactsReprojectWithoutInspector(sample: Tool515Case) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("tool515-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let consumer = try ToolLifecycleConsumer(persistenceURL: root.appendingPathComponent("events.json"))
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "session515", turnID: 1, messageID: "message515"),
            operationID: "operation515", attempt: 1)
        let phases = Tool515Phases()
        let approvals = Tool550ApprovalDelegate()
        // Production registers discovered MCP names as known, alwaysAsk. Keep
        // that classification and the existing defaults for file_read/shell.
        let gate = ApprovalGate(policyByTool: ["mcp_private_sample_query": .alwaysAsk],
            delegate: approvals, onApprovalReceipt: { await approvals.record($0) })
        var loop = AgentLoop(maxIterations: 2, approvalGate: gate,
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        loop.onToolExecutionPhase = { phases.record($0) }
        let object: [String: Any] = ["tool_calls": [["id": "call515", "name": sample.name,
                                                    "input": ["payload": "SECRET_SAMPLE515"]]]]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let tool = AgentToolDefinition(name: sample.name, description: "owned synthetic tool", parameters: [:], required: [])
        let executor = Tool515Executor(sample: sample)
        // Preserve the original preflight counterexample: all three supplied
        // inputs are high/unclassified risk. A missing gate must yield no
        // executor effect, receipt or phase, rather than invented progress.
        #expect(ApprovalGate.inputRiskLevel(tool: sample.name,
            input: ["payload": "SECRET_SAMPLE515"]) == (sample == .mcpCancellation ? .low : .high))
        let blockedLedger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("blocked-facts.json"))
        let blockedPhases = Tool515Phases()
        var blockedLoop = AgentLoop(maxIterations: 2, toolExecutionFactLedger: blockedLedger)
        blockedLoop.onToolExecutionPhase = { blockedPhases.record($0) }
        let blocked = await blockedLoop.runOutcome(messages: [], systemPrompt: nil,
            provider: Tool515Provider(responses: [response, "done"]),
            toolExecutor: ConcurrentToolLimitingExecutor(base: executor, maxConcurrent: 4), tools: [tool], executionIdentity: identity)
        let blockedResult = try #require(blocked.result)
        #expect(blocked.failure == nil)
        let blockedErrors = blockedResult.messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> Bool? in
            guard case .toolResult(let id, _, _, let isError, _, _, _, _) = part,
                  id == "call515" else { return nil }
            return isError
        }
        #expect(blockedErrors == [true])
        #expect(blockedResult.toolCallsExecuted == 0)
        #expect(blockedResult.messages.contains {
            $0.content.contains(ToolExecutorError.approvalRequired(sample.name).localizedDescription)
        })
        #expect(blockedPhases.values.isEmpty)
        #expect(blocked.toolExecutionFacts.isEmpty && blockedLedger.facts.isEmpty)
        #expect(executor.executedNames.isEmpty)
        // Actual AgentLoop dispatch and durable facts; this executor never reads
        // files, starts a shell/MCP backend, or sends a network request.
        let outcome = await loop.runOutcome(messages: [], systemPrompt: nil,
            provider: Tool515Provider(responses: [response, "done"]),
            toolExecutor: ConcurrentToolLimitingExecutor(base: executor, maxConcurrent: 4), tools: [tool],
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "task515", actorID: "synthetic550"),
            executionIdentity: identity)
        let requests = await approvals.requests
        let request = try #require(requests.only)
        let binding = try #require(request.binding)
        #expect(request.toolName == sample.name && request.callID == "call515")
        // The discovered MCP is alwaysAsk, with an unclassified .medium tool
        // risk and a .low payload input. Approval policy is separate from risk.
        let expectedRisk: ApprovalRiskLevel = sample == .mcpCancellation ? .medium : .high
        #expect(request.requiresApproval)
        #expect(request.riskLevel == expectedRisk)
        #expect(binding.actorID == "synthetic550" && binding.scope == "request")
        #expect(binding.sessionID == identity.turn.sessionID && binding.turnID == identity.turn.turnID)
        #expect(binding.taskID == "task515" && binding.runID == identity.operationID)
        #expect(binding.attemptID == "\(identity.operationID):attempt:\(identity.attempt)")
        let receipts = await approvals.receipts
        let receipt = try #require(receipts.only)
        #expect(receipt.requestID == request.requestID && receipt.identityDigest == request.identityDigest)
        #expect(receipt.riskLevel == expectedRisk)
        #expect(executor.executedNames == [sample.name])
        if sample == .mcpCancellation {
            #expect(outcome.result == nil)
            let failure = try #require(outcome.failure)
            #expect(failure.agentError == nil)
            #expect(failure.message == CancellationError().localizedDescription)
        } else {
            #expect(outcome.result != nil)
            #expect(outcome.failure == nil)
        }
        #expect(phases.values.map(\.phase) == [.queued, .running])
        let terminal = try #require(outcome.toolExecutionFacts.only)
        #expect(terminal.status == sample.terminal)
        #expect(terminal.elapsedMilliseconds != nil)
        #expect(terminal.compositeKey == phases.values.last?.compositeKey)
        #expect(ledger.facts.contains(terminal))
        #expect(!String(decoding: try JSONEncoder().encode(phases.values), as: UTF8.self).contains("SECRET_SAMPLE515"))

        let source = Tool515Source(consumer: consumer, sessionID: identity.turn.sessionID)
        let lease = NativeTestHostLifecycle.begin("ToolLive515")
        let host = NSHostingView(rootView: TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            ChatTranscriptToolNode(group: .init(id: String(identity.turn.turnID), events: source.read()))
        }.frame(width: 720, height: 240))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("ToolLive515-" + UUID().uuidString)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        window.layoutIfNeeded()
        let contentFrame = try #require(window.contentView?.frame)
        try #require(window.frame.width > 0 && window.frame.height > 0
            && contentFrame.width > 0 && contentFrame.height > 0,
            "ToolLive515 requires a nonzero owned host before native rendering")
        let key = try #require(terminal.compositeKey)
        for (phase, title) in zip(phases.values, ["排队中", "进行中"]) {
            #expect(await consumer.ingestToolExecutionPhase(phase, eventID: key.toolCallID,
                eventName: sample.name, taskID: "task515", expectedAttemptID: key.attemptID, scopeID: "scope515"))
            let event = try #require(source.read().only)
            try await expectCard(eventID: event.id, title: sample.title, status: title,
                                 expandGroup: phase.phase == .queued, in: window)
            #expect(ToolEventCard.displayModel(for: event).elapsed == "未记录")
        }
        #expect(await consumer.ingestToolExecutionFact(terminal, eventID: key.toolCallID,
            eventName: sample.name, taskID: "task515", expectedAttemptID: key.attemptID, scopeID: "scope515"))
        let event = try #require(source.read().only)
        let expected = ToolEventCard.displayModel(for: event)
        try await expectCard(eventID: event.id, title: sample.title, status: expected.status, in: window)
        #expect(expected.elapsed != "未记录")
        #expect(!expected.summary.contains("SECRET_SAMPLE515"))
        #expect(!expected.accessibilityLabel.contains("private_sample"))
        let card = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-event-\(event.id)"))
        #expect(NativeConsumerOwnedAX.role(card) == .button)
        #expect(NativeConsumerOwnedAX.press(card))
        try await expectValue(eventID: event.id, contains: "详情已展开", in: window)
        let expandedCard = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-event-\(event.id)"))
        let value = try #require(NativeConsumerOwnedAX.attribute(expandedCard, kAXValueAttribute as CFString) as? String)
        #expect(value.contains(expected.summary))
        #expect(!value.contains("SECRET_SAMPLE515"))
        #expect(!value.contains("private_sample"))
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "chat-inspector") == true)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "task-center") == true)
        let frozen = consumer.events
        source.sessionID = "foreign-session515"
        try await expectAbsent(in: window)
        #expect(consumer.events == frozen)
        source.sessionID = identity.turn.sessionID
        try await expectCard(eventID: event.id, title: sample.title, status: expected.status, in: window)
        #expect(consumer.events == frozen)
        NativeTestHostLifecycle.observe(window, phase: "real-dispatch-facts-rendered")
    }

    @Test("typed observed approval uses the same safe card; no authority decision invents waiting")
    func observedApprovalProjectsSafeWaitingAndCancellation() async throws {
        _ = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let consumer = ToolLifecycleConsumer()
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "approval-session515", turnID: 2, messageID: "approval-message515"),
            operationID: "approval-operation515", attempt: 1)
        let key = ToolExecutionCompositeKey(sessionID: identity.turn.sessionID, turnID: 2,
            messageID: identity.turn.messageID, operationID: identity.operationID,
            attemptID: "approval-attempt515", attemptNumber: 1, toolCallID: "approval-call515")
        let name = "mcp_private_sample_query"
        let bound = ApprovalAuthorizationContext(actorID: "actor515", sessionID: key.sessionID,
            turnID: key.turnID, taskID: "approval-task515", runID: key.operationID,
            attemptID: key.attemptID, effectID: key.toolCallID, scope: "request",
            payloadDigest: "synthetic-digest515", expiresAt: Date().addingTimeInterval(600),
            policyRevision: "policy515", grantEpoch: "epoch515", toolName: name)
        let request = ApprovalRequest(id: "approval515", requestID: "approval515", callID: key.toolCallID,
            toolName: name, inputSummary: "SECRET_SAMPLE515", riskLevel: .high, requiresApproval: true,
            sessionID: key.sessionID, turnID: key.turnID, taskID: bound.taskID, attemptID: key.attemptID,
            approvalScope: "request", messageID: key.operationID, policyRevision: bound.policyRevision,
            grantEpoch: bound.grantEpoch, inputDigest: bound.payloadDigest, identityDigest: bound.identityDigest,
            actorID: bound.actorID, runID: key.operationID, effectID: key.toolCallID, expiresAt: bound.expiresAt)
        let context = ApprovalPresentationContext(compositeKey: key, executionIdentity: identity,
            toolName: name, eventSink: { _ in })
        let cancelled = try #require(context.makeFact(for: request, stage: .authorityCancelled))
        #expect(!(await consumer.ingestApprovalLifecycleFact(cancelled)))
        #expect(consumer.events.isEmpty)
        let presented = try #require(context.makeFact(for: request, stage: .presented))
        #expect(await consumer.ingestApprovalLifecycleFact(presented))
        let source = Tool515Source(consumer: consumer, sessionID: identity.turn.sessionID)
        let event = try #require(source.read().only)
        #expect(event.status == .waiting && event.kind == .approval)
        let display = ToolEventCard.displayModel(for: event)
        #expect(display.kind == "审批 · MCP 工具调用")
        #expect(display.elapsed == "未记录")
        #expect(!display.summary.contains("SECRET_SAMPLE515"))
        #expect(!display.accessibilityLabel.contains("private_sample"))

        // This is a synthetic observed-presentation fact factory, not an App
        // approval controller or an authorization grant. No executor is bound.
        let lease = NativeTestHostLifecycle.begin("ToolApproval515")
        let controller = NSHostingController(rootView: TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            ChatTranscriptToolNode(group: .init(id: String(identity.turn.turnID), events: source.read()))
                .frame(width: 720, height: 240)
        })
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        try await expectCard(eventID: event.id, title: "审批 · MCP 工具调用", status: "等待中",
                             expandGroup: true, in: window)
        #expect(await consumer.ingestApprovalLifecycleFact(cancelled))
        try await expectCard(eventID: event.id, title: "审批 · MCP 工具调用", status: "已取消", in: window)
        #expect(consumer.events.count == 1)
        #expect(consumer.toolLifecycleEvents.isEmpty)
    }

    private func expectCard(eventID: String, title: String, status: String,
                            expandGroup: Bool = false, in window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(4)
        var label: String?
        var expanded = false
        var firstMismatch: String?
        repeat {
            window.layoutIfNeeded()
            if expandGroup, !expanded,
               NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-event-\(eventID)") == nil,
               let group = NativeConsumerOwnedAX.find(in: window, identifierPrefix: "chat-tool-turn-") {
                try #require(NativeConsumerOwnedAX.press(group))
                expanded = true
            }
            if let element = NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-event-\(eventID)") {
                label = NativeConsumerOwnedAX.label(element)
                if label?.contains(title) == true && label?.contains(status) == true { break }
                if firstMismatch == nil {
                    firstMismatch = "label=\(label ?? "nil") frame=\(window.frame) contentFrame=\(String(describing: window.contentView?.frame))"
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        #expect(label?.contains(title) == true && label?.contains(status) == true,
            "First native mismatch: \(firstMismatch ?? "no matching owned element")")
        #expect(label?.contains("SECRET_SAMPLE515") == false)
        #expect(label?.contains("private_sample") == false)
    }

    private func expectValue(eventID: String, contains expected: String, in window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(4)
        var value: String?
        repeat {
            window.layoutIfNeeded()
            if let element = NativeConsumerOwnedAX.find(in: window, identifier: "chat-tool-event-\(eventID)") {
                value = NativeConsumerOwnedAX.attribute(element, kAXValueAttribute as CFString) as? String
                if value?.contains(expected) == true { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        #expect(value?.contains(expected) == true)
    }

    private func expectAbsent(in window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(4)
        var absent: Bool?
        repeat {
            window.layoutIfNeeded()
            absent = NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "chat-tool-events")
            if absent == true { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        #expect(absent == true)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
