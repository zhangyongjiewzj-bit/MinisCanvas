import Foundation

/// Finds value-token spans in validated JSON without serializing its contents.
/// A failed scan returns nil so the caller retains the existing safe projector.
enum FileReadJSONProjection {
    static func redact(_ text: String, sensitiveKey: @escaping (String) -> Bool) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              value is [String: Any] || value is [Any] else { return nil }
        var scanner = Scanner(bytes: Array(text.utf8), sensitiveKey: sensitiveKey)
        return try? scanner.project()
    }

    private struct Scanner {
        enum Failure: Error { case invalidJSON, requiresLegacyProjection }
        let bytes: [UInt8]
        let sensitiveKey: (String) -> Bool
        var position = 0
        var replacements: [Range<Int>] = []

        mutating func project() throws -> String {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
            _ = try value(redactNested: true)
            whitespace()
            guard position == bytes.count else { throw Failure.invalidJSON }
            var output: [UInt8] = []
            var previousEnd = 0
            for range in replacements {
                output.append(contentsOf: bytes[previousEnd..<range.lowerBound])
                output.append(contentsOf: "\"[REDACTED]\"".utf8)
                previousEnd = range.upperBound
            }
            output.append(contentsOf: bytes[previousEnd...])
            return String(decoding: output, as: UTF8.self)
        }

        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) {
                position += 1
            }
        }

        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { throw Failure.invalidJSON }
            position += 1
        }

        mutating func string(checkEscapedSecrets: Bool) throws -> Range<Int> {
            whitespace()
            let start = position
            try consume(34)
            var escaped = false
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 {
                    let range = start..<position
                    if escaped, checkEscapedSecrets {
                        // The legacy projector normalizes escapes before its
                        // free-text scan. Retain that projection if an escape
                        // could hide a credential from the raw-byte scan.
                        let decoded = try JSONSerialization.jsonObject(
                            with: Data(bytes[range]), options: .fragmentsAllowed) as? String
                        if let decoded, MCPServerSecretPolicy.redactText(decoded) != decoded {
                            throw Failure.requiresLegacyProjection
                        }
                    }
                    return range
                }
                if byte == 92 {
                    escaped = true
                    guard position < bytes.count else { throw Failure.invalidJSON }
                    position += 1
                }
            }
            throw Failure.invalidJSON
        }

        mutating func value(redactNested: Bool) throws -> Range<Int> {
            whitespace()
            let start = position
            guard position < bytes.count else { throw Failure.invalidJSON }
            switch bytes[position] {
            case 123:
                try object(redactNested: redactNested)
            case 91:
                try array(redactNested: redactNested)
            case 34:
                _ = try string(checkEscapedSecrets: redactNested)
            default:
                while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) {
                    position += 1
                }
                guard position > start else { throw Failure.invalidJSON }
            }
            return start..<position
        }

        mutating func object(redactNested: Bool) throws {
            try consume(123)
            whitespace()
            if position < bytes.count, bytes[position] == 125 { position += 1; return }
            while true {
                let keyRange = try string(checkEscapedSecrets: redactNested)
                guard let key = try JSONSerialization.jsonObject(
                    with: Data(bytes[keyRange]), options: .fragmentsAllowed) as? String else {
                    throw Failure.invalidJSON
                }
                try consume(58)
                let shouldRedact = redactNested && sensitiveKey(key)
                let range = try value(redactNested: redactNested && !shouldRedact)
                if shouldRedact { replacements.append(range) }
                whitespace()
                guard position < bytes.count else { throw Failure.invalidJSON }
                if bytes[position] == 125 { position += 1; return }
                try consume(44)
            }
        }

        mutating func array(redactNested: Bool) throws {
            try consume(91)
            whitespace()
            if position < bytes.count, bytes[position] == 93 { position += 1; return }
            while true {
                _ = try value(redactNested: redactNested)
                whitespace()
                guard position < bytes.count else { throw Failure.invalidJSON }
                if bytes[position] == 93 { position += 1; return }
                try consume(44)
            }
        }
    }
}
