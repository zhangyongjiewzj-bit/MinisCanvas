import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

// Goal25 attachment repair: pure helpers first, then the real detached resolver.
@Suite("Composer attachment repair", .serialized)
@MainActor
struct ComposerAttachmentRepairTests {
    private func fixture() throws -> (ChatStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-repair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "attachment-repair-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        return (chat, root)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "attachment did not reach the observed state")
    }

    private func failedAttachment(
        name: String = "a.txt", type: FileType = .text, path: String? = "/tmp/a.txt", reason: String? = "文本编码无法识别"
    ) -> ChatAttachment {
        ChatAttachment(kind: .file, fileName: name, fileType: type, mimeType: nil, size: 12,
                       fileURL: path, status: .failed, failureReason: reason)
    }

    // MARK: 2 / 3 text cap, head+tail, byte limit

    @Test("text under the cap is injected unchanged and the cap is 60k")
    func capConstantsAndShortText() {
        #expect(ChatStore.maxTextAttachmentChars == 60_000)
        #expect(ChatStore.textAttachmentHeadChars + ChatStore.textAttachmentTailChars == ChatStore.maxTextAttachmentChars)
        let text = String(repeating: "字", count: 60_000)
        #expect(ChatStore.capTextForInjection(text) == text)
    }

    @Test("text over the cap keeps 48k head and 12k tail with an omission line")
    func headTailCap() {
        let text = String(repeating: "H", count: 48_000) + String(repeating: "x", count: 5_000)
            + String(repeating: "T", count: 12_000)
        let capped = ChatStore.capTextForInjection(text)
        #expect(capped.hasPrefix(String(repeating: "H", count: 48_000)))
        #expect(capped.hasSuffix(String(repeating: "T", count: 12_000)))
        #expect(capped.contains("中间省略 5000 字"))
        #expect(capped.contains("file_read"))
        #expect(!capped.contains("x"))
    }

    @Test("a source cut by the read cap keeps only the head and says the total is approximate")
    func readCapHeadOnly() {
        let text = String(repeating: "a", count: 70_000)
        let capped = ChatStore.capTextForInjection(text, sourceWasTruncated: true, estimatedTotalCharacters: 2_500_000)
        #expect(capped.hasPrefix(String(repeating: "a", count: 60_000) + "\n\n["))
        #expect(capped.contains("已注入前 60000 字"))
        #expect(capped.contains("全文约 2500000 字"))
    }

    @Test("character estimate scales by file size and never drops below the decoded count")
    func estimate() {
        #expect(ChatStore.estimatedTextCharacterCount(decodedCount: 1_000, readBytes: 2_000, fileSize: 8_000) == 4_000)
        #expect(ChatStore.estimatedTextCharacterCount(decodedCount: 1_000, readBytes: 2_000, fileSize: 1_000) == 1_000)
        #expect(ChatStore.estimatedTextCharacterCount(decodedCount: 1_000, readBytes: 2_000, fileSize: nil) == 1_000)
    }

    @Test("leading-bytes read stops at the limit and reports truncation")
    func leadingBytes() throws {
        let (_, root) = try fixture()
        let big = root.appendingPathComponent("big.bin")
        try Data(repeating: 0x61, count: 1_000).write(to: big)
        let cut = try #require(ChatStore.readLeadingBytes(url: big, maxBytes: 100))
        #expect(cut.data.count == 100 && cut.truncated)
        let whole = try #require(ChatStore.readLeadingBytes(url: big, maxBytes: 1_000))
        #expect(whole.data.count == 1_000 && !whole.truncated)
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let none = try #require(ChatStore.readLeadingBytes(url: empty, maxBytes: 100))
        #expect(none.data.isEmpty && !none.truncated)
        #expect(ChatStore.readLeadingBytes(url: root.appendingPathComponent("missing"), maxBytes: 10) == nil)
    }

    // MARK: 1 encodings

