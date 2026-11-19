import AppKit
import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Composer paste image and file attachments")
struct ComposerPasteImageAttachmentTests {
    @MainActor
    private func makeView(
        string: @escaping () -> String?,
        attachments: @escaping () -> [URL],
        images: @escaping () -> [URL] = { [] }
    ) -> (ComposerPasteAwareTextView, Recorder) {
        let view = ComposerPasteAwareTextView(frame: .zero)
        view.string = "正文"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.pasteboardStringProvider = string
        view.pasteboardAttachmentProvider = attachments
        view.pasteboardImageProvider = images
        let recorder = Recorder()
        view.onPasteEvent = { event in
            recorder.events.append(event)
            return !event.attachmentURLs.isEmpty
        }
        return (view, recorder)
    }

    @MainActor
    final class Recorder { var events: [ComposerPasteEvent] = [] }

    @Test("text only keeps the original text path")
    @MainActor
    func textOnly() {
        let (view, recorder) = makeView(string: { "短文字" }, attachments: { [] })
        view.paste(nil)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.text == "短文字")
        #expect(recorder.events.first?.attachmentURLs.isEmpty == true)
    }

    @Test("image plus blob text becomes an attachment and inserts no text")
    @MainActor
    func imageWithBlobText() {
        let url = URL(fileURLWithPath: "/tmp/pasted.png")
        let (view, recorder) = makeView(
            string: { "blob:https://claude.ai/abc" }, attachments: { [] }, images: { [url] }
        )
        view.paste(nil)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.attachmentURLs == [url])
        #expect(view.string == "正文")
    }

    @Test("image with empty text becomes an image attachment")
    @MainActor
    func imageWithEmptyText() {
        let url = URL(fileURLWithPath: "/tmp/pasted.png")
        let (view, recorder) = makeView(string: { nil }, attachments: { [] }, images: { [url] })
        view.paste(nil)
        #expect(recorder.events.first?.attachmentURLs == [url])
    }

    @Test("image representation next to real text (Excel/Pages table) pastes the text")
    @MainActor
    func imageWithRealTextPastesText() {
        let url = URL(fileURLWithPath: "/tmp/pasted.png")
        let (view, recorder) = makeView(
            string: { "姓名\t分数\n甲\t90" }, attachments: { [] }, images: { [url] }
        )
        view.paste(nil)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.attachmentURLs.isEmpty == true)
        #expect(recorder.events.first?.text == "姓名\t分数\n甲\t90")
    }

    @Test("file URLs win over real text")
    @MainActor
    func fileURLsBeatText() {
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let (view, recorder) = makeView(string: { "a.pdf" }, attachments: { [url] })
        view.paste(nil)
        #expect(recorder.events.first?.attachmentURLs == [url])
    }

    @Test("paste decision is a pure priority: files, then image with empty or single-link text, then text")
    func decisionTable() {
        typealias D = ComposerPasteDecision
        #expect(D.resolve(hasFileURLs: true, hasImage: true, text: "文字") == .fileAttachments)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: nil) == .imageAttachment)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "  \n") == .imageAttachment)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "blob:https://claude.ai/abc") == .imageAttachment)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "https://example.com/a.png") == .imageAttachment)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "http://example.com/a") == .imageAttachment)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "看这个 https://example.com") == .text)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "https://a.com https://b.com") == .text)
        #expect(D.resolve(hasFileURLs: false, hasImage: true, text: "普通文字") == .text)
        #expect(D.resolve(hasFileURLs: false, hasImage: false, text: nil) == .text)
    }

    @Test("file URL becomes an attachment")
    @MainActor
    func fileURL() {
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let (view, recorder) = makeView(string: { nil }, attachments: { [url] })
        view.paste(nil)
        #expect(recorder.events.first?.attachmentURLs == [url])
        #expect(view.string == "正文")
    }

    @Test("unsupported pasteboard content falls back to the original path")
    @MainActor
    func unsupported() {
        let (view, recorder) = makeView(string: { nil }, attachments: { [] })
        view.paste(nil)
        #expect(recorder.events.isEmpty)
    }

    @Test("pasteboard reader writes an image as a PNG under the shared attachment temp root")
    @MainActor
    func readerWritesImage() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerPasteImageAttachmentTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString("blob:https://claude.ai/abc", forType: .string)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerPasteImageAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = ComposerPasteboardAttachments.urls(from: pasteboard, imageDirectory: root)

        #expect(urls.count == 1)
        let url = try #require(urls.first)
        #expect(url.pathExtension == "png")
        #expect(url.path.hasPrefix(root.path))
        #expect(NSImage(contentsOf: url) != nil)
    }

    @Test("pasteboard reader prefers file URLs and returns nothing for text only")
    @MainActor
    func readerFilesAndText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerPasteImageAttachmentTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerPasteImageAttachmentTests-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(ComposerPasteboardAttachments.urls(from: pasteboard).map(\.lastPathComponent) == [file.lastPathComponent])

        pasteboard.clearContents()
        pasteboard.setString("纯文字", forType: .string)
        #expect(ComposerPasteboardAttachments.urls(from: pasteboard).isEmpty)
    }
}

