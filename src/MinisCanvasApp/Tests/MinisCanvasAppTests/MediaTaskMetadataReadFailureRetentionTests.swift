import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("CONC2 metadata sidecar read failure retention")
struct MediaTaskMetadataReadFailureRetentionTests {
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

    @Test func unreadableExistingSidecarCannotBeReplacedByAnotherBinding() throws {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let directory = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("media-read-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = directory.appendingPathComponent(MediaTaskMetadataStore.fileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let firstContext = context(providerID: "provider-a")
        try MediaTaskMetadataStore(directory: directory).bind(
            recordID: "record-a", context: firstContext, allowLegacyBinding: true
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecar.path)

        // The parent directory stays writable, so an atomic rename could
        // replace the unreadable file. Confirm this is a real read error first.
        switch Result(catching: { try Data(contentsOf: sidecar) }) {
        case .success:
            Issue.record("Test precondition failed: the existing sidecar remained readable")
            return
        case .failure(let error):
            #expect((error as NSError).code != NSFileReadNoSuchFileError)
        }

        let second = MediaTaskMetadataStore(directory: directory)
        let secondContext = context(providerID: "provider-b")
        #expect(throws: MediaTaskMetadataError.persistenceFailed) {
            try second.bind(recordID: "record-b", context: secondContext, allowLegacyBinding: true)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        let restored = MediaTaskMetadataStore(directory: directory)
        #expect(try restored.context(recordID: "record-a") == firstContext)
        #expect(try restored.context(recordID: "record-b") == nil)
    }
}
