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

private func mcpCharPrefix(_ text: String, maxChars: Int) -> String {
    guard maxChars > 0 else { return "" }
    return String(text.prefix(maxChars))
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
            message: "Tool output exceeded the "
                + String(max(0, maximumCharacters))
                + "-character bound"
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
        self.text = mcpCharPrefix(text, maxChars: MCPOutputLimiter.defaultMaximumCharacters)
        self.terminalReason = terminalReason
    }
}

/// Deterministic character bound (not bytes, so Chinese text is not cut three
/// times earlier than ASCII) for text returned to the model by any tool.
public enum MCPOutputLimiter {
    public static let defaultMaximumCharacters = 100_000
    public static let truncationMarker = "...[truncated]"
    private static let streamedRedactionCarryBytes = 1_024
    /// Room reserved for the human-readable truncation explanation.
    private static let truncationNoteReserve = 120
    private static let truncationNoteMinimumBound = 400

    /// Prefix + explanation of how much was kept + the stable marker. The
    /// explanation tells the model the total length so it can narrow its request.
    private static func truncatedText(_ text: String, maximum: Int, totalCharacters: Int? = nil,
                                      atLeast: Bool = false) -> String {
        let marker = truncationMarker
        guard maximum > marker.count else { return mcpCharPrefix("truncated", maxChars: maximum) }
        guard maximum >= truncationNoteMinimumBound else {
            return mcpCharPrefix(text, maxChars: maximum - marker.count) + marker
        }
        let kept = maximum - marker.count - truncationNoteReserve
        let total = totalCharacters ?? text.count
        let note = "\n[输出过长：共\(atLeast ? "超过 " : " ")\(total) 字符，此处只保留前 \(kept) 字符，其余未显示；请缩小范围或分段获取]"
        return mcpCharPrefix(text, maxChars: kept) + note + marker
    }

    /// Joins streamed MCP text parts without first materializing an
    /// unbounded intermediate string. A bounded carry lets redaction see
    /// credentials split across chunks while the cumulative byte budget
    /// prevents later chunks from expanding the published projection.
    public static func limit<S: Sequence>(_ segments: S, to maximumCharacters: Int) -> String where S.Element == String {
        let maximum = max(0, maximumCharacters)
        guard maximum > 0 else { return "" }
        guard maximum > truncationMarker.count else {
            return mcpCharPrefix("truncated", maxChars: maximum)
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
            let segment = mcpCharPrefix(rawSegment, maxChars: remaining)
            buffered.append(segment)
            bufferedBytes += segment.count
            if segment.count < rawSegment.count {
                sourceWasTruncated = true
                break
            }
        }

        let joined = buffered.joined()
        let joinedIsJSONShaped = looksLikeJSONDocument(joined)
        let rendered = redactStreamSegments(buffered, joined: joined)
        let contentLimit = maximum - truncationMarker.count
        if sourceWasTruncated {
            // The unread suffix could complete a credential that begins in
            // the bounded carry. Redact what was read, then publish only the
            // part that ends well before the carry region, so a credential
            // straddling the cut is never exposed. The model still gets the
            // beginning of the output and is told it was cut.
            var visible = joinedIsJSONShaped ? redactSensitiveJSONPairs(rendered) : rendered
            visible = String(visible.prefix(max(0, visible.count - streamedRedactionCarryBytes)))
            return truncatedText(visible, maximum: maximum, totalCharacters: sourceBudget, atLeast: true)
        }
        if let structured = redactSensitiveJSON(joined) {
            return limitJSON(MCPServerSecretPolicy.redactText(structured), to: maximum, originalCharacters: joined.count)
        }
        if joinedIsJSONShaped {
            return minimalValidJSON(maxBytes: maximum)
        }
        guard rendered.count <= contentLimit else {
            return truncatedText(rendered, maximum: maximum)
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
            return limitJSON(redacted, to: maximum, originalCharacters: text.count)
        }
        guard redacted.count > maximum else { return redacted }
        return truncatedText(redacted, maximum: maximum)
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
        // file_read 的正文每行带 cat -n 行号前缀，整段不再是合法 JSON：先剥掉前缀，按正文做脱敏
        // （JSON 里的密钥值才会被识别），再把前缀按行接回；行数对不上时宁可不带行号也不带密钥。
        if let numbered = splitLineNumberedFileRead(text) {
            let projected = projectFileReadBody(numbered.body, to: maximumCharacters)
            let lines = projected.components(separatedBy: "\n")
            let rebuilt: String
            if lines.count == numbered.prefixes.count {
                rebuilt = zip(numbered.prefixes, lines).map { $0 + $1 }.joined(separator: "\n") + numbered.trailer
            } else {
                rebuilt = projected + numbered.trailer
            }
            guard maximumCharacters > 0 else { return "" }
            return rebuilt.count > maximumCharacters ? truncatedText(rebuilt, maximum: maximumCharacters) : rebuilt
        }
        return projectFileReadBody(text, to: maximumCharacters)
    }

