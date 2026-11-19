import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 绕过「全面放开」的 App 侧：禁用绕过开关、设置回写不丢字段。
@Suite("Bypass open: disable switch and settings round trip")
@MainActor
struct BypassOpenSettingsTests {
    @Test("Composer selection write-back keeps the settings-page fields")
    func selectionWriteBackPreservesSettingsOnlyFields() {
        let stored = ComposerPolicySettings(
            mode: .manual, approvalScope: .session, disableBypass: true, protectCredentialPaths: false)
        let selection = ComposerPolicySelection(
            mode: .auto, approvalScope: .request, effort: .high, bypassModeConfirmed: false)
        let merged = selection.settings(preserving: stored)
        #expect(merged.mode == .auto)
        #expect(merged.approvalScope == .session)
        #expect(merged.effort == .high)
        #expect(merged.disableBypass)
        #expect(!merged.protectCredentialPaths)
        #expect(ComposerPolicySelection(stored).approvalScope == .request)
        var staleSelection = selection
        staleSelection.approvalScope = .session
        #expect(staleSelection.settings(preserving: .default).approvalScope == .request)
        // 不带 base 的旧入口给出安全默认。
        #expect(selection.settings.disableBypass == false)
        #expect(selection.settings.protectCredentialPaths == true)
    }

    @Test("disable-bypass drops an already selected bypass back to manual and says so")
    func disableBypassFallsBackToManual() {
        let chat = ChatStore()
        chat.restoreComposerPolicy(ComposerPolicySettings(
            mode: .bypassPermission, approvalScope: .workspace, effort: .high, bypassModeConfirmed: true))
        #expect(chat.composerPolicySelection.mode == .bypassPermission)
        #expect(!chat.composerBypassDisabled)

        chat.restoreComposerPolicy(ComposerPolicySettings(
            mode: .bypassPermission, approvalScope: .workspace, effort: .high,
            bypassModeConfirmed: true, disableBypass: true))
        #expect(chat.composerBypassDisabled)
        #expect(chat.composerPolicySelection.mode == .manual)
        #expect(!chat.composerPolicySelection.bypassModeConfirmed)
        #expect(chat.composerBypassDisabledFeedback != nil)

        // 禁用期间手动选回绕过同样被回落。
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.composerPolicySelection.mode == .manual)

        // 关闭禁用后提示清除，绕过可再次选择。
        chat.restoreComposerPolicy(ComposerPolicySettings(mode: .manual))
        #expect(!chat.composerBypassDisabled)
        #expect(chat.composerBypassDisabledFeedback == nil)
        chat.composerPolicySelection.mode = .bypassPermission
        #expect(chat.composerPolicySelection.mode == .bypassPermission)
    }

    @Test("unconfirmed bypass is treated as manual approval until confirmed")
    func unconfirmedBypassFallsBackToManualApproval() {
        let chat = ChatStore()
        chat.restoreComposerPolicy(ComposerPolicySettings(
            mode: .bypassPermission, approvalScope: .workspace, effort: .high, bypassModeConfirmed: false))
        // 选择本身保留（用户还能去确认），但提交按手动审批处理并给出提示标志。
        #expect(chat.composerPolicySelection.mode == .bypassPermission)
        #expect(chat.composerBypassUnconfirmedFallbackActive)
        #expect(chat.effectiveComposerSelection.mode == .manual)
        // 确认后提示消失、提交快照仍是绕过，行为不变。
        chat.composerPolicySelection.bypassModeConfirmed = true
        #expect(!chat.composerBypassUnconfirmedFallbackActive)
        #expect(chat.effectiveComposerSelection.mode == .bypassPermission)
        #expect(chat.effectiveComposerSelection.bypassModeConfirmed)
    }
}
