import CryptoKit
import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness persistence")
struct ProviderReadinessPersistenceTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)

    @Test("highest-generation complete histories agree in full")
    func highestGenerationHistoriesAgreeInFull() {
        let firstID = "00000000-0000-4000-8000-000000000001"
        let secondID = "00000000-0000-4000-8000-000000000002"
        let expected = [firstID, secondID]
        let observations: [(generation: UInt64?, value: [String]?)] = [
            (generation: 8, value: expected),
            (generation: 8, value: expected),
            (generation: 7, value: [secondID]),
        ]

        #expect(
            ProviderReadinessStore.agreedHighestGenerationValue(observations)
                == expected
        )
    }

    @Test("different highest-generation complete histories do not agree")
    func highestGenerationHistoriesRejectDisagreement() {
        let firstID = "00000000-0000-4000-8000-000000000001"
        let secondID = "00000000-0000-4000-8000-000000000002"
        let thirdID = "00000000-0000-4000-8000-000000000003"
        let observations: [(generation: UInt64?, value: [String]?)] = [
            (generation: 8, value: [firstID, secondID]),
            (generation: 8, value: [firstID, thirdID]),
        ]

        #expect(
            ProviderReadinessStore.agreedHighestGenerationValue(observations)
                == nil
        )
    }

    @Test("highest-generation history agreement preserves entry order")
    func highestGenerationHistoriesRejectOrderMismatch() {
        let firstID = "00000000-0000-4000-8000-000000000001"
        let secondID = "00000000-0000-4000-8000-000000000002"
        let observations: [(generation: UInt64?, value: [String]?)] = [
            (generation: 8, value: [firstID, secondID]),
            (generation: 8, value: [secondID, firstID]),
        ]

        #expect(
            ProviderReadinessStore.agreedHighestGenerationValue(observations)
                == nil
        )
    }

    @Test("missing highest-generation histories remain ambiguous")
    func highestGenerationHistoriesRejectEmptyOrNilObservations() {
        let empty: [(generation: UInt64?, value: [String]?)] = []
        let nilOnly: [(generation: UInt64?, value: [String]?)] = [
            (generation: 8, value: nil),
            (generation: nil, value: ["00000000-0000-4000-8000-000000000001"]),
        ]

        #expect(ProviderReadinessStore.agreedHighestGenerationValue(empty) == nil)
        #expect(ProviderReadinessStore.agreedHighestGenerationValue(nilOnly) == nil)
    }

    @Test("records round-trip with only redacted readiness facts")
    func recordRoundTripDoesNotPersistSecrets() throws {
        let record = ProviderReadinessPersistenceRecord(
            providerID: "luna apiKey=sk-provider-secret-123456",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .mock,
            checkedAt: checkedAt,
            errorCategory: nil,
            latency: 42,
            evidenceID: "apiKey=sk-provider-secret-123456 mock-evidence-42",
            isApplied: true
        )

        let data = try JSONEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        let restored = try JSONDecoder().decode(
            ProviderReadinessPersistenceRecord.self,
            from: data
        )

        #expect(restored == record)
        #expect(json.contains("apiKey") == false)
        #expect(json.contains("sk-provider-secret-123456") == false)
        #expect(json.contains("Authorization") == false)
        #expect(json.contains("mock-evidence-42"))
    }

    @Test("decoding persisted records re-applies secret redaction")
    func decodingCannotReintroduceSecrets() throws {
        let secret = "sk-decoded-provider-secret-1234"
        let data = Data(
            """
            {
              "providerID": "luna apiKey=\(secret)",
              "modelID": "gpt-5.6-luna",
              "status": "passed",
              "readinessState": "mock",
              "checkedAt": 1787200000,
              "errorCategory": null,
              "latency": -4,
              "evidenceID": "Bearer \(secret)",
              "isApplied": true
            }
            """.utf8
        )

        let record = try JSONDecoder().decode(
            ProviderReadinessPersistenceRecord.self,
            from: data
        )
        let json = String(
            decoding: try JSONEncoder().encode(record),
            as: UTF8.self
        )

        #expect(record.providerID.contains(secret) == false)
        #expect((record.evidenceID?.contains(secret) ?? false) == false)
        #expect(record.latency == 0)
        #expect(json.contains(secret) == false)
    }

    @Test("report mapping persists model outcomes without promoting mock to live")
    func reportMappingIsSecretFreeAndPerModel() async {
        let request = ProviderReadinessCheckRequest(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            deployment: .mock,
            baseURL: "https://mock.invalid/v1",
            credential: .present(source: "fixture"),
            evidenceID: "mock-report-evidence",
            checkedAt: checkedAt
        )
        let transport = MockProviderReadinessTransport(
            script: .init(
                modelCatalog: .success([
                    ProviderReadinessModel(id: "gpt-5.6-luna"),
                    ProviderReadinessModel(id: "gpt-5.6-luna-mini")
                ]),
                minimumRequests: [
                    "gpt-5.6-luna-mini": .failure(.permissionDenied)
                ]
            )
        )
        let report = await ProviderReadinessContractProbe(
            request: request,
            transport: transport
        ).check()

        let records = ProviderReadinessPersistenceRecord.records(
            from: report,
            latency: 17,
            appliedModelIDs: ["gpt-5.6-luna"]
        )
        let passed = records.first { $0.modelID == "gpt-5.6-luna" }
        let failed = records.first { $0.modelID == "gpt-5.6-luna-mini" }

        #expect(passed?.status == .passed)
        #expect(passed?.readinessState == .mock)
        #expect(passed?.isApplied == true)
        #expect(passed?.latency == 17)
        #expect(passed?.evidenceID == "mock-report-evidence")
        #expect(failed?.status == .unavailable)
        #expect(failed?.errorCategory == .permissionDenied)
        #expect(failed?.evidenceID == nil)
    }

    @Test("store persists records and ignores older observations")
    func storePersistsNewestObservation() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)

        let newest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "live-evidence",
            isApplied: true
        )
        let older = makeRecord(
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: false
        )

        store.upsert(newest)
        store.upsert(older)

        let reloaded = ProviderReadinessStore(directory: directory)
        #expect(reloaded.records == [newest])
        #expect(reloaded.records[0].errorCategory == nil)
        #expect(reloaded.records[0].latency == newest.latency)
    }

    @Test("stale store instance cannot replace a newer snapshot")
    func staleStoreInstanceFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let firstStore = ProviderReadinessStore(directory: directory)
        let staleStore = ProviderReadinessStore(directory: directory)

        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "first-writer"
        )
        let stale = makeRecord(
            modelID: "gpt-5.6-luna-mini",
            status: .passed,
            readinessState: .live,
            evidenceID: "stale-writer"
        )

        #expect(firstStore.upsert([first]))
        #expect(staleStore.upsert([stale]) == false)
        #expect(ProviderReadinessStore(directory: directory).records == [first])
    }

    @Test("persistence lock is a private single-link regular file")
    func persistenceLockHasPrivateIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "lock-identity"
        )]))

        let lockURL = directory.appendingPathComponent(
            "\(ProviderReadinessStore.fileName).lock"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: lockURL.path
        )
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.referenceCount] as? NSNumber)?.intValue == 1)
    }

    @Test("atomic snapshot target is private and single-link")
    func snapshotTargetHasPrivateIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "target-identity"
        )]))

        let snapshotURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: snapshotURL.path
        )
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.referenceCount] as? NSNumber)?.intValue == 1)
    }

    @Test("symlinked journal artifact fails closed and preserves bytes")
    func symlinkedJournalArtifactIsRejected() throws {
        let pair = try makeCommittedPair(evidenceID: "symlink-journal")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let journalBackupURL = pair.directory.appendingPathComponent(
            "journal-original.json"
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try FileManager.default.moveItem(at: journalURL, to: journalBackupURL)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: primaryURL
        )

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalBackupURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: journalURL.path
        ) == primaryURL.path)
    }

    @Test("hardlinked marker artifact fails closed and preserves bytes")
    func hardlinkedMarkerArtifactIsRejected() throws {
        let pair = try makeCommittedPair(evidenceID: "hardlink-marker")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let markerBackupURL = pair.directory.appendingPathComponent(
            "marker-original.json"
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try FileManager.default.moveItem(at: markerURL, to: markerBackupURL)
        try FileManager.default.linkItem(at: markerBackupURL, to: markerURL)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerBackupURL) == markerData)
        #expect(try Data(contentsOf: markerURL) == markerData)
        let markerAttributes = try FileManager.default.attributesOfItem(
            atPath: markerURL.path
        )
        #expect((markerAttributes[.referenceCount] as? NSNumber)?.intValue == 2)
    }

    @Test("symlinked primary artifact recovers only pending journal evidence")
    func symlinkedPrimaryArtifactRecoversPendingWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "symlink-primary")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryBackupURL = pair.directory.appendingPathComponent(
            "primary-original.json"
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try FileManager.default.moveItem(at: primaryURL, to: primaryBackupURL)
        try FileManager.default.createSymbolicLink(
            at: primaryURL,
            withDestinationURL: journalURL
        )

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryBackupURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: primaryURL.path
        ) == journalURL.path)
    }

    @Test("hardlinked primary artifact recovers only pending journal evidence")
    func hardlinkedPrimaryArtifactRecoversPendingWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "hardlink-primary")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryBackupURL = pair.directory.appendingPathComponent(
            "primary-original.json"
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try FileManager.default.moveItem(at: primaryURL, to: primaryBackupURL)
        try FileManager.default.linkItem(at: primaryBackupURL, to: primaryURL)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryBackupURL) == primaryData)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
        let primaryAttributes = try FileManager.default.attributesOfItem(
            atPath: primaryURL.path
        )
        #expect((primaryAttributes[.referenceCount] as? NSNumber)?.intValue == 2)
    }

    @Test("inode replacement before commit fails without changing artifacts")
    func inodeReplacementIsRejectedBeforeAnyArtifactWrite() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "inode-before"
        )
        #expect(store.upsert([first]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        let replacementURL = directory.appendingPathComponent(
            "primary-replacement.json"
        )
        try primaryData.write(to: replacementURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(
            primaryURL,
            withItemAt: replacementURL
        )

        let fresh = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "inode-after"
        )
        #expect(store.upsert([fresh]) == false)
        let pending = try #require(store.records.first)
        #expect(store.records.count == 1)
        #expect(pending.checkedAt == first.checkedAt)
        #expect(pending.discoveryReceiptID == first.discoveryReceiptID)
        #expect(pending.status == .unverified)
        #expect(pending.readinessState == .unverified)
        #expect(pending.isApplied == false)
        #expect(pending.evidenceID == nil)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("conflicting duplicate identities in one batch fail closed")
    func conflictingDuplicateBatchIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let passed = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "passed",
            isApplied: true
        )
        let blocked = makeRecord(
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: true
        )

        #expect(store.upsert([passed, blocked]) == false)
        #expect(store.records.isEmpty)
    }

    @Test("canonical provider and model aliases cannot create duplicate durable identities")
    func canonicalAliasesShareOneDurableKey() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            providerID: " Provider-A ",
            modelID: " model-a ",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "first",
            isApplied: true
        )
        let second = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: true
        )

        #expect(store.upsert([first, second]) == false)
        #expect(store.records.isEmpty)
    }

    @Test("provider identity remains canonical across persistence reload")
    func providerIdentityCanonicalizationSurvivesReload() throws {
        let directory = try makeTemporaryDirectory()
        let first = makeRecord(
            providerID: "  Provider-A  ",
            modelID: "  model-a  ",
            status: .passed,
            readinessState: .live,
            evidenceID: "canonical-provider",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([first]))
        #expect(store.records.first?.providerID == "provider-a")
        #expect(store.records.first?.modelID == "model-a")

        let reloaded = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        let record = try #require(reloaded.record(
            providerID: "PROVIDER-A",
            modelID: "model-a",
            configurationFingerprint: "fingerprint-2",
            now: checkedAt,
            configurationGeneration: "generation-2"
        ))
        #expect(record.providerID == "provider-a")
        #expect(record.modelID == "model-a")
        #expect(record.status == .passed)
        #expect(record.isApplied)
    }

    @Test("non-finite durable timestamps are rejected before persistence")
    func nonFiniteRecordIsInvalid() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let invalid = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            evidenceID: "must-not-persist",
            isApplied: true,
            discoveredAt: Date(timeIntervalSinceReferenceDate: .infinity),
            expiresAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )

        #expect(store.upsert([invalid]) == false)
        #expect(store.records.isEmpty)
    }

    @Test("store load rejects duplicate and unknown persisted JSON keys")
    func strictPersistedJSONIsFailClosed() throws {
        let duplicateDirectory = try makeTemporaryDirectory()
        try Data(#"{"schemaVersion":1,"records":[],"records":[]}"#.utf8)
            .write(
                to: duplicateDirectory.appendingPathComponent(
                    ProviderReadinessStore.fileName
                )
            )
        let duplicateStore = ProviderReadinessStore(directory: duplicateDirectory)
        #expect(duplicateStore.recoveryState == .quarantinedCorrupt)

        let unknownDirectory = try makeTemporaryDirectory()
        try Data(
            #"{"schemaVersion":1,"records":[{"providerID":"provider-a","modelID":"model-a","status":"passed","readinessState":"live","checkedAt":1787200000,"isApplied":true,"unexpected":true}]}"#.utf8
        ).write(
            to: unknownDirectory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
        )
        let unknownStore = ProviderReadinessStore(directory: unknownDirectory)
        #expect(unknownStore.recoveryState == .quarantinedCorrupt)
    }

    @Test("legacy snapshots cannot revive an enabled configured ready picker row")
    func legacySnapshotIsVisibleOnlyAsUnverifiedPending() throws {
        let directory = try makeTemporaryDirectory()
        let legacySnapshot = Data(
            """
            {
              "schemaVersion": 1,
              "records": [{
                "providerID": "provider-a",
                "modelID": "model-a",
                "status": "passed",
                "readinessState": "live",
                "checkedAt": 1787200000,
                "errorCategory": null,
                "latency": 42,
                "evidenceID": "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "isApplied": true,
                "discoveryReceiptID": "discover:legacy",
                "discoveredAt": 1787200000,
                "applyReceiptID": "apply:legacy",
                "appliedAt": 1787200001
              }]
            }
            """.utf8
        )
        try legacySnapshot.write(
            to: directory.appendingPathComponent(ProviderReadinessStore.fileName),
            options: .atomic
        )

        let store = ProviderReadinessStore(directory: directory)
        let projection = ChatModelPickerProjection(records: store.records)
        let item = try #require(projection.pending.first)

        #expect(store.recoveryState == .loaded(recordCount: 1))
        #expect(item.status == .unverified)
        #expect(item.readinessState == .unverified)
        #expect(item.isApplied == false)
        #expect(item.isEnabled == false)
        #expect(item.isConfigured == false)
        #expect(item.selectionTruth.isReady == false)
        #expect(item.selectionTruth.isActionable == false)
        #expect(projection.items.isEmpty)
    }

    @Test("missing apply authority cannot revive a persisted actionable row")
    func missingApplyAuthorityIsPendingAfterReload() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let record = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "missing-apply-authority",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        #expect(store.upsert([record]))

        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        var rawRecords = try #require(primaryObject["records"] as? [Any])
        var firstRecord = try #require(rawRecords[0] as? [String: Any])
        firstRecord.removeValue(forKey: "applyReceiptID")
        firstRecord.removeValue(forKey: "appliedAt")
        rawRecords[0] = firstRecord
        primaryObject["records"] = rawRecords
        let mutatedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try mutatedPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(
            recovered.recoveryState
                == .recoveredCommittedSnapshot(recordCount: 1)
        )
        #expect(recovered.recoveryState.isUsable == false)
        let recoveredRecord = try #require(recovered.records.first)
        #expect(recoveredRecord.isApplied == false)
        #expect(recoveredRecord.applyReceiptID == nil)
        #expect(recoveredRecord.appliedAt == nil)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == mutatedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("apply authority cannot predate its discovery receipt")
    func invertedApplyTimelineIsPendingAfterDecode() throws {
        let record = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "inverted-apply-timeline",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(record)
            ) as? [String: Any]
        )
        object["appliedAt"] = checkedAt
            .addingTimeInterval(-1)
            .timeIntervalSinceReferenceDate
        let mutated = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(
            ProviderReadinessPersistenceRecord.self,
            from: mutated
        )
        #expect(restored.status == .passed)
        #expect(restored.readinessState == .live)
        #expect(restored.isApplied == false)
        #expect(restored.applyReceiptID == nil)
        #expect(restored.appliedAt == nil)
        let projection = ChatModelPickerProjection(records: [restored])
        #expect(projection.items.isEmpty)
        #expect(projection.pending.count == 1)
        #expect(projection.pending.first?.selectionTruth.isActionable == false)
    }

    @Test("persisted lineage receipts must be canonical")
    func noncanonicalLineageReceiptsAreRejected() throws {
        let record = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "noncanonical-lineage-receipt",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let encoded = try JSONEncoder().encode(record)
        let original = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for key in ["discoveryReceiptID", "applyReceiptID"] {
            var object = original
            let receipt = try #require(object[key] as? String)
            object[key] = " " + receipt + " "
            let mutated = try JSONSerialization.data(withJSONObject: object)
            var rejected = false
            do {
                _ = try JSONDecoder().decode(
                    ProviderReadinessPersistenceRecord.self,
                    from: mutated
                )
            } catch {
                rejected = true
            }
            #expect(rejected)
        }
    }

    @Test("runtime admission rejects an inverted applied lineage")
    func invertedAppliedLineageCannotBePersisted() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let record = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationGeneration: "generation-2",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            discoveryReceiptID: "discovery-receipt-a",
            discoveredAt: checkedAt,
            applyReceiptID: "apply-receipt-a",
            appliedAt: checkedAt.addingTimeInterval(-1),
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )

        #expect(store.upsert([record]) == false)
        #expect(store.records.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ProviderReadinessStore.fileName
                ).path
            ) == false
        )
    }

    @Test("truncated primary recovers the latest journal as typed pending")
    func truncatedPrimaryRecoversLastCommittedSnapshotFailClosed() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "journal-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "journal-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latest]))

        let snapshotURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let truncated = Data(#"{"schemaVersion":1,"records":["#.utf8)
        try truncated.write(to: snapshotURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        let record = try #require(recovered.records.first)
        #expect(record.checkedAt == latest.checkedAt)
        #expect(record.status == .unverified)
        #expect(record.readinessState == .unverified)
        #expect(record.isApplied == false)
        #expect(record.evidenceID == nil)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        let repeated = ProviderReadinessStore(directory: directory)
        #expect(repeated.recoveryState == recovered.recoveryState)
        #expect(repeated.records == recovered.records)
        #expect(try Data(contentsOf: snapshotURL) == truncated)
    }

    @Test("unknown primary schema recovers the latest journal as typed pending")
    func unknownPrimarySchemaRecoversLastCommittedSnapshotFailClosed() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "unknown-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "unknown-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latest]))

        let snapshotURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let unknownSchema = Data(
            #"{"schemaVersion":999,"records":[]}"#.utf8
        )
        try unknownSchema.write(to: snapshotURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        let record = try #require(recovered.records.first)
        #expect(record.checkedAt == latest.checkedAt)
        #expect(record.status == .unverified)
        #expect(record.readinessState == .unverified)
        #expect(record.isApplied == false)
        #expect(record.evidenceID == nil)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        let repeated = ProviderReadinessStore(directory: directory)
        #expect(repeated.recoveryState == recovered.recoveryState)
        #expect(repeated.records == recovered.records)
        #expect(try Data(contentsOf: snapshotURL) == unknownSchema)
    }

    @Test("matching primary and journal transaction identities load normally")
    func matchingPrimaryAndJournalRemainValidated() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "transaction-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "transaction-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latest]))
        let committedLatest = try #require(store.records.first)
        #expect(committedLatest.discoveryReceiptID == first.discoveryReceiptID)
        #expect(committedLatest.applyReceiptID == first.applyReceiptID)

        let reloaded = ProviderReadinessStore(directory: directory)
        #expect(reloaded.recoveryState == .loaded(recordCount: 1))
        #expect(reloaded.recoveryState.isUsable)
        #expect(reloaded.records == [committedLatest])
        #expect(ChatModelPickerProjection(records: reloaded.records).items.count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        ).path))
    }

    @Test("mismatched valid commit identities fail closed without timestamp choice")
    func mismatchedCommitIdentitiesAreNotSelectedByTimestamp() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: false
        )
        let latestGreen = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(30),
            evidenceID: "transaction-green",
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latestGreen]))

        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["transactionID"] = "00000000-0000-0000-0000-000000000099"
        try JSONSerialization.data(withJSONObject: markerObject).write(
            to: markerURL,
            options: .atomic
        )

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        let repeated = ProviderReadinessStore(directory: directory)
        #expect(repeated.recoveryState == .transactionIdentityMismatch)
        #expect(repeated.records.isEmpty)
        #expect(ChatModelPickerProjection(records: repeated.records).items.isEmpty)
    }

    @Test("mismatched predecessor seals block later writes without repair")
    func mismatchedPredecessorSealBlocksSuccessorWrite() throws {
        let pair = try makeCommittedPair(evidenceID: "predecessor-seal")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["previousDigest"] = String(repeating: "a", count: 64)
        let mismatchedMarker = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try mismatchedMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        #expect(recovered.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(60),
            evidenceID: "must-not-advance",
            isApplied: true
        )]) == false)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == mismatchedMarker)
    }

    @Test("payload mixing cannot revive a committed provider snapshot")
    func payloadDigestFencesCrossArtifactMixing() throws {
        let primaryPair = try makeCommittedPair(
            evidenceID: "payload-mixed-primary"
        )
        let primaryURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        primaryObject["records"] = []
        let mixedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try mixedPrimary.write(to: primaryURL, options: .atomic)

        let primaryRecovered = ProviderReadinessStore(directory: primaryPair.directory)
        #expect(primaryRecovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(primaryRecovered.recoveryState.isUsable == false)
        #expect(primaryRecovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: primaryRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == mixedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)

        let markerPair = try makeCommittedPair(
            evidenceID: "payload-mixed-marker"
        )
        let markerPrimaryURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let markerJournalURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerTargetURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerTargetURL)
            ) as? [String: Any]
        )
        markerObject["payloadDigest"] = "cross-artifact-digest"
        let mixedMarker = try JSONSerialization.data(withJSONObject: markerObject)
        let markerPrimaryData = try Data(contentsOf: markerPrimaryURL)
        let markerJournalData = try Data(contentsOf: markerJournalURL)
        try mixedMarker.write(to: markerTargetURL, options: .atomic)

        let markerRecovered = ProviderReadinessStore(directory: markerPair.directory)
        #expect(markerRecovered.recoveryState == .incompleteTransaction)
        #expect(markerRecovered.recoveryState.isUsable == false)
        #expect(markerRecovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: markerRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: markerPrimaryURL) == markerPrimaryData)
        #expect(try Data(contentsOf: markerJournalURL) == markerJournalData)
        #expect(try Data(contentsOf: markerTargetURL) == mixedMarker)
    }

    @Test("missing durable commit marker never publishes a half-committed pair")
    func missingCommitMarkerFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "marker-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "marker-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latest]))

        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        try FileManager.default.removeItem(at: markerURL)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        let repeated = ProviderReadinessStore(directory: directory)
        #expect(repeated.recoveryState == .incompleteTransaction)
        #expect(repeated.records.isEmpty)
        #expect(ChatModelPickerProjection(records: repeated.records).items.isEmpty)
    }

    @Test("prepared marker never publishes an interrupted three-artifact commit")
    func preparedCommitMarkerFailsClosedWithoutReplayingOrOverwriting() throws {
        let pair = try makeCommittedPair(
            evidenceID: "prepared-interrupted"
        )
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["state"] = "prepared"
        let preparedMarker = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try preparedMarker.write(to: markerURL, options: .atomic)

        func canonicalMigrationHistory(at url: URL) throws -> Data {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            let history = try #require(
                object["providerScopeMigrationHistory"] as? [[String: Any]]
            )
            return try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
        }
        let primaryHistory = try canonicalMigrationHistory(
            at: pair.directory.appendingPathComponent(ProviderReadinessStore.fileName)
        )
        let journalHistory = try canonicalMigrationHistory(
            at: pair.directory.appendingPathComponent(ProviderReadinessStore.journalFileName)
        )
        let markerHistory = try canonicalMigrationHistory(at: markerURL)
        #expect(primaryHistory == journalHistory)
        #expect(journalHistory == markerHistory)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == preparedMarker)

        // A second reload must not repair the pair, replay the old generation,
        // or overwrite a primary that may have been replaced after the crash.
        let repeated = ProviderReadinessStore(directory: pair.directory)
        #expect(repeated.recoveryState == .incompleteTransaction)
        #expect(repeated.records.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == preparedMarker)
    }

    @Test("fresh durable commit clears an interrupted recovery state")
    func freshCommitAfterPreparedMarkerRestoresLoadedState() throws {
        let pair = try makeCommittedPair(evidenceID: "prepared-retry")
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["state"] = "prepared"
        let preparedMarker = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try preparedMarker.write(to: markerURL, options: .atomic)

        var persistFailureCategory = "none"
        let store = ProviderReadinessStore(
            directory: pair.directory,
            onPersistError: { error in
                persistFailureCategory = ProviderReadinessStore
                    .persistenceDiagnosticStage(for: error)
            }
        )
        #expect(store.recoveryState == .incompleteTransaction)
        #expect(store.records.isEmpty)

        let fresh = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(60),
            evidenceID: "fresh-after-prepared",
            isApplied: true
        )
        #expect(
            store.upsert([fresh]),
            "persist-failure-category=\(persistFailureCategory)"
        )
        #expect(store.recoveryState == .loaded(recordCount: 1))
        #expect(store.records == [fresh])
        #expect(ChatModelPickerProjection(records: store.records).items.count == 1)

        let reloaded = ProviderReadinessStore(directory: pair.directory)
        #expect(reloaded.recoveryState == .loaded(recordCount: 1))
        #expect(reloaded.records == [fresh])
    }

    @Test("prepared successor marker retains the prior committed pair as pending")
    func preparedSuccessorMarkerRecoversPriorPairWithoutPromotion() throws {
        let pair = try makeCommittedPair(evidenceID: "prepared-successor")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: primaryData
            ) as? [String: Any]
        )
        let previousPayloadDigest = try #require(
            primaryObject["payloadDigest"] as? String
        )
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["transactionID"] = "00000000-0000-4000-8000-000000000099"
        markerObject["commitGeneration"] = 3
        markerObject["previousDigest"] = previousPayloadDigest
        markerObject["state"] = "prepared"
        let preparedSuccessor = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try preparedSuccessor.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        let record = try #require(recovered.records.first)
        #expect(record.checkedAt == pair.latest.checkedAt)
        #expect(record.status == .unverified)
        #expect(record.isApplied == false)
        #expect(record.evidenceID == nil)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == preparedSuccessor)

        let repeated = ProviderReadinessStore(directory: pair.directory)
        #expect(repeated.recoveryState == recovered.recoveryState)
        #expect(repeated.records == recovered.records)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == preparedSuccessor)
    }

    @Test("unknown commit marker state preserves all artifacts and fails closed")
    func unknownCommitMarkerStateFailsClosedWithoutRepair() throws {
        let pair = try makeCommittedPair(evidenceID: "marker-state-unknown")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["state"] = "future-state"
        let unknownMarker = try JSONSerialization.data(withJSONObject: markerObject)
        try unknownMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == unknownMarker)
    }

    @Test("missing commit marker state is not treated as committed")
    func missingCommitMarkerStateFailsClosedWithoutRepair() throws {
        let pair = try makeCommittedPair(evidenceID: "marker-state-missing")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject.removeValue(forKey: "state")
        let legacyMarker = try JSONSerialization.data(withJSONObject: markerObject)
        try legacyMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == legacyMarker)
    }

    @Test("oversized transaction artifacts fail closed without rewrite")
    func oversizedTransactionArtifactsPreserveBytes() throws {
        let cases: [(String, Int, ProviderReadinessStoreRecoveryState, Int)] = [
            (
                ProviderReadinessStore.fileName,
                4 * 1024 * 1024 + 1,
                .recoveredCommittedSnapshot(recordCount: 1),
                1
            ),
            (
                ProviderReadinessStore.journalFileName,
                4 * 1024 * 1024 + 1,
                .incompleteTransaction,
                0
            ),
            (
                ProviderReadinessStore.commitMarkerFileName,
                64 * 1024 + 1,
                .incompleteTransaction,
                0
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let pair = try makeCommittedPair(
                evidenceID: "oversized-transaction-\(index)"
            )
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            let targetURL = pair.directory.appendingPathComponent(testCase.0)
            let primaryData = try Data(contentsOf: primaryURL)
            let journalData = try Data(contentsOf: journalURL)
            let markerData = try Data(contentsOf: markerURL)
            let oversized = Data(repeating: 0x78, count: testCase.1)
            try oversized.write(to: targetURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == testCase.2)
            #expect(recovered.recoveryState.isUsable == false)
            #expect(recovered.records.count == testCase.3)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(
                ChatModelPickerProjection(records: recovered.records).pending.count
                    == testCase.3
            )
            #expect(try Data(contentsOf: targetURL) == oversized)
            #expect(try Data(contentsOf: primaryURL) == (
                testCase.0 == ProviderReadinessStore.fileName
                    ? oversized
                    : primaryData
            ))
            #expect(try Data(contentsOf: journalURL) == (
                testCase.0 == ProviderReadinessStore.journalFileName
                    ? oversized
                    : journalData
            ))
            #expect(try Data(contentsOf: markerURL) == (
                testCase.0 == ProviderReadinessStore.commitMarkerFileName
                    ? oversized
                    : markerData
            ))
        }
    }

    @Test("replayed old marker blocks a fresh transaction by generation CAS")
    func oldCommitMarkerCannotFenceNextGeneration() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "generation-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "generation-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let oldMarkerData = try Data(contentsOf: markerURL)
        #expect(store.upsert([latest]))
        try oldMarkerData.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.records.isEmpty)
        let primaryBeforeFresh = try Data(contentsOf: directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        ))
        let journalBeforeFresh = try Data(contentsOf: directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        ))
        let markerBeforeFresh = try Data(contentsOf: markerURL)

        let fresh = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(20),
            evidenceID: "generation-fresh",
            isApplied: true
        )
        #expect(recovered.upsert([fresh]) == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )) == primaryBeforeFresh)
        #expect(try Data(contentsOf: directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )) == journalBeforeFresh)
        #expect(try Data(contentsOf: markerURL) == markerBeforeFresh)
    }

    @Test("successor transaction links the prior digest and reloads idempotently")
    func successorCommitGenerationLinksPreviousDigest() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "chain-first"
        )]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let firstObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let firstTransactionID = try #require(
            firstObject["transactionID"] as? String
        )
        #expect(UUID(uuidString: firstTransactionID) != nil)
        let firstDigest = try #require(firstObject["payloadDigest"] as? String)
        #expect((firstObject["commitGeneration"] as? NSNumber)?.uint64Value == 1)
        #expect(firstObject["previousDigest"] as? String == nil)

        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "chain-successor"
        )]))
        let successorObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let successorTransactionID = try #require(
            successorObject["transactionID"] as? String
        )
        #expect(UUID(uuidString: successorTransactionID) != nil)
        #expect(successorTransactionID != firstTransactionID)
        #expect((successorObject["commitGeneration"] as? NSNumber)?.uint64Value == 2)
        #expect(successorObject["previousDigest"] as? String == firstDigest)

        let firstReload = ProviderReadinessStore(directory: directory)
        let secondReload = ProviderReadinessStore(directory: directory)
        #expect(firstReload.recoveryState == .loaded(recordCount: 1))
        #expect(firstReload.records == secondReload.records)
        #expect(firstReload.records.first?.evidenceID == "chain-successor")
    }

    @Test("successor scope seal binds provider configuration fingerprint")
    func providerScopeBindsConfigurationFingerprint() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "fingerprint-first",
            configurationFingerprint: "fingerprint-1"
        )]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let firstObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let firstScope = try #require(firstObject["providerScope"] as? String)

        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "fingerprint-successor",
            configurationFingerprint: "fingerprint-2"
        )]))
        let successorObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let successorScope = try #require(
            successorObject["providerScope"] as? String
        )
        #expect(successorScope != firstScope)
        #expect((successorObject["commitGeneration"] as? NSNumber)?.uint64Value == 2)

        let reloaded = ProviderReadinessStore(directory: directory)
        #expect(reloaded.recoveryState == .loaded(recordCount: 1))
        #expect(reloaded.records.first?.configurationFingerprint == "fingerprint-2")
    }

    @Test("versioned provider scope canonicalizes equivalent config identity")
    func equivalentProviderConfigReloadsWithStableScopeSeal() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            providerID: "  Provider-A  ",
            status: .passed,
            readinessState: .live,
            evidenceID: "canonical-config",
            configurationFingerprint: "  fingerprint-equivalent  "
        )]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let firstData = try Data(contentsOf: primaryURL)
        let firstObject = try #require(
            JSONSerialization.jsonObject(with: firstData) as? [String: Any]
        )
        let firstScope = try #require(firstObject["providerScope"] as? String)
        let firstVersion = try #require(
            firstObject["providerScopeVersion"] as? NSNumber
        )
        #expect(firstVersion.intValue == 1)
        #expect(firstObject["providerScopeMigrationReceipt"] as? String == "provider-scope-v1-native")
        #expect(firstObject["providerScopePreviousVersionDigest"] is NSNull)
        let migrationHistory = try #require(
            firstObject["providerScopeMigrationHistory"] as? [[String: Any]]
        )
        #expect(migrationHistory.count == 1)
        #expect(migrationHistory[0]["migrationID"] as? String == "00000000-0000-4000-8000-000000000001")
        #expect((migrationHistory[0]["fromVersion"] as? NSNumber)?.intValue == 0)
        #expect((migrationHistory[0]["toVersion"] as? NSNumber)?.intValue == 1)
        #expect(migrationHistory[0]["previousVersionDigest"] is NSNull)
        #expect((firstObject["providerScopeMigrationEpoch"] as? NSNumber)?.uint64Value == 1)
        #expect((firstObject["providerScopeMigrationCheckpoint"] as? String)?.count == 64)
        #expect(firstObject["providerScopeMigrationCleanupTombstone"] as? String == "provider-scope-v1-history-retained")
        #expect(firstObject["providerScopeMigrationPreviousRoot"] is NSNull)

        let reloaded = ProviderReadinessStore(directory: directory)
        #expect(reloaded.recoveryState == .loaded(recordCount: 1))
        #expect(reloaded.records.first?.providerID == "provider-a")
        #expect(reloaded.records.first?.configurationFingerprint == "fingerprint-equivalent")
        #expect(try Data(contentsOf: primaryURL) == firstData)

        let secondObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: primaryURL))
                as? [String: Any]
        )
        #expect(secondObject["providerScope"] as? String == firstScope)
    }

    @Test("provider scope migration metadata rejects downgrade and future versions without rewrite")
    func migrationVersionDriftFailsClosedWithoutRewrite() throws {
        for version in [0, 2] {
            let pair = try makeCommittedPair(
                evidenceID: "migration-version-\(version)"
            )
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            var primaryObject = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: primaryURL)
                ) as? [String: Any]
            )
            primaryObject["providerScopeVersion"] = version
            let driftedPrimary = try JSONSerialization.data(
                withJSONObject: primaryObject
            )
            let journalData = try Data(contentsOf: journalURL)
            let markerData = try Data(contentsOf: markerURL)
            try driftedPrimary.write(to: primaryURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
            #expect(recovered.recoveryState.isUsable == false)
            #expect(recovered.records.first?.isApplied == false)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == driftedPrimary)
            #expect(try Data(contentsOf: journalURL) == journalData)
            #expect(try Data(contentsOf: markerURL) == markerData)
        }
    }

    @Test("provider scope migration receipt substitution fails closed without rewrite")
    func migrationReceiptSubstitutionFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-receipt-substitution")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["providerScopeMigrationReceipt"] = "provider-scope-v2-future"
        markerObject["providerScopePreviousVersionDigest"] = String(repeating: "0", count: 64)
        let substitutedMarker = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try substitutedMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == substitutedMarker)
    }

    @Test("semantically equivalent provider config bytes preserve the migration seal")
    func equivalentConfigBytesPreserveMigrationSeal() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-semantic-equivalence")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let originalObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let rewrittenPrimary = try JSONSerialization.data(
            withJSONObject: originalObject,
            options: [.sortedKeys]
        )
        #expect(try rewrittenPrimary != Data(contentsOf: primaryURL))
        try rewrittenPrimary.write(to: primaryURL, options: .atomic)

        let reloaded = ProviderReadinessStore(directory: pair.directory)
        #expect(reloaded.recoveryState == .loaded(recordCount: 1))
        #expect(reloaded.records.first?.evidenceID == "migration-semantic-equivalence")
        #expect(try Data(contentsOf: primaryURL) == rewrittenPrimary)
    }

    @Test("migration crash leaves a mixed receipt pair pending and byte stable")
    func migrationCrashMixedReceiptFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-crash")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let markerData = try Data(contentsOf: markerURL)
        var journalObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: journalURL)
            ) as? [String: Any]
        )
        journalObject["providerScopePreviousVersionDigest"] = String(repeating: "f", count: 64)
        let migratedJournal = try JSONSerialization.data(
            withJSONObject: journalObject
        )
        try migratedJournal.write(to: journalURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == migratedJournal)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("bounded migration history rejects replay and multi-version substitutions")
    func migrationHistoryReplayFailsClosedWithoutRewrite() throws {
        for mutation in ["duplicate", "replayed", "future", "oversized"] {
            let pair = try makeCommittedPair(evidenceID: "migration-history-\(mutation)")
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            var primaryObject = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: primaryURL)
                ) as? [String: Any]
            )
            var history = try #require(
                primaryObject["providerScopeMigrationHistory"] as? [[String: Any]]
            )
            if mutation == "duplicate" {
                history.append(history[0])
            } else if mutation == "oversized" {
                for _ in 0..<8 {
                    history.append([
                        "migrationID": "00000000-0000-4000-8000-000000000002",
                        "fromVersion": 0,
                        "toVersion": 1,
                        "previousVersionDigest": NSNull(),
                    ])
                }
            } else if mutation == "replayed" {
                history[0]["fromVersion"] = 1
                history[0]["toVersion"] = 1
            } else {
                history[0]["toVersion"] = 2
            }
            primaryObject["providerScopeMigrationHistory"] = history
            let mutatedPrimary = try JSONSerialization.data(withJSONObject: primaryObject)
            let journalData = try Data(contentsOf: journalURL)
            let markerData = try Data(contentsOf: markerURL)
            try mutatedPrimary.write(to: primaryURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
            #expect(recovered.recoveryState.isUsable == false)
            #expect(recovered.records.first?.isApplied == false)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == mutatedPrimary)
            #expect(try Data(contentsOf: journalURL) == journalData)
            #expect(try Data(contentsOf: markerURL) == markerData)
        }
    }

    @Test("migration checkpoint substitution fails closed without rewriting siblings")
    func migrationCheckpointSubstitutionFailsClosedWithoutRewrite() throws {
        for mutation in ["checkpoint", "epoch", "tombstone", "previous-root", "previous-root-oversized"] {
            let pair = try makeCommittedPair(evidenceID: "migration-\(mutation)-substitution")
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            let primaryData = try Data(contentsOf: primaryURL)
            let journalData = try Data(contentsOf: journalURL)
            var markerObject = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: markerURL)
                ) as? [String: Any]
            )
            if mutation == "checkpoint" {
                markerObject["providerScopeMigrationCheckpoint"] = String(repeating: "a", count: 64)
            } else if mutation == "tombstone" {
                markerObject["providerScopeMigrationCleanupTombstone"] = "provider-scope-v0-cleaned"
            } else if mutation == "previous-root" {
                markerObject["providerScopeMigrationPreviousRoot"] = String(repeating: "b", count: 64)
            } else if mutation == "previous-root-oversized" {
                markerObject["providerScopeMigrationPreviousRoot"] = String(repeating: "c", count: 64 * 1024)
            } else {
                markerObject["providerScopeMigrationEpoch"] = 2
            }
            let substitutedMarker = try JSONSerialization.data(withJSONObject: markerObject)
            try substitutedMarker.write(to: markerURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == .incompleteTransaction)
            #expect(recovered.recoveryState.isUsable == false)
            #expect(recovered.records.isEmpty)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == primaryData)
            #expect(try Data(contentsOf: journalURL) == journalData)
            #expect(try Data(contentsOf: markerURL) == substitutedMarker)
        }
    }

    @Test("prepared migration history crash remains pending and byte stable")
    func preparedMigrationHistoryCrashFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-prepared-crash")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["state"] = "prepared"
        var history = try #require(
            markerObject["providerScopeMigrationHistory"] as? [[String: Any]]
        )
        history[0]["migrationID"] = "00000000-0000-4000-8000-000000000002"
        markerObject["providerScopeMigrationHistory"] = history
        let preparedMarker = try JSONSerialization.data(withJSONObject: markerObject)
        try preparedMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == preparedMarker)
    }

    @Test("old migration cleanup history cannot resurrect a provider snapshot")
    func oldMigrationCleanupResurrectionFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-cleanup-resurrection")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        primaryObject["providerScopeMigrationHistory"] = []
        primaryObject["providerScopeMigrationCheckpoint"] = String(repeating: "0", count: 64)
        primaryObject["providerScopeMigrationCleanupTombstone"] = "provider-scope-v0-cleaned"
        let resurrectedPrimary = try JSONSerialization.data(withJSONObject: primaryObject)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try resurrectedPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == resurrectedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("cross-epoch cleanup history cannot resurrect an old provider snapshot")
    func crossEpochCleanupHistoryResurrectionFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "migration-cross-epoch-resurrection")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        primaryObject["providerScopeMigrationEpoch"] = 2
        primaryObject["providerScopeMigrationPreviousRoot"] = String(repeating: "c", count: 64)
        primaryObject["providerScopeMigrationHistory"] = []
        primaryObject["providerScopeMigrationCheckpoint"] = String(repeating: "0", count: 64)
        primaryObject["providerScopeMigrationCleanupTombstone"] = "provider-scope-v1-compacted"
        let crossEpochPrimary = try JSONSerialization.data(withJSONObject: primaryObject)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try crossEpochPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == crossEpochPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)

        let repeated = ProviderReadinessStore(directory: pair.directory)
        #expect(repeated.recoveryState == recovered.recoveryState)
        #expect(repeated.records == recovered.records)
        #expect(try Data(contentsOf: primaryURL) == crossEpochPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("unknown provider projection field cannot substitute a committed payload")
    func unknownProviderProjectionFieldFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "unknown-config-projection")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        var records = try #require(primaryObject["records"] as? [[String: Any]])
        records[0]["unknownProjectionField"] = "substitute"
        primaryObject["records"] = records
        let substitutedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try substitutedPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == substitutedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("cross-scope committed marker cannot publish a provider snapshot")
    func crossScopeMarkerFailsClosedWithoutRepair() throws {
        let pair = try makeCommittedPair(evidenceID: "scope-binding")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        markerObject["providerScope"] = String(repeating: "0", count: 64)
        let crossScopeMarker = try JSONSerialization.data(withJSONObject: markerObject)
        try crossScopeMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == crossScopeMarker)
    }

    @Test("canonical payload replacement fails closed without repair")
    func payloadReplacementFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "payload-replacement")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        primaryObject["payloadDigest"] = String(repeating: "0", count: 64)
        let replacedPayload = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        try replacedPayload.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == replacedPayload)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)

        let repeated = ProviderReadinessStore(directory: pair.directory)
        #expect(repeated.recoveryState == recovered.recoveryState)
        #expect(repeated.records == recovered.records)
        #expect(try Data(contentsOf: primaryURL) == replacedPayload)
    }

    @Test("duplicate transaction UUID field fails closed without repair")
    func duplicateTransactionUUIDFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "duplicate-transaction-uuid")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        let markerObject = try #require(
            JSONSerialization.jsonObject(with: markerData) as? [String: Any]
        )
        let transactionID = try #require(markerObject["transactionID"] as? String)
        let markerString = try #require(
            String(data: markerData, encoding: .utf8)
        )
        let compactMarker = markerString.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let duplicateMarker = Data(
            (String(compactMarker.dropLast())
                + ",\"transactionID\":\"\(transactionID)\"}").utf8
        )
        try duplicateMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == duplicateMarker)
    }

    @Test("aggregate transaction size overflow preserves every artifact")
    func aggregateTransactionSizeFailsClosedWithoutRewrite() throws {
        let pair = try makeCommittedPair(evidenceID: "aggregate-size")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var oversizedPrimary = try Data(contentsOf: primaryURL)
        var oversizedJournal = try Data(contentsOf: journalURL)
        oversizedPrimary.append(Data(repeating: 0x20, count: 2_100_000))
        oversizedJournal.append(Data(repeating: 0x20, count: 2_100_000))
        let markerData = try Data(contentsOf: markerURL)
        try oversizedPrimary.write(to: primaryURL, options: .atomic)
        try oversizedJournal.write(to: journalURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == oversizedPrimary)
        #expect(try Data(contentsOf: journalURL) == oversizedJournal)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("stale predecessor candidate is rejected without selecting by timestamp")
    func stalePredecessorCandidateFailsClosedWithoutRewrite() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "chain-current-first"
        )]))
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let staleCurrentGeneration = try Data(contentsOf: journalURL)
        #expect(store.upsert([makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "chain-current-successor"
        )]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let markerData = try Data(contentsOf: markerURL)

        // The only recoverable two-candidate case is the immediate
        // successor pointing exactly at its predecessor digest.
        try staleCurrentGeneration.write(to: journalURL, options: .atomic)
        let successorRecovered = ProviderReadinessStore(directory: directory)
        #expect(successorRecovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(successorRecovered.records.first?.status == .unverified)
        #expect(successorRecovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: successorRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == staleCurrentGeneration)
        #expect(try Data(contentsOf: markerURL) == markerData)

        // A different generation-1 transaction is a stale predecessor even
        // though its timestamp and schema are otherwise valid.
        let otherDirectory = try makeTemporaryDirectory()
        let otherStore = ProviderReadinessStore(directory: otherDirectory)
        #expect(otherStore.upsert([makeRecord(
            providerID: "other-provider",
            status: .passed,
            readinessState: .live,
            evidenceID: "chain-stale-predecessor"
        )]))
        let staleJournal = try Data(contentsOf: otherDirectory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        ))
        try staleJournal.write(to: journalURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == staleJournal)
        #expect(try Data(contentsOf: markerURL) == markerData)
        #expect(staleCurrentGeneration != staleJournal)

        // A same-generation fork has no immediate predecessor relation and
        // must not win merely because its wall-clock data is newer.
        #expect(otherStore.upsert([makeRecord(
            providerID: "other-provider",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "chain-fork"
        )]))
        let forkJournal = try Data(contentsOf: otherDirectory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        ))
        try forkJournal.write(to: journalURL, options: .atomic)
        let forkRecovered = ProviderReadinessStore(directory: directory)
        #expect(forkRecovered.recoveryState == .transactionIdentityMismatch)
        #expect(forkRecovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: forkRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == forkJournal)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("corrupt commit marker preserves evidence but fails closed")
    func corruptCommitMarkerFailsClosedWithoutDiscardingPair() throws {
        let pair = try makeCommittedPair(
            evidenceID: "marker-corrupt-latest"
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        try Data(#"{"schemaVersion":1,"transactionID":"#.utf8)
            .write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
    }

    @Test("unknown commit marker schema preserves evidence but fails closed")
    func unknownCommitMarkerSchemaFailsClosedWithoutDiscardingPair() throws {
        let pair = try makeCommittedPair(
            evidenceID: "marker-unknown-latest"
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        try Data(
            #"{"schemaVersion":999,"transactionID":"transaction-unknown"}"#.utf8
        ).write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
    }

    @Test("no-primary incomplete artifacts cannot repair over corrupt evidence")
    func noPrimaryIncompleteArtifactsFailClosedWithoutRewrite() throws {
        let directory = try makeTemporaryDirectory()
        let legacyRecord = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "legacy-journal",
            isApplied: true
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let legacyObject: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "records": [
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(legacyRecord)
                )
            ]
        ]
        let legacyJournal = try JSONSerialization.data(withJSONObject: legacyObject)
        let corruptMarker = Data(
            #"{"schemaVersion":1,"transactionID":"corrupt"}"#.utf8
        )
        try legacyJournal.write(to: journalURL, options: .atomic)
        try corruptMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .incompleteTransaction)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)

        let fresh = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(30),
            evidenceID: "must-not-repair",
            isApplied: true
        )
        #expect(recovered.upsert([fresh]) == false)
        #expect(recovered.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: primaryURL.path))
        #expect(try Data(contentsOf: journalURL) == legacyJournal)
        #expect(try Data(contentsOf: markerURL) == corruptMarker)
    }

    @Test("replayed old commit marker cannot revive a validated pair")
    func replayedCommitMarkerFailsClosedWithoutDiscardingPair() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "marker-replay-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "marker-replay-latest",
            isApplied: true
        )
        #expect(store.upsert([first]))
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let oldMarkerData = try Data(contentsOf: markerURL)
        #expect(store.upsert([latest]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let primaryData = try Data(contentsOf: primaryURL)
        let journalData = try Data(contentsOf: journalURL)
        try oldMarkerData.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .transactionIdentityMismatch)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == oldMarkerData)
    }

    @Test("partial recovery persistence failure downgrades recovered records")
    func partialRecoveryPersistenceFailureDoesNotExposeActionableRecord() throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let validRecord = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "partial-valid",
            isApplied: true
        )
        let primaryObject: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "records": [
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(validRecord)
                ),
                ["providerID": "missing-required-fields"]
            ]
        ]
        let primaryData = try JSONSerialization.data(withJSONObject: primaryObject)
        try primaryData.write(to: primaryURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: primaryURL
        )

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .recoveredPartial(
            validRecordCount: 1,
            droppedRecordCount: 1
        ))
        #expect(recovered.records.count == 1)
        #expect(recovered.records[0].status == .unverified)
        #expect(recovered.records[0].readinessState == .unverified)
        #expect(recovered.records[0].isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: journalURL.path
        ) == primaryURL.path)
    }

    @Test("partial primary repair failure downgrades valid sibling evidence")
    func partialPrimaryRepairFailureDoesNotExposeActionableRecord() throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let validRecord = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "partial-primary-valid",
            isApplied: true
        )
        var invalidRecord = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(validRecord)
            ) as? [String: Any]
        )
        invalidRecord["providerID"] = ""
        let primaryObject: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "records": [
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(validRecord)
                ),
                invalidRecord
            ]
        ]
        let primaryData = try JSONSerialization.data(withJSONObject: primaryObject)
        try primaryData.write(to: primaryURL, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .recoveredPartial(
            validRecordCount: 1,
            droppedRecordCount: 1
        ))
        #expect(recovered.records.count == 1)
        #expect(recovered.records[0].status == .unverified)
        #expect(recovered.records[0].readinessState == .unverified)
        #expect(recovered.records[0].isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == primaryData)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("generation without transaction identity is quarantined")
    func generationWithoutTransactionIdentityFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let record = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "orphan-generation",
            isApplied: true
        )
        let object: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "transactionID": NSNull(),
            "commitGeneration": 1,
            "records": [
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(record)
                )
            ]
        ]
        let originalData = try JSONSerialization.data(withJSONObject: object)
        try originalData.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .quarantinedCorrupt)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: primaryURL.path))

        let quarantined = try #require(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(
                    "\(ProviderReadinessStore.fileName).corrupt-"
                )
            }
        )
        #expect(try Data(contentsOf: quarantined) == originalData)
    }

    @Test("whitespace-padded transaction identities fail closed")
    func whitespacePaddedTransactionIdentitiesFailClosed() throws {
        let primaryPair = try makeCommittedPair(evidenceID: "padded-primary")
        let primaryURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let primaryJournalURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let primaryMarkerURL = primaryPair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        let primaryTransactionID = try #require(
            primaryObject["transactionID"] as? String
        )
        primaryObject["transactionID"] = " \(primaryTransactionID) "
        let paddedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let primaryJournal = try Data(contentsOf: primaryJournalURL)
        let primaryMarker = try Data(contentsOf: primaryMarkerURL)
        try paddedPrimary.write(to: primaryURL, options: .atomic)

        let primaryRecovered = ProviderReadinessStore(directory: primaryPair.directory)
        #expect(primaryRecovered.recoveryState == .recoveredCommittedSnapshot(
            recordCount: 1
        ))
        #expect(primaryRecovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: primaryRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == paddedPrimary)
        #expect(try Data(contentsOf: primaryJournalURL) == primaryJournal)
        #expect(try Data(contentsOf: primaryMarkerURL) == primaryMarker)

        let markerPair = try makeCommittedPair(evidenceID: "padded-marker")
        let markerPrimaryURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let markerJournalURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = markerPair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let markerPrimary = try Data(contentsOf: markerPrimaryURL)
        let markerJournal = try Data(contentsOf: markerJournalURL)
        var markerObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: markerURL)
            ) as? [String: Any]
        )
        let markerTransactionID = try #require(
            markerObject["transactionID"] as? String
        )
        markerObject["transactionID"] = " \(markerTransactionID) "
        let paddedMarker = try JSONSerialization.data(
            withJSONObject: markerObject
        )
        try paddedMarker.write(to: markerURL, options: .atomic)

        let markerRecovered = ProviderReadinessStore(directory: markerPair.directory)
        #expect(markerRecovered.recoveryState == .incompleteTransaction)
        #expect(markerRecovered.recoveryState.isUsable == false)
        #expect(markerRecovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: markerRecovered.records).items.isEmpty)
        #expect(try Data(contentsOf: markerPrimaryURL) == markerPrimary)
        #expect(try Data(contentsOf: markerJournalURL) == markerJournal)
        #expect(try Data(contentsOf: markerURL) == paddedMarker)
    }

    @Test("formatted canonical integer fields survive provider reload")
    func formattedCanonicalIntegerFieldsSurviveReload() throws {
        let pair = try makeCommittedPair(evidenceID: "formatted-integer-reload")
        let recovered = ProviderReadinessStore(directory: pair.directory)
        let expected = pair.latest

        #expect(recovered.recoveryState == .loaded(recordCount: 1))
        #expect(recovered.records == [expected])
        #expect(recovered.records.first?.discoveryReceiptID == expected.discoveryReceiptID)
        #expect(recovered.records.first?.applyReceiptID == expected.applyReceiptID)
        let picker = ChatModelPickerProjection(records: recovered.records)
        #expect(picker.items.count == 1)
        #expect(picker.items.first?.isSelectable == false)
    }

    @Test("whitespace-padded configuration generation cannot revive readiness")
    func whitespacePaddedConfigurationGenerationFailsClosed() throws {
        let pair = try makeCommittedPair(evidenceID: "padded-configuration-generation")
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        var rawRecords = try #require(primaryObject["records"] as? [Any])
        var firstRecord = try #require(rawRecords[0] as? [String: Any])
        firstRecord["configurationGeneration"] = " legacy "
        rawRecords[0] = firstRecord
        primaryObject["records"] = rawRecords
        let paddedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try paddedPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == paddedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("whitespace-padded provider identities cannot revive readiness")
    func whitespacePaddedProviderIdentitiesFailClosed() throws {
        for field in ["providerID", "modelID"] {
            let pair = try makeCommittedPair(
                evidenceID: "padded-identity-(field)"
            )
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            var primaryObject = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: primaryURL)
                ) as? [String: Any]
            )
            var rawRecords = try #require(primaryObject["records"] as? [Any])
            var firstRecord = try #require(rawRecords[0] as? [String: Any])
            let original = try #require(firstRecord[field] as? String)
            firstRecord[field] = " \(original) "
            rawRecords[0] = firstRecord
            primaryObject["records"] = rawRecords
            let paddedPrimary = try JSONSerialization.data(
                withJSONObject: primaryObject
            )
            let journalData = try Data(contentsOf: journalURL)
            let markerData = try Data(contentsOf: markerURL)
            try paddedPrimary.write(to: primaryURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == .recoveredCommittedSnapshot(
                recordCount: 1
            ))
            #expect(recovered.recoveryState.isUsable == false)
            #expect(recovered.records.first?.isApplied == false)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == paddedPrimary)
            #expect(try Data(contentsOf: journalURL) == journalData)
            #expect(try Data(contentsOf: markerURL) == markerData)
        }
    }

    @Test("whitespace-padded configuration fingerprint cannot revive readiness")
    func whitespacePaddedConfigurationFingerprintFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let record = makeRecord(
            status: .passed,
            readinessState: .live,
            evidenceID: "padded-fingerprint",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        #expect(store.upsert([record]))

        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        var primaryObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: primaryURL)
            ) as? [String: Any]
        )
        var rawRecords = try #require(primaryObject["records"] as? [Any])
        var firstRecord = try #require(rawRecords[0] as? [String: Any])
        firstRecord["configurationFingerprint"] = " fingerprint-2 "
        rawRecords[0] = firstRecord
        primaryObject["records"] = rawRecords
        let paddedPrimary = try JSONSerialization.data(
            withJSONObject: primaryObject
        )
        let journalData = try Data(contentsOf: journalURL)
        let markerData = try Data(contentsOf: markerURL)
        try paddedPrimary.write(to: primaryURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: directory)
        #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.first?.isApplied == false)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(try Data(contentsOf: primaryURL) == paddedPrimary)
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    @Test("malicious oversized generation is quarantined without picker recovery")
    func oversizedCommitGenerationFailsClosedAndPreservesEvidence() throws {
        let pair = try makeCommittedPair(
            evidenceID: "generation-oversized"
        )
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        let oversizedGeneration = "18446744073709551616"
        let oversizedPrimary = replacingCommitGeneration(
            in: try Data(contentsOf: primaryURL),
            with: oversizedGeneration
        )
        let oversizedJournal = replacingCommitGeneration(
            in: try Data(contentsOf: journalURL),
            with: oversizedGeneration
        )
        let oversizedMarker = replacingCommitGeneration(
            in: try Data(contentsOf: markerURL),
            with: oversizedGeneration
        )
        try oversizedPrimary.write(to: primaryURL, options: .atomic)
        try oversizedJournal.write(to: journalURL, options: .atomic)
        try oversizedMarker.write(to: markerURL, options: .atomic)

        let recovered = ProviderReadinessStore(directory: pair.directory)
        #expect(recovered.recoveryState == .quarantinedCorrupt)
        #expect(recovered.recoveryState.isUsable == false)
        #expect(recovered.records.isEmpty)
        #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: primaryURL.path) == false)

        let names = try FileManager.default.contentsOfDirectory(
            atPath: pair.directory.path
        )
        let quarantineName = try #require(
            names.first { $0.hasPrefix("\(ProviderReadinessStore.fileName).corrupt-") }
        )
        let quarantineURL = pair.directory.appendingPathComponent(quarantineName)
        #expect(try Data(contentsOf: quarantineURL) == oversizedPrimary)
        #expect(try Data(contentsOf: journalURL) == oversizedJournal)
        #expect(try Data(contentsOf: markerURL) == oversizedMarker)
    }

    @Test("generation overflow refuses to wrap or write a new snapshot")
    func commitGenerationOverflowFailsWithoutWriting() throws {
        let pair = try makeCommittedPair(
            evidenceID: "generation-overflow"
        )
        let primaryURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let journalURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.journalFileName
        )
        let markerURL = pair.directory.appendingPathComponent(
            ProviderReadinessStore.commitMarkerFileName
        )
        try rewriteCompleteTripletGeneration(
            in: pair.directory,
            generation: UInt64.max
        )

        let primaryDecodeStage = ProviderReadinessStore.snapshotDecodeDiagnosticStage(
            try Data(contentsOf: primaryURL)
        )
        let reloaded = ProviderReadinessStore(directory: pair.directory)
        #expect(
            reloaded.recoveryState == .loaded(recordCount: 1),
            "primary-decode-stage=\(primaryDecodeStage)"
        )
        let primaryBefore = try Data(contentsOf: primaryURL)
        let journalBefore = try Data(contentsOf: journalURL)
        let markerBefore = try Data(contentsOf: markerURL)

        let fresh = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(20),
            evidenceID: "generation-overflow-fresh",
            isApplied: true
        )
        #expect(reloaded.upsert([fresh]) == false)
        let pending = try #require(reloaded.records.first)
        #expect(reloaded.records == [pair.latest.downgradedToPending()])
        #expect(pending.status == .unverified)
        #expect(pending.readinessState == .unverified)
        #expect(pending.evidenceID == nil)
        #expect(pending.isApplied == false)
        #expect(pending.applyReceiptID == nil)
        #expect(pending.appliedAt == nil)
        #expect(try Data(contentsOf: primaryURL) == primaryBefore)
        #expect(try Data(contentsOf: journalURL) == journalBefore)
        #expect(try Data(contentsOf: markerURL) == markerBefore)
    }

    @Test("non-canonical generation values never coerce into readiness")
    func nonCanonicalCommitGenerationFailsClosedWithoutRewrite() throws {
        for rawValue in ["1.0", "1e0", "-1", "\"1\""] {
            let pair = try makeCommittedPair(
                evidenceID: "generation-noncanonical-\(rawValue)"
            )
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            let malformedPrimary = replacingCommitGeneration(
                in: try Data(contentsOf: primaryURL),
                with: rawValue
            )
            let journalData = try Data(contentsOf: journalURL)
            let markerData = try Data(contentsOf: markerURL)
            try malformedPrimary.write(to: primaryURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
            #expect(recovered.recoveryState.isUsable == false)
            let pending = try #require(recovered.records.first)
            #expect(pending.isApplied == false)
            #expect(pending.evidenceID == nil)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == malformedPrimary)
            #expect(try Data(contentsOf: journalURL) == journalData)
            #expect(try Data(contentsOf: markerURL) == markerData)
        }
    }

    @Test("duplicate generation keys fail closed in every commit artifact")
    func duplicateCommitGenerationKeysFailClosedWithoutRewrite() throws {
        for fileName in [
            ProviderReadinessStore.fileName,
            ProviderReadinessStore.journalFileName,
            ProviderReadinessStore.commitMarkerFileName
        ] {
            let pair = try makeCommittedPair(
                evidenceID: "generation-duplicate-\(fileName)"
            )
            let primaryURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.fileName
            )
            let journalURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.journalFileName
            )
            let markerURL = pair.directory.appendingPathComponent(
                ProviderReadinessStore.commitMarkerFileName
            )
            let targetURL = pair.directory.appendingPathComponent(fileName)
            let primaryBefore = try Data(contentsOf: primaryURL)
            let journalBefore = try Data(contentsOf: journalURL)
            let markerBefore = try Data(contentsOf: markerURL)
            let duplicateData = duplicatingCommitGeneration(
                in: try Data(contentsOf: targetURL)
            )
            try duplicateData.write(to: targetURL, options: .atomic)

            let recovered = ProviderReadinessStore(directory: pair.directory)
            if fileName == ProviderReadinessStore.fileName {
                #expect(recovered.recoveryState == .recoveredCommittedSnapshot(recordCount: 1))
                #expect(recovered.records.first?.isApplied == false)
            } else {
                #expect(recovered.recoveryState == .incompleteTransaction)
                #expect(recovered.records.isEmpty)
            }
            #expect(recovered.recoveryState.isUsable == false)
            #expect(ChatModelPickerProjection(records: recovered.records).items.isEmpty)
            #expect(try Data(contentsOf: primaryURL) == (
                fileName == ProviderReadinessStore.fileName ? duplicateData : primaryBefore
            ))
            #expect(try Data(contentsOf: journalURL) == (
                fileName == ProviderReadinessStore.journalFileName ? duplicateData : journalBefore
            ))
            #expect(try Data(contentsOf: markerURL) == (
                fileName == ProviderReadinessStore.commitMarkerFileName ? duplicateData : markerBefore
            ))
            #expect(try Data(contentsOf: targetURL) == duplicateData)
        }
    }

    @Test("generation drift returns an explicit unverified recovery fact")
    func generationDriftLookupFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let oldGeneration = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationGeneration: "generation-1",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        #expect(store.upsert([oldGeneration]))

        let drifted = try #require(store.record(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "fingerprint-2",
            now: checkedAt,
            configurationGeneration: "generation-2"
        ))
        let projection = ChatModelPickerProjection(records: [drifted])
        let item = try #require(projection.items.first)

        #expect(drifted.configurationGeneration == "generation-1")
        #expect(drifted.status == .unverified)
        #expect(drifted.readinessState == .unverified)
        #expect(drifted.evidenceID == nil)
        #expect(item.isSelectable == false)
        #expect(item.selectionTruth.isActionable == false)
    }

    @Test("provider picker projection honors expected generation fencing")
    func pickerProjectionCannotReviveOlderGeneration() throws {
        let directory = try makeTemporaryDirectory()
        let writer = ProviderReadinessStore(directory: directory)
        let oldGeneration = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        #expect(writer.upsert([oldGeneration]))

        let current = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        let projected = current.recordsForSelection(
            configuredProviderIDs: ["provider-a"],
            enabledProviderIDs: ["provider-a"],
            readyProviderIDs: ["provider-a"]
        )
        let item = try #require(
            ChatModelPickerProjection(records: projected).pending.first
        )
        #expect(item.providerID == "provider-a")
        #expect(item.status == .unverified)
        #expect(item.isApplied == false)
        #expect(item.selectionTruth.isActionable == false)
    }

    @Test("apply cannot promote a persisted row from an older generation")
    func applyDiscoveredModelsHonorsExpectedGeneration() throws {
        let directory = try makeTemporaryDirectory()
        let writer = ProviderReadinessStore(directory: directory)
        let oldGeneration = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: false,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        #expect(writer.upsert([oldGeneration]))
        let primaryURL = directory.appendingPathComponent(
            ProviderReadinessStore.fileName
        )
        let before = try Data(contentsOf: primaryURL)

        let current = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        #expect(current.applyDiscoveredModels(
            providerID: "provider-a",
            modelIDs: ["model-a"],
            appliedAt: checkedAt
        ).isEmpty)
        #expect(current.records.first?.isApplied == false)
        #expect(try Data(contentsOf: primaryURL) == before)
    }

    @Test("disabled or missing provider configuration cannot revive an applied snapshot")
    func unavailableConfigurationDowngradesBuiltInSnapshotToPending() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let builtInSnapshot = makeRecord(
            providerID: "OpenAI",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        #expect(store.upsert([builtInSnapshot]))
        let independentSnapshot = makeRecord(
            providerID: "Anthropic",
            modelID: "claude-sonnet",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        #expect(store.upsert([independentSnapshot]))

        let strictDisabled = try #require(store.record(
            providerID: "OpenAI",
            modelID: "gpt-5.6-luna",
            configurationFingerprint: "fingerprint-1",
            now: checkedAt,
            configurationGeneration: "generation-1",
            isEnabled: false,
            isConfigured: true,
            isReady: true
        ))
        #expect(strictDisabled.status == .unverified)
        #expect(strictDisabled.isApplied == false)
        #expect(strictDisabled.evidenceID == nil)

        let disabled = store.recordsForSelection(
            providerID: "openai",
            isEnabled: false,
            isConfigured: true,
            isReady: true
        )
        let missing = store.recordsForSelection(
            providerID: "OPENAI",
            isEnabled: true,
            isConfigured: false,
            isReady: true
        )
        let notReady = store.recordsForSelection(
            providerID: "OpenAI",
            isEnabled: true,
            isConfigured: true,
            isReady: false
        )

        for gated in [disabled, missing, notReady] {
            let item = try #require(
                ChatModelPickerProjection(records: gated).pending.first {
                    $0.providerID == "openai"
                }
            )
            #expect(item.status == .unverified)
            #expect(item.readinessState == .unverified)
            #expect(item.isApplied == false)
            #expect(item.applyReceiptID == nil)
            #expect(item.evidenceID == nil)
            #expect(item.isEnabled == false)
            #expect(item.isConfigured == false)
            #expect(item.selectionTruth.isReady == false)
            #expect(item.selectionTruth.isActionable == false)
            #expect(ChatModelPickerProjection(records: gated).items.map(\.providerID) == ["anthropic"])
        }

        // A built-in provider is an explicit exception only when the current
        // runtime supplies all three selection facts; persistence must not
        // infer that exception from the old provider label.
        let explicitlyAvailable = store.recordsForSelection(
            configuredProviderIDs: ["OpenAI", "Anthropic"],
            enabledProviderIDs: ["OpenAI", "Anthropic"],
            readyProviderIDs: ["OpenAI", "Anthropic"]
        )
        let item = try #require(
            ChatModelPickerProjection(records: explicitlyAvailable).items.first {
                $0.providerID == "openai"
            }
        )
        #expect(item.selectionTruth.isActionable)

        let missingConfiguration = store.recordsForSelection(
            configuredProviderIDs: ["Anthropic"],
            enabledProviderIDs: ["Anthropic"],
            readyProviderIDs: ["Anthropic"]
        )
        let missingItem = try #require(
            ChatModelPickerProjection(records: missingConfiguration).pending.first {
                $0.providerID == "openai"
            }
        )
        #expect(missingItem.isConfigured == false)
        #expect(ChatModelPickerProjection(records: missingConfiguration).items.map(\.providerID) == ["anthropic"])
    }

    @Test("late readiness results are fenced by generation and runtime state")
    func lateResultCannotRestorePreviousGeneration() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let current = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let latePreviousGeneration = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(100),
            evidenceID: "live-settings:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(240)
        )
        #expect(store.upsert([current]))

        // The old probe completed later on the wall clock, but its generation
        // and initiating runtime state are no longer current.
        #expect(store.upsert(
            [latePreviousGeneration],
            configurationGeneration: "generation-2",
            isEnabled: true,
            isConfigured: true,
            isReady: true
        ) == false)
        #expect(store.reconnect(
            [latePreviousGeneration],
            configurationGeneration: "generation-2",
            isEnabled: true,
            isConfigured: true,
            isReady: true
        ) == [.rejectedInvalid])
        #expect(store.records == [current])

        // A completion racing a disable/configuration removal is rejected as
        // well; the prior green row is only visible as pending through the
        // current runtime gate.
        #expect(store.upsert(
            [current],
            configurationGeneration: "generation-2",
            isEnabled: false,
            isConfigured: false,
            isReady: false
        ) == false)
        let gated = store.recordsForSelection(
            providerID: "provider-a",
            isEnabled: false,
            isConfigured: false,
            isReady: false
        )
        let item = try #require(ChatModelPickerProjection(records: gated).pending.first)
        #expect(item.status == .unverified)
        #expect(item.isApplied == false)
        #expect(item.selectionTruth.isActionable == false)
    }

    @Test("reloaded stores reject generation rollback and health receipt replay")
    func reloadFencesRollbackAndReplay() throws {
        let directory = try makeTemporaryDirectory()
        let previousGeneration = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(-30),
            evidenceID: "live-settings:1111111111111111111111111111111111111111111111111111111111111111",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(60)
        )
        let current = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let writer = ProviderReadinessStore(directory: directory)
        #expect(writer.upsert([previousGeneration]))
        let primaryURL = directory.appendingPathComponent(ProviderReadinessStore.fileName)
        let journalURL = directory.appendingPathComponent(ProviderReadinessStore.journalFileName)
        let markerURL = directory.appendingPathComponent(ProviderReadinessStore.commitMarkerFileName)
        let previousPrimary = try Data(contentsOf: primaryURL)
        let previousJournal = try Data(contentsOf: journalURL)
        let previousMarker = try Data(contentsOf: markerURL)
        #expect(writer.upsert([current]))
        let committedCurrent = try #require(writer.records.first {
            $0.configurationGeneration == "generation-2"
        })

        // A second process reloads the current generation and must not accept
        // a late result from the previous generation, even when that result
        // has a later checkedAt value.
        let reloaded = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        let lateRollback = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(30),
            evidenceID: "live-settings:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isApplied: true,
            configurationGeneration: "generation-1",
            configurationFingerprint: "fingerprint-1",
            expiresAt: checkedAt.addingTimeInterval(240)
        )
        #expect(reloaded.upsert([lateRollback]) == false)
        #expect(reloaded.records.contains(committedCurrent))
        #expect(reloaded.records.first {
            $0.configurationGeneration == "generation-1"
        }?.isApplied == false)

        // Replaying an already consumed health receipt cannot replace the
        // current observation with a later timestamp after reload.
        let replay = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(30),
            evidenceID: current.evidenceID,
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(240)
        )
        #expect(reloaded.upsert([replay]))
        #expect(reloaded.reconnect([replay]) == [.ignoredStale])
        #expect(reloaded.records.contains(committedCurrent))
        #expect(reloaded.records.allSatisfy {
            $0.configurationGeneration == "generation-2" || $0.isApplied == false
        })

        // A mixed transaction remains rejected independently of the complete
        // rollback below.
        let currentPrimary = try Data(contentsOf: primaryURL)
        try previousPrimary.write(to: primaryURL, options: .atomic)
        let mixed = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        #expect(mixed.records.isEmpty == false)
        #expect(ChatModelPickerProjection(records: mixed.records).items.isEmpty)
        #expect(
            ChatModelPickerProjection(records: mixed.records)
                .pending.allSatisfy { $0.isSelectable == false }
        )
        try currentPrimary.write(to: primaryURL, options: .atomic)

        // Restore the complete internally valid older triplet. It remains
        // inspectable, while strict lookup and picker projection retain
        // fail-closed unverified state under the current generation.
        try previousPrimary.write(to: primaryURL, options: .atomic)
        try previousJournal.write(to: journalURL, options: .atomic)
        try previousMarker.write(to: markerURL, options: .atomic)
        let rolledBack = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )
        #expect(rolledBack.records.first?.configurationGeneration == "generation-1")
        #expect(rolledBack.records.first?.isApplied == false)
        let recovered = try #require(rolledBack.record(
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "fingerprint-2",
            now: checkedAt,
            configurationGeneration: "generation-2"
        ))
        #expect(recovered.status == .unverified)
        #expect(recovered.evidenceID == nil)
        let rolledBackProjection = ChatModelPickerProjection(records: [recovered])
        let rolledBackItem = try #require(rolledBackProjection.items.first)
        #expect(rolledBackItem.isApplied)
        #expect(rolledBackItem.isSelectable == false)
        #expect(rolledBackProjection.pending.isEmpty)
    }

    @Test("reload merges conflicting same-generation receipts as deterministic pending")
    func reloadConflictingReceiptsNeverChoosesActionableTimestamp() throws {
        let directory = try makeTemporaryDirectory()
        let earlierReceipt = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationGeneration: "generation-2",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            discoveryReceiptID: "discovery-receipt-a",
            discoveredAt: checkedAt,
            applyReceiptID: "apply-receipt-a",
            appliedAt: checkedAt,
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let laterReceipt = ProviderReadinessPersistenceRecord(
            providerID: "provider-a",
            modelID: "model-a",
            configurationGeneration: "generation-2",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(30),
            evidenceID: "live-settings:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isApplied: true,
            discoveryReceiptID: "discovery-receipt-b",
            discoveredAt: checkedAt.addingTimeInterval(30),
            applyReceiptID: "apply-receipt-b",
            appliedAt: checkedAt.addingTimeInterval(30),
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(240)
        )
        let object: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "records": [
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(laterReceipt)
                ),
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(earlierReceipt)
                ),
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(
            to: directory.appendingPathComponent(ProviderReadinessStore.fileName),
            options: .atomic
        )

        let firstReload = ProviderReadinessStore(directory: directory)
        let secondReload = ProviderReadinessStore(directory: directory)
        #expect(firstReload.records == secondReload.records)
        let record = try #require(firstReload.records.first)
        #expect(record.status == .unverified)
        #expect(record.readinessState == .unverified)
        #expect(record.isApplied == false)
        #expect(record.evidenceID == nil)
        #expect(record.applyReceiptID == nil)
        #expect(ChatModelPickerProjection(records: firstReload.records).items.isEmpty)
        #expect(ChatModelPickerProjection(records: firstReload.records).pending.count == 1)
    }

    @Test("failed conflict persistence retains the previously committed pending snapshot")
    func failedConflictCommitDoesNotCreateQuarantineOrActionableState() throws {
        let directory = try makeTemporaryDirectory()
        let committedPending = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        ).downgradedToPending()
        let writer = ProviderReadinessStore(directory: directory)
        #expect(writer.upsert([committedPending]))

        var persistenceFailureCount = 0
        let staleWriter = ProviderReadinessStore(directory: directory) { _ in
            persistenceFailureCount += 1
        }
        let newerPending = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "live-settings:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(240)
        ).downgradedToPending()
        #expect(writer.upsert([newerPending]))

        // The stale writer tries to promote its local pending conflict after
        // another process has committed a newer pending snapshot. The
        // baseline guard rejects the write and restores its prior memory.
        let lateGreen = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(20),
            evidenceID: "live-settings:fedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcba",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(360)
        )
        #expect(staleWriter.upsert([lateGreen]) == false)
        #expect(persistenceFailureCount == 1)

        let memoryRecord = try #require(staleWriter.records.first)
        let diskStore = ProviderReadinessStore(directory: directory)
        let diskRecord = try #require(diskStore.records.first)
        #expect(staleWriter.recoveryState.isUsable)
        #expect(memoryRecord.status == .unverified)
        #expect(memoryRecord.isApplied == false)
        #expect(memoryRecord.evidenceID == nil)
        #expect(diskRecord.status == .unverified)
        #expect(diskRecord.isApplied == false)
        #expect(diskRecord.evidenceID == nil)
        #expect(diskStore.recoveryState.isUsable)
        #expect(ChatModelPickerProjection(records: [memoryRecord]).items.isEmpty)
        #expect(ChatModelPickerProjection(records: [diskRecord]).items.isEmpty)
    }

    @Test("failed stale commit downgrades its in-memory actionable snapshot")
    func failedStaleCommitCannotExposeActionableMemoryRow() throws {
        let directory = try makeTemporaryDirectory()
        let first = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:stale-first",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(120)
        )
        let writer = ProviderReadinessStore(directory: directory)
        #expect(writer.upsert([first]))
        let staleWriter = ProviderReadinessStore(
            directory: directory,
            configurationGeneration: "generation-2"
        )

        let newer = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: "live-settings:disk-newer",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(240)
        )
        #expect(writer.upsert([newer]))

        let late = makeRecord(
            providerID: "provider-a",
            modelID: "model-a",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(20),
            evidenceID: "live-settings:stale-late",
            isApplied: true,
            configurationGeneration: "generation-2",
            configurationFingerprint: "fingerprint-2",
            expiresAt: checkedAt.addingTimeInterval(360)
        )
        #expect(staleWriter.upsert([late]) == false)

        let memoryRecord = try #require(staleWriter.records.first)
        #expect(memoryRecord.status == .unverified)
        #expect(memoryRecord.readinessState == .unverified)
        #expect(memoryRecord.isApplied == false)
        #expect(memoryRecord.evidenceID == nil)
        #expect(ChatModelPickerProjection(records: staleWriter.records).items.isEmpty)

        let diskRecord = try #require(
            ProviderReadinessStore(directory: directory).records.first
        )
        #expect(diskRecord.evidenceID == newer.evidenceID)
        #expect(diskRecord.status == .passed)
        #expect(diskRecord.isApplied)
    }

    @Test("restart merge downgrades equal-timestamp duplicate identities")
    func restartMergeDowngradesConflictingDuplicates() throws {
        let directory = try makeTemporaryDirectory()
        let passed = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "passed",
            isApplied: true
        )
        let blocked = makeRecord(
            status: .unavailable,
            readinessState: .blocked,
            checkedAt: checkedAt,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: true
        )
        let object: [String: Any] = [
            "schemaVersion": ProviderReadinessStore.schemaVersion,
            "records": [
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(passed)),
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(blocked)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(
            to: directory.appendingPathComponent(ProviderReadinessStore.fileName),
            options: .atomic
        )

        let restarted = ProviderReadinessStore(directory: directory)
        #expect(restarted.records.count == 1)
        #expect(restarted.records[0].status == .unverified)
        #expect(restarted.records[0].readinessState == .unverified)
        #expect(restarted.records[0].evidenceID == nil)
    }

    @Test("discovered records enter the picker only after explicit application")
    func discoveredModelsRequireExplicitApply() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let discovered = makeRecord(
            status: .discovered,
            readinessState: .unverified,
            evidenceID: nil,
            isApplied: false
        )

        store.upsert(discovered)
        let pendingProjection = ChatModelPickerProjection(records: store.records)
        #expect(pendingProjection.items.isEmpty)
        #expect(pendingProjection.pending.map(\.modelID) == ["gpt-5.6-luna"])
        #expect(pendingProjection.pending[0].status == .discovered)

        _ = store.applyDiscoveredModels(
            providerID: "luna",
            modelIDs: ["gpt-5.6-luna"]
        )
        let appliedProjection = ChatModelPickerProjection(records: store.records)
        #expect(appliedProjection.items.map(\.modelID) == ["gpt-5.6-luna"])
        #expect(appliedProjection.items[0].isSelectable == false)
    }

    @Test("explicit apply matches provider identity case-insensitively")
    func explicitApplyNormalizesProviderIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(makeRecord(
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-evidence",
            isApplied: false
        ))

        _ = store.applyDiscoveredModels(
            providerID: "LUNA",
            modelIDs: ["gpt-5.6-luna"]
        )

        #expect(store.records.first?.isApplied == true)
        #expect(ChatModelPickerProjection(records: store.records).items.first?.isSelectable == true)
    }

    @Test("passed records become selectable after explicit application")
    func passedModelsRequireExplicitApply() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let passed = makeRecord(
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-evidence",
            isApplied: false
        )

        store.upsert(passed)
        #expect(ChatModelPickerProjection(records: store.records).items.isEmpty)

        _ = store.applyDiscoveredModels(
            providerID: "luna",
            modelIDs: ["gpt-5.6-luna"]
        )
        let appliedProjection = ChatModelPickerProjection(records: store.records)
        #expect(appliedProjection.items.map(\.modelID) == ["gpt-5.6-luna"])
        #expect(appliedProjection.items.first?.isSelectable == true)
    }

    @Test("removing a provider deletes all applied and pending records")
    func removeProviderDeletesAllRecords() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(makeRecord(
            status: .passed,
            readinessState: .mock,
            evidenceID: "mock-evidence",
            isApplied: true
        ))
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "luna",
                modelID: "gpt-5.6-luna-mini",
                status: .discovered,
                readinessState: .unverified,
                checkedAt: checkedAt.addingTimeInterval(1),
                evidenceID: nil,
                isApplied: false
            )
        )

        #expect(store.removeProvider(providerID: "LUNA") == 2)
        #expect(store.records.isEmpty)
        #expect(ChatModelPickerProjection(records: store.records).items.isEmpty)
        #expect(ChatModelPickerProjection(records: store.records).pending.isEmpty)
        #expect(ProviderReadinessStore(directory: directory).records.isEmpty)
    }

    @Test("discover and apply receipts remain immutable across refreshes")
    func discoverAndApplyLineageSurvivesRefresh() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let discoveredAt = checkedAt
        let discovered = makeRecord(
            status: .discovered,
            readinessState: .unverified,
            checkedAt: discoveredAt,
            isApplied: false
        )

        store.upsert(discovered)
        _ = store.applyDiscoveredModels(
            providerID: "luna",
            modelIDs: ["gpt-5.6-luna"],
            appliedAt: discoveredAt.addingTimeInterval(3)
        )
        let applied = try #require(store.records.first)
        #expect(applied.discoveryReceiptID == discovered.discoveryReceiptID)
        #expect(applied.applyReceiptID != nil)
        #expect(applied.appliedAt == discoveredAt.addingTimeInterval(3))

        let refreshed = makeRecord(
            status: .passed,
            readinessState: .mock,
            checkedAt: discoveredAt.addingTimeInterval(10),
            evidenceID: "mock-refresh",
            isApplied: false
        )
        store.upsert(refreshed)
        let afterRefresh = try #require(store.records.first)
        #expect(afterRefresh.isApplied)
        #expect(afterRefresh.discoveryReceiptID == applied.discoveryReceiptID)
        #expect(afterRefresh.applyReceiptID == applied.applyReceiptID)
        #expect(afterRefresh.appliedAt == applied.appliedAt)
    }

    @Test("credential successor rebind invalidates only the exact provider/model lineage")
    func credentialSuccessorRebindIsScopedAndAllowsFreshCheck() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let oldFailure = makeRecord(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            status: .unavailable,
            readinessState: .blocked,
            errorCategory: .permissionDenied,
            evidenceID: nil,
            isApplied: true
        )
        let sameProviderSibling = makeRecord(
            providerID: "luna",
            modelID: "gpt-5.6-luna-mini",
            status: .passed,
            readinessState: .live,
            evidenceID: "live-settings:sibling",
            isApplied: true
        )
        let otherProvider = makeRecord(
            providerID: "hermes",
            modelID: "gpt-5.6-luna",
            status: .unavailable,
            readinessState: .blocked,
            errorCategory: .timeout,
            evidenceID: nil,
            isApplied: false
        )
        store.upsert(oldFailure)
        store.upsert(sameProviderSibling)
        store.upsert(otherProvider)

        #expect(store.rebindCredentialSuccessor(
            providerID: "LUNA",
            modelID: "gpt-5.6-luna"
        ))
        #expect(store.records.contains(sameProviderSibling))
        #expect(store.records.contains(otherProvider))
        #expect(store.records.contains(oldFailure) == false)

        // A replacement credential may be checked at the same timestamp (or
        // have a clock that is behind the old failure); it must still win.
        let freshCheck = makeRecord(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "live-settings:fresh",
            isApplied: false
        )
        store.upsert(freshCheck)

        let reloaded = ProviderReadinessStore(directory: directory)
        #expect(reloaded.records.contains(freshCheck))
        #expect(reloaded.records.contains(sameProviderSibling))
        #expect(reloaded.records.contains(otherProvider))
        #expect(reloaded.records.contains(oldFailure) == false)
    }

    @Test("missing credential successor lineage is a no-op")
    func missingCredentialSuccessorRebindDoesNotPersist() throws {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        #expect(store.rebindCredentialSuccessor(
            providerID: "unknown",
            modelID: "model"
        ) == false)
        #expect(store.records.isEmpty)
    }

    private func makeCommittedPair(
        evidenceID: String
    ) throws -> (directory: URL, latest: ProviderReadinessPersistenceRecord) {
        let directory = try makeTemporaryDirectory()
        let store = ProviderReadinessStore(directory: directory)
        let first = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "(evidenceID)-first",
            isApplied: true
        )
        let latest = makeRecord(
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt.addingTimeInterval(10),
            evidenceID: evidenceID,
            isApplied: true
        )
        #expect(store.upsert([first]))
        #expect(store.upsert([latest]))
        return (directory, try #require(store.records.first))
    }

    private struct MigrationHistoryFixture: Codable {
        let migrationID: String
        let fromVersion: Int
        let toVersion: Int
        let previousVersionDigest: String?

        private enum CodingKeys: String, CodingKey {
            case migrationID
            case fromVersion
            case toVersion
            case previousVersionDigest
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(migrationID, forKey: .migrationID)
            try container.encode(fromVersion, forKey: .fromVersion)
            try container.encode(toVersion, forKey: .toVersion)
            try container.encode(previousVersionDigest, forKey: .previousVersionDigest)
        }
    }

    private struct SnapshotDigestFixture: Codable {
        let schemaVersion: Int
        let transactionID: String
        var commitGeneration: UInt64
        let previousDigest: String?
        let providerScope: String?
        let providerScopeVersion: Int
        let providerScopeMigrationReceipt: String?
        let providerScopePreviousVersionDigest: String?
        let providerScopeMigrationHistory: [MigrationHistoryFixture]?
        let providerScopeMigrationCheckpoint: String?
        let providerScopeMigrationEpoch: UInt64?
        let providerScopeMigrationCleanupTombstone: String?
        let providerScopeMigrationPreviousRoot: String?
        let records: [ProviderReadinessPersistenceRecord]
    }

    private func rewriteCompleteTripletGeneration(
        in directory: URL,
        generation: UInt64
    ) throws {
        let primaryURL = directory.appendingPathComponent(ProviderReadinessStore.fileName)
        let journalURL = directory.appendingPathComponent(ProviderReadinessStore.journalFileName)
        let markerURL = directory.appendingPathComponent(ProviderReadinessStore.commitMarkerFileName)
        var digestFixture = try JSONDecoder().decode(
            SnapshotDigestFixture.self,
            from: Data(contentsOf: primaryURL)
        )
        digestFixture.commitGeneration = generation
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(digestFixture))
            .map { String(format: "%02x", $0) }
            .joined()

        for url in [primaryURL, journalURL, markerURL] {
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            object["payloadDigest"] = digest
            let updated = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try replacingCommitGeneration(
                in: updated,
                with: String(generation)
            ).write(to: url, options: .atomic)
        }
    }

    private func replacingCommitGeneration(
        in data: Data,
        with rawJSONValue: String
    ) -> Data {
        let json = String(decoding: data, as: UTF8.self)
        guard let keyRange = json.range(of: "\"commitGeneration\"") else {
            return data
        }
        guard let colon = json[keyRange.upperBound...].firstIndex(of: ":") else {
            return data
        }
        var valueStart = json.index(after: colon)
        while valueStart < json.endIndex, json[valueStart].isWhitespace {
            valueStart = json.index(after: valueStart)
        }
        var valueEnd = valueStart
        while valueEnd < json.endIndex,
              !json[valueEnd].isWhitespace,
              json[valueEnd] != ",",
              json[valueEnd] != "}" {
            valueEnd = json.index(after: valueEnd)
        }
        var replaced = json
        replaced.replaceSubrange(valueStart..<valueEnd, with: rawJSONValue)
        return Data(replaced.utf8)
    }

    private func duplicatingCommitGeneration(in data: Data) -> Data {
        let json = String(decoding: data, as: UTF8.self)
        guard let keyRange = json.range(of: "\"commitGeneration\"") else {
            return data
        }
        guard let colon = json[keyRange.upperBound...].firstIndex(of: ":") else {
            return data
        }
        var valueStart = json.index(after: colon)
        while valueStart < json.endIndex, json[valueStart].isWhitespace {
            valueStart = json.index(after: valueStart)
        }
        var valueEnd = valueStart
        while valueEnd < json.endIndex,
              !json[valueEnd].isWhitespace,
              json[valueEnd] != ",",
              json[valueEnd] != "}" {
            valueEnd = json.index(after: valueEnd)
        }
        let value = String(json[valueStart..<valueEnd])
        var replaced = json
        replaced.insert(contentsOf: ",\"commitGeneration\":\(value)", at: valueEnd)
        return Data(replaced.utf8)
    }

    private func makeRecord(
        providerID: String = "luna",
        modelID: String = "gpt-5.6-luna",
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        checkedAt: Date? = nil,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        evidenceID: String? = "fixture-evidence",
        isApplied: Bool = true,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration,
        configurationFingerprint: String? = nil,
        expiresAt: Date? = nil
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
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("if-07e-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
