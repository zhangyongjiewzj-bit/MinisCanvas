// Historical design source: OpenMinis ExternalFileImporter and external-file import capabilities.
// Reimplemented from an independent behavior specification; not a claim of a verbatim whole-file port.
import Foundation
import Darwin

public enum FileType: String, Codable, Sendable, CaseIterable {
    case text, markdown, json, image, audio, video, unknown

    public var displayName: String {
        self == .json ? "JSON" : rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
    }
}

public struct ImportableFile: Sendable, Equatable {
    public let url: URL
    public let type: FileType
    public let suggestedName: String
    public let size: Int64?

    public init(url: URL, type: FileType, suggestedName: String, size: Int64? = nil) {
        self.url = url
        self.type = type
        self.suggestedName = suggestedName
        self.size = size
    }
}

public enum FileImportError: Error, Equatable, Sendable, LocalizedError {
    case notAFileURL(URL)
    case notARegularFile(URL)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAFileURL(let url): return "A local file URL is required: \(url.absoluteString)"
        case .notARegularFile(let url): return "The source is not an existing regular file: \(url.path)"
        case .copyFailed(let reason): return "Unable to copy the imported file: \(reason)"
        }
    }
}

public enum FileImporter {
    /// 源码、配置与脚本类扩展名：按文本注入。`.env` 本身不在其中（可能含密钥），只收 `.env.example`（见 `declaredType(forFileName:)`）。
    private static let sourceCodeExtensions = "yaml yml toml ini conf cfg plist xml html htm css js ts tsx jsx swift py mdx "
        + "go rs java kt kts c h cpp hpp cc cxx m mm vue sh zsh bash sql gradle rb php lua r scala dart"

