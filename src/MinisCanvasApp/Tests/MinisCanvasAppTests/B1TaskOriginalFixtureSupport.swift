import Foundation
import Testing
@testable import MinisCanvasApp

// Only original Task/approval tests' owned fixture lifecycle; no product API.
@MainActor
enum B1TaskOriginalFixtureSupport {
    private struct Worker {
        let task: Task<Void, Never>
        let cancel: @MainActor () -> Void
        let finished: @MainActor () -> Bool
    }
    private static var workers: [String: [Worker]] = [:]
    static func register(root: URL, task: Task<Void, Never>,
                         cancel: @escaping @MainActor () -> Void,
                         finished: @escaping @MainActor () -> Bool) {
        workers[root.path, default: []].append(Worker(task: task, cancel: cancel, finished: finished))
    }
    static func withRoot(_ label: String, body: @MainActor (URL) async throws -> Void) async throws {
        let root = try B1ARCHOriginalFixtureSupport.makeRoot(label)
        let business: Result<Void, Error>
        do { try await body(root); business = .success(()) }
        catch { business = .failure(error) }
        let ownedWorkers = workers.removeValue(forKey: root.path) ?? []
        for worker in ownedWorkers { worker.cancel(); worker.task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !ownedWorkers.allSatisfy({ $0.finished() }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let allFinished = ownedWorkers.allSatisfy { $0.finished() }
        #expect(allFinished, "all owned writer tasks must retire before root cleanup")
        if allFinished {
            for worker in ownedWorkers { await worker.task.value }
            B1ARCHOriginalFixtureSupport.cleanupRoot(root)
            print("TASK01_ORIGINAL_WORKERS retired=\(ownedWorkers.count) rootCleanupAllowed=true")
        } else {
            Issue.record("owned writer did not retire; retain exact fixture root")
            print("TASK01_ORIGINAL_WORKERS rootCleanupAllowed=false retained=\(root.path)")
        }
        try business.get()
    }
}
