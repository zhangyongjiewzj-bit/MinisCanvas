import Foundation

/// E20 中英文 HTTP 状态码 → 用户友好信息映射表。
///
/// 供 `LLMError.httpStatus(code:detail:)` 使用：把 401/403/404/429/5xx 等
/// 常见 API 错误翻译成中英双语用户信息 + 建议操作，避免把原始 JSON body
/// 直接展示给用户。
public enum HTTPStatusMessages {

    /// 一条状态码对应的双语信息。
    public struct StatusMessage: Sendable, Equatable {
        /// 中文用户信息（如 "API Key 无效或已过期"）。
        public let zh: String
        /// 英文用户信息（如 "Invalid or expired API key"）。
        public let en: String
        /// 中文建议操作（可为空字符串）。
        public let suggestionZH: String
        /// 英文建议操作（可为空字符串）。
        public let suggestionEN: String

        public init(zh: String, en: String, suggestionZH: String = "", suggestionEN: String = "") {
            self.zh = zh
            self.en = en
            self.suggestionZH = suggestionZH
            self.suggestionEN = suggestionEN
        }
    }

    /// 按状态码查映射表；未知状态码返回通用兜底信息。
    public static func message(for code: Int) -> StatusMessage {
        switch code {
        case 400:
            return StatusMessage(
                zh: "请求参数错误",
                en: "Bad request",
                suggestionZH: "请检查请求内容是否正确",
                suggestionEN: "Please check the request payload"
            )
        case 401:
            return StatusMessage(
                zh: "API Key 无效或已过期",
                en: "Invalid or expired API key",
                suggestionZH: "请检查该服务商的 API Key",
                suggestionEN: "Please check this provider’s API key"
            )
        case 402:
            return StatusMessage(
                zh: "账户欠费或额度不足",
                en: "Payment required / insufficient quota",
                suggestionZH: "请检查账户余额或充值后重试",
                suggestionEN: "Please check your account balance or top up and retry"
            )
        case 403:
            return StatusMessage(
                zh: "账户欠费或没有该模型的访问权限",
                en: "Insufficient quota or no permission for this model",
                suggestionZH: "请检查账户余额、API Key 权限，或确认已开通该模型",
                suggestionEN: "Please check your balance, API key permissions, or model access"
            )
        case 404:
            return StatusMessage(
                zh: "模型不存在或模型 ID 错误",
                en: "Model not found or wrong model ID",
                suggestionZH: "请检查模型 ID 是否正确、该模型是否已上线",
                suggestionEN: "Please check the model ID or whether the model is available"
            )
        case 408:
            return StatusMessage(
                zh: "请求超时",
                en: "Request timeout",
                suggestionZH: "请检查网络后重试",
                suggestionEN: "Please check your network and retry"
            )
        case 409:
            return StatusMessage(
                zh: "请求冲突",
                en: "Request conflict",
                suggestionZH: "请稍后重试",
                suggestionEN: "Please retry later"
            )
        case 413:
            return StatusMessage(
                zh: "请求内容太大，服务端拒收",
                en: "Request body too large",
                suggestionZH: "请缩短这条消息或减少附件（图片、视频帧）的数量，或改为路径引用后分批发送",
                suggestionEN: "Please shorten this message or reduce attachments, or send them by path reference in batches"
            )
        case 422:
            return StatusMessage(
                zh: "请求内容无法处理",
                en: "Unprocessable request",
                suggestionZH: "请检查请求参数是否符合模型要求",
                suggestionEN: "Please check the request parameters"
            )
        case 429:
            return StatusMessage(
                zh: "请求过于频繁，已触发限流",
                en: "Too many requests — rate limited",
                suggestionZH: "请稍后重试或降低请求频率",
                suggestionEN: "Please retry later or lower the request frequency"
            )
        case 500, 501:
            return StatusMessage(
                zh: "服务端内部错误",
                en: "Server internal error",
                suggestionZH: "服务端异常，请稍后重试",
                suggestionEN: "Server error, please retry later"
            )
        case 502, 503, 504:
            return StatusMessage(
                zh: "服务暂时不可用",
                en: "Service temporarily unavailable",
                suggestionZH: "请稍后重试",
                suggestionEN: "Please retry later"
            )
        case 529:
            return StatusMessage(
                zh: "服务过载",
                en: "Service overloaded",
                suggestionZH: "请稍后重试",
                suggestionEN: "Please retry later"
            )
        default:
            return StatusMessage(
                zh: "服务端返回错误（HTTP \(code)）",
                en: "Server returned an error (HTTP \(code))",
                suggestionZH: "请稍后重试，若持续出现请联系服务方",
                suggestionEN: "Please retry later; contact the provider if it persists"
            )
        }
    }

