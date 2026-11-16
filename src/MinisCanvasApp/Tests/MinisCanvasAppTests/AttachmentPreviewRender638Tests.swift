import Foundation
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Preview638FileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let hold: Bool
    private var reads: [Bool] = []
    private var didTimeout = false

    init(hold: Bool = false) { self.hold = hold; super.init() }
    var readThreads: [Bool] { lock.withLock { reads } }
    var timedOut: Bool { lock.withLock { didTimeout } }
    func release() { releaseSignal.signal() }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        lock.withLock { reads.append(Thread.isMainThread) }
        if hold, releaseSignal.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { didTimeout = true }
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}

@Suite("PERF638 real attachment chip rendering and live preview boundary", .serialized)
@MainActor
struct AttachmentPreviewRender638Tests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview638-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2048, height: 1024,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        let image = try #require(context.makeImage())
        let bytes = try #require(CFDataCreateMutable(nil, 0))
        let destination = try #require(CGImageDestinationCreateWithData(
            bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func waitForRead(_ fileManager: Preview638FileManager) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while fileManager.readThreads.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!fileManager.readThreads.isEmpty, "real background source check must enter")
    }

    @Test("prepared actual chip can relayout repeatedly without filesystem access; click still rechecks")
    func repeatedRenderAndLiveClick() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("present.txt")
        let bytes = Data("owned preview source".utf8)
        try bytes.write(to: url)
        let attachment = ChatAttachment(kind: .text, fileName: "present.txt", fileType: .text,
                                        data: nil, fileURL: url.path)
        let session = UUID()
        let fileManager = Preview638FileManager()
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == nil)
        var opened: [(ChatAttachment, UUID)] = []
        var unavailable: [(ChatAttachment, UUID)] = []
        let chip = ChatAttachmentOpenButton(attachment: attachment, onOpen: { _ in },
                                           sessionID: session, sourceStateReader: {
                                               ChatAttachmentOpenTarget.sourceState(for: $0, fileManager: fileManager)
                                           })
        let host = NSHostingView(rootView: chip)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        host.layoutSubtreeIfNeeded()
        // Observe the actual chip's own lazy task, not a second manual warmup.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while AttachmentThumbnailer.cachedSourceState(for: attachment) == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == .sourceAvailable)
        #expect(fileManager.readThreads == [false], "one real mount performs one off-main source read")
        for width in [180.0, 320.0, 240.0, 360.0, 200.0] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 48)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            #expect(GlobalComposer.canRenderPendingAttachmentPreview(attachment,
                expectedSessionID: session, activeSessionID: session, pendingAttachments: [attachment]))
            #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        }
        #expect(fileManager.readThreads == [false], "actual chip body must not check disk on relayout")
        GlobalComposer.previewPendingAttachment(attachment, expectedSessionID: session,
            activeSessionID: session, pendingAttachments: [attachment], fileManager: fileManager) {
                opened.append(($0, $1))
            }
        #expect(opened.count == 1 && opened.first?.0 == attachment && opened.first?.1 == session)
        let resolved = try ChatAttachmentOpenTarget(fileManager: fileManager).resolve(attachment)
        let resolvedBytes = try Data(contentsOf: resolved)
        #expect(resolved == url && resolvedBytes == bytes)

        // Only the owned fixture moves; the old display hint deliberately stays cached.
        let moved = directory.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == .sourceAvailable)
        GlobalComposer.previewPendingAttachment(attachment, expectedSessionID: session,
            activeSessionID: session, pendingAttachments: [attachment], fileManager: fileManager,
            onUnavailable: { unavailable.append(($0, $1)) }) {
                opened.append(($0, $1))
            }
        #expect(opened.count == 1, "stale available hint cannot authorize a missing source")
        #expect(unavailable.count == 1 && unavailable.first?.0 == attachment && unavailable.first?.1 == session)
        let unavailableState = ChatAttachmentOpenTarget.sourceState(for: attachment, fileManager: fileManager)
        #expect(unavailableState == .unavailable)
        #expect(unavailableState.statusText == "原文件缺失且没有可恢复数据")
        #expect(throws: ChatAttachmentOpenError.unavailable) {
            try ChatAttachmentOpenTarget(fileManager: fileManager, temporaryDirectory: directory).resolve(attachment)
        }
        #expect(fileManager.readThreads.dropFirst().allSatisfy { $0 })
        #expect(try Data(contentsOf: moved) == bytes)

        let unsafe = ChatAttachment(kind: .file, fileName: "directory", fileType: .unknown,
                                    fileURL: directory.path)
        GlobalComposer.previewPendingAttachment(unsafe, expectedSessionID: session,
            activeSessionID: session, pendingAttachments: [unsafe], fileManager: fileManager) {
                opened.append(($0, $1))
            }
        #expect(opened.count == 1, "directory cannot pass the existing regular-file boundary")
        let readsBeforeRejectedOrigins = fileManager.readThreads.count
        GlobalComposer.previewPendingAttachment(attachment, expectedSessionID: session,
            activeSessionID: UUID(), pendingAttachments: [attachment], fileManager: fileManager,
            onUnavailable: { unavailable.append(($0, $1)) }) {
                opened.append(($0, $1))
            }
        #expect(opened.count == 1)
        GlobalComposer.previewPendingAttachment(attachment, expectedSessionID: session,
            activeSessionID: session, pendingAttachments: [], fileManager: fileManager,
            onUnavailable: { unavailable.append(($0, $1)) }) { opened.append(($0, $1)) }
        for status in [ChatAttachment.Status.pending, .failed] {
            let nonready = ChatAttachment(kind: .text, fileName: "missing.txt", fileType: .text,
                fileURL: url.path, status: status)
            GlobalComposer.previewPendingAttachment(nonready, expectedSessionID: session,
                activeSessionID: session, pendingAttachments: [nonready], fileManager: fileManager,
                onUnavailable: { unavailable.append(($0, $1)) }) { opened.append(($0, $1)) }
        }
        #expect(opened.count == 1 && unavailable.count == 1)
        #expect(fileManager.readThreads.count == readsBeforeRejectedOrigins)
        let cached = ChatAttachment(kind: .text, fileName: "cached.txt", fileType: .text,
            data: Data("owned cached preview".utf8), fileURL: url.path)
        var recovered: [ChatAttachment] = []
        GlobalComposer.previewPendingAttachment(cached, expectedSessionID: session,
            activeSessionID: session, pendingAttachments: [cached], fileManager: fileManager,
            onUnavailable: { unavailable.append(($0, $1)) }) { value, owner in
                #expect(owner == session)
                recovered.append(value)
            }
        #expect(recovered == [cached] && unavailable.count == 1)
        let restoredURL = try ChatAttachmentOpenTarget(fileManager: fileManager, temporaryDirectory: directory).resolve(cached)
        #expect(try Data(contentsOf: restoredURL) == cached.data)
    }

    @Test("a new visible load refreshes a missing-source hint after the owned file is restored")
    func restoredSourceRefresh() async throws {
        let directory = try root()
        let url = directory.appendingPathComponent("restored.txt")
        let attachment = ChatAttachment(kind: .text, fileName: "restored.txt", fileType: .text, fileURL: url.path)
        let fileManager = Preview638FileManager()
        let read: @Sendable (ChatAttachment) -> ChatAttachmentSourceState = {
            ChatAttachmentOpenTarget.sourceState(for: $0, fileManager: fileManager)
        }
        let missingPublished = await AttachmentThumbnailer.preparePreview(for: attachment, sourceStateReader: read)
        #expect(missingPublished && AttachmentThumbnailer.cachedSourceState(for: attachment) == .unavailable)
        let bytes = Data("owned restored source".utf8)
        try bytes.write(to: url)
        let restoredPublished = await AttachmentThumbnailer.preparePreview(
            for: attachment, refreshSource: true, sourceStateReader: read)
        #expect(restoredPublished && AttachmentThumbnailer.cachedSourceState(for: attachment) == .sourceAvailable)
        #expect(fileManager.readThreads == [false, false])
        #expect(try Data(contentsOf: ChatAttachmentOpenTarget().resolve(attachment)) == bytes)
    }

    @Test("lazy preparation preserves bounded valid decoding and full-value cache identity")
    func lazyMediaAndSnapshotIdentity() async throws {
        let bytes = try png()
        let attachment = ChatAttachment(kind: .image, fileName: "owned.png", fileType: .image,
                                        mimeType: "image/png", data: bytes)
        #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        let published = await AttachmentThumbnailer.preparePreview(for: attachment)
        #expect(published)
        let first = try #require(AttachmentThumbnailer.cachedThumbnail(for: attachment))
        var proposed = NSRect.zero
        let image = try #require(first.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        #expect(image.width == 1024 && image.height == 512)
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == .missingSourceMaterializable)
        let again = await AttachmentThumbnailer.preparePreview(for: attachment)
        #expect(!again && AttachmentThumbnailer.cachedThumbnail(for: attachment) === first)
        let changed = ChatAttachment(id: attachment.id, kind: .image, fileName: "owned.png",
            fileType: .image, mimeType: "image/png", data: Data("not an image".utf8))
        #expect(AttachmentThumbnailer.cachedThumbnail(for: changed) == nil)
        #expect(AttachmentThumbnailer.cachedSourceState(for: changed) == nil)
        let changedPublished = await AttachmentThumbnailer.preparePreview(for: changed)
        #expect(changedPublished && AttachmentThumbnailer.cachedThumbnail(for: changed) == nil)
        #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        #expect(attachment.data == bytes && changed.data == Data("not an image".utf8))
    }

    @Test("unsupported kind and corrupt images keep icon fallback without inventing media success",
          arguments: [ChatAttachment.Kind.file, .image])
    func nonDecodableMedia(kind: ChatAttachment.Kind) async throws {
        let attachment = ChatAttachment(kind: kind, fileName: "owned.bin", fileType: .unknown,
                                        data: Data("owned nonimage bytes".utf8))
        let published = await AttachmentThumbnailer.preparePreview(for: attachment)
        #expect(published && AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == .missingSourceMaterializable)
        #expect(attachment.status == .ready && attachment.fileType == .unknown)
    }

    @Test("retired visible-row worker cannot publish after actual draft removal/edit/session change",
          arguments: ["cancel", "remove", "edit", "session", "slotABA"])
    func retiredPreparation(action: String) async throws {
        let directory = try root()
        let url = directory.appendingPathComponent("owned.txt")
        try Data("owned source".utf8).write(to: url)
        let defaults = try #require(UserDefaults(suiteName: "preview638-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: directory.appendingPathComponent("logs")))
        let attachment = ChatAttachment(kind: .text, fileName: "owned.txt", fileType: .text, fileURL: url.path)
        let message = ChatMessageUI(role: .user, content: "owned edit source", attachments: [attachment])
        chat.messages = [message]
        chat.beginEdit(messageID: message.id)
        let session = try #require(chat.activeSessionID)
        #expect(chat.pendingAttachments == [attachment])
        let fileManager = Preview638FileManager(hold: true)
        let task = Task { @MainActor in
            await AttachmentThumbnailer.preparePreview(for: attachment, sourceStateReader: {
            ChatAttachmentOpenTarget.sourceState(for: $0, fileManager: fileManager)
        }) {
                chat.activeSessionID == session && chat.pendingAttachments.contains(attachment)
            }
        }
        defer { fileManager.release() }
        try await waitForRead(fileManager)
        #expect(fileManager.readThreads == [false])
        // Reaching here on MainActor while the real source read is held is
        // the responsiveness witness; no asynchronous hop fakes thread evidence.
        switch action {
        case "cancel": task.cancel()
        case "remove": chat.removePendingAttachment(id: attachment.id)
        case "edit":
            let changed = ChatAttachment(id: attachment.id, kind: .text, fileName: "changed.txt",
                fileType: .text, data: Data("changed bytes".utf8), fileURL: url.path)
            let newer = ChatMessageUI(role: .user, content: "owned changed source", attachments: [changed])
            chat.messages.append(newer)
            chat.beginEdit(messageID: newer.id)
        case "session": chat.newSession()
        case "slotABA":
            chat.removePendingAttachment(id: attachment.id)
            // SwiftUI's changed row/request lifetime cancels the old task;
            // restore the exact same value to prove cancellation also fences ABA.
            task.cancel()
            chat.beginEdit(messageID: message.id)
        default: Issue.record("unknown owned action")
        }
        fileManager.release()
        let published = await task.value
        #expect(!published && !fileManager.timedOut)
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == nil)
        #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        if action == "slotABA" {
            #expect(chat.pendingAttachments == [attachment])
            let freshPublished = await AttachmentThumbnailer.preparePreview(for: attachment)
            #expect(freshPublished && AttachmentThumbnailer.cachedSourceState(for: attachment) == .sourceAvailable)
        }
    }

    @Test("sent failed media still opens its available source while the draft remains blocked")
    func failedTranscriptPreservesSourceAccess() async throws {
        let directory = try root()
        let url = directory.appendingPathComponent("failed-image.png")
        let bytes = Data("owned damaged image".utf8)
        try bytes.write(to: url)
        let attachment = ChatAttachment(kind: .image, fileName: "failed-image.png", fileType: .image,
                                        data: bytes, fileURL: url.path, status: .failed)
        let fileManager = Preview638FileManager()
        let published = await AttachmentThumbnailer.preparePreview(
            for: attachment, requiresReady: false, sourceStateReader: {
                ChatAttachmentOpenTarget.sourceState(for: $0, fileManager: fileManager)
            })
        #expect(published && fileManager.readThreads == [false])
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == .sourceAvailable)
        #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
        #expect(ChatAttachmentOpenTarget.canOpen(attachment))
        let session = UUID()
        #expect(!GlobalComposer.canRenderPendingAttachmentPreview(attachment,
            expectedSessionID: session, activeSessionID: session, pendingAttachments: [attachment]))
        #expect(!GlobalComposer.canPreviewPendingAttachment(attachment,
            expectedSessionID: session, activeSessionID: session, pendingAttachments: [attachment]))
        #expect(try Data(contentsOf: ChatAttachmentOpenTarget().resolve(attachment)) == bytes)
        #expect(attachment.status == .failed && attachment.data == bytes)
    }

    @Test("pending and failed rows do not start file checks or thumbnail decoding",
          arguments: [ChatAttachment.Status.pending, .failed])
    func notReadyRemainsUnprepared(status: ChatAttachment.Status) async throws {
        let attachment = ChatAttachment(kind: .image, fileName: "owned.png", fileType: .image,
            data: try png(), fileURL: "/owned638/not-read", status: status)
        let fileManager = Preview638FileManager()
        let published = await AttachmentThumbnailer.preparePreview(for: attachment, sourceStateReader: {
            ChatAttachmentOpenTarget.sourceState(for: $0, fileManager: fileManager)
        })
        #expect(!published && fileManager.readThreads.isEmpty)
        #expect(AttachmentThumbnailer.cachedSourceState(for: attachment) == nil)
        #expect(AttachmentThumbnailer.cachedThumbnail(for: attachment) == nil)
    }
}
