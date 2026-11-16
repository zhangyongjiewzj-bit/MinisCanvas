import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-ARCH1 injected Memory writer identity")
@MainActor
struct ProductionDomainAssembly2671Tests {
    @Test("one injected store is shared; a second writer is rejected even for the same directory")
    func memoryProposalConsumerCannotIntroduceSecondWriter() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = try B1ARCHOriginalFixtureSupport.makeRoot("memory2671")
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(root) }
        let owned = try B1ARCHOriginalFixtureSupport.inputs(root)

        let owner = MemoryStore(directory: root)
        let sameOwner = MemoryProposalConsumer(store: owner)
        let secondInstance = MemoryStore(directory: root)
        let secondWriter = MemoryProposalConsumer(store: secondInstance)
        let defaults = profile.makeUserDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        let logger = LogManager(directory: root.appendingPathComponent("logs", isDirectory: true))
        let workflows = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows", isDirectory: true))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges", isDirectory: true))
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        let documents = SessionDocumentStore(directory: sessions.directory)

        let rejectedLedger = root.appendingPathComponent("rejected-agent-tasks.json")
        do {
            _ = try BridgeStore(
                taskStorePersistenceURL: rejectedLedger,
                shortcutStore: shortcuts,
                preferencesDefaults: defaults,
                settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
                logManager: logger,
                workflowStore: workflows,
                sessionBadgeStore: badges,
                sessionDocumentStore: documents,
                sessionStore: sessions,
                memoryStore: owner,
                memoryProposalConsumer: secondWriter,
                commandEnvStore: owned.env, canonicalMCPManager: owned.mcp, providerReadinessStore: owned.readiness,
                canvasFeatureLane: .phase3NonCanvas
            )
            Issue.record("production constructor accepted two MemoryStore writers")
        } catch let error as BridgeStore.ProductionAssemblyError {
            #expect(error == .conflictingMemoryWriter)
        } catch {
            Issue.record("production constructor rejected for an unrelated reason: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: rejectedLedger.path))

        // The ordinary App passes this exact owner pair; the accepted durable
        // constructor reaches the same non-Canvas composition as its fallback.
        let bridge = try BridgeStore(
            taskStorePersistenceURL: root.appendingPathComponent("accepted-agent-tasks.json"),
            shortcutStore: shortcuts,
            preferencesDefaults: defaults,
            settingsCatalogSkillsStore: owned.catalog, settingsCatalogSchedulerStore: owned.scheduler,
            logManager: logger,
            workflowStore: workflows,
            sessionBadgeStore: badges,
            sessionDocumentStore: documents,
            sessionStore: sessions,
            memoryStore: owner,
            memoryProposalConsumer: sameOwner,
            commandEnvStore: owned.env, canonicalMCPManager: owned.mcp, providerReadinessStore: owned.readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.canvasIfAvailable == nil)
        #expect(bridge.canvasFeatureLane == .phase3NonCanvas)
    }
}
