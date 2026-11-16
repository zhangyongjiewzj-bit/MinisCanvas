import Foundation
import CoreFoundation

private func mcpUTF8Prefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for character in text {
        let characterBytes = String(character).utf8.count
        guard usedBytes + characterBytes <= maxBytes else { break }
        result.append(character)
        usedBytes += characterBytes
    }
    return result
}

/// The bounded terminal reason shared by tool output, request budgets, and
/// loop protection.  A terminal reason is deliberately machine-readable and
/// fail-closed so consumers never have to infer safety from display text.
public struct ToolTerminalReason: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case outputTruncated = "output-truncated"
        case requestBudgetExhausted = "request-budget-exhausted"
        case requestBudgetExpired = "request-budget-expired"
        case requestBudgetInvalid = "request-budget-invalid"
        case loopDetected = "loop-detected"
    }

    public static let maxMessageCharacters = 160

    public let code: Code
    public let message: String
    /// Terminal reasons never authorize an automatic retry or route change.
    public let failClosed: Bool

    public init(code: Code, message: String) {
        self.code = code
        self.message = mcpUTF8Prefix(message, maxBytes: Self.maxMessageCharacters)
        self.failClosed = true
    }

    public static func outputTruncated(maximumCharacters: Int) -> Self {
        Self(
            code: .outputTruncated,
            message: "MCP output exceeded the "
                + String(max(0, maximumCharacters))
                + "-byte bound"
        )
    }

    public static let requestBudgetExhausted = Self(
        code: .requestBudgetExhausted,
        message: "Request budget exhausted"
    )

    public static let requestBudgetExpired = Self(
        code: .requestBudgetExpired,
        message: "Request deadline exceeded"
    )

    public static let requestBudgetInvalid = Self(
        code: .requestBudgetInvalid,
        message: "Request budget configuration is invalid"
    )

    public static let loopDetected = Self(
        code: .loopDetected,
        message: "Repeated tool invocation blocked"
    )
}

/// A bounded tool projection.  The payload is optional at a terminal
/// boundary; when a reason is present, consumers must treat it as final.
public struct BoundedToolOutput: Codable, Equatable, Sendable {
    public let text: String
    public let terminalReason: ToolTerminalReason?

    public init(text: String, terminalReason: ToolTerminalReason? = nil) {
        self.text = mcpUTF8Prefix(text, maxBytes: MCPOutputLimiter.defaultMaximumCharacters)
        self.terminalReason = terminalReason
    }
}

/// Deterministic UTF-8 byte bound for text returned by an MCP tool.
public enum MCPOutputLimiter {
    public static let defaultMaximumCharacters = 32_000
    public static let truncationMarker = "...[truncated]"
    private static let streamedRedactionCarryBytes = 1_024

    /// Joins streamed MCP text parts without first materializing an
    /// unbounded intermediate string. A bounded carry lets redaction see
    /// credentials split across chunks while the cumulative byte budget
    /// prevents later chunks from expanding the published projection.
    public static func limit<S: Sequence>(_ segments: S, to maximumCharacters: Int) -> String where S.Element == String {
        let maximum = max(0, maximumCharacters)
        guard maximum > 0 else { return "" }
        guard maximum > truncationMarker.utf8.count else {
            return mcpUTF8Prefix("truncated", maxBytes: maximum)
        }

        let sourceBudget = maximum + streamedRedactionCarryBytes
        var buffered: [String] = []
        buffered.reserveCapacity(8)
        var bufferedBytes = 0
        var sourceWasTruncated = false
        for rawSegment in segments {
            let remaining = sourceBudget - bufferedBytes
            guard remaining > 0 else {
                sourceWasTruncated = true
                break
            }
            let segment = mcpUTF8Prefix(rawSegment, maxBytes: remaining)
            buffered.append(segment)
            bufferedBytes += segment.utf8.count
            if segment.utf8.count < rawSegment.utf8.count {
                sourceWasTruncated = true
                break
            }
        }

        let joined = buffered.joined()
        let joinedIsJSONShaped = looksLikeJSONDocument(joined)
        let rendered = redactStreamSegments(buffered, joined: joined)
        let contentLimit = maximum - truncationMarker.utf8.count
        if sourceWasTruncated, joinedIsJSONShaped {
            return minimalValidJSON(maxBytes: maximum)
        }
        if sourceWasTruncated {
            // The unread suffix could complete a credential that begins in
            // the bounded carry. Do not publish a prefix whose safety cannot
            // be proven; the terminal marker is the fail-closed projection.
            return truncationMarker
        }
        if let structured = redactSensitiveJSON(joined) {
            return limitJSON(MCPServerSecretPolicy.redactText(structured), to: maximum)
        }
        if joinedIsJSONShaped {
            return minimalValidJSON(maxBytes: maximum)
        }
        guard rendered.utf8.count <= contentLimit else {
            return mcpUTF8Prefix(rendered, maxBytes: contentLimit) + truncationMarker
        }
        return rendered
    }

