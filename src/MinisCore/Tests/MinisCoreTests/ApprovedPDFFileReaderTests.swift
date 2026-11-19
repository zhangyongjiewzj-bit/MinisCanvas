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
        #expect(empty.contains("没有可提取的文字"))
        #expect(empty.contains("as_images=true"))
    }

    @Test func truncatedReadTellsWhereToContinue() throws {
        let clipped = try FileImporter.readPDF(
            data: Self.document(["first page", String(repeating: "B", count: 200), "third"]), input: ["max_length": 80])
        #expect(clipped.contains("truncated at 80 chars"))
        // M-06：放不下的第 2 页不输出半截，提示从这一页重读（旧行为：输出半截并让模型跳到第 3 页）。
        #expect(clipped.contains("first page"))
        #expect(!clipped.contains("BBBB"))
        #expect(clipped.contains("第 1 页至第 1 页已完整读到"))
        #expect(clipped.contains("page_start=2"))
        #expect(!clipped.contains("page_start=3"))
    }

    @Test func pageThatDoesNotFitIsNeverEmittedHalfAndTheHintPointsAtThatPage() throws {
        // 每页 60 个字符（页内放得下），每页输出约 71 字，文件头 19 字：170 放得下两页放不下三页。
        let data = Self.document([
            String(repeating: "A", count: 60), String(repeating: "B", count: 60), String(repeating: "C", count: 60)])
        let result = try FileImporter.readPDF(data: data, input: ["max_length": 170])
        #expect(result.contains(String(repeating: "A", count: 60)) && result.contains(String(repeating: "B", count: 60)))
        #expect(!result.contains("CCCC"))
        #expect(result.contains("page_start=3"))
        // 按提示续读，第 3 页完整出现。
        let next = try FileImporter.readPDF(data: data, input: ["page_start": 3, "max_length": 170])
        #expect(next.contains(String(repeating: "C", count: 60)))
    }

    @Test func aFirstPageLongerThanMaxLengthIsCutAndToldToRaiseMaxLength() throws {
        let data = Self.document([String(repeating: "A", count: 60), "second"])
        let result = try FileImporter.readPDF(data: data, input: ["max_length": 40])
        #expect(result.contains("AAAA"))
        #expect(result.contains("调大 max_length 重读该页（page_start=1）"))
        #expect(!result.contains("已完整读到"))
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
