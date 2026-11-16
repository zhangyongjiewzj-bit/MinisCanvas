import Foundation
import Testing
@testable import MinisCore

@Suite("Provider model picker consumer")
struct ProviderModelPickerConsumerTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_200_200)

    @Test("blocked configured record stays diagnostic but never reaches selectable picker items")
    func blockedRecordIsExcludedFromPicker() {
        let record = record(
            providerID: "provider-a",
            modelID: "model-a",
            status: .unavailable,
            readinessState: .blocked,
            evidenceID: nil
        )
        let consumer = ProviderModelPickerConsumer(records: [record])

        #expect(consumer.projection.item(providerID: "provider-a", modelID: "model-a") != nil)
        #expect(consumer.selectableItems.isEmpty)
        #expect(consumer.isSelectable(providerID: "provider-a", modelID: "model-a") == false)
    }

    @Test("current credential passed record is exposed while stale blocked record is ignored")
    func currentCredentialHealthControlsPicker() {
        let records = [
            record(
                providerID: "provider-a",
                modelID: "model-a",
                status: .unavailable,
                readinessState: .blocked,
                evidenceID: nil,
                checkedAt: checkedAt
            ),
            record(
                providerID: "provider-a",
                modelID: "model-a",
                status: .passed,
                readinessState: .live,
                evidenceID: "live-settings:" + String(repeating: "a", count: 64),
                checkedAt: checkedAt.addingTimeInterval(10)
            )
        ]
        let catalog = ProviderModelSelectionCatalog(
            candidates: [
                candidate(
                    providerID: "provider-a",
                    modelID: "model-a",
                    status: .passed,
                    readinessState: .live,
                    credentialVersion: "new"
                )
            ],
            activeCredentialVersions: ["provider-a": "new"]
        )
        let consumer = ProviderModelPickerConsumer(records: records, catalog: catalog)

        #expect(consumer.selectableItems.map(\.id) == ["provider-a/model-a"])
        #expect(consumer.isSelectable(providerID: "provider-a", modelID: "model-a"))
    }

    @Test("one provider's blocked record does not hide another provider's passed model")
    func providerIsolationSurvivesConsumerProjection() {
        let records = [
            record(
                providerID: "provider-a",
                modelID: "model-a",
                status: .unavailable,
                readinessState: .blocked,
                evidenceID: nil
            ),
            record(
                providerID: "provider-b",
                modelID: "model-b",
                status: .passed,
                readinessState: .live,
                evidenceID: "live-settings:" + String(repeating: "b", count: 64)
            )
        ]
        let consumer = ProviderModelPickerConsumer(records: records)

        #expect(consumer.selectableItems.map(\.id) == ["provider-b/model-b"])
        #expect(consumer.isSelectable(providerID: "provider-a", modelID: "model-a") == false)
        #expect(consumer.isSelectable(providerID: "provider-b", modelID: "model-b"))
    }

    @Test("default and persisted references survive alias resolution through the consumer")
    func defaultAndPersistedSelectionAreRetained() {
        let oldReference = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "legacy-model"
        )
        let record = record(
            providerID: "provider-a",
            modelID: "current-model",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:" + String(repeating: "c", count: 64)
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
        let consumer = ProviderModelPickerConsumer(records: [record], catalog: catalog)

        #expect(consumer.retainedDefaultSelection == oldReference)
        #expect(consumer.retainedPersistedSelection == oldReference)
        #expect(consumer.defaultDecision?.isSelectable == true)
        #expect(consumer.defaultDecision?.resolvedReference?.modelID == "current-model")
        #expect(consumer.persistedDecision?.requested == oldReference)
    }

    @Test("a removed model is not resurrected by a stale catalog selection")
    func removedModelCannotBeResolvedFromStaleCatalog() {
        let selected = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "removed-model"
        )
        let consumer = ProviderModelPickerConsumer(
            records: [],
            catalog: ProviderModelSelectionCatalog(
                candidates: [candidate(
                    providerID: "provider-a",
                    modelID: "removed-model",
                    status: .passed,
                    readinessState: .live,
                    credentialVersion: "v1"
                )],
                persistedSelection: selected
            )
        )

        let decision = consumer.resolve(preferred: selected, fallback: nil)
        #expect(decision?.isSelectable == false)
        #expect(decision?.availability == .missing)
        #expect(consumer.selectableItems.isEmpty)
    }

    @Test("a newer blocked record fences an older selectable catalog revision")
    func newerBlockedProjectionFencesOlderCatalogRevision() {
        let selected = ProviderModelSelectionReference(
            providerID: "provider-a",
            modelID: "model-a"
        )
        let consumer = ProviderModelPickerConsumer(
            records: [record(
                providerID: "provider-a",
                modelID: "model-a",
                status: .unavailable,
                readinessState: .blocked,
                evidenceID: nil,
                checkedAt: checkedAt.addingTimeInterval(10)
            )],
            catalog: ProviderModelSelectionCatalog(
                candidates: [candidate(
                    providerID: "provider-a",
                    modelID: "model-a",
                    status: .passed,
                    readinessState: .live,
                    credentialVersion: "v1"
                )],
                persistedSelection: selected
            )
        )

        let decision = consumer.resolve(preferred: selected, fallback: nil)
        #expect(decision?.isSelectable == false)
        #expect(decision?.availability == .missing)
        #expect(consumer.isSelectable(providerID: "provider-a", modelID: "model-a") == false)
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

    private func record(
        providerID: String,
        modelID: String,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        evidenceID: String?,
        checkedAt: Date? = nil
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: status,
            readinessState: readinessState,
            checkedAt: checkedAt ?? self.checkedAt,
            evidenceID: evidenceID,
            isApplied: true
        )
    }
}