    /// True when `text` begins like a JSON object/array document (including one
    /// that was cut off). Plain text that merely starts with a bracket, such as
    /// `[FILE] a.txt`, `[ERROR] boom` or `{not json`, is not JSON-shaped.
    private static func looksLikeJSONDocument(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        guard let opener = trimmed.first, opener == "{" || opener == "[" else { return false }
        let body = trimmed.dropFirst().drop { $0.isWhitespace }
        guard let next = body.first else { return true }
        if opener == "{" { return next == "\"" || next == "}" }
        if next == "{" || next == "[" || next == "\"" || next == "]" { return true }
        // A scalar first element (`[1,` / `[true,`) only counts as JSON when the
        // scalar token is followed by `,` or the end of the text, so `[1] foo`,
        // `[2024-01-01] log` and `[12:30] msg` stay plain text.
        let isNumeric = next == "-" || next.isASCII && next.isNumber
        let token = isNumeric
            ? body.prefix { "+-.eE".contains($0) || $0.isASCII && $0.isNumber }
            : body.prefix { $0.isASCII && $0.isLetter }
        let after = body.dropFirst(token.count).drop { $0.isWhitespace }.first
        guard after == nil || after == "," else { return false }
        if isNumeric { return Double(token) != nil }
        let literals = ["true", "false", "null"]
        return literals.contains(String(token))
            || (after == nil && literals.contains { $0.hasPrefix(token) })
    }

    public static func limit(_ text: String, to maximumCharacters: Int) -> String {
        limit(text, to: maximumCharacters, preservingSettingsCatalogMetadata: false)
    }

    private static func limit(_ text: String, to maximumCharacters: Int,
                              preservingSettingsCatalogMetadata: Bool) -> String {
        let maximum = max(0, maximumCharacters)
        guard maximum > 0 else { return "" }
        let structuredJSON = redactSensitiveJSON(text,
            preservingSettingsCatalogMetadata: preservingSettingsCatalogMetadata)
        let redacted = MCPServerSecretPolicy.redactText(structuredJSON ?? text)
        if structuredJSON != nil {
            return limitJSON(redacted, to: maximum)
        }
        guard redacted.utf8.count > maximum else { return redacted }
        guard maximum > truncationMarker.utf8.count else {
            return mcpUTF8Prefix("truncated", maxBytes: maximum)
        }
        return mcpUTF8Prefix(redacted, maxBytes: maximum - truncationMarker.utf8.count) + truncationMarker
    }

    /// Project JSON-shaped remote output before applying the UTF-8 byte bound.
    /// Sensitive fields are replaced by a constant marker while ordinary
    /// fields (including remote正文) remain available subject to truncation.
    public static func project(_ text: String, to maximumCharacters: Int = defaultMaximumCharacters) -> String {
        limit(text, to: maximumCharacters)
    }

