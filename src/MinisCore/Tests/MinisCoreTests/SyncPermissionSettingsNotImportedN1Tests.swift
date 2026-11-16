import Foundation
import Testing
@testable import MinisCore

/// N1：.minissync 导入不得带入权限与安全边界相关设置，本机现值保持不变；
/// 其余设置照常导入。合成包由“源机”导出，目标机预先持有不同的权限值。
@Suite("N1 sync import keeps local permission settings", .serialized)
struct SyncPermissionSettingsNotImportedN1Tests {
    private struct Machine {
        let root: URL
        let manager: SyncManager
        var directory: URL { root.appendingPathComponent("core", isDirectory: true) }
        init(_ label: String) {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("N1-\(label)-\(UUID().uuidString)", isDirectory: true)
            let chat = root.appendingPathComponent("chat", isDirectory: true)
            let core = root.appendingPathComponent("core", isDirectory: true)
            manager = SyncManager(
                sessionStore: SessionStore(directory: chat), memoryStore: MemoryStore(directory: chat),
                skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
                settingsStore: SettingsStore(directory: core))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// 源机：所有权限与安全相关字段都取与默认相反或更宽松的值。
    private static func permissiveSource() -> (Machine, Data) {
        let source = Machine("source")
        let s = source.manager.settingsStore
        s.update(\.agent.composerPolicy, to: ComposerPolicySettings(
            mode: .bypassPermission, approvalScope: .session, effort: .high,
            bypassModeConfirmed: true, disableBypass: true, protectCredentialPaths: false))
        s.update(\.agent.approvalPolicy, to: .riskOnlyAsk)
        s.update(\.agent) {
            $0.legacyApprovalPolicyOriginal = .autoApprove
            $0.legacyAutomaticApprovalCompatibilityActive = true
            $0.legacyApprovalPolicyNoticePending = false
            $0.legacyApprovalScopeNoticePending = true
        }
        s.update(\.agent.policyRuntimeDefaults, to: ProductionPolicyDefaults(
            budget: 999_999, deadlineHorizon: 99 * 3600, autonomyLevel: .l3, networkDomains: ["evil.example"]))
        s.update(\.agent.terminalPolicy, to: TerminalPolicySettings(
            automaticAllowCommands: ["rm"], confirmationCommands: [], userDeniedCommands: [],
            explicitConfirmationCommands: [], confirmationProvenanceVersion: 1))
        s.update(\.agent.childMutationsEnabled, to: !AgentSettings.default.childMutationsEnabled)
        s.update(\.agent.childMutationsExplicitlySelected, to: !AgentSettings.default.childMutationsExplicitlySelected)
        s.update(\.agent.childModelOverridesEnabled, to: !AgentSettings.default.childModelOverridesEnabled)
        s.update(\.agent.childDeletionAutoReviewWhitelist, to: ["/usr/local/n1-source"])
        s.update(\.agent.stripModelShellCredentials, to: !AgentSettings.default.stripModelShellCredentials)
        s.update(\.privacy.allowedRootPath, to: "/n1/source-root")
        s.update(\.privacy.deniedRootPaths, to: ["/n1/source-denied"])
        s.update(\.privacy.mountedFolderPaths, to: ["/n1/source-mount"])
        s.update(\.privacy.redactEnvValues, to: !PrivacySettings.default.redactEnvValues)
        s.update(\.privacy.collectAnalytics, to: !PrivacySettings.default.collectAnalytics)
        // 非权限字段：应照常导入。
        s.update(\.agent.toolTimeoutSeconds, to: 41)
        s.update(\.storage.sessionRetentionDays, to: 77)
        s.update(\.general.language, to: "en")
        return (source, try! source.manager.exportSnapshot(scopes: [.settings]))
    }

    /// 目标机：权限字段为与源机不同的本机值（绕过关、逐次询问、自主权 l0 等）。
    private static func restrictiveTarget() -> Machine {
        let target = Machine("target")
        let s = target.manager.settingsStore
        s.update(\.agent.composerPolicy, to: ComposerPolicySettings(
            mode: .manual, approvalScope: .request, effort: .standard,
            bypassModeConfirmed: false, disableBypass: false, protectCredentialPaths: true))
        s.update(\.agent.approvalPolicy, to: .alwaysAsk)
        s.update(\.agent) {
            $0.legacyApprovalPolicyOriginal = .autoApprove
            $0.legacyApprovalPolicyNoticePending = true
        }
        s.update(\.agent.policyRuntimeDefaults, to: ProductionPolicyDefaults(
            budget: 1_000, deadlineHorizon: 3600, autonomyLevel: .l0, networkDomains: []))
        s.update(\.agent.terminalPolicy, to: TerminalPolicySettings.default)
        s.update(\.agent.childMutationsEnabled, to: AgentSettings.default.childMutationsEnabled)
        s.update(\.agent.childMutationsExplicitlySelected, to: AgentSettings.default.childMutationsExplicitlySelected)
        s.update(\.agent.childModelOverridesEnabled, to: AgentSettings.default.childModelOverridesEnabled)
        s.update(\.agent.childDeletionAutoReviewWhitelist, to: ["/usr/local/n1-target"])
        s.update(\.agent.stripModelShellCredentials, to: AgentSettings.default.stripModelShellCredentials)
        s.update(\.privacy.allowedRootPath, to: "/n1/target-root")
        s.update(\.privacy.deniedRootPaths, to: ["/n1/target-denied"])
        s.update(\.privacy.mountedFolderPaths, to: [])
        s.update(\.privacy.redactEnvValues, to: PrivacySettings.default.redactEnvValues)
        s.update(\.privacy.collectAnalytics, to: PrivacySettings.default.collectAnalytics)
        return target
    }

    private func expectPermissionsUnchanged(_ after: AppSettings, local before: AppSettings) {
        #expect(after.agent.composerPolicy == before.agent.composerPolicy)
        #expect(after.agent.composerPolicy.mode != .bypassPermission)
        #expect(!after.agent.composerPolicy.bypassModeConfirmed)
        #expect(after.agent.composerPolicy.protectCredentialPaths)
        #expect(after.agent.approvalPolicy == before.agent.approvalPolicy)
        #expect(after.agent.legacyAutomaticApprovalCompatibilityActive == before.agent.legacyAutomaticApprovalCompatibilityActive)
        #expect(after.agent.legacyApprovalPolicyOriginal == before.agent.legacyApprovalPolicyOriginal)
        #expect(after.agent.legacyApprovalPolicyNoticePending == before.agent.legacyApprovalPolicyNoticePending)
        #expect(after.agent.legacyApprovalScopeNoticePending == before.agent.legacyApprovalScopeNoticePending)
        #expect(after.agent.policyRuntimeDefaults == before.agent.policyRuntimeDefaults)
        #expect(after.agent.terminalPolicy == before.agent.terminalPolicy)
        #expect(after.agent.childMutationsEnabled == before.agent.childMutationsEnabled)
        #expect(after.agent.childMutationsExplicitlySelected == before.agent.childMutationsExplicitlySelected)
        #expect(after.agent.childModelOverridesEnabled == before.agent.childModelOverridesEnabled)
        #expect(after.agent.childDeletionAutoReviewEnabled == before.agent.childDeletionAutoReviewEnabled)
        #expect(after.agent.childDeletionAutoReviewWhitelist == before.agent.childDeletionAutoReviewWhitelist)
        #expect(after.agent.browserWriteEnabled == before.agent.browserWriteEnabled)
        #expect(after.agent.stripModelShellCredentials == before.agent.stripModelShellCredentials)
        #expect(after.privacy.allowedRootPath == before.privacy.allowedRootPath)
        #expect(after.privacy.fileRootPolicyVersion == before.privacy.fileRootPolicyVersion)
        #expect(after.privacy.deniedRootPaths == before.privacy.deniedRootPaths)
        #expect(after.privacy.mountedFolderPaths == before.privacy.mountedFolderPaths)
        #expect(after.privacy.redactEnvValues == before.privacy.redactEnvValues)
        #expect(after.privacy.collectAnalytics == before.privacy.collectAnalytics)
    }

    private func expectOrdinaryImported(_ after: AppSettings) {
        #expect(after.agent.toolTimeoutSeconds == 41)
        #expect(after.storage.sessionRetentionDays == 77)
        #expect(after.general.language == "en")
    }

    @Test func directImportKeepsLocalPermissionSettings() throws {
        let (source, data) = Self.permissiveSource(); defer { source.remove() }
        // 前提：合成包里确实带着宽松权限值（否则测试无意义）。
        let exported = source.manager.settingsStore.settings
        #expect(exported.agent.composerPolicy.mode == .bypassPermission)
        let target = Self.restrictiveTarget(); defer { target.remove() }
        let before = target.manager.settingsStore.settings
        #expect(before.agent.composerPolicy != exported.agent.composerPolicy)
        let result = try target.manager.importSnapshot(data)
        #expect(result.allSucceeded)
        let after = target.manager.settingsStore.settings
        expectPermissionsUnchanged(after, local: before)
        expectOrdinaryImported(after)
    }

    @Test func atomicImportKeepsLocalPermissionSettingsOnDisk() throws {
        let (source, data) = Self.permissiveSource(); defer { source.remove() }
        let target = Self.restrictiveTarget(); defer { target.remove() }
        let before = target.manager.settingsStore.settings
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(data, selecting: [.settings])
        #expect(try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)).committed)
        // 直接解码磁盘上的 settings.json。提交后 SettingsStore.settings 在重开前会返回
        // fence 捕获的“导入前”视图（SettingsStore.swift:142-148），任何 store 实例都不能用来读回。
        let onDisk = try Data(contentsOf: target.directory.appendingPathComponent(SettingsStore.fileName))
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: onDisk)
        expectPermissionsUnchanged(reloaded, local: before)
        expectOrdinaryImported(reloaded)
    }

    @Test func importIntoEmptyTargetUsesDefaultPermissionsNotPackageValues() throws {
        let (source, data) = Self.permissiveSource(); defer { source.remove() }
        let target = Machine("empty-target"); defer { target.remove() }
        let before = target.manager.settingsStore.settings
        _ = try target.manager.importSnapshot(data)
        expectPermissionsUnchanged(target.manager.settingsStore.settings, local: before)
    }
}
