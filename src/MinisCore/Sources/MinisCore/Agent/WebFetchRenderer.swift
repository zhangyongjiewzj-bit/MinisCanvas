import Foundation
import SwiftSoup

/// HTML is untrusted tool data: it is never executed or loaded in a browser.
public enum WebFetchRenderer {
    private static let plainTextTypes: Set<String> = [
        "application/json", "application/xml", "application/rss+xml", "application/atom+xml",
        "application/xhtml+xml", "application/javascript", "application/x-yaml", "application/yaml",
        "application/x-ndjson", "application/ld+json", "application/csv"
    ]

    private static func isRawTextType(_ mime: String) -> Bool {
        if plainTextTypes.contains(mime) { return true }
        if mime.hasPrefix("text/") { return true }
        return mime.hasSuffix("+json") || mime.hasSuffix("+xml")
    }

    public static func text(from data: Data, mimeType: String?, characterEncoding: String?) throws -> String {
        let mime = (mimeType ?? "").lowercased()
        if mime == "application/pdf" {
            return "这是 PDF 文件，web_fetch 不能直接读取。请用 shell_execute 把它下载到授权目录（例如 curl -L -o 文件.pdf 网址），再用 file_read 读取；如果网站未被允许下载，请告知用户。"
        }
        let isHTML = ["text/html", "application/xhtml+xml"].contains(mime)
        guard isHTML || isRawTextType(mime) else {
            throw WebFetchError.unsupportedContentType
        }
        let source = try decode(data, declared: characterEncoding, sniffHTML: isHTML)
        guard isHTML else { return source }
        let document = try SwiftSoup.parse(source)
        _ = try document.select("script,style,noscript,template").remove()
        // Keep links as [text](url): the model can only follow a page it can see.
        for anchor in try document.select("a[href]").array() {
            let href = try anchor.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") else { continue }
            let label = try anchor.text()
            guard !label.isEmpty else { continue }
            try anchor.text("[\(label)](\(href))")
        }
        return try document.body()?.text() ?? ""
    }

    /// Decode with the declared charset (GBK, GB2312, Big5, Shift_JIS, ...),
    /// else an HTML meta charset, else UTF-8, else GB18030 for legacy Chinese pages.
    private static func decode(_ data: Data, declared: String?, sniffHTML: Bool) throws -> String {
        var name = declared?.trimmingCharacters(in: .whitespaces).lowercased()
        if name?.isEmpty == true { name = nil }
        if name == nil, sniffHTML {
            name = sniffedCharset(in: data)
        }
        if let name {
            if ["utf-8", "utf8", "us-ascii", "ascii"].contains(name) {
                guard let text = String(data: data, encoding: .utf8) else { throw WebFetchError.unsupportedEncoding }
                return text
            }
            guard let encoding = stringEncoding(forIANAName: name) else { throw WebFetchError.unsupportedEncoding }
            guard let text = String(data: data, encoding: encoding) else { throw WebFetchError.unsupportedEncoding }
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        throw WebFetchError.unsupportedEncoding
    }

    private static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        if ["gbk", "gb2312", "gb_2312-80", "x-gbk", "gb18030"].contains(name) {
            let gb18030 = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: gb18030)
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func sniffedCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let rest = head[range.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return name.isEmpty ? nil : String(name)
    }
}
