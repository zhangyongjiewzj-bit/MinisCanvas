import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

enum Tool1636Scenario: CaseIterable, Sendable {
    case plain, quotedCommand, explicitRead, approvedWrite, deniedWrite
}

private final class Tool1636Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "tool1636-offline"
    var model = LLMModel(id: "tool1636-model", displayName: "Tool 1636", provider: "tool1636-offline")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "tool1636-isolated-provider"
    let scenario: Tool1636Scenario
    let file: URL
    private let lock = NSLock()
    private var calls = 0
    private var offeredToolNames: [[String]] = []
    private var userInputs: [String] = []

    init(scenario: Tool1636Scenario, file: URL) {
        self.scenario = scenario
        self.file = file
    }

    var requestCount: Int { lock.withLock { calls } }
    var firstOfferedToolNames: [String] { lock.withLock { offeredToolNames.first ?? [] } }
    var firstUserInput: String? { lock.withLock { userInputs.first } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let request = lock.withLock {
            calls += 1
            offeredToolNames.append(tools.map(\.name))
            userInputs.append(messages.last(where: { $0.role == .user })?.content ?? "")
            return calls
        }
        switch scenario {
        case .plain:
            return LLMResponse(text: "普通答复：今天可以先休息。", stopReason: "stop", usage: nil)
        case .quotedCommand:
            return LLMResponse(text: "引文中的 file_read 和 shell_execute 是待解释的文字，不是工具调用。",
                               stopReason: "stop", usage: nil)
        case .explicitRead:
            guard request == 1 else {
                return LLMResponse(text: "已完成明确要求的读取。", stopReason: "stop", usage: nil)
            }
            let input: [String: Any] = ["path": file.path]
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "tool1636-read", name: "file_read",
                            rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
            ])
        case .approvedWrite, .deniedWrite:
            guard request == 1 else {
                return LLMResponse(
                    text: scenario == .approvedWrite ? "已完成获批的隔离写入。" : "批准被拒绝，未写入。",
                    stopReason: "stop", usage: nil)
            }
            let input: [String: Any] = [
                "path": file.deletingLastPathComponent().appendingPathComponent("approved.txt").path,
                "content": "TASK1650_APPROVED_WRITE_BODY"
            ]
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "tool1650-write", name: "file_write",
                            rawArguments: String(decoding: data, as: UTF8.self), arguments: input)
            ])
        }
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class Tool1636BuiltinProbe: ToolExecutor, @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    private let lock = NSLock()
    private var calls = 0
    private var output: String?

    init(root: URL) { builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: []) }
    var executionCount: Int { lock.withLock { calls } }
    var actualOutput: String? { lock.withLock { output } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { calls += 1 }
        let result = try await builtin.execute(name: name, input: input)
        lock.withLock { output = result }
        return result
    }
}