extension ComposerPasteImageAttachmentTests {
    @Test("several images on the pasteboard all become attachments")
    @MainActor
    func allPasteboardImagesBecomeFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("w1-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let images = [NSColor.red, NSColor.blue].map { color in
            NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
        }
        #expect(pasteboard.writeObjects(images))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w1-pasted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ComposerPasteboardAttachments.imageURLs(from: pasteboard, imageDirectory: directory)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("pasted temporary images older than a week are cleaned up")
    func staleTemporaryImagesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w1-stale-\(UUID())")
        let old = directory.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ComposerPasteboardAttachments.removeStaleImages(in: directory, now: Date())
        #expect(FileManager.default.fileExists(atPath: old.path))
        ComposerPasteboardAttachments.removeStaleImages(in: directory, now: Date().addingTimeInterval(2 * 24 * 3600))
        #expect(FileManager.default.fileExists(atPath: old.path))
        ComposerPasteboardAttachments.removeStaleImages(in: directory, now: Date().addingTimeInterval(8 * 24 * 3600))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test("paste menu and ⌘V are enabled when the clipboard holds only an image or file")
    @MainActor
    func pasteIsEnabledForImageOnlyClipboard() {
        let (view, _) = makeView(string: { nil }, attachments: { [] })
        let item = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        view.pasteboardHasAttachmentProvider = { true }
        #expect(view.validateUserInterfaceItem(item))
    }

    @Test("stale sweep runs at most once per interval for the same directory")
    func staleSweepIsThrottled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w1-throttle-\(UUID())")
        let old = directory.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let later = Date().addingTimeInterval(8 * 24 * 3600)
        ComposerPasteboardAttachments.removeStaleImagesIfDue(in: directory, now: Date())
        #expect(FileManager.default.fileExists(atPath: old.path))
        // 同一间隔内再次调用不清理；超过间隔后清理。
        ComposerPasteboardAttachments.removeStaleImagesIfDue(in: directory, now: Date().addingTimeInterval(3600))
        #expect(FileManager.default.fileExists(atPath: old.path))
        ComposerPasteboardAttachments.removeStaleImagesIfDue(in: directory, now: later)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test("pasteboard image bytes are snapshotted without encoding and staged as PNG files")
    @MainActor
    func imageSnapshotStagesPNGFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("w1-snap-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.green.setFill(); rect.fill(); return true
        }
        #expect(pasteboard.writeObjects([image]))
        let snapshot = ComposerPasteboardAttachments.imageDataSnapshot(from: pasteboard)
        #expect(snapshot.count == 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w1-snap-dir-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ComposerPasteboardAttachments.stageImageData(snapshot, imageDirectory: directory)
        #expect(urls.count == 1)
        #expect(urls.first?.lastPathComponent == "粘贴的图片 1.png")
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}

/// 实时输出看板：来源处按约 50ms 合并，每个调用独立。
@Suite("Shell live output board coalescing")
struct ShellLiveOutputBoardCoalescingTests {
    @Test("chunks from a burst land in order after one coalesced flush")
    @MainActor
    func burstIsCoalescedInOrder() async throws {
        let id = "coalesce-\(UUID().uuidString)"
        for index in 0..<200 { ShellLiveOutputBoard.receive(callID: id, text: "行\(index)\n") }
        try await Task.sleep(for: .milliseconds(300))
        let tail = try #require(ShellLiveOutputBoard.shared.tail(for: id))
        #expect(tail.hasPrefix("行0\n行1\n"))
        #expect(tail.hasSuffix("行199\n"))
        ShellLiveOutputBoard.shared.clear(callID: id)
    }

    @Test("calls keep independent tails and the tail stays within the limit")
    @MainActor
    func callsAreIndependentAndBounded() {
        let board = ShellLiveOutputBoard.shared
        let a = "a-\(UUID().uuidString)", b = "b-\(UUID().uuidString)"
        board.append(callID: a, text: String(repeating: "x", count: ShellLiveOutputBoard.tailLimit + 500))
        board.append(callID: b, text: "short")
        #expect(board.tail(for: b) == "short")
        let tail = board.tail(for: a) ?? ""
        #expect(tail.count <= ShellLiveOutputBoard.tailLimit + 2)
        board.clear(callID: a); board.clear(callID: b)
        #expect(board.tail(for: a) == nil)
    }
}