    /// The built-in file reader preserves source bytes around redacted values.
    /// Other tools retain the established structured MCP projection.
    public static func projectFileRead(_ text: String, to maximumCharacters: Int = defaultMaximumCharacters) -> String {
        guard let structured = FileReadJSONProjection.redact(text, sensitiveKey: isSensitiveKey) else {
            return project(text, to: maximumCharacters)
        }
        let maximum = max(0, maximumCharacters)
        guard maximum > 0 else { return "" }
        let redacted = MCPServerSecretPolicy.redactText(structured)
        guard redacted.utf8.count > maximum else { return redacted }
        guard maximum > truncationMarker.utf8.count else {
            return mcpUTF8Prefix("truncated", maxBytes: maximum)
        }
        return mcpUTF8Prefix(redacted, maxBytes: maximum - truncationMarker.utf8.count) + truncationMarker
    }

    /// Only the registered built-in settings_catalog result may use this
    /// projection. Remote MCP and other tools retain the ordinary projector.
    /// Descriptor classification and already-redacted typed markers are status
    /// metadata; this grants no write authority and exposes no credential value.
    public static func projectSettingsCatalog(
        _ text: String, to maximumCharacters: Int = defaultMaximumCharacters
    ) -> String {
        limit(text, to: maximumCharacters, preservingSettingsCatalogMetadata: true)
    }

    /// Return the bounded payload and its explicit terminal reason when the
    /// bound changed the projected output.  The reason is the same contract
    /// used by request-budget and loop-protection producers.
    public static func projectResult(
        _ text: String,
        to maximumCharacters: Int = defaultMaximumCharacters
    ) -> BoundedToolOutput {
        let projected = limit(text, to: maximumCharacters)
        let redacted = redactSensitiveJSON(text) ?? text
        let wasTruncated = redacted.utf8.count > max(0, maximumCharacters)
        return BoundedToolOutput(
            text: projected,
            terminalReason: wasTruncated
                ? .outputTruncated(maximumCharacters: maximumCharacters)
                : nil
        )
    }

    private static let sensitiveKeyFragments = [
        "token", "secret", "password", "authorization", "credential",
        "api_key", "apikey", "access_key", "private_key", "cookie"
    ]

