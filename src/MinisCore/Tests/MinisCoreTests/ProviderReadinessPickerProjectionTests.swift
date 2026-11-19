import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness chat picker projection")
struct ProviderReadinessPickerProjectionTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_200_100)
    private let liveEvidence = "live-settings:" + String(repeating: "a", count: 64)

    @Test("projection keeps provider and model identity separate from canvas")
    func providerModelIdentityIsExplicit() {
        let records = [
            record(
                providerID: "provider-a",
                modelID: "model-a",
                status: .passed,
                readinessState: .mock,
                evidenceID: "mock-a"
            ),
            record(
                providerID: "provider-b",
                modelID: "model-b",
                status: .passed,
                readinessState: .live,
                evidenceID: liveEvidence
            )
        ]

        let projection = ChatModelPickerProjection(records: records)

        let first = projection.items.first { $0.providerID == "provider-a" }
        let second = projection.items.first { $0.providerID == "provider-b" }
        #expect(first?.modelID == "model-a")
        #expect(second?.modelID == "model-b")
        #expect(first?.id == "provider-a/model-a")
    }

    @Test("mock passed evidence is selectable but never live verified")
    func mockDoesNotEqualLive() {
        let projection = ChatModelPickerProjection(records: [
            record(
                providerID: "mock-provider",
                modelID: "mock-model",
                status: .passed,
                readinessState: .mock,
                evidenceID: "fixture-evidence"
            ),
            record(
                providerID: "live-provider",
                modelID: "live-model",
                status: .passed,
                readinessState: .live,
                evidenceID: liveEvidence
            )
        ])

        let mock = projection.items.first { $0.providerID == "mock-provider" }
        let live = projection.items.first { $0.providerID == "live-provider" }
        #expect(mock?.isSelectable == true)
        #expect(mock?.isLiveVerified == false)
        #expect(live?.isLiveVerified == true)
    }

    @Test("selection requires enabled configured ready and no in-flight state")
    func selectionTruthRequiresAllFacts() {
        let ready = ProviderReadinessSelectionTruth(
            isEnabled: true,
            isConfigured: true,
            isReady: true
        )
        #expect(ready.isActionable)
        #expect(
            ProviderReadinessSelectionTruth(
                isEnabled: false,
                isConfigured: true,
                isReady: true
            ).isActionable == false
        )
        #expect(
            ProviderReadinessSelectionTruth(
                isEnabled: true,
                isConfigured: false,
                isReady: true
            ).isActionable == false
        )
        #expect(
            ProviderReadinessSelectionTruth(
                isEnabled: true,
                isConfigured: true,
                isReady: false
            ).isActionable == false
        )
        #expect(
            ProviderReadinessSelectionTruth(
                isEnabled: true,
                isConfigured: true,
                isReady: true,
                isInFlight: true
            ).isActionable == false
        )
    }

    @Test("projection uses one stable vocabulary for mock/local/live/beta/blocked/unverified")
    func stableReadinessStatesAreDistinct() throws {
        let states: [(ProviderReadinessState, ProviderReadinessPersistenceStatus, ProviderReadinessProjectionState)] = [
            (.mock, .passed, .mock),
            (.local, .passed, .local),
            (.live, .passed, .live),
            (.beta, .passed, .beta),
            (.blocked, .unavailable, .blocked),
            (.unverified, .unverified, .unverified),
        ]
        for (readinessState, status, expected) in states {
            let record = record(
                providerID: expected.rawValue,
                modelID: "model",
                status: status,
                readinessState: readinessState,
                evidenceID: status == .passed ? "evidence" : nil
            )
            let item = try #require(ChatModelPickerProjection(records: [record]).items.first
                ?? ChatModelPickerProjection(records: [record]).pending.first)
            #expect(item.projectionState == expected)
            #expect(item.projectionReason.rawValue == (expected == .mock ? "mockEvidence" : expected == .local ? "localEvidence" : expected == .live ? "liveEvidence" : expected == .beta ? "betaEvidence" : expected.rawValue))
        }
    }

    @Test("unknown projection state is never selectable")
    func unknownStateFailsClosed() {
        let state = ProviderReadinessProjectionState(rawValueOrUnknown: "future-provider-state")
        #expect(state == .unknown)
        #expect(state.isSelectableState == false)
    }

    @Test("unverified and unavailable records remain visible with their error facts")
    func failureFactsSurviveProjection() {
        let projection = ChatModelPickerProjection(records: [
            record(
                providerID: "provider",
                modelID: "unverified-model",
                status: .unverified,
                readinessState: .unverified,
                evidenceID: nil
            ),
            record(
                providerID: "provider",
                modelID: "unavailable-model",
                status: .unavailable,
                readinessState: .blocked,
                errorCategory: .permissionDenied,
                evidenceID: nil
            )
        ])

        #expect(projection.items.allSatisfy { $0.isSelectable == false })
        let unavailable = projection.items.first { $0.modelID == "unavailable-model" }
        #expect(unavailable?.status == .unavailable)
        #expect(unavailable?.errorCategory == .permissionDenied)
        #expect(unavailable?.latency == 100)
    }

    @Test("a passed claim without verified evidence remains unselectable")
    func passedWithoutEvidenceFailsClosed() {
        let projection = ChatModelPickerProjection(records: [
            record(
                providerID: "provider",
                modelID: "unverified-pass",
                status: .passed,
                readinessState: .unverified,
                evidenceID: nil
            )
        ])

        #expect(projection.items[0].isSelectable == false)
        #expect(projection.items[0].isLiveVerified == false)
    }

    @Test("remote passed records require a traceable readiness receipt")
    func remotePassedRecordRejectsForgedEvidence() {
        let projection = ChatModelPickerProjection(records: [
            record(
                providerID: "remote-provider",
                modelID: "remote-model",
                status: .passed,
                readinessState: .live,
                evidenceID: "live-settings:not-a-receipt"
            )
        ])

        #expect(projection.items[0].isSelectable == false)
        #expect(projection.items[0].isLiveVerified == false)
        #expect(projection.receipt(
            providerID: "remote-provider",
            modelID: "remote-model"
        ) == nil)
    }

    @Test("one provider rebind replaces its old failure without global fallback red")
    func unavailableProviderRebindIsIsolated() throws {
        let oldProviderFailure = record(
            providerID: "provider-a",
            modelID: "shared-model",
            status: .unavailable,
            readinessState: .blocked,
            errorCategory: .permissionDenied,
            evidenceID: nil,
            checkedAt: checkedAt,
            isApplied: true
        )
        let reboundProviderSuccess = record(
            providerID: "provider-a",
            modelID: "shared-model",
            status: .passed,
            readinessState: .live,
            evidenceID: liveEvidence,
            checkedAt: checkedAt.addingTimeInterval(1),
            isApplied: true
        )
        let otherProviderSuccess = record(
            providerID: "provider-b",
            modelID: "shared-model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "provider-b-evidence",
            checkedAt: checkedAt,
            isApplied: true
        )

        let projection = ChatModelPickerProjection(records: [
            oldProviderFailure,
            reboundProviderSuccess,
            otherProviderSuccess,
        ])

        #expect(projection.items.count == 2)
        let rebound = try #require(projection.item(
            providerID: "provider-a",
            modelID: "shared-model"
        ))
        #expect(rebound.status == .passed)
        #expect(rebound.readinessState == .live)
        #expect(rebound.isBlocked == false)
        #expect(rebound.isActionable == false)
        #expect(rebound.isLiveVerified)
        #expect(projection.blockedItems.isEmpty)

        let other = try #require(projection.item(
            providerID: "PROVIDER-B",
            modelID: "shared-model"
        ))
        #expect(other.status == .passed)
        #expect(other.readinessState == .mock)
        #expect(other.isSelectable)
        #expect(projection.actionableItems.isEmpty)
    }

    @Test("unavailable entries stay blocked but actionable without changing another model")
    func unavailableEntryIsBlockedAndActionablePerModel() throws {
        let projection = ChatModelPickerProjection(records: [
            record(
                providerID: "provider-a",
                modelID: "failed-model",
                status: .unavailable,
                readinessState: .blocked,
                errorCategory: .timeout,
                evidenceID: nil,
                isApplied: true
            ),
            record(
                providerID: "provider-a",
                modelID: "healthy-model",
                status: .passed,
                readinessState: .mock,
                evidenceID: "healthy-evidence",
                isApplied: true
            ),
        ])

        let failed = try #require(projection.item(
            providerID: "provider-a",
            modelID: "failed-model"
        ))
        let healthy = try #require(projection.item(
            providerID: "provider-a",
            modelID: "healthy-model"
        ))
        #expect(failed.isBlocked)
        #expect(failed.isActionable)
        #expect(failed.isSelectable == false)
        #expect(healthy.readinessState == .mock)
        #expect(healthy.isSelectable)
        #expect(projection.blockedItems.map(\.id) == ["provider-a/failed-model"])
        #expect(projection.actionableItems.map(\.id) == ["provider-a/failed-model"])
    }

    @Test("equal timestamp observations accept the latest revision")
    func equalTimestampAcceptsLatestRevision() throws {
        let first = record(
            providerID: "provider",
            modelID: "model",
            status: .unavailable,
            readinessState: .blocked,
            errorCategory: .timeout,
            evidenceID: nil,
            checkedAt: checkedAt,
            isApplied: true
        )
        let sameTimestamp = record(
            providerID: "provider",
            modelID: "model",
            status: .passed,
            readinessState: .mock,
            evidenceID: "newer-looking-evidence",
            checkedAt: checkedAt,
            isApplied: true
        )

        let projection = ChatModelPickerProjection(records: [first, sameTimestamp])
        let item = try #require(projection.item(providerID: "provider", modelID: "model"))
        #expect(item.status == .passed)
        #expect(item.readinessState == .mock)
        #expect(item.evidenceID == "newer-looking-evidence")
        #expect(item.isSelectable)
    }

    @Test("duplicate provider identities fail closed independent of input order")
    func duplicateProviderIdentitiesFailClosed() throws {
        let first = record(
            providerID: "Provider",
            modelID: "model",
            status: .passed,
            readinessState: .live,
            evidenceID: liveEvidence,
            checkedAt: checkedAt,
            isApplied: true
        )
        let conflicting = record(
            providerID: "provider",
            modelID: "model",
            status: .unavailable,
            readinessState: .blocked,
            errorCategory: .timeout,
            evidenceID: nil,
            checkedAt: checkedAt,
            isApplied: true
        )

        let forward = ChatModelPickerProjection(records: [first, conflicting])
        let reverse = ChatModelPickerProjection(records: [conflicting, first])
        let forwardItem = try #require(forward.item(providerID: "PROVIDER", modelID: "model"))
        let reverseItem = try #require(reverse.item(providerID: "provider", modelID: "model"))

        #expect(forwardItem.id == reverseItem.id)
        #expect(forwardItem.readinessState == .unverified)
        #expect(reverseItem.readinessState == .unverified)
        #expect(forwardItem.isSelectable == false)
        #expect(reverseItem.isSelectable == false)

        let encodedCanonical = try JSONEncoder().encode(conflicting)
        let canonicalJSON = try #require(String(data: encodedCanonical, encoding: .utf8))
        let encodedVariant = try #require(
            canonicalJSON.replacingOccurrences(
                of: "\"providerID\":\"provider\"",
                with: "\"providerID\":\"Provider\""
            ).data(using: .utf8)
        )
        #expect(encodedVariant != encodedCanonical)
        let decodedVariant = try JSONDecoder().decode(
            ProviderReadinessPersistenceRecord.self,
            from: encodedVariant
        )
        let decodedCanonical = try JSONDecoder().decode(
            ProviderReadinessPersistenceRecord.self,
            from: encodedCanonical
        )
        let decodedProjection = ChatModelPickerProjection(
            records: [decodedVariant, decodedCanonical]
        )
        let decodedItem = try #require(decodedProjection.item(
            providerID: "provider",
            modelID: "model"
        ))
        #expect(decodedItem.readinessState == .unverified)
        #expect(decodedItem.isSelectable == false)
    }

    @Test("configuration identity drift cannot select a stale row")
    func configurationIdentityDriftFailsClosed() throws {
        let oldGeneration = record(
            providerID: "provider",
            modelID: "model",
            status: .passed,
            readinessState: .live,
            evidenceID: liveEvidence,
            checkedAt: checkedAt,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1"
        )
        let reboundGeneration = record(
            providerID: "provider",
            modelID: "model",
            status: .passed,
            readinessState: .live,
            evidenceID: liveEvidence,
            checkedAt: checkedAt.addingTimeInterval(1),
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2"
        )

        let projection = ChatModelPickerProjection(records: [
            oldGeneration,
            reboundGeneration
        ])
        let item = try #require(projection.item(
            providerID: "provider",
            modelID: "model"
        ))
        #expect(item.readinessState == .unverified)
        #expect(item.isSelectable == false)
        #expect(item.evidenceID == nil)
    }

    @Test("applied but never checked models are flagged unchecked without becoming ready")
    func appliedUncheckedModelIsNotReadyEvidence() {
        let projection = ChatModelPickerProjection(records: [
            record(providerID: "p", modelID: "never", status: .discovered,
                   readinessState: .unverified, evidenceID: nil),
            record(providerID: "p", modelID: "failed", status: .unavailable,
                   readinessState: .blocked, errorCategory: .unauthorized, evidenceID: nil),
            record(providerID: "p", modelID: "ok", status: .passed,
                   readinessState: .mock, evidenceID: "fixture"),
            record(providerID: "p", modelID: "pending", status: .discovered,
                   readinessState: .unverified, evidenceID: nil, isApplied: false)
        ])
        let never = projection.item(providerID: "p", modelID: "never")
        #expect(never?.isUncheckedApplied == true)
        #expect(never?.isSelectable == false)
        #expect(projection.item(providerID: "p", modelID: "failed")?.isUncheckedApplied == false)
        #expect(projection.item(providerID: "p", modelID: "ok")?.isUncheckedApplied == false)
        #expect(projection.item(providerID: "p", modelID: "pending")?.isUncheckedApplied == false)
    }

    @Test("only transient failure categories keep earlier passed evidence")
    func transientCategoriesAreRetryableNotBlocking() {
        let transient: [ProviderReadinessFailureCategory] = [.timeout, .rateLimited, .server, .unavailable, .transport]
        for category in transient { #expect(category.isTransient) }
        for category in ProviderReadinessFailureCategory.allCases where !transient.contains(category) {
            #expect(!category.isTransient, "\(category) must stay blocking")
        }
    }

    private func record(
        providerID: String,
        modelID: String,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        evidenceID: String?,
        checkedAt: Date? = nil,
        isApplied: Bool = true,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration,
        configurationFingerprint: String? = nil
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration,
            status: status,
            readinessState: readinessState,
            checkedAt: checkedAt ?? self.checkedAt,
            errorCategory: errorCategory,
            latency: 100,
            evidenceID: evidenceID,
            isApplied: isApplied,
            configurationFingerprint: configurationFingerprint
        )
    }
}
