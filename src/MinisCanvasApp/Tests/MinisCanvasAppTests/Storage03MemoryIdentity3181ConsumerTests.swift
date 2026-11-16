import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private struct Storage3181NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Original STORAGE03 memory provenance, through the actual App draft,
/// preview and confirmation consumers. All roots and identities are synthetic.
/// Device name is display metadata, not an authentication or rejection policy.
@Suite("Storage03 App memory identity3181", .serialized)
@MainActor
struct Storage03MemoryIdentity3181ConsumerTests {
    private let scope = MemoryScope(sessionID: "storage3181-session", projectID: "storage3181-project")
    private let neighbor = MemoryScope(sessionID: "storage3181-neighbor", projectID: "storage3181-other-project")

    private func root() throws -> URL {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("Storage3181-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    // Same existing SettingsCenter constructor as SafeSelectedRecovery2295.
    // No substitute importer, authority source or production test-only API.
    private func center(_ root: URL) -> SettingsCenter {
        let core = root.appendingPathComponent("core"), chat = root.appendingPathComponent("chat")
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keys),
            memoryStore: MemoryStore(directory: chat), memoryFileStore: MemoryFileStore(directory: chat),
            sessionStore: SessionStore(directory: chat),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Storage3181NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        center.memoryScopeProvider = { scope }
        return center
    }

    private struct DiskState: Equatable {
        let type: FileAttributeType
        let inode: UInt64
        let modified: Date
        let bytes: Data?
    }

    /// Retains directory membership and inode/mtime as well as full file bytes.
    /// An unchanged result proves no observed persisted mutation; it does not
    /// claim an uninstrumented count of OS write syscalls.
    private func disk(_ root: URL) throws -> [String: DiskState] {
        let entries = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]))
        var result: [String: DiskState] = [:]
        for case let url as URL in entries {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = try #require(attributes[.type] as? FileAttributeType)
            try #require(type == .typeRegular || type == .typeDirectory)
            let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
            let modified = try #require(attributes[.modificationDate] as? Date)
            result[String(url.path.dropFirst(root.path.count + 1))] = DiskState(
                type: type, inode: inode, modified: modified,
                bytes: type == .typeRegular ? try Data(contentsOf: url) : nil)
        }
        return result
    }

    @Test
    func sameProjectWrongSessionRejectsWithoutPersistedMutationThenCorrectIdentityRestores() async throws {
        let owned = try root()
        let sourceRoot = owned.appendingPathComponent("source", isDirectory: true)
        let targetRoot = owned.appendingPathComponent("target", isDirectory: true)
        let source = center(sourceRoot), target = center(targetRoot)
        _ = try source.memoryStore.addFact("source accepted", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try target.memoryStore.addFact("target must survive rejection", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try target.memoryStore.addFact("neighbor must survive commit", sourceSessionID: neighbor.sessionID, memoryScope: neighbor)
        let session = try target.sessionStore.createSession(id: scope.sessionID, title: "session is unselected")
        let sessionFile = target.sessionStore.sessionsDirectory.appendingPathComponent(session.id + ".json")
        let sessionBytes = try Data(contentsOf: sessionFile)
        let exported = try source.syncManager.exportSnapshot(scopes: [.memories])
        var object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        var manifest = try #require(object["manifest"] as? [String: Any])
        manifest["deviceName"] = "Another owned synthetic device3181"
        object["manifest"] = manifest
        let backup = sourceRoot.appendingPathComponent("owned.minissync")
        try JSONSerialization.data(withJSONObject: object).write(to: backup)
        target.syncManager.markDirty(.settings)
        let before = try disk(targetRoot)
        let factsBefore = try target.memoryStore.facts()
        let draft = try target.readAtomicBackupDraft(from: backup)
        #expect(draft.manifest.deviceName == "Another owned synthetic device3181")
        #expect(draft.sourceMemoryScopes == [scope] && !draft.hasMissingMemoryProvenance)
        let wrongSession = MemoryScope(sessionID: "storage3181-wrong-session", projectID: scope.projectID)
        #expect(wrongSession.isValid && wrongSession.projectID == scope.projectID)
        #expect(throws: SyncAtomicImportError.foreignMemoryScope) {
            try target.previewAtomicBackup(draft, selecting: [.memories], memoryScope: wrongSession)
        }
        #expect(try disk(targetRoot) == before)
        #expect(try target.memoryStore.facts() == factsBefore)
        #expect(target.syncManager.dirtyScopes == [.settings])
        #expect(target.atomicBackupReceipt == nil)
        #expect(!target.atomicBackupInProgress && !target.atomicBackupReopenRequired && !target.atomicBackupRecoveryRequired)

        // Identical App consumer and identical cross-device draft: correct
        // memory identity must reach real confirmation, not merely a preview.
        let preview = try target.previewAtomicBackup(draft, selecting: [.memories], memoryScope: scope)
        #expect(preview.selected == [.memories] && preview.memoryScope == scope)
        #expect(try disk(targetRoot) == before)
        let receipt = try await target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        #expect(receipt.committed && receipt.reopenRequired && receipt.selected == [.memories])
        #expect(target.atomicBackupReceipt?.transactionID == receipt.transactionID)
        #expect(target.atomicBackupReopenRequired && !target.atomicBackupInProgress)
        // The old store generation is retired by commit. Observe its actual
        // published file, without claiming a new Store is an App restart.
        let published = try JSONDecoder().decode([MemoryFact].self,
            from: Data(contentsOf: target.memoryStore.fileURL))
        #expect(published.filter { $0.memoryScope == scope }.map(\.text) == ["source accepted"])
        #expect(published.filter { $0.memoryScope == neighbor }.map(\.text) == ["neighbor must survive commit"])
        #expect(try Data(contentsOf: sessionFile) == sessionBytes)
        #expect(try disk(targetRoot) != before)
    }
}
