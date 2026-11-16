import Foundation
import Testing
@testable import MinisCore

// E20 中英文错误信息体系测试：
//   - HTTP 状态码映射（401/403/404/429/5xx…）中英双语正确
//   - 网络错误（断网 -1009 / 超时 -1001）映射
//   - friendlyMessage 中英文切换
//   - technicalDetail 仅含状态码，不含原始 body
//   - Provider 统一抛错（mapHTTPError → .httpStatus）

@Suite("LLMError 中英文错误信息（E20）")
struct LLMErrorMessagesTests {

    // MARK: - HTTP 状态码映射（中文）

    @Test func http401Chinese() {
        let err = LLMError.httpStatus(code: 401, detail: "401 Unauthorized - bad key")
        #expect(err.userMessageZH.contains("API Key 无效或已过期"))
        #expect(err.userMessageZH.contains("请检查该服务商的 API Key"))
        #expect(!err.userMessageZH.contains("HERMES_CUSTOM_QWEN38_API_KEY"))
        #expect(!err.userMessageZH.contains("Unauthorized - bad key"))
    }

    @Test func http403Chinese() {
        let err = LLMError.httpStatus(code: 403, detail: "quota exceeded")
        #expect(err.userMessageZH.contains("欠费"))
        #expect(err.userMessageZH.contains("没有该模型的访问权限"))
    }

    @Test func http404Chinese() {
        let err = LLMError.httpStatus(code: 404, detail: "model not found")
        #expect(err.userMessageZH.contains("模型不存在或模型 ID 错误"))
    }

    @Test func http429Chinese() {
        let err = LLMError.httpStatus(code: 429, detail: "rate limit")
        #expect(err.userMessageZH.contains("限流"))
        #expect(err.userMessageZH.contains("请稍后重试或降低请求频率"))
    }

    @Test func http500Chinese() {
        let err = LLMError.httpStatus(code: 500, detail: "internal error")
        #expect(err.userMessageZH.contains("服务端内部错误"))
    }

    @Test func http503Chinese() {
        let err = LLMError.httpStatus(code: 503, detail: "unavailable")
        #expect(err.userMessageZH.contains("服务暂时不可用"))
    }

    @Test func unknownStatusCodeChineseFallback() {
        let err = LLMError.httpStatus(code: 418, detail: "teapot")
        #expect(err.userMessageZH.contains("HTTP 418"))
    }

    // MARK: - HTTP 状态码映射（英文）

    @Test func http401English() {
        let err = LLMError.httpStatus(code: 401, detail: "Unauthorized")
        #expect(err.userMessageEN.contains("Invalid or expired API key"))
        #expect(err.userMessageEN.contains("Please check this provider’s API key"))
        #expect(!err.userMessageEN.contains("HERMES_CUSTOM_QWEN38_API_KEY"))
    }

    @Test func http403English() {
        let err = LLMError.httpStatus(code: 403, detail: "forbidden")
        #expect(err.userMessageEN.contains("Insufficient quota or no permission"))
    }

    @Test func http404English() {
        let err = LLMError.httpStatus(code: 404, detail: "not found")
        #expect(err.userMessageEN.contains("Model not found or wrong model ID"))
    }

    @Test func http429English() {
        let err = LLMError.httpStatus(code: 429, detail: "slow down")
        #expect(err.userMessageEN.contains("rate limited"))
        #expect(err.userMessageEN.contains("lower the request frequency"))
    }

    @Test func http503English() {
        let err = LLMError.httpStatus(code: 503, detail: "unavailable")
        #expect(err.userMessageEN.contains("Service temporarily unavailable"))
    }

    // MARK: - 网络错误映射

    @Test func notConnectedChinese() {
        let urlError = URLError(.notConnectedToInternet)
        let err = LLMError.networkError(underlying: urlError)
        #expect(err.userMessageZH.contains("网络连接失败"))
        #expect(err.userMessageZH.contains("请检查网络"))
    }

    @Test func timedOutChinese() {
        let urlError = URLError(.timedOut)
        let err = LLMError.networkError(underlying: urlError)
        #expect(err.userMessageZH.contains("请求超时"))
    }

    @Test func notConnectedEnglish() {
        let urlError = URLError(.notConnectedToInternet)
        let err = LLMError.networkError(underlying: urlError)
        #expect(err.userMessageEN.contains("Network connection failed"))
    }

    @Test func nsErrorDomainMapping() {
        // NSError 包装的 NSURLErrorDomain -1009（断网）也应映射为中文断网提示
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let err = LLMError.networkError(underlying: nsError)
        #expect(err.userMessageZH.contains("网络连接失败"))
        #expect(err.isNetworkError)
        #expect(err.isRetryable)
    }

    // MARK: - friendlyMessage 中英文切换

