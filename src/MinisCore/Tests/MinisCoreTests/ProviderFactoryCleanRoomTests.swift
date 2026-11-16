import Testing
@testable import MinisCore

@Suite(.serialized)
struct ProviderFactoryCleanRoomTests {

    @Test func openRouterDoesNotInjectReferenceRepositoryReferer() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "OpenRouter",
            providerType: .openRouter,
            apiKey: "test-key"
        )

        let provider = try factory.makeProvider(for: config)
        let openRouter = try #require(provider as? OpenAICompatibleProvider)

        #expect(openRouter.extraHeaders["HTTP-Referer"] == nil)
        #expect(openRouter.extraHeaders.values.allSatisfy { !$0.localizedCaseInsensitiveContains("openminis") })
        #expect(openRouter.extraHeaders["X-Title"] == "MinisCanvas")
    }

    @Test func invalidLocalBaseURLIsRejectedWithoutCrashing() {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Broken local",
            providerType: .local,
            credentialType: .apiKey,
            customBaseURL: "http://["
        )

        #expect(throws: ProviderFactory.FactoryError.self) {
            try factory.makeProvider(for: config, requireCredentials: false)
        }
    }

    @Test func missingCredentialIsTypedUnavailableWithoutBlockingOtherProviders() throws {
        let factory = ProviderFactory()
        let missing = ProviderConfig(
            label: "DeepSeek without key",
            providerType: .deepSeek
        )
        let missingResult = try factory.makeProviderResult(for: missing)
        guard case .unavailable(.missingCredential(let label)) = missingResult else {
            Issue.record("missing credentials must be a typed unavailable result")
            return
        }
        #expect(label == "DeepSeek without key")

        let usable = ProviderConfig(
            label: "OpenAI fixture",
            providerType: .openAI,
            apiKey: "fixture-key"
        )
        let usableResult = try factory.makeProviderResult(for: usable)
        guard case .ready(let provider) = usableResult else {
            Issue.record("one unavailable provider must not block another provider")
            return
        }
        #expect(provider.name == "OpenAI")
    }

    @Test func unknownProviderRemainsFailClosed() {
        let factory = ProviderFactory()
        let unknown = ProviderConfig(
            label: "Unknown provider",
            providerType: .unsupported,
            apiKey: "fixture-key"
        )

        #expect(throws: ProviderFactory.FactoryError.self) {
            try factory.makeProviderResult(for: unknown)
        }
    }

    @Test func admittedAuditBindsFactoryToCurrentRouteAndIsOneShot() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Audited OpenAI",
            providerType: .openAI,
            apiKey: "fixture-key"
        )
        let audit = makeAudit(receiptID: "factory-audit-one-shot")
        let policyRevision = try #require(audit.policyRevision)

        let provider = try factory.makeProvider(
            for: config,
            auditReceipt: audit,
            expectedPolicyRevision: policyRevision,
            expectedConfigurationFingerprint: "settings-fp"
        )
        #expect(provider.name == "OpenAI")
        #expect(throws: ProviderFactory.FactoryError.auditReceiptReplayed) {
            try factory.makeProvider(
                for: config,
                auditReceipt: audit,
                expectedPolicyRevision: policyRevision,
                expectedConfigurationFingerprint: "settings-fp"
            )
        }
    }

    @Test func stalePolicyOrSettingsCannotCreateProviderFromAudit() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Audited OpenAI",
            providerType: .openAI,
            apiKey: "fixture-key"
        )
        let audit = makeAudit(receiptID: "factory-audit-stale")
        let policyRevision = try #require(audit.policyRevision)

        #expect(throws: ProviderFactory.FactoryError.auditPolicyRevisionMismatch) {
            try factory.makeProvider(
                for: config,
                auditReceipt: audit,
                expectedPolicyRevision: "provider-policy:stale",
                expectedConfigurationFingerprint: "settings-fp"
            )
        }
        #expect(throws: ProviderFactory.FactoryError.auditConfigurationMismatch) {
            try factory.makeProvider(
                for: config,
                auditReceipt: audit,
                expectedPolicyRevision: policyRevision,
                expectedConfigurationFingerprint: "settings-changed"
            )
        }
    }

    @Test func routeBindingMismatchAndUnknownDecisionFailClosed() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Renamed OpenAI",
            providerType: .openAI,
            runtimeProviderID: "Renamed",
            apiKey: "fixture-key"
        )
        let audit = makeAudit(receiptID: "factory-audit-binding")
        let policyRevision = try #require(audit.policyRevision)

        #expect(throws: ProviderFactory.FactoryError.auditBindingMismatch) {
            try factory.makeProvider(
                for: config,
                auditReceipt: audit,
                expectedPolicyRevision: policyRevision,
                expectedConfigurationFingerprint: "settings-fp"
            )
        }

        let unknown = ProviderRoutePolicyAuditReceipt(observation: ProviderRouteResolutionObservation(
            receiptID: "factory-audit-unknown",
            observedOutcome: "future-decision",
            route: nil,
            selectionReason: "unknown"
        ))
        #expect(throws: ProviderFactory.FactoryError.auditReceiptDenied) {
            try factory.makeProvider(
                for: config,
                auditReceipt: unknown,
                expectedPolicyRevision: "provider-policy:unknown",
                expectedConfigurationFingerprint: "settings-fp"
            )
        }
    }

    @Test func duplicateReceiptIdentityWithDifferentBindingFailsClosed() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Audited OpenAI",
            providerType: .openAI,
            apiKey: "fixture-key"
        )
        let first = makeAudit(
            receiptID: "Bearer abcd1111wxyz",
            providerID: "OpenAI",
            configurationFingerprint: "settings-v1"
        )
        let firstPolicyRevision = try #require(first.policyRevision)
        _ = try factory.makeProvider(
            for: config,
            auditReceipt: first,
            expectedPolicyRevision: firstPolicyRevision,
            expectedConfigurationFingerprint: "settings-v1"
        )

        // The source ledger keys raw IDs, while the product receipt exposes a
        // redacted identity. The factory must fence this projection collision
        // before a second route can be constructed.
        let conflicting = makeAudit(
            // Distinct raw IDs intentionally redact to the same receipt
            // identity, exercising the consumer's terminal collision fence.
            receiptID: "Bearer abcd2222wxyz",
            providerID: "OpenAI",
            configurationFingerprint: "settings-v2"
        )
        let conflictingPolicyRevision = try #require(conflicting.policyRevision)
        #expect(throws: ProviderFactory.FactoryError.auditReceiptConflict) {
            try factory.makeProvider(
                for: config,
                auditReceipt: conflicting,
                expectedPolicyRevision: conflictingPolicyRevision,
                expectedConfigurationFingerprint: "settings-v2"
            )
        }
    }

    private func makeAudit(
        receiptID: String,
        providerID: String = "OpenAI",
        configurationFingerprint: String = "settings-fp"
    ) -> ProviderRoutePolicyAuditReceipt {
        let policy = ProviderRoutePolicyInput(
            request: ProviderRouteRequest(
                requiredCapabilities: [.tools],
                allowedProviderIDs: [providerID]
            )
        )
        let route = ProviderRouteSnapshot(
            candidate: ProviderRouteCandidate(
                id: providerID,
                providerName: providerID,
                modelID: LLMModel.gpt4oMini.id,
                capabilities: [.tools]
            ),
            requiredCapabilities: [.tools],
            configurationFingerprint: configurationFingerprint
        )
        return ProviderRoutePolicyAuditReceipt(receipt: ProviderRouteResolutionReceipt(
            receiptID: receiptID,
            policyInput: policy,
            outcome: .selected,
            route: route,
            selectionReason: "factory audit"
        ))
    }
}
