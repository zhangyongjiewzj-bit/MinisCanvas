import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PERF-06 workflow cold-start ownership")
struct WorkflowBootstrapMainActor2335Tests {
    @Test("slow canonical workflow read leaves the main actor available during startup construction")
    func workflowReadDoesNotBlockMainActor() async throws {
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile()
        #expect(profile.mode == .isolatedTest)
        let workflows = profile.minisCanvasDirectory
            .appendingPathComponent("Workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        let persisted = WorkflowTemplate(
            id: "bootstrap-reopen", name: "持久模板", description: "synthetic",
            steps: [WorkflowStep(id: "one", type: .custom, title: "one",
                promptTemplate: "fixed", outputKey: "result")]
        )
        let originalDocument = try JSONEncoder().encode([persisted])
        let documentURL = workflows.appendingPathComponent(WorkflowStore.fileName)
        try originalDocument.write(to: documentURL)

        let readEntered = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        let bootstrapReturned = DispatchSemaphore(value: 0)
        let mainActorPing = DispatchSemaphore(value: 0)
        let bootstrap = Task { @MainActor in
            let store = WorkflowStore.startForAppBootstrap(storeDirectory: workflows, readData: { url in
                readEntered.signal()
                readRelease.wait()
                return try? Data(contentsOf: url)
            })
            bootstrapReturned.signal()
            return store
        }

        let entered = await wait(readEntered, seconds: 5)
        guard entered else {
            readRelease.signal()
            _ = await bootstrap.result
            Issue.record("MainActor construction did not reach the canonical WorkflowStore read")
            return
        }
        let returnedBeforeReadRelease = await wait(bootstrapReturned, seconds: 1)
        Task { @MainActor in mainActorPing.signal() }
        let pingBeforeReadRelease = await wait(mainActorPing, seconds: 1)
        if returnedBeforeReadRelease {
            let pendingStore = await bootstrap.value
            #expect(!pendingStore.isInitialLoadComplete)
            #expect(pendingStore.template(id: persisted.id) == nil)
            #expect(pendingStore.listTemplates().isEmpty)
            var pendingEdit = persisted
            pendingEdit.name = "未批准的覆盖"
            do {
                try pendingStore.saveTemplate(pendingEdit)
                Issue.record("first save overwrote a template before the canonical load")
            } catch let error as WorkflowStoreInitialLoadError {
                #expect(error == .pending)
            }
            #expect(!pendingStore.removeTemplate(id: persisted.id))
            #expect((try Data(contentsOf: documentURL)) == originalDocument)
        }
        readRelease.signal()
        let store = await bootstrap.value
        await store.waitForInitialLoad()
        #expect(returnedBeforeReadRelease, "startup construction waited for the workflow document")
        #expect(pingBeforeReadRelease, "a slow workflow document read blocked the App main actor")
        #expect(store.isInitialLoadComplete)
        #expect(store.template(id: persisted.id) == persisted)
        let reopened = WorkflowStore.startForAppBootstrap(storeDirectory: workflows)
        await reopened.waitForInitialLoad()
        #expect(reopened.template(id: persisted.id) == persisted)
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + .seconds(seconds)) == .success)
            }
        }
    }
}
