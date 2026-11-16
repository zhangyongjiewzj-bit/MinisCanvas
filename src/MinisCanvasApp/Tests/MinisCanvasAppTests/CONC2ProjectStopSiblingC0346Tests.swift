import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

// A transport-only admission barrier. Responses come from the existing Release
// MockProvider; ChatStore, project launch, Stop and AgentLoop are production code.
private actor C0346ProviderGate {
    private var entered: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var closed = false
    private(set) var unexpected = 0
    func wait(_ marker: String) async {
        entered.insert(marker)
        if closed || released.contains(marker) { return }
        await withCheckedContinuation { pending[marker] = $0 }
    }
    func hasEntered(_ marker: String) -> Bool { entered.contains(marker) }
    func release(_ marker: String) {
        released.insert(marker)
        pending.removeValue(forKey: marker)?.resume()
    }
    func releaseAll() {
        closed = true
        let continuations = Array(pending.values)
        released.formUnion(entered)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
    func recordUnexpected() { unexpected += 1 }
}

private struct C0346MockProvider: LLMProvider, Sendable {
    let gate: C0346ProviderGate
    let name = "C0346-owned-Mock"
    var model = LLMModel(id: "c0346-mock", displayName: "C0346 Mock", provider: "C0346-owned-Mock")
    var capabilities: Set<ProviderCapability> { [.tools] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let marker = messages.last(where: { $0.role == .user })?.content ?? ""
        guard marker == "C0346-PROJECT-A" || marker == "C0346-SIBLING-B" else {
            await gate.recordUnexpected()
            throw LLMError.providerError(message: "unexpected synthetic request")
        }
        await gate.wait(marker)
        try Task.checkCancellation()
        return try await MockProvider().sendMessage(messages: messages, systemPrompt: systemPrompt,
                                                   maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await gate.recordUnexpected()
        throw LLMError.providerError(message: "unexpected streaming transport")
    }
}

@Suite("D-CONC2 C0346 real project Stop versus sibling turn", .serialized)
@MainActor
struct CONC2ProjectStopSiblingC0346Tests {
    private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func projectStopDoesNotInterruptSiblingAgentLoopTurn() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("C0346-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var identity = stat()
        try #require(lstat(root.path, &identity) == 0)
        try #require((identity.st_mode & S_IFMT) == S_IFDIR && identity.st_uid == geteuid()
                     && (identity.st_mode & 0o777) == 0o700)
        let suite = "C0346-owned-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let a = UUID(), b = UUID(), project = "C0346-owned-project"
        _ = try sessions.createSession(id: a.uuidString, title: "Project A", projectID: project)
        try sessions.saveMessage(LLMMessage(role: .user, content: "C0346-PROJECT-A"), sessionID: a.uuidString)
        _ = try sessions.createSession(id: b.uuidString, title: "Sibling B")
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        try #require(chat.attachPersistence(sessions, badgeStore: badges))
        chat.restoreSpeedTier(.fast) // metadata only; the provider override below is the sole transport.
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "C0346", grantEpoch: "C0346", leaseID: "C0346",
            expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        let legacyController = TurnController()
        chat.agentEngine = AgentLoopChatEngine(turnController: legacyController, composerPolicyFacts: facts)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let gate = C0346ProviderGate()
        chat.streamingProviderOverride = C0346MockProvider(gate: gate)
        var handles: [Task<Void, Never>] = []
        var projectFinished = false
        var failure: (any Error)?
        print("C0346_BEGIN root=\(root.path) dev=\(identity.st_dev) ino=\(identity.st_ino) uid=\(identity.st_uid) suite=\(suite) condition2=NOT_EXERCISED_NO_CURRENT_TYPEWRITER_SEAM")
        do {
            let run = "C0346-\(UUID().uuidString)"
            _ = try tasks.enqueue(taskID: "C0346-task", parentID: "C0346-parent", providerID: nil, modelID: nil)
            _ = try tasks.startRun(taskID: "C0346-task", runID: run)
            let actualStart = chat.startProjectTask(targetID: a.uuidString, projectID: project,
                instruction: "C0346-PROJECT-A", runID: run, taskStore: tasks,
                authorization: { true }, onFinished: { projectFinished = true })
            try #require(actualStart)
            let aTask = try #require(chat.turnTaskForTests(sessionID: a))
            handles.append(aTask)
            try #require(await until { await gate.hasEntered("C0346-PROJECT-A") })
            try #require(chat.activeExecutionIdentity(for: a) == nil,
                         "This test must actually enter the project no-identity Stop route")
            try #require(chat.applySwitchSession(id: b))
            chat.draftText = "C0346-SIBLING-B"
            chat.submitComposer()
            let bTask = try #require(chat.turnTaskForTests(sessionID: b))
            handles.append(bTask)
            try #require(await until { await gate.hasEntered("C0346-SIBLING-B") })
            let bIdentity = try #require(chat.activeExecutionIdentity(for: b))
            try #require(chat.applySwitchSession(id: a))
            try #require(chat.activeExecutionIdentity(for: a) == nil)
            chat.stopStreaming() // The one real Stop under test, on project A while B is suspended.
            await gate.release("C0346-PROJECT-A")
            await aTask.value
            #expect(projectFinished)
            #expect(aTask.isCancelled)
            #expect(chat.turnTaskForTests(sessionID: a) == nil)
            #expect(!bTask.isCancelled)
            #expect(chat.turnTaskForTests(sessionID: b) == bTask)
            #expect(chat.activeExecutionIdentity(for: b) == bIdentity)
            await gate.release("C0346-SIBLING-B")
            await bTask.value
            #expect(chat.terminalReceipt(for: bIdentity)?.outcome == .succeeded)
            let persisted = try #require(sessions.loadSession(id: b.uuidString))
            #expect(persisted.messages.contains { $0.role == .assistant && $0.content.contains("收到：C0346-SIBLING-B") })
            #expect(persisted.messages.allSatisfy { !$0.content.contains("已中断") })
            #expect(await gate.unexpected == 0)
            print("C0346_CONDITION1_END aTaskJoined=true bTaskJoined=true bTerminal=\(String(describing: chat.terminalReceipt(for: bIdentity)?.outcome)) condition2=NOT_EXERCISED")
        } catch { failure = error }
        // Always release controlled provider continuations before real Task.value joins,
        // including fatal admission failures. Cancellation is not treated as joining.
        for id in [a, b] {
            if let handle = chat.turnTaskForTests(sessionID: id), !handles.contains(handle) { handles.append(handle) }
        }
        chat.stopAllStreamingForSafety()
        await gate.releaseAll()
        for handle in handles { await handle.value }
        print("C0346_CLEANUP capturedTasksJoined=\(handles.count) rootRetained=true suiteRetained=true usageStoreInstalled=false internalEngineTaskCensus=UNKNOWN")
        if let failure { throw failure }
    }
}
