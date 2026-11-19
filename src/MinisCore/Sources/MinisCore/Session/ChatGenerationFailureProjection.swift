import Foundation

/// Typed failure state consumed by Chat/UI after a provider generation fails.
///
/// The projection is deliberately built from status/code/category only. It
/// never uses an LLMError detail, response body, header, URL, query, token,
/// or localized transport description as UI text or retry state.
public enum ChatGenerationFailureCategory: String, Codable, CaseIterable, Sendable {
    case retry
    case authorization
    case rateLimit
    case server
    case transport
    case model
    case contextLength
    case cancelled
}

public enum ChatGenerationRecoveryAction: String, Codable, CaseIterable, Sendable {
    case retry
    case reauthenticate
    case waitAndRetry
    case checkNetwork
    case selectModel
    /// 上下文超长：先压缩当前对话（等同 /compact），再重发上一条消息。
    case compactAndRetry
    case none

    /// Stable copy for a user-facing recovery control. No action is triggered
    /// by the projection; the caller must explicitly invoke its typed handler.
    public var title: String {
        switch self {
        case .retry: return "重试"
        case .reauthenticate: return "检查 API Key"
        case .waitAndRetry: return "稍后重试"
        case .checkNetwork: return "检查网络"
        case .selectModel: return "选择模型"
        case .compactAndRetry: return "压缩后重试"
        case .none: return ""
        }
    }

    public var accessibilityHint: String {
        switch self {
        case .retry: return "仅在本次请求结束后由用户明确发起一次重试"
        case .reauthenticate: return "打开服务商配置并更新授权信息"
        case .waitAndRetry: return "等待限流窗口结束后再明确发起一次请求"
        case .checkNetwork: return "检查网络连接后重新发送"
        case .selectModel: return "选择可用模型后重新发送"
        case .compactAndRetry: return "先压缩当前对话，再由你明确发起一次重新发送"
        case .none: return "当前没有可执行的恢复动作"
        }
    }
}

public struct ChatGenerationFailureProjection: Codable, Equatable, Sendable {
    public let status: ConversationEventStatus
    public let category: ChatGenerationFailureCategory
    public let recoveryAction: ChatGenerationRecoveryAction
    public let retryable: Bool
    public let fallbackable: Bool
    public let httpStatus: Int?
    public let errorCategory: ConversationEventErrorCategory?
    public let message: String

    public init(error: Error, locale: Locale = .current) {
        let facts = Self.facts(for: error)
        self.status = facts.category == .cancelled ? .cancelled : .failed
        self.category = facts.category
        self.recoveryAction = facts.recoveryAction
        self.retryable = facts.retryable
        self.fallbackable = facts.fallbackable
        self.httpStatus = facts.httpStatus
        self.errorCategory = Self.conversationErrorCategory(for: facts.category)
        self.message = facts.quotaExhausted
            ? "账户余额或额度不足，请到供应商处充值或更换 API Key（HTTP \(facts.httpStatus ?? 0)）"
            : Self.message(
                category: facts.category,
                httpStatus: facts.httpStatus,
                retryable: facts.retryable
            )
    }

    /// Safe failure text suitable for `ChatRetryEnvelope.failureMessage`.
    public var failureMessage: String { message }

    /// Recovery is offered only when the typed facts support it. In
    /// particular, a non-retryable provider/decoding failure cannot surface a
    /// retry button merely because its broad category is `.server`.
    public var actionableRecoveryAction: ChatGenerationRecoveryAction {
        guard status == .failed else { return .none }
        switch recoveryAction {
        case .retry, .waitAndRetry:
            return retryable ? recoveryAction : .none
        case .reauthenticate, .selectModel, .compactAndRetry:
            return fallbackable ? recoveryAction : .none
        case .checkNetwork:
            return .checkNetwork
        case .none:
            return .none
        }
    }

    /// 结合会话情况得出最终恢复动作与文案：上下文超长但会话里没有可压缩的历史时，
    /// 不提供“压缩后重试”，改为提示精简内容或换窗口更大的模型。
    public func recovery(conversationHasHistory: Bool) -> (action: ChatGenerationRecoveryAction, message: String) {
        let action = actionableRecoveryAction
        guard action == .compactAndRetry, !conversationHasHistory else {
            return (action, userFacingMessage)
        }
        return (.none, "这条内容本身就超出了模型的上下文窗口，没有可压缩的历史。请精简内容或换用窗口更大的模型后重发。")
    }

    public var isRecoverable: Bool {
        actionableRecoveryAction != .none
    }

    /// Terminal means no further action is implied by this failure. This is a
    /// display fact, not permission to report success or to retry implicitly.
    public var isTerminal: Bool {
        status.isTerminal && !isRecoverable
    }

    /// Safe copy for an empty-state surface. Terminal failures do not retain
    /// the generic "please retry" wording when no typed retry is available.
    public var userFacingMessage: String {
        guard isTerminal, status != .cancelled, !Self.hasSpecificHTTPGuidance(httpStatus) else { return message }
        return "本次请求未完成，未自动重试。请检查服务商或模型设置后重新发送。"
    }

    private struct Facts {
        let category: ChatGenerationFailureCategory
        let recoveryAction: ChatGenerationRecoveryAction
        let retryable: Bool
        let fallbackable: Bool
        let httpStatus: Int?
        var quotaExhausted: Bool = false
    }

