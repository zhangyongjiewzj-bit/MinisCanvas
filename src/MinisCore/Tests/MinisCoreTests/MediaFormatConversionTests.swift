import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import MinisCore

// Format-conversion primitives that let attachments the composer accepts but the
// send-time validator rejects (HEIC/GIF/TIFF/BMP images, m4a/aac/flac/aiff/caf
// audio, docx/rtf/odt/html documents) reach the model as PNG/JPEG, WAV and text.
// All samples are synthesized in-process; no fixtures.

// MARK: - Synthesis helpers

private func makeImage(width: Int, height: Int, alpha: Bool, noise: Bool = false) -> CGImage {
    let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise, let pixels = context.data {
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(context.bytesPerRow * height) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return context.makeImage()!
}

private func encode(_ images: [CGImage], type: String) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type as CFString, images.count, nil) else {
        return nil
    }
    for image in images { CGImageDestinationAddImage(destination, image, nil) }
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}

private func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

private func writeTone(
    to url: URL, fileType: String, seconds: Double, sampleRate: Double = 44_100,
    channels: AVAudioChannelCount = 2, settings: [String: Any]? = nil
) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
    }
    let fileSettings = settings ?? [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channels),
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: fileType == "aiff",
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        try file.write(from: buffer)
    }
}

private func temporaryAudioURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("minis-fmt-test-\(UUID().uuidString).\(ext)")
}

private func attributedData(_ text: String, type: NSAttributedString.DocumentType) throws -> Data {
    let attributed = NSAttributedString(string: text)
    let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
    if type == .rtfd {
        return try #require(attributed.rtfd(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
    }
    return try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: attributes)
}

// MARK: - Image

@Suite("MediaFormatConversion image")
struct MediaFormatConversionImageTests {
    @Test func opaqueTIFFBecomesJPEGWithinMaxPixel() throws {
        let tiff = try #require(encode([makeImage(width: 800, height: 400, alpha: false)], type: "public.tiff"))
        let result = try #require(try? MediaConversion.convertImageForUpload(tiff, maxBytes: 5_000_000, maxPixel: 200).get())
        #expect(result.mimeType == "image/jpeg")
        #expect(Array(result.data.prefix(2)) == [0xFF, 0xD8])
        let size = try #require(pixelSize(result.data))
        #expect(max(size.width, size.height) == 200)
        #expect(size.width == 200 && size.height == 100)
    }

    @Test func alphaBMPAndTIFFBecomePNG() throws {
        let image = makeImage(width: 64, height: 64, alpha: true)
        for type in ["public.tiff", "com.microsoft.bmp"] {
            let source = try #require(encode([image], type: type))
            let result = try #require(try? MediaConversion.convertImageForUpload(source, maxBytes: 5_000_000, maxPixel: 2048).get())
            #expect(result.mimeType == "image/png")
            #expect(Array(result.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        }
    }

    @Test func smallImageIsNeverUpscaled() throws {
        let tiff = try #require(encode([makeImage(width: 50, height: 30, alpha: false)], type: "public.tiff"))
        let result = try #require(try? MediaConversion.convertImageForUpload(tiff, maxBytes: 1_000_000, maxPixel: 2048).get())
        let size = try #require(pixelSize(result.data))
        #expect(size.width == 50 && size.height == 30)
    }

    @Test func heicConverts() throws {
        let heic = try #require(encode([makeImage(width: 256, height: 128, alpha: false)], type: "public.heic"))
        let result = try #require(try? MediaConversion.convertImageForUpload(heic, maxBytes: 1_000_000, maxPixel: 2048).get())
        #expect(result.mimeType == "image/jpeg")
        let size = try #require(pixelSize(result.data))
        #expect(size.width == 256 && size.height == 128)
    }

    @Test func animatedGIFUsesFirstFrame() throws {
        let red = makeImage(width: 32, height: 32, alpha: true)
        let blueContext = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        blueContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        blueContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let gif = try #require(encode([red, blueContext.makeImage()!], type: "com.compuserve.gif"))
        let result = try #require(try? MediaConversion.convertImageForUpload(gif, maxBytes: 1_000_000, maxPixel: 2048).get())
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let probe = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        probe.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = probe.data!.bindMemory(to: UInt8.self, capacity: 4)
        #expect(pixel[0] > 200 && pixel[2] < 60)
    }

    @Test func oversizedResultShrinksUntilItFits() throws {
        let noisy = try #require(encode([makeImage(width: 600, height: 600, alpha: false, noise: true)], type: "public.tiff"))
        let result = try #require(try? MediaConversion.convertImageForUpload(noisy, maxBytes: 20_000, maxPixel: 2048).get())
        #expect(result.data.count <= 20_000)
        let size = try #require(pixelSize(result.data))
        #expect(max(size.width, size.height) < 600)
    }

    @Test func impossibleBudgetFailsAsOutputTooLarge() throws {
        let noisy = try #require(encode([makeImage(width: 300, height: 300, alpha: false, noise: true)], type: "public.tiff"))
        guard case .failure(.outputTooLarge) = MediaConversion.convertImageForUpload(noisy, maxBytes: 50, maxPixel: 2048) else {
            Issue.record("expected .outputTooLarge")
            return
        }
    }

    @Test func invalidInputsFailAsUndecodable() {
        for (data, maxBytes, maxPixel) in [(Data(), 1000, 100), (Data("not an image".utf8), 1000, 100),
                                            (Data([1, 2, 3]), 0, 100), (Data([1, 2, 3]), 1000, 0)] {
            guard case .failure(.undecodableSource) = MediaConversion.convertImageForUpload(data, maxBytes: maxBytes, maxPixel: maxPixel) else {
                Issue.record("expected .undecodableSource")
                return
            }
        }
    }

    @Test func runsOffTheMainThread() async throws {
        let tiff = try #require(encode([makeImage(width: 64, height: 64, alpha: false)], type: "public.tiff"))
        let onMain = await Task.detached { () -> Bool in
            _ = MediaConversion.convertImageForUpload(tiff, maxBytes: 1_000_000, maxPixel: 32)
            return pthread_main_np() != 0
        }.value
        #expect(!onMain)
    }
}

// MARK: - Audio

@Suite("MediaFormatConversion audio")
struct MediaFormatConversionAudioTests {
    private func assertWAV(_ data: Data, seconds: Double) throws {
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self) == "WAVE")
        let url = temporaryAudioURL("wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let actual = Double(file.length) / 16_000
        #expect(abs(actual - seconds) < 0.1)
    }

