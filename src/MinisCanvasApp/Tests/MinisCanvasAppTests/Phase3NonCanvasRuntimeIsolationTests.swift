import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

struct Phase3NonCanvasRuntimeIsolationTests {
    @Test @MainActor
    func canvasDefaultStoresFollowFormalTestProfileBeforeSharedStores() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let canvas = CanvasStore(preferencesDefaults: profile.makeUserDefaults())
        let implicitDefaultsCanvas = CanvasStore()

        #expect(canvas.assetPersistenceDirectory == profile.minisCoreDirectory)
        #expect(implicitDefaultsCanvas.assetPersistenceDirectory == profile.minisCoreDirectory)
    }

    @Test @MainActor
    func packagedChatDoesNotConstructCanvasOrOpenItsDamagedMediaStore() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let fixtureDirectory = try B1ARCHOriginalFixtureSupport.makeRoot("phase3-canvas-absence")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(fixtureDirectory) }
        let owned = try B1ARCHOriginalFixtureSupport.inputs(fixtureDirectory)
        let damagedVideoSnapshot = fixtureDirectory
            .appendingPathComponent(VideoTaskStore.fileName)
        let originalBytes = Data("damaged synthetic Canvas media snapshot".utf8)
        try originalBytes.write(to: damagedVideoSnapshot)

        let defaults = profile.makeUserDefaults()
        var canvasFactoryCalls = 0
        var coordinatorFactoryCalls = 0
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            settingsCatalogSkillsStore: owned.catalog,
            settingsCatalogSchedulerStore: owned.scheduler,
            logManager: owned.logger, workflowStore: owned.workflows,
            sessionBadgeStore: owned.badges,
            sessionDocumentStore: owned.documents, sessionStore: owned.sessions,
            canvasFactory: { preferences in
                canvasFactoryCalls += 1
                return CanvasStore(
                    videoTaskStore: VideoTaskStore(directory: fixtureDirectory),
                    artifactStore: ArtifactStore(
                        directory: fixtureDirectory.appendingPathComponent("artifacts")
                    ),
                    preferencesDefaults: preferences
                )
            },
            canvasRuntimeState: .enabled,
            agentTaskStore: owned.tasks, contextManifestStore: owned.context,
            memoryStore: owned.memory, commandEnvStore: owned.env, canonicalMCPManager: owned.mcp,
            canvasMutationCoordinatorFactory: { canvas in
                coordinatorFactoryCalls += 1
                return CanvasMutationCoordinator(target: canvas)
            },
            providerReadinessStore: owned.readiness,
            taskCenterBindingPersistenceURL: fixtureDirectory.appendingPathComponent("owned-task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )

        #expect(canvasFactoryCalls == 0)
        #expect(coordinatorFactoryCalls == 0)
        #expect(bridge.canvasIfAvailable == nil)
        #expect(bridge.canvasBoundaryIfAvailable == nil)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.chat.activeSessionID != nil)
        let unchangedBytes = try Data(contentsOf: damagedVideoSnapshot)
        #expect(unchangedBytes == originalBytes)
        bridge.dispatchCanvasMutation(.resetStatuses)
        let layoutBeforeStaleCommands = bridge.layoutMode
        bridge.runCommand(id: "ui.layout.canvas")
        bridge.runCommand(id: "ui.add-node.text")
        bridge.runCommand(id: "ui.pipeline")
        #expect(bridge.layoutMode == layoutBeforeStaleCommands)
        #expect(bridge.composerCanvasDispatchCount == 0)
        #expect(canvasFactoryCalls == 0)
        #expect(coordinatorFactoryCalls == 0)
    }

    @Test @MainActor
    func packagedPhase3RuntimeCannotPublishCanvasConsumers() throws {
        let root = try B1ARCHOriginalFixtureSupport.makeRoot("phase3-runtime-value")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(root) }
        let owned = try B1ARCHOriginalFixtureSupport.inputs(root)
        #expect(RuntimeIsolationProfile.phase3CanvasFeatureLane == .phase3NonCanvas)
        #expect(RuntimeIsolationProfile.phase3CanvasChatConsumerCount == 0)
        #expect(RuntimeIsolationProfile.phase3CanvasEventToChatWriteCount == 0)

        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: owned.defaults), preferencesDefaults: owned.defaults,
            settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
            logManager: owned.logger, workflowStore: owned.workflows, sessionBadgeStore: owned.badges,
            sessionDocumentStore: owned.documents, sessionStore: owned.sessions,
            canvasRuntimeState: .enabled, agentTaskStore: owned.tasks, contextManifestStore: owned.context,
            memoryStore: owned.memory, commandEnvStore: owned.env, canonicalMCPManager: owned.mcp,
            providerReadinessStore: owned.readiness,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("owned-task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )

        #expect(bridge.canvasFeatureLane == .phase3NonCanvas)
        #expect(bridge.canvasRuntimeState == .disabled)
        #expect(bridge.productionChatComposition.chatStartupIndependent)
        #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)
    }

    @Test
    @MainActor
    func phase3ChatDraftLifecycleLeavesLegacyCanvasFilesUntouched() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.minisCanvasDirectory.appendingPathComponent(
            "phase3-draft-legacy-files-\(UUID().uuidString)", isDirectory: true
        )
        let draftsDirectory = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyFiles: [URL: Data] = [
            draftsDirectory.appendingPathComponent("canvas.json"): Data("legacy-canvas".utf8),
            root.appendingPathComponent("canvas_collection.json"): Data("legacy-collection".utf8),
            root.appendingPathComponent("canvas_cleanup.json"): Data("legacy-cleanup".utf8)
        ]
        for (url, bytes) in legacyFiles {
            try bytes.write(to: url)
        }
        let before = try legacyFiles.map { url, bytes in
            (url, bytes, try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }

        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: root),
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase3NonCanvas
        )
        await bridge.attachProductionServices(
            sessionDirectory: root,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            externalNetworkAllowed: false
        ).value

        let longDraft = String(repeating: "phase3-chat-draft", count: 400)
        let sessionID = try #require(bridge.chat.activeSessionID)
        let chatDraftURL = draftsDirectory.appendingPathComponent(
            "\(DraftStore.chatDraftKey(sessionID: sessionID)).json"
        )
        bridge.chat.draftText = longDraft
        #expect(bridge.chat.flushPendingDraftForTermination())
        #expect(FileManager.default.fileExists(atPath: chatDraftURL.path))
        let chatEnvelope = try JSONDecoder().decode(
            DraftEnvelope.self, from: Data(contentsOf: chatDraftURL)
        )
        #expect(chatEnvelope.payload == Data(longDraft.utf8))
        bridge.chat.draftText = ""
        #expect(!FileManager.default.fileExists(atPath: chatDraftURL.path))
        #expect(bridge.chat.draftStore?.flushAll() == true)

        for (url, bytes, mtime) in before {
            #expect(try Data(contentsOf: url) == bytes)
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == mtime)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("canvas").path))
        #expect(bridge.canvasIfAvailable == nil)
    }

    @Test @MainActor
    func phase4OptInChatAndCanvasDraftStoresRemainDirectoryIsolated() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.minisCanvasDirectory.appendingPathComponent(
            "phase4-draft-store-isolation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: root),
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase4OptIn
        )
        await bridge.attachProductionServices(
            sessionDirectory: root,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            externalNetworkAllowed: false
        ).value

        let chatDraftStore = try #require(bridge.chat.draftStore)
        let canvasDraftStore = try #require(bridge.canvasIfAvailable?.draftStore)
        #expect(chatDraftStore.directory != canvasDraftStore.directory)
        #expect(canvasDraftStore.directory == root.appendingPathComponent("canvas", isDirectory: true))

        let canvasPayload = Data("phase4-canvas-only".utf8)
        canvasDraftStore.scheduleSave(key: DraftStore.canvasKey, payload: canvasPayload)
        #expect(canvasDraftStore.flushNow(key: DraftStore.canvasKey))
        let canvasDraftURL = canvasDraftStore.draftsDirectory
            .appendingPathComponent("\(DraftStore.canvasKey).json")
        let chatDraftURL = chatDraftStore.draftsDirectory
            .appendingPathComponent("\(DraftStore.canvasKey).json")
        #expect(FileManager.default.fileExists(atPath: canvasDraftURL.path))
        let canvasEnvelope = try JSONDecoder().decode(
            DraftEnvelope.self, from: Data(contentsOf: canvasDraftURL)
        )
        #expect(canvasEnvelope.payload == canvasPayload)
        #expect(!FileManager.default.fileExists(atPath: chatDraftURL.path))
    }

    @Test @MainActor
    func phase4RemainsAnExplicitOptInSeam() {
        let bridge = BridgeStore(
            canvasRuntimeState: .enabled,
            canvasFeatureLane: .phase4OptIn
        )

        #expect(bridge.canvasFeatureLane == .phase4OptIn)
        #expect(bridge.canvasRuntimeState == .enabled)
        #expect(bridge.canvasIfAvailable != nil)
        #expect(bridge.canvasBoundaryIfAvailable != nil)
        #expect(bridge.productionChatComposition.canvasCapabilities == [
            "canvas_read", "canvas_mutation"
        ])
    }

    @Test @MainActor
    func unavailableCanvasStatesCannotReachChatConsumer() {
        for state in [
            RuntimeIsolationProfile.CanvasRuntimeState.absent,
            .disabled,
            .corrupt
        ] {
            let bridge = BridgeStore(
                canvasRuntimeState: state,
                canvasFeatureLane: .phase4OptIn
            )

            #expect(bridge.canvasRuntimeState == state)
            #expect(bridge.productionChatComposition.chatStartupIndependent)
            #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)
        }
    }
}
