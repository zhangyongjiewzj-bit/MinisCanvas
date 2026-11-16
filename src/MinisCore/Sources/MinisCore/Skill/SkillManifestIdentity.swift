//
//  SkillManifestIdentity.swift
//  MinisCore
//
//  Canonical identity admission for local skill/plugin catalog consumers.
//  This layer is deliberately value-only: a failed identity is omitted from
//  discovery and never carries a path or manifest payload into diagnostics.
//

import Foundation

/// Stable identity and compatibility checks used at skill catalog boundaries.
///
/// A legacy SKILL.md without a sidecar manifest remains discoverable with an
/// implicit current identity.  When a sidecar exists, it is authoritative and
/// every field that can affect catalog identity is checked before admission.
public struct SkillManifestIdentity: Equatable, Sendable {
    public static let currentSchema = SkillSourceManifest.currentSchema
    public static let currentVersion = SkillSourceManifest.currentVersion
    public static let maxSkillIDBytes = 128
    public static let maxSkillVersionBytes = 128
    public static let maxManifestJSONDepth = 8
    public static let maxManifestCollectionEntries = 32
    public static let maxSourceURLBytes = 2 * 1024
    // Allow a small envelope above the source-URL cap so an oversized URL is
    // classified by the URL policy rather than the generic JSON budget.
    public static let maxManifestJSONStringBytes = maxSourceURLBytes + 32
    private static let maxManifestJSONValues = 256

    public enum Rejection: String, Equatable, Sendable {
        case invalidSkillID
        case invalidSkillVersion
        case malformedManifest
        case unknownSchema
        case unknownManifestVersion
        case manifestSkillIDMismatch
        case manifestSkillVersionMismatch
        case manifestHashMismatch
        case invalidSourceURL
    }

    public let skillID: String
    public let skillVersion: String
    public let source: SkillImportSource?
    public let manifestSchema: String
    public let manifestVersion: Int
    public let isLegacy: Bool

    private init(
        skillID: String,
        skillVersion: String,
        source: SkillImportSource?,
        manifestSchema: String,
        manifestVersion: Int,
        isLegacy: Bool
    ) {
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.source = source
        self.manifestSchema = manifestSchema
        self.manifestVersion = manifestVersion
        self.isLegacy = isLegacy
    }

    /// Resolve a local catalog identity. `manifestData == nil` means the
    /// legacy sidecar-free form; malformed or unsupported present manifests
    /// are rejected rather than downgraded to legacy.
    public static func resolve(
        skillID: String,
        skillVersion: String,
        content: String,
        manifestData: Data? = nil
    ) -> SkillManifestIdentity? {
        guard rejection(
            skillID: skillID,
            skillVersion: skillVersion,
            content: content,
            manifestData: manifestData
        ) == nil else { return nil }

        guard let manifestData,
              let manifest = try? JSONDecoder().decode(SkillSourceManifest.self, from: manifestData)
        else {
            return SkillManifestIdentity(
                skillID: skillID,
                skillVersion: skillVersion,
                source: nil,
                manifestSchema: currentSchema,
                manifestVersion: currentVersion,
                isLegacy: true
            )
        }
        return SkillManifestIdentity(
            skillID: manifest.skillID,
            skillVersion: manifest.skillVersion,
            source: manifest.source,
            manifestSchema: manifest.schema,
            manifestVersion: manifest.version,
            isLegacy: false
        )
    }

