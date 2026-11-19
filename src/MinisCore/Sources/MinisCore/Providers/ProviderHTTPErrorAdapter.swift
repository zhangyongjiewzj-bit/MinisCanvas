import Foundation

/// Secret-free classification at the OpenAI-compatible HTTP boundary.
///
/// Callers provide only the status code and headers needed for retry policy.
/// Response bodies, URLs, query items, and authorization headers are
/// deliberately not accepted or retained. This keeps readiness and LLM
/// error projections typed without creating a second payload-leak path.
public enum ProviderHTTPErrorAdapter {

    /// Retry metadata is advisory and must remain bounded before it reaches
    /// a scheduler. Values outside one day are treated as malformed so an
    /// overflow, non-finite value, negative value, or date-form value cannot
    /// create an unbounded retry delay.
    private static let maxRetryAfterSeconds = 86_400

    public struct Classification: Sendable, Hashable {
        public let statusCode: Int
        public let category: ProviderReadinessFailureCategory
        public let retryAfterSeconds: Int?

        public var isRetryable: Bool {
            category == .timeout || category == .rateLimited || category == .server
        }

        public var readinessError: ProviderReadinessTransportError {
            switch category {
            case .timeout:
                return .timeout
            case .unauthorized:
                return .unauthorized
            case .permissionDenied:
                return .permissionDenied
            case .notFound:
                return .notFound
            case .rateLimited:
                return .rateLimited(retryAfterSeconds: retryAfterSeconds)
            case .server:
                return .server(statusCode: statusCode)
            default:
                return .transport
            }
        }

        /// The HTTP status is preserved, while the compatibility detail is
        /// intentionally empty so no provider response body can escape.
        public var llmError: LLMError {
            .httpStatus(code: statusCode, detail: "")
        }

        fileprivate init(
            statusCode: Int,
            category: ProviderReadinessFailureCategory,
            retryAfterSeconds: Int?
        ) {
            self.statusCode = statusCode
            self.category = category
            self.retryAfterSeconds = retryAfterSeconds
        }
    }

    public struct TransportClassification: Sendable, Hashable {
        public let code: Int
        public let category: ProviderReadinessFailureCategory
        public let isCancelled: Bool

        public var isRetryable: Bool {
            !isCancelled && category == .timeout
        }

        public var readinessError: ProviderReadinessTransportError {
            category == .timeout ? .timeout : .transport
        }

        /// Converts to an LLMError without retaining the original NSError,
        /// localized description, URL, headers, or any provider payload.
        public var llmError: LLMError {
            isCancelled
                ? .cancelled
                : .networkError(underlying: ProviderTransportCodeError(code: code))
        }

        fileprivate init(code: Int, category: ProviderReadinessFailureCategory, isCancelled: Bool) {
            self.code = code
            self.category = category
            self.isCancelled = isCancelled
        }
    }

    /// Classifies an HTTP status using only status and retry metadata.
    public static func classify(
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> Classification {
        let category: ProviderReadinessFailureCategory
        switch statusCode {
        case 401:
            category = .unauthorized
        case 402, 403:
            category = .permissionDenied
        case 404:
            category = .notFound
        case 408:
            category = .timeout
        case 429:
            category = .rateLimited
        case 500...599:
            category = .server
        default:
            category = .transport
        }

        return Classification(
            statusCode: statusCode,
            category: category,
            retryAfterSeconds: category == .rateLimited ? retryAfterSeconds(from: headers) : nil
        )
    }

    /// 固定标签：供应商明确表示余额或额度不足。只写入这个标签，响应正文不带出。
    public static let quotaReasonLabel = "reason=quota"

    /// 只用白名单关键词判断“余额或额度不足”，正文本身不保留、不外传。
    /// 仅在 400/402/403/429 时判定（OpenAI 额度用尽是 429，Anthropic 余额不足是 400）。
    public static func indicatesQuotaExhausted(statusCode: Int, body: String) -> Bool {
        guard [400, 402, 403, 429].contains(statusCode), !body.isEmpty else { return false }
        let lower = String(decoding: body.utf8.prefix(64 * 1024), as: UTF8.self).lowercased()
        // 429 多半是限速（Gemini 免费额度的 RESOURCE_EXHAUSTED / quota exceeded 过一会儿就恢复），
        // 只认明确的计费、余额关键词，不把通用的“额度用尽”当成余额不足。
        let strongBillingKeywords = [
            "insufficient_quota", "insufficient quota",
            "credit balance is too low", "insufficient balance",
            "insufficient_balance", "insufficient credit", "out of credits",
            "billing_hard_limit_reached", "balance is not enough", "arrearage",
            "payment required", "payment_required", "余额不足", "额度不足", "欠费"
        ]
        if statusCode == 429 {
            if strongBillingKeywords.contains(where: { lower.contains($0) }) { return true }
            // Gemini 的限速正文也会写“check your plan and billing details”，同时带
            // RESOURCE_EXHAUSTED / exceeded your current quota，不能凭 billing 判余额不足。
            if lower.contains("resource_exhausted") || lower.contains("exceeded your current quota") {
                return false
            }
            return lower.contains("billing")
        }
        let otherKeywords = strongBillingKeywords + [
            "exceeded your current quota", "quota exceeded"
        ]
        return otherKeywords.contains { lower.contains($0) }
    }

    /// 额度不足的安全详情：状态码、类别和固定标签，不含任何响应正文。
    public static func quotaDetail(statusCode: Int, headers: [String: String] = [:]) -> String {
        let classification = classify(statusCode: statusCode, headers: headers)
        return "status=\(statusCode); category=\(classification.category.rawValue); \(quotaReasonLabel)"
    }

    /// Classifies a transport error by stable code only. Unknown domains are
    /// normalized to `-1`; their domain and localized text are never retained.
    public static func classify(transport error: Error) -> TransportClassification {
        let code: Int
        if let urlError = error as? URLError {
            code = urlError.code.rawValue
        } else {
            let nsError = error as NSError
            code = nsError.domain == NSURLErrorDomain ? nsError.code : -1
        }

        if code == NSURLErrorCancelled {
            return TransportClassification(code: code, category: .transport, isCancelled: true)
        }
        let category: ProviderReadinessFailureCategory = code == NSURLErrorTimedOut
            ? .timeout
            : .transport
        return TransportClassification(code: code, category: category, isCancelled: false)
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
        (0...maxRetryAfterSeconds).contains(seconds) else {
            return nil
        }
        return seconds
    }
}

/// Stable, payload-free transport error used when projecting into LLMError.
public struct ProviderTransportCodeError: Error, Sendable, Hashable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }
}
