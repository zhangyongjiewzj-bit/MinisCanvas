import Testing
@testable import MinisCore

struct ConversationGoalReviewVerdictTests {
    @Test func classifiesBoundedVerdictPresentations() {
        func verdict(_ text: String) -> ConversationGoalState.ReviewRecord.Outcome {
            ConversationGoalReviewVerdict(response: .init(text: text, stopReason: "stop", usage: nil),
                  normalStopReasons: ["stop"]).outcome
        }
        #expect(verdict("VERDICT: PASS - evidence shows both sections were reviewed") == .passed)
        #expect(verdict("**VERDICT: PASS**") == .passed)
        #expect(verdict("VERDICT: FAIL") == .rejected)
        #expect(verdict("VERDICT: FAIL Not a PASS") == .rejected)
        #expect(verdict("VERDICT: PASSED") == .invalidResponse)
        #expect(verdict("VERDICT: PASS\nEvidence") == .invalidResponse)
        // The leading verdict token is authoritative. The reason does not participate in classification.
        #expect(verdict("VERDICT: PASS - the evidence does not establish the objective") == .passed)
        #expect(verdict("VERDICT: PASS - VERDICT: FAIL Missing evidence") == .passed)
        let prefix = "VERDICT: PASS "
        let maximum = prefix + String(repeating: "x", count: 300 - prefix.count)
        #expect(verdict(maximum) == .passed)
        #expect(verdict(maximum + "x") == .invalidResponse)
        #expect(verdict("**`VERDICT: PASS`**") == .invalidResponse)
        #expect(verdict("VERDICT: PASS - \u{200B}evidence") == .invalidResponse)
        #expect(verdict("VERDICT: PASS, evidence") == .passed)
        #expect(verdict("VERDICT: PASS.") == .passed)
    }

    @Test func classifiesTextAndPreservesOnlyValidReportedUsage() {
        let usage = LLMUsage(inputTokens: 12, outputTokens: 3)
        func verdict(_ text: String, stop: String? = "stop", usage: LLMUsage? = nil, discarded: Int = 0)
            -> ConversationGoalReviewVerdict {
            .init(response: .init(text: text, stopReason: stop, usage: usage,
                                  mediaAttachments: [], toolCalls: [], discardedToolCallCount: discarded),
                  normalStopReasons: ["stop"])
        }
        let pass = verdict(" VERDICT: PASS\n", usage: usage)
        #expect(pass.outcome == .passed)
        #expect(pass.usage == usage)
        #expect(verdict("VERDICT: PASS Evidence checked").rejectedReason == nil)
        let rejected = verdict("**VERDICT: FAIL   Not enough evidence**")
        #expect(rejected.outcome == .rejected)
        #expect(rejected.rejectedReason == "Not enough evidence")
        #expect(verdict("VERDICT: FAIL").rejectedReason == nil)
        let invalid = verdict("VERDICT: FAIL Not enough evidence", stop: "length")
        #expect(invalid.outcome == .invalidResponse)
        #expect(invalid.rejectedReason == nil)
        #expect(verdict("VERDICT: PASS\nExtra").outcome == .invalidResponse)
        #expect(verdict("VERDICT: PASS", stop: "length").outcome == .invalidResponse)
        #expect(verdict("VERDICT: PASS", discarded: 1).outcome == .invalidResponse)
        #expect(verdict("VERDICT: PASS").usage == nil)
        #expect(verdict("VERDICT: PASS", usage: .init(inputTokens: Int.max, outputTokens: 1)).usage == nil)
    }
}