    /// Return a machine-stable rejection code without exposing local paths,
    /// manifest bytes, credentials, or remote metadata.
    public static func rejection(
        skillID: String,
        skillVersion: String,
        content: String,
        manifestData: Data? = nil
    ) -> Rejection? {
        guard isValidSkillID(skillID) else { return .invalidSkillID }
        guard isValidSkillVersion(skillVersion) else { return .invalidSkillVersion }
        guard let manifestData else { return nil }
        guard isBoundedManifestJSON(manifestData) else { return .malformedManifest }
        guard let manifest = try? JSONDecoder().decode(SkillSourceManifest.self, from: manifestData)
        else { return .malformedManifest }
        guard manifest.schema == currentSchema else { return .unknownSchema }
        guard manifest.version == currentVersion else { return .unknownManifestVersion }
        guard isValidSkillID(manifest.skillID) else { return .invalidSkillID }
        guard isValidSkillVersion(manifest.skillVersion) else { return .invalidSkillVersion }
        guard isSafeSource(manifest.source) else { return .invalidSourceURL }
        guard manifest.skillID == skillID else { return .manifestSkillIDMismatch }
        guard manifest.skillVersion == skillVersion else { return .manifestSkillVersionMismatch }
        guard manifest.contentHash == SkillManifest.hash(content) else { return .manifestHashMismatch }
        return nil
    }

    /// IDs are directory-safe, bounded, and stable across the App/Hermes
    /// projections.  This check is stricter than a display-name check.
    public static func isValidSkillID(_ value: String) -> Bool {
        guard value.utf8.count <= maxSkillIDBytes,
              SkillFilesystemBoundary.isSafePathComponent(value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// Versions are catalog identity fields, so empty, control-bearing,
    /// path-like, or unbounded values are not compatible identities.
    public static func isValidSkillVersion(_ value: String) -> Bool {
        guard value.utf8.count <= maxSkillVersionBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !SkillFilesystemBoundary.containsControlCharacters(value),
              !value.contains("/"),
              !value.contains("\\")
        else { return false }
        return true
    }

    /// Strip the source namespace from an App/Hermes/picker identity. This is
    /// used only for collision detection; the returned value contains no path.
    public static func canonicalCatalogID(_ value: String) -> String? {
        let prefixes = ["skill:", "app:", "hermes:", "plugin:"]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else {
            return isValidSkillID(value) ? value : nil
        }
        let id = String(value.dropFirst(prefix.count))
        return isValidSkillID(id) ? id : nil
    }

    private static func isBoundedManifestJSON(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return false }
        var scanner = ManifestJSONBudgetScanner(
            data: data,
            maxDepth: maxManifestJSONDepth,
            maxCollectionEntries: maxManifestCollectionEntries,
            maxStringBytes: maxManifestJSONStringBytes,
            maxValues: maxManifestJSONValues
        )
        return scanner.isWithinBudget()
    }

    private static func isSafeSource(_ source: SkillImportSource) -> Bool {
        switch source {
        case .file, .bundled, .session:
            return true
        case .url(let value):
            return isSafeSourceURL(value)
        }
    }

    private static func isSafeSourceURL(_ value: String) -> Bool {
        guard value.utf8.count <= maxSourceURLBytes,
              !SkillFilesystemBoundary.containsControlCharacters(value),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              !hasPathTraversal(components.percentEncodedPath) else { return false }
        return true
    }

    private static func hasPathTraversal(_ encodedPath: String) -> Bool {
        guard let decodedPath = encodedPath.removingPercentEncoding,
              !SkillFilesystemBoundary.containsControlCharacters(decodedPath),
              !decodedPath.contains("\\") else { return true }
        return [encodedPath, decodedPath].contains { path in
            path.split(separator: "/", omittingEmptySubsequences: false)
                .contains { $0 == ".." }
        }
    }

    private struct ManifestJSONBudgetScanner {
        private let bytes: [UInt8]
        private let maxDepth: Int
        private let maxCollectionEntries: Int
        private let maxStringBytes: Int
        private let maxValues: Int
        private var offset = 0
        private var valueCount = 0

        init(
            data: Data,
            maxDepth: Int,
            maxCollectionEntries: Int,
            maxStringBytes: Int,
            maxValues: Int
        ) {
            self.bytes = Array(data)
            self.maxDepth = maxDepth
            self.maxCollectionEntries = maxCollectionEntries
            self.maxStringBytes = maxStringBytes
            self.maxValues = maxValues
        }

        mutating func isWithinBudget() -> Bool {
            skipWhitespace()
            guard scanValue(depth: 0) else { return false }
            skipWhitespace()
            return offset == bytes.count
        }

        private mutating func scanValue(depth: Int) -> Bool {
            guard depth <= maxDepth, valueCount < maxValues else { return false }
            skipWhitespace()
            guard offset < bytes.count else { return false }
            valueCount += 1
            switch bytes[offset] {
            case 0x7B: return scanObject(depth: depth)
            case 0x5B: return scanArray(depth: depth)
            case 0x22: return scanString()
            case 0x74: return scanLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66: return scanLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case 0x6E: return scanLiteral([0x6E, 0x75, 0x6C, 0x6C])
            case 0x2D, 0x30...0x39: return scanNumber()
            default: return false
            }
        }

        private mutating func scanObject(depth: Int) -> Bool {
            guard consume(0x7B) else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }
            var memberCount = 0
            while true {
                guard scanString(), consumeAfterWhitespace(0x3A), scanValue(depth: depth + 1) else {
                    return false
                }
                memberCount += 1
                guard memberCount <= maxCollectionEntries else { return false }
                skipWhitespace()
                if consume(0x7D) { return true }
                guard consume(0x2C) else { return false }
                skipWhitespace()
            }
        }

        private mutating func scanArray(depth: Int) -> Bool {
            guard consume(0x5B) else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }
            var entryCount = 0
            while true {
                guard scanValue(depth: depth + 1) else { return false }
                entryCount += 1
                guard entryCount <= maxCollectionEntries else { return false }
                skipWhitespace()
                if consume(0x5D) { return true }
                guard consume(0x2C) else { return false }
                skipWhitespace()
            }
        }