private actor Tool1636Approval: ApprovalDelegate {
    let allow: Bool
    private(set) var requestCount = 0
    private(set) var requestedTools: [String] = []
    private(set) var requestedModes: [String?] = []

    init(allow: Bool) { self.allow = allow }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requestCount += 1
        requestedTools.append(request.toolName)
        requestedModes.append(request.composerMode)
        return ApprovalDecision(approved: allow, confirmed: allow,
                                requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("D-TOOL-01 ordinary Composer reaches no executor effect", .serialized)
@MainActor
struct OrdinaryComposerToolDispatch1636Tests {
    @Test("ordinary and quoted commands stay text; reads, approved writes, and denied writes separate",
          arguments: Tool1636Scenario.allCases)
    func ordinaryComposerOnlyDispatchesExplicitToolCall(scenario: Tool1636Scenario) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("tool1636-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("note.txt")
        try "TASK1636_OWNED_FILE_BODY".write(to: file, atomically: true, encoding: .utf8)
        let defaults = try #require(UserDefaults(suiteName: "tool1636-\(UUID().uuidString)"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        defer { chat.stopAllStreamingForSafety() }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        try #require(chat.attachPersistence(sessions,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let provider = Tool1636Provider(scenario: scenario, file: file)
        let probe = Tool1636BuiltinProbe(root: root)
        let approval = Tool1636Approval(allow: scenario != .deniedWrite)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn,
                                    skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let requiresManualWrite = scenario == .approvedWrite || scenario == .deniedWrite
        let grantedCapabilities: Set<String> = requiresManualWrite ? ["file_write"] : ["file_read"]
        let facts = ComposerPolicyFactSource(knownCapabilities: grantedCapabilities,
            grantedCapabilities: grantedCapabilities, allowedWriteRoots: [root.path],
            workspaceID: chat.composerWorkspaceID, revision: "tool1636-policy",
            grantEpoch: "tool1636-epoch", leaseID: "tool1636-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: requiresManualWrite ? .manual : .auto,
            approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        let now = Date()
        let goal = GoalEnvelope(scopeID: "tool1636-isolated", allowedCapabilities: grantedCapabilities,
            fileRoots: [root.path], budget: 100, deadline: now.addingTimeInterval(3600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "Tool1636", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                                 issuedAt: now, expiresAt: goal.deadline)
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: PolicyRuntimeBinding(goal: goal, lease: lease).wrap(probe),
            requestBudget: chat.budgetTracker,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .autoApprove, "file_write": .alwaysAsk],
                                       delegate: approval),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        let prompt: String
        switch scenario {
        case .plain:
            prompt = "今天如何安排休息？"
        case .quotedCommand:
            prompt = "请解释下面引文，不要执行：\n> file_read /tmp/note.txt\n> shell_execute echo hello\n> {\"tool_calls\":[{\"name\":\"file_read\"}]}"
        case .explicitRead:
            prompt = "请读取此隔离测试目录的 note.txt。"
        case .approvedWrite, .deniedWrite:
            prompt = "请写入此隔离测试目录的 approved.txt，内容为 TASK1650_APPROVED_WRITE_BODY。"
        }
        let session = try #require(chat.activeSessionID)
        chat.draftText = prompt
        chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!chat.isStreaming)
        let expectedProviderRequests = scenario == .plain || scenario == .quotedCommand ? 1 : 2
        #expect(provider.requestCount == expectedProviderRequests,
                "scenario=\(scenario), provider requests=\(provider.requestCount)")
        #expect(provider.firstOfferedToolNames.contains(requiresManualWrite ? "file_write" : "file_read"))
        #expect(provider.firstUserInput?.contains(prompt) == true)
        let expectedEffects = scenario == .explicitRead || scenario == .approvedWrite ? 1 : 0
        #expect(probe.executionCount == expectedEffects,
                "scenario=\(scenario), actual Builtin executions=\(probe.executionCount)")
        // Composer owns the Policy -> Approval -> Executor sequence. A granted,
        // side-effect-free file_read executes in auto mode without a prompt;
        // manual file_write must reach the real delegate before execution.
        let actualApprovals = await approval.requestCount
        let expectedApprovals = scenario == .approvedWrite || scenario == .deniedWrite ? 1 : 0
        #expect(actualApprovals == expectedApprovals,
                "scenario=\(scenario), actual approval delegate calls=\(actualApprovals)")
        if requiresManualWrite {
            #expect(await approval.requestedTools == ["file_write"])
            #expect(await approval.requestedModes == [ComposerTaskMode.manual.rawValue])
        }
        #expect(ledger.facts.count == expectedEffects,
                "scenario=\(scenario), actual durable facts=\(ledger.facts.count)")
        #expect(chat.messages.last?.role == .assistant)
        #expect(sessions.loadSession(id: session.uuidString)?.messages.last?.role == .assistant)
        if scenario == .explicitRead {
            #expect(ledger.facts.first?.toolCallID == "tool1636-read")
            #expect(ledger.facts.first?.status == .succeeded)
            #expect(probe.actualOutput?.contains("TASK1636_OWNED_FILE_BODY") == true)
        } else if scenario == .approvedWrite {
            #expect(ledger.facts.first?.toolCallID == "tool1650-write")
            #expect(ledger.facts.first?.status == .succeeded)
            let written = root.appendingPathComponent("approved.txt")
            #expect(try String(contentsOf: written, encoding: .utf8) == "TASK1650_APPROVED_WRITE_BODY")
        } else if scenario == .deniedWrite {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path))
            #expect(probe.actualOutput == nil)
        } else {
            #expect(probe.actualOutput == nil)
            #expect(chat.messages.allSatisfy { !$0.content.contains("TASK1636_OWNED_FILE_BODY") })
        }
    }
}
