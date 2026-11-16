import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-COMPOSER-12 attachment preparation session switch", .serialized)
@MainActor
struct ComposerAttachmentPreflightSwitch1405Tests {
    @Test("unknown video reference send shows cancellation in B and preserves A draft")
    func unknownVideoReferenceSendSwitchShowsUnsentDraft() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ComposerAttachmentSwitch1405",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager()
        )
        defer { chat.stopAllStreamingForSafety() }
        let aID = try #require(chat.activeSessionID)
        let bID = chat.applyNewSession(title: "B1405")
        #expect(chat.applySwitchSession(id: aID))

        let unknownVideo = profile.rootDirectory.appendingPathComponent("synthetic-video.bin")
        try Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32]).write(to: unknownVideo)
        let staged = try #require(chat.addAttachments(urls: [unknownVideo]).first)
        #expect(staged.fileType == .unknown)
        chat.draftText = "ORIGINAL_A_UNSENT_ATTACHMENT_1405"
        chat.submitComposer()
        #expect(chat.isComposerAttachmentPreflightPending,
                "the real submit boundary must await the original unknown-file worker")
        #expect(chat.applySwitchSession(id: bID))
        #expect(chat.pastedTextActionFeedback?.contains("上一会话的附件请求未发送") == true)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.messages.isEmpty)

        let deadline = ContinuousClock.now + .seconds(5)
        while chat.isComposerAttachmentPreflightPending && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!chat.isComposerAttachmentPreflightPending)
        #expect(chat.messages.isEmpty)
        #expect(chat.applySwitchSession(id: aID))
        #expect(chat.pastedTextActionFeedback?.contains("附件请求未发送") == true)
        #expect(chat.draftText == "ORIGINAL_A_UNSENT_ATTACHMENT_1405")
        #expect(chat.pendingAttachments.first?.id == staged.id)
        #expect(chat.messages.allSatisfy { $0.role != .user })
    }
}
