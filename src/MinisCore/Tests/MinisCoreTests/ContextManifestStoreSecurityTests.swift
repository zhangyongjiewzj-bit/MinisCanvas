import Foundation
import Testing
@testable import MinisCore

@Suite("Context manifest store security boundaries")
struct ContextManifestStoreSecurityTests {
    private struct PersistedManifestRecord: Encodable {
        let manifest: ContextManifest
        let receipt: ContextManifestReceipt
        let provenance: MemoryProvenance? = nil
    }

    private func snapshot() -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            sessionID: "session-manifest",
            providerID: "provider-manifest",
            modelID: "model-manifest",
            configurationFingerprint: "configuration-manifest",
            skillIdentifiers: ["browser"],
            conversationID: "conversation-manifest"
        )
    }

    private func entry(
        _ identifier: String,
        tokenCost: Int = 1,
        contentHash: String = "digest-manifest"
    ) -> ContextManifest.Entry {
        ContextManifest.Entry(
            identifier: identifier,
            tokenCost: tokenCost,
            scope: "conversation",
            provenance: "test:manifest",
            contentHash: contentHash
        )
    }

    private func scopeIdentity(workspaceID: String = "workspace-manifest") -> AgentExecutionScopeIdentity {
        AgentExecutionScopeIdentity(
            sessionID: "session-manifest",
            workspaceID: workspaceID,
            memoryScopeID: "memory-manifest",
            skillsScopeID: "skills-manifest",
            permissionsScopeID: "permissions-manifest",
            taskID: "task-manifest",
            budgetScopeID: "budget-manifest"
        )
    }

    private func manifest(
        entries: [ContextManifest.Entry],
        runID: String = "run-manifest"
    ) -> (ContextManifest, ContextManifestReceipt) {
        let value = ContextManifest(snapshot: snapshot(), entries: entries)
        let receipt = ContextManifestReceipt(
            runID: runID,
            requestedBudget: entries.reduce(0) { $0 + $1.tokenCost },
            usedBudget: entries.reduce(0) { $0 + $1.tokenCost },
            droppedEntryIDs: []
        )
        return (value, receipt)
    }

    @Test("overflowing token totals fail closed instead of trapping")
    func overflowingTokenTotalIsRejected() {
        let value = ContextManifest(
            snapshot: snapshot(),
            entries: [entry("max", tokenCost: Int.max), entry("overflow", tokenCost: 1)]
        )
        let receipt = ContextManifestReceipt(
            runID: "run-overflow",
            requestedBudget: Int.max,
            usedBudget: Int.max,
            droppedEntryIDs: []
        )

        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: value, receipt: receipt)
        }
    }

    @Test("entry count, duplicate identifiers, and unsafe identities are bounded")
    func manifestIdentityAndCountBoundaries() {
        let tooManyEntries = (0...1_024).map { entry("entry-\($0)") }
        let (oversized, oversizedReceipt) = manifest(entries: tooManyEntries, runID: "run-count")
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: oversized, receipt: oversizedReceipt)
        }

        let (duplicate, duplicateReceipt) = manifest(
            entries: [entry("same"), entry("same")],
            runID: "run-duplicate"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: duplicate, receipt: duplicateReceipt)
        }

        let (bidi, bidiReceipt) = manifest(
            entries: [entry("visible\u{202E}identifier")],
            runID: "run-bidi"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: bidi, receipt: bidiReceipt)
        }

        let (unsafeScope, unsafeScopeReceipt) = manifest(
            entries: [
                ContextManifest.Entry(
                    identifier: "safe",
                    tokenCost: 1,
                    scope: "conversation\u{0000}",
                    provenance: "test:manifest"
                )
            ],
            runID: "run-scope-control"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: unsafeScope, receipt: unsafeScopeReceipt)
        }

        let malformedScope = scopeIdentity(workspaceID: "workspace\u{202E}manifest")
        let scopedManifest = ContextManifest(
            snapshot: snapshot(),
            entries: [],
            scopeIdentity: malformedScope
        )
        let scopedReceipt = ContextManifestReceipt(
            runID: "run-scoped-control",
            requestedBudget: 0,
            usedBudget: 0,
            droppedEntryIDs: []
        )
        #expect(throws: ContextManifestStoreError.invalidScopeIdentity) {
            try ContextManifestStore().record(
                manifest: scopedManifest,
                receipt: scopedReceipt,
                scopeIdentity: malformedScope
            )
        }

        let (oversizedIdentifier, oversizedIdentifierReceipt) = manifest(
            entries: [entry(String(repeating: "i", count: 257))],
            runID: "run-identifier-oversized"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(
                manifest: oversizedIdentifier,
                receipt: oversizedIdentifierReceipt
            )
        }
    }

    @Test("hash and receipt boundaries reject unsafe or unbounded values while preserving legacy empty hashes")
    func hashAndReceiptBoundaries() throws {
        let oversizedHash = String(repeating: "x", count: 257)
        let (oversized, oversizedReceipt) = manifest(
            entries: [entry("hash-oversized", contentHash: oversizedHash)],
            runID: "run-hash-oversized"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: oversized, receipt: oversizedReceipt)
        }

        let (unsafeHash, unsafeHashReceipt) = manifest(
            entries: [entry("hash-control", contentHash: "digest\u{0000}unsafe")],
            runID: "run-hash-control"
        )
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: unsafeHash, receipt: unsafeHashReceipt)
        }

        let legacyManifest = ContextManifest(
            snapshot: snapshot(),
            entries: [ContextManifest.Entry(identifier: "legacy-empty-hash", tokenCost: 1)]
        )
        let legacyReceipt = ContextManifestReceipt(
            runID: "run-legacy-empty-hash",
            requestedBudget: 1,
            usedBudget: 1,
            droppedEntryIDs: []
        )
        #expect(try ContextManifestStore().record(manifest: legacyManifest, receipt: legacyReceipt) == legacyReceipt)

        let unsafeDroppedReceipt = ContextManifestReceipt(
            runID: "run-dropped-control",
            requestedBudget: 0,
            usedBudget: 0,
            droppedEntryIDs: ["dropped\u{202E}entry"]
        )
        let (empty, _) = manifest(entries: [], runID: unsafeDroppedReceipt.runID)
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: empty, receipt: unsafeDroppedReceipt)
        }

        let duplicateDroppedReceipt = ContextManifestReceipt(
            runID: "run-dropped-duplicate",
            requestedBudget: 0,
            usedBudget: 0,
            droppedEntryIDs: ["same", "same"]
        )
        let (emptyDuplicate, _) = manifest(entries: [], runID: duplicateDroppedReceipt.runID)
        #expect(throws: ContextManifestStoreError.invalidManifest) {
            try ContextManifestStore().record(manifest: emptyDuplicate, receipt: duplicateDroppedReceipt)
        }
    }

    @Test("old manifest remains inert while new canonical runs persist")
    func oldProductionManifestIsNotReturnedToExecution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context-manifests-v1.json")
        let session = "00000000-0000-4000-8000-000000000001"
        let oldID = "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:browser:\(session)"
        let oldSnapshot = ConversationContextSnapshotV1(
            snapshotID: oldID, sessionID: session, providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"], conversationID: session
        )
        let oldRecord = PersistedManifestRecord(
            manifest: ContextManifest(snapshot: oldSnapshot, entries: [entry("system-prompt")]),
            receipt: ContextManifestReceipt(
                runID: "run-old", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
            )
        )
        let rawOld = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecord)) as? [String: Any]
        )
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": ["run-old": rawOld], "deletions": [:]
        ])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)

        let store = try ContextManifestStore(persistenceURL: url)
        #expect(store.persistenceDiagnostics() == nil)
        #expect(try Data(contentsOf: url) == original)
        #expect(store.manifest(runID: "run-old") == nil)
        #expect(store.receipt(runID: "run-old") == nil)
        #expect(store.provenance(runID: "run-old") == nil)
        let scope = AgentExecutionScopeIdentity(
            sessionID: session, workspaceID: "workspace-synthetic",
            memoryScopeID: "memory-synthetic", skillsScopeID: "skills-synthetic",
            permissionsScopeID: "permissions-synthetic", taskID: "task-synthetic",
            budgetScopeID: "budget-synthetic"
        )
        #expect(try store.manifest(runID: "run-old", scopeIdentity: scope) == nil)

        let currentSnapshot = ConversationContextSnapshotV1(
            sessionID: session, providerID: "mock", modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"], conversationID: session
        )
        let currentManifest = ContextManifest(
            snapshot: currentSnapshot, entries: [entry("system-prompt")]
        )
        let duplicate = ContextManifestReceipt(
            runID: "run-old", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
        )
        #expect(throws: ContextManifestStoreError.conflictingReceipt) {
            _ = try store.record(manifest: currentManifest, receipt: duplicate)
        }
        let fresh = ContextManifestReceipt(
            runID: "run-new", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
        )
        #expect(try store.record(manifest: currentManifest, receipt: fresh) == fresh)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let records = try #require(saved["records"] as? [String: [String: Any]])
        #expect(NSDictionary(dictionary: records["run-old"] ?? [:]).isEqual(to: rawOld))
        let restarted = try ContextManifestStore(persistenceURL: url)
        #expect(restarted.manifest(runID: "run-old") == nil)
        #expect(restarted.manifest(runID: "run-new") == currentManifest)
    }

    @Test("unknown old manifest fields keep the file fail closed and unchanged")
    func oldManifestUnknownFieldIsNotDropped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-manifest-unknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context-manifests-v1.json")
        let session = "00000000-0000-4000-8000-000000000001"
        let oldSnapshot = ConversationContextSnapshotV1(
            snapshotID: "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:browser:\(session)",
            sessionID: session, providerID: "mock", modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"], conversationID: session
        )
        let oldRecord = PersistedManifestRecord(
            manifest: ContextManifest(snapshot: oldSnapshot, entries: [entry("system-prompt")]),
            receipt: ContextManifestReceipt(
                runID: "run-old", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
            )
        )
        var raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecord)) as? [String: Any]
        )
        let cleanRaw = raw
        raw["futureField"] = "retain-me"
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": ["run-old": raw], "deletions": [:]
        ])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)
        let store = try ContextManifestStore(persistenceURL: url)
        #expect(store.persistenceDiagnostics() != nil)
        #expect(store.manifest(runID: "run-old") == nil)
        #expect(try Data(contentsOf: url) == original)

        let unknownEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": ["run-old": cleanRaw],
            "deletions": [:], "futureField": "retain-top-level"
        ])
        try unknownEnvelope.write(to: url)
        let topLevelStore = try ContextManifestStore(persistenceURL: url)
        #expect(topLevelStore.persistenceDiagnostics() != nil)
        #expect(topLevelStore.manifest(runID: "run-old") == nil)
        #expect(try Data(contentsOf: url) == unknownEnvelope)
    }

    @Test("ambiguous old manifest cannot execute or share its ID with another binding")
    func ambiguousOldManifestIsInertAndAliasFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-ambiguous-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("context-manifests-v1.json")
        let session = "00000000-0000-4000-8000-000000000001"
        let fingerprint = "chat:v2:1024:context-settings:v1:" + String(repeating: "a", count: 64)
        let oldID = "context:\(session):Local:qwen:7b:\(fingerprint):browser:\(session)"
        let old = ConversationContextSnapshotV1(
            snapshotID: oldID, sessionID: session, providerID: "Local", modelID: "qwen:7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        let oldRecord = PersistedManifestRecord(
            manifest: ContextManifest(snapshot: old, entries: [entry("system-prompt")]),
            receipt: ContextManifestReceipt(
                runID: "run-old", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
            )
        )
        let rawOld = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecord)) as? [String: Any]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": ["run-old": rawOld], "deletions": [:]
        ])
        try original.write(to: url)

        let store = try ContextManifestStore(persistenceURL: url)
        #expect(store.persistenceDiagnostics() == nil)
        #expect(try Data(contentsOf: url) == original)
        #expect(store.manifest(runID: "run-old") == nil)
        #expect(store.receipt(runID: "run-old") == nil)
        #expect(store.provenance(runID: "run-old") == nil)
        let fresh = ConversationContextSnapshotV1(
            sessionID: session, providerID: "Local", modelID: "qwen:7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        #expect(fresh.snapshotID.hasPrefix("context:v2:"))
        let freshManifest = ContextManifest(snapshot: fresh, entries: [entry("system-prompt")])
        let duplicateRun = ContextManifestReceipt(
            runID: "run-old", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
        )
        #expect(throws: ContextManifestStoreError.conflictingReceipt) {
            _ = try store.record(manifest: freshManifest, receipt: duplicateRun)
        }
        let freshReceipt = ContextManifestReceipt(
            runID: "run-new", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
        )
        #expect(try store.record(manifest: freshManifest, receipt: freshReceipt) == freshReceipt)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let savedRecords = try #require(saved["records"] as? [String: [String: Any]])
        #expect(NSDictionary(dictionary: savedRecords["run-old"] ?? [:]).isEqual(to: rawOld))
        let restarted = try ContextManifestStore(persistenceURL: url)
        #expect(restarted.manifest(runID: "run-old") == nil)
        #expect(restarted.manifest(runID: "run-new") == freshManifest)

        let alias = ConversationContextSnapshotV1(
            snapshotID: oldID, sessionID: session, providerID: "Local:qwen", modelID: "7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        let aliasRecord = PersistedManifestRecord(
            manifest: ContextManifest(snapshot: alias, entries: [entry("system-prompt")]),
            receipt: ContextManifestReceipt(
                runID: "run-alias", requestedBudget: 1, usedBudget: 1, droppedEntryIDs: []
            )
        )
        let rawAlias = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(aliasRecord)) as? [String: Any]
        )
        let collision = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "records": ["run-old": rawOld, "run-alias": rawAlias],
            "deletions": [:]
        ])
        try collision.write(to: url)
        let blocked = try ContextManifestStore(persistenceURL: url)
        #expect(blocked.persistenceDiagnostics() != nil)
        #expect(blocked.manifest(runID: "run-old") == nil)
        #expect(blocked.manifest(runID: "run-alias") == nil)
        #expect(try Data(contentsOf: url) == collision)
    }
}
