import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("IF-02 设置页关闭与 Provider Key 显隐")
struct IF02SettingsUIContractTests {
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

    private func settingsCenterSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsCenter.swift"
            ),
            encoding: .utf8
        )
    }

    private func skillsStoreSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SkillsStore.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("设置页有可见且可访问的关闭入口")
    func settingsExposeVisibleCloseAction() throws {
        let source = try settingsSource()

        #expect(source.contains("Label { Text(\"关闭\") } icon: { MinisIconView(.close, size: 14) }"))
        #expect(source.contains(".accessibilityLabel(\"关闭设置\")"))
        #expect(source.contains(".accessibilityHint(\"关闭设置面板\")"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test("设置页只保留一个关闭动作和 AX identifier")
    func settingsExposeSingleCloseAction() throws {
        let source = try settingsSource()

        #expect(source.components(separatedBy: ".accessibilityIdentifier(\"settings.close\")").count - 1 == 1)
        #expect(!source.contains("settings.toolbar.close"))
    }

    @Test("设置侧栏保留项目 Keyline 图标并避开 TabView 宿主拉伸")
    func settingsSidebarUsesBoundedProjectIcons() throws {
        let source = try settingsSource()

        #expect(source.contains("enum SettingsPage: String, CaseIterable, Identifiable"))
        #expect(source.contains("var icon: MinisIcon"))
        #expect(source.contains("MinisIconView("))
        #expect(source.contains("page.icon,"))
        #expect(source.contains("size: 16"))
        #expect(source.contains("MinisIconTokens.keylineOrangeA7A.opacity(0.12)"))
        #expect(source.contains(".accessibilityIdentifier(page.accessibilityIdentifier)"))
        #expect(!source.contains("Label(\"常规\", systemImage:"))
        #expect(!source.contains(".tabItem"))
        #expect(!source.contains(".modifier(SidebarAdaptableModifier())"))
    }

    @Test("设置标题和关闭入口局部化到右侧内容而不覆盖侧栏")
    func settingsHeaderIsPageLocal() throws {
        let source = try settingsSource()

        #expect(source.contains("private func settingsPage<Content: View>"))
        #expect(source.contains("Text(title)"))
        #expect(source.contains("settingsContent(for: selectedPage, metrics: metrics)"))
        #expect(source.components(separatedBy: "settingsPage(title: isSearchingSettings ? \"搜索设置\" : selectedPage.displayTitle, metrics: metrics)").count - 1 == 1)
        #expect(!source.contains(".safeAreaInset(edge: .top"))
        #expect(source.components(separatedBy: ".accessibilityIdentifier(\"settings.close\")").count - 1 == 1)
    }

    @Test("设置页在窄窗保持可读侧栏并在重开时刷新持久化状态")
    func settingsResponsiveReopenContract() throws {
        let source = try settingsSource()

        #expect(abs(SettingsLayoutPolicy.sidebarWidth(for: 600) - 168) < 0.001)
        #expect(SettingsLayoutPolicy.sidebarWidth(for: 1_600) == 220)
        #expect(SettingsLayoutPolicy.sidebarWidth(for: .nan) == 220)
        #expect(source.contains("enum SettingsLayoutPolicy"))
        #expect(source.contains("minimumSupportedWidth: CGFloat = 600"))
        #expect(source.contains("sidebarWidth(for availableWidth: CGFloat)"))
        #expect(source.contains("GeometryReader { geometry in"))
        #expect(source.contains("settingsSidebar(metrics: metrics)"))
        #expect(source.contains("center.reloadAll()"))
        #expect(source.contains("dismissedPersistenceError = nil"))
    }

    @Test("Provider Key 始终使用安全输入且不泄漏密钥")
    func providerKeyVisibilityContract() throws {
        let source = try settingsSource()

        #expect(source.contains("ProviderSecretField("))
        #expect(source.contains("value: $apiKey,\n                    focus: $focusedField,"))
        #expect(source.contains("SecureField(\"输入新 Key；留空保留现有 Keychain 引用\""))
        #expect(source.contains(".accessibilityLabel(\"API Key（仅输入或替换，不读取旧值）\")"))
        #expect(source.contains(".accessibilityHint(\"编辑已有供应商时留空表示保留 Keychain 引用\")"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.apiKey\")"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.apiKey.reference-note\")"))
        #expect(source.contains("仅保存 Keychain 引用；此输入框只写入或替换 Key，不读取旧值；查看或复制请使用专门的凭据控件。"))
        #expect(!source.contains("isAPIKeyRevealed"))
        #expect(!source.contains("readCredential(canonicalName)"))
        #expect(!source.contains("settings.provider.apiKey.reveal"))
        #expect(!source.contains("settings.provider.apiKey.copy"))
        #expect(!source.contains(".accessibilityLabel(apiKey)"))
        #expect(!source.contains(".accessibilityValue(apiKey)"))
    }

    @Test("Provider 凭证 UI 保留 Keychain 引用并支持失败替换")
    func providerCredentialLifecycleContract() throws {
        let source = try settingsSource()
        let centerSource = try settingsCenterSource()

        #expect(source.contains("return hasExistingProviderReference ? .keepExisting : .missing"))
        #expect(source.contains("return .replace(trimmed)"))
        #expect(source.contains("ProviderCredentialUpdate"))
        #expect(!source.contains("readCredential(canonicalName)"))
        #expect(!source.contains("KeychainStore().get(canonicalName)"))
        #expect(!source.contains("apiKey = existing.isProviderRecord ? \"\" : existing.value"))
        #expect(!source.contains("settings.provider.apiKey.copy"))
        #expect(!source.contains("currentPasteboard.changeCount == copiedChangeCount"))
        #expect(centerSource.contains("无法从钥匙串读取当前 API Key：未找到；请直接输入新 Key 替换。"))
        #expect(centerSource.contains("无法从钥匙串读取当前 API Key：访问被拒绝；请检查钥匙串权限，或直接输入新 Key 替换。"))
        #expect(centerSource.contains("无法从钥匙串读取当前 API Key：读取失败；请重试，或直接输入新 Key 替换。"))
        #expect(!centerSource.contains("currentEnvEntry(name: old, resolveCredential: submitted.isEmpty)"))
        #expect(centerSource.contains("currentEnvEntry(name: old, resolveCredential: false)"))
        #expect(centerSource.components(separatedBy: "switch envStore.readEnvVarResult(name: record.name)").count - 1 == 1)
        let renameContractSlices = centerSource.components(separatedBy: "func previewProviderRename")
        #expect(renameContractSlices.count == 2)
        let renameAndMetadataSource = renameContractSlices.count == 2
            ? renameContractSlices[1].components(separatedBy: "private func currentEnvEntry")
            : []
        #expect(renameAndMetadataSource.count == 2)
        let renameAndMetadataBody = renameAndMetadataSource.first ?? ""
        #expect(!renameAndMetadataBody.contains("envStore.getEnvVar(name: record.name)"))
        #expect(!centerSource.contains("restoreEnvEntry"))
        #expect(centerSource.contains("let oldDeleteError = envStore.lastPersistenceError"))
        #expect(centerSource.contains("let removedNewProvider = envStore.deleteEnvVar(name: canonicalNew)"))
        #expect(centerSource.contains("guard oldDeleteError == .keychainDeleteFailed else"))
        #expect(centerSource.contains("currentEnvEntry(name: canonicalNew, resolveCredential: false)"))
        #expect(centerSource.contains("if resolveCredential, entry.valueInKeychain"))
    }

    @Test("失焦、取消、保存和离开表单都保持安全边界")
    func providerKeyResetsOnExitPaths() throws {
        let source = try settingsSource()

        #expect(source.contains("@FocusState private var focusedField: ProviderEditFocus?"))
        let secretStart = try #require(source.range(of: "private struct ProviderSecretField: View"))
        let secretEnd = try #require(source.range(
            of: "enum ProviderEditSaveOutcome",
            range: secretStart.upperBound..<source.endIndex
        ))
        let secretField = String(source[secretStart.lowerBound..<secretEnd.lowerBound])
        #expect(secretField.contains("SecureField(\"输入新 Key；留空保留现有 Keychain 引用\""))
        #expect(secretField.contains(".accessibilityIdentifier(\"settings.provider.apiKey\")"))
        #expect(secretField.contains(".accessibilityIdentifier(\"settings.provider.apiKey.reference-note\")"))
        #expect(!secretField.contains("isRevealed"))
        #expect(!secretField.contains("readCredential"))
        #expect(!secretField.contains("copy"))

        let sheetStart = try #require(source.range(of: "private struct ProviderEditSheet: View"))
        let sheetEnd = try #require(source.range(
            of: "private func modelAccessibilityIdentifier",
            range: sheetStart.upperBound..<source.endIndex
        ))
        let sheet = String(source[sheetStart.lowerBound..<sheetEnd.lowerBound])
        let cancelStart = try #require(sheet.range(of: "Button(\"取消\")", options: [], range: nil))
        let providerCancelStart = try #require(sheet.range(
            of: "Button(\"取消\")",
            range: cancelStart.upperBound..<sheet.endIndex
        ))
        let cancelEnd = try #require(sheet.range(
            of: ".keyboardShortcut(.cancelAction)",
            range: providerCancelStart.upperBound..<sheet.endIndex
        ))
        let cancelBody = String(sheet[providerCancelStart.lowerBound..<cancelEnd.lowerBound])
        #expect(cancelBody.contains("focusedField = nil"))
        #expect(cancelBody.contains("dismiss()"))

        let submitStart = try #require(sheet.range(of: "private func submitIfValid()"))
        let submitBody = String(sheet[submitStart.lowerBound..<sheet.endIndex])
        #expect(submitBody.contains("focusedField = nil"))
        #expect(submitBody.contains("let draft = ProviderEditDraft("))
    }

    @Test("Provider credential sheet remains readable under narrow and dynamic layouts")
    func providerCredentialSheetLayoutAndErrorContract() throws {
        let source = try settingsSource()

        #expect(source.contains(".frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)"))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains(".accessibilityIdentifier(\"settings.provider.save.error\")"))
        #expect(source.contains(".foregroundStyle(Color.red)"))
    }

    @Test("Provider save keeps the sheet open on typed persistence failure")
    func providerSaveFailureDoesNotDismissSheet() throws {
        let source = try settingsSource()

        let sheetStart = try #require(source.range(of: "private struct ProviderEditSheet: View"))
        let submitStart = try #require(source.range(
            of: "private func submitIfValid()",
            range: sheetStart.upperBound..<source.endIndex
        ))
        let submitEnd = try #require(source.range(
            of: "private func modelAccessibilityIdentifier",
            range: submitStart.upperBound..<source.endIndex
        ))
        let submit = String(source[submitStart.lowerBound..<submitEnd.lowerBound])

        #expect(submit.contains("ProviderEditSaveTransition(outcome: onSave(draft))"))
        let dismissCaseStart = try #require(submit.range(of: "case .dismiss:"))
        let presentCaseStart = try #require(submit.range(
            of: "case .present",
            range: dismissCaseStart.upperBound..<submit.endIndex
        ))
        let dismissCase = String(submit[dismissCaseStart.lowerBound..<presentCaseStart.lowerBound])
        #expect(dismissCase.contains("dismiss()"))
        #expect(submit.contains("case .present(let message)"))
        let presentBody = String(submit[presentCaseStart.lowerBound..<submit.endIndex])
        #expect(presentBody.contains("errorMessage = message"))
        #expect(presentBody.contains("focusedField = .apiKey"))
        #expect(!presentBody.contains("dismiss()"))
    }

    @Test("Provider save transition keeps failure visible and exposes only safe typed AX text")
    func providerSaveTransitionIsExecutableAndAXSafe() throws {
        let source = try settingsSource()
        let failure = ProviderSaveFailureCategory.keychainWriteFailed
        let transition = ProviderEditSaveTransition(outcome: .failed(failure))

        #expect(transition == .present(errorMessage: failure.message))
        #expect(transition.keepsSheetPresented)
        #expect(transition.accessibilityValue == failure.message)
        #expect(transition.accessibilityValue?.contains("secret") == false)
        #expect(transition.accessibilityValue?.contains("API Key") == false)
        #expect(source.contains("focusedField = .apiKey\n            errorMessage = message"))
        #expect(source.contains("focusedField = .apiKey\n                    errorMessage = \"供应商保存流程未完成（PROVIDER-UPDATE-FAILED）。请刷新列表，确认名称和凭据引用后重试。\""))
    }

    @Test("Provider saved transition dismisses the sheet")
    func providerSavedTransitionDismissesSheet() {
        let transition = ProviderEditSaveTransition(outcome: .saved)

        #expect(transition == .dismiss)
        #expect(!transition.keepsSheetPresented)
        #expect(transition.accessibilityValue == nil)
    }

    @Test("设置页提供可持久化的系统字号入口")
    func typographySettingsExposeSupportedRangeAndDefault() throws {
        let source = try settingsSource()

        #expect(source.contains("TypographySettingsTab(center: center)"))
        #expect(source.contains("TypographySettings.uiBaseFontSizeRange"))
        #expect(source.contains("TypographySettings.uiBaseFontSizeStep"))
        #expect(source.contains("center.uiBaseFontSize"))
        #expect(source.contains("center.resetTypographyToDefaults()"))
        #expect(source.contains("默认 14 pt"))
    }

    @Test("设置页使用共享校验数字输入")
    func typographySettingsExposeDirectNumericInput() throws {
        let source = try settingsSource()

        #expect(source.contains("ValidatedNumericSettingField("))
        #expect(source.contains("\"输入字号\""))
        #expect(source.contains("settings.typography.base-font-size.input"))
        #expect(source.contains("let range = TypographySettings.uiBaseFontSizeRange"))
        #expect(source.contains("in: range"))
        #expect(source.contains("step: TypographySettings.uiBaseFontSizeStep"))
        #expect(source.contains("settings.typography.reset"))
        #expect(source.contains("settings.agent.max-loop-iterations"))
        #expect(source.contains("settings.storage.memory-limit"))
        #expect(source.contains("settings.browser.viewport-width"))
        #expect(source.contains("settings.browser.viewport-height"))
    }

    @Test("设置页展示 PolicyRuntime 的只读有效边界")
    func policyRuntimeBoundaryProjectionIsVisible() throws {
        let source = try settingsSource()

        #expect(source.contains("Section(\"运行安全上限\")"))
        #expect(source.contains("center.policyRuntimeDefaults.budget"))
        #expect(source.contains("center.policyRuntimeDefaults.deadlineHorizon"))
        #expect(source.contains("center.policyRuntimeDefaults.autonomyLevel"))
        #expect(source.contains("center.policyRuntimeDefaults.networkDomains"))
        #expect(source.contains("Composer 只能选择请求策略，不能放宽"))
    }

    @Test("设置持久化失败有安全可访问投影")
    func settingsPersistenceErrorProjectionSelectorsAndSafeCopy() throws {
        let source = try settingsSource()

        #expect(source.contains("SettingsPersistenceErrorBanner(error: error)"))
        #expect(source.contains("settings.persistence.error"))
        #expect(source.contains("settings.persistence.error.message"))
        #expect(source.contains("settings.persistence.error.dismiss"))
        #expect(source.contains("设置保存失败，当前设置未改变；请重试。"))
        #expect(source.contains("设置保存失败，无法创建设置目录；请检查磁盘权限后重试。"))
        #expect(source.contains("设置保存失败，当前设置未改变；请检查磁盘权限后重试。"))
    }

    @Test("设置持久化错误关闭仅隐藏且成功后清除")
    func settingsPersistenceDismissAndLayeringContract() throws {
        let source = try settingsSource()

        #expect(source.contains("@State private var dismissedPersistenceError: SettingsPersistenceError?"))
        #expect(source.contains("dismissedPersistenceError = error"))
        #expect(source.contains("if error == nil"))
        #expect(source.contains("dismissedPersistenceError = nil"))
        #expect(source.contains("VStack(spacing: 0)"))
        #expect(source.contains("if let error = center.lastPersistenceError"))
        #expect(!source.contains("center.lastPersistenceError = nil"))
    }

    @Test("技能切换失败有安全可访问投影")
    func skillToggleErrorProjectionSelectorsAndSafeCopy() throws {
        let source = try settingsSource()
        let skillsSource = try skillsStoreSource()

        #expect(source.contains("store.lastErrorMessage"))
        #expect(source.contains("settings.skills.toggle-error"))
        #expect(source.contains("settings.skills.toggle-error.message"))
        #expect(source.contains("settings.skills.toggle-error.dismiss"))
        #expect(skillsSource.contains("技能不存在，请刷新后重试。"))
        #expect(skillsSource.contains("运行时拒绝了这项更改，技能状态未改变。"))
        #expect(skillsSource.contains("技能状态保存失败，当前状态未改变；请检查磁盘权限后重试。"))
        #expect(skillsSource.contains("技能状态未能安全回滚，请重启应用后重试。"))
    }

    @Test("技能切换失败保持状态且使用稳定控件标识")
    func skillToggleDismissAndStableToggleContract() throws {
        let source = try settingsSource()

        #expect(source.contains("@State private var dismissedErrorMessage: String?"))
        #expect(source.contains("dismissedErrorMessage = message"))
        #expect(source.contains("dismissedErrorMessage = nil"))
        #expect(source.contains("dismissedErrorMessage = nil\n                        _ = store.setEnabled(entry.id, enabled: $0)"))
        #expect(source.contains("settings.skills.toggle.\\(entry.id)"))
        #expect(source.contains("accessibilityLabel(\"启用技能 \\(entry.name)\")"))
    }
}
