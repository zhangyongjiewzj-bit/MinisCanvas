import Foundation
import CryptoKit

/// A deterministic, human-editable Markdown representation of memory facts.
///
/// The Markdown body is intentionally small and familiar: facts are grouped
/// under category headings and represented by ordinary list items.  A compact
/// HTML comment immediately before each item keeps the stable fact identity and
/// the fields needed for an exact round trip.  The comment is metadata only;
/// it is never interpreted as an instruction or executed as Markdown.
public enum MemoryMarkdownCodec {
    public static let currentVersion = 1
    public static let formatMarker = "miniscanvas-memory-format"
    public static let factMarker = "miniscanvas-memory-fact"

    /// The parsed document and the hash of the exact source bytes.
    public struct Document: Equatable, Sendable {
        public let facts: [MemoryFact]
        public let sourceHash: String
        public let sourceText: String
        public let formatVersion: Int

        public init(
            facts: [MemoryFact],
            sourceHash: String,
            sourceText: String,
            formatVersion: Int = MemoryMarkdownCodec.currentVersion
        ) {
            self.facts = facts
            self.sourceHash = sourceHash
            self.sourceText = sourceText
            self.formatVersion = formatVersion
        }

        public var categoryCounts: [MemoryCategory: Int] {
            facts.reduce(into: [:]) { counts, fact in
                counts[fact.category, default: 0] += 1
            }
        }
    }

    /// Errors are deliberately typed so the settings surface can distinguish
    /// an empty document, malformed metadata, and a content conflict.
    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case invalidUTF8
        case emptyDocument
        case unsupportedVersion(Int)
        case malformedLine(Int)
        case malformedMetadata(Int)
        case malformedVersion(Int)
        case invalidFactID(Int)
        case duplicateFactID(String)
        case duplicateFactText(String)
        case unsupportedCategory(String, Int)

