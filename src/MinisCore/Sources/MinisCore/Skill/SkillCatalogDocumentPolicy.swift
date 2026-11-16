//
//  SkillCatalogDocumentPolicy.swift
//  MinisCore
//
//  Fail-closed admission for SKILL.md parsing at discovery boundaries.
//  SkillStore.parse remains the lifecycle/store parser; catalog callers use
//  this policy first so malformed documents cannot poison the whole catalog.
//

import Foundation

/// The value-only result of admitting one SKILL.md into a catalog scan.
/// No filesystem path or parser error is retained.
public struct SkillCatalogParsedDocument: Equatable, Sendable {
    public let name: String
    public let description: String
    public let argumentHint: String?
    public let version: String
    public let body: String
    public let documentByteCount: Int
    public let frontmatterByteCount: Int
    public let bodyByteCount: Int

    public init(
        name: String,
        description: String,
        version: String,
        body: String,
        documentByteCount: Int,
        frontmatterByteCount: Int,
        bodyByteCount: Int,
        argumentHint: String? = nil
    ) {
        self.argumentHint = argumentHint
        self.name = name
        self.description = description
        self.version = version
        self.body = body
        self.documentByteCount = documentByteCount
        self.frontmatterByteCount = frontmatterByteCount
        self.bodyByteCount = bodyByteCount
    }
}

/// Admission policy applied after the stable SKILL.md snapshot and before a
/// catalog item is built. The policy deliberately mirrors the supported
/// frontmatter forms in `SkillStore.parse`, while rejecting duplicate keys and
/// resource-heavy values before the shared lifecycle parser is invoked.
public enum SkillCatalogDocumentPolicy {
    public static let maxDocumentBytes = SkillStore.maxSkillContentBytes
    public static let maxFrontmatterBytes = 64 * 1024
    public static let maxBodyBytes = SkillStore.maxSkillContentBytes
    public static let maxFieldBytes = 8 * 1024
    public static let maxKeyBytes = 128

    /// Admit a UTF-8-decoded SKILL.md for catalog discovery.
    ///
    /// Duplicate keys are compared case-insensitively across the complete
    /// frontmatter block, including unknown keys. Block scalar continuation
    /// lines are values rather than keys. A malformed document returns nil;
    /// callers can then skip only that entry and continue scanning siblings.
    public static func admit(
        _ content: String,
        maxDocumentBytes: Int = SkillCatalogDocumentPolicy.maxDocumentBytes,
        maxFrontmatterBytes: Int = SkillCatalogDocumentPolicy.maxFrontmatterBytes,
        maxBodyBytes: Int = SkillCatalogDocumentPolicy.maxBodyBytes,
        maxFieldBytes: Int = SkillCatalogDocumentPolicy.maxFieldBytes
    ) -> SkillCatalogParsedDocument? {
        guard maxDocumentBytes >= 0,
              maxFrontmatterBytes >= 0,
              maxBodyBytes >= 0,
              maxFieldBytes >= 0,
              content.utf8.count <= maxDocumentBytes
        else { return nil }

        let lines = content.components(separatedBy: "\n")
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOpeningFence = trimmed.hasPrefix("---")
        let scanStart = hasOpeningFence ? 1 : 0

        var frontmatterEnd: Int?
        if scanStart < lines.count {
            for index in scanStart..<lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                    frontmatterEnd = index
                    break
                }
            }
        }

        let parsed = SkillStore.parse(skillMD: content)
        guard parsed.name.utf8.count <= maxFieldBytes,
              parsed.description.utf8.count <= maxFieldBytes,
              parsed.version.utf8.count <= maxFieldBytes,
              parsed.body.utf8.count <= maxBodyBytes
        else { return nil }

        guard let endIndex = frontmatterEnd else {
            return SkillCatalogParsedDocument(
                name: parsed.name,
                description: parsed.description,
                version: parsed.version,
                body: parsed.body,
                documentByteCount: content.utf8.count,
                frontmatterByteCount: 0,
                bodyByteCount: parsed.body.utf8.count
            )
        }

        if !hasOpeningFence {
            var sawRecognizedKey = false
            let looksLikeFrontmatter = (scanStart..<endIndex).allSatisfy { index in
                let line = lines[index]
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { return true }
                if line.first?.isWhitespace == true { return true }
                guard let colon = line.firstIndex(of: ":") else { return false }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard isValidKey(key) else { return false }
                let lowered = key.lowercased()
                if lowered == "name" || lowered == "description" || lowered == "version" {
                    sawRecognizedKey = true
                }
                return true
            }
            guard looksLikeFrontmatter, sawRecognizedKey else {
                // The shared parser treats an unrecognized leading block as
                // body; preserve that compatibility while still enforcing
                // document/body limits above.
                return SkillCatalogParsedDocument(
                    name: parsed.name,
                    description: parsed.description,
                    version: parsed.version,
                    body: parsed.body,
                    documentByteCount: content.utf8.count,
                    frontmatterByteCount: 0,
                    bodyByteCount: parsed.body.utf8.count
                )
            }
        }

        let frontmatterByteCount = lines[0...endIndex].joined(separator: "\n").utf8.count
        guard frontmatterByteCount <= maxFrontmatterBytes else { return nil }

        var argumentHint: String?
        var keys = Set<String>()
        var index = scanStart
        while index < endIndex {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.first?.isWhitespace == true {
                index += 1
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let rawKey = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard isValidKey(rawKey) else { return nil }
            let key = rawKey.lowercased()
            guard keys.insert(key).inserted else { return nil }

            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let isBlockScalar: Bool = {
                guard let first = rawValue.first, first == "|" || first == ">" else { return false }
                return rawValue.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
            }()
            let resolvedValue: String
            if isBlockScalar, index + 1 < endIndex {
                let fold = rawValue.first == ">"
                var blockLines: [String] = []
                var next = index + 1
                while next < endIndex {
                    let continuation = lines[next]
                    if continuation.isEmpty || continuation.first?.isWhitespace == true {
                        blockLines.append(continuation.trimmingCharacters(in: .whitespaces))
                    } else {
                        break
                    }
                    next += 1
                }
                resolvedValue = fold
                    ? blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    : blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                index = next
            } else {
                resolvedValue = String(rawValue)
                index += 1
            }
            guard resolvedValue.utf8.count <= maxFieldBytes else { return nil }
            if key == "argument-hint" {
                let value = resolvedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 2, let quote = value.first,
                   (quote == "\"" || quote == "'"), value.last == quote {
                    argumentHint = String(value.dropFirst().dropLast())
                } else { argumentHint = value.isEmpty ? nil : value }
            }
        }

        return SkillCatalogParsedDocument(
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            body: parsed.body,
            documentByteCount: content.utf8.count,
            frontmatterByteCount: frontmatterByteCount,
            bodyByteCount: parsed.body.utf8.count,
            argumentHint: argumentHint
        )
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty
            && key.utf8.count <= maxKeyBytes
            && key.allSatisfy { character in
                character.isLetter || character.isNumber || character == "_" || character == "-"
            }
    }
}
