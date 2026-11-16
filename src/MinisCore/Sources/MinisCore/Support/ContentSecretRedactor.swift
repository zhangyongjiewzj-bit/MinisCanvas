import Foundation

/// Content-level redaction seam for summaries that may embed secret values
/// inside otherwise non-secret free-form text (approval digests, tool-history
/// records, tool-error text).
///
/// Two layers, both preserving non-secret text verbatim:
/// 1. known-secret values (configured env vars) via `EnvVarRedactor` —
///    exact substring replacement, longest-first, no regex;
/// 2. format-based embedded-secret patterns — Bearer tokens, `sk-...` keys,
///    credential query params / assignments / headers, and URL userinfo
///    (`scheme://user:pass@`), plus the pinned Gitleaks format rules.
///
/// Masking rule is the app-wide one: `EnvVarRedactor.redact`
/// (all characters replaced with asterisks). The app never
/// invents a second masking policy. Gitleaks source records and MIT attribution
/// are retained under docs/third-party/gitleaks-v8.24.3.
public enum ContentSecretRedactor {
    /// Conservative fast negative shared with the Composer credential capture.
    /// Every current format expression contains one of these ASCII pairs. Any
    /// pair, or a cased non-ASCII scalar whose Unicode case fold might create
    /// one, falls through to the original regex path. Uncased scalars break an
    /// ASCII pair; they cannot fold into an ASCII letter. A false result proves
    /// only that format matching is unnecessary; known values must still be masked.
    public static func mayContainFormatTrigger(_ text: String) -> Bool {
        if GitleaksSecretRules.containsMatch(text) { return true }
        var previous: UInt8 = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard value < 0x80 else {
                if scalar.properties.isCased { return true }
                previous = 0
                continue
            }
            let byte = UInt8(value)
            let current = byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
            switch previous {
            case 0x61: if current == 0x70 || current == 0x75 { return true } // ap, au
            case 0x62: if current == 0x65 { return true } // be
            case 0x63: if current == 0x6F { return true } // co
            case 0x68: if current == 0x74 { return true } // ht
            case 0x6B: if current == 0x65 { return true } // ke
            case 0x70: if current == 0x61 { return true } // pa
            case 0x73: if current == 0x65 || current == 0x6B { return true } // se, sk
            case 0x74: if current == 0x6F { return true } // to
            default: break
            }
            previous = current
        }
        return false
    }

    /// A format check bound to immutable source content. Clients cannot supply
    /// an unchecked negative or apply its result to a different string.
    public struct FormatCheckedText: Sendable {
        public let text: String
        public let mayContainFormatTrigger: Bool

        public init(_ text: String) {
            self.text = text
            self.mayContainFormatTrigger = ContentSecretRedactor.mayContainFormatTrigger(text)
        }
    }

    /// Reuse a format-negative only while known-value masking leaves exactly
    /// the checked bytes unchanged. Changed content always uses the original
    /// format scan, including any triggers introduced by masking.
    public static func redact(_ checked: FormatCheckedText, knownSecrets: [String] = []) -> String {
        let result = redactKnownSecrets(in: checked.text, values: knownSecrets)
        if !checked.mayContainFormatTrigger,
           knownSecrets.isEmpty || result.utf8.elementsEqual(checked.text.utf8) {
            return result
        }
        return redactFormats(in: result)
    }

    /// Mask a single value with the app-wide masking rule.
    public static func mask(_ value: String) -> String {
        EnvVarRedactor.redact(value)
    }

    /// Redact embedded secrets from free-form `text`.
    /// - Parameters:
    ///   - text: free-form text (may embed secrets in prose).
    ///   - knownSecrets: known secret values to mask exactly (env store values).
    /// - Returns: `text` with secret values masked; non-secret text preserved.
    public static func redact(_ text: String, knownSecrets: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        // Explicitly supplied values are authoritative, including short
        // credentials that generic redaction intentionally ignores.
        return redactFormats(in: redactKnownSecrets(in: text, values: knownSecrets))
    }

    private static func redactFormats(in text: String) -> String {
        var result = GitleaksSecretRules.redact(text)
        // Every format below necessarily contains one of these literals.
        // Use the same ICU case folding as the authoritative patterns (including
        // Unicode folds); a failed probe compilation falls back to every scan.
        // Known opaque credentials have already been protected above.
        if !mayContainFormatTrigger(result) { return result }
        if let probe = formatProbe,
           probe.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) == nil {
            return result
        }
        // Order matters: sk- keys first (masks the whole token incl. prefix),
        // then Bearer tokens (already-masked `***` values no longer match the
        // token char classes), then credential params/headers, then userinfo.
        // EnvVarRedactor.redact is idempotent, so later patterns re-masking an
        // already-masked value leave it unchanged.
        result = replace(result, regex: skKeyRegex, tokenGroup: -1)
        result = replace(result, regex: bearerTokenRegex, tokenGroup: 1)
        result = replace(result, regex: quotedDoubleQueryParamRegex, tokenGroup: 2)
        result = replace(result, regex: quotedSingleQueryParamRegex, tokenGroup: 2)
        result = replace(result, regex: queryParamRegex, tokenGroup: 2)
        result = replace(result, regex: quotedDoubleAssignmentRegex, tokenGroup: 2)
        result = replace(result, regex: quotedSingleAssignmentRegex, tokenGroup: 2)
        result = replace(result, regex: assignmentRegex, tokenGroup: 2)
        result = replace(result, regex: authHeaderRegex, tokenGroup: 2)
        result = redactCookieHeaders(in: result)
        result = replace(result, regex: userinfoRegex, tokenGroup: 2)
        return result
    }

    /// Conversation-body URL admission only. Reuse the existing credential
    /// name grammar even when a query value is empty or below format thresholds.
    static func isCredentialURLQueryName(_ name: String) -> Bool {
        guard let regex = credentialURLQueryNameRegex else { return true }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    // MARK: Patterns

    /// `sk-...` provider keys (OpenAI-style): mask the whole match.
    private static let skKeyPattern = #"\bsk-[A-Za-z0-9_\-]{8,}"#

    /// `Bearer <token>`: mask the token, keep the `Bearer ` prefix.
    /// Token char class allows `.` `_` `-` `=` `+` `/` (JWT / API tokens).
    private static let bearerTokenPattern = #"(?i)\bBearer\s+([A-Za-z0-9_\-\.=+/]{8,})"#

    /// Credential query params: `?api_key=...` / `&token=...` — mask the value.
    /// Name must END with a sensitive term (`(?![A-Za-z0-9_\-])`) so `keyword=`
    /// is not mistaken for `key=`.
    private static let sensitiveName = "(?:api[_-]?key|apikey|key|token|access[_-]?token|auth|password|secret|cookie|session[_-]?id)"
    private static let credentialURLQueryNameRegex = try? NSRegularExpression(
        pattern: "(?i)^[A-Za-z0-9_\\-]*" + sensitiveName + "$"
    )
    private static let queryParamPattern = "(?i)([?&][A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)([^&\\s\"']{4,})"
    private static let quotedDoubleQueryParamPattern = "(?i)([?&][A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)\"([^\"\\r\\n]{1,})\""
    private static let quotedSingleQueryParamPattern = "(?i)([?&][A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)'([^'\\r\\n]{1,})'"
    /// Credential assignments: `export FOO_KEY=...` / `FOO_TOKEN=...`.
    /// Value class excludes `&` so a trailing query string (`...&page=2`) survives.
    private static let assignmentPattern = "(?i)(\\b[A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)(?=[^&\\s\"'`]{4,})([；，。][^&\\s\"'`]*|[^&\\s\"'`；，。]+)"
    private static let quotedDoubleAssignmentPattern = "(?i)(\\b[A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)\"([^\"\\r\\n]{1,})\""
    private static let quotedSingleAssignmentPattern = "(?i)(\\b[A-Za-z0-9_\\-]*" + sensitiveName + "(?![A-Za-z0-9_\\-])[A-Za-z0-9_\\-]*=)'([^'\\r\\n]{1,})'"
    /// Auth / API-key header values (whole rest-of-line). `\s*` in group 1 can
    /// split the single space before `Bearer` either side of `:`, so the guard
    /// must tolerate leading whitespace before the value (`(?!\\s*Bearer\\b)`).
    private static let authHeaderPattern = "(?i)((?:api[_-]?key|x-api-key|proxy-authorization|authorization)\\s*:\\s*)(?!\\s*Bearer\\b)([^\r\n\"']{4,})"
    /// URL userinfo: `https://user:pass@` — mask the userinfo, keep `@`.
    private static let userinfoPattern = "(https?://)([^/@\\s:]+:[^/@\\s]*)@"

    private static let formatProbe = try? NSRegularExpression(
        pattern: #"(?i)sk-|bearer|key|token|auth|password|secret|cookie|session|https?://"#
    )

    // Compile immutable grammar once. NSRegularExpression matching is
    // thread-safe; input, matches and masked values remain local to each call.
    private static let skKeyRegex = try? NSRegularExpression(pattern: skKeyPattern)
    private static let bearerTokenRegex = try? NSRegularExpression(pattern: bearerTokenPattern)
    private static let quotedDoubleQueryParamRegex = try? NSRegularExpression(pattern: quotedDoubleQueryParamPattern)
    private static let quotedSingleQueryParamRegex = try? NSRegularExpression(pattern: quotedSingleQueryParamPattern)
    private static let queryParamRegex = try? NSRegularExpression(pattern: queryParamPattern)
    private static let quotedDoubleAssignmentRegex = try? NSRegularExpression(pattern: quotedDoubleAssignmentPattern)
    private static let quotedSingleAssignmentRegex = try? NSRegularExpression(pattern: quotedSingleAssignmentPattern)
    private static let assignmentRegex = try? NSRegularExpression(pattern: assignmentPattern)
    private static let authHeaderRegex = try? NSRegularExpression(pattern: authHeaderPattern)
    private static let userinfoRegex = try? NSRegularExpression(pattern: userinfoPattern)

    private static let cookieHeaderRegex = try? NSRegularExpression(pattern: #"(?i)\b(?:cookie|set-cookie)[ \t]*:[ \t]*"#)
    private static let cookiePairRegex = try? NSRegularExpression(pattern: #"([^\s;=\"'\r\n]+[ \t]*=[ \t]*)?(\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s;\"'\r\n]*)"#)
    private static let cookieSeparatorRegex = try? NSRegularExpression(pattern: #"[ \t]*;[ \t]*"#)

    /// Cookie names cannot establish which values are credentials. Parse all
    /// adjacent pairs, including short and quoted values. A newline, closing
    /// shell quote, or prose after a value stays outside the parsed header.
    private static func redactCookieHeaders(in text: String) -> String {
        guard let header = cookieHeaderRegex,
              let pair = cookiePairRegex,
              let separator = cookieSeparatorRegex else { return text }
        let source = text as NSString
        var values: [NSRange] = []
        var consumedThrough = 0
        for start in header.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            // A header-like string inside a quoted cookie value is already
            // covered by that value, rather than being a second overlapping edit.
            guard start.range.location >= consumedThrough else { continue }
            var cursor = NSMaxRange(start.range)
            var first = true
            while cursor < source.length,
                  let match = pair.firstMatch(in: text, options: .anchored,
                                              range: NSRange(location: cursor, length: source.length - cursor)),
                  match.range.length > 0 {
                // Only the first item may be an opaque header value. Later
                // items require name=value, so semicolon-separated prose stays.
                guard first || match.range(at: 1).location != NSNotFound else { break }
                var value = match.range(at: 2)
                if value.length >= 2 {
                    let leading = source.substring(with: NSRange(location: value.location, length: 1))
                    if leading == "\"" || leading == "'" {
                        value.location += 1
                        value.length -= 2
                    }
                }
                if value.length > 0 { values.append(value) }
                cursor = NSMaxRange(match.range)
                consumedThrough = cursor
                guard let next = separator.firstMatch(in: text, options: .anchored,
                                                      range: NSRange(location: cursor, length: source.length - cursor)) else { break }
                cursor = NSMaxRange(next.range)
                first = false
            }
        }
        var result = text
        for value in values.reversed() {
            guard let range = Range(value, in: result) else { continue }
            result.replaceSubrange(range, with: mask(source.substring(with: value)))
        }
        return result
    }

    private static func redactKnownSecrets(in text: String, values: [String]) -> String {
        let candidates = Set(values.filter { !$0.isEmpty }).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
        var result = text
        for value in candidates {
            result = result.replacingOccurrences(of: value, with: mask(value))
        }
        return result
    }

    /// Replace every match of the compiled pattern with the masked capture (or whole match
    /// when `tokenGroup < 0`), walking matches from the end so earlier ranges
    /// stay valid.
    private static func replace(_ text: String, regex: NSRegularExpression?, tokenGroup: Int) -> String {
        guard let regex else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let range = tokenGroup >= 0 ? match.range(at: tokenGroup) : match.range
            guard range.location != NSNotFound, let r = Range(range, in: result) else { continue }
            result.replaceSubrange(r, with: mask(String(result[r])))
        }
        return result
    }
}
