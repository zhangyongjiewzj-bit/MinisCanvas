import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("ARCH1 actual App domain factory identity 3085", .serialized)
@MainActor
struct ProductionDomainIdentity3085Tests {
    private enum Route: CaseIterable { case primary, degraded, blocked }

    /// Ancillary inputs use the existing isolated profile and fake backing.
    /// Settings and Bridge are constructed by the same functions called from
    /// MinisCanvasApp.init; this fixture does not duplicate their assembly.
    @MainActor
    private struct Inputs {
        let profile: RuntimeIsolationProfile
        let defaults: UserDefaults
        let shortcuts: ShortcutStore
        let sessions: SessionStore
        let badges: SessionBadgeStore
        let log: LogManager
        let workflows: WorkflowStore
        let settings: SettingsCenter
        let skills: SkillsStore
        let scheduler: SchedulerTaskStore

        init(label: String) throws {
            let freshProfile = try RuntimeIsolationProfile.makeIsolatedTest(label: label)
            profile = freshProfile
            var fixtureComplete = false
            defer { if !fixtureComplete { B1ARCHOriginalFixtureSupport.cleanupProfile(freshProfile) } }
            try B1ARCHOriginalFixtureSupport.qualifyProfile(freshProfile)
            defaults = profile.makeUserDefaults()
            shortcuts = ShortcutStore(defaults: defaults)
            sessions = SessionStore(directory: profile.sessionDirectory)
            badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
            log = profile.makeLogManager()
            workflows = WorkflowStore.startForAppBootstrap(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows"))
            settings = ProductionDomainAssembly.makeSettings(
                profile: profile, keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: log,
                store: shortcuts, readinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
            skills = SkillsStore(
                appStore: settings.skillStore, stateFileURL: profile.skillStateURL, loadImmediately: false)
            scheduler = SchedulerTaskStore(defaults: defaults,
                occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json"))
            fixtureComplete = true
        }

        func bridge(blocked: Bool = false) -> BridgeStore {
            ProductionDomainAssembly.makeBridge(
                profile: profile, bootstrapFailure: blocked ? .unexpectedProfileResolution : nil,
                settings: settings, store: shortcuts, defaults: defaults,
                skillsStore: skills, schedulerStore: scheduler, logManager: log,
                workflowStore: workflows, sessionBadgeStore: badges, sessionStore: sessions)
        }
    }

    private func record(_ model: String) -> ProviderReadinessPersistenceRecord {
        .init(providerID: "assembly3085", modelID: model,
              status: .unverified, readinessState: .unverified,
              checkedAt: Date(timeIntervalSince1970: 1_900_000_000), isApplied: false)
    }

    @Test("production preset env writer uses the Settings owner and its profile target")
    func presetEnvMutationUsesCanonicalSettingsStore() async throws {
        let inputs = try Inputs(label: "arch3085-command-env")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(inputs.profile) }
        let bridge = inputs.bridge()
        let target = inputs.profile.providerConfigurationDirectory
            .appendingPathComponent(EnvVarStore.fileName)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let result = try await bridge.commandRegistry.execute(
            id: "env.set", args: ["name": "ARCH1_PLAIN_SETTING", "value": "synthetic-only"]
        )
        #expect(result.ok)
        #expect(inputs.settings.envStore.getEnvVar(name: "ARCH1_PLAIN_SETTING") == "synthetic-only")
        #expect(FileManager.default.fileExists(atPath: target.path))
        let reopened = EnvVarStore(
            directory: inputs.profile.providerConfigurationDirectory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        #expect(reopened.getEnvVar(name: "ARCH1_PLAIN_SETTING") == "synthetic-only")
    }

    @Test("actual primary, fallback and blocker factories share the Settings readiness object")
    func originalLaunchRoutesUseSettingsReadinessIdentity() throws {
        for route in Route.allCases {
            let inputs = try Inputs(label: "arch3085-\(route)")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(inputs.profile) }
            if route == .degraded {
                // Make the original persistent constructor fail without a new
                // failure hook or mocked replacement of AppLaunchCoordinator.
                try FileManager.default.createDirectory(at: inputs.profile.agentTaskStorePersistenceURL,
                    withIntermediateDirectories: true)
            }
            let bridge = inputs.bridge(blocked: route == .blocked)
            let actual = try #require(bridge.chat.providerReadinessStore)
            #expect(actual === inputs.settings.providerReadinessStore)
            #expect(inputs.settings.sessionStore === inputs.sessions)
            #expect(bridge.canvasIfAvailable == nil)
            actual.upsert(record("\(route)"))
            #expect(inputs.settings.providerReadinessStore.records.map(\.modelID) == ["\(route)"])
            let reopened = ProviderReadinessStore(directory: inputs.profile.providerConfigurationDirectory)
            #expect(reopened.records == actual.records)
            let target = inputs.profile.providerConfigurationDirectory.appendingPathComponent(ProviderReadinessStore.fileName)
            #expect(FileManager.default.fileExists(atPath: target.path))
            if route != .primary {
                _ = try bridge.agentTaskStore.enqueue(taskID: "disposable-\(route)", parentID: "3085",
                    providerID: "offline", modelID: "synthetic")
                if route == .blocked {
                    #expect(!FileManager.default.fileExists(atPath: inputs.profile.agentTaskStorePersistenceURL.path))
                } else {
                    let ledgerKind = try inputs.profile.agentTaskStorePersistenceURL.resourceValues(forKeys: [.isDirectoryKey])
                    #expect(ledgerKind.isDirectory == true)
                }
            }
        }
    }

    @Test("factory reconstruction drops a foreign projection and writes only its canonical readiness target")
    func replacementCannotCarryForeignReadinessWriter() throws {
        let inputs = try Inputs(label: "arch3085-owner")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(inputs.profile) }
        let foreign = try Inputs(label: "arch3085-foreign")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(foreign.profile) }
        foreign.settings.providerReadinessStore.upsert(record("foreign"))
        let foreignURL = foreign.profile.providerConfigurationDirectory.appendingPathComponent(ProviderReadinessStore.fileName)
        let foreignBefore = try Data(contentsOf: foreignURL)
        var oldBridge: BridgeStore? = inputs.bridge()
        #expect(oldBridge?.chat.providerReadinessStore === inputs.settings.providerReadinessStore)
        oldBridge?.chat.providerReadinessStore = foreign.settings.providerReadinessStore
        // App construction is one generation at a time; do not deliberately
        // retain two durable TaskStore owners just to test reconstruction.
        oldBridge = nil
        let replacement = inputs.bridge()
        let actual = try #require(replacement.chat.providerReadinessStore)
        #expect(actual === inputs.settings.providerReadinessStore)
        #expect(actual !== foreign.settings.providerReadinessStore)
        actual.upsert(record("replacement"))
        #expect(try Data(contentsOf: foreignURL) == foreignBefore)
        #expect(foreign.settings.providerReadinessStore.records.map(\.modelID) == ["foreign"])
        let reopened = ProviderReadinessStore(directory: inputs.profile.providerConfigurationDirectory)
        #expect(reopened.records.map(\.modelID) == ["replacement"])
    }

