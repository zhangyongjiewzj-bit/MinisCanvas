import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// One missing D-CANVAS-28 runtime predicate. A dormant Canvas data root fails
/// its real DraftStore persistence path while the phase3 Chat consumer writes
/// and reloads successfully. No CanvasStore is activated. This intentionally
/// does not claim all Canvas schema/ledger/rollback domains have been observed.
@Suite("D-CANVAS-28 closed lane persistence failure")
@MainActor
struct Canvas28ClosedLanePersistenceFailureTests {
    @Test("D-CANVAS-28 failed dormant Canvas persistence cannot poison active Chat draft write and reload")
    func dormantCanvasWriteFailureLeavesProductionChatWritableAndReloadable() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("canvas28-closed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canvasRoot = root.appendingPathComponent("canvas", isDirectory: true)
        let blockedBytes = Data("synthetic dormant Canvas root is a regular file".utf8)
        try blockedBytes.write(to: canvasRoot)
        let defaults = profile.makeUserDefaults()
        var canvasFactoryCalls = 0
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: root),
            canvasFactory: { preferences in
                canvasFactoryCalls += 1
                return CanvasStore(preferencesDefaults: preferences)
            },
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase3NonCanvas
        )
        await bridge.attachProductionServices(
            sessionDirectory: root,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            externalNetworkAllowed: false
        ).value
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety() }
        let chatDrafts = try #require(chat.draftStore)
        let session = try #require(chat.activeSessionID)
        let chatKey = DraftStore.chatDraftKey(sessionID: session)
        let before = String(repeating: "synthetic Chat draft before Canvas failure ", count: 200)
        try #require(before.utf8.count >= 4_096)
        chat.draftText = before
        try #require(chat.flushPendingDraftForTermination())
        let chatURL = chatDrafts.draftsDirectory.appendingPathComponent(chatKey + ".json")
        let beforeEnvelope = try JSONDecoder().decode(DraftEnvelope.self, from: Data(contentsOf: chatURL))
        #expect(beforeEnvelope.payload == Data(before.utf8))
        let receiptsBefore = bridge.agentTaskStore.allReceipts()

        // This is the real persistence writer, not an executor failure stub.
        // A regular-file parent guarantees the directory/openat path fails.
        let canvasDrafts = DraftStore(directory: canvasRoot)
        let canvasPending = Data("synthetic Canvas pending payload".utf8)
        canvasDrafts.scheduleSave(key: DraftStore.canvasKey, payload: canvasPending)
        let canvasWriteFailed = !canvasDrafts.flushNow(key: DraftStore.canvasKey)
        #expect(canvasWriteFailed)
        #expect(canvasDrafts.lastIOError(for: DraftStore.canvasKey) != nil)
        #expect(canvasDrafts.latestPayload(for: DraftStore.canvasKey) == canvasPending)
        #expect(chatDrafts.latestPayload(for: chatKey) == Data(before.utf8))
        #expect(chatDrafts.lastIOError(for: chatKey) == nil)
        #expect(chatDrafts !== canvasDrafts)
        #expect(chatDrafts.directory != canvasDrafts.directory)

        let after = String(repeating: "synthetic Chat draft after Canvas failure ", count: 200)
        try #require(after.utf8.count >= 4_096)
        chat.draftText = after
        let chatWriteSucceeded = chat.flushPendingDraftForTermination()
        #expect(chatWriteSucceeded)
        let afterEnvelope = try JSONDecoder().decode(DraftEnvelope.self, from: Data(contentsOf: chatURL))
        #expect(afterEnvelope.payload == Data(after.utf8))
        #expect(afterEnvelope.schemaVersion == DraftStore.currentSchemaVersion)
        #expect(afterEnvelope.payloadSHA256?.isEmpty == false)
        let reopened = DraftStore(directory: chatDrafts.directory)
        let reloaded = reopened.load(key: chatKey)
        #expect(reloaded == Data(after.utf8))
        #expect(reopened.lastIOError(for: chatKey) == nil)
        #expect(bridge.agentTaskStore.allReceipts() == receiptsBefore)
        #expect(try Data(contentsOf: canvasRoot) == blockedBytes)
        #expect(bridge.canvasIfAvailable == nil && canvasFactoryCalls == 0)
        #expect(!chat.isStreaming)
        print("CANVAS28_PERSISTENCE failedCanvasFlush=\(canvasWriteFailed) chatFlushSucceeded=\(chatWriteSucceeded) chatReloadMatches=\(reloaded == Data(after.utf8)) canvasFactoryCalls=\(canvasFactoryCalls) chatSchema=\(afterEnvelope.schemaVersion) taskReceiptsUnchanged=\(bridge.agentTaskStore.allReceipts() == receiptsBefore)")
        print("CANVAS28_LIMIT allCanvasSchemaLocksLedgerCacheRollbackReferences=NOT_OBSERVED")
        canvasDrafts.cancelPending(key: DraftStore.canvasKey)
    }
}
