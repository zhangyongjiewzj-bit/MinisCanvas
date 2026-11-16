import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 persistent state classification")
struct P3SettingsStateClassificationTests {
    @Test
    func missingLegacyCredentialIsProviderLocalAndReplaceable() {
        let classification = SettingsStateClassification.classifyProviderCredential(
            providerID: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
            persistenceError: .keychainReadMissing
        )

        #expect(classification.providerID == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(classification.state == .blocked)
        #expect(classification.failure == .missing)
        #expect(classification.recoveryAction == .replaceAPIKey)
        #expect(classification.isBlocked)
        #expect(classification.isActionable)
        #expect(classification.message?.contains("直接输入新 Key 替换") == true)
    }

    @Test
    func deniedAndFailedLegacyCredentialsRemainTypedAndNonCrashing() {
        let denied = SettingsStateClassification.classifyProviderCredential(
            providerID: "DENIED_PROVIDER",
            persistenceError: .keychainReadDenied
        )
        let failed = SettingsStateClassification.classifyProviderCredential(
            providerID: "FAILED_PROVIDER",
            persistenceError: .keychainReadFailed
        )

        #expect(denied.state == .blocked)
        #expect(denied.failure == .denied)
        #expect(denied.recoveryAction == .replaceAPIKey)
        #expect(failed.state == .blocked)
        #expect(failed.failure == .failed)
        #expect(failed.recoveryAction == .replaceAPIKey)
        #expect(denied.message != failed.message)
    }

    @Test
    func healthySiblingProviderRemainsReady() {
        let healthy = SettingsStateClassification.classifyProviderCredential(
            providerID: "HEALTHY_PROVIDER",
            persistenceError: nil
        )

        #expect(healthy.state == .ready)
        #expect(healthy.failure == nil)
        #expect(healthy.recoveryAction == .none)
        #expect(!healthy.isBlocked)
        #expect(!healthy.isActionable)
        #expect(healthy.message == nil)
    }

    @Test
    func allFiveStateClassesHaveTypedDescriptors() {
        let represented = Set(SettingsStateClassification.descriptors.map(\.stateClass))
        #expect(represented == Set(PersistentStateClass.allCases))
    }

    @Test
    func canonicalEntriesHaveOneSettingsKeyAndOneEffectiveConsumer() {
        let canonical = SettingsStateClassification.descriptors(
            for: .canonicalSetting
        )
        #expect(canonical.allSatisfy { $0.settingsKey != nil })
        #expect(canonical.allSatisfy { $0.effectiveSource != nil })
        #expect(Set(canonical.compactMap(\.settingsKey)).count == canonical.count)
        #expect(Set(canonical.map(\.consumer)).count == canonical.count)
    }

    @Test
    func viewAndHistoryStateCannotOverrideEffectiveValues() {
        let nonCanonical = SettingsStateClassification.descriptors.filter {
            $0.stateClass == .viewState || $0.stateClass == .historyCache
        }
        #expect(nonCanonical.count == 2)
        #expect(nonCanonical.allSatisfy { !$0.mayOverrideEffectiveValue })
        #expect(nonCanonical.allSatisfy {
            !$0.owner.isEmpty && $0.priority > 0 && !$0.reset.isEmpty
                && !$0.persistence.isEmpty && !$0.consumer.isEmpty
                && !$0.scope.isEmpty && !$0.defaultValue.isEmpty
                && !$0.restart.isEmpty && !$0.validation.isEmpty
        })
    }

    @Test
    @MainActor
    func browserEffectiveValueIsThePersistedSettingsValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SettingsState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var initial = AppSettings.defaults
        initial.browser.userAgentPreset = .mobileChrome
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory, initial: initial),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )

        #expect(center.effectiveBrowserSettings == center.settings.browser)
        #expect(center.effectiveBrowserSettings.userAgentPreset == .mobileChrome)
        #expect(
            SettingsStateClassification.canonicalDescriptor(for: "browser")?.effectiveSource
                == "SettingsCenter.effectiveBrowserSettings"
        )
    }

    @Test
    @MainActor
    func disabledTerminalSafetyUsesFailClosedCapability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3TerminalState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        center.setSafeMode(true)
        let snapshot = TerminalContextSnapshot(
            sessionID: "session",
            turnID: "turn",
            taskID: "task",
            projectID: "project",
            workdir: directory.path
        )

        let request = TerminalContextPanelAdapter(
            snapshot: snapshot,
            settings: center
        ).makeRequest(command: "echo blocked", cwd: directory.path, approved: false)
        #expect(request.capabilityID.isEmpty)
    }

    @Test("provider diagnostic mutations cannot expose credentials or transport payloads")
    func providerDiagnosticMutationsRemainSecretSafe() {
        let secret = "sk-live-0123456789abcdef0123456789"
        let mutations = [
            "鉴权失败（HTTP 401） Authorization: Bearer \(secret)",
            "鉴权失败（HTTP 401）?api_key=\(secret)",
            "鉴权失败（HTTP 401） response body: {\"token\":\"\(secret)\"}",
            "鉴权失败（HTTP 401） request body: {\"messages\":[{\"content\":\"\(secret)\"}]}"
        ]

        for mutation in mutations {
            let projected = ProviderStatusTextProjection.project(mutation)
            #expect(projected.contains("鉴权失败"))
            #expect(projected.contains("HTTP 401"))
            #expect(!projected.contains(secret))
            #expect(!projected.localizedCaseInsensitiveContains("authorization"))
            #expect(!projected.localizedCaseInsensitiveContains("bearer"))
            #expect(!projected.localizedCaseInsensitiveContains("request body"))
            #expect(!projected.localizedCaseInsensitiveContains("response body"))
            #expect(!projected.contains("api_key="))
            #expect(!projected.contains("token"))
        }
    }

    @Test("keychain typed cause survives display projection without raw detail")
    func keychainCauseRemainsActionableAfterProjection() {
        let raw = "无法从钥匙串读取当前 API Key：访问被拒绝；detail=sk-keychain-0123456789abcdef"
        let projected = ProviderStatusTextProjection.project(raw)

        #expect(projected.contains("钥匙串"))
        #expect(projected.contains("访问被拒绝"))
        #expect(!projected.contains("sk-keychain-0123456789abcdef"))
        #expect(!projected.contains("detail="))
    }
}
