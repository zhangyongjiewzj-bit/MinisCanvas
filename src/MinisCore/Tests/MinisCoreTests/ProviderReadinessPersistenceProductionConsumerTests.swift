import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness production persistence consumer")
struct ProviderReadinessPersistenceProductionConsumerTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)

    @Test("production consumer persists discovery and model outcomes across reopen")
    func consumeReportPersistsPerModelOutcomes() async throws {
        let directory = try makeDirectory("consumer")
        defer { try? FileManager.default.removeItem(at: directory) }

        let readiness = ProviderReadiness.evaluate(
            providerID: "provider-a",
            modelID: "model-a",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "keychain-reference"),
            capabilities: [],
            checkedAt: checkedAt,
            evidenceID: "evidence-a"
        )
        let report = ProviderReadinessCheckReport(
            readiness: readiness,
            stageResults: [],
            discoveredModels: [
                ProviderReadinessModel(id: "model-a"),
                ProviderReadinessModel(id: "model-b")
            ],
            modelResults: [
                "model-a": ProviderReadinessModelResult(
                    modelID: "model-a",
                    status: .passed
                ),
                "model-b": ProviderReadinessModelResult(
                    modelID: "model-b",
                    status: .failed,
                    failureCategory: .modelNotFound
                )
            ]
        )

        let store = ProviderReadinessStore(directory: directory)
        let consumer = ProviderReadinessProductionConsumer(store: store)
        let records = await consumer.consume(
            report,
            latency: 24,
            appliedModelIDs: ["model-a"]
        )

        #expect(records.map(\.modelID) == ["model-a", "model-b"])
        #expect(records.first?.isApplied == true)
        #expect(records.last?.status == .unavailable)
        #expect(await consumer.currentRecords().count == 2)
        #expect(ProviderReadinessStore(directory: directory).records.count == 2)

        let persisted = try Data(
            contentsOf: directory.appendingPathComponent(ProviderReadinessStore.fileName)
        )
        let json = String(decoding: persisted, as: UTF8.self)
        #expect(!json.contains("keychain-reference"))
        #expect(!json.contains("sk-"))
        #expect(!json.contains("Authorization"))
    }

    @Test("valid siblings survive a partial snapshot and corrupt input is quarantined")
    func recoveryIsExplicitAndFailClosed() throws {
        let partialDirectory = try makeDirectory("partial")
        defer { try? FileManager.default.removeItem(at: partialDirectory) }
        let valid = makeRecord(providerID: "provider-a", modelID: "model-a")
        let validObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(valid)
        )
        let partialObject: [String: Any] = [
            "schemaVersion": 1,
            "records": [validObject, ["providerID": "missing-fields"]]
        ]
        let partialData = try JSONSerialization.data(withJSONObject: partialObject)
        try partialData.write(
            to: partialDirectory.appendingPathComponent(ProviderReadinessStore.fileName),
            options: .atomic
        )

        let partialStore = ProviderReadinessStore(directory: partialDirectory)
        #expect(
            partialStore.recoveryState
                == .recoveredPartial(validRecordCount: 1, droppedRecordCount: 1)
        )
        #expect(partialStore.records.map(\.modelID) == ["model-a"])
        #expect(
            ProviderReadinessStore(directory: partialDirectory).recoveryState
                == .loaded(recordCount: 1)
        )

        let corruptDirectory = try makeDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: corruptDirectory) }
        try Data("not-json".utf8).write(
            to: corruptDirectory.appendingPathComponent(ProviderReadinessStore.fileName),
            options: .atomic
        )
        let corruptStore = ProviderReadinessStore(directory: corruptDirectory)
        #expect(corruptStore.recoveryState == .quarantinedCorrupt)
        #expect(corruptStore.records.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: corruptDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(files.contains { $0.lastPathComponent.contains(".corrupt-") })
    }

    @Test("provider identity rebind removes all old models but preserves other providers")
    func providerIdentityRebindIsScoped() throws {
        let directory = try makeDirectory("rebind")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        store.upsert(makeRecord(providerID: "provider-a", modelID: "model-a"))
        store.upsert(makeRecord(providerID: "provider-a", modelID: "model-b"))
        store.upsert(makeRecord(providerID: "provider-b", modelID: "model-a"))

        #expect(store.rebindCredentialSuccessor(providerID: "PROVIDER-A") == 2)
        #expect(store.records.map(\.providerID) == ["provider-b"])
        #expect(ProviderReadinessStore(directory: directory).records.count == 1)
    }

    @Test("cache store reopens atomically and invalidates only old credential versions")
    func cacheStoreRebindIsScoped() throws {
        let directory = try makeDirectory("cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProviderReadinessCacheStore(directory: directory)
        #expect(cache.upsert(
            makeRecord(providerID: "provider-a", modelID: "model-a"),
            credentialVersion: "old"
        ))
        #expect(cache.upsert(
            makeRecord(providerID: "provider-a", modelID: "model-a"),
            credentialVersion: "new"
        ))
        #expect(cache.upsert(
            makeRecord(providerID: "provider-b", modelID: "model-a"),
            credentialVersion: "other"
        ))

        #expect(cache.invalidateForSuccessorRebind(
            providerID: "PROVIDER-A",
            newCredentialVersion: "new"
        ) == 1)
        let reopened = ProviderReadinessCacheStore(directory: directory)
        #expect(reopened.recoveryState == .loaded(recordCount: 2))
        #expect(reopened.record(
            providerID: "provider-a", modelID: "model-a", credentialVersion: "old"
        ) == nil)
        #expect(reopened.record(
            providerID: "provider-a", modelID: "model-a", credentialVersion: "new"
        ) != nil)
        #expect(reopened.record(
            providerID: "provider-b", modelID: "model-a", credentialVersion: "other"
        ) != nil)
    }

    @Test("reconnect replaces equal-timestamp latency and rejects late results")
    func reconnectUsesFreshLatencyAndStaleFence() async throws {
        let directory = try makeDirectory("reconnect")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeReport(checkedAt: checkedAt, evidenceID: "first")
        let store = ProviderReadinessStore(directory: directory)
        let consumer = ProviderReadinessProductionConsumer(store: store)
        _ = await consumer.consume(first, latency: 180)

        let sameTimestampRetry = makeReport(checkedAt: checkedAt, evidenceID: "retry")
        #expect(await consumer.reconnect(sameTimestampRetry, latency: 42) == [.persisted])
        #expect(await consumer.currentRecords().first?.latency == 42)
        #expect(await consumer.currentRecords().first?.evidenceID == "retry")

        let late = makeReport(
            checkedAt: checkedAt.addingTimeInterval(-1),
            evidenceID: "late"
        )
        #expect(await consumer.reconnect(late, latency: 7) == [.ignoredStale])
        #expect(await consumer.currentRecords().first?.latency == 42)
        #expect(
            ProviderReadinessStore(directory: directory).records.first?.evidenceID == "retry"
        )
    }

    @Test("reconnect rejects conflicting duplicate provider/model revisions")
    func reconnectRejectsConflictingDuplicateRevisions() async throws {
        let directory = try makeDirectory("reconnect-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderReadinessStore(directory: directory)
        let consumer = ProviderReadinessProductionConsumer(store: store)
        let passed = makeReport(checkedAt: checkedAt, evidenceID: "passed")

        let conflictingReport = ProviderReadinessCheckReport(
            readiness: passed.readiness,
            stageResults: [],
            discoveredModels: [
                ProviderReadinessModel(id: "model-a"),
                ProviderReadinessModel(id: " model-a ")
            ],
            modelResults: [
                "model-a": ProviderReadinessModelResult(
                    modelID: "model-a",
                    status: .passed
                ),
                " model-a ": ProviderReadinessModelResult(
                    modelID: " model-a ",
                    status: .failed,
                    failureCategory: .modelNotFound
                )
            ]
        )
        #expect(
            await consumer.reconnect(conflictingReport)
                == [.rejectedInvalid, .rejectedInvalid]
        )
        #expect(await consumer.currentRecords().isEmpty)
    }

    @Test("one report reconnect commits all model outcomes atomically")
    func reconnectPersistsModelBatchAsOneGeneration() async throws {
        let directory = try makeDirectory("reconnect-batch")
        defer { try? FileManager.default.removeItem(at: directory) }

        let readiness = ProviderReadiness.evaluate(
            providerID: "provider-a",
            modelID: "model-a",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "keychain-reference"),
            capabilities: [],
            checkedAt: checkedAt,
            evidenceID: "batch"
        )
        let report = ProviderReadinessCheckReport(
            readiness: readiness,
            stageResults: [],
            discoveredModels: [
                ProviderReadinessModel(id: "model-a"),
                ProviderReadinessModel(id: "model-b")
            ],
            modelResults: [:]
        )

        let store = ProviderReadinessStore(directory: directory)
        let consumer = ProviderReadinessProductionConsumer(store: store)
        #expect(await consumer.reconnect(report, latency: -3) == [.persisted, .persisted])
        let records = await consumer.currentRecords()
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.latency == 0 })
        #expect(ProviderReadinessStore(directory: directory).records.count == 2)
    }

    private func makeRecord(
        providerID: String,
        modelID: String
    ) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .live,
            checkedAt: checkedAt,
            evidenceID: "evidence-\(providerID)-\(modelID)",
            isApplied: false
        )
    }

    private func makeReport(
        checkedAt: Date,
        evidenceID: String
    ) -> ProviderReadinessCheckReport {
        let readiness = ProviderReadiness.evaluate(
            providerID: "provider-a",
            modelID: "model-a",
            deployment: .remote,
            probe: .reachable,
            credential: .available(source: "keychain-reference"),
            capabilities: [],
            checkedAt: checkedAt,
            evidenceID: evidenceID
        )
        return ProviderReadinessCheckReport(
            readiness: readiness,
            stageResults: [],
            discoveredModels: [],
            modelResults: [:]
        )
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3Readiness-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
