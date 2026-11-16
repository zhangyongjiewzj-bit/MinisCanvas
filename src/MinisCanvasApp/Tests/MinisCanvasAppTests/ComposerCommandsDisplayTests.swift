import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-03 注册表命令展示")
@MainActor
struct ComposerCommandsDisplayTests {
    private func makeChat() -> ChatStore {
        let defaults = UserDefaults(suiteName: "commands-display-\(UUID().uuidString)")!
        return ChatStore(preferencesDefaults: defaults)
    }

    private func facts(workspaceID: String) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: "commands-101",
            grantEpoch: "epoch-101",
            leaseID: "lease-101",
            expiresAt: Date().addingTimeInterval(600),
            revoked: false
        )
    }

    private func snapshot(workspaceID: String) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "session-101",
            turnID: 1,
            taskID: "chat:session-101:1:attempt",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: "commands-101",
            grantEpoch: "epoch-101"
        )
    }

    private func wiredChat() -> (ChatStore, ComposerCommandAdjudicationCenter) {
        let chat = makeChat()
        let center = ComposerCommandAdjudicationCenter()
        chat.configureComposerPolicy(facts(workspaceID: chat.composerWorkspaceID))
        chat.onComposerCommandPolicy = { request, submission in
            center.evaluate(request: request, snapshot: submission, facts: chat.composerPolicyFacts)
        }
        return (chat, center)
    }

    @Test func commandsProjectsTheLiveRegistryWithoutAUserTurn() {
        let (chat, center) = wiredChat()
        let transcriptBefore = chat.messages
        let registered = CommandRegistry.shared.allCommands()
            .filter { CommandRegistry.composerCommandIDs.contains($0.id) }
        #expect(!registered.isEmpty)

        chat.draftText = "/commands"
        chat.submitComposer()

        #expect(chat.lastComposerCommandReceipt?.commandID == "commands")
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.messages == transcriptBefore)
        let projection = center.projection?.text ?? ""
        #expect(projection.contains("来自当前注册表"))
        #expect(!projection.contains("尚无专属结果视图"))
        for command in registered {
            #expect(projection.contains("/\(command.id) · \(command.title)"))
        }
    }

    @Test func categoryUsesRegisteredCommandsAndUnknownCategoryIsExplicit() {
        _ = makeChat() // 生产初始化会向同一 shared registry 注册 Composer 命令。
        let center = ComposerCommandAdjudicationCenter()
        let workspaceID = "ws-commands-101"
        let source = facts(workspaceID: workspaceID)
        let submission = snapshot(workspaceID: workspaceID)

        let categoryRequest = PendingCommandRequest(
            id: UUID(), commandID: "commands", args: ["category": "画布"],
            requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: categoryRequest, snapshot: submission, facts: source) == .execute)
        let canvas = center.projection?.text ?? ""
        #expect(canvas.contains("/canvas.run"))
        #expect(!canvas.contains("/provider"))

        let unknownRequest = PendingCommandRequest(
            id: UUID(), commandID: "commands", args: ["category": "not-a-category"],
            requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: unknownRequest, snapshot: submission, facts: source) == .execute)
        let unknown = center.projection?.text ?? ""
        #expect(unknown.contains("未知命令分类：not-a-category"))
        #expect(unknown.contains("可用分类"))
        #expect(!unknown.contains("/canvas.run"))
    }

    @Test func helpProjectionRemainsAvailable() {
        let (chat, center) = wiredChat()
        let transcriptBefore = chat.messages
        chat.draftText = "/help"
        chat.submitComposer()

        #expect(chat.lastComposerCommandReceipt?.commandID == "help")
        #expect(chat.messages == transcriptBefore)
        let expectation561_1 = (center.projection?.text ?? "").contains("/compact")
        #expect(expectation561_1)
    }
}
