import Foundation

/// Payload-free projection of an Anthropic HTTP failure.
///
/// The body is consulted only for a small allow-list of stable reason labels.
/// No provider message, URL, header value, or body text is retained in the
/// resulting `LLMError` detail.
public enum ProviderAnthropicErrorProjectionPolicy {
    public enum Category: String, Equatable, Sendable {
        case authentication
        case permissionDenied = "permission_denied"
        case notFound = "not_found"
        case rateLimited = "rate_limited"
        case timeout
        case server
        case request
        case transport
    }

    public struct Projection: Equatable, Sendable {
        public let statusCode: Int
        public let category: Category
        public let retryAfterSeconds: Int?
        public let requestIDPresent: Bool
        public let safeDetail: String

        fileprivate init(
            statusCode: Int,
            category: Category,
            retryAfterSeconds: Int?,
            requestIDPresent: Bool,
            safeDetail: String
        ) {
            self.statusCode = statusCode
            self.category = category
            self.retryAfterSeconds = retryAfterSeconds
            self.requestIDPresent = requestIDPresent
            self.safeDetail = safeDetail
        }
    }

    private static let maximumRetryAfterSeconds = 86_400
    private static let maximumBodyBytesForClassification = 64 * 1024

    /// Classifies status and bounded retry/request identity metadata. Body
    /// text can contribute only a fixed allow-listed reason label.
    public static func project(
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = "",
        now: Date = Date()
    ) -> Projection {
        let category = category(for: statusCode)
        let retryAfter = category == .rateLimited
            ? (retryAfterSeconds(from: headers) ?? rateLimitResetSeconds(from: headers, now: now))
            : nil
        let requestIDPresent = hasRequestID(in: headers)

        var fields = [
            "status=\(statusCode)",
            "category=\(category.rawValue)"
        ]
        if let retryAfter {
            fields.append("retry_after=\(retryAfter)")
        }
        if requestIDPresent {
            fields.append("request_id=present")
        }
        if ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: statusCode, body: body) {
            // 余额或额度不足：固定标签，供界面显示“余额或额度不足”并停止自动重试。
            fields.append(ProviderHTTPErrorAdapter.quotaReasonLabel)
        } else if let reason = safeReason(from: body) {
            fields.append("reason=\(reason)")
        }