    @Test("UTF-8, GB18030 and a byte-cut UTF-8 tail decode; undecodable bytes do not")
    func decoding() throws {
        #expect(ChatStore.decodeTextAttachmentBytes(Data("你好".utf8), truncated: false) == "你好")
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbk = try #require("你好，世界".data(using: gb18030))
        #expect(String(data: gbk, encoding: .utf8) == nil)
        #expect(ChatStore.decodeTextAttachmentBytes(gbk, truncated: false) == "你好，世界")
        let cut = Data("字字字".utf8).prefix(8)
        #expect(ChatStore.decodeTextAttachmentBytes(Data(cut), truncated: true) == "字字")
        #expect(ChatStore.decodeTextAttachmentBytes(Data([0xFF, 0xFF, 0xFF]), truncated: false) == nil)
    }

    @Test("E-10: one stray bad byte in UTF-8 text is replaced, not reinterpreted as GB18030; UTF-16 BOM decodes")
    func lenientUTF8AndUTF16() throws {
        var mixed = Data(String(repeating: "日志行 ok 你好\n", count: 200).utf8)
        mixed.insert(0xFF, at: 50)
        let text = try #require(ChatStore.decodeTextAttachmentBytes(mixed, truncated: false))
        #expect(text.contains("日志行 ok 你好"))
        #expect(text.contains("\u{FFFD}"))
        let utf16 = try #require("你好 world".data(using: .utf16))
        #expect(ChatStore.decodeTextAttachmentBytes(utf16, truncated: false) == "你好 world")
    }