    private static let settingsCatalogCounterKeys: Set<String> = [
        "usage.session.total-tokens", "context.used-tokens", "context.window-tokens"
    ]

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    /// Return a deterministic redacted JSON representation when `text` is a
    /// JSON object/array, otherwise nil so ordinary prose stays byte-for-byte
    /// compatible. JSON is sorted to keep downstream projections stable.
    private static func redactSensitiveJSON(_ text: String,
                                             preservingSettingsCatalogMetadata: Bool = false) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else {
            return nil
        }
        let projected = redactJSONValue(value, key: nil,
            settingsCatalog: preservingSettingsCatalogMetadata, isRoot: true)
        guard JSONSerialization.isValidJSONObject(projected),
              let output = try? JSONSerialization.data(
                  withJSONObject: projected,
                  options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func redactSensitiveText(_ text: String) -> String {
        MCPServerSecretPolicy.redactText(redactSensitiveJSON(text) ?? text)
    }

    private static func redactStreamSegments(_ segments: [String], joined: String) -> String {
        let separatelyRedacted = segments.map(redactSensitiveText)
        let concatenatedRedaction = redactSensitiveText(joined)
        // Preserve the established newline projection when no credential or
        // JSON structure crosses a chunk boundary. Once it does, publish the
        // contiguous redacted result so a split token cannot leak its prefix.
        if concatenatedRedaction == separatelyRedacted.joined() {
            return separatelyRedacted.joined(separator: "\n")
        }
        return concatenatedRedaction
    }

    /// Keep JSON structurally valid when the redacted representation exceeds
    /// the byte budget. A raw prefix would cut through a string/object and
    /// publish malformed JSON to the bridge consumer.
    private static func limitJSON(_ redactedJSON: String, to maximumBytes: Int) -> String {
        guard redactedJSON.utf8.count > maximumBytes else { return redactedJSON }
        guard maximumBytes > truncationMarker.utf8.count else { return minimalValidJSON(maxBytes: maximumBytes) }

        let base: [String: Any] = ["truncated": true, "preview": ""]
        guard let baseData = try? JSONSerialization.data(withJSONObject: base, options: [.sortedKeys]) else {
            return minimalValidJSON(maxBytes: maximumBytes)
        }
        if baseData.count > maximumBytes {
            let markerJSON = "\"\(truncationMarker)\""
            return markerJSON.utf8.count <= maximumBytes
                ? markerJSON
                : minimalValidJSON(maxBytes: maximumBytes)
        }

        var preview = mcpUTF8Prefix(redactedJSON, maxBytes: maximumBytes - baseData.count)
        while true {
            let candidate: [String: Any] = ["truncated": true, "preview": preview]
            if let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]),
               data.count <= maximumBytes {
                return String(decoding: data, as: UTF8.self)
            }
            guard !preview.isEmpty else {
                return String(decoding: baseData, as: UTF8.self)
            }
            preview.removeLast()
        }
    }

    private static func minimalValidJSON(maxBytes: Int) -> String {
        guard maxBytes >= 2 else { return "" }
        return "{}"
    }

    private static func redactSettingsCatalogDescriptor(_ value: Any) -> Any {
        guard let entry = value as? [String: Any],
              Set(entry.keys) == Set(["id", "kind", "agentMutable", "secret"]),
              let id = entry["id"] as? String, !id.isEmpty,
              let kind = entry["kind"] as? String, BL6SettingValueKind(rawValue: kind) != nil,
              let mutable = entry["agentMutable"] as? NSNumber,
              CFGetTypeID(mutable) == CFBooleanGetTypeID(),
              let secret = entry["secret"] as? NSNumber,
              CFGetTypeID(secret) == CFBooleanGetTypeID() else {
            return redactJSONValue(value, key: nil, settingsCatalog: true)
        }
        return ["id": id, "kind": kind, "agentMutable": mutable.boolValue,
                "secret": secret.boolValue] as [String: Any]
    }

    private static func redactJSONValue(_ value: Any, key: String?,
                                        settingsCatalog: Bool = false, isRoot: Bool = false) -> Any {
        if let key, isSensitiveKey(key) {
            // An exact typed status marker cannot carry a credential value.
            // Rebuild its two public fields; never forward an arbitrary object.
            if settingsCatalog, let marker = value as? [String: Any],
               Set(marker.keys) == Set(["kind", "present"]),
               marker["kind"] as? String == "redactedSecret",
               let present = marker["present"] as? NSNumber,
               CFGetTypeID(present) == CFBooleanGetTypeID() {
                return ["kind": "redactedSecret", "present": present.boolValue] as [String: Any]
            }
            // Usage/context counters are public numbers whose catalog ids merely
            // contain "tokens". Only the exact typed integer shape passes.
            if settingsCatalog, settingsCatalogCounterKeys.contains(key),
               let counter = value as? [String: Any],
               Set(counter.keys) == Set(["kind", "integer"]),
               counter["kind"] as? String == "integer",
               let number = counter["integer"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               Double(exactly: number.int64Value) == number.doubleValue {
                return ["kind": "integer", "integer": number.intValue] as [String: Any]
            }
            // This exact receipt field is a status, not a secret value. Only
            // JSON false is safe: reject true, numeric 0 and string "false".
            if key == "secretValuesExposed", let flag = value as? NSNumber,
               CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue {
                return false
            }
            return "[REDACTED]"
        }
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                if settingsCatalog, isRoot, entry.key == "entries", let entries = entry.value as? [Any] {
                    result[entry.key] = entries.map(redactSettingsCatalogDescriptor)
                } else {
                    result[entry.key] = redactJSONValue(entry.value, key: entry.key, settingsCatalog: settingsCatalog)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONValue($0, key: nil, settingsCatalog: settingsCatalog) }
        }
        return value
    }
}
