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
        // 最后一个完整输出的页（还没输出任何页时是 first - 1）。
        var lastReached = first - 1
        var firstPageCut = false
        for index in (first - 1)..<last {
            guard let page = document.page(at: index) else {
                throw ToolExecutorError.readFailed("Cannot decode PDF page \(index + 1)")
            }
            let text = page.string ?? ""
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "[本页没有可提取的文字（可能是扫描页）；请给 file_read 设置 as_images=true，并用 page_start=\(index + 1) 按页看图]" : text
            let section = "\n[Page \(index + 1)]\n\(body)\n"
            let remaining = maxLength - output.count
            guard remaining > 0 else { truncated = true; break }
            // 放不下的页不输出半截（否则按提示从下一页继续会丢掉这一页的后半段）；
            // 只有本次调用的第一页本身就超长时才输出前半部分。
            if section.count > remaining, index > first - 1 { truncated = true; break }
            lastReached = index + 1
            output += String(section.prefix(remaining))
            if section.count > remaining { truncated = true; firstPageCut = true; break }
        }
        if output.count > maxLength {
            output = String(output.prefix(maxLength))
            truncated = true
        }
        if truncated {
            output += "\n…[truncated at \(maxLength) chars]"
            if lastReached < first {
                output += "\nmax_length 太小，连第 \(first) 页都放不下；请调大 max_length 后用 page_start=\(first) 重读。"
            } else if firstPageCut {
                output += "\n第 \(first) 页本身超过 max_length，只给出了前半部分；请调大 max_length 重读该页（page_start=\(first)）"
                    + (first < total ? "，再从 page_start=\(first + 1) 继续。" : "。")
            } else if lastReached < total {
                output += "\n第 \(first) 页至第 \(lastReached) 页已完整读到；第 \(lastReached + 1) 页放不下，未输出半截。从 page_start=\(lastReached + 1) 继续，需要更长内容可调大 max_length。"
            }
        }
        return output
    }

    /// file_read 的 `as_images`：把 PDF 的指定页渲染成图片，经图片通道交给模型
    /// （扫描件、图表页用）。每次最多 `ToolResultImageChannel.maxImagesPerResult` 页，
    /// 用 page_start 继续看后面的页。图片会在请求前按模型能力处理：看不了图的模型改用本地文字识别。
    public static func readPDFAsImages(data: Data, input: [String: Any]) throws -> String {
        for key in ["offset", "lines", "direction", "max_length"] where input[key] != nil {
            throw ToolExecutorError.invalidParameter("\(key) 只适用于文本；按页看图请用 page_start/page_count")
        }
        let first = try pdfPositiveInteger(input, key: "page_start", fallback: 1)
        let requested = try pdfPositiveInteger(input, key: "page_count", fallback: ToolResultImageChannel.maxImagesPerResult)
        let count = min(requested, ToolResultImageChannel.maxImagesPerResult)
        guard let document = PDFDocument(data: data) else {
            throw ToolExecutorError.readFailed("PDF 文件无法解析，可能已损坏")
        }
        guard !document.isLocked else {
            throw ToolExecutorError.readFailed("PDF 受密码保护，请先解除密码再读取")
        }
        let total = document.pageCount
        guard total > 0, first <= total else {
            throw ToolExecutorError.invalidParameter("page_start 超出 PDF 页数范围（1...\(total)）")
        }
        let pages: [(data: Data, mimeType: String, page: Int)]
        do {
            pages = try MediaConversion.renderPDFPagesAsImages(
                data: data, maxPages: count, maxLongEdge: ToolResultImageChannel.maxLongEdge, firstPage: first)
        } catch {
            throw ToolExecutorError.readFailed("PDF 页面渲染失败，可改用不带 as_images 的文字读取")
        }
        var markers: [String] = []
        var shown: [Int] = []
        for page in pages {
            if let marker = ToolResultImageChannel.attach(data: page.data, mimeType: page.mimeType) {
                markers.append(marker)
                shown.append(page.page)
            }
        }
        guard let lastShown = shown.last, let firstShown = shown.first else {
            throw ToolExecutorError.readFailed("PDF 页面渲染失败，可改用不带 as_images 的文字读取")
        }
        var text = "PDF 第 \(firstShown)-\(lastShown) 页（共 \(total) 页）已渲染为图片，随本次结果一并提供。"
        if lastShown < total {
            text += "还有后续页：用 page_start=\(lastShown + 1) 继续按页看图。"
        }
        return text + "\n" + markers.joined(separator: "\n")
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
