import AVFoundation
import AppKit
import Foundation
import ImageIO
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 附件转码接入：图片（HEIC/TIFF → PNG/JPEG）、音频（caf → WAV）、富文本文档提取、
/// 路径引用提示与截断说明。样本全部合成；HEIC 编码依赖本机 ImageIO（不可用时 #require 失败，不静默跳过）。
@Suite("Attachment conversion intake 3300", .serialized)
@MainActor
struct AttachmentConversionIntake3300Tests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv3300-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rasterImage(type: String, width: Int = 64, height: Int = 48) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func settle(_ chat: ChatStore) async throws -> ChatAttachment {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(chat.pendingAttachments.first)
    }

    private func store() throws -> ChatStore {
        let defaults = try #require(UserDefaults(suiteName: "conv3300-\(UUID())"))
        return ChatStore(preferencesDefaults: defaults)
    }

    // MARK: image

    @Test("HEIC is converted in the background to a PNG/JPEG attachment and the user is told")
    func heicIsConverted() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.heic")
        try rasterImage(type: "public.heic").write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let ready = try await settle(chat)
        #expect(ready.status == .ready && ready.kind == .image)
        #expect(["image/png", "image/jpeg"].contains(ready.mimeType ?? ""))
        let data = try #require(ready.data)
        #expect(MediaPayloadValidation.failure(data: data, mimeType: ready.mimeType ?? "") == nil)
        #expect(chat.pastedTextActionFeedback?.contains("已将 photo.heic 自动转换为") == true)
    }

    // MC4-019：两帧 GIF 改名成 .jpg，按实际帧数仍提示只取首帧。
    @Test("a two-frame GIF named .jpg still tells the user only the first frame is used")
    func animatedGifNamedJpgReportsFirstFrameOnly() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let single = try rasterImage(type: "com.compuserve.gif")
        #expect(ChatStore.imageFrameCount(single) == 1)
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let frame = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        CGImageDestinationAddImage(destination, frame, nil)
        try #require(CGImageDestinationFinalize(destination))
        #expect(ChatStore.imageFrameCount(data as Data) == 2)
        let url = dir.appendingPathComponent("fake.jpg")
        try (data as Data).write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let ready = try await settle(chat)
        #expect(ready.status == .ready)
        #expect(chat.pastedTextActionFeedback?.contains("只取首帧") == true)
    }

    @Test("TIFF is converted and a PNG under the limit is passed through unchanged")
    func tiffConvertedPngUntouched() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tiff = dir.appendingPathComponent("scan.tiff")
        try rasterImage(type: "public.tiff").write(to: tiff)
        let png = dir.appendingPathComponent("plain.png")
        let pngData = try rasterImage(type: "public.png")
        try pngData.write(to: png)
        let chat = try store()
        chat.addAttachments(urls: [tiff])
        let converted = try await settle(chat)
        #expect(converted.status == .ready && ["image/png", "image/jpeg"].contains(converted.mimeType ?? ""))
        chat.clearPendingAttachments()
        chat.addAttachments(urls: [png])
        let same = try await settle(chat)
        #expect(same.status == .ready && same.data == pngData && same.mimeType == "image/png")
    }

    @Test("F-07: a small PNG whose long edge is over 2000 is transcoded, one at 2000 passes through")
    func pngOverTwoThousandPixelsIsTranscoded() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("retina.png")
        let bigData = try rasterImage(type: "public.png", width: 3000, height: 1500)
        #expect(bigData.count <= ChatStore.maxUploadImageBytes)
        try bigData.write(to: big)
        let edge = dir.appendingPathComponent("edge.png")
        let edgeData = try rasterImage(type: "public.png", width: 2000, height: 1000)
        try edgeData.write(to: edge)
        let chat = try store()
        chat.addAttachments(urls: [big])
        let converted = try await settle(chat)
        #expect(converted.status == .ready)
        let convertedData = try #require(converted.data)
        #expect(convertedData != bigData)
        let size = try #require(MediaConversion.imagePixelSize(convertedData))
        #expect(max(size.width, size.height) <= ChatStore.uploadImageMaxPixel)
        chat.clearPendingAttachments()
        chat.addAttachments(urls: [edge])
        let same = try await settle(chat)
        #expect(same.status == .ready && same.data == edgeData)
    }

    @Test("an undecodable image with a non-PNG name fails with a Chinese reason that offers path reference")
    func undecodableImageFails() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.bmp")
        try Data("not an image".utf8).write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let failed = try await settle(chat)
        #expect(failed.status == .failed)
        #expect(failed.failureReason?.contains("自动转换失败") == true)
        #expect(ChatStore.composerFailedAttachmentReason(for: failed).contains("可改为路径引用"))
    }

    @Test("validation wording tells the user about automatic conversion")
    func validationWordingMentionsConversion() {
        #expect(MediaPayloadValidation.Failure.unsupportedImageFormat.reason.contains("自动转换"))
        #expect(MediaPayloadValidation.Failure.unsupportedAudioFormat.reason.contains("自动转换为 WAV"))
        #expect(ChatStore.imageConversionFailureReason(.outputTooLarge).contains("5 MB"))
    }

    // MARK: audio

    @Test("caf audio is converted to a WAV attachment; ogg reports it cannot be converted")
    func audioConversion() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("clip.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: caf, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = 4_410
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<4_410 { samples[index] = sinf(Float(index) * 0.05) * 0.3 }
            try file.write(from: buffer)
        }
        let chat = try store()
        chat.addAttachments(urls: [caf])
        let ready = try await settle(chat)
        #expect(ready.status == .ready && ready.kind == .audio && ready.mimeType == "audio/wav")
        let wav = try #require(ready.data)
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/wav") == nil)
        #expect(chat.pastedTextActionFeedback?.contains("自动转换为 WAV") == true)

        let ogg = dir.appendingPathComponent("voice.ogg")
        try Data("OggS-synthetic".utf8).write(to: ogg)
        chat.clearPendingAttachments()
        chat.addAttachments(urls: [ogg])
        let failed = try await settle(chat)
        #expect(failed.status == .failed)
        #expect(failed.failureReason == ChatStore.audioConversionFailureReason(.unsupportedFormat))
        #expect(ChatStore.composerFailedAttachmentReason(for: failed).contains("无法转换"))
        #expect(ChatStore.composerFailedAttachmentReason(for: failed).contains("可改为路径引用"))
    }

    // MARK: rich documents

    private func richData(_ type: NSAttributedString.DocumentType, text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        return try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                   documentAttributes: [.documentType: type])
    }

    @Test("docx and rtf are extracted to text attachments; the prompt never says file_read can open them")
    func richDocumentsInjectAsText() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for (name, type) in [("report.docx", NSAttributedString.DocumentType.officeOpenXML),
                             ("memo.rtf", .rtf)] {
            let url = dir.appendingPathComponent(name)
            try richData(type, text: "季度总结：营收增长 12%").write(to: url)
            let chat = try store()
            chat.addAttachments(urls: [url])
            let ready = try await settle(chat)
            #expect(ready.status == .ready && ready.kind == .text, "\(name)")
            #expect(ready.mimeType == ChatStore.extractedDocumentMimeType)
            let content = ChatStore.composeUserContent(text: "", attachments: [ready])
            #expect(content.contains("营收增长 12%"))
            #expect(content.contains("已提取为纯文本"))
            #expect(!content.contains("file_read"))
        }
    }

    @Test("html is injected as source text so the model sees the markup")
    func htmlIsInjectedAsSource() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("page.html")
        try Data("<html><body><h1>标题</h1><p>正文段落</p><script>var x=1;</script></body></html>".utf8).write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let ready = try await settle(chat)
        let body = String(data: try #require(ready.data), encoding: .utf8) ?? ""
        #expect(body.contains("<h1>标题</h1>") && body.contains("正文段落"))
        #expect(ready.mimeType != ChatStore.extractedDocumentMimeType)
    }

    @Test("a long document keeps the first 60000 characters with a 'full text is long' note and chip notice")
    func longDocumentTruncation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.rtf")
        try richData(.rtf, text: String(repeating: "字", count: 80_000)).write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let ready = try await settle(chat)
        let body = String(data: try #require(ready.data), encoding: .utf8) ?? ""
        #expect(body.contains("全文较长，已截取前 60000 字"))
        #expect(!body.contains("file_read"))
        #expect(ComposerAttachmentPresentation.truncationNotice(for: ready, sent: false)
                == "将发送前 60000 字，全文较长，其余未提取")
        #expect(ComposerAttachmentPresentation.status(for: ready) == .injectedAtCap)
    }

    @Test("a corrupt docx fails with a Chinese reason")
    func corruptDocxFails() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.docx")
        try Data("PK-not-really".utf8).write(to: url)
        let chat = try store()
        chat.addAttachments(urls: [url])
        let failed = try await settle(chat)
        #expect(failed.status == .failed)
        #expect(failed.failureReason?.contains("文档") == true)
    }

    // MARK: path reference hint and truncation notices

    @Test("xlsx path references say file_read cannot read binary Office files; text references keep file_read")
    func pathReferenceHints() {
        let sheet = ChatAttachment(kind: .file, fileName: "data.xlsx", fileType: .unknown, fileURL: "/tmp/data.xlsx")
        let sheetContent = ChatStore.composeUserContent(text: "", attachments: [sheet])
        #expect(sheetContent.contains("二进制 Office 文件，file_read 无法直接读取"))
        #expect(sheetContent.contains("shell 命令转换"))
        let text = ChatAttachment(kind: .file, fileName: "a.txt", fileType: .unknown, fileURL: "/tmp/a.txt")
        #expect(ChatStore.composeUserContent(text: "", attachments: [text]).contains("可用 file_read 工具读取该文件"))
        let zip = ChatAttachment(kind: .file, fileName: "a.zip", fileType: .unknown, fileURL: "/tmp/a.zip")
        let zipContent = ChatStore.composeUserContent(text: "", attachments: [zip])
        #expect(!zipContent.contains("可用 file_read 工具读取该文件") && zipContent.contains("unzip -l"))
    }

    @Test("truncation notices describe head+tail and estimated head-only injection")
    func truncationWording() {
        let long = String(repeating: "H", count: 48_000) + String(repeating: "x", count: 5_000) + String(repeating: "T", count: 12_000)
        let headTail = ChatStore.capTextForInjection(long)
        let a = ChatAttachment(kind: .text, fileName: "a.txt", fileType: .text,
            data: Data(headTail.utf8), originalTextCharacterCount: long.count)
        #expect(ComposerAttachmentPresentation.truncationNotice(for: a, sent: true)
                == "已发送开头 48000 字与结尾 12000 字，全文共 65000 字，中间部分已省略")
        let headOnly = ChatStore.capTextForInjection(String(repeating: "a", count: 70_000),
            sourceWasTruncated: true, estimatedTotalCharacters: 2_500_000)
        let b = ChatAttachment(kind: .text, fileName: "b.txt", fileType: .text,
            data: Data(headOnly.utf8), originalTextCharacterCount: 2_500_000)
        #expect(ComposerAttachmentPresentation.truncationNotice(for: b, sent: false)
                == "将发送开头 60000 字，全文约 2500000 字（按文件大小估算），其余未发送")
    }
}
