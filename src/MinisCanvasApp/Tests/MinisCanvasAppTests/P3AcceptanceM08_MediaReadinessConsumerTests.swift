import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-MULTIMODAL-04 Composer media readiness projection")
@MainActor
struct P3AcceptanceM08_MediaReadinessConsumerTests {
    @Test("global and companion projections use the same snapshot reason")
    func staleProjectionFailsClosedAndTracksSelection() {
        let attachment = ChatAttachment(
            kind: .image, fileName: "synthetic.png", fileType: .image,
            mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let snapshot = ComposerMediaReadinessSnapshot(
            providerID: "synthetic", modelID: "text-only", selectionRevision: "rev-1",
            attachments: [.init(
                attachmentID: attachment.id, mimeType: attachment.mimeType,
                wireMIMEType: "image/png", readiness: .unsupported,
                reason: "附件不可发送：所选模型不支持此附件的媒体输入；请更换模型或移除附件",
                decision: nil
            )]
        )
        let reason = ComposerAttachmentPresentation.mediaReadinessText(for: attachment, in: snapshot)
        #expect(reason == snapshot.attachment(id: attachment.id)?.reason)
        #expect(ComposerAttachmentPresentation.accessibilityValue(
            for: attachment, mediaReadiness: snapshot
        ).contains(reason))
        let stale = ComposerMediaReadinessSnapshot(
            providerID: "synthetic", modelID: "old", selectionRevision: "old", attachments: []
        )
        #expect(snapshot.selectionRevision != stale.selectionRevision)
        #expect(ComposerAttachmentPresentation.mediaReadinessText(for: attachment, in: stale)
            == "附件或模型已变化，请重新选择模型；仍无法发送时请移除附件后重试。")
    }
}
