import Foundation
import Testing

@Suite("Task Center filter archive native consumer contract")
struct TaskCenterFilterArchiveNativeConsumerTests {
    @Test func taskCenterViewExposesStableFilterAndArchiveAccessibilityContracts() throws {
        let source = try String(contentsOf: taskCenterViewURL, encoding: .utf8)

        #expect(source.contains("task-center-filter-status"))
        #expect(source.contains("task-center-filter-source"))
        #expect(source.contains("task-center-filter-archived"))
        #expect(source.contains("task-center-archive-"))
        #expect(source.contains("task-center-archive-restore-"))
        #expect(source.contains("filteredReceiptRows"))
        #expect(source.contains("TaskCenterArchiveRequest"))
        #expect(!source.contains("TaskCenterNativeAccessibilityConsumerTests.swift"))
    }

    @Test func controlConsumerKeepsCanonicalSourceAndArchiveProducerBoundaries() throws {
        let source = try String(contentsOf: controlConsumerURL, encoding: .utf8)

        #expect(source.contains("sourceSessionID: task.sourceSessionID"))
        #expect(source.contains("public func filteredReceiptRows"))
        #expect(source.contains("public func applyArchive"))
        #expect(source.contains("store.applyArchive(coreRequest"))
        #expect(!source.contains("BridgeStore"))
        #expect(!source.contains("activeSessionID"))
    }

    private var taskCenterViewURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
    }

    private var controlConsumerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterControlConsumer.swift")
    }
}
