import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Consumer fixtures for the DeepSeek settings -> readiness -> picker chain.
/// This suite is intentionally mock-only and never invokes URLSession or
/// Keychain; production readiness remains responsible for live evidence.
@Suite("V425 DeepSeek settings readiness picker UI contract")
struct V425DeepSeekUIContractTests {
    @Test("custom DeepSeek picker runtime keeps the bare official route")
    @MainActor
    func customProviderDoesNotAppendV1() throws {
        let chat = ChatStore()
        let record = EnvVarEntry(
            name: DeepSeekProviderContract.apiKeyEnvironmentVariable,
            value: "fixture-deepseek-secret",
            isSecret: true,
            baseURL: DeepSeekProviderContract.baseURL,
            modelNames: [DeepSeekProviderContract.preferredModelID],
            protocolType: .openaiCompatible
        )
        let provider = try chat.makeCustomProvider(
            record: record,
            modelID: DeepSeekProviderContract.preferredModelID
        )
        let openAI = try #require(provider as? OpenAICompatibleProvider)
        #expect(openAI.customBaseURL == DeepSeekProviderContract.baseURL)
        #expect(openAI.appendV1Suffix == false)
        #expect(openAI.model.id == DeepSeekProviderContract.preferredModelID)
    }

    @Test("missing DeepSeek credential is actionable without blocking a sibling")
    func missingCredentialIsProviderLocal() {
        let deepSeek = SettingsStateClassification.classifyProviderCredential(
            providerID: DeepSeekProviderContract.providerID,
            persistenceError: .keychainReadMissing
        )
        let sibling = SettingsStateClassification.classifyProviderCredential(
            providerID: "openai",
            persistenceError: nil
        )
        #expect(deepSeek.isBlocked)
        #expect(deepSeek.isActionable)
        #expect(deepSeek.recoveryAction == .replaceAPIKey)
        #expect(sibling.state == .ready)
        #expect(sibling.isActionable == false)
    }

    @Test("DeepSeek settings error projection stays secret-safe")
    func settingsProjectionRedactsCredentialAndPayload() {
        let secret = "fixture-deepseek-secret"
        let projected = ProviderStatusTextProjection.project(
            "Authorization: Bearer \(secret) request body prompt=fixture"
        )
        #expect(projected.contains(secret) == false)
        #expect(projected.contains("Authorization") == false)
        #expect(projected.contains("request body") == false)
    }

    @Test("applied DeepSeek V4 Flash and sibling records remain independently selectable")
    func pickerKeepsSiblingHealthy() {
        let checkedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let records = [
            ProviderReadinessPersistenceRecord(
                providerID: DeepSeekProviderContract.providerID,
                modelID: DeepSeekProviderContract.preferredModelID,
                status: .passed,
                readinessState: .mock,
                checkedAt: checkedAt,
                evidenceID: "fixture-deepseek",
                isApplied: true
            ),
            ProviderReadinessPersistenceRecord(
                providerID: "openai",
                modelID: "gpt-fixture",
                status: .passed,
                readinessState: .mock,
                checkedAt: checkedAt,
                evidenceID: "fixture-openai",
                isApplied: true
            ),
        ]
        let picker = ProviderModelPickerConsumer(records: records)
        #expect(picker.isSelectable(
            providerID: DeepSeekProviderContract.providerID,
            modelID: DeepSeekProviderContract.preferredModelID
        ))
        #expect(picker.isSelectable(providerID: "openai", modelID: "gpt-fixture"))
        #expect(picker.selectableItems.map(\.providerID) == ["deepseek", "openai"])
    }

    @Test("settings source keeps the DeepSeek contract on the existing UI seams")
    func settingsSourceUsesProviderConversionReadinessAndPickerSeams() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
        #expect(settingsSource.contains("EnvVarStore.providerSuggestion(for: entry.name)"))
        #expect(settingsSource.contains("center.checkProviderReadiness(forProviderName: provider.name)"))
        #expect(settingsSource.contains("center.startProviderModelReadiness("))
        #expect(settingsSource.contains("ProviderStatusTextProjection.project"))

        let chatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift"
            ),
            encoding: .utf8
        )
        #expect(chatSource.contains("DeepSeekProviderContract.isCanonicalBaseURL"))
        #expect(chatSource.contains("config.appendV1Suffix = !DeepSeekProviderContract"))
    }
}
