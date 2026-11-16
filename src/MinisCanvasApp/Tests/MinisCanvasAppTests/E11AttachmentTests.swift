import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MinisCore
@testable import MinisCanvasApp

// MARK: - E11 聊天附件上传

/// 1x1 透明 PNG（多模态测试用）
let e11PngData: Data = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!

/// 记录型 Provider：捕获最近一次收到的 [LLMMessage]，验证 images/audios 贯通。
final class RecordingProvider: LLMProvider, @unchecked Sendable {
    var name: String { "Recording" }
    var model: LLMModel = LLMModel(id: "rec", displayName: "Recording", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    private let lock = NSLock()
    private var _lastMessages: [LLMMessage] = []

    var lastMessages: [LLMMessage] {
        lock.lock(); defer { lock.unlock() }
        return _lastMessages
    }

    /// 同步记录（async 上下文直接调 NSLock 会被 Swift 6 拒绝，经此同步方法中转）
    private func record(_ messages: [LLMMessage]) {
        lock.lock()
        _lastMessages = messages
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        record(messages)
        return LLMResponse(text: "ok", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        record(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.text("ok"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

/// 临时文件工厂：在系统临时目录造测试文件，defer 清理。
private func makeTempFile(name: String, data: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("e11-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - ImageAttachment base64 往返

@Suite("E11 图片附件 base64 往返")
struct ImageAttachmentBase64Tests {
    @Test func base64RoundTripPreservesBytes() throws {
        let attachment = LLMMessage.ImageAttachment(mimeType: "image/png", data: e11PngData)
        let encoded = attachment.data.base64EncodedString()
        let decoded = Data(base64Encoded: encoded)
        #expect(decoded == e11PngData)
        #expect(decoded?.count == e11PngData.count)
        #expect(attachment.mimeType == "image/png")
    }

    @Test func imageAttachmentCarriesMimeAndBytes() {
        let att = ChatAttachment(kind: .image, fileName: "a.png", fileType: .image,
                                 mimeType: "image/png", size: Int64(e11PngData.count),
                                 data: e11PngData, fileURL: "/tmp/a.png")
        let llm = att.imageAttachment
        #expect(llm?.mimeType == "image/png")
        #expect(llm?.data == e11PngData)
        // 非图片附件不产出 imageAttachment
        let text = ChatAttachment(kind: .text, fileName: "b.md", fileType: .markdown,
                                  data: Data("hi".utf8))
        #expect(text.imageAttachment == nil)
    }

    @Test func audioAttachmentBase64Encodes() {
        let att = ChatAttachment(kind: .audio, fileName: "voice.wav", fileType: .audio,
                                 data: ComposerMediaFixtures589.wav)
        let llm = att.audioAttachment
        #expect(llm?.format == "wav")
        #expect(llm?.base64Data == ComposerMediaFixtures589.wav.base64EncodedString())
        // 非音频附件不产出 audioAttachment
        let img = ChatAttachment(kind: .image, fileName: "a.png", fileType: .image,
                                 mimeType: "image/png", data: e11PngData)
        #expect(img.audioAttachment == nil)
    }

    @Test func invalidAudioBytesNeverAcquireWAVFormatOrBase64Payload() {
        let invalid = ChatAttachment(kind: .audio, fileName: "voice.wav", fileType: .audio,
            data: Data([0x01, 0x02, 0x03]))
        #expect(MediaPayloadValidation.audioFormat(Data([0x01, 0x02, 0x03])) == nil)
        #expect(invalid.audioAttachment == nil)
    }

}

// MARK: - FileImporter 分类

@Suite("E11 FileImporter 分类")
struct AttachmentClassificationTests {
    @Test func extensionClassification() throws {
        let cases: [(String, FileType)] = [
            ("photo.png", .image), ("pic.jpg", .image), ("pic.jpeg", .image),
            ("doc.md", .markdown), ("doc.markdown", .markdown),
            ("notes.txt", .text), ("code.swift", .text), ("data.csv", .text),
            ("config.json", .json), ("data.jsonl", .json),
            ("song.mp3", .audio), ("clip.mp4", .video),
        ]
        for (name, expected) in cases {
            let url = try makeTempFile(name: name, data: Data())
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(FileImporter.classify(url: url) == expected, "\(name) 应分类为 \(expected)")
        }
    }

    @Test func unknownAndMIMEFallback() throws {
        // 未知扩展名 + 空内容 → .unknown
        let bin = try makeTempFile(name: "blob.bin", data: Data([0x00, 0x01]))
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        #expect(FileImporter.classify(url: bin) == .unknown)

        // 无扩展名但内容为 PNG 魔数 → MIME 兜底 .image
        let magic = try makeTempFile(name: "noext", data: e11PngData)
        defer { try? FileManager.default.removeItem(at: magic.deletingLastPathComponent()) }
        #expect(FileImporter.classify(url: magic) == .image)
        #expect(FileImporter.mimeType(of: magic) == "image/png")
    }
}

// MARK: - 聊天内附件打开

@Suite("E11 聊天内附件打开")
struct ChatAttachmentOpeningTests {
    @Test func canOpenMatchesPersistedSourceAvailability() throws {
        let source = try makeTempFile(name: "available.txt", data: Data("ok".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let available = ChatAttachment(
            kind: .file,
            fileName: "available.txt",
            fileType: .text,
            fileURL: source.path
        )
        let recoverable = ChatAttachment(
            kind: .file,
            fileName: "recoverable.txt",
            fileType: .text,
            data: Data("restored".utf8),
            fileURL: "/path/that/no-longer-exists/recoverable.txt"
        )
        let unavailable = ChatAttachment(
            kind: .file,
            fileName: "missing.txt",
            fileType: .text,
            fileURL: "/path/that/no-longer-exists/missing.txt"
        )

        #expect(ChatAttachmentOpenTarget.canOpen(available))
        #expect(ChatAttachmentOpenTarget.canOpen(recoverable))
        #expect(!ChatAttachmentOpenTarget.canOpen(unavailable))
    }

    @Test func existingFileURLIsUsedWithoutMaterializingAnotherCopy() throws {
        let source = try makeTempFile(name: "report.txt", data: Data("report".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let attachment = ChatAttachment(
            kind: .text,
            fileName: "report.txt",
            fileType: .text,
            data: Data("report".utf8),
            fileURL: source.path
        )
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e11-open-root-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = try ChatAttachmentOpenTarget(
            fileManager: .default,
            temporaryDirectory: tempRoot
        ).resolve(attachment)

        #expect(resolved == source)
        #expect(!FileManager.default.fileExists(atPath: tempRoot.path))
    }

    @Test func missingFileURLFallsBackToPersistedData() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e11-open-root-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "../restored.txt",
            fileType: .text,
            data: Data("restored content".utf8),
            fileURL: "/path/that/no-longer-exists/restored.txt"
        )

        let resolved = try ChatAttachmentOpenTarget(
            fileManager: .default,
            temporaryDirectory: tempRoot
        ).resolve(attachment)

        #expect(resolved.lastPathComponent == "restored.txt")
        #expect(resolved.path.hasPrefix(tempRoot.path))
        #expect(try Data(contentsOf: resolved) == Data("restored content".utf8))
    }

    @Test func attachmentWithoutExistingURLOrDataHasExplicitFailure() {
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "missing.bin",
            fileType: .unknown,
            fileURL: "/path/that/no-longer-exists/missing.bin"
        )

        do {
            _ = try ChatAttachmentOpenTarget().resolve(attachment)
            Issue.record("没有来源的附件不应产生静默打开动作")
        } catch let error as ChatAttachmentOpenError {
            #expect(error == .unavailable)
        } catch {
            Issue.record("应返回 ChatAttachmentOpenError.unavailable，实际为 \(error)")
        }
    }

    @Test func externalOpenUsesInjectedActionAndResolvedFileURL() throws {
        let source = try makeTempFile(name: "report.txt", data: Data("report".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let attachment = ChatAttachment(
            kind: .text,
            fileName: "report.txt",
            fileType: .text,
            fileURL: source.absoluteString
        )
        var openedURL: URL?
        let opener = ChatAttachmentExternalOpener(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/TextEdit.app") },
            openAction: { url in
                openedURL = url
                return true
            }
        )

        let resolved = try opener.open(attachment)

        #expect(resolved == source)
        #expect(openedURL == source)
    }

    @Test func externalOpenPreservesTildePathCompatibility() throws {
        let rawPath = "~/Documents/MinisCanvas-attachment.txt"
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MinisCanvas-attachment.txt")
            .standardizedFileURL

        #expect(ChatAttachmentOpenTarget.sourceURL(from: rawPath) == expected)
    }

    @Test func externalOpenReportsPermissionFailureBeforeCallingSystem() throws {
        let source = try makeTempFile(name: "private.txt", data: Data("private".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "private.txt",
            fileType: .text,
            fileURL: source.path
        )
        var didAttemptOpen = false
        let opener = ChatAttachmentExternalOpener(
            isReadable: { _ in false },
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/TextEdit.app") },
            openAction: { _ in
                didAttemptOpen = true
                return true
            }
        )

        do {
            _ = try opener.open(attachment)
            Issue.record("不可读附件不应进入系统打开动作")
        } catch let error as ChatAttachmentOpenError {
            #expect(error == .permissionDenied)
            #expect(!didAttemptOpen)
        }
    }

    @Test func externalOpenReportsMissingApplicationWithoutSilentNoOp() throws {
        let source = try makeTempFile(name: "unknown.bin", data: Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "unknown.bin",
            fileType: .unknown,
            fileURL: source.path
        )
        var didAttemptOpen = false
        let opener = ChatAttachmentExternalOpener(
            applicationResolver: { _ in nil },
            openAction: { _ in
                didAttemptOpen = true
                return true
            }
        )

        do {
            _ = try opener.open(attachment)
            Issue.record("没有系统打开器时不应静默成功")
        } catch let error as ChatAttachmentOpenError {
            #expect(error == .noApplication)
            #expect(!didAttemptOpen)
        }
    }

    @Test func externalOpenReportsSystemActionFailure() throws {
        let source = try makeTempFile(name: "failed.txt", data: Data("failed".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "failed.txt",
            fileType: .text,
            fileURL: source.path
        )
        let opener = ChatAttachmentExternalOpener(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/TextEdit.app") },
            openAction: { _ in false }
        )

        do {
            _ = try opener.open(attachment)
            Issue.record("系统打开动作返回失败时不应静默成功")
        } catch let error as ChatAttachmentOpenError {
            #expect(error == .externalOpenFailed)
        }
    }

    @Test func externalOpenPreservesRecoveryDataWhenOriginalURLIsGone() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e11-external-open-root-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let attachment = ChatAttachment(
            kind: .image,
            fileName: "restored.png",
            fileType: .image,
            data: e11PngData,
            fileURL: "file:///path/that/no-longer-exists/restored.png"
        )
        var openedURL: URL?
        let opener = ChatAttachmentExternalOpener(
            temporaryDirectory: tempRoot,
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Preview.app") },
            openAction: { url in
                openedURL = url
                return true
            }
        )

        let resolved = try opener.open(attachment)

        #expect(resolved == openedURL)
        #expect(resolved.lastPathComponent == "restored.png")
        #expect(try Data(contentsOf: resolved) == e11PngData)
    }
}

// MARK: - ChatStore 附件添加

@Suite("E11 附件添加与发送")
@MainActor
struct AttachmentStoreTests {
    @Test func addImageMarkdownAndBinary() async throws {
        let chat = ChatStore()
        let pngURL = try makeTempFile(name: "cat.png", data: e11PngData)
        let mdURL = try makeTempFile(name: "notes.md", data: Data("# 标题\n\n正文内容".utf8))
        let binURL = try makeTempFile(name: "blob.bin", data: Data([0x00, 0x01]))
        defer {
            for url in [pngURL, mdURL, binURL] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        chat.addAttachments(urls: [pngURL, mdURL, binURL])
        #expect(chat.pendingAttachments.count == 3)
        // 图片/markdown 数据由后台线程读取升级（卡顿专项异步化），等待就绪
        var attachWaited: TimeInterval = 0
        while (chat.pendingAttachments[0].data == nil || chat.pendingAttachments[1].data == nil) && attachWaited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            attachWaited += 0.05
        }

        // 图片：原始字节 + mime
        let image = chat.pendingAttachments[0]
        #expect(image.kind == .image)
        #expect(image.mimeType == "image/png")
        #expect(image.data == e11PngData)
        #expect(image.imageAttachment != nil)

        // markdown：内容注入（text 类）
        let md = chat.pendingAttachments[1]
        #expect(md.kind == .text)
        #expect(md.fileType == .markdown)
        #expect(String(data: md.data!, encoding: .utf8)?.contains("正文内容") == true)

        // 未知二进制：文件引用
        let bin = chat.pendingAttachments[2]
        #expect(bin.kind == .file)
        #expect(bin.fileURL == binURL.path)

        // 移除
        chat.removePendingAttachment(id: image.id)
        #expect(chat.pendingAttachments.count == 2)
        chat.clearPendingAttachments()
        #expect(chat.pendingAttachments.isEmpty)
    }

    @Test func oversizedTextAttachmentIsCapped() async throws {
        let chat = ChatStore()
        let long = String(repeating: "a", count: 10_000)
        let txtURL = try makeTempFile(name: "long.txt", data: Data(long.utf8))
        defer { try? FileManager.default.removeItem(at: txtURL.deletingLastPathComponent()) }

        chat.addAttachments(urls: [txtURL])
        // 文本数据由后台线程读取升级（卡顿专项异步化），等待就绪
        var waited: TimeInterval = 0
        while chat.pendingAttachments.first?.data == nil && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        let att = try #require(chat.pendingAttachments.first)
        #expect(att.kind == .text)
        let body = try #require(att.data)
        #expect(body.count <= ChatStore.maxTextAttachmentChars)
    }

    @Test func composeUserContentCombinesTextAndAttachments() async throws {
        let txtURL = try makeTempFile(name: "readme.md", data: Data("# Readme\n\nhello world".utf8))
        let binURL = try makeTempFile(name: "report.pdf", data: Data("%PDF-1.4 fake".utf8))
        defer {
            for url in [txtURL, binURL] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        let chat = ChatStore()
        chat.addAttachments(urls: [txtURL, binURL])
        // 文本数据由后台线程读取升级（卡顿专项异步化），等待就绪
        var waited: TimeInterval = 0
        while chat.pendingAttachments.first?.data == nil && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        let attachments = chat.pendingAttachments

        // 文本注入 + 用户文字
        let content = ChatStore.composeUserContent(text: "请总结", attachments: attachments)
        #expect(content.contains("请总结"))
        #expect(content.contains("我上传了文件 readme.md"))
        #expect(content.contains("hello world"))
        #expect(content.contains("file_read"))

        // 纯图片：说明已附加
        let imgAtt = ChatAttachment(kind: .image, fileName: "cat.png", fileType: .image,
                                    mimeType: "image/png", data: e11PngData)
        let imgContent = ChatStore.composeUserContent(text: "", attachments: [imgAtt])
        #expect(imgContent.contains("我上传了图片 cat.png"))
    }

    @Test func sendDraftWithAttachmentOnlySends() async throws {
        let chat = ChatStore()
        let pngURL = try makeTempFile(name: "cat.png", data: e11PngData)
        defer { try? FileManager.default.removeItem(at: pngURL.deletingLastPathComponent()) }

        chat.addAttachments(urls: [pngURL])
        // 附件数据由后台线程读取升级（卡顿专项异步化），等待就绪再发送
        var attachWaited: TimeInterval = 0
        while chat.pendingAttachments.first?.data == nil && attachWaited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            attachWaited += 0.05
        }
        #expect(chat.pendingAttachments.first?.kind == .image)
        // 无文本也可发送（附件触发）
        chat.sendDraft()

        #expect(chat.pendingAttachments.isEmpty)
        let userMsg = chat.messages.last(where: { $0.role == .user })
        #expect(userMsg?.content.contains("我上传了图片 cat.png") == true)
        #expect(userMsg?.attachments.count == 1)
        #expect(userMsg?.llmImages.count == 1)
        #expect(userMsg?.llmImages.first?.data == e11PngData)

        // 等待 Mock 流式完成
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.role == .assistant)
    }

    @Test func attachmentIdentityAndSessionBoundariesRejectStaleWriteback() async throws {
        let chat = ChatStore()
        let firstURL = try makeTempFile(
            name: "first.txt",
            data: Data(String(repeating: "first ", count: 250_000).utf8)
        )
        let secondURL = try makeTempFile(name: "second.txt", data: Data("second".utf8))
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        chat.addAttachments(urls: [firstURL, secondURL])
        let firstID = try #require(chat.pendingAttachments.first?.id)
        chat.removePendingAttachment(id: firstID)
        var waited: TimeInterval = 0
        while chat.pendingAttachments.first?.data == nil && waited < 5 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        let remaining = try #require(chat.pendingAttachments.first)
        #expect(remaining.fileName == "second.txt")
        #expect(String(data: remaining.data ?? Data(), encoding: .utf8) == "second")

        chat.clearPendingAttachments()
        chat.addAttachments(urls: [secondURL])
        let firstSessionID = try #require(chat.activeSessionID)
        chat.newSession()
        #expect(chat.pendingAttachments.isEmpty)
        chat.switchSession(id: firstSessionID)
        #expect(chat.pendingAttachments.count == 1)
        #expect(chat.pendingAttachments.first?.fileName == "second.txt")
    }

    @Test func duplicateRestoreAndDeleteBoundariesClearPendingAttachments() throws {
        let chat = ChatStore()
        let firstID = try #require(chat.activeSessionID)
        let fileURL = try makeTempFile(name: "boundary.bin", data: Data([0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        chat.addAttachments(urls: [fileURL])
        _ = chat.duplicateSession(id: firstID)
        #expect(chat.pendingAttachments.isEmpty)

        chat.addAttachments(urls: [fileURL])
        let archivedID = try #require(chat.sessions.first(where: { $0.id != chat.activeSessionID })?.id)
        chat.archiveSession(id: archivedID)
        chat.addAttachments(urls: [fileURL])
        chat.restoreSession(id: archivedID)
        #expect(chat.pendingAttachments.count == 1)
        #expect(chat.pendingAttachments.first?.fileName == "boundary.bin")
    }

    @Test func messageCodableBackwardCompatible() throws {
        // 旧持久化 JSON（无 attachments 键）仍可解码
        let oldJSON = """
        {"id":"\(UUID().uuidString)","role":"user","content":"旧消息",
         "isStreaming":false,"timestamp":\(Date().timeIntervalSinceReferenceDate)}
        """
        let decoded = try JSONDecoder().decode(ChatMessageUI.self, from: Data(oldJSON.utf8))
        #expect(decoded.content == "旧消息")
        #expect(decoded.attachments.isEmpty)

        // 带附件往返
        let att = ChatAttachment(kind: .image, fileName: "cat.png", fileType: .image,
                                 mimeType: "image/png", data: e11PngData)
        let msg = ChatMessageUI(role: .user, content: "图", attachments: [att])
        let data = try JSONEncoder().encode(msg)
        let round = try JSONDecoder().decode(ChatMessageUI.self, from: data)
        #expect(round.attachments.count == 1)
        #expect(round.attachments.first?.data == e11PngData)
    }
}

// MARK: - 附件缩略图（限幅解码 + NSCache，防主线程卡死）

@Suite("E11 附件缩略图（AttachmentThumbnailer）")
@MainActor
struct AttachmentThumbnailTests {
    /// 生成宽高像素的真实大图 PNG Data（用于验证限幅解码）
    private func makeLargePNGData(pixelsWide: Int, pixelsHigh: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        let image = ctx.makeImage()!
        let mutable = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return mutable as Data
    }

    @Test func thumbnailCachesAndReturnsSameInstance() {
        // 同一附件两次取缩略图：命中缓存返回同一实例（防 body 重算反复解码）
        let att = ChatAttachment(kind: .image, fileName: "cat.png", fileType: .image,
                                 mimeType: "image/png", data: e11PngData)
        let first = AttachmentThumbnailer.thumbnail(for: att)
        #expect(first != nil)
        let second = AttachmentThumbnailer.thumbnail(for: att)
        #expect(second === first)
        // 非图片附件 → nil（调用方显示图标占位）
        let text = ChatAttachment(kind: .text, fileName: "b.md", fileType: .markdown,
                                  data: Data("hi".utf8))
        #expect(AttachmentThumbnailer.thumbnail(for: text) == nil)
        // 无数据图片附件 → nil
        let noData = ChatAttachment(kind: .image, fileName: "gone.png", fileType: .image)
        #expect(AttachmentThumbnailer.thumbnail(for: noData) == nil)
    }

    @Test func thumbnailRejectsTextDataDisguisedAsImage() {
        // 文本内容伪装图片 data：CGImageSource 只读文件头即拒绝
        // （旧实现 NSImage(data:) 会主线程全量解码后才发现不可读 —— 卡死根因回归防护）
        let fake = ChatAttachment(kind: .image, fileName: "fake.png", fileType: .image,
                                  mimeType: "image/png", data: Data("not an image at all".utf8))
        #expect(AttachmentThumbnailer.thumbnail(for: fake) == nil)
    }

    @Test func thumbnailDownscalesLargeImage() throws {
        // 4000×3000 大图 data：限幅解码后最大边 ≤ thumbnailMaxPixel（1024），
        // 内存/耗时随最大边平方级下降（旧实现全分辨率解码 ≈48MB 位图）
        let data = makeLargePNGData(pixelsWide: 4000, pixelsHigh: 3000)
        let att = ChatAttachment(kind: .image, fileName: "big.png", fileType: .image,
                                 mimeType: "image/png", data: data)
        let image = try #require(AttachmentThumbnailer.thumbnail(for: att))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(cg.width, cg.height) <= Int(AttachmentThumbnailer.thumbnailMaxPixel))
        #expect(cg.width == 1024)  // 4000→1024 等比（高度 768）
        #expect(cg.height == 768)
    }
}

// MARK: - 引擎多模态贯通（images 随 LLMMessage 送达 Provider）

@Suite("E11 引擎多模态贯通")
struct EngineMultimodalTests {
    private func imageHistory() -> [ChatMessageUI] {
        let att = ChatAttachment(kind: .image, fileName: "cat.png", fileType: .image,
                                 mimeType: "image/png", data: e11PngData)
        return [ChatMessageUI(role: .user, content: "看图", attachments: [att])]
    }

    @Test func fallbackEngineDeliversImages() async throws {
        let recorder = RecordingProvider()
        let engine = FallbackChatEngine()
        let stream = try await engine.streamReply(
            provider: recorder, history: imageHistory(),
            systemPrompt: "test", maxTokens: 1024
        )
        for try await _ in stream {}
        let user = recorder.lastMessages.first { $0.role == .user }
        #expect(user?.images.count == 1)
        #expect(user?.images.first?.mimeType == "image/png")
        #expect(user?.images.first?.data == e11PngData)
    }

    @Test func agentLoopEngineDeliversImages() async throws {
        let recorder = RecordingProvider()
        let engine = AgentLoopChatEngine()
        let stream = try await engine.streamReply(
            provider: recorder, history: imageHistory(),
            systemPrompt: "test", maxTokens: 1024,
            conversationID: "e11-agent-loop",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )
        for try await _ in stream {}
        let user = recorder.lastMessages.first { $0.role == .user }
        #expect(user?.images.count == 1)
        #expect(user?.images.first?.data == e11PngData)
    }
}

// MARK: - P3-MEDIA-01 ownership and recovery

@Suite("P3-MEDIA-01 附件归属恢复")
struct P3MediaAttachmentOwnershipTests {
    @Test("attachment sidecar save enforces budget and preserves old bytes")
    func attachmentSidecarSavePreservesOldBytesOnRejection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-sidecar-save-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let small = ChatAttachment(
            kind: .text,
            fileName: "small.txt",
            fileType: .text,
            data: Data("stable".utf8)
        )
        let source = ChatThread(
            id: UUID(),
            messages: [ChatMessageUI(role: .user, content: "保留", attachments: [small])]
        )
        try ChatAttachmentPersistence.save(sessions: [source], to: root)
        let sidecar = ChatAttachmentPersistence.url(in: root)
        let original = try Data(contentsOf: sidecar)

        // A target replacement is rejected before the atomic rename and the
        // symlink destination remains byte-for-byte unchanged.
        let target = root.appendingPathComponent("sidecar-target.json")
        try FileManager.default.moveItem(at: sidecar, to: target)
        try FileManager.default.createSymbolicLink(
            atPath: sidecar.path,
            withDestinationPath: target.path
        )
        #expect(throws: NSError.self) {
            try ChatAttachmentPersistence.save(sessions: [source], to: root)
        }
        #expect(try Data(contentsOf: target) == original)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.moveItem(at: target, to: sidecar)

        // The encoded envelope is rejected before touching the existing file.
        let oversizedData = Data(repeating: 0x41, count: 6_300_000)
        let oversized = ChatAttachment(
            kind: .file,
            fileName: "oversized.bin",
            fileType: .unknown,
            size: Int64(oversizedData.count),
            data: oversizedData
        )
        let oversizedSource = ChatThread(
            id: UUID(),
            messages: [ChatMessageUI(role: .user, content: "过大", attachments: [oversized])]
        )
        #expect(throws: NSError.self) {
            try ChatAttachmentPersistence.save(sessions: [oversizedSource], to: root)
        }
        #expect(try Data(contentsOf: sidecar) == original)
    }

    @Test("attachment sidecar accepts the exact 8 MiB format boundary")
    func attachmentSidecarAcceptsExactFormatBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-sidecar-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = Data(#"{"schemaVersion":1,"sessions":[]}"#.utf8)
        let boundary = prefix + Data(repeating: 0x20, count: 8 * 1024 * 1024 - prefix.count)
        try boundary.write(to: ChatAttachmentPersistence.url(in: root))

        #expect(boundary.count == 8 * 1024 * 1024)
        #expect(try ChatAttachmentPersistence.load(from: root).isEmpty)
    }

    @Test("attachment sidecar keeps per-session ownership separate")
    func attachmentSidecarPreservesPerSessionOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-sidecar-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstAttachment = ChatAttachment(
            kind: .text,
            fileName: "first.txt",
            fileType: .text,
            data: Data("first".utf8)
        )
        let secondAttachment = ChatAttachment(
            kind: .text,
            fileName: "second.txt",
            fileType: .text,
            data: Data("second".utf8)
        )
        let first = ChatThread(
            id: UUID(),
            messages: [ChatMessageUI(role: .user, content: "第一会话", attachments: [firstAttachment])]
        )
        let second = ChatThread(
            id: UUID(),
            messages: [ChatMessageUI(role: .user, content: "第二会话", attachments: [secondAttachment])]
        )

        try ChatAttachmentPersistence.save(sessions: [first, second], to: root)
        let records = try ChatAttachmentPersistence.load(from: root)
        #expect(records.count == 2)
        #expect(records[first.id.uuidString]?.first?.attachments == [firstAttachment])
        #expect(records[second.id.uuidString]?.first?.attachments == [secondAttachment])
    }

    @Test("attachment sidecar load is bounded and rejects symlinks")
    func attachmentSidecarLoadUsesStableBoundedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-sidecar-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A normal envelope remains readable, and a missing sidecar keeps the
        // legacy empty result.
        try ChatAttachmentPersistence.save(sessions: [], to: root)
        #expect(try ChatAttachmentPersistence.load(from: root).isEmpty)
        try FileManager.default.removeItem(at: ChatAttachmentPersistence.url(in: root))
        #expect(try ChatAttachmentPersistence.load(from: root).isEmpty)

        // The loader must inspect the directory entry without following a
        // symlink, even when the destination is a valid sidecar.
        let target = root.appendingPathComponent("sidecar-target.json")
        try Data(#"{"schemaVersion":1,"sessions":[]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: ChatAttachmentPersistence.url(in: root).path,
            withDestinationPath: target.path
        )
        #expect(throws: NSError.self) {
            try ChatAttachmentPersistence.load(from: root)
        }
        try FileManager.default.removeItem(at: ChatAttachmentPersistence.url(in: root))

        // The project persisted-state budget is enforced before JSON decode.
        let oversized = Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: ChatAttachmentPersistence.url(in: root))
        #expect(throws: NSError.self) {
            try ChatAttachmentPersistence.load(from: root)
        }
    }

    @Test("generic attachment ownership survives Core transcript round-trip")
    func genericAttachmentOwnershipReopensWithMessage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-closure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attachment = ChatAttachment(
            kind: .text,
            fileName: "brief.md",
            fileType: .markdown,
            mimeType: "text/markdown",
            size: 12,
            data: Data("恢复正文".utf8),
            fileURL: root.appendingPathComponent("brief.md").path
        )
        let source = ChatThread(
            id: UUID(),
            messages: [
                ChatMessageUI(role: .user, content: "请预览", attachments: [attachment]),
                ChatMessageUI(role: .assistant, content: "已收到")
            ]
        )
        try ChatAttachmentPersistence.save(sessions: [source], to: root)
        let records = try ChatAttachmentPersistence.load(from: root)
        let reopened = ChatAttachmentPersistence.restoreAttachments(
            from: source.asPersisted(),
            records: records[source.id.uuidString]
        )

        #expect(reopened.messages.first?.attachments == [attachment])
        #expect(reopened.messages.first?.displayContent == "请预览")
        #expect(ChatAttachmentOpenTarget.canOpen(attachment))
    }

    @Test("attachment ownership digest fence rejects stale transcript position")
    func staleAttachmentOwnershipDoesNotRebind() throws {
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "report.pdf",
            fileType: .unknown,
            size: 8,
            fileURL: "/missing/report.pdf"
        )
        let source = ChatThread(
            id: UUID(),
            messages: [ChatMessageUI(role: .user, content: "原始消息", attachments: [attachment])]
        )
        let records = [ChatAttachmentPersistence.records(for: source).messages[0]]
        let edited = MinisCore.ChatSession(
            id: source.id.uuidString,
            messages: [LLMMessage(role: .user, content: "已编辑消息")]
        )

        let reopened = ChatAttachmentPersistence.restoreAttachments(from: edited, records: records)

        #expect(reopened.messages.first?.attachments.isEmpty == true)
    }
}

@Suite("P3-MEDIA-01 ChatStore persistence wiring")
@MainActor
struct P3MediaChatStorePersistenceTests {
    @Test("sent attachment reopens after its source file disappears")
    func sentAttachmentReopensFromAtomicOwnershipSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-chat-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MinisCore.SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sourceURL = root.appendingPathComponent("source.md")
        try Data("可恢复".utf8).write(to: sourceURL)
        let attachment = ChatAttachment(
            kind: .text,
            fileName: "source.md",
            fileType: .markdown,
            data: Data("可恢复".utf8),
            fileURL: sourceURL.path
        )
        chat.appendUser(ChatStore.composeUserContent(text: "打开它", attachments: [attachment]), attachments: [attachment])

        // Simulate restart and a deleted original source. The sidecar keeps
        // the message-owned bytes/name, while OpenTarget materializes safely.
        try FileManager.default.removeItem(at: sourceURL)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(store))
        // ChatStore starts every new conversation with its product welcome
        // assistant message. The sent attachment belongs to the later user
        // message, so select that message by its stable display semantics
        // instead of assuming it is the transcript's first entry.
        let restoredAttachment = try #require(
            reopened.messages.first(where: {
                $0.role == .user && $0.displayContent == "打开它"
            })?.attachments.first
        )
        #expect(restoredAttachment.id == attachment.id)
        #expect(restoredAttachment.data == attachment.data)
        #expect(ChatAttachmentOpenTarget.canOpen(restoredAttachment))
    }
}

@Suite("P3-MEDIA-01 附件来源状态")
struct P3MediaAttachmentSourceStateTests {
    @Test("source state distinguishes existing, materializable, and unavailable")
    func sourceStateIsExplicitAndPathFree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-source-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready.txt")
        try Data("ready".utf8).write(to: source)