    @Test func cafAndAiffStereoConvertToMono16kWAV() async throws {
        for (ext, type) in [("caf", "caf"), ("aiff", "aiff")] {
            let url = temporaryAudioURL(ext)
            defer { try? FileManager.default.removeItem(at: url) }
            try writeTone(to: url, fileType: type, seconds: 1.0)
            let wav = try #require(try? await MediaConversion.convertAudioToWAV(fileURL: url, maxBytes: 10_000_000).get())
            try assertWAV(wav, seconds: 1.0)
        }
    }

    @Test func m4aAACConverts() async throws {
        let url = temporaryAudioURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, fileType: "m4a", seconds: 1.0, channels: 1, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ])
        let wav = try #require(try? await MediaConversion.convertAudioToWAV(fileURL: url, maxBytes: 10_000_000).get())
        try assertWAV(wav, seconds: 1.0)
    }

    @Test func flacConverts() async throws {
        let url = temporaryAudioURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, fileType: "flac", seconds: 0.5, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
        ])
        let wav = try #require(try? await MediaConversion.convertAudioToWAV(fileURL: url, maxBytes: 10_000_000).get())
        try assertWAV(wav, seconds: 0.5)
    }

    @Test func outputOverBudgetFailsBeforeConverting() async throws {
        let url = temporaryAudioURL("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(to: url, fileType: "caf", seconds: 1.0)
        let result = await MediaConversion.convertAudioToWAV(fileURL: url, maxBytes: 10_000)
        guard case .failure(.outputTooLarge) = result else {
            Issue.record("expected .outputTooLarge, got \(result)")
            return
        }
    }

    @Test func unreadableOggIsUnsupportedAndCorruptOtherIsUndecodable() async throws {
        let ogg = temporaryAudioURL("ogg")
        try Data("OggS-not-really".utf8).write(to: ogg)
        let broken = temporaryAudioURL("caf")
        try Data("garbage".utf8).write(to: broken)
        defer {
            try? FileManager.default.removeItem(at: ogg)
            try? FileManager.default.removeItem(at: broken)
        }
        let oggResult = await MediaConversion.convertAudioToWAV(fileURL: ogg, maxBytes: 1_000_000)
        guard case .failure(.unsupportedFormat) = oggResult else {
            Issue.record("expected .unsupportedFormat, got \(oggResult)")
            return
        }
        let brokenResult = await MediaConversion.convertAudioToWAV(fileURL: broken, maxBytes: 1_000_000)
        guard case .failure(.undecodableSource) = brokenResult else {
            Issue.record("expected .undecodableSource, got \(brokenResult)")
            return
        }
    }

    @Test func missingFileFailsAsUndecodable() async {
        let url = temporaryAudioURL("m4a")
        let result = await MediaConversion.convertAudioToWAV(fileURL: url, maxBytes: 1_000_000)
        guard case .failure(.undecodableSource) = result else {
            Issue.record("expected .undecodableSource, got \(result)")
            return
        }
    }
}

