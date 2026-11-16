import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private actor WorkflowOwnershipHold {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class WorkflowOwnershipProvider: LLMProvider, @unchecked Sendable {
    let label: String
    let failSecond: Bool
    let hold: WorkflowOwnershipHold?
    private let lock = NSLock()
    private var calls = 0
    var name: String { "OwnedWorkflowLifetime" }
    var model = LLMModel(id: "owned-lifetime", displayName: "Owned", provider: "Synthetic")
    init(_ label: String, failSecond: Bool, hold: WorkflowOwnershipHold? = nil) {
        self.label = label; self.failSecond = failSecond; self.hold = hold
    }
    private func nextCall() -> Int {
        lock.lock(); defer { lock.unlock() }; calls += 1; return calls
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let n = nextCall()
        if n == 2 {
            if let hold { await hold.wait() }
            if failSecond {
                throw NSError(domain: "OwnedWorkflowLifetime", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "owned second-step failure"])
            }
        }
        return LLMResponse(text: "\(label)-\(n)", stopReason: "end_turn",
                           usage: LLMUsage(inputTokens: 0, outputTokens: 0))
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}

@Suite("R21 shared workflow ownership actual consumers", .serialized)
@MainActor
struct WorkflowSharedRunnerOwnershipCurrentConsumerTests {
    private func fixture(_ id: String) throws -> (WorkflowStore, WorkflowTemplate) {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolved)
        let directory = paths.rootDirectory.appendingPathComponent("workflow-ownership-\(UUID().uuidString)")
        let store = WorkflowStore(storeDirectory: directory)
        let template = WorkflowTemplate(id: id, name: id, description: "owned lifecycle input",
            steps: [
                WorkflowStep(id: "s1", type: .custom, title: "First",
                             promptTemplate: "{{input}}", outputKey: "first"),
                WorkflowStep(id: "s2", type: .custom, title: "Second",
                             promptTemplate: "{{first}}", outputKey: "second")
            ], requiredInputs: ["input"])
        try store.saveTemplate(template)
        return (store, template)
    }
    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await predicate(), "actual consumer did not reach its held/terminal state")
    }
    private func failures(_ bridge: BridgeStore, name: String) -> Int {
        bridge.chat.messages.filter { $0.content.contains("工作流「\(name)」失败") }.count
    }

    @Test func ordinaryResetCannotBeUndoneByHeldDeepLinkFailure() async throws {
        let (store, template) = try fixture("ownership-reset")
        let bridge = BridgeStore()
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)
        let hold = WorkflowOwnershipHold()
        let old = WorkflowOwnershipProvider("old", failSecond: true, hold: hold)
        bridge.workflowChat.providerOverride = old
        handler.handle(.runWorkflow(name: template.id, input: "old-input"))
        try await until { await hold.entered }
        #expect(old.callCount == 2)
        #expect(!bridge.workflowChat.isRunning, "deep-link owner is distinct from the retained chat task")
        bridge.workflowChat.run(text: "/workflow 重置", chat: bridge.chat)
        #expect(bridge.chat.messages.contains { $0.content.contains("工作流断点已清空") })
        #expect(bridge.workflowChat.sharedRunner.completedOutputs(templateID: template.id).isEmpty)
        await hold.release()
        try await until { failures(bridge, name: template.name) == 1 }
        #expect(old.callCount == 2)
        #expect(bridge.workflowChat.sharedRunner.completedOutputs(templateID: template.id).isEmpty,
                "a failure completing after the ordinary reset must not restore old checkpoints")
        let fresh = WorkflowOwnershipProvider("fresh", failSecond: false)
        bridge.workflowChat.providerOverride = fresh
        handler.handle(.runWorkflow(name: template.id, input: "old-input"))
        try await until { bridge.chat.messages.contains { $0.content.contains("工作流「\(template.name)」完成") } }
        #expect(fresh.callCount == 2)
        #expect(bridge.chat.messages.contains { $0.content.contains("工作流「\(template.name)」完成") && $0.content.contains("0 步命中缓存") })
        #expect(bridge.workflowChat.sharedRunner.completedOutputs(templateID: template.id).isEmpty)
    }

    @Test func olderDeepLinkFailureCannotReplaceNewInputCheckpoint() async throws {
        let (store, template) = try fixture("ownership-fingerprint")
        let bridge = BridgeStore()
        let handler = DeepLinkHandler(bridge: bridge, workflowStore: store)
        let hold = WorkflowOwnershipHold()
        let old = WorkflowOwnershipProvider("old", failSecond: true, hold: hold)
        bridge.workflowChat.providerOverride = old
        handler.handle(.runWorkflow(name: template.id, input: "old-input"))
        try await until { await hold.entered }
        let fresh = WorkflowOwnershipProvider("fresh", failSecond: true)
        bridge.workflowChat.providerOverride = fresh
        handler.handle(.runWorkflow(name: template.id, input: "fresh-input"))
        try await until { failures(bridge, name: template.name) == 1 }
        #expect(fresh.callCount == 2)
        #expect(bridge.workflowChat.sharedRunner.completedOutputs(templateID: template.id) == ["first": "fresh-1"])
        await hold.release()
        try await until { failures(bridge, name: template.name) == 2 }
        #expect(old.callCount == 2)
        #expect(bridge.workflowChat.sharedRunner.completedOutputs(templateID: template.id) == ["first": "fresh-1"],
                "the older fingerprint must not replace the newer actual request's checkpoint")
        let resume = WorkflowOwnershipProvider("resume", failSecond: false)
        bridge.workflowChat.providerOverride = resume
        handler.handle(.runWorkflow(name: template.id, input: "fresh-input"))
        try await until { bridge.chat.messages.contains { $0.content.contains("工作流「\(template.name)」完成") } }
        #expect(resume.callCount == 1)
        #expect(bridge.chat.messages.contains { $0.content.contains("工作流「\(template.name)」完成") && $0.content.contains("1 步命中缓存") })
    }

    @Test func ownedCancellationJoinsHeldProviderAndCannotRepopulateResetCheckpoint() async throws {
        let (_, template) = try fixture("ownership-cancel")
        let runner = WorkflowRunner()
        let hold = WorkflowOwnershipHold()
        let old = WorkflowOwnershipProvider("old", failSecond: true, hold: hold)
        let task = Task {
            try await runner.run(template: template, inputs: ["input": "owned"],
                                 provider: LLMWorkflowProvider(provider: old))
        }
        try await until { await hold.entered }
        task.cancel()
        runner.reset()
        await hold.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(old.callCount == 2)
        #expect(runner.completedOutputs(templateID: template.id).isEmpty)
        let fresh = WorkflowOwnershipProvider("fresh", failSecond: false)
        let result = try await runner.run(template: template, inputs: ["input": "owned"],
                                          provider: LLMWorkflowProvider(provider: fresh))
        #expect(fresh.callCount == 2)
        #expect(result.cachedStepIDs.isEmpty)
        #expect(result.executedStepIDs == ["s1", "s2"])
        #expect(result.outputs == ["first": "fresh-1", "second": "fresh-2"])
        #expect(runner.completedOutputs(templateID: template.id).isEmpty)
    }
}
