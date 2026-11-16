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
        case 403:
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
