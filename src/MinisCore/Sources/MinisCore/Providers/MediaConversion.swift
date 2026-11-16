import AppKit
import Foundation
import ImageIO
import PDFKit

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
            reason = "the source exceeded the PDF extraction byte limit"
        }
        return "[media-convert] Conversion of an attachment (\(mimeType)) did not produce a usable replacement: \(reason). The media capability gate note applies unchanged; nothing partial was sent."
    }

    // MARK: - PDF → text extraction

    /// The PDF extraction path has independent byte, page and text budgets.
    /// Keeping the bounds here lets the App reject large files before PDFKit
    /// decoding and makes the same bytes produce the same frozen page payload.
    public static let defaultMaxPDFInputBytes = 4 * 1024 * 1024
    public static let defaultMaxPDFPages = 20
    public static let defaultMaxPDFCharacters = 12_000

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
}
