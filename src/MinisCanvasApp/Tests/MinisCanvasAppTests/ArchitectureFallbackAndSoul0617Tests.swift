import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Tests-only diagnostics of existing production semantics. No UI or network.
@Suite("ARCH1 fallback Memory and Soul owned consumers 0617", .serialized)
@MainActor
struct ArchitectureFallbackAndSoul0617Tests {
    private struct OwnedRoot {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
    }

    private enum FixtureError: Error {
        case unsafeRoot
        case cleanupIdentityChanged
        case cleanupFailed(Int32)
        case businessAndCleanup(business: Error, cleanup: Error)
    }

    private func ownedRoot() throws -> OwnedRoot {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let parent = profile.rootDirectory.standardizedFileURL
        var parentStat = stat()
        try #require(lstat(parent.path, &parentStat) == 0)
        try #require((parentStat.st_mode & S_IFMT) == S_IFDIR)
        try #require((parentStat.st_mode & 0o777) == 0o700)
        try #require(parentStat.st_uid == geteuid() && parentStat.st_uid == formal.rootOwner)
        try #require(UInt64(parentStat.st_dev) == formal.rootDevice)
        try #require(UInt64(parentStat.st_ino) == formal.rootInode)
        let root = parent.appendingPathComponent("arch-fallback-soul-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager()
        try fm.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700,
              info.st_uid == geteuid(), info.st_uid == formal.rootOwner,
              info.st_dev == parentStat.st_dev, info.st_ino != parentStat.st_ino else {
            throw FixtureError.unsafeRoot
        }
        return OwnedRoot(url: root, device: info.st_dev, inode: info.st_ino, owner: info.st_uid)
    }

    private func cleanup(_ root: OwnedRoot) throws {
        var info = stat()
        guard lstat(root.url.path, &info) == 0,
              info.st_dev == root.device, info.st_ino == root.inode,
              info.st_uid == root.owner, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700 else {
            throw FixtureError.cleanupIdentityChanged
        }
        try FileManager().removeItem(at: root.url)
        errno = 0
        guard lstat(root.url.path, &info) == -1, errno == ENOENT else {
            throw FixtureError.cleanupFailed(errno)
        }
    }

    @MainActor
    private struct Inputs {
        let root: URL
        let defaults: UserDefaults
        let memory: MemoryStore
        let sessions: SessionStore
        let badges: SessionBadgeStore
        let documents: SessionDocumentStore
        let shortcuts: ShortcutStore
        let log: LogManager
        let workflows: WorkflowStore
        let env: EnvVarStore
        let mcp: MCPServerManager
        let skills: SkillStore
        let readiness: ProviderReadinessStore
        let catalogSkills: SkillsStore
        let scheduler: SchedulerTaskStore

        init(root: URL, defaults: UserDefaults) {
            self.root = root
            self.defaults = defaults
            memory = MemoryStore(directory: root.appendingPathComponent("memory"))
            sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
            documents = SessionDocumentStore(directory: sessions.directory)
            shortcuts = ShortcutStore(defaults: defaults)
            log = LogManager(directory: root.appendingPathComponent("logs"))
            workflows = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            env = EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults))
            mcp = MCPServerManager(fileURL: root.appendingPathComponent("mcp/mcps.json"), keychain: keychain)
            skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
            catalogSkills = SkillsStore(
                appStore: skills, stateFileURL: root.appendingPathComponent("skills-state.json"), loadImmediately: false)
            scheduler = SchedulerTaskStore(defaults: defaults,
                occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json"))
        }

        func bridge(consumer: MemoryProposalConsumer) throws -> BridgeStore {
            // All fallback store arguments explicitly owned. This is the
            // nonthrowing constructor, not the guarded persistent convenience init.
            let independent = root.appendingPathComponent("bridge-" + UUID().uuidString)
            try FileManager().createDirectory(at: independent, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return BridgeStore(
                shortcutStore: shortcuts, preferencesDefaults: defaults,
                settingsCatalogSkillsStore: catalogSkills, settingsCatalogSchedulerStore: scheduler,
                logManager: log, workflowStore: workflows, sessionBadgeStore: badges,
                sessionDocumentStore: documents, sessionStore: sessions,
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: independent.appendingPathComponent("tasks.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: independent.appendingPathComponent("context.json")),
                memoryStore: memory, memoryProposalConsumer: consumer,
                commandEnvStore: env, canonicalMCPManager: mcp,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: independent.appendingPathComponent("bindings.json"),
                canvasFeatureLane: .phase3NonCanvas
            )
        }

        func attach(to bridge: BridgeStore) -> Task<Void, Never> {
            bridge.attachProductionServices(
                fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], fileAccessMountedRoots: [],
                sessionDirectory: sessions.directory, mcpManager: mcp, skillStore: skills,
                canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false,
                sessionReadSecretStore: env)
        }
    }

    private func withInputs(_ body: (Inputs) async throws -> Void) async throws {
        let lease = try ownedRoot()
        let suite = "ARCHFallbackSoul-" + lease.url.lastPathComponent
        let result: Result<Void, Error>
        do {
            let defaults = try #require(UserDefaults(suiteName: suite))
            try await body(Inputs(root: lease.url, defaults: defaults))
            result = .success(())
        } catch { result = .failure(error) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        do { try cleanup(lease) }
        catch {
            if case .failure(let business) = result {
                throw FixtureError.businessAndCleanup(business: business, cleanup: error)
            }
            throw error
        }
        try result.get()
    }

    private func ownedBytes(_ directory: URL) throws -> [String: Data] {
        let fm = FileManager()
        guard fm.fileExists(atPath: directory.path) else { return [:] }
        let files = try fm.subpathsOfDirectory(atPath: directory.path).sorted()
        var result: [String: Data] = [:]
        for relative in files {
            let file = directory.appendingPathComponent(relative)
            var info = stat()
            try #require(lstat(file.path, &info) == 0)
            try #require((info.st_mode & S_IFMT) != S_IFLNK)
            if (info.st_mode & S_IFMT) == S_IFREG { result[relative] = try Data(contentsOf: file) }
        }
        return result
    }

    private func setOwnedProject(_ bridge: BridgeStore, root: URL) throws -> MemoryScope {
        let sessionID = try #require(bridge.chat.activeSessionID)
        let projectID = "arch-owned-project"
        bridge.chat.setProject(.init(id: projectID, name: "Owned ARCH fixture", workingDirectory: root.path),
            forSession: sessionID)
        let scope = try #require(bridge.chat.activeMemoryScope)
        #expect(scope == MemoryScope(sessionID: sessionID.uuidString, projectID: projectID))
        return scope
    }

    @Test
    func nonthrowingMemoryFallbackRejectsForeignConsumerAtOriginalCommandWithoutWrites() async throws {
        try await withInputs { inputs in
            let owner = MemoryProposalConsumer(store: inputs.memory)
            _ = try owner.provisionCandidateSubmissionIfAbsent(sourceID: "preset-command", reason: "owned synthetic fixture")
            let legal = try inputs.bridge(consumer: owner)
            let scope = try setOwnedProject(legal, root: inputs.root)
            let positive = try await legal.commandRegistry.execute(id: "memory.add", args: ["text": "ARCH owned same-owner positive"])
            #expect(positive.ok)
            #expect(try inputs.memory.facts().count == 1)
            #expect(try inputs.memory.facts().first?.memoryScope == scope)
            #expect(try owner.envelopes().first?.sourceID == "preset-command")

            let otherStore = MemoryStore(directory: inputs.memory.directory)
            let foreign = MemoryProposalConsumer(store: otherStore)
            #expect(foreign.store !== inputs.memory)
            #expect(foreign.store.directory == inputs.memory.directory)
            let deniedBridge = try inputs.bridge(consumer: foreign)
            _ = try setOwnedProject(deniedBridge, root: inputs.root)
            let before = try ownedBytes(inputs.memory.directory)
            let beforeFacts = try inputs.memory.facts()
            let denied = try await deniedBridge.commandRegistry.execute(id: "memory.add", args: ["text": "ARCH foreign must not commit"])
            #expect(!denied.ok)
            #expect(try ownedBytes(inputs.memory.directory) == before)
            #expect(try inputs.memory.facts().map(\.id) == beforeFacts.map(\.id))
            #expect(try inputs.memory.facts().count == 1)
            print("ARCH_MEMORY_FALLBACK command=memory.add sameOwnerPositive=true foreignSameTarget=true rejectedResult=\(!denied.ok) memoryBytesUnchanged=\(try ownedBytes(inputs.memory.directory) == before)")
        }
    }

    @Test
    func repeatedOriginalAttachPreservesOwnedSoulSeedActiveBytesAndFacts() async throws {
        try await withInputs { inputs in
            let bridge = try inputs.bridge(consumer: MemoryProposalConsumer(store: inputs.memory))
            await inputs.attach(to: bridge).value
            let firstEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            let firstDeps = try #require(firstEngine.chatRuntimeDependencies)
            let first = firstDeps.soulStore
            #expect(first.directory.standardizedFileURL == inputs.sessions.directory.standardizedFileURL)
            let seeded = first.listSouls()
            #expect(seeded == [SoulStore.defaultSoul])
            #expect(first.activeSoul() == SoulStore.defaultSoul)
            let seedBytes = try Data(contentsOf: first.soulsFileURL)
            let custom = Soul(id: "arch-owned-soul", name: "Owned synthetic soul", systemPrompt: "Synthetic only", isActive: true)
            _ = try first.upsert(custom)
            let beforeFacts = first.listSouls()
            let beforeActive = try #require(first.activeSoul())
            #expect(beforeActive == custom)
            let beforeBytes = try Data(contentsOf: first.soulsFileURL)
            #expect(beforeBytes != seedBytes)

            await inputs.attach(to: bridge).value
            let secondEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            let secondDeps = try #require(secondEngine.chatRuntimeDependencies)
            let second = secondDeps.soulStore
            #expect(second.directory.standardizedFileURL == first.directory.standardizedFileURL)
            #expect(second.listSouls() == beforeFacts)
            #expect(second.activeSoul() == beforeActive)
            #expect(try Data(contentsOf: second.soulsFileURL) == beforeBytes)
            #expect(first.listSouls() == beforeFacts)
            #expect(first.activeSoul() == beforeActive)
            print("ARCH_SOUL_REATTACH sameTarget=true sameInstance=\(first === second) active=\(beforeActive.id) seedPreserved=true activeBytesUnchanged=\(try Data(contentsOf: second.soulsFileURL) == beforeBytes)")
        }
    }
}
