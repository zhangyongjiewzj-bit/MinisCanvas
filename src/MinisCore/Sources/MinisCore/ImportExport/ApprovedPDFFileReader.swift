import Foundation
import CoreFoundation
import PDFKit

extension FileImporter {
    /// Classification consumes bytes already read by the authorized file tool.
    /// Never call MIME URL sniffing here: that would introduce a second open.
    public static func isPDF(data: Data, pathExtension: String) -> Bool {
        mimeType(forExtension: pathExtension) == "application/pdf"
            || data.starts(with: Data("%PDF-".utf8))
    }

    /// Extract text from approved file contents. This API deliberately accepts
    /// no URL and cannot widen the caller's filesystem authority.
    /// PDF pages are 1-based; omitted page_count means the remaining pages.
    /// Text offset/lines/direction have no PDF meaning and are rejected.
    public static func readPDF(data: Data, input: [String: Any]) throws -> String {
        for key in ["offset", "lines", "direction"] where input[key] != nil {
            throw ToolExecutorError.invalidParameter("\(key) is text-only; use page_start/page_count for PDF")
        }
        let first = try pdfPositiveInteger(input, key: "page_start", fallback: 1)
        let requestedCount = try pdfPositiveInteger(input, key: "page_count", fallback: Int.max)
        let maxLength = try pdfPositiveInteger(input, key: "max_length", fallback: 15_000)
        guard let document = PDFDocument(data: data) else {
            throw ToolExecutorError.readFailed("Invalid PDF document")
        }
        guard !document.isLocked else {
            throw ToolExecutorError.readFailed("PDF is password protected; unlock it before reading")
        }
        let total = document.pageCount
        guard total > 0, first <= total else {
            throw ToolExecutorError.invalidParameter("page_start is outside the PDF page range (1...\(total))")
        }
        // Subtract before adding so even Int.max page_count cannot overflow.
        let count = min(requestedCount, total - first + 1)
        let last = first + count - 1
        var output = "PDF pages \(first)-\(last) of \(total)\n"
        var truncated = false
        for index in (first - 1)..<last {
            guard let page = document.page(at: index) else {
                throw ToolExecutorError.readFailed("Cannot decode PDF page \(index + 1)")
            }
            let text = page.string ?? ""
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "[No extractable text; scanned/image pages require OCR]" : text
            let section = "\n[Page \(index + 1)]\n\(body)\n"
            let remaining = maxLength - output.count
            guard remaining > 0 else { truncated = true; break }
            output += String(section.prefix(remaining))
            if section.count > remaining { truncated = true; break }
        }
        if output.count > maxLength {
            output = String(output.prefix(maxLength))
            truncated = true
        }
        if truncated { output += "\n…[truncated at \(maxLength) chars]" }
        return output
    }

    private static func pdfPositiveInteger(_ input: [String: Any], key: String, fallback: Int) throws -> Int {
        guard let raw = input[key] else { return fallback }
        // Composer's approved-input round trip emits native Int64 values.
        // Swift's Any-to-Int cast does not convert that native integer type.
        if Swift.type(of: raw) == Int64.self, let integer = raw as? Int64 {
            guard let value = Int(exactly: integer), value > 0 else {
                throw ToolExecutorError.invalidParameter(key)
            }
            return value
        }
        // JSON booleans bridge to NSNumber too; do not accept true as page 1.
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = raw as? Int, value > 0,
              number.doubleValue == Double(value) else {
            throw ToolExecutorError.invalidParameter(key)
        }
        return value
    }
}
