import Testing
@testable import MinisCore

struct ProviderRoutePolicyAuditTests {
    @Test func auditAdmitsSelectedObservationAndPreservesRoutePayload() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "selected-receipt",
            observedOutcome: "selected",
            route: routeSnapshot(id: "selected"),
            selectionReason: "capabilities satisfied"
        )

        let audit = ProviderRoutePolicyAuditReceipt(observation: observation)

        #expect(audit.receiptID == "selected-receipt")
        #expect(audit.decision == ProviderRoutePolicyAuditReceipt.Decision.admitted)
        #expect(audit.route?.providerID == "selected")
        #expect(audit.reason == "capabilities satisfied")
    }

    @Test func auditAdmitsFallbackObservationAndPreservesRoutePayload() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "fallback-receipt",
            observedOutcome: "fallback",
            route: routeSnapshot(id: "fallback"),
            selectionReason: "declared fallback"
        )

        let audit = ProviderRoutePolicyAuditReceipt(observation: observation)

        #expect(audit.decision == ProviderRoutePolicyAuditReceipt.Decision.admitted)
        #expect(audit.route?.providerID == "fallback")
        #expect(audit.reason == "declared fallback")
    }

    @Test func auditDeniesMissingOrMalformedRouteIdentity() {
        let missingRoute = ProviderRouteResolutionObservation(
            receiptID: "missing-route-receipt",
            observedOutcome: "selected",
            route: nil,
            selectionReason: "selected without binding"
        )
        let missingAudit = ProviderRoutePolicyAuditReceipt(observation: missingRoute)
        #expect(missingAudit.decision == .denied)
        #expect(missingAudit.route == nil)
        #expect(missingAudit.reason == "routing audit denied; invalid route identity")

        let malformedRoute = ProviderRouteResolutionObservation(
            receiptID: "malformed-route-receipt",
            observedOutcome: "fallback",
            route: ProviderRouteSnapshot(
                candidate: ProviderRouteCandidate(
                    id: "   ",
                    providerName: "provider",
                    modelID: "model",
                    capabilities: [.tools]
                ),
                requiredCapabilities: [.tools]
            ),
            selectionReason: "fallback binding"
        )
        let malformedAudit = ProviderRoutePolicyAuditReceipt(observation: malformedRoute)
        #expect(malformedAudit.decision == .denied)
        #expect(malformedAudit.route == nil)
        #expect(malformedAudit.bindingFingerprint == nil)
    }

    @Test func auditReceiptIDIsTerminalAcrossReplayAndRouteConflict() {
        let firstObservation = ProviderRouteResolutionObservation(
            receiptID: "terminal-audit-receipt",
            observedOutcome: "selected",
            route: routeSnapshot(id: "provider-a"),
            selectionReason: "selected"
        )
        let first = ProviderRoutePolicyAuditReceipt(observation: firstObservation)
        #expect(first.decision == .admitted)
        #expect(first.bindingFingerprint?.hasPrefix("provider-route-audit:") == true)

        let replay = ProviderRoutePolicyAuditReceipt(observation: firstObservation)
        #expect(replay.decision == .denied)
        #expect(replay.route == nil)
        #expect(replay.reason == "routing audit denied; receipt replay or identity conflict")

        let conflict = ProviderRoutePolicyAuditReceipt(observation: ProviderRouteResolutionObservation(
            receiptID: "terminal-audit-receipt",
            observedOutcome: "selected",
            route: routeSnapshot(id: "provider-b"),
            selectionReason: "selected"
        ))
        #expect(conflict.decision == .denied)
        #expect(conflict.route == nil)
    }

    @Test func receiptCarriesTypedPolicyRevisionIntoCompositeIdentity() {
        let policy = ProviderRoutePolicyInput(
            request: ProviderRouteRequest(
                requiredCapabilities: [.tools],
                allowedProviderIDs: ["provider-policy"]
            )
        )
        let receipt = ProviderRouteResolutionReceipt(
            receiptID: "policy-revision-receipt",
            policyInput: policy,
            outcome: .selected,
            route: routeSnapshot(id: "provider-policy"),
            selectionReason: "policy selected"
        )

        let audit = ProviderRoutePolicyAuditReceipt(receipt: receipt)
        #expect(audit.decision == .admitted)
        #expect(audit.policyRevision?.hasPrefix("provider-policy:") == true)
        #expect(audit.bindingFingerprint?.hasPrefix("provider-route-audit:") == true)

        let changedPolicyReceipt = ProviderRouteResolutionReceipt(
            receiptID: "policy-revision-receipt",
            policyInput: ProviderRoutePolicyInput(
                request: ProviderRouteRequest(
                    requiredCapabilities: [.vision],
                    allowedProviderIDs: ["provider-policy"]
                )
            ),
            outcome: .selected,
            route: routeSnapshot(id: "provider-policy"),
            selectionReason: "stale policy revision"
        )
        let changedAudit = ProviderRoutePolicyAuditReceipt(receipt: changedPolicyReceipt)
        #expect(changedAudit.decision == .denied)
        #expect(changedAudit.route == nil)
    }

    @Test func auditConsumesResolutionReceiptWithoutCallingAnyProvider() {
        let receipt = ProviderRouteResolutionReceipt(
            receiptID: "receipt-source",
            policyInput: ProviderRoutePolicyInput(request: ProviderRouteRequest(requiredCapabilities: [.tools])),
            outcome: .failure(.noMatchingProvider),
            route: routeSnapshot(id: "must-not-escape"),
            selectionReason: "no matching provider"
        )

        let audit = ProviderRoutePolicyAuditReceipt(receipt: receipt)

        #expect(audit.receiptID == "receipt-source")
        #expect(audit.decision == .denied)
        #expect(audit.route == nil)
        #expect(audit.reason == "no matching provider")
    }

    @Test func auditDeniesFailureAndDoesNotExposeRoutePayload() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "failure-receipt",
            observedOutcome: "failure",
            route: routeSnapshot(id: "must-not-escape"),
            selectionReason: "no matching provider"
        )

        let audit = ProviderRoutePolicyAuditReceipt(observation: observation)

        #expect(audit.receiptID == "failure-receipt")
        #expect(audit.decision == .denied)
        #expect(audit.route == nil)
        #expect(audit.reason == "no matching provider")
    }

    @Test func auditFailsClosedForUnknownOutcomeAndDoesNotExposeRoutePayload() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "unknown-receipt",
            observedOutcome: "deferred",
            route: routeSnapshot(id: "must-not-escape"),
            selectionReason: "unrecognized future outcome"
        )

        let audit = ProviderRoutePolicyAuditReceipt(observation: observation)

        #expect(audit.receiptID == "unknown-receipt")
        #expect(audit.decision == .denied)
        #expect(audit.route == nil)
        #expect(audit.reason == "routing observation failed closed; unknown outcome=deferred")
    }

    @Test("typed unavailable candidate is skipped and healthy fallback remains auditable")
    func typedUnavailableCandidateIsSkippedLocally() {
        let request = ProviderRouteRequest(requiredCapabilities: [.tools])
        let policy = ProviderRoutePolicyInput(request: request)
        let receipt = CapabilityRouter.resolve(
            policyInput: policy,
            candidates: [
                ProviderRouteCandidate(
                    id: "missing-keychain",
                    providerName: "missing-keychain",
                    modelID: "missing-model",
                    capabilities: [.tools],
                    qualityScore: 100,
                    availability: .unavailable(reason: .keychainMissing)
                ),
                ProviderRouteCandidate(
                    id: "healthy-fallback",
                    providerName: "healthy-fallback",
                    modelID: "healthy-model",
                    capabilities: [.tools],
                    qualityScore: 1
                )
            ],
            receiptID: "isolated-unavailable"
        )

        let audit = ProviderRoutePolicyAuditReceipt(receipt: receipt)
        #expect(audit.decision == ProviderRoutePolicyAuditReceipt.Decision.admitted)
        #expect(audit.route?.providerID == "healthy-fallback")
        #expect(audit.reason.contains("skipped unavailable candidates"))
        #expect(audit.reason.contains("missing-keychain=keychainMissing"))
    }

    @Test("all typed unavailable candidates fail closed with an auditable reason")
    func allTypedUnavailableCandidatesFailClosed() {
        let policy = ProviderRoutePolicyInput(
            request: ProviderRouteRequest(requiredCapabilities: [.tools]),
            fallback: .fail
        )
        let receipt = CapabilityRouter.resolve(
            policyInput: policy,
            candidates: [
                ProviderRouteCandidate(
                    id: "missing-keychain",
                    providerName: "missing-keychain",
                    modelID: "missing-model",
                    capabilities: [.tools],
                    availability: .unavailable(reason: .keychainMissing)
                )
            ],
            receiptID: "all-unavailable"
        )

        let audit = ProviderRoutePolicyAuditReceipt(receipt: receipt)
        #expect(audit.decision == .denied)
        #expect(audit.route == nil)
        #expect(audit.reason.contains("no matching provider"))
        #expect(audit.reason.contains("missing-keychain=keychainMissing"))
    }

    @Test("audit receipt redacts secrets, remote content, paths, and bounds fields")
    func auditReceiptUsesBoundedProductRedaction() {
        let observation = ProviderRouteResolutionObservation(
            receiptID: "Bearer receipt-secret-token",
            observedOutcome: "selected",
            route: ProviderRouteSnapshot(
                candidate: ProviderRouteCandidate(
                    id: "/Users/alice/private/provider",
                    providerName: "https://remote.example/provider",
                    modelID: "model",
                    capabilities: [.tools]
                ),
                requiredCapabilities: [.tools]
            ),
            selectionReason: "Authorization: Bearer abcdefghijklmnop https://remote.example/body /Users/alice/private/transcript "
                + String(repeating: "x", count: 600)
        )

        let audit = ProviderRoutePolicyAuditReceipt(observation: observation)

        #expect(audit.receiptID.contains("***"))
        #expect(audit.reason.count == ProductRedactionPolicy.maxAuditFieldLength)
        #expect(!audit.reason.contains("https://remote.example/body"))
        #expect(!audit.reason.contains("/Users/alice/private/transcript"))
        #expect(audit.route?.providerID == "<path>")
        #expect(audit.route?.providerName == "<remote-url>")
    }

    @Test("shared product redaction masks known secrets before bounding")
    func sharedProductRedactionIsDeterministic() {
        let redacted = ProductRedactionPolicy.redact(
            "token=super-secret-value https://remote.example/body /tmp/private",
            knownSecrets: ["super-secret-value"],
            maxLength: 80
        )

        #expect(!redacted.contains("super-secret-value"))
        #expect(!redacted.contains("https://remote.example/body"))
        #expect(!redacted.contains("/tmp/private"))
        #expect(redacted.count <= 80)
    }

    private func routeSnapshot(id: String) -> ProviderRouteSnapshot {
        ProviderRouteSnapshot(
            candidate: ProviderRouteCandidate(
                id: id,
                providerName: id,
                modelID: "model-\(id)",
                capabilities: [.tools]
            ),
            requiredCapabilities: [.tools]
        )
    }
}