    @Test("E-4: a PNG saved with a .jpg extension is admitted as image/png")
    func misnamedImageUsesHeaderMIME() async throws {
        let (chat, root) = try fixture()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent("shot.jpg")
        try png.write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .image)
        #expect(att.mimeType == "image/png")
    }

    @Test("M-04: a GIF saved with a .jpg extension is transcoded to a ready PNG/JPEG, not passed through")
    func misnamedGifIsTranscoded() async throws {
        let (chat, root) = try fixture()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let gif = try #require(rep.representation(using: .gif, properties: [:]))
        #expect(MediaPayloadValidation.sniffedImageMIME(gif) == nil)
        let url = root.appendingPathComponent("anim.jpg")
        try gif.write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .image)
        let sniffed = att.data.flatMap { MediaPayloadValidation.sniffedImageMIME($0) }
        #expect(sniffed == "image/png" || sniffed == "image/jpeg")
    }

    @Test("R3-15: a passed-through image keeps its bytes after the source file is truncated in place")
    func passThroughImageSurvivesSourceTruncation() async throws {
        let (chat, root) = try fixture()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // 确定性噪声，压缩后仍有数百 KB，足以跨多个内存页。
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let pixels = try #require(rep.bitmapData)
        for offset in 0..<(rep.bytesPerRow * 512) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[offset] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 100_000)
        let url = root.appendingPathComponent("shot.png")
        try png.write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .image)
        // 源文件被原地改写（cp、重定向等）：内存映射的字节会变或直接崩溃。
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        #expect(att.data == png)
    }

    @Test("E-12: a PDF over the 32 MB extraction limit becomes a path reference, not a failure")
    func oversizePDFBecomesReference() async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("big.pdf")
        var bytes = Data("%PDF-1.4\n".utf8)
        bytes.append(Data(count: 33 * 1024 * 1024))
        try bytes.write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .file)
        #expect(att.fileURL == url.path)
    }

    @Test("a GBK text file becomes a ready text attachment through the real resolver")
    func gbkFileEndToEnd() async throws {
        let (chat, root) = try fixture()
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let url = root.appendingPathComponent("gbk.txt")
        try #require("你好，世界".data(using: gb18030)).write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .text)
        #expect(att.data.flatMap { String(data: $0, encoding: .utf8) } == "你好，世界")
    }

    @Test("a file over 2 MB is read only up to 2 MB and states an approximate total")
    func largeFileEndToEnd() async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("large.txt")
        let total = 3 * 1024 * 1024
        try Data(repeating: 0x61, count: total).write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.status != .pending }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.status == .ready && att.kind == .text)
        let body = try #require(att.data.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("全文约 \(total) 字"))
        #expect(att.originalTextCharacterCount == total)
        #expect(body.count < ChatStore.maxTextAttachmentChars + 1_000)
    }

    // MARK: 6 type sniffing

    @Test("unknown extension with UTF-8 text and extensionless Makefile are injected as text")
    func sniffedAndNamedText() async throws {
        let (chat, root) = try fixture()
        let weird = root.appendingPathComponent("notes.weirdext")
        try Data("hello 你好\n".utf8).write(to: weird)
        let make = root.appendingPathComponent("Makefile")
        try Data("all:\n\techo hi\n".utf8).write(to: make)
        chat.addAttachments(urls: [weird, make])
        try await waitUntil { chat.pendingAttachments.allSatisfy { $0.kind == .text } }
        #expect(chat.pendingAttachments.map(\.fileType) == [.text, .text])
        #expect(chat.pendingAttachments[0].data.flatMap { String(data: $0, encoding: .utf8) } == "hello 你好\n")
    }

    // 11/16 第三批：rtf 走富文本提取，注入的是正文而不是 {\rtf1 原始标记，也不再按 UTF-8 嗅探成原文。
    @Test("rtf is extracted as document text, never injected as raw markup")
    func rtfStaysReference() async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("memo.rtf")
        try Data("{\\rtf1\\ansi hello}".utf8).write(to: url)
        _ = try #require(chat.addAttachments(urls: [url]).first)
        try await waitUntil { chat.pendingAttachments.first?.status == .ready }
        let resolved = try #require(chat.pendingAttachments.first)
        #expect(resolved.kind == .text && resolved.mimeType == ChatStore.extractedDocumentMimeType)
        let body = String(decoding: try #require(resolved.data), as: UTF8.self)
        #expect(body.contains("hello"))
        #expect(!body.contains("\\rtf1"))
    }

    @Test("unknown binary stays a reference")
    func binaryStaysReference() async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("blob.weirdext")
        try Data([0x61, 0x00, 0x62, 0x63]).write(to: url)
        chat.addAttachments(urls: [url])
        try await waitUntil { chat.pendingAttachments.first?.size != nil }
        #expect(chat.pendingAttachments.first?.kind == .file)
        #expect(chat.pendingAttachments.first?.fileType == .unknown)
    }

    // MARK: 8 symlink / alias

    @Test("a symlink without extension follows its target but keeps the user's path")
    func symlinkIsFollowed() async throws {
        let (chat, root) = try fixture()
        let target = root.appendingPathComponent("real.txt")
        try Data("via link".utf8).write(to: target)
        let link = root.appendingPathComponent("latest")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        chat.addAttachments(urls: [link])
        try await waitUntil { chat.pendingAttachments.first?.kind == .text }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.fileURL == link.path)
        #expect(att.size == Int64("via link".utf8.count))
        #expect(att.data.flatMap { String(data: $0, encoding: .utf8) } == "via link")
    }

    @Test("source resolution follows a symlink chain and returns plain files unchanged")
    func sourceResolution() throws {
        let (_, root) = try fixture()
        let target = root.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(ChatStore.resolvedAttachmentSourceURL(link).lastPathComponent == "t.txt")
        #expect(ChatStore.resolvedAttachmentSourceURL(target).lastPathComponent == "t.txt")
    }

    @Test("a Finder alias resolves to its target (inference: bookmark files need a real volume)")
    func aliasResolution() throws {
        let (_, root) = try fixture()
        let target = root.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)
        let alias = root.appendingPathComponent("target alias")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: alias)
        #expect(ChatStore.resolvedAttachmentSourceURL(alias).lastPathComponent == "target.txt")
    }

    // MARK: 1 / 9 failure reasons and path reference

    @Test("failure reason is one sentence: no duplicated text and no 。， punctuation")
    func reasonText() {
        let withPath = ChatStore.composerFailedAttachmentReason(for: failedAttachment(reason: "附件超过 25 MB。"))
        #expect(withPath == "附件超过 25 MB；可改为路径引用，或移除后重新添加。")
        #expect(!withPath.contains("。，") && !withPath.contains("。；"))
        #expect(withPath.components(separatedBy: "附件超过").count == 2)
        let noPath = ChatStore.composerFailedAttachmentReason(for: failedAttachment(path: nil))
        #expect(noPath == "文本编码无法识别；请移除后重新添加。")
        #expect(ChatStore.composerFailedAttachmentReason(
            for: failedAttachment(type: .image, reason: nil)) == "读取失败；可改为路径引用，或移除后重新添加。")
    }

    @Test("unsupported video containers say so directly; other video failures stay generic",
          arguments: ["mkv", "webm", "avi", "wmv", "flv"])
    func unsupportedVideoFormat(ext: String) {
        let att = failedAttachment(name: "clip.\(ext)", type: .video, path: "/tmp/clip.\(ext)", reason: nil)
        #expect(ChatStore.composerFailedAttachmentReason(for: att) == "该视频格式不支持抽帧，可改为路径引用。")
        let mp4 = failedAttachment(name: "clip.mp4", type: .video, path: "/tmp/clip.mp4", reason: nil)
        #expect(ChatStore.composerFailedAttachmentReason(for: mp4) == "视频抽帧失败；可改为路径引用，或移除后重新添加。")
    }

    @Test("the readiness snapshot carries the single-sentence reason for a failed attachment")
    func snapshotReason() throws {
        let (chat, _) = try fixture()
        let failed = failedAttachment(reason: "附件超过 25 MB")
        chat.addComposerDraftAttachment(failed)
        let item = try #require(chat.composerMediaReadinessSnapshot.attachment(id: failed.id))
        #expect(item.readiness == .failed && item.blocksSend)
        #expect(item.reason == "附件超过 25 MB；可改为路径引用，或移除后重新添加。")
        #expect(chat.composerAttachmentBlockReason == item.reason)
    }

    @Test("text attachments over the 200k total are blocked with a visible reason and can become path references")
    func textAttachmentTotalCap() throws {
        let (chat, _) = try fixture()
        #expect(ChatStore.maxComposerTextAttachmentTotalChars == 200_000)
        let body = Data(String(repeating: "字", count: 60_000).utf8)
        let items = (0..<4).map { index in
            ChatAttachment(kind: .text, fileName: "t\(index).txt", fileType: .text,
                           data: body, fileURL: "/tmp/t\(index).txt", originalTextCharacterCount: 60_000)
        }
        for item in items { chat.addComposerDraftAttachment(item) }
        let snapshot = chat.composerMediaReadinessSnapshot
        for item in items.prefix(3) {
            #expect(snapshot.attachment(id: item.id)?.blocksSend == false)
        }
        let over = try #require(snapshot.attachment(id: items[3].id))
        #expect(over.blocksSend)
        #expect(over.reason.contains("文本附件总量超出上限"))
        #expect(chat.convertPendingAttachmentToPathReference(id: items[3].id))
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: items[3].id)?.blocksSend == false)
    }

    @Test("a failed attachment converts to a ready path reference and unblocks sending")
    func convertToPathReference() throws {
        let (chat, _) = try fixture()
        let failed = failedAttachment()
        chat.addComposerDraftAttachment(failed)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.convertPendingAttachmentToPathReference(id: failed.id))
        let ref = try #require(chat.pendingAttachments.first)
        #expect(ref.id == failed.id && ref.status == .ready)
        #expect(ref.kind == .file && ref.fileType == .unknown && ref.fileURL == "/tmp/a.txt")
        #expect(ref.data == nil && ref.size == 12)
        #expect(chat.canSubmitComposerAttachments)
        let content = ChatStore.composeUserContent(text: "", attachments: [ref])
        #expect(content.contains("路径 /tmp/a.txt") && content.contains("file_read"))
    }

    @Test("conversion refuses pending attachments, unknown ids and attachments without a path")
    func conversionGuards() throws {
        let (chat, _) = try fixture()
        let pending = ChatAttachment(kind: .file, fileName: "p.txt", fileType: .text, fileURL: "/tmp/p.txt", status: .pending)
        let noPath = failedAttachment(path: nil)
        chat.addComposerDraftAttachment(pending)
        chat.addComposerDraftAttachment(noPath)
        #expect(!chat.convertPendingAttachmentToPathReference(id: pending.id))
        #expect(!chat.convertPendingAttachmentToPathReference(id: noPath.id))
        #expect(!chat.convertPendingAttachmentToPathReference(id: UUID()))
        #expect(ChatStore.pathReference(for: noPath) == nil)
        #expect(chat.pendingAttachments == [pending, noPath])
    }

    // MARK: 4 send feedback

    @Test("a blocked send explains itself; a pending attachment says it becomes sendable after parsing")
    func blockedSendFeedback() throws {
        let (chat, _) = try fixture()
        chat.noteComposerSendBlockedByAttachments()
        #expect(chat.pastedTextActionFeedback == nil)

        let pending = ChatAttachment(kind: .file, fileName: "p.txt", fileType: .text, fileURL: "/tmp/p.txt", status: .pending)
        chat.addComposerDraftAttachment(pending)
        chat.noteComposerSendBlockedByAttachments()
        let message = try #require(chat.pastedTextActionFeedback)
        #expect(message.contains("附件解析中") && message.contains("解析完成后即可发送"))
        #expect(!message.contains("自动发送") || message.contains("不会自动发送"))
    }

    @Test("a failed attachment's reason reaches the feedback line")
    func failedSendFeedback() throws {
        let (chat, _) = try fixture()
        chat.addComposerDraftAttachment(failedAttachment(reason: "附件超过 25 MB"))
        chat.noteComposerSendBlockedByAttachments()
        #expect(chat.pastedTextActionFeedback == "附件超过 25 MB；可改为路径引用，或移除后重新添加。")
    }

    // MARK: 7 dropped web links

    @Test("dropped web links are not attachments and are inserted into the draft as text")
    func droppedWebLink() throws {
        let (chat, _) = try fixture()
        let web = try #require(URL(string: "https://example.com/report.pdf"))
        let split = ChatStore.partitionDroppedURLs([web, URL(fileURLWithPath: "/tmp/x.txt")])
        #expect(split.files.map(\.path) == ["/tmp/x.txt"] && split.webLinkCount == 1)
        #expect(chat.addDroppedURLs([web]) == true)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.draftText.contains("https://example.com/report.pdf"))
    }

    @Test("a mixed drop keeps the local file and still shows the hint")
    func droppedMixed() throws {
        let (chat, root) = try fixture()
        let file = root.appendingPathComponent("ok.txt")
        try Data("ok".utf8).write(to: file)
        let web = try #require(URL(string: "http://example.com/a"))
        #expect(chat.addDroppedURLs([web, file]))
        #expect(chat.pendingAttachments.map(\.fileName) == ["ok.txt"])
        #expect(chat.pastedTextActionFeedback == "请先把网页上的文件保存到本地再拖入")
    }
}

