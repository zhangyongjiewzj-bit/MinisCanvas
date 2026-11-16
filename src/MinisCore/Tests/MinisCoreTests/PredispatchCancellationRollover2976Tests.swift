import Foundation
import Testing
@testable import MinisCore

/// Moves the actual controller during the provider's synchronous capability
/// preflight, after orchestration has observed its entry cancellation state.
/// It neither settles a ledger nor fabricates an admission or result.
private final class RolloverProvider2976: LLMProvider, @unchecked Sendable {
    let name = "owned-rollover2976"
    private let lock = NSLock()
    private var storedModel = LLMModel(id: "owned2976", displayName: "Owned", provider: "synthetic")
    private var armed = false
    private var storedNewTurn: TurnController.TurnHandle?
    private var storedCalls = 0
    private let controller: TurnController

    init(controller: TurnController) { self.controller = controller }
    var model: LLMModel {
        get { lock.withLock { storedModel } }
        set { lock.withLock { storedModel = newValue } }
    }
    var calls: Int { lock.withLock { storedCalls } }
    var newTurn: TurnController.TurnHandle? { lock.withLock { storedNewTurn } }
    func armRollover() { lock.withLock { armed = true } }
    var capabilities: Set<ProviderCapability> {
        let shouldRoll = lock.withLock {
            let value = armed
            armed = false
            return value
        }
        if shouldRoll {
            let completed = DispatchSemaphore(value: 0)
            Task.detached { [self] in
                let turn = await controller.beginTurn()
                lock.withLock { storedNewTurn = turn }
                completed.signal()
            }
            // A bounded handshake fixes the interleaving; a missing newTurn
            // fails the fixture below instead of accepting a timing guess.
            _ = completed.wait(timeout: .now() + 3)
        }
        return []
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { storedCalls += 1 }
        return LLMResponse(text: "owned actual request finished", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoToolsRollover2976: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.unknownTool(name)
    }
}

@Suite("2976 entry cancellation survives actual legacy controller rollover", .serialized)
struct PredispatchCancellationRollover2976Tests {
    @Test("fresh latest turn cannot revive a cancelled entry; active entry still executes",
          arguments: [true, false])
    func entryFactSurvivesBeginNewTurn(cancelledAtEntry: Bool) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("rollover2976-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let controller = TurnController()
        let oldTurn = await controller.beginTurn()
        let provider = RolloverProvider2976(controller: controller)
        defer { Task { await oldTurn.finish(); await provider.newTurn?.finish() } }
        if cancelledAtEntry { await oldTurn.interrupt() }
        let orchestrator = AgentOrchestrator(provider: provider,
            toolExecutor: NoToolsRollover2976(), turnController: controller,
            taskStore: store, parentID: "owned-legacy-parent2976")
        provider.armRollover()
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(
            id: "entry-child2976", title: "Owned", instructions: "Complete")], strategy: .sequential)
        let newTurn = try #require(provider.newTurn)
        #expect(newTurn.turnID == oldTurn.turnID + 1)
        #expect(await newTurn.isActive())
        #expect(await newTurn.isCancelled() == false)
        #expect(await oldTurn.isCancelled() == cancelledAtEntry)
        let snapshot = try #require(store.snapshot(taskID: "entry-child2976"))
        let receipt = try #require(store.allReceipts().first)
        let events = store.events(runID: receipt.runID)
        #expect(snapshot.parentRuntimeIdentity == nil, "legacy labels cannot create a verified parent handle")
        #expect(snapshot.parentID == "owned-legacy-parent2976")
        #expect(store.allReceipts().count == 1)
        if cancelledAtEntry {
            #expect(reports.first?.result == .failed(error: "任务已取消"))
            #expect(provider.calls == 0)
            #expect(snapshot.status == .cancelled)
            #expect(receipt.outcome == .cancelled)
            #expect(events.map(\.kind) == [.started, .cancelled])
        } else {
            #expect(reports.first?.result.isSuccess == true)
            #expect(provider.calls == 1)
            #expect(receipt.outcome == .succeeded)
        }
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.snapshot(taskID: snapshot.taskID) == snapshot)
        #expect(reopened.allReceipts() == [receipt])
        #expect(reopened.events(runID: receipt.runID) == events)
    }
}