        let ready = ChatAttachment(
            kind: .file,
            fileName: "ready.txt",
            fileType: .text,
            fileURL: source.path
        )
        let materializable = ChatAttachment(
            kind: .file,
            fileName: "restored.txt",
            fileType: .text,
            data: Data("restored".utf8),
            fileURL: root.appendingPathComponent("gone.txt").path
        )
        let unavailable = ChatAttachment(
            kind: .file,
            fileName: "missing.txt",
            fileType: .text,
            fileURL: root.appendingPathComponent("missing.txt").path
        )

        #expect(ChatAttachmentOpenTarget.sourceState(for: ready) == .sourceAvailable)
        #expect(ChatAttachmentOpenTarget.sourceState(for: materializable) == .missingSourceMaterializable)
        #expect(ChatAttachmentOpenTarget.sourceState(for: unavailable) == .unavailable)
        #expect(ChatAttachmentOpenTarget.sourceState(for: materializable).statusText.contains("restored.txt") == false)
        #expect(ChatAttachmentOpenTarget.sourceState(for: materializable).statusText.contains(root.path) == false)
    }

    @Test("materializable state resolves to a safe temporary file")
    func materializableStateMaterializesWithoutPathTraversal() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-media-materialize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let attachment = ChatAttachment(
            kind: .file,
            fileName: "../restored.txt",
            fileType: .text,
            data: Data("restored".utf8),
            fileURL: "/missing/restored.txt"
        )

