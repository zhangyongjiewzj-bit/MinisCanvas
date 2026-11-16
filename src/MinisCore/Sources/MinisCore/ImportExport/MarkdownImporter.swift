import Foundation

/// Parsed result of importing a markdown / plain-text document. Designed to
/// feed both a chat session (fullText + sections) and a canvas (title +
/// sections as note blocks).
public struct ImportedContent: Sendable, Equatable {
    /// Document title — first `# Heading` if present, else `nil`.
    public let title: String?
    /// Section bodies split on `##`/`###` headings (or paragraphs for plain text).
    public let sections: [String]
    /// The full raw text, trimmed of surrounding whitespace.
    public let fullText: String

    public init(title: String?, sections: [String], fullText: String) {
        self.title = title
        self.sections = sections
        self.fullText = fullText
    }
}

/// Bounds for the strict markdown import boundary.  The legacy convenience
/// parser remains available for already trusted in-memory text; file imports
/// use these limits before exposing content to product callers.
public struct MarkdownImportLimits: Sendable, Equatable {
    public static let `default` = MarkdownImportLimits()

    public let maxBytes: Int
    public let maxLines: Int
    public let maxLineBytes: Int
    public let maxSections: Int
    public let maxHeadingCharacters: Int
    public let maxHeadingDepth: Int
    public let maxResourceReferences: Int

    public init(
        maxBytes: Int = 1_048_576,
        maxLines: Int = 10_000,
        maxLineBytes: Int = 65_536,
        maxSections: Int = 1_000,
        maxHeadingCharacters: Int = 512,
        maxHeadingDepth: Int = 6,
        maxResourceReferences: Int = 256
    ) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.maxLineBytes = maxLineBytes
        self.maxSections = maxSections
        self.maxHeadingCharacters = maxHeadingCharacters
        self.maxHeadingDepth = maxHeadingDepth
        self.maxResourceReferences = maxResourceReferences
    }

    fileprivate var isValid: Bool {
        maxBytes > 0 && maxLines > 0 && maxLineBytes > 0 && maxSections > 0
            && maxHeadingCharacters > 0 && (1...6).contains(maxHeadingDepth)
            && maxResourceReferences >= 0
    }
}

/// Turns markdown / plain text into structured `ImportedContent`.
public enum MarkdownImporter {

    // MARK: - Markdown

    /// Parse markdown text into title + sections.
    ///
    /// - A leading `# Title` (or the first `#` heading anywhere) becomes
    ///   `title` and is excluded from sections.
    /// - Sections are split on `##` / `###` headings; text before the first
    ///   such heading becomes its own section (the "preamble").
    public static func importMarkdown(_ text: String) -> ImportedContent {
        parseMarkdown(text, skippedLines: [], respectCodeFences: false, maxHeadingDepth: 3)
    }

    /// Strict markdown boundary for untrusted files. It validates text,
    /// frontmatter, fenced blocks, headings, and link/image destinations
    /// before returning the same `ImportedContent` shape used by callers.
    public static func importMarkdownValidated(
        _ text: String,
        limits: MarkdownImportLimits = .default
    ) throws -> ImportedContent {
        guard limits.isValid else { throw MarkdownImportError.invalidLimits }
        guard text.utf8.count <= limits.maxBytes else { throw MarkdownImportError.budgetExceeded }
        try validateText(text, limits: limits)
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= limits.maxLines else { throw MarkdownImportError.budgetExceeded }
        let skippedLines = try validateFrontmatter(lines, limits: limits)
        try validateStructure(lines, skippedLines: skippedLines, limits: limits)

        let content = parseMarkdown(
            text,
            skippedLines: skippedLines,
            respectCodeFences: true,
            maxHeadingDepth: limits.maxHeadingDepth
        )
        guard content.sections.count <= limits.maxSections,
              content.fullText.utf8.count <= limits.maxBytes else {
            throw MarkdownImportError.budgetExceeded
        }
        if let title = content.title, title.count > limits.maxHeadingCharacters {
            throw MarkdownImportError.budgetExceeded
        }
        return content
    }

