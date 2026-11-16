import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness cache scope")
struct ProviderReadinessCacheTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)

    @Test("cache lookup requires provider, model, and credential version")
    func lookupUsesExactCredentialScope() {
        var index = ProviderReadinessCacheIndex()
        let inserted = index.upsert(
            makeRecord(providerID: "provider-a", modelID: "model-a"),
            credentialVersion: "credential-v1"
        )
        #expect(inserted)

        #expect(index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1"
        ) != nil)
        #expect(index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v2"
        ) == nil)
        #expect(index.record(
            providerID: "provider-a",
            modelID: "model-b",
            credentialVersion: "credential-v1"
        ) == nil)
        #expect(index.record(
            providerID: "provider-b",
            modelID: "model-a",
            credentialVersion: "credential-v1"
        ) == nil)
    }

    @Test("successor rebind invalidates only one provider's old versions")
    func successorRebindDoesNotPolluteOtherProviders() throws {
        var index = ProviderReadinessCacheIndex(entries: [
            entry(providerID: "provider-a", modelID: "model-a", version: "old-a"),
            entry(providerID: "provider-a", modelID: "model-b", version: "old-a"),
            entry(providerID: "provider-a", modelID: "model-a", version: "new-a"),
            entry(providerID: "provider-b", modelID: "model-a", version: "old-b")
        ])

        #expect(index.invalidateForSuccessorRebind(
            providerID: "provider-a",
            newCredentialVersion: "new-a"
        ) == 2)
        #expect(index.record(
            providerID: "provider-a", modelID: "model-a", credentialVersion: "old-a"
        ) == nil)
        #expect(index.record(
            providerID: "provider-a", modelID: "model-b", credentialVersion: "old-a"
        ) == nil)
        #expect(index.record(
            providerID: "provider-a", modelID: "model-a", credentialVersion: "new-a"
        ) != nil)
        #expect(index.record(
            providerID: "provider-b", modelID: "model-a", credentialVersion: "old-b"
        ) != nil)
    }

    @Test("cache index round-trips scopes without secrets")
    func cacheIndexRoundTripIsSecretFree() throws {
        let secretLike = "credential-version-sha256"
        let original = ProviderReadinessCacheIndex(entries: [
            entry(providerID: "provider-a", modelID: "model-a", version: secretLike)
        ])
        let data = try JSONEncoder().encode(original)
        let json = String(decoding: data, as: UTF8.self)
        let restored = try JSONDecoder().decode(
            ProviderReadinessCacheIndex.self,
            from: data
        )

        #expect(restored == original)
        #expect(json.contains("apiKey") == false)
        #expect(json.contains("sk-") == false)
        #expect(restored.entries.first?.key.credentialVersion == secretLike)
    }

    @Test("invalid cache scopes are rejected without creating a broad entry")
    func invalidScopeDoesNotEnterIndex() {
        var index = ProviderReadinessCacheIndex()
        let inserted = index.upsert(
            makeRecord(providerID: "provider-a", modelID: "model-a"),
            credentialVersion: "   "
        )
        #expect(inserted == false)
        #expect(index.entries.isEmpty)
    }

    @Test("expired cache facts downgrade instead of reusing green")
    func expiredFactBecomesUnverified() {
        let now = checkedAt
        var index = ProviderReadinessCacheIndex()
        let record = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: now.addingTimeInterval(-1)
        )
        let inserted = index.upsert(record, credentialVersion: "credential-v1")
        #expect(inserted)

        let result = index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1",
            now: now
        )
        #expect(result?.status == .unverified)
        #expect(result?.readinessState == .unverified)
        #expect(result?.evidenceID == nil)
    }

    @Test("configuration drift downgrades the cached fact")
    func configurationDriftBecomesUnverified() {
        let now = checkedAt
        let record = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: now.addingTimeInterval(60)
        )
        var index = ProviderReadinessCacheIndex()
        let inserted = index.upsert(
            record,
            credentialVersion: "credential-v1"
        )
        #expect(inserted)

        let result = index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v2",
            now: now
        )
        #expect(result?.readinessState == .unverified)
        #expect(result?.status == .unverified)
    }

    @Test("configuration generation mismatch cannot satisfy a cache lookup")
    func configurationGenerationIsPartOfCacheScope() {
        let record = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationGeneration: "generation-2",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "generation-2",
            isApplied: true,
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        var index = ProviderReadinessCacheIndex()
        let accepted = index.upsert(record, credentialVersion: "credential-v1")
        #expect(accepted)

        #expect(index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1",
            now: checkedAt,
            configurationGeneration: "generation-1"
        ) == nil)
        #expect(index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1",
            now: checkedAt,
            configurationGeneration: "generation-2"
        )?.status == .passed)
    }

    @Test("corrupt cache identity downgrades instead of escaping its scope")
    func corruptIdentityBecomesUnverified() {
        let now = checkedAt
        let key = ProviderReadinessCacheKey(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1"
        )
        let corruptRecord = makeRecord(
            providerID: "provider-b",
            modelID: "model-b",
            configurationFingerprint: "config-v1",
            expiresAt: now.addingTimeInterval(60)
        )
        let index = ProviderReadinessCacheIndex(entries: [
            ProviderReadinessCacheEntry(key: key, record: corruptRecord)
        ])

        let result = index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1",
            now: now
        )
        #expect(result?.status == .unverified)
        #expect(result?.readinessState == .unverified)
    }

    @Test("persistence consumer rejects missing expiry and preserves identity")
    func persistenceValidationFailsClosed() {
        let record = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1"
        )
        let result = record.validatedForCache(
            configurationFingerprint: "config-v1",
            now: checkedAt
        )
        #expect(result.status == .unverified)
        #expect(result.readinessState == .unverified)
        #expect(result.providerID == "provider-a")
        #expect(result.modelID == "model-a")
        #expect(result.configurationFingerprint == "config-v1")
    }

    @Test("late transport records cannot replace a newer cache revision")
    func lateRecordCannotReplaceNewerRevision() {
        var index = ProviderReadinessCacheIndex()
        let newer = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let older = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(-1),
            evidenceID: "late",
            isApplied: true,
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )

        let newerAccepted = index.upsert(newer, credentialVersion: "credential-v1")
        #expect(newerAccepted)
        let olderAccepted = index.upsert(older, credentialVersion: "credential-v1")
        #expect(olderAccepted == false)
        #expect(index.entries.first?.record.evidenceID == newer.evidenceID)
    }

    @Test("equal timestamp cache conflicts are rejected")
    func equalTimestampConflictIsRejected() {
        var index = ProviderReadinessCacheIndex()
        let first = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let conflict = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: true,
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )

        let firstAccepted = index.upsert(first, credentialVersion: "credential-v1")
        #expect(firstAccepted)
        let conflictAccepted = index.upsert(conflict, credentialVersion: "credential-v1")
        #expect(conflictAccepted == false)
        #expect(index.entries.first?.record.status == .passed)
    }

    @Test("clock rollback downgrades a future cache fact")
    func clockRollbackFailsClosed() {
        let record = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let index = ProviderReadinessCacheIndex(entries: [
            ProviderReadinessCacheEntry(
                key: ProviderReadinessCacheKey(
                    providerID: "provider-a",
                    modelID: "model-a",
                    credentialVersion: "credential-v1",
                    configurationFingerprint: "config-v1"
                ),
                record: record
            )
        ])

        let result = index.record(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1",
            now: checkedAt.addingTimeInterval(-1)
        )
        #expect(result?.status == .unverified)
        #expect(result?.evidenceID == nil)
    }

    @Test("duplicate cache entries downgrade deterministically")
    func duplicateEntriesFailClosed() {
        let passed = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let blocked = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: true,
            configurationFingerprint: "config-v1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let key = ProviderReadinessCacheKey(
            providerID: "provider-a",
            modelID: "model-a",
            credentialVersion: "credential-v1",
            configurationFingerprint: "config-v1"
        )

        let index = ProviderReadinessCacheIndex(entries: [
            ProviderReadinessCacheEntry(key: key, record: passed),
            ProviderReadinessCacheEntry(key: key, record: blocked)
        ])
        #expect(index.entries.count == 1)
        #expect(index.entries.first?.record.readinessState == .unverified)
        #expect(index.entries.first?.record.evidenceID == nil)
    }

    private func entry(
        providerID: String,
        modelID: String,
        version: String
    ) -> ProviderReadinessCacheEntry {
        ProviderReadinessCacheEntry(
            key: ProviderReadinessCacheKey(
                providerID: providerID,
                modelID: modelID,
                credentialVersion: version
            ),
            record: makeRecord(providerID: providerID, modelID: modelID)
        )
    }

    private func makeRecord(
        providerID: String,
        modelID: String,
        configurationFingerprint: String? = nil,
        expiresAt: Date? = nil
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "evidence-\(providerID)-\(modelID)",
            isApplied: true,
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        )
    }
}
