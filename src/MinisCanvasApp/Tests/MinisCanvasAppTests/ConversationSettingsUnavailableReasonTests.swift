import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Conversation settings unavailable reason")
struct ConversationSettingsUnavailableReasonTests {
    private let all: [ConversationSettingsUnavailableReason] = [
        .toolCatalogInvalid, .ownerReleased, .settingsSnapshotUnavailable,
        .shortcutSnapshotFailed, .sidebarSnapshotFailed, .memoryScopeMismatch,
        .memoryScopeInvalid, .mcpSnapshotUnavailable, .mcpRevisionUnavailable,
        .skillsProjectionMismatch, .schedulerSnapshotFailed, .sidebarRowConflict,
        .safetyRowConflict, .shortcutRowInvalid, .memoryRowInvalid, .mcpRowInvalid,
        .sessionRowConflict, .skillsRowInvalid, .schedulerRowInvalid,
        .extraRowConflict, .providerRowInvalid
    ]

    @Test("different reasons give different errors and different user text")
    func reasonsAreDistinguishable() {
        let snapshot = ConversationSettingsToolError.unavailable(.settingsSnapshotUnavailable)
        let mcp = ConversationSettingsToolError.unavailable(.mcpSnapshotUnavailable)
        #expect(snapshot != mcp)
        #expect(snapshot == .ownerUnavailable(.settingsSnapshotUnavailable))
        #expect(snapshot.errorDescription != mcp.errorDescription)
        #expect(snapshot.errorDescription?.hasPrefix("设置暂时不可读：") == true)
        #expect(mcp.errorDescription?.hasPrefix("设置暂时不可读：") == true)
        #expect(snapshot.errorDescription?.contains("设置所有者不可用") == false)
    }

    @Test("every reason has a unique log code and unique non-empty user text")
    func codesAndTextsAreUnique() {
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(Set(all.map(\.userMessage)).count == all.count)
        #expect(all.allSatisfy { !$0.userMessage.isEmpty && !$0.rawValue.isEmpty })
    }

    @Test("other error cases keep their original text")
    func otherCasesUnchanged() {
        #expect(ConversationSettingsToolError.approvalRequired.errorDescription == "此设置改动需要先经用户批准。")
        #expect(ConversationSettingsToolError.invalidInput.errorDescription == "设置请求参数无效。")
    }
}
