import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import SwiftSoup

// MARK: - P3-MEDIA-01 media conversion / extraction
//
// The canonical gap row names the residual after the capability gate landed:
// 「SVG 污染后续，PDF/视频仅路径降级，音频未证」 and the acceptance list
// 「capability gate、转换/提取、失败隔离、重启/compact/模型切换矩阵通过」.
// The gate (MediaCapabilityGate, lanes 128/138) closed the first and third
// acceptance elements at the wire edge. This file closes the 转换/提取 element
// on the MinisCore side: the two conversions the gate's own contracts point at
// and nothing else —
//   * vector image → raster PNG: `MediaCapabilityGate.decide` rejects SVG with
//     the instruction "convert it to PNG or JPEG before sending"
//     (MediaCapabilityGate.swift:124); until now no product site could do that
//     conversion.
//   * PDF → text extraction: `extractPDFText` supplied the original unbounded
//     primitive. The App attachment consumer now uses `extractPDFPages` to
//     freeze bounded, source-numbered text into the message before provider
//     assembly; no native PDF document block is claimed.
// Deliberately NOT implemented here (inventing them would exceed the canonical
// row): audio/video transcoding, SVG in-wire automatic substitution, and any
// change to gate semantics — the gate stays the single enforcement source and
// this module never bypasses it; whatever these functions return still rides
// the same gated assembly edges.
//
// Contract mirrored from the gate (acceptance elements 「失败隔离」 +
// 「重启/compact/模型切换矩阵」):
// 1. PURE FUNCTIONS OF THE INPUT BYTES. No I/O, no clock, no global state, no
//    UI — re-converting the same stored attachment bytes after a restart or a
//    compact replay yields identical results.
// 2. TYPED, FAIL-CLOSED OUTCOMES. Nothing throws: every non-recoverable input
//    becomes a `MediaConversionFailure` value, so one unconvertible attachment
//    can never abort sibling conversions or poison the rest of the turn.
// 3. HONEST EMPTINESS. A payload that decodes but carries no extractable
//    content (text-less scanned PDF, zero-frame source) reports `.emptyResult`
//    instead of fabricating content — the caller keeps its existing fallback.

/// Typed, deterministic failure of a media conversion/extraction. Plain
/// `String`-free payload: safe to embed in log/receipt lines and in model-side
/// notes (no secret-bearing paths or URLs are ever echoed).
public enum MediaConversionFailure: String, Error, Sendable, Hashable, Equatable {
    /// The bytes could not be decoded as the expected medium at all.
    case undecodableSource
    /// Decoded, but produced no usable content (e.g. a PDF without a text
    /// layer). Never silently replaced by invented content.
    case emptyResult
    /// The decoded image could not be re-encoded as PNG.
    case encodingFailed
    /// Input exceeds the bounded PDF text-extraction byte budget.
    case sourceTooLarge
    /// The format is recognised but not convertible on this system (e.g. ogg
    /// audio, xlsx/pptx documents). Distinct from `.undecodableSource`, which
    /// means the bytes are corrupt for a supported format.
    case unsupportedFormat
    /// The conversion succeeded but could not be brought under the caller's
    /// output byte budget (image shrink/quality ladder exhausted, WAV too big).
    case outputTooLarge
}

/// One text-bearing PDF page. `pageNumber` is the original 1-based document
/// index, even when preceding pages have no text layer.
public struct PDFExtractedPage: Sendable, Equatable {
    public let pageNumber: Int
    public let text: String
}

/// Bounded PDF text-layer result. A truncated result never claims that the
/// omitted pages or characters were inspected or sent to the model.
public struct PDFTextExtraction: Sendable, Equatable {
    public let pages: [PDFExtractedPage]
    public let totalPageCount: Int
    public let inspectedPageCount: Int
    public let isTruncated: Bool
}

/// Deterministic conversion/extraction primitives for the media pipeline.
/// Pure static functions only; see the file header for the contract.
public enum MediaConversion {

