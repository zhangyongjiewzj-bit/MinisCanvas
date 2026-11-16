import Foundation
import Testing
@testable import MinisCore

struct ApprovedPDFFileReaderTests {
    @Test func recognizesApprovedBytesWithoutURL() {
        #expect(FileImporter.isPDF(data: Data("%PDF-1.4".utf8), pathExtension: ""))
        #expect(FileImporter.isPDF(data: Data(), pathExtension: "PDF"))
        #expect(!FileImporter.isPDF(data: Data("plain".utf8), pathExtension: "txt"))
    }

    @Test func selectsOneBasedPagesAndClampsCountWithoutOverflow() throws {
        let data = Self.document(["FirstPage", "SecondPage", "ThirdPage"])
        let result = try FileImporter.readPDF(data: data, input: ["page_start": 2, "page_count": 1])
        #expect(result.contains("PDF pages 2-2 of 3"))
        #expect(result.contains("SecondPage"))
        #expect(!result.contains("FirstPage"))
        #expect(!result.contains("ThirdPage"))
        let remainder = try FileImporter.readPDF(data: data, input: ["page_start": 2, "page_count": Int.max])
        #expect(remainder.contains("ThirdPage"))
    }

    @Test func selectsPagesFromFrozenIntegerRepresentation() throws {
        // ComposerInputValue.integer carries Int64 into the executor. Exercise
        // the real PDF consumer, including selected bytes and omitted pages.
        let data = Self.document(["FirstPage", "SecondPage", "ThirdPage"])
        let result = try FileImporter.readPDF(data: data,
            input: ["page_start": Int64(2), "page_count": Int64(1)])
        #expect(result.contains("PDF pages 2-2 of 3"))
        #expect(result.contains("SecondPage"))
        #expect(!result.contains("FirstPage"))
        #expect(!result.contains("ThirdPage"))
    }

    @Test func rejectsInvalidPaginationAndTextOnlyOptions() throws {
        let data = Self.document(["OnlyPage"])
        let inputs: [[String: Any]] = [
            ["page_start": 0], ["page_start": 2], ["page_start": true],
            ["page_start": Int64(0)], ["page_start": Int64(-1)],
            ["page_count": Int64(0)], ["page_count": Int64(-1)],
            ["page_start": "1"], ["page_start": 1.5], ["page_count": false],
            ["page_count": -1], ["page_count": 1.5], ["page_count": "1"],
            ["max_length": 0], ["offset": 1], ["lines": 1], ["direction": "tail"]
        ]
        for input in inputs {
            #expect(throws: ToolExecutorError.self) { try FileImporter.readPDF(data: data, input: input) }
        }
    }

    @Test func reportsMalformedPDFInsteadOfBinarySuccess() {
        #expect(throws: ToolExecutorError.readFailed("Invalid PDF document")) {
            try FileImporter.readPDF(data: Data("not PDF".utf8), input: [:])
        }
    }

    @Test func boundsOutputAndDisclosesImageOnlyPages() throws {
        let clipped = try FileImporter.readPDF(data: Self.document([String(repeating: "A", count: 100)]), input: ["max_length": 40])
        #expect(clipped.contains("truncated at 40 chars"))
        let empty = try FileImporter.readPDF(data: Self.document([""]), input: [:])
        #expect(empty.contains("No extractable text"))
    }

    /// Synthetic PDF assembled in memory; no user document or filesystem read.
    private static func document(_ pages: [String]) -> Data {
        let pageIDs = pages.indices.map { 4 + $0 * 2 }
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        for (index, text) in pages.enumerated() {
            let stream = "BT /F1 12 Tf 50 700 Td (\(text)) Tj ET"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(pageIDs[index] + 1) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        var result = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.utf8.count)
            result += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = result.utf8.count
        result += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { result += String(format: "%010d 00000 n \n", offset) }
        result += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(result.utf8)
    }
}