    @Test func friendlyMessageChineseLocale() {
        let err = LLMError.httpStatus(code: 401, detail: "Unauthorized")
        let zh = err.friendlyMessage(locale: Locale(identifier: "zh_CN"))
        #expect(zh.hasPrefix("❌"))
        #expect(zh.contains("API Key 无效"))
        #expect(zh.contains("401"))
        #expect(zh.contains("请检查"))
    }

    @Test func friendlyMessageEnglishLocale() {
        let err = LLMError.httpStatus(code: 401, detail: "Unauthorized")
        let en = err.friendlyMessage(locale: Locale(identifier: "en_US"))
        #expect(en.hasPrefix("❌"))
        // 与 HTTPStatusMessages 401 文案一致（小写 key）
        #expect(en.contains("Invalid or expired API key"))
        #expect(en.contains("401"))
    }

    @Test func friendlyMessageDefaultLocaleChinese() {
        // 系统为中文时默认走中文（测试里显式传 zh 保证确定性）
        let err = LLMError.httpStatus(code: 429, detail: "limit")
        let zh = err.friendlyMessage(locale: Locale(identifier: "zh-Hans"))
        #expect(zh.contains("限流"))
    }

    // MARK: - technicalDetail 脱敏边界

    @Test func technicalDetailContainsStatusCodeWithoutResponseBody() {
        let rawBody = "Authorization: Bearer fixture-response-secret response body"
        let err = LLMError.httpStatus(code: 401, detail: rawBody)
        #expect(err.technicalDetail.contains("401"))
        #expect(!err.technicalDetail.contains(rawBody))
        #expect(!err.technicalDetail.contains("Authorization"))
        #expect(!err.technicalDetail.contains("Bearer"))
    }

    @Test func technicalDetailNetworkError() {
        let urlError = URLError(.timedOut)
        let err = LLMError.networkError(underlying: urlError)
        #expect(err.technicalDetail.contains("networkError"))
        #expect(err.technicalDetail.contains("NSURLErrorDomain"))
    }

