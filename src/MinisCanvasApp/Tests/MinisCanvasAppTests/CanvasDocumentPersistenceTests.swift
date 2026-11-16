import Testing
import Foundation
import CryptoKit
import CanvasCore
@testable import MinisCanvasApp

@Suite("CanvasDocument 资产/任务/视口/选择/预览持久化")
@MainActor
struct CanvasDocumentPersistenceTests {
    private func makeDraftStore() throws -> DraftStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = DraftStore(directory: directory)
        store.debounceInterval = .milliseconds(300)
        return store
    }

    private func replacementDraftEnvelopeData(
        at url: URL, payload: Data
    ) throws -> Data {
        var envelope = try JSONDecoder().decode(
            DraftEnvelope.self, from: Data(contentsOf: url)
        )
        envelope.payload = payload
        envelope.payloadSHA256 = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        return try JSONEncoder().encode(envelope)
    }

    private func makeCollectionMeta(id: UUID, draftKey: String) -> CanvasCollectionMeta {
        CanvasCollectionMeta(
            id: id,
            name: id.uuidString,
            draftKey: draftKey
        )
    }

    private func writeCollection(
        to drafts: DraftStore,
        currentCanvasID: String?,
        documents: [CanvasCollectionMeta],
        legacyArray: Bool = false
    ) throws {
        let data: Data
        if legacyArray {
            data = try CanvasStore.cleanupEncodedData(documents)
        } else {
            data = try CanvasStore.cleanupEncodedData(CanvasCollectionSnapshot(
                currentCanvasID: currentCanvasID,
                documents: documents
            ))
        }
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        try data.write(
            to: drafts.directory.appendingPathComponent(CanvasStore.collectionFileName),
            options: .atomic
        )
    }

    /// Deterministic await for the async collection restore: suspends on the
    /// restore task handle that attachDraftStore launched instead of polling
    /// canvasDocuments/collectionRestoreDiagnostic (previous wall-clock loop
    /// could pass silently when the restore had not completed).
    private func awaitCollectionRestore(_ canvas: CanvasStore) async throws {
        let task = try #require(canvas.collectionRestoreTask)
        await task.value
    }

    @Test func singleCanvasCleanRestoreRoundTripsAllCanvasState() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let canvas = CanvasStore()
        canvas.attachDraftStore(drafts)
        let node = try #require(canvas.addNode(ofType: "image"))
        var backend = node.backendConfig ?? NodeBackendConfig()
        backend.params["result.path"] = "/tmp/canvas-preview.png"
        backend.params["result.kind"] = "image"
        canvas.updateBackendConfig(backend, for: node.id)

        let assetID = UUID()
        let task = CanvasTaskReference(
            taskID: "task-1",
            state: "running",
            idempotencyKey: "canvas-task-1",
            updatedAt: Date(timeIntervalSince1970: 123)
        )
        let viewport = CanvasViewportState(
            center: Point(x: 240, y: 360),
            zoom: 1.75,
            canvasSize: Size(width: 1200, height: 800)
        )
        canvas.setAssetReferences([assetID])
        canvas.setTaskReferences([task])
        canvas.selectNode(id: node.id)
        canvas.updateViewport(viewport)
        #expect(canvas.presentPreview(for: node.id))
        canvas.flushCanvasDraft()

        let payload = try #require(drafts.load(key: DraftStore.canvasKey))
        let draft = try JSONDecoder().decode(CanvasDraft.self, from: payload)
        #expect(draft.schemaVersion == 3)
        #expect(draft.assetIDs == [assetID])
        #expect(draft.tasks == [task])
        #expect(draft.viewport == viewport)
        #expect(draft.selection == [node.id])
        #expect(draft.selectionOrder == [node.id])
        #expect(draft.previewNodeID == node.id)

        let restored = CanvasStore()
        #expect(AppLifecycleGuard.autoRestoreCanvasDraft(
            into: restored,
            directory: drafts.directory
        ))
        #expect(restored.currentCanvas.assetIDs.contains(assetID))
        #expect(restored.currentCanvas.assetIDs.count == 2)
        #expect(restored.currentCanvas.tasks == [task])
        #expect(restored.viewportState == viewport)
        #expect(restored.selectedNodeIDs == [node.id])
        #expect(restored.selectedNodeID == node.id)
        #expect(restored.previewNodeID == node.id)
    }

    @Test func singleCanvasLegacyMediaRestoreCanonicalizesNodeIdentity() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let nodeID = UUID()
        let graph = NodeGraph(nodes: [
            CanvasNode(
                id: nodeID,
                type: ManjuNodeType.assetRef.rawValue,
                title: "旧资产",
                backendConfig: NodeBackendConfig(
                    params: [
                        "result.path": "/tmp/legacy-restored.png",
                        "result.kind": "image",
                        "result.name": "legacy-restored.png"
                    ]
                )
            )
        ])
        let draft = CanvasDraft(graph: graph, groups: [], savedAt: Date())
        let payload = try JSONEncoder().encode(draft)
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: payload)
        drafts.flushNow(key: DraftStore.canvasKey)

        let restored = CanvasStore()
        #expect(AppLifecycleGuard.autoRestoreCanvasDraft(
            into: restored,
            directory: drafts.directory
        ))

        let restoredNode = try #require(restored.graph.node(id: nodeID))
        let assetID = try #require(restoredNode.mediaAssetID)
        #expect(restored.currentCanvas.assetIDs.contains(assetID))
        #expect(restoredNode.backendConfig?.params["result.path"] == "/tmp/legacy-restored.png")
        #expect(restored.resultMedia(of: nodeID)?.path == "/tmp/legacy-restored.png")

        // autoRestoreCanvasDraft consumes the crash-recovery payload. Reattach
        // the store before exercising the documented write-back path.
        restored.attachDraftStore(drafts)
        restored.noteGraphChanged()
        restored.flushCanvasDraft()
        let saved = try #require(drafts.load(key: DraftStore.canvasKey))
        let savedDraft = try JSONDecoder().decode(CanvasDraft.self, from: saved)
        #expect(savedDraft.nodes.first?.backendConfig?.params["asset.id"] == assetID.uuidString)
    }

    @Test func startupRestoreRejectsStalePreloadedDraftAfterUserMutation() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let source = CanvasStore()
        source.attachDraftStore(drafts)
        _ = try #require(source.addNode(ofType: "image"))
        source.flushCanvasDraft()
        let preloadedData = try #require(drafts.load(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        let startupGeneration = restored.mutationGeneration
        let editedNode = try #require(restored.addNode(ofType: "text"))

        #expect(!AppLifecycleGuard.autoRestoreCanvasDraft(
            into: restored,
            directory: drafts.directory,
            preloadedData: preloadedData,
            expectedMutationGeneration: startupGeneration
        ))
        #expect(restored.graph.nodes.map(\.id) == [editedNode.id])
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
    }

    @Test("future canvas draft is rejected by direct restore")
    func futureCanvasDraftIsRejectedByDirectRestore() throws {
        let canvas = CanvasStore()
        let futureGraph = NodeGraph(nodes: [CanvasNode(type: "text", title: "future")])
        var futureDraft = CanvasDraft(graph: futureGraph, groups: [], savedAt: Date())
        futureDraft.schemaVersion = 4

        #expect(!canvas.restoreCanvas(from: futureDraft))
        #expect(canvas.graph.nodes.isEmpty)
    }

    @Test("future canvas draft is excluded from recovery")
    func futureCanvasDraftIsExcludedFromRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        var futureDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "future")]),
            groups: [],
            savedAt: Date()
        )
        futureDraft.schemaVersion = 4
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(futureDraft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        #expect(restored.recoverableCanvasDraft() == nil)
    }

    @Test("oversized canvas draft is excluded from recovery")
    func oversizedCanvasDraftIsExcludedFromRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let oversizedDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(
                type: "text",
                title: String(repeating: "x", count: CanvasStore.cleanupPayloadBytesLimit)
            )]),
            groups: [],
            savedAt: Date()
        )
        let payload = try JSONEncoder().encode(oversizedDraft)
        #expect(payload.count > CanvasStore.cleanupPayloadBytesLimit)
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: payload)
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(restored.recoverableCanvasDraft() == nil)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
    }

    @Test("duplicate-key canvas draft is excluded from recovery")
    func duplicateKeyCanvasDraftIsExcludedFromRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        var draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            groups: [],
            savedAt: Date()
        )
        draft.schemaVersion = 3
        let canonical = try JSONEncoder().encode(draft)
        let canonicalText = try #require(String(data: canonical, encoding: .utf8))
        try #require(canonicalText.first == "{")
        // Insert at the root regardless of JSONEncoder's object-key order.
        // The original schemaVersion may be the final field with no comma.
        let duplicatedText = "{\"schemaVersion\":3," + String(canonicalText.dropFirst())
        #expect(duplicatedText != canonicalText)
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: Data(duplicatedText.utf8)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(restored.recoverableCanvasDraft() == nil)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
    }

    @Test("canvas restore rejects duplicate node identities")
    func canvasRestoreRejectsDuplicateNodeIdentities() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let duplicateID = UUID()
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [
                CanvasNode(id: duplicateID, type: "text", title: "first"),
                CanvasNode(id: duplicateID, type: "text", title: "second")
            ]),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(restored.recoverableCanvasDraft() == nil)
        #expect(!restored.restoreCanvas(from: draft))
        #expect(restored.graph.nodes.isEmpty)
    }

    @Test("empty canvas draft is excluded from recovery")
    func emptyCanvasDraftIsExcludedFromRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let emptyDraft = CanvasDraft(
            graph: NodeGraph(),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(emptyDraft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(restored.recoverableCanvasDraft() == nil)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
    }

    @Test("collection marker suppresses single-canvas recovery")
    func collectionMarkerSuppressesSingleCanvasRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: firstID.uuidString,
            documents: [
                makeCollectionMeta(
                    id: firstID,
                    draftKey: CanvasStore.canvasDraftKey(for: firstID)
                ),
                makeCollectionMeta(
                    id: secondID,
                    draftKey: CanvasStore.canvasDraftKey(for: secondID)
                )
            ]
        )
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(restored.recoverableCanvasDraft() == nil)
    }

    @Test("unsafe collection marker suppresses single-canvas recovery")
    func unsafeCollectionMarkerSuppressesSingleCanvasRecovery() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        try FileManager.default.createDirectory(
            at: drafts.directory,
            withIntermediateDirectories: true
        )
        let markerSource = drafts.directory.appendingPathComponent("marker-source")
        let collectionURL = drafts.directory
            .appendingPathComponent(CanvasStore.collectionFileName)
        try Data("unsafe".utf8).write(to: markerSource, options: .atomic)
        try FileManager.default.linkItem(at: markerSource, to: collectionURL)

        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(key: DraftStore.canvasKey, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: DraftStore.canvasKey))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(!CanvasStore.collectionFileExists(at: drafts.directory))
        #expect(restored.recoverableCanvasDraft() == nil)
    }

    @Test("multi-canvas restore rejects an invalid draft graph")
    func multiCanvasRestoreRejectsInvalidDraftGraph() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: firstID.uuidString,
            documents: [
                makeCollectionMeta(
                    id: firstID,
                    draftKey: CanvasStore.canvasDraftKey(for: firstID)
                ),
                makeCollectionMeta(
                    id: secondID,
                    draftKey: CanvasStore.canvasDraftKey(for: secondID)
                )
            ]
        )
        let duplicateID = UUID()
        let invalidDraft = CanvasDraft(
            graph: NodeGraph(nodes: [
                CanvasNode(id: duplicateID, type: "text", title: "first"),
                CanvasNode(id: duplicateID, type: "text", title: "second")
            ]),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: CanvasStore.canvasDraftKey(for: secondID),
            payload: try JSONEncoder().encode(invalidDraft)
        )
        #expect(drafts.flushNow(key: CanvasStore.canvasDraftKey(for: secondID)))

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(drafts.hasDraft(key: CanvasStore.canvasDraftKey(for: secondID)))
    }

    @Test func multiCanvasStartupRestoresStatePerCanvas() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let canvas = CanvasStore()
        canvas.attachDraftStore(drafts)
        let second = canvas.createCanvas(name: "第二画布")
        let node = try #require(canvas.addNode(ofType: "image"))
        var backend = node.backendConfig ?? NodeBackendConfig()
        backend.params["result.path"] = "/tmp/second-canvas-preview.png"
        backend.params["result.kind"] = "image"
        canvas.updateBackendConfig(backend, for: node.id)
        canvas.setAssetReferences([UUID()])
        canvas.setTaskReferences([
            CanvasTaskReference(
                taskID: "task-2",
                state: "queued",
                idempotencyKey: "canvas-task-2",
                updatedAt: Date(timeIntervalSince1970: 456)
            )
        ])
        canvas.selectNode(id: node.id)
        canvas.updateViewport(CanvasViewportState(
            center: Point(x: 90, y: 120),
            zoom: 1.25,
            canvasSize: Size(width: 900, height: 600)
        ))
        #expect(canvas.presentPreview(for: node.id))
        canvas.flushCanvasDraft()

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        let document = try #require(restored.canvasDocuments.first { $0.id == second.id })
        #expect(document.graph.nodes.contains { $0.id == node.id })
        #expect(document.assetIDs.count == 1)
        #expect(document.tasks.map(\.taskID) == ["task-2"])
        #expect(document.viewport.zoom == 1.25)
        #expect(document.selection == [node.id])
        #expect(document.previewNodeID == node.id)
    }

    @Test("multi-member collection state has stable canonical bytes and restores")
    func multiMemberCollectionStateHasStableCanonicalBytesAndRestores() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let ids = (1...32).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        }
        let selectedOrder = Array(ids.reversed())
        let firstID = UUID()
        let secondID = UUID()
        let key = CanvasStore.canvasDraftKey(for: firstID)
        var first = makeCollectionMeta(id: firstID, draftKey: key)
        first.assetIDs = Set(ids)
        first.selection = Set(ids)
        first.selectionOrder = selectedOrder
        let documents = [
            first,
            makeCollectionMeta(id: secondID, draftKey: CanvasStore.canvasDraftKey(for: secondID))
        ]
        let snapshot = CanvasCollectionSnapshot(
            currentCanvasID: firstID.uuidString, documents: documents
        )
        let bytes = try CanvasStore.cleanupEncodedData(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encodedDocuments = try #require(object["documents"] as? [[String: Any]])
        let encodedFirst = try #require(encodedDocuments.first)
        #expect(encodedFirst["assetIDs"] as? [String] == ids.map(\.uuidString).sorted())
        #expect(encodedFirst["selection"] as? [String] == ids.map(\.uuidString).sorted())
        #expect(encodedFirst["selectionOrder"] as? [String] == selectedOrder.map(\.uuidString))
        let decoded = try JSONDecoder().decode(CanvasCollectionSnapshot.self, from: bytes)
        #expect(decoded.documents == documents)
        #expect(CanvasStore.cleanupJSONIsCanonical(decoded, data: bytes))

        let draft = CanvasDraft(
            graph: NodeGraph(nodes: ids.map { CanvasNode(id: $0, type: "text", title: "节点") }),
            groups: [], savedAt: Date(timeIntervalSince1970: 1),
            assetIDs: Set(ids), selection: Set(ids), selectionOrder: selectedOrder
        )
        drafts.scheduleSave(key: key, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: key))
        try writeCollection(to: drafts, currentCanvasID: firstID.uuidString, documents: documents)
        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)
        #expect(restored.currentCanvasID == firstID)
        #expect(restored.currentCanvas.assetIDs == Set(ids))
        #expect(restored.currentCanvas.selection == Set(ids))
        #expect(restored.currentCanvas.selectionOrder == selectedOrder)
        #expect(restored.collectionRestoreDiagnostic == nil)
    }

    @Test func multiCanvasRestartPreservesCurrentCanvasID() async throws {
        // Exercise collection-only creation before any draft has created its root.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-empty-restart-\(UUID().uuidString)", isDirectory: true)
        let drafts = DraftStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let canvas = CanvasStore()
        canvas.attachDraftStore(drafts)
        let second = canvas.createCanvas(name: "当前画布")
        canvas.flushCanvasDraft()
        #expect(canvas.currentCanvasID == second.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.currentCanvasID == second.id)
    }

    @Test("canvas cleanup journal resumes after partial deletion")
    func cleanupJournalResumesAfterPartialDeletion() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let keptIDs = [UUID(), UUID()]
        let keptDocuments = keptIDs.map { id in
            makeCollectionMeta(id: id, draftKey: CanvasStore.canvasDraftKey(for: id))
        }
        let replacement = CanvasCollectionSnapshot(
            currentCanvasID: keptIDs[0].uuidString,
            documents: keptDocuments
        )
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: CanvasStore.canvasDraftKey(for: removedID),
            collectionAction: "replace",
            replacementCollection: replacement
        )
        try FileManager.default.createDirectory(
            at: drafts.directory,
            withIntermediateDirectories: true
        )
        // The removed draft is already gone: this is the crash point after the
        // first owned entry was deleted but before the journal was finalized.
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)
        let sentinel = drafts.directory.appendingPathComponent("non-owned.txt")
        try Data("preserve".utf8).write(to: sentinel, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.canvasDocuments.map(\.id) == keptIDs)
        #expect(restored.currentCanvasID == keptIDs[0])
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "preserve")

        // A second startup is a no-op after the journal is finalized.
        let restarted = CanvasStore()
        restarted.attachDraftStore(drafts)
        try await awaitCollectionRestore(restarted)
        #expect(restarted.canvasDocuments.map(\.id) == keptIDs)
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "preserve")
    }

    @Test("consumed cleanup journal receipt rejects replay")
    func consumedCleanupJournalReceiptRejectsReplay() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalData = try CanvasStore.cleanupEncodedData(journal)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try journalData.write(to: journalURL, options: .atomic)

        let firstRestore = CanvasStore()
        firstRestore.attachDraftStore(drafts)
        let receiptURL = CanvasStore.cleanupReceiptURL(at: drafts.directory)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(CanvasCleanupReceipt.self, from: receiptData)
        #expect(receipt.transactionGeneration == journal.transactionGeneration + 1)

        try journalData.write(to: journalURL, options: .atomic)
        let replay = CanvasStore()
        replay.attachDraftStore(drafts)

        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))
    }

    @Test("cleanup tombstone predecessor chain permits one bounded successor")
    func cleanupTombstonePredecessorChainRecoversSuccessor() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "successor")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let predecessor = CanvasCleanupReceipt(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            receiptID: UUID().uuidString,
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            transactionID: UUID(),
            documentScope: DraftStore.canvasKey,
            documentEpoch: 2,
            epochPreviousDigest: String(repeating: "c", count: 64),
            epochPreviousRootDigest: String(repeating: "d", count: 64),
            transactionGeneration: 1,
            journalDigest: String(repeating: "a", count: 64)
        )
        let predecessorData = try CanvasStore.cleanupEncodedData(predecessor)
        let successor = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: predecessor.collectionGeneration,
            documentEpoch: predecessor.documentEpoch,
            epochPreviousDigest: predecessor.epochPreviousDigest,
            epochPreviousRootDigest: predecessor.epochPreviousRootDigest,
            tombstonePredecessorDigest: CanvasStore.cleanupJournalDigest(predecessorData),
            tombstoneGeneration: 2
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let receiptURL = CanvasStore.cleanupReceiptURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(successor).write(to: journalURL, options: .atomic)
        try predecessorData.write(to: receiptURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        let successorReceiptData = try Data(contentsOf: receiptURL)
        let successorReceipt = try JSONDecoder().decode(
            CanvasCleanupReceipt.self,
            from: successorReceiptData
        )
        #expect(successorReceipt.tombstoneGeneration == 2)
        #expect(successorReceipt.tombstonePredecessorDigest
                    == CanvasStore.cleanupJournalDigest(predecessorData))
        #expect(successorReceipt.tombstoneRootDigest == predecessor.tombstoneRootDigest)
    }

    @Test("cleanup rejects a receipt resurrected across document epochs")
    func crossEpochCleanupReceiptResurrectionFailsClosed() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "epoch")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let previousEpochReceipt = CanvasCleanupReceipt(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            receiptID: UUID().uuidString,
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            transactionID: UUID(),
            documentScope: DraftStore.canvasKey,
            documentEpoch: 1,
            transactionGeneration: 1,
            journalDigest: String(repeating: "b", count: 64)
        )
        let previousData = try CanvasStore.cleanupEncodedData(previousEpochReceipt)
        let successor = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: previousEpochReceipt.collectionGeneration,
            documentEpoch: 2,
            epochPreviousDigest: String(repeating: "e", count: 64),
            epochPreviousRootDigest: previousEpochReceipt.tombstoneRootDigest,
            tombstonePredecessorDigest: CanvasStore.cleanupJournalDigest(previousData),
            tombstoneGeneration: 2
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let receiptURL = CanvasStore.cleanupReceiptURL(at: drafts.directory)
        let successorData = try CanvasStore.cleanupEncodedData(successor)
        try successorData.write(to: journalURL, options: .atomic)
        try previousData.write(to: receiptURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == successorData)
        #expect(try Data(contentsOf: receiptURL) == previousData)
    }

    @Test("cleanup tombstone generation history is bounded")
    func oversizedCleanupTombstoneGenerationFailsClosed() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        try FileManager.default.createDirectory(
            at: drafts.directory,
            withIntermediateDirectories: true
        )
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            tombstoneGeneration: UInt64(CanvasStore.cleanupTombstoneGenerationLimit) + 1
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("committed cleanup generation one is not trusted as a successor")
    func committedGenerationOneCleanupJournalFailsClosed() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "prepared")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            state: .committed,
            transactionGeneration: 1
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let data = try CanvasStore.cleanupEncodedData(journal)
        try data.write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == data)
    }

    @Test("committed cleanup journal survives clear-to-receipt crash window")
    func committedCleanupJournalSurvivesClearToReceiptCrashWindow() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let oldDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "old")]),
            savedAt: Date(timeIntervalSince1970: 1)
        )
        drafts.scheduleSave(key: removedKey, payload: try JSONEncoder().encode(oldDraft))
        #expect(drafts.flushNow(key: removedKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let oldGeneration = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let newDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "new")]),
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let newData = try replacementDraftEnvelopeData(
            at: draftURL, payload: JSONEncoder().encode(newDraft)
        )
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "remove",
            removedDraftGeneration: oldGeneration,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let firstRestore = CanvasStore()
        firstRestore.cleanupBeforeReceiptHook = {
            do {
                try newData.write(to: draftURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: draftURL.path
                )
            } catch {
                return false
            }
            return false
        }
        firstRestore.attachDraftStore(drafts)

        let committedData = try Data(contentsOf: journalURL)
        let committed = try JSONDecoder().decode(CanvasCleanupJournal.self, from: committedData)
        #expect(committed.state == .committed)
        #expect(committed.transactionGeneration == 2)
        #expect(committed.checkpointGeneration == 1)
        #expect(committed.checkpointDigest == committed.previousDigest)
        #expect(committed.previousDigest == CanvasStore.cleanupJournalDigest(
            try CanvasStore.cleanupEncodedData(journal)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: CanvasStore.cleanupReceiptURL(at: drafts.directory).path
        ))
        let saved = try #require(drafts.load(key: removedKey))
        #expect(try JSONDecoder().decode(CanvasDraft.self, from: saved) == newDraft)

        let restarted = CanvasStore()
        restarted.attachDraftStore(drafts)
        #expect(drafts.hasDraft(key: removedKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: CanvasStore.cleanupReceiptURL(at: drafts.directory).path
        ))
    }

    @Test("cleanup committed successor recovers within the two-file bound")
    func cleanupCommittedSuccessorRecoversWithinBound() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            documentEpoch: 2,
            epochPreviousDigest: String(repeating: "a", count: 64)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            documentEpoch: prepared.documentEpoch,
            epochPreviousDigest: prepared.epochPreviousDigest,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        try preparedData.write(to: journalURL, options: .atomic)
        try CanvasStore.cleanupEncodedData(committed).write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(!drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))
        #expect(FileManager.default.fileExists(
            atPath: CanvasStore.cleanupReceiptURL(at: drafts.directory).path
        ))
    }

    @Test("compaction handoff rejects a substituted checkpoint root seal")
    func cleanupCompactionHandoffRejectsCheckpointRootSubstitution() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "checkpoint")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let substituted = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            checkpointRootDigest: String(repeating: "0", count: 64),
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let substitutedData = try CanvasStore.cleanupEncodedData(substituted)
        try preparedData.write(to: journalURL, options: .atomic)
        try substitutedData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == substitutedData)
    }

    @Test("epoch rollover rejects a divergent previous-root successor seal")
    func cleanupEpochRolloverRejectsSuccessorSealSubstitution() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            documentEpoch: 2,
            epochPreviousDigest: String(repeating: "a", count: 64),
            epochPreviousRootDigest: String(repeating: "b", count: 64),
            epochSuccessorDigest: String(repeating: "0", count: 64)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let data = try CanvasStore.cleanupEncodedData(journal)
        try data.write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(try Data(contentsOf: journalURL) == data)
    }

    @Test("post-compaction active replacement fails the handoff identity fence")
    func postCompactionActiveReplacementLeavesStateUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let committedData = try CanvasStore.cleanupEncodedData(committed)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        try preparedData.write(to: journalURL, options: .atomic)
        try committedData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.cleanupAfterCheckpointPromotionHook = {
            try? committedData.write(to: journalURL, options: .atomic)
        }
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == committedData)
        #expect(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("cleanup marker substitution and post-cleanup recreate are retained")
    func substitutedCleanupMarkerLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let committedData = try CanvasStore.cleanupEncodedData(committed)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let receiptURL = CanvasStore.cleanupReceiptURL(at: drafts.directory)
        try preparedData.write(to: journalURL, options: .atomic)
        try committedData.write(to: candidateURL, options: .atomic)
        let substitutedReceipt = CanvasCleanupReceipt(
            sessionRootPath: committed.sessionRootPath,
            removedDraftKey: committed.removedDraftKey,
            receiptID: UUID().uuidString,
            removedDraftGeneration: committed.removedDraftGeneration,
            collectionGeneration: committed.collectionGeneration,
            transactionID: committed.transactionID,
            documentScope: committed.documentScope,
            documentEpoch: committed.documentEpoch,
            transactionGeneration: committed.transactionGeneration,
            checkpointDigest: committed.checkpointDigest,
            journalDigest: CanvasStore.cleanupJournalDigest(committedData)
        )
        let substitutedData = try CanvasStore.cleanupEncodedData(substitutedReceipt)

        let restored = CanvasStore()
        restored.cleanupBeforeMarkerRemovalHook = {
            try? substitutedData.write(to: receiptURL, options: .atomic)
            try? committedData.write(to: journalURL, options: .atomic)
        }
        restored.attachDraftStore(drafts)

        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(try Data(contentsOf: journalURL) == committedData)
        #expect(try Data(contentsOf: receiptURL) == substitutedData)
    }

    @Test("forked cleanup successor leaves both journal bytes untouched")
    func forkedCleanupSuccessorLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let fork = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: String(repeating: "0", count: 64)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let forkData = try CanvasStore.cleanupEncodedData(fork)
        try preparedData.write(to: journalURL, options: .atomic)
        try forkData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == forkData)
    }

    @Test("same-generation divergent cleanup payload is rejected")
    func sameGenerationDivergentCleanupPayloadLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let divergent = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            payloadDigest: String(repeating: "0", count: 64),
            state: .committed,
            transactionGeneration: prepared.transactionGeneration,
            previousDigest: prepared.previousDigest
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let divergentData = try CanvasStore.cleanupEncodedData(divergent)
        try preparedData.write(to: journalURL, options: .atomic)
        try divergentData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == divergentData)
    }

    @Test("same-epoch divergent cleanup marker predecessor is rejected")
    func sameEpochDivergentCleanupMarkerLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            documentEpoch: 2,
            epochPreviousDigest: String(repeating: "1", count: 64)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let divergent = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            documentEpoch: prepared.documentEpoch,
            epochPreviousDigest: String(repeating: "2", count: 64),
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let divergentData = try CanvasStore.cleanupEncodedData(divergent)
        try preparedData.write(to: journalURL, options: .atomic)
        try divergentData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == divergentData)
    }

    @Test("old checkpoint epoch does not resurrect a committed successor")
    func committedCleanupHistoryRejectsRolloverSuccessor() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let committedData = try CanvasStore.cleanupEncodedData(committed)
        let staleSuccessor = CanvasCleanupJournal(
            sessionRootPath: committed.sessionRootPath,
            removedDraftKey: committed.removedDraftKey,
            collectionAction: committed.collectionAction,
            removedDraftGeneration: committed.removedDraftGeneration,
            collectionGeneration: committed.collectionGeneration,
            receiptID: committed.receiptID,
            transactionID: committed.transactionID,
            documentScope: committed.documentScope,
            documentEpoch: committed.documentEpoch + 1,
            payloadDigest: committed.payloadDigest,
            state: .committed,
            transactionGeneration: 3,
            previousDigest: CanvasStore.cleanupJournalDigest(committedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let staleData = try CanvasStore.cleanupEncodedData(staleSuccessor)
        try committedData.write(to: journalURL, options: .atomic)
        try staleData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == committedData)
        #expect(try Data(contentsOf: candidateURL) == staleData)
    }

    @Test("cleanup successor with a foreign document scope is rejected")
    func foreignCleanupSuccessorLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let foreign = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: CanvasStore.canvasDraftKey(for: UUID()),
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let foreignData = try CanvasStore.cleanupEncodedData(foreign)
        try preparedData.write(to: journalURL, options: .atomic)
        try foreignData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == foreignData)
    }

    @Test("duplicate cleanup transaction receipt is fail-closed")
    func duplicateCleanupTransactionReceiptLeavesOwnedStateUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalData = try CanvasStore.cleanupEncodedData(journal)
        let receipt = CanvasCleanupReceipt(
            sessionRootPath: journal.sessionRootPath,
            removedDraftKey: journal.removedDraftKey,
            receiptID: UUID().uuidString,
            removedDraftGeneration: journal.removedDraftGeneration,
            collectionGeneration: journal.collectionGeneration,
            transactionID: journal.transactionID,
            documentScope: journal.documentScope,
            transactionGeneration: journal.transactionGeneration,
            checkpointDigest: String(repeating: "0", count: 64),
            journalDigest: CanvasStore.cleanupJournalDigest(journalData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let receiptURL = CanvasStore.cleanupReceiptURL(at: drafts.directory)
        let receiptData = try CanvasStore.cleanupEncodedData(receipt)
        try journalData.write(to: journalURL, options: .atomic)
        try receiptData.write(to: receiptURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: receiptURL) == receiptData)

        let foreignReceipt = CanvasCleanupReceipt(
            sessionRootPath: journal.sessionRootPath,
            removedDraftKey: journal.removedDraftKey,
            receiptID: UUID().uuidString,
            removedDraftGeneration: journal.removedDraftGeneration,
            collectionGeneration: journal.collectionGeneration,
            transactionID: UUID(),
            documentScope: journal.documentScope,
            transactionGeneration: journal.transactionGeneration,
            checkpointDigest: journal.checkpointDigest,
            journalDigest: CanvasStore.cleanupJournalDigest(journalData)
        )
        let foreignReceiptData = try CanvasStore.cleanupEncodedData(foreignReceipt)
        try foreignReceiptData.write(to: receiptURL, options: .atomic)
        let foreignRestore = CanvasStore()
        foreignRestore.attachDraftStore(drafts)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == journalData)
        #expect(try Data(contentsOf: receiptURL) == foreignReceiptData)
    }

    @Test("cleanup successor replacement after identity readback is rejected")
    func replacedCleanupSuccessorLeavesDraftAndPrimaryJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let replacement = CanvasCleanupJournal(
            sessionRootPath: committed.sessionRootPath,
            removedDraftKey: committed.removedDraftKey,
            collectionAction: committed.collectionAction,
            removedDraftGeneration: committed.removedDraftGeneration,
            collectionGeneration: committed.collectionGeneration,
            receiptID: committed.receiptID,
            transactionID: UUID(),
            documentScope: committed.documentScope,
            state: .committed,
            transactionGeneration: committed.transactionGeneration,
            previousDigest: committed.previousDigest
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let candidateData = try CanvasStore.cleanupEncodedData(committed)
        let replacementData = try CanvasStore.cleanupEncodedData(replacement)
        try preparedData.write(to: journalURL, options: .atomic)
        try candidateData.write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.cleanupAfterCandidateReadHook = {
            try? replacementData.write(to: candidateURL, options: .atomic)
        }
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: candidateURL) == replacementData)
    }

    @Test("cleanup marker hardlink and symlink substitutions are rejected")
    func substitutedCleanupMarkerIdentityLeavesStateUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let markerTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-cleanup-marker-target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: markerTarget) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let committedData = try CanvasStore.cleanupEncodedData(committed)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        try preparedData.write(to: journalURL, options: .atomic)
        try committedData.write(to: markerTarget, options: .atomic)
        try FileManager.default.linkItem(at: markerTarget, to: candidateURL)

        let hardlinkRestore = CanvasStore()
        hardlinkRestore.attachDraftStore(drafts)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(try Data(contentsOf: markerTarget) == committedData)
        #expect(FileManager.default.fileExists(atPath: candidateURL.path))

        try FileManager.default.removeItem(at: candidateURL)
        try FileManager.default.createSymbolicLink(at: candidateURL, withDestinationURL: markerTarget)
        let symlinkRestore = CanvasStore()
        symlinkRestore.attachDraftStore(drafts)
        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: candidateURL.path))
                    == markerTarget.path)
    }

    @Test("cleanup payload digest mismatch is fail-closed")
    func mismatchedCleanupPayloadDigestLeavesJournalUntouched() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1),
            payloadDigest: String(repeating: "0", count: 64)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let journalData = try CanvasStore.cleanupEncodedData(journal)
        try journalData.write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == journalData)
    }

    @Test("partial committed cleanup successor preserves primary journal")
    func partialCommittedSuccessorPreservesPrimaryJournal() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let prepared = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let preparedData = try CanvasStore.cleanupEncodedData(prepared)
        let committed = CanvasCleanupJournal(
            sessionRootPath: prepared.sessionRootPath,
            removedDraftKey: prepared.removedDraftKey,
            collectionAction: prepared.collectionAction,
            removedDraftGeneration: prepared.removedDraftGeneration,
            collectionGeneration: prepared.collectionGeneration,
            receiptID: prepared.receiptID,
            transactionID: prepared.transactionID,
            documentScope: prepared.documentScope,
            state: .committed,
            transactionGeneration: 2,
            previousDigest: CanvasStore.cleanupJournalDigest(preparedData)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        let candidateURL = CanvasStore.cleanupJournalCandidateURL(at: drafts.directory)
        let committedData = try CanvasStore.cleanupEncodedData(committed)
        try preparedData.write(to: journalURL, options: .atomic)
        try Data(committedData.dropLast()).write(to: candidateURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(try Data(contentsOf: journalURL) == preparedData)
        #expect(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @Test("matching cleanup generations complete idempotently")
    func matchingCleanupGenerationsComplete() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let keptIDs = [UUID(), UUID()]
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let removedDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(key: removedKey, payload: try JSONEncoder().encode(removedDraft))
        #expect(drafts.flushNow(key: removedKey))
        let removedURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let removedGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        let replacement = CanvasCollectionSnapshot(
            currentCanvasID: keptIDs[0].uuidString,
            documents: keptIDs.map { id in
                makeCollectionMeta(id: id, draftKey: CanvasStore.canvasDraftKey(for: id))
            }
        )
        let oldCollection = CanvasCollectionSnapshot(
            currentCanvasID: keptIDs[0].uuidString,
            documents: [makeCollectionMeta(
                id: removedID,
                draftKey: removedKey
            )] + keptIDs.map { id in
                makeCollectionMeta(id: id, draftKey: CanvasStore.canvasDraftKey(for: id))
            }
        )
        try CanvasStore.cleanupEncodedData(oldCollection).write(
            to: drafts.directory.appendingPathComponent(CanvasStore.collectionFileName),
            options: .atomic
        )
        let collectionGeneration = try #require(CanvasStore.cleanupFileGeneration(
            at: drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        ))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "replace",
            replacementCollection: replacement,
            removedDraftGeneration: removedGeneration,
            collectionGeneration: collectionGeneration
        )
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(!drafts.hasDraft(key: removedKey))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(restored.canvasDocuments.map(\.id) == keptIDs)
    }

    @Test("new draft generation is never removed by an old cleanup journal")
    func oldCleanupJournalCannotRemoveNewDraftGeneration() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let oldDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "old")]),
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let oldData = try JSONEncoder().encode(oldDraft)
        drafts.scheduleSave(key: removedKey, payload: oldData)
        #expect(drafts.flushNow(key: removedKey))
        let removedURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let oldGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        let newDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "new")]),
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let newData = try replacementDraftEnvelopeData(
            at: removedURL, payload: JSONEncoder().encode(newDraft)
        )
        let oldEnvelopeData = try Data(contentsOf: removedURL)
        try newData.write(to: removedURL)
        let newGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        #expect(oldGeneration.device == newGeneration.device)
        #expect(oldGeneration.inode == newGeneration.inode)
        #expect(oldGeneration.digest != newGeneration.digest)
        #expect(oldEnvelopeData.count == newData.count)
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "remove",
            removedDraftGeneration: oldGeneration,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: removedKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let saved = try #require(drafts.load(key: removedKey))
        let decoded = try JSONDecoder().decode(CanvasDraft.self, from: saved)
        #expect(decoded.nodes.first?.title == "new")
    }

    @Test("symlinked cleanup draft is never cleared")
    func symlinkedCleanupDraftIsNeverCleared() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(key: removedKey, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: removedKey))
        let removedURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let oldGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-cleanup-sentinel-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: sentinel) }
        try Data("preserve".utf8).write(to: sentinel, options: .atomic)
        try FileManager.default.removeItem(at: removedURL)
        try FileManager.default.createSymbolicLink(at: removedURL, withDestinationURL: sentinel)
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "remove",
            removedDraftGeneration: oldGeneration,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: removedURL.path)) == sentinel.path)
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "preserve")
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("cleanup draft replacement between checks fails closed")
    func cleanupDraftReplacementBetweenChecksFailsClosed() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let oldDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "old")]),
            savedAt: Date(timeIntervalSince1970: 1)
        )
        drafts.scheduleSave(key: removedKey, payload: try JSONEncoder().encode(oldDraft))
        #expect(drafts.flushNow(key: removedKey))
        let removedURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let oldGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        let newDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "new")]),
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "remove",
            removedDraftGeneration: oldGeneration,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let newEnvelopeData = try replacementDraftEnvelopeData(
            at: removedURL, payload: JSONEncoder().encode(newDraft)
        )
        let restored = CanvasStore()
        restored.cleanupBeforeDraftClearHook = {
            try? newEnvelopeData.write(to: removedURL)
        }
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: removedKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let saved = try #require(drafts.load(key: removedKey))
        let decoded = try JSONDecoder().decode(CanvasDraft.self, from: saved)
        #expect(decoded.nodes.first?.title == "new")
    }

    @Test("new collection index generation is never overwritten by an old cleanup journal")
    func oldCleanupJournalCannotOverwriteNewCollectionGeneration() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let oldIDs = [UUID(), UUID()]
        let newIDs = [UUID(), UUID()]
        let oldSnapshot = CanvasCollectionSnapshot(
            currentCanvasID: oldIDs[0].uuidString,
            documents: oldIDs.map { makeCollectionMeta(id: $0, draftKey: CanvasStore.canvasDraftKey(for: $0)) }
        )
        let newSnapshot = CanvasCollectionSnapshot(
            currentCanvasID: newIDs[0].uuidString,
            documents: newIDs.map { makeCollectionMeta(id: $0, draftKey: CanvasStore.canvasDraftKey(for: $0)) }
        )
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        let oldData = try CanvasStore.cleanupEncodedData(oldSnapshot)
        try oldData.write(to: collectionURL)
        let oldGeneration = try #require(CanvasStore.cleanupFileGeneration(at: collectionURL))
        let newData = try CanvasStore.cleanupEncodedData(newSnapshot)
        try newData.write(to: collectionURL)
        let newGeneration = try #require(CanvasStore.cleanupFileGeneration(at: collectionURL))
        #expect(oldGeneration.device == newGeneration.device)
        #expect(oldGeneration.inode == newGeneration.inode)
        #expect(oldGeneration.digest != newGeneration.digest)
        #expect(oldData.count == newData.count)
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: CanvasStore.canvasDraftKey(for: UUID()),
            collectionAction: "replace",
            replacementCollection: oldSnapshot,
            collectionGeneration: oldGeneration
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        let saved = try Data(contentsOf: collectionURL)
        #expect(try JSONDecoder().decode(CanvasCollectionSnapshot.self, from: saved) == newSnapshot)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("oversized cleanup digest input fails closed")
    func oversizedCleanupDigestInputFailsClosed() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        try FileManager.default.createDirectory(at: drafts.draftsDirectory, withIntermediateDirectories: true)
        let oversizedURL = drafts.draftsDirectory.appendingPathComponent("canvas.oversized.json")
        let oversizedData = Data(
            repeating: 0x41,
            count: CanvasStore.cleanupFileDigestReadLimit + 1
        )
        try oversizedData.write(to: oversizedURL, options: .atomic)

        #expect(CanvasStore.cleanupFileGeneration(at: oversizedURL) == nil)
        #expect(FileManager.default.fileExists(atPath: oversizedURL.path))
    }

    @Test("cleanup replacement collection limits enforce exact boundaries")
    func cleanupReplacementCollectionLimitsEnforceExactBoundaries() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        func snapshot(ids: [UUID]) -> CanvasCollectionSnapshot {
            CanvasCollectionSnapshot(
                currentCanvasID: ids[0].uuidString,
                documents: ids.map { id in
                    makeCollectionMeta(
                        id: id,
                        draftKey: CanvasStore.canvasDraftKey(for: id)
                    )
                }
            )
        }

        let entryIDs = (0..<CanvasStore.cleanupCollectionEntryLimit).map { _ in UUID() }
        let entryLimitSnapshot = snapshot(ids: entryIDs)
        let entryOverflowSnapshot = snapshot(ids: entryIDs + [UUID()])
        #expect(CanvasStore.cleanupReplacementCollectionData(
            entryLimitSnapshot,
            excluding: "canvas.excluded"
        ) != nil)
        #expect(CanvasStore.cleanupReplacementCollectionData(
            entryOverflowSnapshot,
            excluding: "canvas.excluded"
        ) == nil)

        let sizedIDs = [UUID(), UUID()]
        func sizedSnapshot(nameLength: Int) -> CanvasCollectionSnapshot {
            CanvasCollectionSnapshot(
                currentCanvasID: sizedIDs[0].uuidString,
                documents: sizedIDs.map { id in
                    CanvasCollectionMeta(
                        id: id,
                        name: String(repeating: "x", count: nameLength),
                        draftKey: CanvasStore.canvasDraftKey(for: id)
                    )
                }
            )
        }
        var low = 0
        var high = CanvasStore.cleanupCollectionBytesLimit
        while low < high {
            let midpoint = (low + high + 1) / 2
            let data = try CanvasStore.cleanupEncodedData(sizedSnapshot(nameLength: midpoint))
            if data.count <= CanvasStore.cleanupCollectionBytesLimit {
                low = midpoint
            } else {
                high = midpoint - 1
            }
        }
        let byteLimitSnapshot = sizedSnapshot(nameLength: low)
        let byteOverflowSnapshot = sizedSnapshot(nameLength: low + 1)
        #expect(try CanvasStore.cleanupEncodedData(byteLimitSnapshot).count <= CanvasStore.cleanupCollectionBytesLimit)
        #expect(try CanvasStore.cleanupEncodedData(byteOverflowSnapshot).count > CanvasStore.cleanupCollectionBytesLimit)
        #expect(CanvasStore.cleanupReplacementCollectionData(
            byteLimitSnapshot,
            excluding: "canvas.excluded"
        ) != nil)
        #expect(CanvasStore.cleanupReplacementCollectionData(
            byteOverflowSnapshot,
            excluding: "canvas.excluded"
        ) == nil)
        let boundedJournal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: "canvas.excluded",
            collectionAction: "replace",
            replacementCollection: byteLimitSnapshot
        )
        let oversizedJournal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: "canvas.excluded",
            collectionAction: "replace",
            replacementCollection: byteOverflowSnapshot
        )
        let boundedPayload = try #require(
            CanvasStore.cleanupPayloadData(for: boundedJournal)
        )
        #expect(boundedPayload.count <= CanvasStore.cleanupPayloadBytesLimit)
        #expect(CanvasStore.cleanupPayloadData(for: oversizedJournal) == nil)

        let markerJournalAtLimit = Data(
            repeating: 0x41,
            count: CanvasStore.cleanupJournalBytesLimit
        )
        let markerReceiptAtLimit = Data(
            repeating: 0x42,
            count: CanvasStore.cleanupReceiptBytesLimit
        )
        #expect(CanvasStore.cleanupMarkerHistoryIsBounded(
            journalData: markerJournalAtLimit,
            receiptData: markerReceiptAtLimit
        ))
        #expect(!CanvasStore.cleanupMarkerHistoryIsBounded(
            journalData: markerJournalAtLimit,
            receiptData: markerReceiptAtLimit,
            candidateData: Data(repeating: 0x43, count: 1024 * 1024 + 1)
        ))
    }

    @Test("cleanup JSON rejects duplicate keys, deep nesting, and wide objects")
    func cleanupJSONStrictnessRejectsAmbiguousStructure() {
        #expect(CanvasStore.cleanupJSONStructureIsStrict(Data("{}".utf8)))
        #expect(!CanvasStore.cleanupJSONStructureIsStrict(
            Data(#"{"schemaVersion":1,"schemaVersion":1}"#.utf8)
        ))
        let deep = String(repeating: "[", count: CanvasStore.cleanupJSONMaxDepth + 1)
            + "0"
            + String(repeating: "]", count: CanvasStore.cleanupJSONMaxDepth + 1)
        #expect(!CanvasStore.cleanupJSONStructureIsStrict(Data(deep.utf8)))
        let wide = "{"
            + (0...CanvasStore.cleanupJSONObjectFieldLimit)
                .map { "\"field\($0)\":0" }
                .joined(separator: ",")
            + "}"
        #expect(!CanvasStore.cleanupJSONStructureIsStrict(Data(wide.utf8)))
    }

    @Test("cleanup replacement requires canonical entry draft keys")
    func cleanupReplacementRejectsNonCanonicalEntryDraftKeys() {
        let ids = [
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        ]
        let replacement = CanvasCollectionSnapshot(
            currentCanvasID: ids[0].uuidString,
            documents: [
                makeCollectionMeta(
                    id: ids[0],
                    draftKey: "canvas.\(ids[0].uuidString.lowercased())"
                ),
                makeCollectionMeta(
                    id: ids[1],
                    draftKey: CanvasStore.canvasDraftKey(for: ids[1])
                )
            ]
        )

        #expect(CanvasStore.cleanupReplacementCollectionData(
            replacement,
            excluding: "canvas.excluded"
        ) == nil)
    }

    @Test("duplicate-key cleanup journal never clears a draft")
    func duplicateKeyCleanupJournalNeverClearsDraft() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let root = drafts.directory.standardizedFileURL.path
        let duplicateJournal = """
        {"schemaVersion":1,"sessionRootPath":"\(root)","removedDraftKey":"\(DraftStore.canvasKey)","collectionAction":"remove","collectionAction":"remove"}
        """
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try Data(duplicateJournal.utf8).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("confusable-key cleanup journal never clears a draft")
    func confusableKeyCleanupJournalNeverClearsDraft() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let canonical = String(
            decoding: try CanvasStore.cleanupEncodedData(journal),
            as: UTF8.self
        )
        let confusable = canonical.replacingOccurrences(
            of: "\"schemaVersion\"",
            with: "\"schemaVersi\\u006Fn\""
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try Data(confusable.utf8).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("oversized cleanup journal never clears a draft")
    func oversizedCleanupJournalNeverClearsDraft() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try Data(repeating: 0x20, count: CanvasStore.cleanupJournalBytesLimit + 1)
            .write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("replaced cleanup journal fails the identity fence before clear")
    func replacedCleanupJournalFailsIdentityFence() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(DraftStore.canvasKey).json")
        let generation = try #require(CanvasStore.cleanupFileGeneration(at: draftURL))
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove",
            removedDraftGeneration: generation,
            collectionGeneration: CanvasFileGeneration(device: 1, inode: 1)
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.cleanupBeforeDraftClearHook = {
            try? Data("replaced".utf8).write(to: journalURL, options: .atomic)
        }
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(String(data: try Data(contentsOf: journalURL), encoding: .utf8) == "replaced")
    }

    @Test("oversized cleanup collection never partially clears drafts")
    func oversizedCleanupCollectionNeverPartiallyClearsDrafts() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let removedID = UUID()
        let removedKey = CanvasStore.canvasDraftKey(for: removedID)
        let removedDraft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(key: removedKey, payload: try JSONEncoder().encode(removedDraft))
        #expect(drafts.flushNow(key: removedKey))
        let removedURL = drafts.draftsDirectory.appendingPathComponent("\(removedKey).json")
        let removedGeneration = try #require(CanvasStore.cleanupFileGeneration(at: removedURL))
        let overflowIDs = (0...CanvasStore.cleanupCollectionEntryLimit).map { _ in UUID() }
        let replacement = CanvasCollectionSnapshot(
            currentCanvasID: overflowIDs[0].uuidString,
            documents: overflowIDs.map { id in
                makeCollectionMeta(id: id, draftKey: CanvasStore.canvasDraftKey(for: id))
            }
        )
        let existingIDs = [UUID(), UUID()]
        let existingCollection = CanvasCollectionSnapshot(
            currentCanvasID: existingIDs[0].uuidString,
            documents: existingIDs.map { id in
                makeCollectionMeta(id: id, draftKey: CanvasStore.canvasDraftKey(for: id))
            }
        )
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        try CanvasStore.cleanupEncodedData(existingCollection).write(to: collectionURL, options: .atomic)
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.standardizedFileURL.path,
            removedDraftKey: removedKey,
            collectionAction: "replace",
            replacementCollection: replacement,
            removedDraftGeneration: removedGeneration
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(drafts.hasDraft(key: removedKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        let savedCollection = try Data(contentsOf: collectionURL)
        #expect(try JSONDecoder().decode(CanvasCollectionSnapshot.self, from: savedCollection) == existingCollection)
    }

    @Test("corrupt canvas cleanup journal is fail closed")
    func corruptCleanupJournalDoesNotTouchOtherFiles() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try Data("not-json".utf8).write(to: journalURL, options: .atomic)
        let sentinel = drafts.directory.appendingPathComponent("non-owned.txt")
        try Data("preserve".utf8).write(to: sentinel, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "preserve")
    }

    @Test("wrong-session canvas cleanup journal is fail closed")
    func wrongSessionCleanupJournalDoesNotTouchOtherFiles() throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "owned")]),
            savedAt: Date()
        )
        drafts.scheduleSave(
            key: DraftStore.canvasKey,
            payload: try JSONEncoder().encode(draft)
        )
        #expect(drafts.flushNow(key: DraftStore.canvasKey))
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let journal = CanvasCleanupJournal(
            sessionRootPath: drafts.directory.appendingPathComponent("other-session").path,
            removedDraftKey: DraftStore.canvasKey,
            collectionAction: "remove"
        )
        let journalURL = CanvasStore.cleanupJournalURL(at: drafts.directory)
        try CanvasStore.cleanupEncodedData(journal).write(to: journalURL, options: .atomic)
        let sentinel = drafts.directory.appendingPathComponent("non-owned.txt")
        try Data("preserve".utf8).write(to: sentinel, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)

        #expect(drafts.hasDraft(key: DraftStore.canvasKey))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "preserve")
    }

    @Test func legacyCollectionWithoutCurrentCanvasIDFallsBackWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: nil,
            documents: [
                makeCollectionMeta(id: firstID, draftKey: "canvas.\(firstID.uuidString)"),
                makeCollectionMeta(id: secondID, draftKey: "canvas.\(secondID.uuidString)")
            ],
            legacyArray: true
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.currentCanvasID == firstID)
        #expect(restored.collectionRestoreDiagnostic == .missingCurrentCanvasID)
    }

    @Test func invalidCurrentCanvasIDFallsBackWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: "not-a-uuid",
            documents: [
                makeCollectionMeta(id: firstID, draftKey: "canvas.\(firstID.uuidString)"),
                makeCollectionMeta(id: secondID, draftKey: "canvas.\(secondID.uuidString)")
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.currentCanvasID == firstID)
        #expect(restored.collectionRestoreDiagnostic == .invalidCurrentCanvasID("not-a-uuid"))
    }

    @Test("noncanonical current canvas ID is rejected")
    func noncanonicalCurrentCanvasIDIsRejected() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let noncanonicalID = firstID.uuidString.lowercased()
        try writeCollection(
            to: drafts,
            currentCanvasID: noncanonicalID,
            documents: [
                makeCollectionMeta(id: firstID, draftKey: CanvasStore.canvasDraftKey(for: firstID)),
                makeCollectionMeta(id: secondID, draftKey: CanvasStore.canvasDraftKey(for: secondID))
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.currentCanvasID == firstID)
        #expect(restored.collectionRestoreDiagnostic == .invalidCurrentCanvasID(noncanonicalID))
    }

    @Test func unknownCurrentCanvasIDFallsBackWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        let unknownID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: unknownID.uuidString,
            documents: [
                makeCollectionMeta(id: firstID, draftKey: "canvas.\(firstID.uuidString)"),
                makeCollectionMeta(id: secondID, draftKey: "canvas.\(secondID.uuidString)")
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.currentCanvasID == firstID)
        #expect(restored.collectionRestoreDiagnostic == .unknownCurrentCanvasID(unknownID))
    }

    @Test func corruptCollectionIsQuarantinedWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        try Data("not-json".utf8).write(to: collectionURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(!FileManager.default.fileExists(atPath: collectionURL.path))
        #expect(FileManager.default.fileExists(
            atPath: CanvasStore.collectionQuarantineURL(at: drafts.directory).path
        ))
    }

    @Test func duplicateCanvasIDCollectionIsRejectedWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let duplicateID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: duplicateID.uuidString,
            documents: [
                makeCollectionMeta(id: duplicateID, draftKey: "canvas.first"),
                makeCollectionMeta(id: duplicateID, draftKey: "canvas.second")
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .duplicateCanvasID(duplicateID))
        #expect(restored.canvasDocuments.count == 1)
    }

    @Test func duplicateDraftKeyCollectionIsRejectedWithDiagnostic() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: firstID.uuidString,
            documents: [
                makeCollectionMeta(id: firstID, draftKey: "canvas.duplicate"),
                makeCollectionMeta(id: secondID, draftKey: "canvas.duplicate")
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .duplicateDraftKey("canvas.duplicate"))
        #expect(restored.canvasDocuments.count == 1)
    }

    @Test("collection cannot consume a chat draft key")
    func crossConsumerDraftKeyCollectionIsRejected() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [
                makeCollectionMeta(
                    id: canvasID,
                    draftKey: DraftStore.chatDraftKey(sessionID: UUID())
                ),
                makeCollectionMeta(id: secondID, draftKey: CanvasStore.canvasDraftKey(for: secondID))
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
    }

    @Test("legacy canvas draft key stays bound to the first entry")
    func legacyCanvasDraftKeyCannotMoveToAnotherCollectionEntry() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: firstID.uuidString,
            documents: [
                makeCollectionMeta(id: firstID, draftKey: CanvasStore.canvasDraftKey(for: firstID)),
                makeCollectionMeta(id: secondID, draftKey: DraftStore.canvasKey)
            ]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
    }

    @Test("oversized collection restore is fail closed")
    func oversizedCollectionRestoreIsFailClosed() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let firstID = UUID()
        let secondID = UUID()
        var oversized = makeCollectionMeta(
            id: firstID,
            draftKey: CanvasStore.canvasDraftKey(for: firstID)
        )
        oversized.name = String(repeating: "x", count: CanvasStore.cleanupCollectionBytesLimit)
        let data = try CanvasStore.cleanupEncodedData(CanvasCollectionSnapshot(
            currentCanvasID: firstID.uuidString,
            documents: [
                oversized,
                makeCollectionMeta(id: secondID, draftKey: CanvasStore.canvasDraftKey(for: secondID))
            ]
        ))
        #expect(data.count > CanvasStore.cleanupCollectionBytesLimit)
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        try data.write(to: collectionURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(!FileManager.default.fileExists(atPath: collectionURL.path))
        #expect(FileManager.default.fileExists(
            atPath: CanvasStore.collectionQuarantineURL(at: drafts.directory).path
        ))
    }

    @Test("collection restore rejects unknown fields")
    func collectionRestoreRejectsUnknownFields() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        let snapshot = CanvasCollectionSnapshot(
            currentCanvasID: canvasID.uuidString,
            documents: [makeCollectionMeta(
                id: canvasID,
                draftKey: CanvasStore.canvasDraftKey(for: canvasID)
            )]
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: CanvasStore.cleanupEncodedData(snapshot),
                options: [.mutableContainers]
            ) as? [String: Any]
        )
        object["unexpected"] = true
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        try data.write(to: collectionURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(!FileManager.default.fileExists(atPath: collectionURL.path))
    }

    @Test("future collection schema is quarantined")
    func futureCollectionSchemaIsQuarantined() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        var snapshot = CanvasCollectionSnapshot(
            currentCanvasID: canvasID.uuidString,
            documents: [makeCollectionMeta(
                id: canvasID,
                draftKey: CanvasStore.canvasDraftKey(for: canvasID)
            )]
        )
        snapshot.schemaVersion = CanvasCollectionSnapshot.currentSchemaVersion + 1
        let data = try CanvasStore.cleanupEncodedData(snapshot)
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let collectionURL = drafts.directory.appendingPathComponent(CanvasStore.collectionFileName)
        try data.write(to: collectionURL, options: .atomic)

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(!FileManager.default.fileExists(atPath: collectionURL.path))
        #expect(FileManager.default.fileExists(
            atPath: CanvasStore.collectionQuarantineURL(at: drafts.directory).path
        ))
    }

    @Test("future collection entry schema is rejected")
    func futureCollectionEntrySchemaIsRejected() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        var meta = makeCollectionMeta(
            id: canvasID,
            draftKey: CanvasStore.canvasDraftKey(for: canvasID)
        )
        meta.schemaVersion = CanvasCollectionMeta.currentSchemaVersion + 1
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [meta]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: drafts.directory.appendingPathComponent(CanvasStore.collectionFileName).path
        ))
    }

    @Test("single-entry collection marker is rejected")
    func singleEntryCollectionMarkerIsRejected() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [makeCollectionMeta(
                id: canvasID,
                draftKey: CanvasStore.canvasDraftKey(for: canvasID)
            )]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: drafts.directory.appendingPathComponent(CanvasStore.collectionFileName).path
        ))
    }

    @Test("corrupt canvas draft blocks collection restore")
    func corruptCanvasDraftBlocksCollectionRestore() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        let draftKey = CanvasStore.canvasDraftKey(for: canvasID)
        drafts.scheduleSave(key: draftKey, payload: Data("not-canvas-json".utf8))
        #expect(drafts.flushNow(key: draftKey))
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [makeCollectionMeta(id: canvasID, draftKey: draftKey)]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(drafts.hasDraft(key: draftKey))
    }

    @Test("future canvas draft blocks collection restore")
    func futureCanvasDraftBlocksCollectionRestore() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        let draftKey = CanvasStore.canvasDraftKey(for: canvasID)
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CanvasDraft(graph: NodeGraph(), groups: [], savedAt: Date())),
                options: [.mutableContainers]
            ) as? [String: Any]
        )
        object["schemaVersion"] = 4
        let futurePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        drafts.scheduleSave(key: draftKey, payload: futurePayload)
        #expect(drafts.flushNow(key: draftKey))
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [makeCollectionMeta(id: canvasID, draftKey: draftKey)]
        )

        let restored = CanvasStore()
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.collectionRestoreDiagnostic == .corruptCollection)
        #expect(restored.canvasDocuments.count == 1)
        #expect(drafts.hasDraft(key: draftKey))
    }

    @Test("replaced canvas draft is not applied after restore read")
    func replacedCanvasDraftIsNotAppliedAfterRestoreRead() async throws {
        let drafts = try makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let canvasID = UUID()
        let draftKey = CanvasStore.canvasDraftKey(for: canvasID)
        let draft = CanvasDraft(
            graph: NodeGraph(nodes: [CanvasNode(type: "text", title: "original")]),
            groups: [],
            savedAt: Date()
        )
        drafts.scheduleSave(key: draftKey, payload: try JSONEncoder().encode(draft))
        #expect(drafts.flushNow(key: draftKey))
        let secondID = UUID()
        try writeCollection(
            to: drafts,
            currentCanvasID: canvasID.uuidString,
            documents: [
                makeCollectionMeta(id: canvasID, draftKey: draftKey),
                makeCollectionMeta(id: secondID, draftKey: CanvasStore.canvasDraftKey(for: secondID))
            ]
        )
        let draftURL = drafts.draftsDirectory.appendingPathComponent("\(draftKey).json")

        let restored = CanvasStore()
        restored.collectionRestoreBeforeApplyHook = {
            try? Data("replaced".utf8).write(to: draftURL, options: .atomic)
        }
        restored.attachDraftStore(drafts)
        try await awaitCollectionRestore(restored)

        #expect(restored.graph.nodes.isEmpty)
        #expect(String(data: try Data(contentsOf: draftURL), encoding: .utf8) == "replaced")
    }

    @Test func lateDAGWritebackAfterCanvasSwitchIsRejectedEvenWhenGraphRevisionMatches() throws {
        let canvas = CanvasStore()
        let node = try #require(canvas.addNode(ofType: "text"))
        let sourceGraph = canvas.graph
        let sourceCanvasID = canvas.currentCanvasID
        canvas.isRunning = true
        canvas.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: UUID(),
                canvasID: sourceCanvasID,
                graphRevision: sourceGraph.structuralRevision
            )
        )

        let switched = canvas.createCanvas(name: "迟到写回目标")
        #expect(switched.id != sourceCanvasID)
        canvas.graph = sourceGraph
        let result = DAGExecutionResult(
            statuses: [node.id: .succeeded],
            outputs: [:],
            wasCancelled: false,
            skipReasons: [:]
        )

        canvas.finishRun(result, before: [:])

        #expect(canvas.lastResult == nil, "旧画布结果不得写入当前画布")
        #expect(canvas.graph.node(id: node.id)?.status == .pending)
        #expect(canvas.statusMessage?.contains("画布") == true)
    }
}