        private mutating func scanString() -> Bool {
            guard consume(0x22) else { return false }
            let start = offset
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == 0x22 {
                    offset += 1
                    return offset - start - 1 <= maxStringBytes
                }
                guard byte >= 0x20 else { return false }
                if byte == 0x5C {
                    offset += 1
                    guard offset < bytes.count else { return false }
                    switch bytes[offset] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        offset += 1
                    case 0x75:
                        guard offset + 4 < bytes.count,
                              isHex(bytes[offset + 1]),
                              isHex(bytes[offset + 2]),
                              isHex(bytes[offset + 3]),
                              isHex(bytes[offset + 4]) else { return false }
                        offset += 5
                    default:
                        return false
                    }
                } else {
                    offset += 1
                }
                guard offset - start <= maxStringBytes else { return false }
            }
            return false
        }

        private mutating func scanLiteral(_ literal: [UInt8]) -> Bool {
            guard offset + literal.count <= bytes.count,
                  Array(bytes[offset..<(offset + literal.count)]) == literal else {
                return false
            }
            offset += literal.count
            return true
        }

        private mutating func scanNumber() -> Bool {
            let start = offset
            if consume(0x2D) {}
            if consume(0x30) {
                // A leading zero may only be followed by a fraction, exponent,
                // delimiter, or end of input; JSONDecoder performs the final
                // grammar check after this bounded scan.
            } else {
                guard offset < bytes.count, bytes[offset] >= 0x31, bytes[offset] <= 0x39 else {
                    return false
                }
                while offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 {
                    offset += 1
                }
            }
            if consume(0x2E) {
                guard offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 else {
                    return false
                }
                while offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 {
                    offset += 1
                }
            }
            if offset < bytes.count, bytes[offset] == 0x65 || (offset < bytes.count && bytes[offset] == 0x45) {
                offset += 1
                if offset < bytes.count, bytes[offset] == 0x2B || (offset < bytes.count && bytes[offset] == 0x2D) {
                    offset += 1
                }
                guard offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 else {
                    return false
                }
                while offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 {
                    offset += 1
                }
            }
            return offset - start <= maxStringBytes
        }

        private mutating func consumeAfterWhitespace(_ byte: UInt8) -> Bool {
            skipWhitespace()
            return consume(byte)
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        private mutating func skipWhitespace() {
            while offset < bytes.count,
                  bytes[offset] == 0x20 || bytes[offset] == 0x09
                    || bytes[offset] == 0x0A || bytes[offset] == 0x0D {
                offset += 1
            }
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x46)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }
}
