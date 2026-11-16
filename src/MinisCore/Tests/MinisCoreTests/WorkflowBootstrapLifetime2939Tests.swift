import Foundation
import Testing
@testable import MinisCore

/// Holds the actual readData call made by WorkflowStore's owned detached task.
/// It returns real bytes read from the isolated canonical workflow document.
private final class HeldWorkflowReader2939: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var exited = false
    private var cancelledAtExit: Bool?
    var state: (entered: Bool, exited: Bool, cancelled: Bool?) {
        lock.withLock { (entered, exited, cancelledAtExit) }
    }
    func read(_ url: URL) -> Data? {
        let snapshot = try? Data(contentsOf: url)
        lock.withLock { entered = true }
        _ = release.wait(timeout: .now() + .seconds(5))
        let cancelled = Task.isCancelled
        lock.withLock { exited = true; cancelledAtExit = cancelled }
        return snapshot
    }
    func releaseRead() { release.signal() }
}

private actor WorkflowWaiter2939 {
    private(set) var entered = false
    func markEntered() { entered = true }
}

@Suite("D-CONC2 workflow bootstrap task ownership", .serialized)
struct WorkflowBootstrapLifetime2939Tests {
    private func fixture() throws -> (directory: URL, document: URL, template: WorkflowTemplate, bytes: Data) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let directory = formal.rootDirectory.appendingPathComponent("workflow2939-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let template = WorkflowTemplate(id: "owned2939", name: "原模板", description: "synthetic",
            steps: [WorkflowStep(id: "one", type: .custom, title: "one", promptTemplate: "fixed", outputKey: "result")])
        let bytes = try JSONEncoder().encode([template])
        let document = directory.appendingPathComponent(WorkflowStore.fileName)
        try bytes.write(to: document)
        return (directory, document, template, bytes)
    }

    private func waitFor(_ predicate: @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return predicate()
    }

    @Test
    func cancelledWaiterDoesNotCancelOwnedWorkflowBootstrap() async throws {
        let f = try fixture()
        let reader = HeldWorkflowReader2939()
        defer { reader.releaseRead() }
        let store = WorkflowStore.startForAppBootstrap(storeDirectory: f.directory, readData: reader.read)
        try #require(try await waitFor { reader.state.entered })
        let waiterProbe = WorkflowWaiter2939()
        let waiter = Task {
            await waiterProbe.markEntered()
            await store.waitForInitialLoad()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await waiterProbe.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await waiterProbe.entered)
        waiter.cancel()
        #expect(waiter.isCancelled)
        #expect(!reader.state.exited, "cancelling a consumer cannot finish the held physical read")
        #expect(!store.isInitialLoadComplete)
        #expect(store.template(id: f.template.id) == nil)
        #expect(store.listTemplates().isEmpty)
        #expect(throws: WorkflowStoreInitialLoadError.pending) { try store.saveTemplate(f.template) }
        #expect(throws: WorkflowStoreInitialLoadError.pending) { try store.saveToDisk() }
        #expect(!store.removeTemplate(id: f.template.id))
        #expect(try Data(contentsOf: f.document) == f.bytes)

        reader.releaseRead()
        await store.waitForInitialLoad()
        await waiter.value
        #expect(reader.state.exited && reader.state.cancelled == false,
                "the owning store keeps its bootstrap task when one waiter is cancelled")
        #expect(store.isInitialLoadComplete)
        #expect(store.template(id: f.template.id) == f.template)
        #expect(try Data(contentsOf: f.document) == f.bytes)
        print("TASK2939 cancelledWaiter actualReaderCancelled=\(String(describing: reader.state.cancelled)) loaded=\(store.isInitialLoadComplete)")
    }

    @Test
    func retiredStoreCancelsHeldReaderAndLateSnapshotCannotAffectReplacement() async throws {
        let f = try fixture()
        let reader = HeldWorkflowReader2939()
        defer { reader.releaseRead() }
        var owner: WorkflowStore? = WorkflowStore.startForAppBootstrap(storeDirectory: f.directory, readData: reader.read)
        weak let retiredOwner = owner
        try #require(try await waitFor { reader.state.entered })
        #expect(owner?.isInitialLoadComplete == false)
        owner = nil
        #expect(retiredOwner == nil, "the held task must not retain the retired store")
        #expect(!reader.state.exited)

        var replacementTemplate = f.template
        replacementTemplate.name = "新所有者模板"
        let replacementBytes = try JSONEncoder().encode([replacementTemplate])
        try replacementBytes.write(to: f.document, options: .atomic)
        let replacement = WorkflowStore.startForAppBootstrap(storeDirectory: f.directory)
        await replacement.waitForInitialLoad()
        #expect(replacement.template(id: replacementTemplate.id) == replacementTemplate)
        reader.releaseRead()
        try #require(try await waitFor { reader.state.exited })
        #expect(reader.state.cancelled == true, "deinit must cancel the task owned by that store")
        #expect(retiredOwner == nil)
        #expect(replacement.template(id: replacementTemplate.id) == replacementTemplate,
                "the old physical read returned an old snapshot after the new owner loaded")
        #expect(try Data(contentsOf: f.document) == replacementBytes)
        let reopened = WorkflowStore(storeDirectory: f.directory)
        #expect(reopened.template(id: replacementTemplate.id) == replacementTemplate)
        print("TASK2939 retiredOwnerNil=\(retiredOwner == nil) actualReaderCancelled=\(String(describing: reader.state.cancelled)) replacement=\(replacement.template(id: replacementTemplate.id)?.name ?? "missing")")
    }
}