    @Test("actual App factory Task writer and Project rebind keep one durable target; another root fails closed")
    func taskAndProjectRebindKeepCanonicalEffects() async throws {
        let inputs = try Inputs(label: "arch3085-task-project")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(inputs.profile) }
        let bridge = inputs.bridge()
        await bridge.attachProductionServices(fileAccessAllowedRoot: inputs.profile.rootDirectory,
            sessionDirectory: inputs.sessions.directory, externalNetworkAllowed: false).value
        let handler = try #require(bridge.productionProjectSessionHandler)
        let canonicalStore = bridge.agentTaskStore
        let task = try canonicalStore.enqueue(taskID: "3085-task", parentID: "3085-parent",
            providerID: "offline", modelID: "synthetic")
        let run = try canonicalStore.startRun(taskID: task.taskID, parentID: task.parentID, runID: "3085-run")
        let finished = try canonicalStore.finish(runID: run.runID, outcome: .failed(reason: "synthetic-result"))
        // The existing durable Store redacts arbitrary reason text. Preserve
        // that original contract while checking the same canonical receipt.
        #expect(finished.outcome == .failed(reason: "execution-failed"))
        let before = try Data(contentsOf: inputs.profile.agentTaskStorePersistenceURL)
        await bridge.attachProductionServices(fileAccessAllowedRoot: inputs.profile.rootDirectory,
            sessionDirectory: inputs.sessions.directory.appendingPathComponent("."), externalNetworkAllowed: false).value
        #expect(bridge.agentTaskStore === canonicalStore)
        #expect(bridge.chat.sessionStore === inputs.sessions)
        #expect(bridge.productionProjectSessionHandler === handler)
        #expect(bridge.chat.projectSessionHandler === handler)
        let row = try #require(bridge.taskCenterControlConsumer.receiptRows().first { $0.taskID == task.taskID })
        #expect(row.receiptID == run.runID && row.failureReason == "execution-failed")
        #expect(try Data(contentsOf: inputs.profile.agentTaskStorePersistenceURL) == before)
        let reopened = try AgentTaskStore(persistenceURL: inputs.profile.agentTaskStorePersistenceURL)
        #expect(reopened.receipt(runID: run.runID)?.outcome == .failed(reason: "execution-failed"))
        let wrongRoot = inputs.profile.rootDirectory.appendingPathComponent("foreign-session-root")
        await bridge.attachProductionServices(fileAccessAllowedRoot: inputs.profile.rootDirectory,
            sessionDirectory: wrongRoot, externalNetworkAllowed: false).value
        #expect(bridge.productionProjectSessionHandler == nil && bridge.chat.projectSessionHandler == nil)
        #expect(bridge.chat.sessionStore === inputs.sessions)
        #expect(bridge.agentTaskStore === canonicalStore)
        #expect(!FileManager.default.fileExists(atPath: wrongRoot.path))
        #expect(try Data(contentsOf: inputs.profile.agentTaskStorePersistenceURL) == before)
    }

    @Test("ARCH1 original picker reads the canonical MCP writer and foreign MCP binding fails closed without MCP document writes")
    func pickerCatalogUsesCanonicalMCPAndRejectsForeignAssemblyWithoutWriting() throws {
        let owner = try Inputs(label: "arch3085-mcp-owner")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(owner.profile) }
        let foreign = try Inputs(label: "arch3085-mcp-foreign")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(foreign.profile) }
        let bridge = owner.bridge()
        let manager = owner.settings.mcpManager
        let foreignManager = foreign.settings.mcpManager
        #expect(manager !== foreignManager)
        #expect(manager.fileURL != foreignManager.fileURL)
        let ownerID = "arch1-canonical-mcp"
        _ = try manager.addServer(MCPServer(id: ownerID, name: "Canonical before", type: .http,
            enabled: false, url: "http://127.0.0.1:9"))
        _ = try foreignManager.addServer(MCPServer(id: "arch1-foreign-mcp", name: "Foreign only",
            type: .http, enabled: false, url: "http://127.0.0.1:9"))
        func bytes(_ source: MCPServerManager) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in [source.fileURL, source.authorizationFileURL] {
                if FileManager.default.fileExists(atPath: url.path) {
                    result[url.path] = try Data(contentsOf: url)
                }
            }
            return result
        }
        #expect(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: owner.settings,
            profile: owner.profile))
        let beforeFirstReader = try bytes(manager)
        let foreignBaseline = try bytes(foreignManager)
        let initial = bridge.chat.pickerCatalogRefreshLoader()
        #expect(initial.contains { $0.id == "plugin:" + ownerID && $0.name == "Canonical before" })
        #expect(!initial.contains { $0.id == "plugin:arch1-foreign-mcp" })
        #expect(try bytes(manager) == beforeFirstReader)
        #expect(try bytes(foreignManager) == foreignBaseline)
        // A real owner write after binding must be seen by the original reader,
        // rather than a stale snapshot or a second manager from disk.
        _ = try manager.updateServer(MCPServer(id: ownerID, name: "Canonical after", type: .http,
            enabled: false, url: "http://127.0.0.1:9"))
        let afterOwnerWrite = try bytes(manager)
        #expect(afterOwnerWrite != beforeFirstReader)
        let updated = bridge.chat.pickerCatalogRefreshLoader()
        #expect(updated.contains { $0.id == "plugin:" + ownerID && $0.name == "Canonical after" })
        #expect(try bytes(manager) == afterOwnerWrite)
        #expect(try bytes(foreignManager) == foreignBaseline)
        // Inject only a foreign MCP manager into the real Settings consumer;
        // the canonical Skill owner stays identical so its first guard passes.
        let mismatchedMCP = SettingsCenter(
            settingsStore: owner.settings.settingsStore, envStore: owner.settings.envStore,
            memoryStore: owner.settings.memoryStore, memoryFileStore: owner.settings.memoryFileStore,
            sessionStore: owner.sessions, sessionBadgeStore: owner.badges,
            logManager: owner.log, mcpManager: foreignManager,
            skillStore: owner.settings.skillStore, usageStore: owner.settings.usageStore,
            shortcutStore: owner.shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: owner.settings.providerReadinessStore)
        #expect(mismatchedMCP.skillStore === owner.settings.skillStore)
        #expect(mismatchedMCP.mcpManager === foreignManager)
        // Failed original binding replaces both readers with empty callbacks.
        #expect(!ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: mismatchedMCP,
            profile: owner.profile))
        #expect(bridge.chat.pickerCatalogLoader().isEmpty)
        #expect(bridge.chat.pickerCatalogRefreshLoader().isEmpty)
        #expect(try bytes(manager) == afterOwnerWrite)
        #expect(try bytes(foreignManager) == foreignBaseline)
        #expect(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: owner.settings,
            profile: owner.profile))
        let rebound = bridge.chat.pickerCatalogRefreshLoader()
        #expect(rebound.contains { $0.id == "plugin:" + ownerID && $0.name == "Canonical after" })
        #expect(!rebound.contains { $0.id == "plugin:arch1-foreign-mcp" })
        #expect(try bytes(manager) == afterOwnerWrite)
        #expect(try bytes(foreignManager) == foreignBaseline)
    }

    @Test("ARCH1 overlapping same-path MCP writer is refused while canonical writer remains legal")
    func sameCanonicalMCPPathRejectsSecondLiveWriter() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let owner = try Inputs(label: "arch3085-mcp-samepath-owner")
        defer { try? owner.profile.cleanupDisposableRoots() }
        let canonical = owner.settings.mcpManager
        let serverID = "arch1-samepath-owner"
        func bytes() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in [canonical.fileURL, canonical.authorizationFileURL] {
                if FileManager.default.fileExists(atPath: url.path) {
                    result[url.lastPathComponent] = try Data(contentsOf: url)
                }
            }
            return result
        }
        _ = try canonical.addServer(MCPServer(id: serverID, name: "Canonical initial",
            type: .http, enabled: false, url: "http://127.0.0.1:9"))
        let initialBytes = try bytes()
        #expect(!initialBytes.isEmpty)
        // Initializers cannot throw; refusal must occur before a second writer
        // mutates the same config/authorization pair, not by changing API access.
        let second = MCPServerManager(fileURL: canonical.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: canonical.authorizationFileURL)
        #expect(second !== canonical)
        #expect(second.fileURL == canonical.fileURL)
        #expect(second.authorizationFileURL == canonical.authorizationFileURL)
        #expect(try bytes() == initialBytes)
        // Positive control: the original production assembly owner remains
        // live and can write after the competing object was constructed.
        _ = try canonical.updateServer(MCPServer(id: serverID, name: "Canonical successor",
            type: .http, enabled: false, url: "http://127.0.0.1:9"))
        let canonicalBytes = try bytes()
        #expect(canonicalBytes != initialBytes)
        #expect(canonical.server(id: serverID)?.name == "Canonical successor")
        #expect(second.server(id: serverID)?.name == "Canonical initial")
        // Overlap the lifetimes, serialize the writes deterministically: a
        // stale competing writer must not replace the canonical before-image.
        var rejected = false
        var errorType = "none"
        do {
            _ = try second.updateServer(MCPServer(id: serverID, name: "Second writer overwrite",
                type: .http, enabled: false, url: "http://127.0.0.1:9"))
        } catch {
            rejected = true
            errorType = String(reflecting: type(of: error))
        }
        let preserved = try bytes() == canonicalBytes
        print("ARCH1_MCP_SAMEPATH secondRejected=\(rejected) errorType=\(errorType) canonicalBytesPreserved=\(preserved)")
        #expect(rejected, "a second live manager must not gain the canonical writer's durable authority")
        #expect(preserved, "second writer must not replace MCP config or authorization bytes")
        #expect(canonical.server(id: serverID)?.name == "Canonical successor")
        // Preserve a valid owner positive control after the rejected attempt.
        _ = try canonical.updateServer(MCPServer(id: serverID, name: "Canonical final",
            type: .http, enabled: false, url: "http://127.0.0.1:9"))
        #expect(canonical.server(id: serverID)?.name == "Canonical final")
        #expect(try bytes() != canonicalBytes)
    }

    @Test("ARCH1 library stale A update must preserve a different canonical B record; keep owned JSON evidence")
    func libraryStaleAUpdatePreservesCanonicalBWithOwnedJSONEvidence() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let owner = try Inputs(label: "arch3085-mcp-ab-owned-json")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(owner.profile) }
        // Evidence is a sibling under the formal root, outside the disposable
        // profile. Do not erase the crucial before/after JSON in fixture cleanup.
        let evidence = formal.rootDirectory.appendingPathComponent(
            "ARCH_MCP_AB_EVIDENCE-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let canonical = owner.settings.mcpManager
        let idA = "arch1-ab-a"
        let idB = "arch1-ab-b"
        func capture(_ stage: String) throws -> (names: [String: String], digests: [String: String]) {
            var names: [String: String] = [:]
            var digests: [String: String] = [:]
            var summaries: [String: Any] = [:]
            for (label, url) in [("config", canonical.fileURL), ("authorization", canonical.authorizationFileURL)] {
                let bytes = try Data(contentsOf: url)
                let parsed = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let digest = DeletionGate.fingerprint(bytes)
                digests[label] = digest
                let snapshotFile = evidence.appendingPathComponent(stage + "." + label + ".json")
                try bytes.write(to: snapshotFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotFile.path)
                var summary: [String: Any] = ["sha256": digest, "byteCount": bytes.count,
                    "revision": parsed["revision"] ?? NSNull()]
                if label == "config" {
                    for row in (parsed["servers"] as? [[String: Any]] ?? []) {
                        if let id = row["id"] as? String, let name = row["name"] as? String { names[id] = name }
                    }
                    summary["serverNames"] = names
                } else {
                    summary["authorizationCount"] = (parsed["authorizations"] as? [Any])?.count ?? 0
                }
                summaries[label] = summary
            }
            let summaryBytes = try JSONSerialization.data(withJSONObject: ["stage": stage, "files": summaries], options: [.sortedKeys])
            try summaryBytes.write(to: evidence.appendingPathComponent(stage + ".summary.json"), options: .atomic)
            print("ARCH_MCP_AB_CHECKPOINT " + String(decoding: summaryBytes, as: UTF8.self))
            return (names, digests)
        }
        _ = try canonical.addServer(MCPServer(id: idA, name: "A initial", type: .http,
            enabled: false, url: "http://127.0.0.1:9"))
        let stale = MCPServerManager(fileURL: canonical.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: canonical.authorizationFileURL)
        #expect(stale.fileURL == canonical.fileURL && stale !== canonical)
        let capturedAOnly = try capture("01_A_only_before_B")
        #expect(capturedAOnly.names == [idA: "A initial"])
        _ = try canonical.addServer(MCPServer(id: idB, name: "B canonical unrelated", type: .http,
            enabled: false, url: "http://127.0.0.1:9"))
        // Legal same-ID LWW positive control remains allowed on canonical A.
        _ = try canonical.updateServer(MCPServer(id: idA, name: "A canonical updated", type: .http,
            enabled: false, url: "http://127.0.0.1:9"))
        let beforeStale = try capture("02_canonical_A_and_B")
        #expect(beforeStale.names[idB] == "B canonical unrelated")
        #expect(beforeStale.names[idA] == "A canonical updated")
        #expect(stale.server(id: idB) == nil)
        var rejected = false
        var errorType = "none"
        do {
            _ = try stale.updateServer(MCPServer(id: idA, name: "A stale writer update", type: .http,
                enabled: false, url: "http://127.0.0.1:9"))
        } catch {
            rejected = true
            errorType = String(reflecting: type(of: error))
        }
        let afterStale = try capture("03_after_stale_A_update")
        print("ARCH_MCP_AB_RESULT secondRejected=\(rejected) errorType=\(errorType) BPreserved=\(afterStale.names[idB] == beforeStale.names[idB]) configBytesChanged=\(afterStale.digests["config"] != beforeStale.digests["config"]) authorizationBytesChanged=\(afterStale.digests["authorization"] != beforeStale.digests["authorization"])")
        print("ARCH_MCP_AB_EVIDENCE_ROOT " + evidence.path)
        // Same A may follow LWW, or a stale transaction may be refused safely.
        // The diagnostic does not require rejection: unrelated B must survive.
        #expect(afterStale.names[idB] == "B canonical unrelated",
            "changing A may not silently erase the separately committed B record")
        #expect(afterStale.names[idA] == (rejected ? "A canonical updated" : "A stale writer update"))
    }

    @Test("ARCH1 original frozen MCP reader leaves Settings and manager documents byte-identical")
    func normalFrozenMCPReaderKeepsOwnedSettingsAndManagerBytes() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let owner = try Inputs(label: "arch3085-mcp-frozen-reader-bytes")
        defer { B1ARCHOriginalFixtureSupport.cleanupProfile(owner.profile) }
        _ = owner.settings.settingsStore.update(\.agent.maxLoopIterations, to: 25)
        let manager = owner.settings.mcpManager
        _ = try manager.addServer(MCPServer(id: "arch1-reader-owned", name: "Owned reader fact",
            type: .http, enabled: false, url: "http://127.0.0.1:9"))
        let watched = [owner.settings.settingsStore.fileURL, manager.fileURL, manager.authorizationFileURL]
        func bytes() throws -> [String: Data] {
            var value: [String: Data] = [:]
            for url in watched { value[url.path] = try Data(contentsOf: url) }
            return value
        }
        let before = try bytes()
        // This is the real Registry used by Bridge's original turn reader,
        // with the exact Settings-owned manager from production makeSettings.
        let live = MCPToolRegistry(manager: manager, clientFactory: { server in
            Issue.record("frozen reader attempted client construction for a disabled server")
            return MCPClient(server: server)
        })
        #expect(live.manager === owner.settings.mcpManager)
        let turn = try live.snapshotForTurn()
        let frozen = try #require(turn as? MCPToolRegistry)
        #expect(frozen.manager !== manager)
        #expect(frozen.manager.fileURL == manager.fileURL)
        #expect(frozen.manager.server(id: "arch1-reader-owned")?.name == "Owned reader fact")
        let frozenTools = try await turn.mcpBoundTools()
        #expect(frozenTools.isEmpty)
        #expect(try bytes() == before)
        let prepare = live.captureTurnSnapshotPreparation()
        let prepared = try prepare()
        let preparedRegistry = try #require(prepared as? MCPToolRegistry)
        #expect(preparedRegistry.manager !== manager)
        #expect(preparedRegistry.manager.server(id: "arch1-reader-owned")?.name == "Owned reader fact")
        let preparedTools = try await prepared.mcpBoundTools()
        #expect(preparedTools.isEmpty)
        #expect(try bytes() == before)
        let digestRows = before.keys.sorted().map { key in
            key + "=" + DeletionGate.fingerprint(before[key]!)
        }
        print("ARCH_MCP_FROZEN_READER_UNCHANGED " + digestRows.joined(separator: " "))
    }
}