extension ComposerAttachmentRepairTests {
    @Test("MCP image result line with a full-width closing bracket still yields the saved image path")
    func savedImagePathSurvivesFullWidthBracket() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-thumb-\(UUID())/tool-output/s", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let png = dir.appendingPathComponent("mcp-image-1.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 1]).write(to: png)
        let output = "[工具返回了 1 张图片（image/png，已保存：\(png.path)）]"
        #expect(ToolEventCard.savedImagePaths(in: output) == [png.path])
    }

    @Test("an @ word is replaced by the file path instead of being deleted")
    func atMentionKeepsTextReference() {
        let text = "看看 @a.sw 的问题"
        let cursor = ("看看 @a.sw" as NSString).length
        #expect(ChatStore.replacingAtMention(in: text, cursorUTF16: cursor, with: "a.swift") == "看看 a.swift 的问题")
    }

    @Test("scanned PDF page images tell the model how to read more pages")
    func scannedPDFPageImageHint() {
        let page = ChatAttachment(kind: .image, fileName: "x.pdf 第3页", fileType: .image,
            mimeType: "image/png", data: Data([1]), fileURL: "/tmp/x.pdf")
        let content = ChatStore.composeUserContent(text: "看", attachments: [page])
        #expect(content.contains("as_images=true"))
    }

    @Test("editing a message with a text attachment fills only the typed words, not the attachment body")
    func editUsesDisplayContent() throws {
        let (chat, _) = try fixture()
        let attachment = ChatAttachment(kind: .text, fileName: "n.txt", fileType: .text,
            data: Data("附件正文".utf8), fileURL: "/tmp/n.txt")
        let content = ChatStore.composeUserContent(text: "请总结", attachments: [attachment])
        let message = ChatMessageUI(role: .user, content: content, attachments: [attachment])
        chat.messages = [message]
        chat.beginEdit(messageID: message.id)
        #expect(chat.draftText == "请总结")
        #expect(chat.pendingAttachments == [attachment])
    }

    @Test("an empty session recalls recent inputs from other sessions, newest first, without duplicates")
    func inputHistoryFallsBackToOtherSessions() throws {
        let (chat, _) = try fixture()
        chat.appendUser("第一条")
        chat.appendUser("第二条")
        chat.appendUser("第一条")
        _ = chat.applyNewSession(title: "新会话")
        #expect(chat.localInputHistory.isEmpty)
        #expect(chat.recentInputHistoryAcrossSessions() == ["第二条", "第一条"])
        chat.draftText = ""
        #expect(chat.handleInputHistoryKey(.up))
        #expect(chat.draftText == "第一条")
        #expect(chat.handleInputHistoryKey(.up))
        #expect(chat.draftText == "第二条")
    }

    @Test("@ completion finds project files by name, skipping hidden and dependency folders")
    func atMentionFileCandidates() throws {
        let (_, root) = try fixture()
        let fileManager = FileManager.default
        for path in ["src/Readme.md", "node_modules/pkg/readme.md", ".git/readme.txt", "docs/guide-readme.txt", "other.swift"] {
            let url = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let found = ChatStore.projectFileMentionCandidates(root: root.path, query: "read")
        #expect(found == ["src/Readme.md", "docs/guide-readme.txt"])
        #expect(ChatStore.atMentionQuery(in: "看看 @src/Re") == "src/Re")
        #expect(ChatStore.atMentionQuery(in: "mail me@x.com") == nil)
        #expect(ChatStore.atMentionQuery(in: "@a b") == nil)
        #expect(ChatStore.removingTrailingAtMention(from: "看看 @src/Re") == "看看 ")
    }

    @Test("@ completion in an ordinary session also searches /add-dir directories, still hiding secret files")
    func atMentionSearchesAddedDirectories() throws {
        let (chat, root) = try fixture()
        let added = root.appendingPathComponent("added")
        for path in ["notes/plan-draft.md", ".env"] {
            let url = added.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let found = ChatStore.additionalDirectoryMentionCandidates(roots: [added.path], query: "plan")
        #expect(found == [added.path + "/notes/plan-draft.md"])
        #expect(!ChatStore.additionalDirectoryMentionCandidates(roots: [added.path], query: "env").contains { $0.hasSuffix(".env") })
        // 选中目录后继续往下选：引用词是该目录下的绝对路径。
        #expect(ChatStore.additionalDirectoryMentionCandidates(roots: [added.path], query: added.path + "/notes/pl")
                == [added.path + "/notes/plan-draft.md"])

        _ = chat.applyNewSession(title: "普通会话")
        #expect(chat.fileMentionAdditionalRoots.isEmpty)
        chat.additionalDirectoriesProvider = { _ in [added.path] }
        #expect(chat.fileMentionAdditionalRoots == [added.path])
    }

    @Test("@ completion works at the cursor, lists directories and hidden files, never lists secret files")
    func atMentionCursorDirectoriesAndHiddenFiles() throws {
        let (_, root) = try fixture()
        let fileManager = FileManager.default
        for path in [".github/workflows/ci.yml", "src/app/Main.swift", ".env", "node_modules/x/app.js"] {
            let url = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let dirs = ChatStore.projectFileMentionCandidates(root: root.path, query: "app")
        #expect(dirs.contains("src/app/"))
        #expect(!dirs.contains { $0.hasPrefix("node_modules") })
        #expect(ChatStore.projectFileMentionCandidates(root: root.path, query: "ci.yml") == [".github/workflows/ci.yml"])
        #expect(!ChatStore.projectFileMentionCandidates(root: root.path, query: "env").contains(".env"))

        // 光标在句中：只认光标前的 @ 词，光标后的文字保留。
        let text = "看 @src/ap 然后继续"
        let cursor = ("看 @src/ap" as NSString).length
        #expect(ChatStore.atMentionToken(in: text, cursorUTF16: cursor)?.query == "src/ap")
        #expect(ChatStore.removingAtMention(from: text, cursorUTF16: cursor) == "看  然后继续")
        #expect(ChatStore.atMentionToken(in: text, cursorUTF16: 1) == nil)
    }

    @Test("pasted and dropped images are numbered 图 1, 图 2 by one landing function")
    func pastedImagesAreNumbered() throws {
        let (chat, _) = try fixture()
        #expect(ChatStore.nextPastedImageNumber(existingFileNames: ["a.png", "图 2.png"]) == 3)
        let directory = ComposerPasteboardAttachments.defaultImageDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var urls: [URL] = []
        for index in 1...2 {
            let url = directory.appendingPathComponent("粘贴的图片 \(index).png")
            try Data("x".utf8).write(to: url)
            urls.append(url)
        }
        #expect(chat.addDroppedURLs(urls))
        #expect(chat.pendingAttachments.map(\.fileName) == ["图 1.png", "图 2.png"])
        _ = chat.addDroppedURLs([URL(string: "https://example.com/a.png")!])
        #expect(chat.pendingAttachments.count == 2)
    }

    @Test("a PNG whose long edge is over 2000 px is transcoded instead of passed through")
    func hugeImagePixelsAreNotPassedThrough() {
        let limit = ChatStore.uploadImageMaxPixel
        #expect(MediaConversion.imageExceedsPassThroughPixels(width: 9_000, height: 100, maxLongEdge: limit))
        #expect(MediaConversion.imageExceedsPassThroughPixels(width: 2_880, height: 1_800, maxLongEdge: limit))
        #expect(MediaConversion.imageExceedsPassThroughPixels(width: 100, height: 2_001, maxLongEdge: limit))
        #expect(!MediaConversion.imageExceedsPassThroughPixels(width: 2_000, height: 1_500, maxLongEdge: limit))
    }

    @Test("a source cut by the read cap keeps head and tail when the file end was read")
    func readCapKeepsHeadAndTail() {
        let head = String(repeating: "a", count: 60_000)
        let tail = String(repeating: "z", count: 20_000)
        let capped = ChatStore.capTextForInjection(head, sourceWasTruncated: true,
            estimatedTotalCharacters: 2_500_000, sourcePath: "/tmp/big.log", tailText: tail)
        #expect(capped.hasPrefix(String(repeating: "a", count: 48_000) + "\n\n["))
        #expect(capped.hasSuffix(String(repeating: "z", count: 12_000)))
        #expect(capped.contains("direction=tail") && capped.contains("/tmp/big.log"))
    }

    @Test("a ready attachment can be switched to a path reference; a PDF reference keeps its type and hint")
    func readyAttachmentToPathReference() throws {
        let text = ChatAttachment(kind: .text, fileName: "n.txt", fileType: .text,
                                  data: Data("x".utf8), fileURL: "/tmp/n.txt")
        #expect(ChatStore.canConvertToPathReference(text))
        let plain = ChatAttachment(kind: .file, fileName: "n.bin", fileType: .unknown, fileURL: "/tmp/n.bin")
        #expect(!ChatStore.canConvertToPathReference(plain))
        let pdf = ChatAttachment(kind: .text, fileName: "a.pdf", fileType: .unknown,
                                 mimeType: "application/pdf", data: Data("t".utf8), fileURL: "/tmp/a.pdf")
        let reference = try #require(ChatStore.pathReference(for: pdf))
        #expect(reference.mimeType == "application/pdf")
        let content = ChatStore.composeUserContent(text: "", attachments: [reference])
        #expect(content.contains("page_start") && !content.contains("不是已识别的文本格式"))
    }

    @Test("a scanned-PDF page image becomes a path reference to the PDF when the model has no image input")
    func scannedPDFPageWithoutVision() throws {
        let page = ChatAttachment(kind: .image, fileName: "scan.pdf 第1页", fileType: .image,
                                  mimeType: "image/png", data: Data([1, 2, 3]), fileURL: "/tmp/scan.pdf")
        #expect(ChatStore.isScannedPDFPageImage(page))
        let adapted = ChatStore.adaptingVideo(page, supported: [.textInput])
        #expect(adapted.attachment.kind == .file && adapted.attachment.fileName == "scan.pdf")
        #expect(adapted.note?.contains("扫描件") == true)
        let kept = ChatStore.adaptingVideo(page, supported: [.textInput, .imageInput])
        #expect(kept.attachment == page)
    }

    @Test("E-5 an image is replaced by its recognized text when the model has no image input")
    func imageTextReplacesImageForTextOnlyModel() throws {
        let image = ChatAttachment(kind: .image, fileName: "截图.png", fileType: .image,
                                   mimeType: "image/png", data: Data([1, 2, 3]), fileURL: "/tmp/截图.png")
        // 没有识别结果、或模型能看图：不替换。
        #expect(ChatStore.imageTextSubstitution(image, supported: [.textInput], recognizedText: nil) == nil)
        #expect(ChatStore.imageTextSubstitution(image, supported: [.textInput, .imageInput], recognizedText: "文字") == nil)
        let replaced = try #require(ChatStore.imageTextSubstitution(
            image, supported: [.textInput], recognizedText: "订单号 12345"))
        #expect(replaced.attachment.kind == .text)
        #expect(replaced.attachment.id == image.id)
        #expect(replaced.note.contains("没有发送图片本身"))
        let content = ChatStore.composeUserContent(text: "看看", attachments: [replaced.attachment])
        #expect(content.contains("订单号 12345"))
        #expect(content.contains("看不到图片"))
        #expect(!content.contains("我上传了文件"))
    }

    @Test("an audio attachment with a transcript is sent as text when the model has no audio input")
    func audioTranscriptReplacesAudioForTextOnlyModel() throws {
        var audio = ChatAttachment(kind: .audio, fileName: "会议.wav", fileType: .audio,
                                   mimeType: "audio/wav", data: Data([1, 2, 3]), fileURL: "/tmp/会议.wav")
        audio.audioTranscript = AudioTranscript(text: "大家好", localeIdentifier: "zh-CN",
                                                durationSeconds: 65, onDevice: true)
        #expect(ChatStore.audioTranscriptSubstitution(audio, supported: [.textInput], wire: .openaiCompatible) != nil)
        #expect(ChatStore.audioTranscriptSubstitution(audio, supported: [.textInput, .audioInput], wire: .openaiCompatible) == nil)
        let replaced = try #require(ChatStore.audioTranscriptSubstitution(audio, supported: [.textInput], wire: nil)).attachment
        let content = ChatStore.composeUserContent(text: "总结一下", attachments: [replaced])
        #expect(content == "总结一下\n\n[音频转写：会议.wav，时长 01:05]\n大家好")
        let decoded = try JSONDecoder().decode(ChatAttachment.self, from: JSONEncoder().encode(audio))
        #expect(decoded.audioTranscript?.text == "大家好")
    }

    @Test("a directory attachment tells the model it is a folder")
    func directoryReferenceContent() {
        let reference = ChatStore.directoryReference(id: UUID(), url: URL(fileURLWithPath: "/tmp/proj/", isDirectory: true), size: nil)
        #expect(reference.fileName == "proj" && reference.fileURL == "/tmp/proj")
        #expect(ChatStore.composeUserContent(text: "", attachments: [reference]).contains("这是目录"))
    }

    @Test("missing-source text from a PDF is opened as a .txt file")
    func extractedTextMaterializesAsTxt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = ChatAttachment(kind: .text, fileName: "合同.pdf", fileType: .unknown,
                                 mimeType: "application/pdf", data: Data("正文".utf8), fileURL: "/nonexistent/合同.pdf")
        let url = try ChatAttachmentOpenTarget(temporaryDirectory: root).resolve(pdf)
        #expect(url.lastPathComponent == "合同.txt")
    }
}
