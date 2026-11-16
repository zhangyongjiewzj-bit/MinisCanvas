import Testing
@testable import MinisCore

@Suite("Provider model selection health")
struct ProviderModelSelectionHealthTests {
    @Test("configured blocked readiness cannot be presented as available")
    func blockedConfiguredModelIsNotSelectable() {
        let reference = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "model-a"
        )
        let catalog = ProviderModelSelectionCatalog(candidates: [
            candidate(
                providerID: "provider-a",
                modelID: "model-a",
                status: .unavailable,
                readinessState: .blocked,
                credentialVersion: "credential-a"
            )
        ])

        let decision = catalog.decision(for: reference)
        #expect(decision.isSelectable == false)
        #expect(decision.availability == .blocked)
        #expect(decision.reason == .readinessBlocked)
        #expect(decision.candidate?.isConfigured == true)
    }

    @Test("a passed observation for the current credential restores one provider")
    func newCredentialPassedStateRecoversWithoutUsingOldState() {
        let reference = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "model-a"
        )
        let catalog = ProviderModelSelectionCatalog(
            candidates: [
                candidate(
                    providerID: "provider-a",
                    modelID: "model-a",
                    status: .unavailable,
                    readinessState: .blocked,
                    credentialVersion: "old-credential"
                ),
                candidate(
                    providerID: "provider-a",
                    modelID: "model-a",
                    status: .passed,
                    readinessState: .live,
                    credentialVersion: "new-credential"
                )
            ],
            activeCredentialVersions: ["provider-a": "new-credential"]
        )

        let decision = catalog.decision(for: reference)
        #expect(decision.isSelectable)
        #expect(decision.availability == .available)
        #expect(decision.reason == .readinessPassed)
        #expect(decision.candidate?.credentialVersion == "new-credential")
    }

    @Test("one provider's blocked model does not poison another provider")
    func providerFailureDoesNotPolluteOtherModels() {
        let catalog = ProviderModelSelectionCatalog(candidates: [
            candidate(
                providerID: "provider-a",
                modelID: "model-a",
                status: .unavailable,
                readinessState: .blocked,
                credentialVersion: "a"
            ),
            candidate(
                providerID: "provider-b",
                modelID: "model-b",
                status: .passed,
                readinessState: .live,
                credentialVersion: "b"
            )
        ])

        let other = catalog.decision(for: ProviderModelSelectionReference(
            providerID: "provider-b",
            modelID: "model-b"
        ))
        #expect(other.isSelectable)
        #expect(other.candidate?.providerID == "provider-b")
    }

    @Test("default and persisted old aliases remain retained and resolve in provider scope")
    func persistedAliasIsRetainedAndResolved() {
        let oldReference = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "legacy-model"
        )
        let catalog = ProviderModelSelectionCatalog(
            candidates: [candidate(
                providerID: "provider-a",
                modelID: "current-model",
                aliases: ["legacy-model"],
                status: .passed,
                readinessState: .live,
                credentialVersion: "current"
            )],
            defaultSelection: oldReference,
            persistedSelection: oldReference
        )

        #expect(catalog.retainedDefaultSelection == oldReference)
        #expect(catalog.retainedPersistedSelection == oldReference)
        #expect(catalog.defaultDecision?.isSelectable == true)
        #expect(catalog.defaultDecision?.requested == oldReference)
        #expect(catalog.defaultDecision?.resolvedReference?.modelID == "current-model")
        #expect(catalog.persistedDecision?.resolvedReference?.modelID == "current-model")
    }

    @Test("a bare alias from another provider cannot satisfy a persisted reference")
    func aliasesNeverCrossProviderNamespace() {
        let catalog = ProviderModelSelectionCatalog(candidates: [candidate(
            providerID: "provider-b",
            modelID: "current-model",
            aliases: ["legacy-model"],
            status: .passed,
            readinessState: .live,
            credentialVersion: "b"
        )])

        let decision = catalog.decision(for: ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "legacy-model"
        ))
        #expect(decision.isSelectable == false)
        #expect(decision.availability == .missing)
        #expect(decision.reason == .catalogEntryMissing)
    }

    @Test("case-variant duplicate provider identities fail closed")
    func caseVariantDuplicateProviderIdentitiesAreAmbiguous() {
        let catalog = ProviderModelSelectionCatalog(candidates: [
            candidate(
                providerID: "Provider-A",
                modelID: "model-a",
                status: .passed,
                readinessState: .live,
                credentialVersion: "v1"
            ),
            candidate(
                providerID: "provider-a",
                modelID: "model-a",
                status: .passed,
                readinessState: .live,
                credentialVersion: "v1"
            )
        ])

        let decision = catalog.decision(for: ProviderModelSelectionReference(
            providerID: "PROVIDER-A",
            modelID: "model-a"
        ))
        #expect(decision.availability == .ambiguous)
        #expect(decision.reason == .aliasAmbiguous)
        #expect(decision.isSelectable == false)
    }

    @Test("unresolved persisted model remains available to persistence even when catalog is incomplete")
    func unresolvedPersistedReferenceIsNotDropped() {
        let persisted = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "old-model"
        )
        let catalog = ProviderModelSelectionCatalog(
            candidates: [],
            persistedSelection: persisted
        )

        #expect(catalog.retainedPersistedSelection == persisted)
        #expect(catalog.persistedDecision?.availability == .missing)
        #expect(catalog.persistedDecision?.isSelectable == false)
    }

    private func candidate(
        providerID: String,
        modelID: String,
        aliases: [String] = [],
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        credentialVersion: String
    ) -> ProviderModelSelectionCandidate {
        ProviderModelSelectionCandidate(
            providerID: providerID,
            modelID: modelID,
            aliases: aliases,
            isConfigured: true,
            status: status,
            readinessState: readinessState,
            credentialVersion: credentialVersion
        )
    }
}
