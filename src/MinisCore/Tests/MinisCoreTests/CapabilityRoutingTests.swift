import Foundation
import Testing
@testable import MinisCore

struct CapabilityRoutingTests {
    @Test func rawCapabilityManifestRejectsUnknownValuesBeforeRouting() {
        let candidates = [ProviderRouteCandidate(
            id: "provider",
            providerName: "provider",
            modelID: "model",
            capabilities: [.tools]
        )]

        #expect(throws: CapabilityRoutingError.unknownCapability("telepathy")) {
            _ = try CapabilityRouter.route(
                rawRequiredCapabilities: ["telepathy"],
                candidates: candidates
            )
        }
    }

    @Test func rawCapabilityManifestDoesNotTreatDescriptionAsAuthorization() {
        let candidates = [ProviderRouteCandidate(
            id: "provider",
            providerName: "provider",
            modelID: "model",
            capabilities: [.tools]
        )]

        #expect(throws: CapabilityRoutingError.unknownCapability("tools for browsing")) {
            _ = try CapabilityRouter.route(
                rawRequiredCapabilities: ["tools for browsing"],
                candidates: candidates
            )
        }
    }

    @Test func routeSelectsOnlyCandidateMeetingCapabilitiesAndAllowlist() throws {
        let candidates = [
            ProviderRouteCandidate(id: "text", providerName: "text", modelID: "m-text", capabilities: [.streaming]),
            ProviderRouteCandidate(id: "tools", providerName: "tools", modelID: "m-tools", capabilities: [.streaming, .tools])
        ]
        let request = ProviderRouteRequest(requiredCapabilities: [.tools], allowedProviderIDs: ["tools"])
        let route = try CapabilityRouter.route(request: request, candidates: candidates)
        #expect(route.providerID == "tools")
        #expect(route.modelID == "m-tools")
        #expect(route.requiredCapabilities == [.tools])
    }

    @Test func routeReceiptCapturesImmutableSelectionReason() throws {
        let candidates = [ProviderRouteCandidate(id: "tools", providerName: "tools", modelID: "m-tools", capabilities: [.tools])]
        let request = ProviderRouteRequest(requiredCapabilities: [.tools], allowedProviderIDs: ["tools"])
        let receipt = try CapabilityRouter.routeWithReceipt(request: request, candidates: candidates, receiptID: "receipt-1")
        #expect(receipt.receiptID == "receipt-1")
        #expect(receipt.route.providerID == "tools")
        #expect(receipt.selectionReason.contains("required capabilities satisfied; provider allowlist satisfied"))
        #expect(receipt.request == request)
    }

    @Test func routeRejectsMissingCapabilityInsteadOfGuessingFromName() {
        let candidates = [ProviderRouteCandidate(id: "vision-name", providerName: "vision", modelID: "m", capabilities: [.streaming])]
        let request = ProviderRouteRequest(requiredCapabilities: [.vision])
        #expect(throws: CapabilityRoutingError.noMatchingProvider) {
            _ = try CapabilityRouter.route(request: request, candidates: candidates)
        }
    }

    @Test func verifiedBindingReceiptPreservesCapabilitiesAndConfigurationFingerprint() throws {
        let receipt = try CapabilityRouter.verifiedBindingReceipt(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "fp-a",
            requiredCapabilities: [.tools],
            availableCapabilities: [.streaming, .tools]
        )
        #expect(receipt.receiptID == "route:provider-a:model-a:fp-a")
        #expect(receipt.route.requiredCapabilities == [.tools])
        #expect(receipt.route.availableCapabilities == [.streaming, .tools])
        #expect(receipt.route.configurationFingerprint == "fp-a")
    }

    @Test func verifiedBindingReceiptRejectsMissingCapabilityBeforeSelection() {
        #expect(throws: CapabilityRoutingError.noMatchingProvider) {
            _ = try CapabilityRouter.verifiedBindingReceipt(
                providerID: "provider-a",
                modelID: "model-a",
                configurationFingerprint: "fp-a",
                requiredCapabilities: [.vision],
                availableCapabilities: [.streaming]
            )
        }
    }

    @Test func routeRejectsDisallowedProviderAndRecordsDeterministicReason() {
        let candidates = [ProviderRouteCandidate(id: "p1", providerName: "p1", modelID: "m", capabilities: [.tools])]
        let request = ProviderRouteRequest(requiredCapabilities: [.tools], allowedProviderIDs: ["other"])
        #expect(throws: CapabilityRoutingError.noMatchingProvider) {
            _ = try CapabilityRouter.route(request: request, candidates: candidates)
        }
    }

    @Test func routeUsesExplicitCostLatencyQualityPolicyAfterCapabilityFiltering() throws {
        let candidates = [
            ProviderRouteCandidate(id: "cheap", providerName: "p", modelID: "m1", capabilities: [.tools], costMicros: 1, latencyMilliseconds: 200, qualityScore: 60),
            ProviderRouteCandidate(id: "quality", providerName: "p", modelID: "m2", capabilities: [.tools], costMicros: 10, latencyMilliseconds: 40, qualityScore: 95),
        ]
        let request = ProviderRouteRequest(
            requiredCapabilities: [.tools],
            policy: ProviderRoutePolicy(costWeight: 1, latencyWeight: 1, qualityWeight: 4)
        )

        let route = try CapabilityRouter.route(request: request, candidates: candidates)

        #expect(route.providerID == "quality")
        #expect(route.selectionScore > 0)
    }

    @Test func routeReceiptAuditsNonDefaultPolicyScore() throws {
        let policy = ProviderRoutePolicy(costWeight: 1, latencyWeight: 1, qualityWeight: 4)
        let request = ProviderRouteRequest(requiredCapabilities: [.tools], policy: policy)
        let receipt = try CapabilityRouter.routeWithReceipt(
            request: request,
            candidates: [ProviderRouteCandidate(id: "p", providerName: "p", modelID: "m", capabilities: [.tools], qualityScore: 10)],
            receiptID: "receipt-policy"
        )

        #expect(receipt.selectionReason.contains("policy score="))
        #expect(receipt.selectionReason.contains("qualityWeight=4.0"))
    }

    @Test func routeReportsExactPolicyScoreInReceipt() throws {
        // policy score = qualityWeight*qualityScore - costWeight*costMicros - latencyWeight*latencyMilliseconds
        // 4*80 - 1*10 - 1*20 = 290
        let policy = ProviderRoutePolicy(costWeight: 1, latencyWeight: 1, qualityWeight: 4)
        let request = ProviderRouteRequest(
            requiredCapabilities: [.tools],
            policy: policy
        )
        let receipt = try CapabilityRouter.routeWithReceipt(
            request: request,
            candidates: [ProviderRouteCandidate(id: "p", providerName: "p", modelID: "m", capabilities: [.tools], costMicros: 10, latencyMilliseconds: 20, qualityScore: 80)],
            receiptID: "receipt-exact-score"
        )

        #expect(receipt.route.selectionScore == 290)
        #expect(receipt.selectionReason.contains("policy score=290.0"))
    }

    @Test func routeTieBreaksDeterministicallyToFirstEligibleCandidate() throws {
        let makeCandidate = { (id: String) in
            ProviderRouteCandidate(id: id, providerName: "p", modelID: "m-\(id)", capabilities: [.tools], costMicros: 10, latencyMilliseconds: 20, qualityScore: 80)
        }
        // Identical metrics => identical policy score; no allowlist => both eligible.
        let request = ProviderRouteRequest(requiredCapabilities: [.tools])

        let forward = [makeCandidate("first"), makeCandidate("second")]
        let forwardRoute = try CapabilityRouter.route(request: request, candidates: forward)
        #expect(forwardRoute.providerID == "first")
        #expect(forwardRoute.selectionScore == 50) // default policy 1,1,1: 80 - 10 - 20

        // Reversing candidate order must flip the winner to the new first element:
        // the tie-break is deterministic (array order), never iteration/hash dependent.
        let reversed = [makeCandidate("second"), makeCandidate("first")]
        let reversedRoute = try CapabilityRouter.route(request: request, candidates: reversed)
        #expect(reversedRoute.providerID == "second")

        // Same order twice => identical winner and identical exact score.
        let again = try CapabilityRouter.route(request: request, candidates: forward)
        #expect(again.providerID == "first")
        #expect(again.selectionScore == forwardRoute.selectionScore)
    }

    @Test func routeReceiptRecordsNilAllowlistAsUnconstrained() throws {
        let request = ProviderRouteRequest(requiredCapabilities: [.tools], allowedProviderIDs: nil)
        let receipt = try CapabilityRouter.routeWithReceipt(
            request: request,
            candidates: [ProviderRouteCandidate(id: "p", providerName: "p", modelID: "m", capabilities: [.tools])],
            receiptID: "receipt-nil-allowlist"
        )

        #expect(receipt.request.allowedProviderIDs == nil)
        #expect(receipt.selectionReason.contains("provider allowlist not constrained"))
        #expect(!receipt.selectionReason.contains("provider allowlist satisfied"))
    }

    @Test func frozenBindingReceiptRecordsImmutableBindingAndDefersCapabilityRouting() throws {
        let receipt = CapabilityRouter.frozenBindingReceipt(
            providerID: "provider-frozen",
            modelID: "model-frozen",
            configurationFingerprint: "fp-frozen"
        )

        #expect(receipt.receiptID == "route:provider-frozen:model-frozen:fp-frozen")
        #expect(receipt.route.providerID == "provider-frozen")
        #expect(receipt.route.modelID == "model-frozen")
        #expect(receipt.route.configurationFingerprint == "fp-frozen")
        #expect(receipt.route.requiredCapabilities.isEmpty)
        #expect(receipt.route.availableCapabilities.isEmpty)
        #expect(receipt.request.requiredCapabilities.isEmpty)
        #expect(receipt.request.allowedProviderIDs == ["provider-frozen"])
        #expect(receipt.selectionReason == "frozen provider/model binding; capability routing deferred to A2")
    }

    @Test func resolutionReceiptUsesDeclaredFallbackAndPreservesPolicyInput() {
        let request = ProviderRouteRequest(
            requiredCapabilities: [.vision],
            allowedProviderIDs: ["primary"],
            policy: ProviderRoutePolicy(costWeight: 2, latencyWeight: 3, qualityWeight: 4)
        )
        let input = ProviderRoutePolicyInput(
            request: request,
            fallback: .binding(
                providerID: "fallback",
                providerName: "Fallback",
                modelID: "fallback-model",
                configurationFingerprint: "fallback-fp",
                reason: "primary capability unavailable"
            )
        )

        let receipt = CapabilityRouter.resolve(
            policyInput: input,
            candidates: [ProviderRouteCandidate(id: "primary", providerName: "Primary", modelID: "primary-model", capabilities: [.tools])],
            receiptID: "resolution-fallback"
        )

        #expect(receipt.policyInput == input)
        #expect(receipt.outcome == .fallback)
        #expect(receipt.route?.providerID == "fallback")
        #expect(receipt.route?.requiredCapabilities.isEmpty == true)
        #expect(receipt.selectionReason == "fallback binding; primary capability unavailable")
    }

    @Test func resolutionReceiptRecordsDeterministicFailureWhenNoFallbackMatches() {
        let input = ProviderRoutePolicyInput(
            request: ProviderRouteRequest(requiredCapabilities: [.vision], allowedProviderIDs: ["primary"]),
            fallback: .fail
        )

        let receipt = CapabilityRouter.resolve(
            policyInput: input,
            candidates: [ProviderRouteCandidate(id: "primary", providerName: "Primary", modelID: "primary-model", capabilities: [.tools])],
            receiptID: "resolution-failure"
        )

        #expect(receipt.policyInput == input)
        #expect(receipt.outcome == .failure(.noMatchingProvider))
        #expect(receipt.route == nil)
        #expect(receipt.selectionReason == "routing failed; no matching provider")
    }

    @Test func fallbackBindingReceiptPreservesPolicyInputAndReason() {
        let policy = ProviderRoutePolicy(costWeight: 2, latencyWeight: 3, qualityWeight: 4)
        let request = ProviderRouteRequest(requiredCapabilities: [.vision], allowedProviderIDs: ["fallback"], policy: policy)

        let receipt = CapabilityRouter.fallbackBindingReceipt(
            providerID: "fallback",
            modelID: "model-fallback",
            configurationFingerprint: "fp-fallback",
            request: request,
            reason: "no local capability manifest"
        )

        #expect(receipt.receiptID == "route:fallback:model-fallback:fp-fallback")
        #expect(receipt.request == request)
        #expect(receipt.route.providerID == "fallback")
        #expect(receipt.route.modelID == "model-fallback")
        #expect(receipt.route.requiredCapabilities.isEmpty)
        #expect(receipt.route.availableCapabilities.isEmpty)
        #expect(receipt.route.configurationFingerprint == "fp-fallback")
        #expect(receipt.selectionReason == "fallback binding; no local capability manifest")
    }

    @Test func routingObservationPreservesSelectedFallbackAndFailureReceipts() {
        let selected = CapabilityRouter.resolve(
            policyInput: ProviderRoutePolicyInput(request: ProviderRouteRequest(requiredCapabilities: [.tools])),
            candidates: [ProviderRouteCandidate(id: "selected", providerName: "Selected", modelID: "selected-model", capabilities: [.tools])],
            receiptID: "selected-receipt"
        )
        let fallback = CapabilityRouter.resolve(
            policyInput: ProviderRoutePolicyInput(
                request: ProviderRouteRequest(requiredCapabilities: [.vision]),
                fallback: .binding(providerID: "fallback", providerName: "Fallback", modelID: "fallback-model", configurationFingerprint: "fallback-fingerprint", reason: "declared fallback")
            ),
            candidates: [],
            receiptID: "fallback-receipt"
        )
        let failure = CapabilityRouter.resolve(
            policyInput: ProviderRoutePolicyInput(request: ProviderRouteRequest(requiredCapabilities: [.vision])),
            candidates: [],
            receiptID: "failure-receipt"
        )

        let observations = [
            ProviderRouteResolutionObservation(receipt: selected),
            ProviderRouteResolutionObservation(receipt: fallback),
            ProviderRouteResolutionObservation(receipt: failure),
        ]

        #expect(observations.map(\.outcome) == [.selected, .fallback, .failure])
        #expect(observations.map(\.receiptID) == ["selected-receipt", "fallback-receipt", "failure-receipt"])
        #expect(observations[0].route?.providerID == "selected")
        #expect(observations[1].route?.providerID == "fallback")
        #expect(observations[2].route == nil)
    }

    @Test func routingObservationFailsClosedForUnknownOutcomeValues() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "unknown-receipt",
            observedOutcome: "deferred",
            route: ProviderRouteSnapshot(
                candidate: ProviderRouteCandidate(id: "must-not-escape", providerName: "Unknown", modelID: "unknown-model", capabilities: [.tools]),
                requiredCapabilities: [.tools]
            ),
            selectionReason: "unrecognized future outcome"
        )

        #expect(observation.outcome == .failure)
        #expect(observation.route == nil)
        #expect(observation.selectionReason == "routing observation failed closed; unknown outcome=deferred")
    }

    @Test func policyConsumerRetainsBoundedCapabilityDenialReceipt() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "task:capability-routing",
            allowedCapabilities: ["tools"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30)
        )
        let base = CapabilityRoutingCountingExecutor()
        let executor = PolicyEnforcedToolExecutor(
            base: base,
            goal: goal,
            lease: lease,
            clock: { now }
        )
        let unknown = String(repeating: "description grants tools ", count: 12)

        await #expect(throws: PolicyEnforcedToolExecutorError.policyViolation(.capabilityNotAllowed)) {
            _ = try await executor.execute(name: unknown, input: [:])
        }

        #expect(base.executionCount == 0)
        #expect(executor.lastCapabilityDenialReceipt?.reason == .capabilityNotAllowed)
        #expect(executor.lastCapabilityDenialReceipt?.capabilityID == String(unknown.prefix(CapabilityRouter.maxCapabilityIdentifierLength)))
    }

}

private final class CapabilityRoutingCountingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var _executionCount = 0

    var executionCount: Int {
        lock.withLock { _executionCount }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { _executionCount += 1 }
        return "unexpected:\(name)"
    }
}
