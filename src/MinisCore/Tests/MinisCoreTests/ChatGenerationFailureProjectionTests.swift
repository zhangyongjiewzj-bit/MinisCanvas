import Foundation
import Testing
@testable import MinisCore

@Suite("Chat generation failure projection")
struct ChatGenerationFailureProjectionTests {

    @Test func httpFailuresExposeTypedUIStateAndRecoveryAction() {
        let payload = "Authorization: Bearer fixture-generation-secret response body"
        let cases: [(Int, ChatGenerationFailureCategory, ChatGenerationRecoveryAction, Bool)] = [
            (401, .authorization, .reauthenticate, false),
            (403, .authorization, .reauthenticate, false),
            (404, .model, .selectModel, false),
            (408, .retry, .retry, true),
            (429, .rateLimit, .waitAndRetry, true),
            (500, .server, .retry, true),
            (503, .server, .retry, true),
        ]

        for (status, category, action, retryable) in cases {
            let projection = ChatGenerationFailureProjection(
                error: LLMError.httpStatus(code: status, detail: payload),
                locale: Locale(identifier: "zh_CN")
            )
            #expect(projection.status == .failed)
            #expect(projection.category == category)
            #expect(projection.recoveryAction == action)
            #expect(projection.retryable == retryable)
            #expect(projection.httpStatus == status)
            #expect(!projection.message.contains(payload))
            #expect(!projection.message.contains("Authorization"))
            #expect(!projection.message.contains("Bearer"))
            #expect(!projection.message.contains("response body"))
        }
    }

    @Test(arguments: [400, 402, 422])
    func nonRetryableHTTPFailuresShowChineseReasonAndNextStep(_ status: Int) {
        let payload = "owned synthetic provider response"
        let projection = ChatGenerationFailureProjection(
            error: LLMError.httpStatus(code: status, detail: payload),
            locale: Locale(identifier: "en_US")
        )
        let copy = HTTPStatusMessages.message(for: status)
        let expected = "\(copy.zh)，\(copy.suggestionZH)（HTTP \(status)）"
        #expect(!projection.retryable)
        #expect(projection.actionableRecoveryAction == .none)
        #expect(projection.message == expected)
        #expect(projection.userFacingMessage == expected)
        #expect(!projection.message.contains("请稍后重试"))
        #expect(!projection.message.contains(payload))
    }

    @Test func otherNonRetryableHTTPFailureDoesNotSuggestWaitingAndRetrying() {
        let projection = ChatGenerationFailureProjection(
            error: LLMError.httpStatus(code: 418, detail: "owned synthetic provider response"),
            locale: Locale(identifier: "zh_CN")
        )
        #expect(!projection.retryable)
        #expect(!projection.message.contains("请稍后重试"))
    }

    @Test func transportAndCancellationProjectWithoutLocalizedDescription() {
        let payload = "Authorization: Bearer fixture-transport-secret"
        let timeout = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: payload]
        )
        let timeoutProjection = ChatGenerationFailureProjection(
            error: timeout,
            locale: Locale(identifier: "en_US")
        )
        #expect(timeoutProjection.status == .failed)
        #expect(timeoutProjection.category == .retry)
        #expect(timeoutProjection.recoveryAction == .retry)
        #expect(timeoutProjection.retryable)
        #expect(!timeoutProjection.message.contains(payload))
        #expect(!timeoutProjection.message.contains("Bearer"))

        let transportProjection = ChatGenerationFailureProjection(
            error: NSError(domain: "fixture.network", code: 77),
            locale: Locale(identifier: "en_US")
        )
        #expect(transportProjection.status == .failed)
        #expect(transportProjection.category == .transport)
        #expect(transportProjection.recoveryAction == .checkNetwork)
        #expect(!transportProjection.retryable)

        let cancelled = ChatGenerationFailureProjection(
            error: LLMError.cancelled,
            locale: Locale(identifier: "zh_CN")
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.category == .cancelled)
        #expect(cancelled.recoveryAction == .none)
        #expect(!cancelled.retryable)
    }

    @Test func retryEnvelopeMessageIsSafeProjection() {
        let payload = "Authorization: Bearer fixture-envelope-secret"
        let projection = ChatGenerationFailureProjection(
            error: LLMError.httpStatus(code: 503, detail: payload),
            locale: Locale(identifier: "en_US")
        )
        #expect(projection.failureMessage == "服务暂时不可用，请稍后重试（HTTP 503）")
        #expect(!projection.failureMessage.contains(payload))
        #expect(!projection.failureMessage.contains("Authorization"))
        #expect(!projection.failureMessage.contains("Bearer"))
    }
}