    private static func parseMarkdown(
        _ text: String,
        skippedLines: Set<Int>,
        respectCodeFences: Bool,
        maxHeadingDepth: Int
    ) -> ImportedContent {
        let lines = text.components(separatedBy: .newlines)
        var title: String? = nil
        var sections: [String] = []
        var current: [String] = []
        var fence: UInt8?

        func flush() {
            let body = current
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !body.isEmpty {
                sections.append(body)
            }
            current.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            if skippedLines.contains(index) { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if respectCodeFences, let marker = fenceMarker(trimmed) {
                if fence == nil {
                    fence = marker.byte
                } else if fence == marker.byte {
                    fence = nil
                }
                current.append(line)
                continue
            }
            if respectCodeFences, fence != nil {
                current.append(line)
                continue
            }
            if let heading = headingInfo(trimmed), heading.level <= maxHeadingDepth {
                if heading.level == 1, title == nil {
                    // First `# Title` becomes the document title (and is
                    // dropped from section content).
                    title = heading.title
                    continue
                }
                // A second `#` heading: treat as a new top-level section.
                flush()
                current.append(trimmed)
            } else if let heading = headingInfo(trimmed), heading.level > 1, heading.level <= maxHeadingDepth {
                flush()
                current.append(trimmed)
            } else {
                current.append(line)
            }
        }
        flush()

        let fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedContent(title: title, sections: sections, fullText: fullText)
    }

    private static func headingInfo(_ line: String) -> (level: Int, title: String)? {
        let bytes = Array(line.utf8)
        var level = 0
        while level < bytes.count, bytes[level] == 35 { level += 1 }
        guard level > 0, level < bytes.count, bytes[level] == 32 else { return nil }
        let title = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        return (level, title)
    }

    private static func fenceMarker(_ line: String) -> (byte: UInt8, length: Int)? {
        let bytes = Array(line.utf8)
        guard let first = bytes.first, first == 96 || first == 126 else { return nil }
        var length = 0
        while length < bytes.count, bytes[length] == first { length += 1 }
        return length >= 3 ? (first, length) : nil
    }

    private static func validateText(_ text: String, limits: MarkdownImportLimits) throws {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAllowedWhitespace = value == 9 || value == 10 || value == 13
            let isControl = value <= 31 || (127...159).contains(value)
            let isBidiOrInvisible = (0x200B...0x200F).contains(value)
                || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value)
            guard isAllowedWhitespace || (!isControl && !isBidiOrInvisible && value != 0xFFFD) else {
                throw MarkdownImportError.unsafeText
            }
        }
        for line in text.components(separatedBy: .newlines) {
            guard line.utf8.count <= limits.maxLineBytes else {
                throw MarkdownImportError.budgetExceeded
            }
        }
    }

    private static func validateFrontmatter(
        _ lines: [String],
        limits: MarkdownImportLimits
    ) throws -> Set<Int> {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var skipped = Set<Int>([0])
        var keys = Set<String>()
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            skipped.insert(index)
            if line == "---" { return skipped }
            guard let separator = line.firstIndex(of: ":") else {
                throw MarkdownImportError.malformedStructure
            }
            let key = line[..<separator]
            guard !key.isEmpty, key.count <= limits.maxHeadingCharacters,
                  key.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                          || (97...122).contains(scalar.value) || scalar.value == 45 || scalar.value == 95
                  }), keys.insert(String(key).lowercased()).inserted else {
                throw MarkdownImportError.malformedStructure
            }
        }
        throw MarkdownImportError.malformedStructure
    }

    private static func validateStructure(
        _ lines: [String],
        skippedLines: Set<Int>,
        limits: MarkdownImportLimits
    ) throws {
        var fence: UInt8?
        var resourceCount = 0
        for (index, line) in lines.enumerated() {
            if skippedLines.contains(index) { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(trimmed) {
                if fence == nil { fence = marker.byte }
                else if fence == marker.byte { fence = nil }
                continue
            }
            if fence != nil { continue }
            if let heading = headingInfo(trimmed) {
                guard heading.level <= limits.maxHeadingDepth,
                      !heading.title.isEmpty,
                      heading.title.count <= limits.maxHeadingCharacters else {
                    throw MarkdownImportError.malformedStructure
                }
            }
            resourceCount += try validateResources(in: line, currentCount: resourceCount, limits: limits)
        }
        guard fence == nil else { throw MarkdownImportError.malformedStructure }
    }

    private static func validateResources(
        in line: String,
        currentCount: Int,
        limits: MarkdownImportLimits
    ) throws -> Int {
        var count = 0
        var cursor = line.startIndex
        while cursor < line.endIndex,
              let open = line[cursor...].firstIndex(of: "[") {
            let isImage = open > line.startIndex && line[line.index(before: open)] == "!"
            guard let close = line[open...].firstIndex(of: "]") else {
                throw MarkdownImportError.malformedStructure
            }
            let afterClose = line.index(after: close)
            guard afterClose < line.endIndex, line[afterClose] == "(" else {
                cursor = afterClose
                continue
            }
            guard let end = line[afterClose...].firstIndex(of: ")") else {
                throw MarkdownImportError.malformedStructure
            }
            let destinationStart = line.index(after: afterClose)
            let rawDestination = String(line[destinationStart..<end])
            try validateResourceDestination(rawDestination)
            count += 1
            guard currentCount + count <= limits.maxResourceReferences else {
                throw MarkdownImportError.budgetExceeded
            }
            _ = isImage
            cursor = line.index(after: end)
        }
        return count
    }

    private static func validateResourceDestination(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 32 && scalar.value != 127 && scalar.value < 128
              }) else { throw MarkdownImportError.unsafeResource }
        let token = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? value
        guard !token.hasPrefix("/") && !token.hasPrefix("~") && !token.contains("\\") else {
            throw MarkdownImportError.unsafeResource
        }
        let pathParts = token.split(separator: "/")
        guard !pathParts.contains("..") else { throw MarkdownImportError.unsafeResource }
        if let components = URLComponents(string: token), let scheme = components.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https",
                  components.user == nil, components.password == nil,
                  components.query == nil else { throw MarkdownImportError.unsafeResource }
        }
        guard !token.lowercased().hasPrefix("javascript:"),
              !token.lowercased().hasPrefix("data:"),
              !token.lowercased().hasPrefix("file:") else {
            throw MarkdownImportError.unsafeResource
        }
    }

    /// Parse plain text: no title, paragraphs become sections.
    public static func importPlainText(_ text: String) -> ImportedContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ImportedContent(title: nil, sections: paragraphs, fullText: trimmed)
    }

    /// Read a file's contents as UTF-8 and import it as markdown or plain
    /// text depending on its classified type.
    public static func importFile(
        at url: URL,
        limits: MarkdownImportLimits = .default
    ) throws -> ImportedContent {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MarkdownImportError.unreadable(url, "read-failed")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MarkdownImportError.notUTF8(url)
        }
        switch FileImporter.classify(url: url) {
        case .markdown:
            return try importMarkdownValidated(text, limits: limits)
        default:
            return importPlainText(text)
        }
    }
}

/// Errors raised while importing markdown / text files.
public enum MarkdownImportError: Error, Equatable, Sendable {
    case notUTF8(URL)
    case unreadable(URL, String)
    case invalidLimits
    case budgetExceeded
    case unsafeText
    case unsafeResource
    case malformedStructure

    public var localizedDescription: String {
        switch self {
        case .notUTF8(let url):
            _ = url
            return "File is not valid UTF-8 text"
        case .unreadable(let url, _):
            _ = url
            return "Cannot read imported text"
        case .invalidLimits:
            return "Markdown import limits are invalid"
        case .budgetExceeded:
            return "Markdown import exceeds its safety budget"
        case .unsafeText:
            return "Markdown import contains unsafe text"
        case .unsafeResource:
            return "Markdown import contains an unsafe resource"
        case .malformedStructure:
            return "Markdown structure is invalid"
        }
    }
}