        return Projection(
            statusCode: statusCode,
            category: category,
            retryAfterSeconds: retryAfter,
            requestIDPresent: requestIDPresent,
            safeDetail: fields.joined(separator: "; ")
        )
    }

    /// Projects an Anthropic SSE `error` event without retaining its message.
    /// The event type is reduced to a stable category; arbitrary diagnostic
    /// text never enters the `LLMError.providerError` associated value.
    public static func projectStreamError(_ event: [String: Any]) -> String {
        let error = event["error"] as? [String: Any]
        let rawType = (error?["type"] as? String)?.lowercased()
        let category: String
        switch rawType {
        case "authentication_error":
            category = Category.authentication.rawValue
        case "permission_error":
            category = Category.permissionDenied.rawValue
        case "not_found_error":
            category = Category.notFound.rawValue
        case "rate_limit_error":
            category = Category.rateLimited.rawValue
        case "overloaded_error":
            category = "server_overloaded"
        case "api_error":
            category = Category.server.rawValue
        case "invalid_request_error":
            category = Category.request.rawValue
        case "timeout_error":
            category = Category.timeout.rawValue
        default:
            category = "stream_error"
        }

        var fields = ["category=\(category)"]
        if hasRequestID(in: event) {
            fields.append("request_id=present")
        }
        return fields.joined(separator: "; ")
    }

    /// 流内 error 事件（HTTP 已经返回 200 之后）映射成与同类 HTTP 失败一致的错误，
    /// 这样用户文案和自动重试都和 529 / 429 / 5xx 走同一套：
    /// overloaded_error → 529，rate_limit_error → 429，api_error → 瞬时错误；其余保持原来的服务错误。
    /// 只带固定类别标签，不带服务端的任何文字。
    public static func streamLLMError(_ event: [String: Any]) -> LLMError {
        let rawType = ((event["error"] as? [String: Any])?["type"] as? String)?.lowercased()
        let requestID = hasRequestID(in: event) ? "; request_id=present" : ""
        switch rawType {
        case "overloaded_error":
            return .httpStatus(code: 529, detail: "status=529; category=\(Category.server.rawValue)" + requestID)
        case "rate_limit_error":
            return .httpStatus(code: 429, detail: "status=429; category=\(Category.rateLimited.rawValue)" + requestID)
        case "api_error":
            return .transientError(message: "The provider reported a temporary server error.")
        default:
            return .providerError(message: projectStreamError(event))
        }
    }

    private static func category(for statusCode: Int) -> Category {
        switch statusCode {
        case 401:
            return .authentication
        case 403:
            return .permissionDenied
        case 404:
            return .notFound
        case 408:
            return .timeout
        case 429:
            return .rateLimited
        case 500...599:
            return .server
        case 400...499:
            return .request
        default:
            return .transport
        }
    }

    private static func retryAfterSeconds(from headers: [String: String]) -> Int? {
        let values = headers.compactMap { entry -> String? in
            guard entry.key.caseInsensitiveCompare("Retry-After") == .orderedSame else {
                return nil
            }
            return entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.count == 1,
              let value = values.first,
              let seconds = Int(value),
              (0...maximumRetryAfterSeconds).contains(seconds) else {
            return nil
        }
        return seconds
    }

    /// 没有 Retry-After 时，改读 `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-reset`
    /// （RFC 3339 时间点），换算成还要等的秒数。优先取 remaining 为 0 的那几类里最晚的；
    /// 没有哪一类标明用完时，取最早的重置点（宁可早试一次，也不无谓地等）。
    private static func rateLimitResetSeconds(from headers: [String: String], now: Date) -> Int? {
        var lowered: [String: String] = [:]
        for (key, value) in headers {
            lowered[key.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var all: [Int] = []
        var exhausted: [Int] = []
        for bucket in ["requests", "tokens", "input-tokens", "output-tokens"] {
            guard let raw = lowered["anthropic-ratelimit-\(bucket)-reset"],
                  let date = parseResetTimestamp(raw) else { continue }
            let seconds = Int(max(0, date.timeIntervalSince(now)).rounded(.up))
            all.append(seconds)
            if lowered["anthropic-ratelimit-\(bucket)-remaining"] == "0" { exhausted.append(seconds) }
        }
        guard let chosen = exhausted.max() ?? all.min() else { return nil }
        return min(chosen, maximumRetryAfterSeconds)
    }

    private static func parseResetTimestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func hasRequestID(in headers: [String: String]) -> Bool {
        headers.contains { entry in
            let key = entry.key.lowercased()
            let isRequestID = key == "request-id"
                || key == "x-request-id"
                || key == "anthropic-request-id"
            return isRequestID
                && !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasRequestID(in event: [String: Any]) -> Bool {
        for key in ["request_id", "request-id", "requestId"] {
            if let value = event[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    /// Keep only stable, non-sensitive labels that help explain a provider
    /// failure. Arbitrary body text is never copied into the error detail.
    private static func safeReason(from body: String) -> String? {
        let lower = String(
            decoding: body.utf8.prefix(maximumBodyBytesForClassification),
            as: UTF8.self
        ).lowercased()
        if lower.contains("invalid api key") || lower.contains("api key is invalid") {
            return "authentication failed"
        }
        if lower.contains("quota exceeded") {
            return "quota exceeded"
        }
        if lower.contains("permission denied") || lower.contains("not authorized") {
            return "permission denied"
        }
        if lower.contains("model not found") {
            return "model not found"
        }
        if lower.contains("rate limit") || lower.contains("rate_limit") || lower.contains("rate limited") {
            return "rate limited"
        }
        if lower.contains("overloaded") {
            return "service overloaded"
        }
        return nil
    }
}
