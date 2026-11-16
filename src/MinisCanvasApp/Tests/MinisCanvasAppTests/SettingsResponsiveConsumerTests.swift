import Foundation
import Testing
import MinisCore

@testable import MinisCanvasApp

@Suite("P3 Settings responsive consumer")
struct SettingsResponsiveConsumerTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
    }

    private func source(named path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(path),
            encoding: .utf8
        )
    }

    @Test("Settings width policy covers the supported 600...1600pt range")
    func widthPolicyIsBoundedAndReadable() {
        let compact = SettingsLayoutMetrics.forWidth(600)
        let medium = SettingsLayoutMetrics.forWidth(800)
        let regular = SettingsLayoutMetrics.forWidth(1100)
        let wide = SettingsLayoutMetrics.forWidth(1400)

        #expect(compact.widthClass == .compact)
        #expect(compact.showsSidebarLabels)
        #expect(medium.widthClass == .medium)
        #expect(medium.showsSidebarLabels)
        #expect(regular.widthClass == .regular)
        #expect(regular.showsSidebarLabels)
        #expect(wide.widthClass == .wide)
        #expect(wide.showsSidebarLabels)
        #expect(SettingsLayoutMetrics.forWidth(320).widthClass == .compact)
        #expect(SettingsLayoutMetrics.forWidth(2400).widthClass == .wide)
        #expect(compact.sidebarWidth < medium.sidebarWidth)
        #expect(medium.sidebarWidth < regular.sidebarWidth)
        #expect(regular.sidebarWidth < wide.sidebarWidth)
    }

    @Test("Settings surface keeps title, close, sidebar and content locators stable")
    func settingsSurfaceHasStableAccessibilityContract() throws {
        let settings = try source(
            named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        )

        #expect(settings.contains("GeometryReader { geometry in"))
        #expect(settings.contains("SettingsLayoutMetrics.forWidth(geometry.size.width)"))
        #expect(settings.contains(".frame(minWidth: SettingsLayoutPolicy.minimumSupportedWidth, minHeight: 460)"))
        #expect(settings.contains(".accessibilityIdentifier(\"settings.surface\")"))
        #expect(settings.contains(".accessibilityIdentifier(\"settings.sidebar.title\")"))
        #expect(settings.contains(".accessibilityIdentifier(\"settings.title\")"))
        #expect(settings.contains(".accessibilityIdentifier(\"settings.close\")"))
        #expect(settings.contains("settingsSidebar(metrics: metrics)"))
        #expect(settings.contains("settingsPage(title: isSearchingSettings ? \"搜索设置\" : selectedPage.displayTitle, metrics: metrics)"))
        #expect(settings.contains("MinisIconTokens.keylineOrangeA7A.opacity(0.12)"))
        #expect(settings.contains("Text(page.displayTitle)"))
        #expect(settings.contains("Spacer(minLength: 0)"))
        #expect(settings.contains("if metrics.showsSidebarLabels"))
        #expect(!settings.contains("showsSidebarLabels: false"))
        #expect(settings.contains("AdaptiveLayoutPolicy.widthClass(for: width)"))
        #expect(settings.contains("MCPSettingsTab(center: center, widthClass: metrics.adaptiveWidthClass)"))
    }

    @Test("Numeric Settings control exposes a stable container without replacing native value")
    func numericFieldKeepsNativeEditingAndAddsContainerLocator() throws {
        let numeric = try source(
            named: "src/MinisCanvasApp/Sources/MinisCanvasApp/ValidatedNumericSettingField.swift"
        )

        #expect(numeric.contains(".accessibilityIdentifier(identifier)"))
        #expect(numeric.contains(".accessibilityIdentifier(\"\\(identifier).container\")"))
        #expect(numeric.contains(".accessibilityElement(children: .contain)"))
        #expect(numeric.contains("按 Enter 或离开后提交，按 Esc 恢复"))
        #expect(!numeric.contains(".accessibilityValue("))
    }

    @Test("Provider readiness labels are explicit and secret-free")
    func providerStateLabelsDescribeRecovery() {
        let ready = SettingsStateClassification.classifyProviderCredential(
            providerID: "provider",
            persistenceError: nil
        )
        let blocked = SettingsStateClassification.classifyProviderCredential(
            providerID: "provider",
            persistenceError: .keychainReadMissing
        )

        #expect(ready.statusLabel == "就绪")
        #expect(ready.recoveryLabel == nil)
        #expect(ready.accessibilityValue == "就绪")
        #expect(blocked.statusLabel == "受阻")
        #expect(blocked.recoveryLabel == "直接输入新 Key 替换")
        #expect(blocked.accessibilityValue.contains("受阻"))
        #expect(!blocked.accessibilityValue.contains("sk-"))
    }

    @Test("Validated provider snapshot persists only a Keychain reference and closes the factory/chat contract")
    func providerSnapshotIsSecretFreeAndConsumable() throws {
        let entry = EnvVarEntry(
            name: "P3_PROVIDER_API_KEY",
            value: "fixture-secret-must-not-cross-the-boundary",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example/v1",
            modelNames: ["model-a", " model-a ", "model-b"],
            protocolType: .openaiCompatible
        )
        let snapshot = SettingsProviderConfigurationSnapshot(entry: entry)

        #expect(snapshot.state == .ready)
        #expect(snapshot.credentialReference == "P3_PROVIDER_API_KEY")
        #expect(snapshot.modelIDs == ["model-a", "model-b"])
        #expect(snapshot.providerConfig?.apiKey == nil)
        #expect(snapshot.providerConfig?.apiKeyEnvVar == "P3_PROVIDER_API_KEY")
        #expect(snapshot.providerConfig.map { ProviderFactory.shared.hasBuilder(for: $0.providerType) } == true)

        let persisted = String(
            decoding: try JSONEncoder().encode(snapshot),
            as: UTF8.self
        )
        #expect(!persisted.contains("fixture-secret-must-not-cross-the-boundary"))
        let reopened = try JSONDecoder().decode(
            SettingsProviderConfigurationSnapshot.self,
            from: Data(persisted.utf8)
        )
        #expect(reopened == snapshot)

        let consumer = SettingsProviderChatConsumerContract(snapshot: snapshot, modelID: "model-a")
        #expect(consumer?.providerID == "P3_PROVIDER_API_KEY")
        #expect(consumer?.modelID == "model-a")
        #expect(consumer?.credentialReference == "P3_PROVIDER_API_KEY")
        #expect(consumer?.providerConfig.apiKey == nil)
        #expect(consumer?.providerConfig.apiKeyEnvVar == "P3_PROVIDER_API_KEY")
        #expect(!String(describing: consumer).contains("fixture-secret-must-not-cross-the-boundary"))
    }

    @Test("Provider snapshot explains invalid URL, model, and credential-reference states")
    func providerSnapshotHasUnderstandableInvalidStates() {
        let invalidURL = SettingsProviderConfigurationSnapshot(entry: EnvVarEntry(
            name: "P3_PROVIDER_API_KEY",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://user:password@provider.example/v1",
            modelNames: ["model-a"]
        ))
        #expect(invalidURL.state == .invalidBaseURL)
        #expect(invalidURL.statusMessage.contains("Base URL"))

        let missingModel = SettingsProviderConfigurationSnapshot(entry: EnvVarEntry(
            name: "P3_PROVIDER_API_KEY",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example/v1",
            modelNames: []
        ))
        #expect(missingModel.state == .missingModel)
        #expect(missingModel.statusMessage.contains("模型"))

        let invalidReference = SettingsProviderConfigurationSnapshot(entry: EnvVarEntry(
            name: "not a key",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example/v1",
            modelNames: ["model-a"]
        ))
        #expect(invalidReference.state == .missingCredentialReference)
        #expect(invalidReference.statusMessage.contains("API Key"))

        let legacyPlaintext = SettingsProviderConfigurationSnapshot(entry: EnvVarEntry(
            name: "P3_PROVIDER_API_KEY",
            value: "legacy-secret-never-reused-by-settings",
            isSecret: true,
            valueInKeychain: false,
            baseURL: "https://provider.example/v1",
            modelNames: ["model-a"]
        ))
        #expect(legacyPlaintext.state == .missingCredentialReference)
        #expect(legacyPlaintext.credentialReference == nil)
        #expect(!String(describing: legacyPlaintext).contains("legacy-secret-never-reused-by-settings"))
    }

    @Test("Provider Settings never offers a read or copy path for an existing secret")
    func providerSettingsKeepCredentialReferenceOnly() throws {
        let settings = try source(
            named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        )
        #expect(settings.contains("仅保存 Keychain 引用"))
        #expect(settings.contains("settings.provider.apiKey.reference-note"))
        #expect(settings.contains("settings.provider.configuration-recovery"))
        #expect(settings.contains("configurationRecoveryFocus(for: configuration.state)"))
        #expect(settings.contains("return .modelFirst"))
        #expect(!settings.contains("revealFromKeychain"))
        #expect(!settings.contains("settings.provider.apiKey.copy"))
        #expect(!settings.contains("providerCredentialRead(named:"))
        #expect(!settings.contains("apiKey = existing.value"))
    }

    @Test("Provider row actions expose operable native AX labels and identifiers")
    func providerActionsHaveNativeAccessibilityRoutes() throws {
        let settings = try source(
            named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        )

        #expect(settings.contains("accessibilityLabel(\"编辑\\(entryKind) \\(entry.name)\")"))
        #expect(settings.contains("settings.environment.edit.\\(component)"))
        #expect(settings.contains("settings.environment.delete.\\(component)"))
        #expect(settings.contains("settings.provider.readiness.check"))
        #expect(settings.contains("accessibilityValue(center.isCheckingProviderReadiness ? \"进行中\" : \"可操作\")"))
    }
}
