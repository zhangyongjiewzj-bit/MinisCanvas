import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("App typed retry failure language boundary")
struct ChatRetryFailureLocalizationTests {
    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func typedHTTPUsesChineseBeforeCanonicalStorage(code: Int) {
        let error = LLMError.httpStatus(code: code,
            detail: "Authorization: Bearer synthetic-locale-private")
        let actual = AgentLoopChatEngine.retryFailureMessage(for: error)
        #expect(actual == error.friendlyMessage(locale: Locale(identifier: "zh_CN")))
        #expect(actual.contains(String(code)))
        #expect(actual.contains(HTTPStatusMessages.message(for: code).zh))
        #expect(!actual.contains("synthetic-locale-private"))
        // Explicit Core English remains independently selectable.
        let english = error.friendlyMessage(locale: Locale(identifier: "en_US"))
        #expect(english.contains(HTTPStatusMessages.message(for: code).en))
        #expect(actual != english)
    }

    @Test func typedTimeoutUsesChineseWithoutRewritingAnUntypedMessage() {
        let timeout = LLMError.networkError(underlying: URLError(.timedOut))
        #expect(AgentLoopChatEngine.retryFailureMessage(for: timeout).contains("请求超时"))
        let ordinary = NSError(domain: "owned-locale", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "owned English diagnostic"])
        #expect(AgentLoopChatEngine.retryFailureMessage(for: ordinary) == ordinary.localizedDescription)
    }
}
