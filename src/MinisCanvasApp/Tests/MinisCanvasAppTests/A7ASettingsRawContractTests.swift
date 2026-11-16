import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("A7-A Settings 环境变量布局与 Provider 键盘链")
struct A7ASettingsRawContractTests {
    private func settingsSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("环境变量动作栏在窄窗不与列表重叠")
    func environmentActionsHaveIndependentScrollableRows() throws {
        let source = try settingsSource()

        #expect(source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(source.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(source.contains("settings.environment.add-provider"))
        #expect(source.contains("settings.environment.add-variable"))
        #expect(source.contains("settings.environment.import-process"))
        #expect(source.contains("settings.environment.status"))
        #expect(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    }

    @Test("Provider sheet 使用可滚动的动态高度")
    func providerSheetDoesNotClipFieldsOrActions() throws {
        let source = try settingsSource()

        #expect(source.contains("ScrollView(.vertical)"))
        #expect(source.contains("minHeight: 260, idealHeight: 560, maxHeight: .infinity"))
        #expect(source.contains(".frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)"))
        #expect(source.contains(".onDisappear {\n            draftProbeTask?.cancel()"))
    }

    @Test("新增 Provider 延迟聚焦 API Key，已有 Provider 聚焦名称")
    func providerFocusPolicyIsExplicitAndSecretSafe() throws {
        let source = try settingsSource()

        #expect(source.contains("private enum ProviderEditFocus: Hashable"))
        #expect(source.contains("@FocusState private var focusedField: ProviderEditFocus?"))
        #expect(source.contains("let requestedFocus = initialFocus ?? (isEditing ? .name : .apiKey)"))
        #expect(source.contains("if requestedFocus == .modelFirst"))
        #expect(source.contains("focusedField = requestedFocus"))
        #expect(source.contains("let initialFocus: ProviderEditFocus?"))
        #expect(source.contains("self.initialFocus = initialFocus"))
        #expect(source.contains("await Task.yield()"))
        #expect(source.contains(".focused($focusedField, equals: .name)"))
        #expect(source.contains("focus: $focusedField"))
        #expect(source.contains(".focused($focusedField, equals: .baseURL)"))
        #expect(source.contains(".focused($focusedField, equals: .model(row.id))"))
        #expect(source.contains(".accessibilityLabel(\"API Key（仅输入或替换，不读取旧值）\")"))
        #expect(source.contains(".accessibilityHint(\"编辑已有供应商时留空表示保留 Keychain 引用\")"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.apiKey.reference-note\")"))
        #expect(source.contains("仅保存 Keychain 引用；此输入框只写入或替换 Key，不读取旧值；查看或复制请使用专门的凭据控件。"))
        #expect(source.contains("SecureField(\"输入新 Key；留空保留现有 Keychain 引用\""))
        #expect(source.contains("apiKey = \"\""))
        #expect(!source.contains("apiKey = existing.value"))
        #expect(source.contains("ProviderCredentialControls(model: credentialControlsModel)"))
        #expect(!source.contains("isAPIKeyRevealed"))
        #expect(!source.contains("revealFromKeychain"))
        #expect(!source.contains("settings.provider.apiKey.copy"))
        #expect(!source.contains(".accessibilityValue(apiKey)"))
    }

    @Test("Provider 字段 AX 标识与 API Key 键盘链保持稳定")
    func providerFieldsExposeStableAXIdentifiersAndFocusChain() throws {
        let source = try settingsSource()

        // These are compile-level source contracts: the identifiers are
        // attached to the actual fields, while the model selector is derived
        // from deterministic form order rather than a random UUID.
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.apiKey\")"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.baseURL\")"))
        #expect(source.contains(".accessibilityIdentifier(modelAccessibilityIdentifier(for: row))"))
        #expect(source.contains("private func modelAccessibilityIdentifier(for row: ProviderModelRow) -> String"))
        #expect(source.contains("return \"settings.provider.model.\\(index + 1)\""))

        #expect(source.contains("onSubmit: { focusedField = .baseURL }"))
        #expect(source.contains("focusedField = .model(firstModel.id)"))
        #expect(source.contains("focusedField = .model(next.id)"))
        #expect(source.contains("Button(\"保存\", action: submitIfValid)"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.readiness.check\")"))
        #expect(source.contains("settings.provider.model.readiness.check.\\(provider.name).\\(modelID)"))
    }

    @Test("Return 只使用合法保存路径，取消只关闭 sheet")
    func submitAndCancelKeyboardContractsAreFailClosed() throws {
        let source = try settingsSource()

        #expect(source.contains("private func submitIfValid()"))
        #expect(source.contains("guard canSave else { return }"))
        #expect(source.contains(".onSubmit { focusedField = .apiKey }"))
        #expect(source.contains("onSubmit: { focusedField = .baseURL }"))
        #expect(source.contains("Button(\"保存\", action: submitIfValid)"))
        #expect(source.contains(".keyboardShortcut(.defaultAction)"))
        #expect(source.contains("Button(\"取消\")"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains("focusedField = nil\n            dismiss()"))
    }

    @Test("Provider 失焦/离开时不读取或暴露显式密钥")
    func providerSecretStillResetsOnFocusAndLifecycleChanges() throws {
        let source = try settingsSource()

        let secretStart = try #require(source.range(of: "private struct ProviderSecretField: View"))
        let secretEnd = try #require(source.range(
            of: "enum ProviderEditSaveOutcome",
            range: secretStart.upperBound..<source.endIndex
        ))
        let secretField = String(source[secretStart.lowerBound..<secretEnd.lowerBound])
        #expect(secretField.contains("SecureField(\"输入新 Key；留空保留现有 Keychain 引用\""))
        #expect(secretField.contains(".accessibilityLabel(\"API Key（仅输入或替换，不读取旧值）\")"))
        #expect(secretField.contains(".accessibilityIdentifier(\"settings.provider.apiKey.reference-note\")"))
        #expect(!secretField.contains("isRevealed"))
        #expect(!secretField.contains("readCredential"))
        #expect(!secretField.contains("copy"))
    }

    @Test("环境变量 sheet 在窄窗可滚动并保持名称/值键盘链")
    func environmentVariableSheetFocusAndNarrowLayout() throws {
        let source = try envVarSheetSource()

        #expect(source.contains("private enum EnvVarEditFocus: Hashable"))
        #expect(source.contains("@FocusState private var focusedField: EnvVarEditFocus?"))
        #expect(source.contains("ScrollView(.vertical)"))
        #expect(source.contains(".frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity)"))
        #expect(source.contains("await Task.yield()"))
        #expect(source.contains("focusedField = isEditing ? .value : .name"))
        #expect(source.contains(".focused($focusedField, equals: .name)"))
        #expect(source.contains(".focused($focusedField, equals: .value)"))
        #expect(source.contains(".onSubmit { focusedField = .value }"))
        #expect(source.contains(".onSubmit { submitIfValid() }"))
        #expect(source.contains("guard canSave else { return }"))
        #expect(source.contains("focusedField = nil"))
    }

    private func envVarSheetSource() throws -> String {
        let source = try settingsSource()
        guard let start = source.range(of: "private enum EnvVarEditFocus"),
              let end = source.range(of: "// MARK: - U5 模型供应商", range: start.upperBound..<source.endIndex)
        else {
            throw NSError(domain: "A7ASettingsRawContractTests", code: 1)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
