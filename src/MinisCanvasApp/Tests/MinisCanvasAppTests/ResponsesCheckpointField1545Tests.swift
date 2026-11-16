import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("Responses checkpoint field route 1545")
@MainActor
struct ResponsesCheckpointField1545Tests {
    @Test("factory provider binds the App's field profile before durable-state lookup")
    func fieldProviderUsesSyntheticFieldRoot() throws {
        let fieldRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-field-1545-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "responses-checkpoint-1545",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: fieldRoot.path
            ],
            processArguments: [
                "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                RuntimeIsolationProfile.fieldActivationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent(
                    "Workflows", isDirectory: true
                )
            ),
            sessionBadgeStore: SessionBadgeStore(
                directory: profile.minisCanvasDirectory
            ),
            sessionDocumentStore: SessionDocumentStore(
                directory: profile.sessionDirectory
            ),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            canvasFeatureLane: .phase3NonCanvas
        )
        let expected = profile.minisCoreDirectory.appendingPathComponent(
            "responses-attempts", isDirectory: true
        )
        #expect(bridge.chat.responsesAttemptCheckpointDirectory == expected)

        var config = ProviderConfig(
            label: "synthetic-responses",
            providerType: .openAIResponses,
            runtimeProviderID: "synthetic-responses",
            apiKey: "synthetic-only"
        )
        config.attemptCheckpointDirectory =
            bridge.chat.responsesAttemptCheckpointDirectory
        let built = try ProviderFactory().makeProvider(for: config)
        let provider = try #require(built as? OpenAIResponsesProvider)
        #expect(provider.attemptCheckpointDirectory == expected)
        let checkpoint = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "synthetic-responses",
            modelID: provider.model.id,
            directoryOverride: provider.attemptCheckpointDirectory
        ))
        #expect(checkpoint.deletingLastPathComponent() == expected)
        #expect(checkpoint.path.hasPrefix(profile.rootDirectory.path + "/"))

        // Runtime-only path injection must not be written into a saved config.
        let encoded = try JSONEncoder().encode(config)
        #expect(String(decoding: encoded, as: UTF8.self).contains(fieldRoot.path) == false)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: encoded)
        #expect(decoded.attemptCheckpointDirectory == nil)
    }
}
