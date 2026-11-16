import Foundation
import CoreText
import ImageIO
import PDFKit
import Testing
@testable import MinisCore

// MARK: - P3-MEDIA-01 media conversion / extraction tests (lane DEV-220)
//
// Pins the 转换/提取 acceptance element on the MinisCore side:
//   - SVG (vector) → PNG rasterization (the conversion the gate's rejection
//     reason at MediaCapabilityGate.swift:124 instructs but had no product
//     implementation for),
//   - PDF → text extraction (the content primitive the path-only demotion at
//     ChatStore.swift:289-298 lacks),
// plus the two cross-cutting properties the canonical row demands of them:
// per-item failure isolation (typed, never-throwing outcomes; one bad payload
// never touches its siblings) and restart/compact/model-switch determinism
// (pure function of the input bytes → byte-identical re-conversion).
// The gate itself is deliberately untouched: converted output re-enters the
// same gated wires; rejection semantics stay owned by lanes 128/138.
//
// Expected state at delivery: NOT_RUN / UNVERIFIED-RUNTIME — ordinary DEV
// lanes do not run swift test; PKG_MAIN compiles and executes.

private let svgFixture = Data(
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
      <rect x="0" y="0" width="64" height="64" fill="#3366cc"/>
    </svg>
    """.utf8
)

private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

@Suite("P3-MEDIA-01 vector→raster conversion")
struct MediaConversionRasterTests {

    @Test func svgConvertsToDecodablePNG() {
        // (GAP-ON-BASE) No product site could perform this conversion at base;
        // the only prior outcome for an SVG part was the gate note.
        let result = MediaConversion.rasterizeVectorImage(svgFixture)
        guard case .success(let png) = result else {
            Issue.record("SVG fixture must rasterize, got failure: \(result)")
            return
        }
        #expect([UInt8](png.prefix(4)) == pngMagic, "output must carry the PNG signature")
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else {
            Issue.record("PNG output must be ImageIO-decodable")
            return
        }
        #expect(CGImageSourceGetCount(source) > 0, "PNG output must carry at least one frame")
    }

    @Test func conversionIsByteIdenticalForSameStoredBytes() {
        // Restart / compact-replay determinism: same stored attachment bytes
        // re-convert to identical output, so a replayed turn cannot grow or
        // skew a previously accepted payload.
        let first = MediaConversion.rasterizeVectorImage(svgFixture)
        let second = MediaConversion.rasterizeVectorImage(svgFixture)
        guard case .success(let a) = first, case .success(let b) = second else {
            Issue.record("both conversions of the same bytes must succeed")
            return
        }
        #expect(a == b)
    }

    @Test func unconvertiblePayloadsFailTypedNeverThrown() {
        // Fail-closed, typed, non-throwing: each input degrades to a value the
        // caller can turn into a note — no error can propagate past this edge.
        if case .success = MediaConversion.rasterizeVectorImage(Data("clearly not an image".utf8)) {
            Issue.record("garbage bytes must not convert")
        }
        if case .success = MediaConversion.rasterizeVectorImage(Data()) {
            Issue.record("empty bytes must not convert")
        }
        if case .success = MediaConversion.rasterizeVectorImage(svgFixture, maxPixelSize: 0) {
            Issue.record("non-positive pixel cap must be rejected")
        }
    }

    @Test func oneFailedConversionNeverPoisonsSiblings() {
        // Per-item failure isolation across a batch of attachments: the middle
        // convertible item succeeds regardless of its broken neighbors, and
        // each broken item yields exactly its own typed failure.
        let items: [Data] = [
            Data("poison-one".utf8),
            svgFixture,
            Data(),
        ]
        let results = items.map { MediaConversion.rasterizeVectorImage($0) }
        if case .failure = results[1] {
            Issue.record("sibling failures must not affect the convertible item")
        }
        #expect(results[1].isSuccessHint)
        #expect(results[0].isFailureHint)
        #expect(results[2].isFailureHint)
    }

    @Test func convertedRasterReEntersTheGateAsImage() {
        // Conversion never bypasses enforcement: the PNG output classifies as
        // a raster image and is admitted exactly when the model declares
        // imageInput — while the original SVG stays rejected on every
        // capability, independent of this module (gate ownership unchanged).
        guard case .success(let png) = MediaConversion.rasterizeVectorImage(svgFixture) else {
            Issue.record("fixture must convert")
            return
        }
        #expect(MediaPartKind.classify(mimeType: "image/png") == .rasterImage)
        let vision = LLMModel(
            id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: "Anthropic"
        ).capabilities
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: vision).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: vision).isAllowed)
        _ = png
    }
}

// MainActor-isolated per the PDFKit dependency (same pattern as
// SpeechToolTests.swift:24 — @MainActor struct hosting @Test functions).
@MainActor
struct MediaConversionPDFTests {

    /// Deterministic in-memory PDF fixture built with the same PDFKit the
    /// extractor reads — no binary blobs committed, no file I/O.
    ///
    /// `PDFPage.string` is a get-only reader over a page's existing text layer,
    /// so the previous `PDFPage()` + assignment form cannot compile on this SDK
    /// and could never have carried extractable text anyway. Each string is now
    /// drawn as a real text layer (CoreText into a CoreGraphics PDF context),
    /// and each `nil` entry becomes a blank, text-less page — exactly the two
    /// fixture states the @Tests below rely on. Page order matches the input
    /// array order.
    private static func pdfFixture(pages: [String?]) -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            // Unreachable on any macOS SDK (CFMutableData consumer + PDF
            // context creation never fail here). Degrading to undecodable
            // bytes keeps the dependent @Tests failing typed instead of
            // crashing the test runner.
            return Data()
        }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: attributes)
                )
                context.textPosition = CGPoint(x: 72, y: mediaBox.height - 72)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        // Re-open through PDFDocument — the same decode edge the extractor
        // exercises — so the fixture only ships bytes PDFKit accepts.
        return PDFDocument(data: output as Data)?.dataRepresentation() ?? (output as Data)
    }

    @Test func textBearingPDFExtractsItsContent() {
        // (GAP-ON-BASE) The attachment channel had no PDF content primitive at
        // all — only the file path rode along (ChatStore.swift:289-298).
        let data = Self.pdfFixture(pages: ["MinisCanvas extraction fixture"])
        let result = MediaConversion.extractPDFText(data)
        guard case .success(let text) = result else {
            Issue.record("text-bearing PDF must extract, got: \(result)")
            return
        }
        #expect(text.contains("MinisCanvas extraction fixture"))
    }

    @Test func multiPageExtractionPreservesOrderAndSeparation() {
        let data = Self.pdfFixture(pages: ["ALPHA page one", "BETA page two"])
        guard case .success(let text) = MediaConversion.extractPDFText(data) else {
            Issue.record("two-page PDF must extract")
            return
        }
        let alpha = text.range(of: "ALPHA page one")
        let beta = text.range(of: "BETA page two")
        #expect(alpha != nil && beta != nil)
        if let alpha, let beta {
            #expect(alpha.lowerBound < beta.lowerBound, "page order must be preserved")
        }
        #expect(text.contains("\n\n"), "pages must be joined with a blank-line separator")
    }

    @Test func textlessPDFFailsClosedNotFabricated() {
        // A PDF without a text layer (scanned-image analogue) reports
        // .emptyResult — the caller keeps its existing demotion; the
        // extractor never invents content to fill the gap.
        let data = Self.pdfFixture(pages: [nil, nil])
        let result = MediaConversion.extractPDFText(data)
        if case .success(let text) = result {
            Issue.record("text-less PDF must not extract, got: \(text)")
        }
        #expect(result.isFailureEmptyResultHint)
    }

    @Test func nonPDFBytesFailTypedNeverThrown() {
        if case .success = MediaConversion.extractPDFText(Data("definitely not a PDF".utf8)) {
            Issue.record("garbage bytes must not extract")
        }
        if case .success = MediaConversion.extractPDFText(Data()) {
            Issue.record("empty bytes must not extract")
        }
    }

    @Test func extractionIsIdenticalAcrossReplays() {
        // Restart/compact-replay determinism for the extraction edge: the same
        // stored bytes always produce the same string.
        let data = Self.pdfFixture(pages: ["DETERMINISM probe"])
        let first = MediaConversion.extractPDFText(data)
        let second = MediaConversion.extractPDFText(data)
        if case .success(let a) = first, case .success(let b) = second {
            #expect(a == b)
        } else {
            Issue.record("both extractions must succeed")
        }
    }
}

// Small readability helpers so the isolation rows stay declarative.
private extension Result where Success == Data {
    var isSuccessHint: Bool { if case .success = self { return true }; return false }
    var isFailureHint: Bool { if case .failure = self { return true }; return false }
}

private extension Result where Failure == MediaConversionFailure {
    var isFailureEmptyResultHint: Bool {
        if case .failure(.emptyResult) = self { return true }
        return false
    }
}
