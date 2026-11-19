import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Chat error guidance 3300", .serialized)
@MainActor
struct ChatErrorGuidance3300Tests {
    @Test("execution validation failures split into retry, reauthorize, uncertain and changed")
    func executionValidationClasses() {
        let busy = ChatStore.userErrorMessage(ProjectSessionAppError.busy)
        #expect(busy.contains("请稍后重试") && busy.hasSuffix("（PROJECT:busy）。"))
        let grant = ChatStore.userErrorMessage(ProjectSessionAppError.grantChanged)
        #expect(grant.contains("重新确认授权") && grant.hasSuffix("（PROJECT:grantChanged）。"))
        for error: any Error in [ProjectSessionAppError.persistenceUncertain,
                                  ChatStore.ScheduledSubmissionError.duplicateEffect,
                                  ChatStore.ScheduledSubmissionError.effectUncertain] {
            let text = ChatStore.userErrorMessage(error)
            #expect(text.contains("可能已经执行") && text.contains("不要直接重发"), "\(error)")
            #expect(!text.hasPrefix("执行校验"), "internal code must not lead the sentence")
        }
        let changed = ChatStore.userErrorMessage(AgentLoopChatEngine.ContextManifestConsumptionError.modelMismatch)
        #expect(changed.contains("重新发起") && changed.hasSuffix("（CHAT-CONTEXT:modelMismatch）。"))
    }

    @Test("unknown errors are split by domain into permission, configuration, storage and internal")
    func unknownErrorCategories() {
        let perm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let storage = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let config = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        let other = NSError(domain: "Synthetic", code: 1)
        #expect(ChatStore.userErrorMessage(perm).contains("没有权限") && ChatStore.userErrorMessage(perm).contains("CHAT-UNKNOWN:permission"))
        #expect(ChatStore.userErrorMessage(storage).contains("本地存储") && ChatStore.userErrorMessage(storage).contains("CHAT-UNKNOWN:storage"))
        #expect(ChatStore.userErrorMessage(config).contains("配置") && ChatStore.userErrorMessage(config).contains("CHAT-UNKNOWN:configuration"))
        #expect(ChatStore.userErrorMessage(other).contains("CHAT-UNKNOWN:internal"))
    }

    @Test("MCP discovery notices differ by cause and keep the authorization copy")
    func mcpNotices() {
        let all: [AgentToolCatalogDiscoveryFailure] = [.authorization, .configuration, .collision, .protocolError, .timeout, .transport, .unknown]
        let texts = all.map { ChatStore.mcpDiscoveryNotice(for: $0) }
        #expect(Set(texts).count == all.count)
        #expect(ChatStore.mcpDiscoveryNotice(for: .authorization) == "MCP 工具未授权，已继续使用内置工具。请在设置中授权后重试。")
        #expect(ChatStore.mcpDiscoveryNotice(for: .protocolError).contains("参数格式不受支持"))
        #expect(ChatStore.mcpDiscoveryNotice(for: .timeout).contains("超时"))
    }

    private func ceilingStore() -> ChatStore {
        let store = ChatStore()
        store.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: store.composerWorkspaceID, revision: "synthetic-ceiling",
            leaseID: "synthetic-ceiling", expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l1))
        return store
    }

    @Test("ceiling confirmation says which approvals are revoked and a failed save is reported as such")
    func ceilingConfirmationAndSaveFailure() async throws {
        let store = ceilingStore()
        let owner = UUID()
        store.selectInteractiveComposerMode(.auto, owner: owner)
        let request = try #require(store.composerCeilingRequest)
        #expect(request.confirmationText.contains("本会话内允许"))
        #expect(request.confirmationText.contains("撤销"))
        var revoked = 0
        store.onSessionPermissionContextChanged = { revoked += 1 }
        store.persistComposerCeiling = { _, _ in false }
        #expect(await store.confirmComposerCeilingRequest(owner: owner) == false)
        #expect(revoked == 1)
        #expect(store.composerBypassDisabledFeedback?.contains("保存失败") == true)
        #expect(store.composerPolicySelection.mode == .manual)
    }
}
