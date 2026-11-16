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
        body: String = ""
    ) -> Projection {
        let category = category(for: statusCode)
        let retryAfter = category == .rateLimited
            ? retryAfterSeconds(from: headers)
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
        if let reason = safeReason(from: body) {
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