    private static func facts(for error: Error) -> Facts {
        if let llmError = error as? LLMError {
            switch llmError {
            case .httpStatus(let code, _):
                if llmError.isQuotaExhausted {
                    return Facts(
                        category: .authorization,
                        recoveryAction: .reauthenticate,
                        retryable: false,
                        fallbackable: true,
                        httpStatus: code,
                        quotaExhausted: true
                    )
                }
                let classification = ProviderHTTPErrorAdapter.classify(statusCode: code)
                switch classification.category {
                case .unauthorized, .permissionDenied:
                    return Facts(
                        category: .authorization,
                        recoveryAction: .reauthenticate,
                        retryable: false,
                        fallbackable: true,
                        httpStatus: code
                    )
                case .notFound:
                    return Facts(
                        category: .model,
                        recoveryAction: .selectModel,
                        retryable: false,
                        fallbackable: true,
                        httpStatus: code
                    )
                case .timeout:
                    return Facts(
                        category: .retry,
                        recoveryAction: .retry,
                        retryable: true,
                        fallbackable: false,
                        httpStatus: code
                    )
                case .rateLimited:
                    return Facts(
                        category: .rateLimit,
                        recoveryAction: .waitAndRetry,
                        retryable: true,
                        fallbackable: true,
                        httpStatus: code
                    )
                case .server:
                    return Facts(
                        category: .server,
                        recoveryAction: .retry,
                        retryable: true,
                        fallbackable: false,
                        httpStatus: code
                    )
                default:
                    return Facts(
                        category: .server,
                        recoveryAction: .retry,
                        retryable: false,
                        fallbackable: false,
                        httpStatus: code
                    )
                }
            case .networkError(let underlying):
                let code = Self.transportCode(from: underlying)
                return code == NSURLErrorTimedOut
                    ? Facts(
                        category: .retry,
                        recoveryAction: .retry,
                        retryable: true,
                        fallbackable: false,
                        httpStatus: nil
                    )
                    : Facts(
                        category: .transport,
                        recoveryAction: .checkNetwork,
                        retryable: false,
                        fallbackable: false,
                        httpStatus: nil
                    )
            case .invalidAPIKey:
                return Facts(
                    category: .authorization,
                    recoveryAction: .reauthenticate,
                    retryable: false,
                    fallbackable: true,
                    httpStatus: nil
                )
            case .rateLimited:
                return Facts(
                    category: .rateLimit,
                    recoveryAction: .waitAndRetry,
                    retryable: true,
                    fallbackable: true,
                    httpStatus: 429
                )
            case .transientError:
                return Facts(
                    category: .server,
                    recoveryAction: .retry,
                    retryable: true,
                    fallbackable: false,
                    httpStatus: nil
                )
            case .contextLengthExceeded:
                return Facts(
                    category: .contextLength,
                    recoveryAction: .compactAndRetry,
                    retryable: false,
                    fallbackable: true,
                    httpStatus: nil
                )
            case .cancelled:
                return Facts(
                    category: .cancelled,
                    recoveryAction: .none,
                    retryable: false,
                    fallbackable: false,
                    httpStatus: nil
                )
            case .providerError, .decodingError, .unsupportedCapability, .unknown:
                return Facts(
                    category: .server,
                    recoveryAction: .retry,
                    retryable: false,
                    fallbackable: false,
                    httpStatus: nil
                )
            }
        }

        let transport = ProviderHTTPErrorAdapter.classify(transport: error)
        return transport.category == .timeout
            ? Facts(
                category: .retry,
                recoveryAction: .retry,
                retryable: true,
                fallbackable: false,
                httpStatus: nil
            )
            : Facts(
                category: .transport,
                recoveryAction: .checkNetwork,
                retryable: false,
                fallbackable: false,
                httpStatus: nil
            )
    }

    private static func transportCode(from error: Error) -> Int {
        if let codeError = error as? ProviderTransportCodeError {
            return codeError.code
        }
        return ProviderHTTPErrorAdapter.classify(transport: error).code
    }

    private static func conversationErrorCategory(
        for category: ChatGenerationFailureCategory
    ) -> ConversationEventErrorCategory? {
        switch category {
        case .authorization:
            return .authorization
        case .rateLimit, .server:
            return .provider
        case .retry, .transport:
            return .network
        case .model, .contextLength:
            return .model
        case .cancelled:
            return .cancelled
        }
    }

    private static func hasSpecificHTTPGuidance(_ status: Int?) -> Bool {
        status == 400 || status == 402 || status == 422
    }

    private static func message(
        category: ChatGenerationFailureCategory,
        httpStatus: Int?,
        retryable: Bool
    ) -> String {
        if let httpStatus, hasSpecificHTTPGuidance(httpStatus) {
            let copy = HTTPStatusMessages.message(for: httpStatus)
            return "\(copy.zh)，\(copy.suggestionZH)（HTTP \(httpStatus)）"
        }

        let base = switch category {
        case .retry: "请求暂时失败，请重试"
        case .authorization: "API Key 无效或无权限，请更新配置"
        case .rateLimit: "请求过于频繁，请稍后重试"
        case .server: retryable ? "服务暂时不可用，请稍后重试" : "服务商请求失败，请检查服务商或模型设置"
        case .transport: "网络连接失败，请检查网络后重试"
        case .model: "模型不可用，请选择其他模型"
        case .contextLength: "上下文超出模型窗口，可以压缩对话后重试"
        case .cancelled: "请求已取消"
        }
        guard let httpStatus else { return base }
        return "\(base)（HTTP \(httpStatus)）"
    }
}