        #expect(ChatAttachmentOpenTarget.sourceState(for: attachment) == .missingSourceMaterializable)
        let resolved = try ChatAttachmentOpenTarget(temporaryDirectory: temporaryRoot).resolve(attachment)
        #expect(resolved.path.hasPrefix(temporaryRoot.path))
        #expect(resolved.lastPathComponent == "restored.txt")
        #expect(try Data(contentsOf: resolved) == attachment.data)
    }
}

@Suite("O08 producer text source compatibility")
@MainActor
struct ProducerTextSourceCompatibilityTests {
    @Test func actualCanonicalSidecarRestoresNewCountsAndMissingLegacyRemainsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachment = ChatAttachment(kind: .text, fileName: "owned.txt", fileType: .text,
            data: Data("owned text source".utf8))
        let composed = ChatStore.composeUserContentWithOwnership(text: "owned instruction", attachments: [attachment])
        #expect(composed.textSourceCount == 1)
        let source = ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: composed.content, attachments: [attachment],
                producerTextAttachmentCount: composed.textSourceCount),
            ChatMessageUI(role: .user, content: "no attachment", producerTextAttachmentCount: 0)
        ])
        let canonical = source.asPersisted()
        try ChatAttachmentPersistence.save(sessions: [source], to: root)
        let loaded = try ChatAttachmentPersistence.load(from: root)
        let reopened = ChatAttachmentPersistence.restoreAttachments(from: canonical, records: loaded[source.id.uuidString])
        #expect(reopened.messages.map(\.producerTextAttachmentCount) == [1, 0])
        #expect(reopened.asPersisted().messages == canonical.messages, "classification must not alter Provider/Core bytes")
        // Exercise the actual sidecar loader with the pre-field shape, including
        // its real envelope/version/index/content-digest checks.
        let url = ChatAttachmentPersistence.url(in: root)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var sessions = try #require(json["sessions"] as? [[String: Any]])
        var messages = try #require(sessions[0]["messages"] as? [[String: Any]])
        for index in messages.indices {
            messages[index].removeValue(forKey: "producerTextAttachmentCount")
            messages[index]["unknownFutureDisplayField"] = "ignored by the existing Codable decoder"
        }
        sessions[0]["messages"] = messages; json["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let legacy = try ChatAttachmentPersistence.load(from: root)
        let legacyThread = ChatAttachmentPersistence.restoreAttachments(from: canonical, records: legacy[source.id.uuidString])
        #expect(legacyThread.messages.allSatisfy { $0.producerTextAttachmentCount == nil })
        #expect(legacyThread.asPersisted().messages == canonical.messages)
        let encoded = try JSONEncoder().encode(source.messages[0])
        var messageJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        messageJSON.removeValue(forKey: "producerTextAttachmentCount")
        let oldMessage = try JSONDecoder().decode(ChatMessageUI.self,
            from: JSONSerialization.data(withJSONObject: messageJSON))
        #expect(oldMessage.producerTextAttachmentCount == nil)
        #expect(try JSONDecoder().decode(ChatMessageUI.self, from: encoded).producerTextAttachmentCount == 1)
    }

    @Test func invalidOrMismatchedProducerCountsAreNeverReportedAsZero() throws {
        let source = ChatThread(id: UUID(), messages: [
            ChatMessageUI(role: .user, content: "owned", producerTextAttachmentCount: -1)
        ])
        let records = ChatAttachmentPersistence.records(for: source).messages
        let restored = ChatAttachmentPersistence.restoreAttachments(from: source.asPersisted(), records: records)
        #expect(restored.messages[0].producerTextAttachmentCount == nil)
        let edited = ChatThread(id: source.id, messages: [ChatMessageUI(role: .user, content: "edited")])
        let mismatch = ChatAttachmentPersistence.restoreAttachments(from: edited.asPersisted(), records: records)
        #expect(mismatch.messages[0].producerTextAttachmentCount == nil)
    }
}