// MARK: - Rich documents

@Suite("MediaFormatConversion rich documents")
struct MediaFormatConversionDocumentTests {
    private let sample = "你好 hello 世界 0123456789"

    @Test func officeAndRichFormatsRoundTrip() throws {
        let cases: [(String, NSAttributedString.DocumentType)] = [
            ("docx", .officeOpenXML), ("doc", .docFormat), ("rtf", .rtf), ("rtfd", .rtfd), ("odt", .openDocument),
        ]
        for (ext, type) in cases {
            let data = try attributedData(sample, type: type)
            let result = try #require(try? MediaConversion.extractRichDocumentText(data, fileExtension: ext, maxCharacters: 1000).get(), "\(ext)")
            #expect(result.text.contains("你好 hello 世界"), "\(ext): \(result.text)")
            #expect(!result.truncated)
        }
    }

    @Test func extensionIsCaseAndDotInsensitive() throws {
        let data = try attributedData(sample, type: .rtf)
        let result = try #require(try? MediaConversion.extractRichDocumentText(data, fileExtension: ".RTF", maxCharacters: 1000).get())
        #expect(result.text.contains("hello"))
    }

    @Test func truncatesToMaxCharacters() throws {
        let data = try attributedData(String(repeating: "字", count: 100), type: .officeOpenXML)
        let result = try #require(try? MediaConversion.extractRichDocumentText(data, fileExtension: "docx", maxCharacters: 10).get())
        #expect(result.text.count == 10)
        #expect(result.truncated)
    }

    @Test func htmlDropsScriptAndStyle() throws {
        let html = Data("<html><head><style>p{color:red}</style></head><body><script>var x=1</script><p>你好</p><p>world</p></body></html>".utf8)
        let result = try #require(try? MediaConversion.extractRichDocumentText(html, fileExtension: "htm", maxCharacters: 1000).get())
        #expect(result.text.contains("你好") && result.text.contains("world"))
        #expect(!result.text.contains("color") && !result.text.contains("var x"))
    }

    @Test func spreadsheetAndPresentationAreUnsupported() {
        for ext in ["xlsx", "pptx", "xls", "numbers"] {
            guard case .failure(.unsupportedFormat) = MediaConversion.extractRichDocumentText(Data([1, 2, 3]), fileExtension: ext, maxCharacters: 100) else {
                Issue.record("expected .unsupportedFormat for \(ext)")
                return
            }
        }
    }

    @Test func corruptAndEmptyInputs() throws {
        guard case .failure(.undecodableSource) = MediaConversion.extractRichDocumentText(Data("junk".utf8), fileExtension: "docx", maxCharacters: 100) else {
            Issue.record("expected .undecodableSource for corrupt docx")
            return
        }
        guard case .failure(.undecodableSource) = MediaConversion.extractRichDocumentText(Data(), fileExtension: "rtf", maxCharacters: 100) else {
            Issue.record("expected .undecodableSource for empty data")
            return
        }
        let blank = try attributedData("   \n  ", type: .rtf)
        guard case .failure(.emptyResult) = MediaConversion.extractRichDocumentText(blank, fileExtension: "rtf", maxCharacters: 100) else {
            Issue.record("expected .emptyResult for blank rtf")
            return
        }
    }

    @Test func nonHTMLFormatsWorkOffTheMainThread() async throws {
        let docx = try attributedData(sample, type: .officeOpenXML)
        let rtf = try attributedData(sample, type: .rtf)
        let outcome = await Task.detached { () -> (Bool, Bool, Bool) in
            let a = (try? MediaConversion.extractRichDocumentText(docx, fileExtension: "docx", maxCharacters: 1000).get()) != nil
            let b = (try? MediaConversion.extractRichDocumentText(rtf, fileExtension: "rtf", maxCharacters: 1000).get()) != nil
            return (a, b, pthread_main_np() != 0)
        }.value
        #expect(outcome.0 && outcome.1 && !outcome.2)
    }
}
