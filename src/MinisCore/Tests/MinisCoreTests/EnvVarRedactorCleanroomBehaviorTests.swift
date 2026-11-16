import Testing
@testable import MinisCore

struct EnvVarRedactorCleanroomBehaviorTests {
    @Test func longestSecretOwnsOverlapWithoutLeakingTail() {
        let result = EnvVarRedactor.redactAll(in: "token-long token", values: ["token", "token-long"])
        #expect(result.0 == "********** *****")
        #expect(result.1 == 2)
    }

    @Test func duplicateAndShortCandidatesDoNotInflateMasking() {
        let result = EnvVarRedactor.redactAll(in: "token token tiny", values: ["token", "token", "tiny"])
        #expect(result.0 == "***** ***** tiny")
        #expect(result.1 == 1)
    }
}