    /// 把 `"   12\t内容"` 形式的逐行输出拆成（前缀数组, 正文, 末尾说明）。
    /// 只有开头连续的编号行算正文；其后的截断提示等行原样作为末尾说明。没有编号行时返回 nil。
    private static func splitLineNumberedFileRead(_ text: String) -> (prefixes: [String], body: String, trailer: String)? {
        let lines = text.components(separatedBy: "\n")
        var prefixes: [String] = []
        var bodyLines: [String] = []
        for line in lines {
            let scalars = Array(line.unicodeScalars)
            var index = 0
            while index < scalars.count, scalars[index] == " " { index += 1 }
            let digitsStart = index
            while index < scalars.count, scalars[index].value >= 48, scalars[index].value <= 57 { index += 1 }
            guard index > digitsStart, index < scalars.count, scalars[index] == "\t" else { break }
            prefixes.append(String(String.UnicodeScalarView(scalars[...index])))
            bodyLines.append(String(String.UnicodeScalarView(scalars[(index + 1)...])))
        }
        guard !prefixes.isEmpty else { return nil }
        let trailerLines = lines.dropFirst(prefixes.count)
        // 末尾说明本应只有截断提示；万一是未编号的正文，也要过一遍通用脱敏。
        let trailer = trailerLines.isEmpty ? "" : "\n" + MCPServerSecretPolicy.redactText(trailerLines.joined(separator: "\n"))
        return (prefixes, bodyLines.joined(separator: "\n"), trailer)
    }

    private static func projectFileReadBody(_ text: String, to maximumCharacters: Int) -> String {
        guard let structured = FileReadJSONProjection.redact(text, sensitiveKey: isSensitiveKey) else {
            return project(text, to: maximumCharacters)
        }
        let maximum = max(0, maximumCharacters)
        guard maximum > 0 else { return "" }
        let redacted = MCPServerSecretPolicy.redactText(structured)
        guard redacted.count > maximum else { return redacted }
        return truncatedText(redacted, maximum: maximum)
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
        let wasTruncated = redacted.count > max(0, maximumCharacters)
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
    /// the budget. A raw prefix would cut through a string/object and publish
    /// malformed JSON to the bridge consumer. The wrapper keeps the beginning
    /// of the document and states the total length.
    /// `total_characters` reports the original full text length (before redaction
    /// and re-serialization), so the model knows how much the tool really returned.
    private static func limitJSON(_ redactedJSON: String, to maximum: Int, originalCharacters: Int? = nil) -> String {
        guard redactedJSON.count > maximum else { return redactedJSON }
        let total = originalCharacters ?? redactedJSON.count
        guard maximum > truncationMarker.count else { return minimalValidJSON(maxBytes: maximum) }

        func render(_ length: Int) -> String? {
            let candidate: [String: Any] = [
                "truncated": true, "total_characters": total,
                "preview": String(redactedJSON.prefix(length))
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]) else {
                return nil
            }
            let text = String(decoding: data, as: UTF8.self)
            return text.count <= maximum ? text : nil
        }
        guard var best = render(0) else {
            let markerJSON = "\"\(truncationMarker)\""
            return markerJSON.count <= maximum ? markerJSON : minimalValidJSON(maxBytes: maximum)
        }
        var low = 0, high = min(redactedJSON.count, maximum)
        while low < high {
            let mid = (low + high + 1) / 2
            if let rendered = render(mid) { best = rendered; low = mid } else { high = mid - 1 }
        }
        return best
    }

    /// Text-level redaction of `"sensitive_key": value` pairs, for JSON that is
    /// too large or too cut-off to parse. Values become "[REDACTED]".
    private static let sensitiveJSONPairExpression: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"("(?:[^"\\]|\\.)*(?:token|secret|password|authorization|credential|api[_-]?key|access[_-]?key|private[_-]?key|cookie)(?:[^"\\]|\\.)*"\s*:\s*)("(?:[^"\\]|\\.)*"?|[^,}\]\s]+)"#,
        options: [.caseInsensitive])

    private static func redactSensitiveJSONPairs(_ text: String) -> String {
        guard let expression = sensitiveJSONPairExpression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "$1\"[REDACTED]\"")
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
