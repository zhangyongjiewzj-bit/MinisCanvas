import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

private struct MetadataReproProvider: CloudVideoGenerator {
    let providerID: String
    var displayName: String { providerID }
    let isConfigured = true

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        Issue.record("Metadata persistence must not submit a remote task")
        return "unused"
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        Issue.record("Metadata persistence must not poll a remote task")
        return CloudTaskState(phase: .running)
    }
}

@Suite("CONC2 multi-provider metadata persistence regression")
struct MediaTaskMetadataMultiProviderReproTests {
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

    @Test func twoProviderExecutorsRetainBothMetadataRecordsAfterInterleavedSaves() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conc2-media-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = VideoTaskExecutorRegistry(
            store: VideoTaskStore(directory: directory),
            assetDownloader: URLSessionVideoAssetDownloader(),
            assetDirectory: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let providerA = MetadataReproProvider(providerID: "provider-a")
        let providerB = MetadataReproProvider(providerID: "provider-b")

        // Both production executors load the same initially empty sidecar before
        // either writes. Serial writes make the stale-snapshot overwrite repeatable.
        let executorA = await registry.executor(providerID: providerA.providerID, provider: providerA)
        let executorB = await registry.executor(providerID: providerB.providerID, provider: providerB)
        let metadataA = await executorA.metadataStore
        let metadataB = await executorB.metadataStore
        #expect(metadataA !== metadataB)

        let contextA = context(providerID: providerA.providerID)
        let contextB = context(providerID: providerB.providerID)
        try metadataA.bind(recordID: "record-a", context: contextA, allowLegacyBinding: true)
        try metadataB.bind(recordID: "record-b", context: contextB, allowLegacyBinding: true)

        let restored = MediaTaskMetadataStore(directory: directory)
        #expect(try restored.context(recordID: "record-a") == contextA)
        #expect(try restored.context(recordID: "record-b") == contextB)
    }
}