    /// Default longest-edge limit for vector rasterization. Vector sources have
    /// no guaranteed pixel budget; rasterizing at this cap keeps request bodies
    /// bounded while preserving legibility, and is a stable function constant so
    /// repeated conversions of the same bytes stay byte-identical.
    public static let defaultMaxRasterPixelSize: Int = 2048

    // MARK: - SVG (vector image) → PNG raster

    /// Rasterize a vector-image payload (e.g. `image/svg+xml`) to PNG bytes —
    /// the same headless-safe decode path the app already uses for attachment
    /// thumbnails (`AttachmentThumbnailer`, ChatStore.swift:340-348), extended
    /// with the one rasterizer ImageIO does not provide for in-memory bytes:
    /// SVG. See `rasterToBitmap` for the two-pass decode contract.
    ///
    /// Pure function of `(data, maxPixelSize)`: the same input always produces
    /// byte-identical PNG output, so restart / compact / model-switch replays
    /// of a stored attachment re-convert identically and never diverge.
    ///
    /// Failure isolation: every rejection is a returned value, never a throw
    /// and never a partial output — callers fall back to the gate note for this
    /// part while all other parts of the message proceed unchanged.
    public static func rasterizeVectorImage(
        _ data: Data,
        maxPixelSize: Int = defaultMaxRasterPixelSize
    ) -> Result<Data, MediaConversionFailure> {
        guard !data.isEmpty, maxPixelSize > 0 else {
            return .failure(.undecodableSource)
        }
        guard let image = rasterToBitmap(data, maxPixelSize: maxPixelSize) else {
            return .failure(.undecodableSource)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else {
            return .failure(.encodingFailed)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return .failure(.encodingFailed)
        }
        return .success(output as Data)
    }

    /// Decode + rasterize to a bitmap using two first-party rasterizers, in a
    /// fixed order, both deterministic:
    ///
    /// 1. ImageIO `CGImageSource` — covers every raster format it can detect
    ///    and resample. Always-rasterized thumbnail: for a raster source it
    ///    resamples — deterministic and independent of any display or host DPI.
    ///    Same options typing as the pinned app-side idiom
    ///    (ChatStore.swift:373-381).
    /// 2. AppKit `NSImage` — ImageIO exposes no SVG decoder for in-memory
    ///    bytes: a source built from valid SVG data reports zero elements on
    ///    this OS even with an explicit `public.svg-image` type hint (measured
    ///    on the R26-GATE host), which is why SVG conversion failed closed as
    ///    `.undecodableSource` on every input before this fallback. `NSImage`
    ///    rasterizes SVG natively, so the vector is snapshotted to its TIFF
    ///    bitmap and re-enters the same deterministic ImageIO resample path.
    ///
    /// Fail-closed semantics are unchanged: bytes neither rasterizer can
    /// decode return nil and stay a typed `.undecodableSource` upstream; pass
    /// 2 only ever sees payloads pass 1 already rejected.
    private static func rasterToBitmap(
        _ data: Data, maxPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateThumbnailAtIndex(
               source, 0, options as CFDictionary
           ) {
            return image
        }
        guard let vector = NSImage(data: data),
              let tiff = vector.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Gate-compatible note for a failed vector conversion: the part stays
    /// rejected exactly as the un-converted SVG was, with the reason made
    /// concrete. Assembly sites that attempt conversion fall back to
    /// `MediaCapabilityGate.rejectionNote` semantics — this text never
    /// replaces the gate, it explains a conversion attempt that failed.
    public static func conversionFailureNote(
        mimeType: String, failure: MediaConversionFailure
    ) -> String {
        let reason: String
        switch failure {
        case .undecodableSource:
            reason = "the bytes could not be decoded as \(mimeType)"
        case .emptyResult:
            reason = "the payload decoded but contained no convertible content"
        case .encodingFailed:
            reason = "the decoded image could not be re-encoded as PNG"
        case .sourceTooLarge:
            reason = "the source exceeded the size limit (PDF extraction bytes or image pixels)"
        case .unsupportedFormat:
            reason = "this format cannot be converted on this system"
        case .outputTooLarge:
            reason = "the converted result exceeded the size limit"
        }
        return "[media-convert] Conversion of an attachment (\(mimeType)) did not produce a usable replacement: \(reason). The media capability gate note applies unchanged; nothing partial was sent."
    }

    // MARK: - PDF → text extraction

    /// The PDF extraction path has independent byte, page and text budgets.
    /// Keeping the bounds here lets the App reject large files before PDFKit
    /// decoding and makes the same bytes produce the same frozen page payload.
    public static let defaultMaxPDFInputBytes = 32 * 1024 * 1024
    public static let defaultMaxPDFPages = 100
    public static let defaultMaxPDFCharacters = 100_000

    /// Extract a bounded text layer while retaining the source page numbers.
    /// Blank/scanned pages are omitted from `pages`, not renumbered. This
    /// synchronous function owns its PDFDocument and PDFPage values locally;
    /// callers must invoke it from an isolated background worker after a
    /// bounded read. No PDFKit object crosses an actor/executor boundary.
    /// The older `extractPDFText` API keeps its MainActor contract unchanged.
    public static func extractPDFPages(
        _ data: Data,
        maxInputBytes: Int = defaultMaxPDFInputBytes,
        maxPages: Int = defaultMaxPDFPages,
        maxCharacters: Int = defaultMaxPDFCharacters
    ) -> Result<PDFTextExtraction, MediaConversionFailure> {
        guard maxInputBytes > 0, maxPages > 0, maxCharacters > 0 else {
            return .failure(.undecodableSource)
        }
        guard data.count <= maxInputBytes else { return .failure(.sourceTooLarge) }
        guard !data.isEmpty, let document = PDFDocument(data: data) else {
            return .failure(.undecodableSource)
        }
        guard document.pageCount > 0 else { return .failure(.emptyResult) }

        let pageBudget = min(document.pageCount, maxPages)
        var pages: [PDFExtractedPage] = []
        var remaining = maxCharacters
        var inspected = 0
        var truncated = document.pageCount > pageBudget
        for index in 0..<pageBudget {
            inspected = index + 1
            let text = (document.page(at: index)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if remaining == 0 {
                truncated = true
                break
            }
            let selected = String(text.prefix(remaining))
            pages.append(PDFExtractedPage(pageNumber: index + 1, text: selected))
            remaining -= selected.count
            if selected.count < text.count {
                truncated = true
                break
            }
        }
        guard !pages.isEmpty else { return .failure(.emptyResult) }
        return .success(PDFTextExtraction(
            pages: pages,
            totalPageCount: document.pageCount,
            inspectedPageCount: inspected,
            isTruncated: truncated
        ))
    }

    /// 受密码保护（加密且未解锁）的 PDF：PDFKit 读不到文字，也不能渲染页面。
    /// 调用方据此报“受密码保护”，而不是误报成“扫描件，没有文字层”。
    public static func isPasswordProtectedPDF(_ data: Data) -> Bool {
        guard !data.isEmpty, let document = PDFDocument(data: data) else { return false }
        return document.isLocked
    }

    /// Extract the text layer of a PDF document, page by page, joined with a
    /// blank line between pages. MainActor-isolated defensively: PDFKit is a
    /// UI-framework dependency, and the chat attachment pipeline that consumes
    /// this runs on the main actor; the function itself stays a pure
    /// deterministic map from input bytes to output string.
    ///
    /// .pdf with no text layer (scanned image PDF) → `.emptyResult`: honest —
    /// the caller keeps its current behavior (gate note / path reference)
    /// rather than sending fabricated content. OCR is out of the canonical
    /// row and not attempted.
    @MainActor
    public static func extractPDFText(_ data: Data) -> Result<String, MediaConversionFailure> {
        guard !data.isEmpty, let document = PDFDocument(data: data) else {
            return .failure(.undecodableSource)
        }
        guard document.pageCount > 0 else {
            return .failure(.emptyResult)
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            if !text.isEmpty { pages.append(text) }
        }
        let joined = pages.joined(separator: "\n\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyResult)
        }
        return .success(joined)
    }

    // MARK: - PDF page → image (scanned PDFs, model-side viewing)

    /// 把 PDF 的页面渲染成图片（JPEG，白底，长边不超过 `maxLongEdge`），供扫描件和
    /// file_read 的按页看图共用。`firstPage` 从 1 开始；最多渲染 `maxPages` 页，
    /// 超出文档末尾即停止。`page` 是文档里的原始页号（1 起）。
    /// 失败：无法解码 → `.undecodableSource`；文档有密码 → `.unsupportedFormat`
    /// （调用方应先判 isLocked 并给出"受密码保护"提示）；起始页超出范围或没有页 → `.emptyResult`。
    /// 同步函数，PDFKit 对象只在函数内使用；调用方应放在后台 worker 上执行。
    public static func renderPDFPagesAsImages(
        url: URL, maxPages: Int, maxLongEdge: Int, firstPage: Int = 1
    ) throws -> [(data: Data, mimeType: String, page: Int)] {
        guard let document = PDFDocument(url: url) else { throw MediaConversionFailure.undecodableSource }
        return try renderPDFPages(document: document, maxPages: maxPages, maxLongEdge: maxLongEdge, firstPage: firstPage)
    }

    /// 同上，但直接用已读入的字节（调用方已经过授权读取，避免第二次打开文件）。
    public static func renderPDFPagesAsImages(
        data: Data, maxPages: Int, maxLongEdge: Int, firstPage: Int = 1
    ) throws -> [(data: Data, mimeType: String, page: Int)] {
        guard let document = PDFDocument(data: data) else { throw MediaConversionFailure.undecodableSource }
        return try renderPDFPages(document: document, maxPages: maxPages, maxLongEdge: maxLongEdge, firstPage: firstPage)
    }

    private static func renderPDFPages(
        document: PDFDocument, maxPages: Int, maxLongEdge: Int, firstPage: Int
    ) throws -> [(data: Data, mimeType: String, page: Int)] {
        guard maxPages > 0, maxLongEdge > 0, firstPage > 0 else {
            throw MediaConversionFailure.undecodableSource
        }
        guard !document.isLocked else { throw MediaConversionFailure.unsupportedFormat }
        let total = document.pageCount
        guard total > 0, firstPage <= total else { throw MediaConversionFailure.emptyResult }
        let lastPage = min(total, firstPage + maxPages - 1)
        var rendered: [(data: Data, mimeType: String, page: Int)] = []
        for index in (firstPage - 1)..<lastPage {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0 else { continue }
            let scale = CGFloat(maxLongEdge) / longest
            let size = NSSize(width: max(1, (bounds.width * scale).rounded()),
                              height: max(1, (bounds.height * scale).rounded()))
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            var rect = CGRect(origin: .zero, size: thumbnail.size)
            guard let cgImage = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let encoded = encodeImage(cgImage, type: "public.jpeg", quality: 0.8) else { continue }
            rendered.append((data: encoded, mimeType: "image/jpeg", page: index + 1))
        }
        guard !rendered.isEmpty else { throw MediaConversionFailure.undecodableSource }
        return rendered
    }

    // MARK: - Any ImageIO raster → PNG / JPEG for upload

    /// Lowest longest-edge the shrink ladder will reach before giving up.
    private static let minUploadEdge = 64
    /// JPEG qualities tried (descending) at each size step.
    private static let jpegQualityLadder: [Double] = [0.85, 0.7, 0.55, 0.4]

    /// Re-encode any ImageIO-readable raster (HEIC, GIF first frame, TIFF,
    /// BMP, AVIF where the OS decodes it, ...) as PNG (source has an alpha
    /// channel) or JPEG (opaque, quality 0.85 first). The longest edge never
    /// exceeds `maxPixel` and never grows past the source. If the result is
    /// over `maxBytes` the JPEG quality is lowered, then the size is reduced by
    /// 25% per step (PNG: size only) down to a 64 px edge, after which
    /// `.outputTooLarge` is returned. EXIF orientation is applied.
    ///
    /// ImageIO / CoreGraphics only (no AppKit): safe on any background thread.
    /// 转码前允许的来源图片总像素上限（1 亿）。
    public static let maxSourceTotalPixels = 100_000_000

    public static func convertImageForUpload(
        _ data: Data, maxBytes: Int, maxPixel: Int
    ) -> Result<(data: Data, mimeType: String), MediaConversionFailure> {
        guard maxBytes > 0, maxPixel > 0, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return .failure(.undecodableSource)
        }
        // 只读了文件头：像素总数超过上限就在解码之前拒绝，防止小文件解出巨量内存。
        guard width <= maxSourceTotalPixels / height else { return .failure(.sourceTooLarge) }
        // Source-declared alpha, not the decoded bitmap's alphaInfo: ImageIO
        // returns opaque HEIC as premultipliedLast.
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var edge = min(maxPixel, max(width, height))
        while true {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else {
                return .failure(.undecodableSource)
            }
            if hasAlpha {
                guard let encoded = encodeImage(image, type: "public.png", quality: nil) else {
                    return .failure(.encodingFailed)
                }
                if encoded.count <= maxBytes {
                    return .success((data: encoded, mimeType: "image/png"))
                }
            } else {
                for quality in jpegQualityLadder {
                    guard let encoded = encodeImage(image, type: "public.jpeg", quality: quality) else {
                        return .failure(.encodingFailed)
                    }
                    if encoded.count <= maxBytes {
                        return .success((data: encoded, mimeType: "image/jpeg"))
                    }
                }
            }
            if edge <= minUploadEdge { return .failure(.outputTooLarge) }
            edge = max(minUploadEdge, edge * 3 / 4)
        }
    }

    /// Pixel size from the image header only (no full decode). Lets the caller
    /// transcode a small-in-bytes but huge-in-pixels PNG/JPEG/WebP that would
    /// otherwise be passed through and rejected by the provider.
    public static func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// A raster image that is too large in pixels to pass through unchanged:
    /// longest edge over `maxLongEdge` (the transcode target; Anthropic requires
    /// every edge ≤ 2000 px once a request carries more than 20 images).
    public static func imageExceedsPassThroughPixels(width: Int, height: Int, maxLongEdge: Int) -> Bool {
        max(width, height) > maxLongEdge
    }

    private static func encodeImage(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            return nil
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    // MARK: - Audio → 16 kHz mono 16-bit PCM WAV

    public static let wavTargetSampleRate: Double = 16_000

    /// Transcode an AVFoundation-readable audio file (m4a, aac, flac, aiff,
    /// caf, ...) to a 16 kHz mono 16-bit PCM WAV. Streams in 16384-frame
    /// chunks through a temporary file (deleted on exit), so memory stays
    /// bounded. The decode runs on a detached utility task, never on the
    /// caller's actor. A file the system cannot open yields `.unsupportedFormat`
    /// for ogg/oga/opus extensions and `.undecodableSource` otherwise; an
    /// estimated or actual WAV above `maxBytes` yields `.outputTooLarge`.
    public static func convertAudioToWAV(
        fileURL: URL, maxBytes: Int
    ) async -> Result<Data, MediaConversionFailure> {
        await Task.detached(priority: .utility) {
            MediaConversion.transcodeAudioToWAV(fileURL: fileURL, maxBytes: maxBytes)
        }.value
    }

    private static func transcodeAudioToWAV(
        fileURL: URL, maxBytes: Int
    ) -> Result<Data, MediaConversionFailure> {
        guard maxBytes > 0 else { return .failure(.outputTooLarge) }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: fileURL)
        } catch {
            let ext = fileURL.pathExtension.lowercased()
            return .failure(["ogg", "oga", "opus"].contains(ext) ? .unsupportedFormat : .undecodableSource)
        }
        let inputFormat = input.processingFormat
        guard input.length > 0, inputFormat.sampleRate > 0 else { return .failure(.emptyResult) }
        let estimatedFrames = Double(input.length) / inputFormat.sampleRate * wavTargetSampleRate
        guard Int(estimatedFrames) * 2 + 44 <= maxBytes else { return .failure(.outputTooLarge) }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: wavTargetSampleRate, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return .failure(.encodingFailed)
        }
        let inputChunk: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount(Double(inputChunk) * wavTargetSampleRate / inputFormat.sampleRate) + 1024
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunk),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return .failure(.encodingFailed)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: wavTargetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let output = try AVAudioFile(
                forWriting: temporary, settings: settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
            let feed = AudioChunkFeed(file: input, buffer: inputBuffer, chunk: inputChunk)
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    feed.next(inputStatus)
                }
                if feed.readFailed || status == .error { return .failure(.undecodableSource) }
                if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
                if status == .endOfStream { break }
            }
        } catch {
            return .failure(.encodingFailed)
        }
        guard let wav = try? Data(contentsOf: temporary) else { return .failure(.encodingFailed) }
        guard wav.count > 44 else { return .failure(.emptyResult) }
        guard wav.count <= maxBytes else { return .failure(.outputTooLarge) }
        return .success(wav)
    }

    /// Feeds `AVAudioConverter`'s `@Sendable` input block from an
    /// `AVAudioFile`. `@unchecked Sendable` is sound here: the converter calls
    /// the block synchronously on the thread running `convert`, and the owning
    /// function never touches the file or buffer concurrently.
    private final class AudioChunkFeed: @unchecked Sendable {
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let chunk: AVAudioFrameCount
        private(set) var readFailed = false

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer, chunk: AVAudioFrameCount) {
            self.file = file
            self.buffer = buffer
            self.chunk = chunk
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if file.framePosition >= file.length {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                readFailed = true
                status.pointee = .noDataNow
                return nil
            }
            if buffer.frameLength == 0 {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    // MARK: - Rich document → plain text

    /// Extract plain text from docx / doc / rtf / rtfd / odt via
    /// `NSAttributedString` and from html / htm via SwiftSoup (the
    /// `NSAttributedString` HTML importer needs the main thread; SwiftSoup does
    /// not). Everything else, including xlsx and pptx, is `.unsupportedFormat`.
    /// Object-replacement characters (embedded images) are dropped; the text is
    /// trimmed and cut to `maxCharacters` (`truncated` reports the cut).
    /// Non-HTML formats are synchronous and background-thread safe.
    public static func extractRichDocumentText(
        _ data: Data, fileExtension: String, maxCharacters: Int
    ) -> Result<(text: String, truncated: Bool), MediaConversionFailure> {
        guard maxCharacters > 0, !data.isEmpty else { return .failure(.undecodableSource) }
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let raw: String
        switch ext {
        case "html", "htm":
            let source = String(decoding: data, as: UTF8.self)
            guard let parsed = try? SwiftSoup.parse(source),
                  (try? parsed.select("script,style,noscript,template").remove()) != nil,
                  let text = try? parsed.body()?.text() else {
                return .failure(.undecodableSource)
            }
            raw = text
        case "docx", "doc", "rtf", "rtfd", "odt":
            let type: NSAttributedString.DocumentType
            switch ext {
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "rtf": type = .rtf
            case "rtfd": type = .rtfd
            default: type = .openDocument
            }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            guard let attributed = try? NSAttributedString(
                data: data, options: options, documentAttributes: nil
            ) else {
                return .failure(.undecodableSource)
            }
            raw = attributed.string
        default:
            return .failure(.unsupportedFormat)
        }
        let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyResult) }
        let truncated = text.count > maxCharacters
        return .success((text: truncated ? String(text.prefix(maxCharacters)) : text, truncated: truncated))
    }
}
