import Foundation
import Testing
@testable import MinisCore

private actor WebFetchPolicyEffectProbe: ToolExecutor {
    private var calls = 0
    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        await recordCall()
        return "synthetic-page"
    }
    private func recordCall() { calls += 1 }
    func count() -> Int { calls }
}

@Suite("H05 configured network ceiling remains above host approval")
struct WebFetchPolicyConsumerTests {
    @Test func emptyOrDifferentDomainBlocksBeforeTheFetchProducer() async throws {
        let now = Date()
        let ceilings: [Set<String>] = [[], ["allowed.example"]]
        for domains in ceilings {
            let base = WebFetchPolicyEffectProbe()
            let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
                networkDomains: domains, budget: 10, deadline: now.addingTimeInterval(60))
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: now, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: base, goal: goal, lease: lease)
            await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName,
                    input: ["url": "https://other.example/page"])
            }
            #expect(await base.count() == 0)
        }
    }

    @Test func configuredHostIsExtractedAndPassedToTheExistingPolicyBoundary() async throws {
        let now = Date()
        let base = WebFetchPolicyEffectProbe()
        let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
            networkDomains: ["allowed.example"], budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let input: [String: Any] = ["url": "https://allowed.example/page?query=one"]
        #expect(PolicyEnforcedToolExecutor.productionRequestBuilder(WebFetchToolContract.toolName, input)
            .networkDomain == "allowed.example")
        let result = try await PolicyEnforcedToolExecutor(base: base, goal: goal, lease: lease)
            .execute(name: WebFetchToolContract.toolName, input: input)
        #expect(result == "synthetic-page")
        #expect(await base.count() == 1)
        #expect(WebFetchToolContract.unavailableReason(networkAllowed: true, networkDomains: []) != nil)
        #expect(WebFetchToolContract.unavailableReason(networkAllowed: false, networkDomains: ["allowed.example"]) != nil)
    }
    @Test func hostlessOrNonWebURLsAreInvalidBeforeTheFetcher() async throws {
        let now = Date()
        let base = WebFetchPolicyEffectProbe()
        let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
            networkDomains: ["allowed.com"], budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: goal, lease: lease,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        for raw in ["allowed.com", "/only/path", "https:///x", "https://", "", "ftp://allowed.com/file"] {
            await #expect(throws: ToolExecutorError.invalidParameter("url")) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName, input: ["url": raw])
            }
        }
        let invalidInputs: [[String: Any]] = [[:], ["url": NSNull()], ["url": 1]]
        for input in invalidInputs {
            await #expect(throws: ToolExecutorError.invalidParameter("url")) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName, input: input)
            }
        }
        #expect(await base.count() == 0)
    }

    @Test func canonicalHostRulesKeepCaseTrailingDotPortAndSubdomainSemantics() async throws {
        let now = Date()
        let base = WebFetchPolicyEffectProbe()
        let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
            networkDomains: ["allowed.com"], budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: now, expiresAt: goal.deadline)
        let executor = PolicyEnforcedToolExecutor(base: base, goal: goal, lease: lease,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder)
        let accepted: [(String, String)] = [
            ("https://allowed.com/page", "allowed.com"),
            ("https://ALLOWED.COM/page", "allowed.com"),
            ("https://allowed.com./page", "allowed.com"),
            ("https://allowed.com:8443/page", "allowed.com"),
            ("http://allowed.com:8080/page", "allowed.com"),
            ("https://sub.allowed.com/page", "sub.allowed.com")
        ]
        for (raw, expectedHost) in accepted {
            let input: [String: Any] = ["url": raw]
            #expect(PolicyEnforcedToolExecutor.productionRequestBuilder(WebFetchToolContract.toolName, input)
                .networkDomain == expectedHost)
            #expect(try await executor.execute(name: WebFetchToolContract.toolName, input: input) == "synthetic-page")
        }
        #expect(await base.count() == accepted.count)
        let rejected: [(String, String)] = [
            ("https://allowed.com@evil.com/", "evil.com"),
            ("https://evilallowed.com/", "evilallowed.com"),
            ("https://allowed.com.evil.com/", "allowed.com.evil.com"),
            ("https://suballowed.com/", "suballowed.com")
        ]
        for (raw, expectedHost) in rejected {
            let input: [String: Any] = ["url": raw]
            #expect(PolicyEnforcedToolExecutor.productionRequestBuilder(WebFetchToolContract.toolName, input)
                .networkDomain == expectedHost)
            await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName, input: input)
            }
        }
        #expect(await base.count() == accepted.count)
    }

    @Test func genericOrInjectedBuilderCannotOmitOrSubstituteTheFetchHost() async throws {
        let now = Date()
        let builders: [@Sendable (String, [String: Any]) -> PolicyRequest] = [
            PolicyEnforcedToolExecutor.defaultRequestBuilder,
            { name, _ in PolicyRequest(capabilityID: name, networkDomain: "allowed.com") }
        ]
        for builder in builders {
            let base = WebFetchPolicyEffectProbe()
            let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
                networkDomains: ["allowed.com"], budget: 10, deadline: now.addingTimeInterval(60))
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: now, expiresAt: goal.deadline)
            let executor = PolicyEnforcedToolExecutor(base: base, goal: goal, lease: lease, requestBuilder: builder)
            await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.networkDomainNotAllowed)) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName,
                    input: ["url": "https://evilallowed.com/"])
            }
            await #expect(throws: ToolExecutorError.invalidParameter("url")) {
                _ = try await executor.execute(name: WebFetchToolContract.toolName, input: ["url": "allowed.com"])
            }
            #expect(await base.count() == 0)
        }
    }

}
