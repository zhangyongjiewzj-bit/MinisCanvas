import SwiftUI
import AppKit

/// Display hints share the existing bounded thumbnail cache. They never
/// authorize opening: the click route still checks the current source.
@MainActor
struct AttachmentPreviewRenderView<Content: View>: View {
    let attachment: ChatAttachment
    var sessionID: UUID? = nil
    var requiresReady = true
    var isCurrent: @MainActor () -> Bool = { true }
    var sourceStateReader: @Sendable (ChatAttachment) -> ChatAttachmentSourceState = {
        ChatAttachmentOpenTarget.sourceState(for: $0)
    }
    @ViewBuilder let content: (NSImage?, ChatAttachmentSourceState?) -> Content

    @State private var publication = 0

    private struct Request: Equatable {
        let sessionID: UUID?
        let attachment: ChatAttachment
        let requiresReady: Bool
    }

    var body: some View {
        let _ = publication
        return content(
            AttachmentThumbnailer.cachedThumbnail(for: attachment),
            AttachmentThumbnailer.cachedSourceState(for: attachment)
        )
        .task(id: Request(sessionID: sessionID, attachment: attachment, requiresReady: requiresReady)) {
            // SwiftUI owns the task lifetime; changed snapshots, retired rows
            // and session changes cancel it without a second worker registry.
            // Each mount refreshes the source hint off-main; a restored file
            // must not stay disabled forever because of an older cached check.
            if await AttachmentThumbnailer.preparePreview(
                for: attachment, refreshSource: true, requiresReady: requiresReady,
                sourceStateReader: sourceStateReader, isCurrent: isCurrent
            ) {
                publication &+= 1
            }
        }
    }
}
