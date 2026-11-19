import Foundation

/// Errors crossing the provider boundary carry diagnostics without exposing remote payloads.
public enum LLMError: Error, LocalizedError, Sendable, CustomStringConvertible {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    case transientError(message: String)
    case decodingError(underlying: Error)
    case rateLimited
    case cancelled
    case unsupportedCapability(ProviderCapability)
    case unknown(underlying: Error?)
    case httpStatus(code: Int, detail: String)
    case contextLengthExceeded

    /// 供应商明确表示余额或额度不足（只看固定标签，不看响应正文）。
    public var isQuotaExhausted: Bool {
        if case .httpStatus(_, let detail) = self {
            return detail.contains(ProviderHTTPErrorAdapter.quotaReasonLabel)
        }
        return false
    }

    /// 授权类失败：API Key 无效、过期或没有权限（401/403，不含额度不足）。界面据此给“检查 API Key”入口。
    public var isAuthorizationFailure: Bool {
        switch self {
        case .invalidAPIKey: return true
        case .httpStatus(let code, _): return (code == 401 || code == 403) && !isQuotaExhausted
        default: return false
        }
    }

    public var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    public static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? LLMError { return error.isRetryable }
        if let error = error as? URLError { return error.code != .cancelled }
        return false
    }

    public var providerFailureCategory: ProviderReadinessFailureCategory? {
        switch self {
        case .invalidAPIKey: return .unauthorized
        case .networkError: return networkCode == .timedOut ? .timeout : .transport
        case .transientError: return .server
        case .rateLimited: return .rateLimited
        case .httpStatus(let code, _):
            switch code {
            case 400, 422: return .invalidConfiguration
            case 401: return .unauthorized
            case 402, 403: return .permissionDenied
            case 404: return .notFound
            case 408: return .timeout
            case 429: return .rateLimited
            case 500...599: return .server
            default: return .transport
            }
        default: return nil
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkError, .transientError: return true
        case .httpStatus(let code, _): return !isQuotaExhausted && HTTPStatusMessages.isTransient(code)
        default: return false
        }
    }

    public var isFallbackable: Bool {
        switch self {
        case .invalidAPIKey, .rateLimited, .providerError: return true
        case .httpStatus(let code, _): return isQuotaExhausted || [401, 403, 404, 429].contains(code)
        default: return false
        }
    }

    public var fallbackReason: String {
        switch self {
        case .httpStatus(let code, _): return "http_status_\(code)"
        default: return presentation.tag
        }
    }

    public var technicalDetail: String {
        switch self {
        case .invalidAPIKey: return "invalidAPIKey"
        case .networkError(let error):
            if let transport = error as? ProviderTransportCodeError {
                return "networkError ProviderTransportCodeError code=\(transport.code)"
            }
            let value = error as NSError
            let domain = value.domain == NSURLErrorDomain ? NSURLErrorDomain : "network"
            return "networkError domain=\(domain) code=\(value.code)"
        case .providerError: return "providerError"
        case .transientError: return "transientError"
        case .decodingError: return "decodingError"
        case .rateLimited: return "rateLimited"
        case .cancelled: return "cancelled"
        case .unsupportedCapability(let capability): return "unsupportedCapability: \(capability.rawValue)"
        case .unknown: return "unknown"
        case .httpStatus(let code, _): return "HTTP \(code)"
        case .contextLengthExceeded: return "contextLengthExceeded"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid or expired API key"
        case .networkError: return "Network error"
        case .providerError(let message):
            return message == "画布 LLM 节点未配置 modelID，请先配置该节点模型" ? message : "Provider error"
        case .transientError: return "Service temporarily unavailable"
        case .decodingError: return "Decoding error"
        case .rateLimited: return "Rate limited — please try again later"
        case .cancelled: return "Request was cancelled"
        case .unsupportedCapability(let capability): return "Provider does not support capability: \(capability.rawValue)"
        case .unknown: return "Unknown error"
        case .httpStatus(let code, _): return "HTTP \(code)"
        case .contextLengthExceeded: return "Context length exceeded"
        }
    }

    public var description: String { errorDescription ?? "Unknown error" }

    public func friendlyMessage(locale: Locale = .current) -> String {
        let chinese = locale.language.languageCode?.identifier == "zh"
        if !chinese {
            switch networkCode {
            case .timedOut:
                return "❌ 网络错误 / Network Error（network）：Request timed out — please check your network or retry later"
            case .cannotConnectToHost:
                return "❌ 网络错误 / Network Error（network）：Cannot connect to the server — please check your network or the service address"
            default: break
            }
        }
        let metadata = presentation
        return "❌ \(chinese ? metadata.zh : metadata.en)（\(metadata.tag)）：\(chinese ? userMessageZH : userMessageEN)"
    }

    private var presentation: (zh: String, en: String, tag: String) {
        switch self {
        case .invalidAPIKey: return ("API Key 无效", "Invalid API Key", "401/403")
        case .networkError: return ("网络错误", "Network Error", "network")
        case .providerError: return ("服务错误", "Provider Error", "provider")
        case .transientError: return ("服务暂时不可用", "Service Unavailable", "5xx")
        case .decodingError: return ("解析错误", "Decoding Error", "parse")
        case .rateLimited: return ("请求限流", "Rate Limited", "429")
        case .cancelled: return ("请求取消", "Cancelled", "cancel")
        case .unsupportedCapability: return ("能力不支持", "Unsupported Capability", "capability")
        case .unknown: return ("未知错误", "Unknown Error", "unknown")
        case .httpStatus(let code, _):
            if isQuotaExhausted { return ("余额或额度不足", "Insufficient balance or quota", String(code)) }
            let message = HTTPStatusMessages.message(for: code)
            return (message.zh, message.en, String(code))
        case .contextLengthExceeded: return ("上下文超长", "Context Too Long", "context")
        }
    }

    public var userMessageZH: String {
        switch self {
        case .invalidAPIKey: return "API Key 无效或已过期，请检查 API Key 配置"
        case .networkError: return networkExplanation.zh
        case .providerError: return "模型服务请求失败，请检查供应商配置。"
        case .transientError: return "模型服务暂时不可用，请稍后重试。"
        case .decodingError: return "无法解析模型服务的响应。"
        case .rateLimited: return "请求过于频繁，已触发限流，请稍后重试"
        case .cancelled: return "请求已取消。"
        case .unsupportedCapability: return "当前供应商不支持所需能力。"
        case .unknown: return "发生未知错误，请稍后重试。"
        case .contextLengthExceeded: return "对话内容超出了模型的上下文窗口，请压缩对话或精简内容后重发。"
        case .httpStatus(let code, _):
            if isQuotaExhausted { return "账户余额或额度不足，请到供应商处充值，或更换 API Key 后重试。" }
            let value = HTTPStatusMessages.message(for: code)
            return value.zh + (value.suggestionZH.isEmpty ? "" : " " + value.suggestionZH)
        }
    }

    public var userMessageEN: String {
        switch self {
        case .invalidAPIKey: return "The API key is invalid. Check the provider configuration."
        case .networkError: return networkExplanation.en
        case .providerError: return "The model request failed. Check the provider configuration."
        case .transientError: return "The model service is temporarily unavailable. Try again later."
        case .decodingError: return "The model response could not be decoded."
        case .rateLimited: return "Too many requests — rate limited, please try again later"
        case .cancelled: return "The request was cancelled."
        case .unsupportedCapability: return "The provider does not support the required capability."
        case .unknown: return "An unknown error occurred. Try again later."
        case .contextLengthExceeded: return "The conversation exceeds the model context window. Compact the conversation or shorten the input, then resend."
        case .httpStatus(let code, _):
            if isQuotaExhausted { return "The account balance or quota is insufficient. Top up at the provider or switch API keys, then retry." }
            let value = HTTPStatusMessages.message(for: code)
            return value.en + (value.suggestionEN.isEmpty ? "" : " " + value.suggestionEN)
        }
    }

    private var networkCode: URLError.Code? {
        guard case .networkError(let error) = self else { return nil }
        if let error = error as? URLError { return error.code }
        if let error = error as? ProviderTransportCodeError { return URLError.Code(rawValue: error.code) }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: value.code)
    }

    private var networkExplanation: (zh: String, en: String) {
        switch networkCode {
        case .notConnectedToInternet:
            return ("网络连接失败，请检查网络是否可用", "Network connection failed — please check if you are online")
        case .timedOut:
            return ("请求超时，请稍后重试。", "The request timed out. Try again later.")
        case .cannotConnectToHost:
            return ("无法连接到服务器，请检查网络连接。", "The server could not be reached. Check your connection.")
        case .cannotFindHost, .dnsLookupFailed:
            return ("无法解析服务器地址，请检查网络设置。", "The server address could not be resolved. Check your network settings.")
        case .networkConnectionLost:
            return ("网络连接中断，请重试。", "The network connection was interrupted. Try again.")
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return ("无法建立安全连接，请检查网络与证书设置。", "A secure connection could not be established. Check your network and certificate settings.")
        default:
            return ("网络请求失败，请检查连接后重试。", "The network request failed. Check your connection and try again.")
        }
    }
}
