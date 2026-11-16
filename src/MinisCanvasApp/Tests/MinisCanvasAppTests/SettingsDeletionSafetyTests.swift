import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SettingsCenter deletion safety")
@MainActor
struct SettingsDeletionSafetyTests {
    private func makeCenter() -> (SettingsCenter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-deletion-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory,
                keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory)
        )
        return (center, directory)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation(SettingsDeletionPresentation(intent: intent).secondPhrase)
    }

    @Test func legacyProviderDeleteFailsClosedAndConfirmedDeleteIsOneShot() throws {
        let (center, directory) = makeCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(center.saveProvider(
            name: "SAFE_PROVIDER",
            apiKey: "secret",
            baseURL: "https://example.test/v1",
            modelNames: ["model"],
            protocolType: .openaiCompatible
        ))

        _ = center.deleteProvider(name: "SAFE_PROVIDER")
        #expect(center.envStore.entry(name: "SAFE_PROVIDER") != nil)

        let intent = try center.previewProviderDeletion(name: "SAFE_PROVIDER")
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try center.deleteProvider(name: "SAFE_PROVIDER", intent: intent)
        }
        #expect(!intent.reversible)
        #expect(SettingsDeletionPresentation(intent: intent).secondPhrase == "永久删除")
        let recoverable = try center.previewAllSessions()
        #expect(recoverable.reversible)
        #expect(SettingsDeletionPresentation(intent: recoverable).secondPhrase != "永久删除")
        let validated = try DeletionGate.validated(confirmed(recoverable),
            currentRevision: recoverable.revision, currentFingerprint: recoverable.fingerprint)
        #expect(validated.operationID == recoverable.operationID)
        let receipt = try center.deleteProvider(name: "SAFE_PROVIDER", intent: confirmed(intent))
        #expect(receipt.targetID == "SAFE_PROVIDER")
        #expect(center.envStore.entry(name: "SAFE_PROVIDER") == nil)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try center.deleteProvider(name: "SAFE_PROVIDER", intent: confirmed(intent))
        }
    }
}
