import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// B-32: the user-visible error projection must carry the output-limit notice
// (fixed copy, no payload) instead of the generic payload-free fallback.
@MainActor
@Suite("B-32 output truncation App projection")
struct B32OutputTruncationProjectionTests {
    @Test func outputLimitErrorShowsTheTruncationNoticeToTheUser() {
        let visible = ChatStore.userErrorMessage(AgentLoopError.outputTruncated)
        #expect(visible.contains("截断") || visible.lowercased().contains("truncat"))
        #expect(visible == AgentLoopError.outputTruncated.localizedDescription)
    }

    @Test func retryableStreamEndShowsARetryHintNotATruncationClaim() {
        let visible = ChatStore.userErrorMessage(
            LLMError.transientError(message: "Provider stream ended before a complete response was received."))
        #expect(visible.contains("重试") || visible.lowercased().contains("try again"))
        #expect(!visible.contains("Provider stream ended"))
    }
}