        public var errorDescription: String? {
            switch self {
            case .invalidUTF8:
                return "记忆 Markdown 不是有效的 UTF-8 文件。"
            case .emptyDocument:
                return "记忆 Markdown 没有可导入的记忆条目。"
            case .unsupportedVersion(let version):
                return "记忆 Markdown 版本 \(version) 不受支持。"
            case .malformedLine(let line):
                return "记忆 Markdown 第 \(line) 行格式无法识别。"
            case .malformedMetadata(let line):
                return "记忆 Markdown 第 \(line) 行的事实元数据损坏。"
            case .malformedVersion(let line):
                return "记忆 Markdown 第 \(line) 行的版本标记损坏。"
            case .invalidFactID(let line):
                return "记忆 Markdown 第 \(line) 行的事实 ID 无效。"
            case .duplicateFactID(let id):
                return "记忆 Markdown 含有重复事实 ID：\(id)。"
            case .duplicateFactText(let text):
                return "记忆 Markdown 含有重复记忆内容：\(text)。"
            case .unsupportedCategory(let category, let line):
                return "记忆 Markdown 第 \(line) 行的分类「\(category)」不受支持。"
            }
        }
    }

    /// Parse exact bytes into a document.  The source hash is over the input
    /// bytes, so a preview can later reject a changed or substituted file.
    public static func decode(_ data: Data) throws -> Document {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        let sourceHash = digest(data)
        let facts = try parseLines(text)
        return Document(
            facts: facts,
            sourceHash: sourceHash,
            sourceText: text,
            formatVersion: (try version(in: text)) ?? currentVersion
        )
    }

    public static func decode(markdown: String) throws -> Document {
        try decode(Data(markdown.utf8))
    }

    /// Compatibility spelling for callers that only need parsed facts.
    public static func parse(_ markdown: String) throws -> [MemoryFact] {
        try decode(markdown: markdown).facts
    }

    public static func parse(_ data: Data) throws -> [MemoryFact] {
        try decode(data).facts
    }

    /// Render a deterministic Markdown document.  Facts are grouped by the
    /// four public categories while preserving their order inside each group.
    public static func encode(_ facts: [MemoryFact]) throws -> Data {
        Data(try encodeString(facts).utf8)
    }

    public static func encode(facts: [MemoryFact]) throws -> Data {
        try encode(facts)
    }

    public static func encodeString(_ facts: [MemoryFact]) throws -> String {
        var seenIDs = Set<String>()
        for fact in facts {
            let id = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw Error.invalidFactID(0) }
            guard !text.isEmpty else { throw Error.emptyDocument }
            guard seenIDs.insert(id).inserted else { throw Error.duplicateFactID(id) }
        }

        var output = "# MinisCanvas Memory\n\n"
        output += "<!-- \(formatMarker): \(currentVersion) -->\n\n"
        let categories: [MemoryCategory] = [.userPref, .lesson, .security, .fact]
        for category in categories {
            let matching = facts.filter { $0.category == category }
            guard !matching.isEmpty else { continue }
            output += "## \(category.label)\n\n"
            for fact in matching {
                let metadata = try metadataJSON(for: fact)
                output += "<!-- \(factMarker): \(metadata) -->\n"
                output += "- \(markdownText(fact.text))\n\n"
            }
        }
        return output
    }

    public static func encodeMarkdown(_ facts: [MemoryFact]) throws -> Data {
        try encode(facts)
    }

    public static func markdown(from facts: [MemoryFact]) throws -> String {
        try encodeString(facts)
    }

    // MARK: - Parsing

    private struct FactMetadata: Codable {
        let id: String
        let sourceSessionID: String
        let memoryScope: MemoryScope?
        let ownerUserID: String?
        let createdAt: Date
        let category: MemoryCategory
        let sourceProposalID: String?
        let sourceRef: String?
        let contentDigest: String?
        let revision: Int
        let supersedesFactID: String?
        let lifecycleState: MemoryFactLifecycleState
        let activatedAt: Date?

        init(fact: MemoryFact) {
            id = fact.id
            sourceSessionID = fact.sourceSessionID
            memoryScope = fact.memoryScope
            ownerUserID = fact.ownerUserID
            createdAt = fact.createdAt
            category = fact.category
            sourceProposalID = fact.sourceProposalID
            sourceRef = fact.sourceRef
            contentDigest = fact.contentDigest
            revision = fact.revision
            supersedesFactID = fact.supersedesFactID
            lifecycleState = fact.lifecycleState
            activatedAt = fact.activatedAt
        }
    }

    private static func parseLines(_ text: String) throws -> [MemoryFact] {
        let lines = text.components(separatedBy: .newlines)
        let formatVersion = try version(in: text)
        if let formatVersion, formatVersion != currentVersion {
            throw Error.unsupportedVersion(formatVersion)
        }

        var category: MemoryCategory?
        var pendingMetadata: FactMetadata?
        var facts: [MemoryFact] = []
        var seenIDs = Set<String>()
        var inCodeFence = false

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                pendingMetadata = nil
                continue
            }
            if inCodeFence { continue }
            if line.hasPrefix("<!--") {
                if let metadataPayload = metadataPayload(in: line) {
                    pendingMetadata = try decodeMetadata(metadataPayload, line: lineNumber)
                } else if line.hasPrefix("<!-- \(factMarker):") {
                    throw Error.malformedMetadata(lineNumber)
                }
                continue
            }
            if line.hasPrefix("#") {
                if let heading = headingText(from: line),
                   let parsedCategory = Self.category(forHeading: heading) {
                    category = parsedCategory
                } else if line.hasPrefix("##") || line.hasPrefix("###") {
                    // A heading that looks like a category is a contract error;
                    // accepting it as general prose would hide a typo.
                    if line.hasPrefix("##") {
                        let heading = headingText(from: line) ?? ""
                        if !heading.isEmpty {
                            throw Error.unsupportedCategory(heading, lineNumber)
                        }
                    }
                }
                continue
            }
            if let bullet = bulletText(from: line) {
                let text = unescapeMarkdownText(bullet)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw Error.malformedLine(lineNumber) }
                let resolvedCategory = category ?? pendingMetadata?.category ?? .fact
                let fact = makeFact(
                    text: text,
                    category: resolvedCategory,
                    metadata: pendingMetadata
                )
                let id = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { throw Error.invalidFactID(lineNumber) }
                guard seenIDs.insert(id).inserted else { throw Error.duplicateFactID(id) }
                facts.append(fact)
                pendingMetadata = nil
                continue
            }

            // Ordinary explanatory prose is allowed anywhere in the document;
            // only list items become facts.  A bare list marker is still a
            // malformed fact entry and is rejected rather than silently
            // turning into an empty memory.
            if line == "-" || line == "*" || line == "+" {
                throw Error.malformedLine(lineNumber)
            }
            pendingMetadata = nil
        }

        guard !facts.isEmpty else { throw Error.emptyDocument }
        return facts
    }

    private static func makeFact(
        text: String,
        category: MemoryCategory,
        metadata: FactMetadata?
    ) -> MemoryFact {
        let stableID = (metadata?.id.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? deterministicID(category: category, text: text)
        let contentDigest: String?
        if let metadata,
           metadata.contentDigest != nil
                || metadata.sourceProposalID != nil
                || metadata.sourceRef != nil {
            // Recalculate after an editor changes the visible bullet text;
            // MemoryStore validates the provenance digest before persisting.
            contentDigest = MemoryStore.contentDigest(for: text)
        } else {
            contentDigest = nil
        }
        return MemoryFact(
            id: stableID,
            text: text,
            sourceSessionID: metadata?.sourceSessionID ?? "",
            createdAt: metadata?.createdAt ?? Date(timeIntervalSince1970: 0),
            category: category,
            memoryScope: metadata?.memoryScope,
            ownerUserID: metadata?.ownerUserID,
            sourceProposalID: metadata?.sourceProposalID,
            sourceRef: metadata?.sourceRef,
            contentDigest: contentDigest,
            revision: metadata?.revision ?? 1,
            supersedesFactID: metadata?.supersedesFactID,
            lifecycleState: metadata?.lifecycleState ?? .active,
            activatedAt: metadata?.activatedAt
        )
    }

    private static func deterministicID(category: MemoryCategory, text: String) -> String {
        let payload = Data("miniscanvas-memory-v1\n\(category.rawValue)\n\(text)".utf8)
        return digest(payload).prefix(32).description
    }

    private static func decodeMetadata(_ payload: String, line: Int) throws -> FactMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = payload.data(using: .utf8),
              let metadata = try? decoder.decode(FactMetadata.self, from: data) else {
            throw Error.malformedMetadata(line)
        }
        guard !metadata.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.invalidFactID(line)
        }
        let provenanceValues = [metadata.sourceProposalID, metadata.sourceRef, metadata.contentDigest]
        if provenanceValues.contains(where: { $0 != nil }) {
            guard provenanceValues.allSatisfy({
                guard let value = $0 else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw Error.malformedMetadata(line)
            }
        }
        return metadata
    }

    private static func metadataJSON(for fact: MemoryFact) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Keep a user supplied source reference from terminating the HTML
        // comment that carries metadata.  JSON decoding restores the escaped
        // `>` character transparently.
        return String(decoding: try encoder.encode(FactMetadata(fact: fact)), as: UTF8.self)
            .replacingOccurrences(of: "-->", with: "--\\u003e")
    }

    private static func metadataPayload(in line: String) -> String? {
        let prefix = "<!-- \(factMarker):"
        guard line.hasPrefix(prefix), line.hasSuffix("-->") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -3)
        return String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func version(in text: String) throws -> Int? {
        let prefix = "<!-- \(formatMarker):"
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            guard line.hasSuffix("-->") else {
                throw Error.malformedVersion(offset + 1)
            }
            let start = line.index(line.startIndex, offsetBy: prefix.count)
            let end = line.index(line.endIndex, offsetBy: -3)
            guard let parsed = Int(
                String(line[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw Error.malformedVersion(offset + 1)
            }
            return parsed
        }
        return nil
    }

    private static func headingText(from line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        return String(line.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func category(forHeading heading: String) -> MemoryCategory? {
        let normalized = heading
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "用户偏好", "偏好", "userpref", "userpreferences", "preference", "preferences", "personalpreference":
            return .userPref
        case "经验教训", "经验", "教训", "lesson", "lessons", "experience", "learnings", "lessonslearned", "经验和教训", "经验与教训":
            return .lesson
        case "安全", "security", "safety", "privacy":
            return .security
        case "一般事实", "事实", "一般", "fact", "facts", "general", "generalfact", "generalfacts":
            return .fact
        default:
            return nil
        }
    }

    private static func bulletText(from line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        var digits = ""
        for character in line {
            guard character.isNumber else { break }
            digits.append(character)
        }
        guard !digits.isEmpty,
              line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    private static func markdownText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescapeMarkdownText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Alias kept public so app consumers can use a descriptive name in APIs.
public typealias MemoryMarkdownDocument = MemoryMarkdownCodec.Document
