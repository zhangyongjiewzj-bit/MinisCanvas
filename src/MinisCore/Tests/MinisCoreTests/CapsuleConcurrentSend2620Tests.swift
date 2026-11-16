import Foundation
import Testing
@testable import MinisCore

private actor CapsuleTransport2620 {
    private(set) var calls = 0
    private var released = false
    private(set) var secondCompleted = false

    func respond() async throws -> LLMResponse {
        calls += 1
        let call = calls
        if call == 1 {
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        return LLMResponse(text: "synthetic-reply-\(call)", stopReason: "stop", usage: nil)
    }

    func release() { released = true }
    func finishSecond() { secondCompleted = true }

    func waitForFirst() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while calls == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return calls > 0
    }

    func waitForSecond() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !secondCompleted && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return secondCompleted
    }
}

// A controlled transport seam only: all shared capsule state, dispatch and
// transcript writes remain in the actual production runtime and Stores.
private final class CapsuleProvider2620: LLMProvider, Sendable {
    let name = "capsule-2620"
    let transport = CapsuleTransport2620()
    private let fixedModel = LLMModel(id: "capsule-model", displayName: "capsule-model", provider: "capsule-2620")
    var model: LLMModel {
        get { fixedModel }
        set { precondition(newValue.id == fixedModel.id) }
    }
    var capabilities: Set<ProviderCapability> { [.tools] }

    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await transport.respond()
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await transport.respond()
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Core production capsule admission across provider await", .serialized)
struct CapsuleConcurrentSend2620Tests {
    @MainActor
    private func fixture() throws -> (ChatSessionRuntime, CapsuleProvider2620, SessionStore, ChatSession) {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("capsule-2620-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: UUID().uuidString, projectID: "project-2620")
        let provider = CapsuleProvider2620()
        let snapshot = try ProviderRuntimeSnapshot(providerID: provider.name, modelID: provider.model.id,
            readinessEvidenceID: "mock-capsule-2620", applyReceiptID: "provider-readiness-apply:capsule-2620",
            capabilities: [.tools])
        let runtime = try ChatSessionRuntime(sessionStore: sessions, memoryStore: MemoryStore(directory: root),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            soulStore: SoulStore(directory: root), provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root), providerRuntimeSnapshot: snapshot,
            toolCatalog: AgentToolCatalog.makeTools(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root))
        return (runtime, provider, sessions, session)
    }

    private func request(context: ChatRuntimeContext, name: String) -> ChatTurnRequest {
        let capsule = ChatInputCapsule(capsuleID: "capsule-\(name)", sessionID: context.sessionID,
                                       originalSnapshot: "synthetic-input-\(name)", sendSnapshot: "synthetic-input-\(name)")
        // Same qualified capsule/request shape as the existing A4 serial test.
        return ChatTurnRequest(text: capsule.sendSnapshot, context: context, capsule: capsule,
            turnID: "turn:\(name)", taskID: "task:\(name)", attempt: 1,
            executionIdentity: minisCoreToolContractIdentity(name, sessionID: context.sessionID))
    }

    @Test @MainActor
    func sameCapsuleCannotDispatchTwiceWhileFirstProviderAwaits() async throws {
        let (runtime, provider, sessions, session) = try fixture()
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = request(context: context, name: "same")
        let first = Task { try await runtime.sendProduction(request) }
        defer { first.cancel() }
        let entered = try await provider.transport.waitForFirst()
        #expect(entered)
        let second = Task { () -> Bool in
            let rejected: Bool
            do { _ = try await runtime.sendProduction(request); rejected = false }
            catch { rejected = (error as? ChatSessionRuntimeError) == .duplicateCapsuleSend }
            await provider.transport.finishSecond()
            return rejected
        }
        defer { second.cancel() }
        let completed = try await provider.transport.waitForSecond()
        let callsBeforeRelease = await provider.transport.calls
        await provider.transport.release()
        let secondRejected = await second.value
        _ = try await first.value
        #expect(completed)
        #expect(secondRejected)
        #expect(callsBeforeRelease == 1)
        let transcript = try #require(sessions.loadSession(id: session.id))
        #expect(transcript.messages.filter { $0.role == .user && $0.content == request.text }.count == 1)
        await #expect(throws: ChatSessionRuntimeError.duplicateCapsuleSend) {
            try await runtime.sendProduction(request)
        }
        let finalCalls = await provider.transport.calls
        #expect(finalCalls == 1)
    }

    @Test @MainActor
    func distinctQualifiedCapsulesKeepBothProductionDispatches() async throws {
        let (runtime, provider, sessions, session) = try fixture()
        let context = try await runtime.makeContext(sessionID: session.id)
        let a = request(context: context, name: "first")
        let b = request(context: context, name: "second")
        let first = Task { try await runtime.sendProduction(a) }
        defer { first.cancel() }
        let entered = try await provider.transport.waitForFirst()
        #expect(entered)
        let second = Task {
            let result: Result<ChatTurnResult, Error>
            do { result = .success(try await runtime.sendProduction(b)) }
            catch { result = .failure(error) }
            await provider.transport.finishSecond()
            return result
        }
        defer { second.cancel() }
        let completed = try await provider.transport.waitForSecond()
        await provider.transport.release()
        _ = try await second.value.get()
        _ = try await first.value
        #expect(completed)
        let calls = await provider.transport.calls
        #expect(calls == 2)
        let transcript = try #require(sessions.loadSession(id: session.id))
        #expect(transcript.messages.filter { $0.role == .user }.count == 2)
    }

    @Test @MainActor
    func cancelledInFlightCapsuleRetainsExistingRetryEligibility() async throws {
        let (runtime, provider, sessions, session) = try fixture()
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = request(context: context, name: "cancel-retry")
        let first = Task { try await runtime.sendProduction(request) }
        defer { first.cancel() }
        let entered = try await provider.transport.waitForFirst()
        #expect(entered)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        // The interrupted user's message remains honest history, as before.
        _ = try await runtime.sendProduction(request)
        let calls = await provider.transport.calls
        #expect(calls == 2)
        let transcript = try #require(sessions.loadSession(id: session.id))
        #expect(transcript.messages.filter { $0.role == .user && $0.content == request.text }.count == 2)
        await #expect(throws: ChatSessionRuntimeError.duplicateCapsuleSend) {
            try await runtime.sendProduction(request)
        }
    }

}