    @Test func providerHTTPAndTransportFailuresAreTypedAndPayloadFree() {
        let payload = "Authorization: Bearer fixture-provider-secret response body"
        let cases: [(Int, ProviderReadinessFailureCategory)] = [
            (401, .unauthorized),
            (403, .permissionDenied),
            (404, .notFound),
            (408, .timeout),
            (429, .rateLimited),
            (500, .server),
            (503, .server),
        ]

        for (statusCode, category) in cases {
            let err = LLMError.httpStatus(code: statusCode, detail: payload)
            #expect(err.providerFailureCategory == category)
            let surfaces = [
                err.errorDescription ?? "",
                err.userMessageZH,
                err.userMessageEN,
                err.friendlyMessage(locale: Locale(identifier: "zh_CN")),
                err.friendlyMessage(locale: Locale(identifier: "en_US")),
                err.technicalDetail,
                err.fallbackReason,
            ]
            #expect(surfaces.allSatisfy {
                !$0.contains(payload)
                    && !$0.contains("Authorization")
                    && !$0.contains("Bearer")
                    && !$0.contains("response body")
            })
        }

        let transport = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: payload]
        )
        let transportError = LLMError.networkError(underlying: transport)
        #expect(transportError.providerFailureCategory == .timeout)
        #expect(!transportError.userMessageZH.contains(payload))
        #expect(!transportError.userMessageEN.contains(payload))
        #expect(!transportError.technicalDetail.contains(payload))
        #expect(!transportError.technicalDetail.contains("Authorization"))
        #expect(!transportError.technicalDetail.contains("Bearer"))
    }

    // MARK: - Provider 统一抛错（mapHTTPError → .httpStatus）

    @Test func openAICompatibleProviderMaps401() {
        let provider = OpenAICompatibleProvider(apiKey: "test-key")
        let err = provider.mapHTTPError(statusCode: 401, body: "{\"error\":{\"message\":\"Invalid API key\"}}")
        guard case .httpStatus(let code, let detail) = err else {
            Issue.record("expected httpStatus, got \(err)")
            return
        }
        #expect(code == 401)
        #expect(detail.isEmpty)
        #expect(err.userMessageZH.contains("API Key 无效"))
    }

    @Test func openAICompatibleProviderMaps429() {
        let provider = OpenAICompatibleProvider(apiKey: "test-key")
        let err = provider.mapHTTPError(statusCode: 429, body: "rate limited")
        guard case .httpStatus(let code, _) = err else {
            Issue.record("expected httpStatus, got \(err)")
            return
        }
        #expect(code == 429)
        #expect(err.userMessageZH.contains("限流"))
    }

    @Test func openAICompatibleProviderMaps500AsRetryable() {
        let provider = OpenAICompatibleProvider(apiKey: "test-key")
        let err = provider.mapHTTPError(statusCode: 500, body: "boom")
        #expect(err.isRetryable)
        #expect(err.userMessageZH.contains("服务端内部错误"))
    }

    @Test func openAICompatibleRedactsExactConfiguredCredentialBeforeErrorEscapes() {
        let credentials = ["fixture-custom-credential", "xy7"]
        for credential in credentials {
            let provider = OpenAICompatibleProvider(apiKey: credential)
            let bodies = [
                "{\"error\":{\"message\":\"diagnostic \(credential) retained\"}}",
                "fallback diagnostic \(credential) retained",
            ]
            for body in bodies {
                let err = provider.mapHTTPError(statusCode: 401, body: body)
                guard case .httpStatus(let code, let detail) = err else {
                    Issue.record("expected httpStatus, got \(err)")
                    continue
                }
                #expect(code == 401)
                #expect(detail.isEmpty)
                let surfaces = [
                    err.errorDescription ?? "",
                    err.friendlyMessage(locale: Locale(identifier: "zh_CN")),
                    err.friendlyMessage(locale: Locale(identifier: "en_US")),
                    err.technicalDetail,
                ]
                for surface in surfaces {
                    #expect(!surface.contains(credential))
                    #expect(!surface.contains("diagnostic"))
                    #expect(!surface.contains("retained"))
                    #expect(!surface.contains("Authorization"))
                    #expect(!surface.contains("Bearer"))
                }
            }
        }

        let providerMessage = LLMError.providerError(
            message: "provider response body contains user@example.com and fixture-secret"
        )
        #expect(providerMessage.errorDescription == "Provider error")
        #expect(providerMessage.technicalDetail == "providerError")
        #expect(String(describing: providerMessage) == "Provider error")
        #expect(!(providerMessage.errorDescription ?? "").contains("user@example.com"))
        #expect(!providerMessage.technicalDetail.contains("fixture-secret"))
    }

    @Test func openAICompatibleRedactsCredentialFromNetworkErrorAndLogSink() throws {
        let credential = "fixture-network-credential"
        let provider = OpenAICompatibleProvider(apiKey: credential)
        let transportError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "transport echoed \(credential) retained"]
        )

        let err = provider.mapError(transportError)
        #expect(err.isNetworkError)
        #expect(err.isRetryable)
        #expect(!err.technicalDetail.contains(credential))
        #expect(!err.technicalDetail.contains("transport echoed"))
        #expect(!err.technicalDetail.contains("Bearer"))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-LLMError-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = LogManager(directory: dir)
        log.error(err.technicalDetail, category: "FixtureProvider")
        let recent = log.recentLogsText()
        #expect(!recent.contains(credential))
        guard let logURL = log.logFileURL() else {
            Issue.record("expected isolated log file")
            return
        }
        let persisted = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!persisted.contains(credential))
        #expect(persisted.contains("networkError"))
    }

    @Test func anthropicProviderMaps403() {
        let provider = AnthropicProvider(apiKey: "test-key")
        let err = provider.mapHTTPError(
            statusCode: 403,
            body: "{\"type\":\"error\",\"error\":{\"type\":\"permission_error\",\"message\":\"quota exceeded\"}}"
        )
        guard case .httpStatus(let code, let detail) = err else {
            Issue.record("expected httpStatus, got \(err)")
            return
        }
        #expect(code == 403)
        #expect(detail.contains("quota exceeded"))
        #expect(err.userMessageZH.contains("欠费"))
    }

    // MARK: - 旧枚举 case 仍可用（兼容）

    @Test func legacyCasesStillWork() {
        let invalidKey = LLMError.invalidAPIKey(detail: "x")
        #expect(invalidKey.userMessageZH.contains("API Key 无效"))
        #expect(invalidKey.isFallbackable)

        let rateLimited = LLMError.rateLimited
        #expect(rateLimited.userMessageZH.contains("限流"))
        #expect(rateLimited.userMessageEN.contains("rate limited"))
        #expect(rateLimited.isFallbackable)
        #expect(!rateLimited.isRetryable)

        let cancelled = LLMError.cancelled
        #expect(cancelled.userMessageZH.contains("取消"))
    }

    @Test func httpStatusFallbackSemantics() {
        // 401/403/404/429 → 可 fallback；5xx → 可重试
        #expect(LLMError.httpStatus(code: 401, detail: "").isFallbackable)
        #expect(LLMError.httpStatus(code: 403, detail: "").isFallbackable)
        #expect(LLMError.httpStatus(code: 404, detail: "").isFallbackable)
        #expect(LLMError.httpStatus(code: 429, detail: "").isFallbackable)
        #expect(!LLMError.httpStatus(code: 401, detail: "").isRetryable)
        #expect(LLMError.httpStatus(code: 500, detail: "").isRetryable)
        #expect(LLMError.httpStatus(code: 503, detail: "").isRetryable)
        #expect(LLMError.httpStatus(code: 429, detail: "").isRetryable)
        #expect(!LLMError.httpStatus(code: 404, detail: "").isFallbackable == false)
    }
}
