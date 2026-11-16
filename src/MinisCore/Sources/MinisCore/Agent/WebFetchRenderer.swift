import Foundation
import SwiftSoup

/// HTML is untrusted tool data: it is never executed or loaded in a browser.
public enum WebFetchRenderer {
    public static func text(from data: Data, mimeType: String?, characterEncoding: String?) throws -> String {
        let mime = (mimeType ?? "").lowercased()
        guard ["text/html", "application/xhtml+xml", "text/plain"].contains(mime) else {
            throw WebFetchError.unsupportedContentType
        }
        if let encoding = characterEncoding?.lowercased(),
           !["utf-8", "utf8", "us-ascii", "ascii"].contains(encoding) {
            throw WebFetchError.unsupportedEncoding
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw WebFetchError.unsupportedEncoding
        }
        if mime == "text/plain" { return source }
        let document = try SwiftSoup.parse(source)
        _ = try document.select("script,style,noscript,template").remove()
        return try document.body()?.text() ?? ""
    }
}