    /// Typed, payload-free guidance for provider readiness failures.
    ///
    /// Readiness probes deliberately do not retain response bodies, so these
    /// messages must remain actionable using only the normalized category.
    /// In particular, a readiness 404 means the configured endpoint is wrong,
    /// not that a model was absent from a successful catalog response.
    public static func providerReadinessMessage(
        for category: ProviderReadinessFailureCategory
    ) -> StatusMessage {
        switch category {
        case .unauthorized:
            return StatusMessage(
                zh: "认证失败：API Key 无效或已过期",
                en: "Authentication failed: API key is invalid or expired",
                suggestionZH: "请在设置中重新输入 API Key，并确认供应商配置正确",
                suggestionEN: "Re-enter the API key in Settings and verify the provider configuration"
            )
        case .permissionDenied:
            return StatusMessage(
                zh: "API Key 没有访问权限，或账户余额、额度不足",
                en: "API key lacks access permission, or the account balance or quota is insufficient",
                suggestionZH: "请到供应商处确认账户余额或额度（不足请充值），再检查 API Key 权限及模型访问权限",
                suggestionEN: "Check API key permissions, account quota, and model access"
            )
        case .notFound:
            return StatusMessage(
                zh: "供应商端点不存在",
                en: "Provider endpoint not found",
                suggestionZH: "请检查 Base URL 是否正确，避免重复或缺少路径前缀",
                suggestionEN: "Check the Base URL for a missing or duplicated path prefix"
            )
        case .timeout:
            return StatusMessage(
                zh: "供应商请求超时",
                en: "Provider request timed out",
                suggestionZH: "请检查网络和 Base URL，确认服务可达后重试",
                suggestionEN: "Check the network and Base URL, then retry when the service is reachable"
            )
        case .rateLimited:
            return StatusMessage(
                zh: "供应商请求触发限流",
                en: "Provider request was rate limited",
                suggestionZH: "请稍后重试或降低请求频率",
                suggestionEN: "Retry later or reduce the request rate"
            )
        case .server:
            return StatusMessage(
                zh: "供应商服务端暂时不可用",
                en: "Provider server is temporarily unavailable",
                suggestionZH: "请稍后重试；若持续失败请检查供应商状态",
                suggestionEN: "Retry later; check the provider status if the failure persists"
            )
        case .invalidConfiguration:
            return StatusMessage(
                zh: "供应商配置无效",
                en: "Provider configuration is invalid",
                suggestionZH: "请检查 Base URL、协议和模型配置",
                suggestionEN: "Check the Base URL, protocol, and model configuration"
            )
        case .missingCredential:
            return StatusMessage(
                zh: "供应商认证信息缺失",
                en: "Provider authentication is missing",
                suggestionZH: "请在安全输入框中配置 API Key",
                suggestionEN: "Configure the API key in the secure input field"
            )
        case .unavailable, .transport:
            return StatusMessage(
                zh: "无法连接供应商",
                en: "Unable to reach the provider",
                suggestionZH: "请检查网络和 Base URL 后重试",
                suggestionEN: "Check the network and Base URL, then retry"
            )
        case .malformedResponse:
            return StatusMessage(
                zh: "供应商响应格式无法识别",
                en: "Provider response format was not recognized",
                suggestionZH: "请确认 Base URL 指向兼容的 API 端点",
                suggestionEN: "Verify that the Base URL targets a compatible API endpoint"
            )
        case .modelNotFound:
            return StatusMessage(
                zh: "供应商模型不存在",
                en: "Provider model was not found",
                suggestionZH: "请检查模型 ID 是否正确且已开通",
                suggestionEN: "Check that the model ID is correct and enabled"
            )
        }
    }

    /// 是否为瞬时故障（5xx / 429），应重试。
    public static func isTransient(_ code: Int) -> Bool {
        code >= 500 || code == 429
    }
}