    /// 无扩展名但约定俗成是纯文本的文件名（小写比较）。
    private static let plainTextFileNames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "licence", "changelog", "gemfile", "rakefile"
    ]

    /// 内容是文本标记但不应把原始标记当纯文本注入的扩展名：归为未知/文件引用，
    /// 也不参与“前 8 KB 像 UTF-8 就按文本”的嗅探，交给后续的富文本提取。
    private static let referenceOnlyExtensions: Set<String> = ["rtf", "rtfd"]

    private static let extensions: [(FileType, String)] = [
        (.text, "txt log csv tsv svg " + sourceCodeExtensions),
        (.markdown, "md markdown mdown mkd"), (.json, "json jsonl ndjson geojson"),
        (.image, "png jpg jpeg gif webp heic heif bmp tiff tif ico avif"),
        (.audio, "mp3 wav aac m4a flac ogg opus aiff caf wma"),
        (.video, "mp4 mov m4v avi mkv webm wmv flv 3gp mpg mpeg")
    ]

    private static let mimeExtensions: [(String, String)] = [
        ("text/plain", "txt log csv tsv " + sourceCodeExtensions),
        ("text/markdown", "md markdown mdown mkd"), ("application/json", "json jsonl ndjson geojson"),
        ("application/pdf", "pdf"), ("image/png", "png"), ("image/jpeg", "jpg jpeg"),
        ("image/gif", "gif"), ("image/webp", "webp"), ("image/svg+xml", "svg"),
        ("image/heic", "heic heif"), ("audio/mpeg", "mp3"), ("audio/wav", "wav"),
        ("audio/mp4", "m4a"), ("audio/aac", "aac"), ("audio/flac", "flac"),
        ("audio/ogg", "ogg opus"), ("video/mp4", "mp4 m4v"),
        ("video/quicktime", "mov"), ("video/webm", "webm"),
        ("video/x-matroska", "mkv"), ("video/mpeg", "mpg mpeg")
    ]

    /// 按文件名判定类型：先看扩展名，再看无扩展名的约定文件名与 `env.example`。
    public static func declaredType(forFileName name: String) -> FileType? {
        let lower = name.lowercased()
        if let byExtension = type(forExtension: (lower as NSString).pathExtension) { return byExtension }
        if lower == "env.example" || lower == ".env.example" || lower.hasSuffix(".env.example") { return .text }
        return plainTextFileNames.contains(lower) ? .text : nil
    }

    /// 嗅探前 8 KB 判断“未知类型却是文本”时是否允许：富文本等标记格式排除。
    public static func allowsTextSniffing(forExtension value: String) -> Bool {
        !referenceOnlyExtensions.contains(value.lowercased())
    }

    /// 前 8 KB（或更短）是否像文本：非空、无 NUL、是合法 UTF-8。
    /// `truncated` 为真时，末尾被字节截断的不完整 UTF-8 序列不算非法。
    public static func looksLikeUTF8Text(_ prefix: Data, truncated: Bool) -> Bool {
        guard !prefix.isEmpty, !prefix.contains(0) else { return false }
        return utf8DecodedAllowingTruncatedTail(prefix, truncated: truncated) != nil
    }

    /// 按 UTF-8 解码；字节被截断时丢掉末尾最多 3 个不完整字节后再解码。
    public static func utf8DecodedAllowingTruncatedTail(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        for dropped in 1...3 where data.count > dropped {
            if let text = String(data: data.prefix(data.count - dropped), encoding: .utf8) { return text }
        }
        return nil
    }

    public static func type(forExtension value: String) -> FileType? {
        let key = value.lowercased()
        return extensions.first { $0.1.split(separator: " ").contains(Substring(key)) }?.0
    }

    public static func mimeType(forExtension value: String) -> String? {
        let key = value.lowercased()
        return mimeExtensions.first { $0.1.split(separator: " ").contains(Substring(key)) }?.0
    }

    public static func type(forMIME value: String) -> FileType? {
        let mime = value.lowercased()
        if mime == "text/markdown" { return .markdown }
        if mime.hasPrefix("text/") { return .text }
        if mime == "application/json" || mime.hasSuffix("+json") { return .json }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        return nil
    }

    public static func classify(url: URL) -> FileType {
        if let category = declaredType(forFileName: url.lastPathComponent) { return category }
        return mimeType(of: url).flatMap { type(forMIME: $0) } ?? .unknown
    }

    public static func mimeType(of url: URL) -> String? {
        if let mapped = mimeType(forExtension: url.pathExtension) { return mapped }
        guard url.isFileURL else { return nil }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 512)
        let amount = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard amount >= 12 else { return nil }
        let prefix = Array(bytes.prefix(amount))
        func starts(_ signature: [UInt8]) -> Bool { prefix.starts(with: signature) }
        func ascii(_ value: String, at offset: Int = 0) -> Bool {
            prefix.dropFirst(offset).starts(with: value.utf8)
        }
        if starts([137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if starts([255, 216, 255]) { return "image/jpeg" }
        if ascii("GIF87a") || ascii("GIF89a") { return "image/gif" }
        if ascii("%PDF-") { return "application/pdf" }
        if ascii("ftyp", at: 4) { return "video/mp4" }
        if ascii("RIFF") {
            if ascii("WAVE", at: 8) { return "audio/wav" }
            if ascii("AVI ", at: 8) { return "video/x-msvideo" }
            if ascii("WEBP", at: 8) { return "image/webp" }
        }
        if ascii("ID3"), prefix[6...9].allSatisfy({ $0 & 0x80 == 0 }) { return "audio/mpeg" }
        if prefix[0] == 255, prefix[1] & 0xE0 == 0xE0,
           prefix[1] & 0x18 != 0x08, prefix[1] & 0x06 == 0x02,
           prefix[2] & 0xF0 != 0, prefix[2] & 0xF0 != 0xF0,
           prefix[2] & 0x0C != 0x0C { return "audio/mpeg" }
        if ascii("OggS") { return "application/ogg" }
        return nil
    }

    public static func importFile(from source: URL, to directory: URL) throws -> URL {
        guard source.isFileURL else { throw FileImportError.notAFileURL(source) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var attributes = stat()
        let status = source.path.withCString { Darwin.lstat($0, &attributes) }
        guard status == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw FileImportError.notARegularFile(source)
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString
            var destination = directory.appendingPathComponent(stem)
            if !source.pathExtension.isEmpty {
                destination = destination.appendingPathExtension(source.pathExtension)
            }
            if !scoped {
                try manager.copyItem(at: source, to: destination)
            } else {
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges,
                                               error: &coordinationError) { accessibleSource in
                    do { try manager.copyItem(at: accessibleSource, to: destination) }
                    catch { copyError = error }
                }
                if let error = coordinationError { throw error }
                if let error = copyError { throw error }
            }
            return destination
        } catch {
            throw FileImportError.copyFailed(error.localizedDescription)
        }
    }

    public static func describe(url: URL) -> ImportableFile {
        let metadata = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (metadata?[.size] as? NSNumber)?.int64Value
        return ImportableFile(url: url, type: classify(url: url),
                              suggestedName: url.lastPathComponent, size: size)
    }
}
