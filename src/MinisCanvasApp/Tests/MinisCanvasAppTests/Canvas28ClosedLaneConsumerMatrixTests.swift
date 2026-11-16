import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// v38补7: production closed lane only. Setup-owned dormant Canvas snapshots
/// are separate from production actions. No CanvasStore is ever activated.
@Suite("D-CANVAS-28 closed lane remaining production consumers")
@MainActor
struct Canvas28ClosedLaneConsumerMatrixTests {
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let root: URL
        let defaults: UserDefaults
    }

    private func fixture(_ label: String) throws -> Fixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("canvas28-remaining-" + label + "-" + UUID().uuidString)
        try #require(root.path.hasPrefix(profile.rootDirectory.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // Retain all owned files for the runner's evidence inventory.
        return Fixture(profile: profile, root: root, defaults: profile.makeUserDefaults())
    }

    private func assemble(_ f: Fixture) async throws -> BridgeStore {
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: f.defaults),
            preferencesDefaults: f.defaults,
            logManager: f.profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: f.root),
            sessionStore: SessionStore(directory: f.root),
            canvasFactory: { preferences in
                Issue.record("closed lane unexpectedly invoked Canvas factory")
                return CanvasStore(preferencesDefaults: preferences)
            },
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase3NonCanvas
        )
        await bridge.attachProductionServices(
            sessionDirectory: f.root,
            mcpManager: MCPServerManager(fileURL: f.root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: f.root.appendingPathComponent("skills")),
            externalNetworkAllowed: false
        ).value
        try #require(bridge.chat.draftStore != nil)
        try #require(bridge.chat.sessionStore != nil)
        #expect(bridge.canvasIfAvailable == nil)
        #expect(bridge.canvasBoundaryIfAvailable == nil)
        #expect(bridge.canvasFeatureLane == .phase3NonCanvas)
        return bridge
    }

    private func canvasPayload(version: Int) throws -> Data {
        try JSONEncoder().encode(CanvasDraft(
            schemaVersion: version, savedAt: Date(timeIntervalSince1970: 1),
            nodes: [], edges: [], groups: []
        ))
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func seedExistingCanvas(_ f: Fixture, payload: Data) throws {
        let directory = f.root.appendingPathComponent("canvas/drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = DraftEnvelope(
            schemaVersion: DraftStore.currentSchemaVersion,
            savedAt: Date(timeIntervalSince1970: 1), payload: payload,
            payloadSHA256: sha(payload)
        )
        try JSONEncoder().encode(envelope).write(to: directory.appendingPathComponent("canvas.json"))
        let legacyDrafts = f.root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDrafts, withIntermediateDirectories: true)
        try Data("owned legacy Canvas draft".utf8).write(to: legacyDrafts.appendingPathComponent("canvas.json"))
        try Data("owned legacy Canvas collection".utf8).write(to: f.root.appendingPathComponent("canvas_collection.json"))
        try Data("owned legacy Canvas cleanup".utf8).write(to: f.root.appendingPathComponent("canvas_cleanup.json"))
    }

    /// Enumerate only four explicitly owned Canvas locations. Directories and
    /// files include inode/mode/mtime and file SHA; access times are excluded.
    private func canvasInventory(_ root: URL) throws -> [String: String] {
        let names = ["canvas", "drafts/canvas.json", "canvas_collection.json", "canvas_cleanup.json"]
        var result: [String: String] = [:]
        func record(_ url: URL) throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = try #require(attrs[.type] as? FileAttributeType)
            try #require(type == .typeDirectory || type == .typeRegular)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let hash = type == .typeRegular ? sha(try Data(contentsOf: url)) : "DIRECTORY"
            result[relative] = "\(type.rawValue)|inode=\(attrs[.systemFileNumber] ?? "nil")|device=\(attrs[.systemNumber] ?? "nil")|owner=\(attrs[.ownerAccountID] ?? "nil")|mode=\(attrs[.posixPermissions] ?? "nil")|mtime=\(attrs[.modificationDate] ?? "nil")|sha256=\(hash)"
        }
        for name in names {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try record(url)
            if name == "canvas" {
                let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
                for case let child as URL in enumerator {
                    try #require(result.count < 128)
                    try record(child)
                }
            }
        }
        return result
    }

    private func logInventory(_ stage: String, _ inventory: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("CANVAS28_INVENTORY stage=\(stage) json=\(String(decoding: try encoder.encode(inventory), as: UTF8.self))")
    }

    private func writeDraft(_ bridge: BridgeStore, _ text: String) throws -> (UUID, Data) {
        try #require(text.utf8.count >= 4_096)
        let session = bridge.chat.applyNewSession(title: "owned Canvas28 isolation session")
        let sessions = try #require(bridge.chat.sessionStore)
        try #require(sessions.loadSession(id: session.uuidString)?.id == session.uuidString)
        // Two production setter/flush generations on the same Chat key;
        // scheduleSave/flushNow cancels each pending debounced task. The
        // durable and cached result must be the latest accepted generation.
        bridge.chat.draftText = String(repeating: "owned superseded Chat generation ", count: 220)
        try #require(bridge.chat.flushPendingDraftForTermination())
        bridge.chat.draftText = text
        try #require(bridge.chat.flushPendingDraftForTermination())
        let drafts = try #require(bridge.chat.draftStore)
        let data = try Data(contentsOf: drafts.draftsDirectory.appendingPathComponent(DraftStore.chatDraftKey(sessionID: session) + ".json"))
        #expect(drafts.latestPayload(for: DraftStore.chatDraftKey(sessionID: session)) == Data(text.utf8))
        #expect(drafts.lastIOError(for: DraftStore.chatDraftKey(sessionID: session)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: drafts.draftsDirectory.path).filter { $0.contains(".tmp-") }.isEmpty)
        let envelope = try JSONDecoder().decode(DraftEnvelope.self, from: data)
        #expect(envelope.schemaVersion == DraftStore.currentSchemaVersion)
        #expect(envelope.payload == Data(text.utf8))
        #expect(envelope.payloadSHA256 == sha(Data(text.utf8)))
        return (session, data)
    }

    @Test("D-CANVAS-28 production closed Chat rebuild preserves absent and existing typed Canvas snapshots")
    func productionChatRebuildPreservesCanvasSnapshotMatrix() async throws {
        let cases: [(String, Data?)] = [
            ("absent", nil),
            ("currentCanvasDTO", try canvasPayload(version: 3)),
            ("equalVersionCanvasDTO", try canvasPayload(version: DraftStore.currentSchemaVersion)),
            ("futureCanvasDTO", try canvasPayload(version: 9_999)),
            ("corruptCanvasPayload", Data("{broken owned Canvas payload".utf8))
        ]
        for (label, payload) in cases {
            let f = try fixture(label)
            if let payload { try seedExistingCanvas(f, payload: payload) }
            let before = try canvasInventory(f.root)
            try logInventory(label + ":setupBaseline", before)
            let bridge = try await assemble(f)
            defer { bridge.chat.stopAllStreamingForSafety() }
            let text = String(repeating: "owned Chat survives \(label) Canvas payload ", count: 220)
            let (session, _) = try writeDraft(bridge, text)
            let reopened = try await assemble(f)
            defer { reopened.chat.stopAllStreamingForSafety() }
            try #require(reopened.chat.sessions.contains { $0.id == session })
            try #require(reopened.chat.applySwitchSession(id: session))
            #expect(reopened.chat.draftText == text)
            let draftStore = try #require(reopened.chat.draftStore)
            #expect(draftStore.directory == f.root)
            #expect(draftStore.load(key: DraftStore.chatDraftKey(sessionID: session)) == Data(text.utf8))
            #expect(try JSONDecoder().decode(DraftEnvelope.self, from: Data(contentsOf: draftStore.draftsDirectory.appendingPathComponent(DraftStore.chatDraftKey(sessionID: session) + ".json"))).payload == Data(text.utf8))
            #expect(draftStore.lastLoadError(for: DraftStore.chatDraftKey(sessionID: session)) == nil)
            // Flush the accepted restored long text so no timer outlives the
            // final inventory boundary. Same production synchronous seam.
            try #require(reopened.chat.flushPendingDraftForTermination())
            let after = try canvasInventory(f.root)
            try logInventory(label + ":productionAfterRebuild", after)
            #expect(after == before)
            let created = Set(after.keys).subtracting(before.keys).sorted()
            #expect(created.isEmpty)
            if payload == nil {
                #expect(after.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("canvas").path))
            }
            print("CANVAS28_CHAT_REBUILD case=\(label) session=\(session.uuidString) restored=\(reopened.chat.draftText == text) productionCreatedCanvas=\(created)")
        }
        print("CANVAS28_LIMIT CanvasStore.schema/locks/mediaLedger/assetCache/cleanupRollback=NOT_REACHABLE_CLOSED_LANE")
    }

    @Test("D-CANVAS-28 actual Chat SessionStore rejects Canvas DTO and preserves valid Chat recovery")
    func productionSessionConsumerRejectsWrongDomainCanvasPayloads() async throws {
        let cases: [(String, Data, Bool)] = [
            ("equalVersionCanvasDTO", try canvasPayload(version: DraftStore.currentSchemaVersion), true),
            ("currentCanvasDTO", try canvasPayload(version: 3), true),
            ("futureCanvasDTO", try canvasPayload(version: 9_999), true),
            ("corruptCanvasPayload", Data("{broken owned Canvas payload".utf8), false)
        ]
        for (label, wrongPayload, typed) in cases {
            let f = try fixture("reverse-" + label)
            try seedExistingCanvas(f, payload: wrongPayload)
            let before = try canvasInventory(f.root)
            try logInventory(label + ":reverseSetupBaseline", before)
            let bridge = try await assemble(f)
            defer { bridge.chat.stopAllStreamingForSafety() }
            let text = String(repeating: "owned valid Chat reverse domain \(label) ", count: 220)
            let (validID, _) = try writeDraft(bridge, text)
            let store = try #require(bridge.chat.sessionStore)
            #expect(store.directory == f.root)
            let wrongID = UUID().uuidString
            let wrongURL = store.sessionsDirectory.appendingPathComponent(wrongID + ".json")
            // Owned fault injection into the *actual production* SessionStore
            // namespace. Well-formed Canvas DTO is distinct from corrupt JSON.
            if typed { _ = try JSONDecoder().decode(CanvasDraft.self, from: wrongPayload) }
            try wrongPayload.write(to: wrongURL, options: .atomic)
            #expect(store.loadSession(id: wrongID) == nil)
            #expect(!store.listSessions().contains { $0.id == wrongID })
            var originalError = "NOT_OBSERVED"
            do {
                _ = try store.resumeMessages(sessionID: wrongID)
                Issue.record("production Chat consumer accepted wrong-domain Canvas payload")
            } catch let error as DecodingError {
                switch error {
                case .keyNotFound(let key, let context):
                    #expect(typed)
                    #expect(key.stringValue == "id")
                    #expect(context.codingPath.isEmpty)
                    originalError = "DecodingError.keyNotFound(id)"
                case .dataCorrupted:
                    #expect(!typed)
                    originalError = "DecodingError.dataCorrupted"
                default:
                    Issue.record("unexpected original DecodingError: \(error)")
                }
            } catch {
                Issue.record("unexpected original production error domain: \(error)")
            }
            #expect(originalError != "NOT_OBSERVED")
            #expect(try Data(contentsOf: wrongURL) == wrongPayload)
            #expect(try store.resumeMessages(sessionID: validID.uuidString).isEmpty)

            // A separate owned bad Chat draft exercises actual ChatStore
            // restart -> DraftStore version/integrity rejection + quarantine.
            // This is not misreported as an inner Canvas schema check.
            let badDraftID = bridge.chat.applyNewSession(title: "owned damaged draft recovery session")
            let badKey = DraftStore.chatDraftKey(sessionID: badDraftID)
            let drafts = try #require(bridge.chat.draftStore)
            let badEnvelope = DraftEnvelope(
                schemaVersion: typed ? DraftStore.currentSchemaVersion + 1 : DraftStore.currentSchemaVersion,
                savedAt: Date(timeIntervalSince1970: 1), payload: wrongPayload,
                payloadSHA256: typed ? sha(wrongPayload) : "owned-deliberately-invalid-digest"
            )
            let badBytes = try JSONEncoder().encode(badEnvelope)
            let badURL = drafts.draftsDirectory.appendingPathComponent(badKey + ".json")
            try badBytes.write(to: badURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: badURL.path)
            let reopened = try await assemble(f)
            defer { reopened.chat.stopAllStreamingForSafety() }
            #expect(!reopened.chat.sessions.contains { $0.id.uuidString == wrongID })
            try #require(reopened.chat.applySwitchSession(id: badDraftID))
            #expect(reopened.chat.draftText.isEmpty)
            let recoveredDrafts = try #require(reopened.chat.draftStore)
            let expectedDraftError: DraftLoadError = typed
                ? .futureVersion(found: DraftStore.currentSchemaVersion + 1, current: DraftStore.currentSchemaVersion)
                : .decodeFailed
            #expect(recoveredDrafts.lastLoadError(for: badKey) == expectedDraftError)
            #expect(recoveredDrafts.latestPayload(for: badKey) == nil)
            #expect(!FileManager.default.fileExists(atPath: badURL.path))
            let quarantined = try FileManager.default.contentsOfDirectory(at: recoveredDrafts.quarantineDirectory, includingPropertiesForKeys: nil)
            #expect(quarantined.count == 1)
            let preserved = try Data(contentsOf: try #require(quarantined.first))
            #expect(preserved == badBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: recoveredDrafts.draftsDirectory.path).filter { $0.contains(".tmp-") }.isEmpty)
            print("CANVAS28_CHAT_QUARANTINE case=\(label) actualLoadError=\(String(describing: recoveredDrafts.lastLoadError(for: badKey))) preservedSHA256=\(sha(preserved)) count=\(quarantined.count)")
            try #require(reopened.chat.applySwitchSession(id: validID))
            #expect(reopened.chat.draftText == text)
            try #require(reopened.chat.flushPendingDraftForTermination())
            let after = try canvasInventory(f.root)
            try logInventory(label + ":reverseProductionAfter", after)
            #expect(after == before)
            let created = Set(after.keys).subtracting(before.keys).sorted()
            #expect(created.isEmpty)
            print("CANVAS28_REVERSE case=\(label) actualConsumer=SessionStore.resumeMessages originalError=\(originalError) validChatRestored=\(reopened.chat.draftText == text) productionCreatedCanvas=\(created)")
        }
        print("CANVAS28_LIMIT CanvasStore.schema/locks/mediaLedger/assetCache/cleanupRollback=NOT_REACHABLE_CLOSED_LANE")
    }
}
