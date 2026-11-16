import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Pending attachment preview keeps its draft and session origin")
struct PendingAttachmentPreviewTests {
    @Test("only a ready attachment still in the source session can preview")
    func previewEligibility() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("body.txt")
        try Data("four lines\nfrom a\ntest-only\nfixture\n".utf8).write(to: fixture)

        let sourceSessionID = UUID()
        let ready = ChatAttachment(
            kind: .text, fileName: "body.txt", fileType: .text,
            fileURL: fixture.path, status: .ready
        )
        let pending = ChatAttachment(
            kind: .text, fileName: "body.txt", fileType: .text,
            fileURL: fixture.path, status: .pending
        )
        let failed = ChatAttachment(
            kind: .text, fileName: "body.txt", fileType: .text,
            fileURL: fixture.path, status: .failed
        )
        func canPreview(_ attachment: ChatAttachment, activeSessionID: UUID?,
                        pendingAttachments: [ChatAttachment]) -> Bool {
            GlobalComposer.canPreviewPendingAttachment(
                attachment,
                expectedSessionID: sourceSessionID,
                activeSessionID: activeSessionID,
                pendingAttachments: pendingAttachments
            )
        }

        #expect(canPreview(ready, activeSessionID: sourceSessionID, pendingAttachments: [ready]))
        #expect(!canPreview(pending, activeSessionID: sourceSessionID, pendingAttachments: [pending]))
        #expect(!canPreview(failed, activeSessionID: sourceSessionID, pendingAttachments: [failed]))
        #expect(!canPreview(ready, activeSessionID: sourceSessionID, pendingAttachments: []))
        #expect(!canPreview(ready, activeSessionID: UUID(), pendingAttachments: [ready]))
        #expect(!canPreview(ready, activeSessionID: nil, pendingAttachments: [ready]))

        let missing = ChatAttachment(
            kind: .text, fileName: "missing.txt", fileType: .text,
            fileURL: root.appendingPathComponent("missing.txt").path, status: .ready
        )
        #expect(!canPreview(missing, activeSessionID: sourceSessionID, pendingAttachments: [missing]))
    }

    @Test("removal retires only its own request; same-URL new request stays")
    func removalAndRequestIdentity() {
        let sessionID = UUID()
        let url = URL(fileURLWithPath: "/test-only/body.txt")
        let pendingSelection = ChatAttachmentPreviewSelection(sessionID: sessionID, url: url)
        let request = PendingAttachmentPreviewRequest(
            attachmentID: UUID(), requestID: pendingSelection.requestID
        )
        #expect(PendingAttachmentPreviewLifecycle.selectionAfterRemoval(
            pendingSelection, removedRequest: request
        ) == nil)

        let newerSelection = ChatAttachmentPreviewSelection(sessionID: sessionID, url: url)
        #expect(newerSelection.requestID != pendingSelection.requestID)
        #expect(PendingAttachmentPreviewLifecycle.selectionAfterRemoval(
            newerSelection, removedRequest: request
        ) == newerSelection)
        #expect(pendingSelection.visible(in: UUID()) == nil)
        #expect(newerSelection.visible(in: sessionID) == newerSelection)
    }
}
