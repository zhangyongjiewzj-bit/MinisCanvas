import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("CONC2 metadata stores sharing one path")
struct MediaTaskMetadataSharedPathTests {
    private func directory() throws -> URL {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let directory = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("media-shared-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func context(providerID: String) -> MediaTaskContext {
        MediaTaskContext(
            identity: CanvasExecutionIdentity(
                canvasID: UUID(),
                runID: UUID(),
                graphRevision: 1,
                nodeID: UUID(),
                nodeRevision: 1
            ),
            providerSnapshot: ProviderSnapshot(
                providerID: providerID,
                modelID: "video-v1",
                capabilities: [.video],
                configurationFingerprint: "config-\(providerID)"
            ),
            promptFingerprint: "prompt-\(providerID)"
        )
    }

    @Test func concurrentStoresKeepEveryDistinctRecordAndSeePeerWrites() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MediaTaskMetadataStore(directory: root)
        let second = MediaTaskMetadataStore(directory: root)
        let entries = (0..<24).map { index in
            ("record-\(index)", context(providerID: "provider-\(index)"))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, entry) in entries.enumerated() {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try store.bind(recordID: entry.0, context: entry.1, allowLegacyBinding: true)
                }
            }
            try await group.waitForAll()
        }

        let restored = MediaTaskMetadataStore(directory: root)
        for (recordID, expected) in entries {
            #expect(try restored.context(recordID: recordID) == expected)
            #expect(try first.context(recordID: recordID) == expected)
            #expect(try second.context(recordID: recordID) == expected)
        }
    }

    @Test func staleStoreCannotLowerAttemptAfterPeerAdvancesIt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MediaTaskMetadataStore(directory: root)
        let second = MediaTaskMetadataStore(directory: root)
        let original = context(providerID: "provider-a")
        try first.bind(recordID: "record-a", context: original, allowLegacyBinding: true)
        try second.bind(recordID: "record-a", context: original.withAttempt(2), allowLegacyBinding: false)

        #expect(throws: MediaTaskMetadataError.identityConflict("record-a")) {
            try first.bind(recordID: "record-a", context: original, allowLegacyBinding: false)
        }
        #expect(try MediaTaskMetadataStore(directory: root).context(recordID: "record-a")?.attempt == 2)
    }

    @Test func independentStoreDirectoriesRemainIsolated() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        let first = MediaTaskMetadataStore(directory: firstRoot)
        let second = MediaTaskMetadataStore(directory: secondRoot)
        let firstContext = context(providerID: "first")
        let secondContext = context(providerID: "second")
        try first.bind(recordID: "same-record-id", context: firstContext, allowLegacyBinding: true)
        try second.bind(recordID: "same-record-id", context: secondContext, allowLegacyBinding: true)

        #expect(try MediaTaskMetadataStore(directory: firstRoot).context(recordID: "same-record-id") == firstContext)
        #expect(try MediaTaskMetadataStore(directory: secondRoot).context(recordID: "same-record-id") == secondContext)
    }

    @Test func failedWriteDoesNotLeaveAnInMemoryPhantomBinding() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedSidecar = root.appendingPathComponent(MediaTaskMetadataStore.fileName, isDirectory: true)
        try FileManager.default.createDirectory(at: blockedSidecar, withIntermediateDirectories: true)
        let store = MediaTaskMetadataStore(directory: root)
        let intended = context(providerID: "provider-a")

        #expect(throws: MediaTaskMetadataError.persistenceFailed) {
            try store.bind(recordID: "record-a", context: intended, allowLegacyBinding: true)
        }
        try FileManager.default.removeItem(at: blockedSidecar)
        #expect(try store.context(recordID: "record-a") == nil)
        try store.bind(recordID: "record-a", context: intended, allowLegacyBinding: true)
        #expect(try MediaTaskMetadataStore(directory: root).context(recordID: "record-a") == intended)
    }

    @Test func missingOrCorruptSidecarStillReadsAsNoContext() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaTaskMetadataStore(directory: root)
        #expect(try store.context(recordID: "record-a") == nil)

        let sidecar = root.appendingPathComponent(MediaTaskMetadataStore.fileName)
        try Data("not-json".utf8).write(to: sidecar)
        #expect(try store.context(recordID: "record-a") == nil)

        let intended = context(providerID: "provider-a")
        try store.bind(recordID: "record-a", context: intended, allowLegacyBinding: true)
        #expect(try MediaTaskMetadataStore(directory: root).context(recordID: "record-a") == intended)
    }
}
