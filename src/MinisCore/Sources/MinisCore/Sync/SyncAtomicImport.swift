import Foundation
import CryptoKit
import Darwin

public enum SyncAtomicImportError: Error, Equatable, Sendable {
    case invalidLayout, invalidSnapshot, missingMemoryScope, foreignMemoryScope
    case expiredPreview, stalePreview, confirmationRequired, replayedConfirmation
    case unsafePath, inventoryLimit, invalidJournal, rollbackIncomplete, recoveryRequired
    case io(String)
}

fileprivate struct SyncAtomicImportRootIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// Read-only overlap counts come from the same admitted destination generation
/// as the inventory hash. They describe restore semantics, not completed writes.
public struct SyncAtomicImportDomainPreview: Equatable, Sendable {
    public let scope: SyncScope
    public let incomingCount: Int
    public let existingCount: Int
    public let overlappingCount: Int
    public let retainedCount: Int
}

/// The immutable preview binds bytes, choices, destination inventory and epoch.
/// Creating one is read-only, including when the destination does not exist.
public struct SyncAtomicImportPreview: Sendable {
    public let id: UUID
    public let manifest: SyncManifest
    public let selected: Set<SyncScope>
    public let memoryScope: MemoryScope?
    public let snapshotHash: String
    public let inventoryHash: String
    public let expiresAt: Date
    public let confirmationIdentity: UUID
    public let destinationFileCount: Int
    public let domains: [SyncAtomicImportDomainPreview]
    fileprivate let epoch: [UInt64]
    fileprivate let layoutHash: String
    fileprivate let rootIdentities: [SyncAtomicImportRootIdentity?]
    fileprivate let shortcutPlan: ShortcutRecoveryPlan?
}
public struct SyncAtomicImportConfirmation: Sendable {
    public let previewID: UUID
    public let identity: UUID
    public init(preview: SyncAtomicImportPreview) {
        previewID = preview.id; identity = preview.confirmationIdentity
    }
}
public struct SyncAtomicImportReceipt: Codable, Sendable {
    public let transactionID: UUID
    public let snapshotHash: String
    public let selected: [SyncScope]
    public let backupURL: URL
    public let journalURL: URL
    public let fileCount: Int
    public let committed: Bool
    public let reopenRequired: Bool
    public let cancellationObservedAfterCommit: Bool
}

/// Multi-domain observational atomicity comes from admission plus a durable
/// file journal. No shared root or parent directory is ever exchanged.
public final class SyncAtomicImport: @unchecked Sendable {
    public struct Layout: Codable, Equatable, Sendable {
        public let sessionDirectory: URL
        public let memoryDirectory: URL
        public let settingsDirectory: URL
        public let skillsRoot: URL
        /// Exactly the already-composed provider metadata root: production
        /// settings root or the isolated profile's `providers` child.
        public let providerConfigurationDirectory: URL?
        /// nil is the production standard domain; a disposable profile uses
        /// its explicit suite name. This identity never comes from a backup.
        public let shortcutSuiteName: String?
        public init(sessionDirectory: URL, memoryDirectory: URL, settingsDirectory: URL,
                    skillsRoot: URL, providerConfigurationDirectory: URL? = nil,
                    shortcutSuiteName: String? = nil) throws {
            func canonical(_ url: URL) -> URL {
                URL(fileURLWithPath: PersistenceTransactionFence.stablePath(url), isDirectory: true)
            }
            guard [sessionDirectory, memoryDirectory, settingsDirectory, skillsRoot].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
                throw SyncAtomicImportError.invalidLayout
            }
            let sessionDirectory = canonical(sessionDirectory)
            let memoryDirectory = canonical(memoryDirectory)
            let settingsDirectory = canonical(settingsDirectory)
            let skillsRoot = canonical(skillsRoot)
            let urls = [sessionDirectory, memoryDirectory, settingsDirectory, skillsRoot]
            guard urls.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && PersistenceTransactionFence.stablePath($0.standardizedFileURL) == $0.path && canonical($0.resolvingSymlinksInPath()).path == $0.path }),
                  skillsRoot == settingsDirectory.appendingPathComponent("skills", isDirectory: true) || skillsRoot.path == settingsDirectory.appendingPathComponent("skills").path
            else { throw SyncAtomicImportError.invalidLayout }
            self.sessionDirectory = sessionDirectory; self.memoryDirectory = memoryDirectory
            self.settingsDirectory = settingsDirectory; self.skillsRoot = skillsRoot
            if let providerConfigurationDirectory {
                let provider = canonical(providerConfigurationDirectory)
                guard provider == settingsDirectory ||
                        provider == settingsDirectory.appendingPathComponent("providers", isDirectory: true),
                      canonical(provider.resolvingSymlinksInPath()).path == provider.path else {
                    throw SyncAtomicImportError.invalidLayout
                }
                self.providerConfigurationDirectory = provider
            } else {
                self.providerConfigurationDirectory = nil
            }
            if let shortcutSuiteName {
                guard !shortcutSuiteName.isEmpty, shortcutSuiteName.utf8.count <= 256,
                      shortcutSuiteName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                          || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
                    throw SyncAtomicImportError.invalidLayout
                }
            }
            self.shortcutSuiteName = shortcutSuiteName
            let roots = domains.map(\.root.path)
            for (index, root) in roots.enumerated() {
                for other in roots.dropFirst(index + 1) {
                    guard root != other && !root.hasPrefix(other + "/") && !other.hasPrefix(root + "/") else {
                        throw SyncAtomicImportError.invalidLayout
                    }
                }
            }
        }
        public var domains: [PersistenceTransactionFence.Domain] {
            [.sessions(sessionDirectory), .memories(memoryDirectory), .skills(skillsRoot), .settings(settingsDirectory)].sorted()
        }
        fileprivate var hash: String { Self.digest(try! JSONEncoder.sorted.encode(self)) }
        /// Old v1 journals remain discoverable after optional layout fields
        /// are added. Their directory identity was exactly these four roots.
        fileprivate var journalRootHash: String {
            struct OriginalLayout: Encodable {
                let sessionDirectory: URL
                let memoryDirectory: URL
                let settingsDirectory: URL
                let skillsRoot: URL
            }
            return Self.digest(try! JSONEncoder.sorted.encode(OriginalLayout(
                sessionDirectory: sessionDirectory, memoryDirectory: memoryDirectory,
                settingsDirectory: settingsDirectory, skillsRoot: skillsRoot
            )))
        }
        fileprivate var journalRoot: URL {
            settingsDirectory.appendingPathComponent(".minis-sync-import-v1", isDirectory: true)
                .appendingPathComponent(journalRootHash, isDirectory: true)
        }
        fileprivate static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        fileprivate func scope(for url: URL) -> SyncScope? {
            let path = PersistenceTransactionFence.stablePath(url)
            if path == settingsDirectory.appendingPathComponent("settings.json").path ||
                (url.deletingLastPathComponent().path == settingsDirectory.path && url.lastPathComponent.hasPrefix("settings.json.corrupt-")) { return .settings }
            if let providerConfigurationDirectory,
               path == providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName).path {
                return .settings
            }
            if path == settingsDirectory.appendingPathComponent("skills-enabled.json").path { return .skills }
            for domain in domains where domain.scope != .settings {
                if path.hasPrefix(domain.root.path + "/") { return domain.scope }
            }
            return nil
        }
        fileprivate var inventoryRoots: [URL] {
            let roots = Set([sessionDirectory, memoryDirectory, settingsDirectory]).sorted { $0.path < $1.path }
            return roots.filter { candidate in !roots.contains { $0 != candidate && candidate.path.hasPrefix($0.path + "/") } }
        }
    }

    public enum FaultPoint: String, Sendable { case backup, stage, prepareJournal, beforeFile, afterFile, fileFsync, directoryFsync, journalFsync, beforeCommitMarker, afterCommitMarker, rollbackFile, rollbackJournal }
    public typealias FaultInjector = @Sendable (FaultPoint, String?) throws -> Void
    private let manager: SyncManager
    public let layout: Layout
    private let fault: FaultInjector?
    // The serialized envelope, including both base64 layers, must be readable
    // by startup recovery. The smaller injected bound is test-only.
    static let maximumJournalBytes = 256 * 1024 * 1024
    private let journalByteLimit: Int
    private final class ConfirmationRegistry: @unchecked Sendable {
        let lock = NSLock()
        var consumed: Set<UUID> = []
    }
    private static let confirmations = ConfirmationRegistry()
    public convenience init(manager: SyncManager) throws { try self.init(manager: manager, fault: nil) }
    init(manager: SyncManager, fault: FaultInjector?, journalByteLimit: Int = SyncAtomicImport.maximumJournalBytes) throws {
        guard journalByteLimit > 0 && journalByteLimit <= Self.maximumJournalBytes else { throw SyncAtomicImportError.inventoryLimit }
        self.journalByteLimit = journalByteLimit
        guard manager.atomicProfileRegistered else { throw SyncAtomicImportError.invalidLayout }
        self.manager = manager; self.fault = fault
        self.layout = try Layout(sessionDirectory: manager.sessionStore.directory,
                                 memoryDirectory: manager.memoryStore.directory,
                                 settingsDirectory: manager.settingsStore.directory,
                                 skillsRoot: manager.skillStore.skillsRoot,
                                 providerConfigurationDirectory: manager.providerConfigurationDirectory,
                                 shortcutSuiteName: manager.shortcutRecoveryTarget?.suiteName)
    }

    public func preview(_ data: Data, selecting selected: Set<SyncScope>? = nil,
                        memoryScope: MemoryScope? = nil,
                        shortcutPlan: ShortcutRecoveryPlan? = nil,
                        now: Date = Date(), ttl: TimeInterval = 300) throws -> SyncAtomicImportPreview {
        let envelope = try validate(data, selected: selected, memoryScope: memoryScope)
        let scopes = selected ?? Set(envelope.manifest.scopes.compactMap(SyncScope.init(rawValue:)))
        if scopes.contains(.settings), envelope.settingsRecovery != nil {
            guard let shortcutPlan, let target = manager.shortcutRecoveryTarget,
                  layout.providerConfigurationDirectory != nil,
                  shortcutPlan.suiteName == layout.shortcutSuiteName,
                  target.suiteName == shortcutPlan.suiteName,
                  target.defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
                    == shortcutPlan.beforeData else { throw SyncAtomicImportError.invalidSnapshot }
        } else if shortcutPlan != nil {
            throw SyncAtomicImportError.invalidSnapshot
        }
        return try PersistenceTransactionFence.withRead(layout.domains) {
            for domain in layout.domains { try PersistenceTransactionFence.requireLiveRead(domain) }
            let rootIdentities = try Self.rootIdentities(layout)
            let inventory = try Self.inventory(layout)
            let domainCounts = try domainPreview(envelope, selecting: scopes, memoryScope: memoryScope, inventory: inventory)
            guard rootIdentities == (try Self.rootIdentities(layout)),
                  Self.inventoryHash(inventory) == Self.inventoryHash(try Self.inventory(layout))
            else { throw SyncAtomicImportError.stalePreview }
            return SyncAtomicImportPreview(id: UUID(), manifest: envelope.manifest, selected: scopes,
                                           memoryScope: memoryScope, snapshotHash: Layout.digest(data),
                                           inventoryHash: Self.inventoryHash(inventory),
                                           expiresAt: now.addingTimeInterval(min(max(ttl, 1), 900)), confirmationIdentity: UUID(),
                                           destinationFileCount: inventory.count,
                                           domains: domainCounts, epoch: PersistenceTransactionFence.epoch(layout.domains),
                                           layoutHash: layout.hash, rootIdentities: rootIdentities,
                                           shortcutPlan: shortcutPlan)
        }
    }

    private func domainPreview(_ envelope: SyncSnapshotEnvelope, selecting selected: Set<SyncScope>,
                               memoryScope: MemoryScope?, inventory: [String: Record]) throws -> [SyncAtomicImportDomainPreview] {
        func existingIdentifiers(for scope: SyncScope) -> Set<String> {
            guard let root = layout.domains.first(where: { $0.scope == scope })?.root.path else { return [] }
            return Set(inventory.keys.compactMap { path in
                guard path.hasPrefix(root + "/") else { return nil }
                let components = path.dropFirst(root.count + 1).split(separator: "/")
                if scope == .sessions, components.count == 1, components[0].hasSuffix(".json") {
                    let id = String(components[0].dropLast(5))
                    return SkillStore.isSafeSkillID(id) ? id : nil
                }
                if scope == .skills, components.count == 2, components[1] == "SKILL.md" { return String(components[0]) }
                return nil
            })
        }
        return try SyncScope.allCases.filter(selected.contains).map { scope in
            switch scope {
            case .sessions:
                let incoming = Set((envelope.sessions ?? []).map(\.id))
                let existing = existingIdentifiers(for: .sessions)
                return .init(scope: scope, incomingCount: incoming.count, existingCount: existing.count,
                             overlappingCount: incoming.intersection(existing).count, retainedCount: existing.subtracting(incoming).count)
            case .memories:
                let existing = try manager.memoryStore.loadFacts()
                let replaced = existing.filter { $0.memoryScope == memoryScope }.count
                return .init(scope: scope, incomingCount: envelope.memories?.count ?? 0, existingCount: existing.count,
                             overlappingCount: replaced, retainedCount: existing.count - replaced)
            case .skills:
                let incoming = Set((envelope.skills ?? [:]).keys)
                let existing = existingIdentifiers(for: .skills)
                return .init(scope: scope, incomingCount: incoming.count, existingCount: existing.count,
                             overlappingCount: incoming.intersection(existing).count, retainedCount: existing.subtracting(incoming).count)
            case .settings:
                let present = inventory[layout.settingsDirectory.appendingPathComponent("settings.json").path] == nil ? 0 : 1
                return .init(scope: scope, incomingCount: envelope.settings == nil ? 0 : 1, existingCount: present,
                             overlappingCount: present, retainedCount: 0)
            }
        }
    }

    @discardableResult
    public func confirm(_ preview: SyncAtomicImportPreview, snapshot data: Data,
                        confirmation: SyncAtomicImportConfirmation, now: Date = Date(),
                        cancelled: () -> Bool = { false }) throws -> SyncAtomicImportReceipt {
        guard confirmation.previewID == preview.id && confirmation.identity == preview.confirmationIdentity else { throw SyncAtomicImportError.confirmationRequired }
        guard now < preview.expiresAt && Date() < preview.expiresAt else { throw SyncAtomicImportError.expiredPreview }
        guard preview.layoutHash == layout.hash && preview.snapshotHash == Layout.digest(data) else { throw SyncAtomicImportError.stalePreview }
        let envelope = try validate(data, selected: preview.selected, memoryScope: preview.memoryScope)
        Self.confirmations.lock.lock()
        let fresh = Self.confirmations.consumed.insert(confirmation.identity).inserted
        Self.confirmations.lock.unlock()
        guard fresh else { throw SyncAtomicImportError.replayedConfirmation }
        if cancelled() { throw PersistenceTransactionError.cancelled }
        let admission = try PersistenceTransactionFence.exclusive(layout.domains, deadline: preview.expiresAt, cancelled: cancelled)
        var beforeView: PersistenceTransactionFence.BeforeView?
        var journal: Journal?
        let transactionID = UUID()
        let root = layout.journalRoot.appendingPathComponent(transactionID.uuidString, isDirectory: true)
        let journalURL = root.appendingPathComponent("journal.json")
        let backupURL = root.appendingPathComponent("backup.json")
        do {
            guard Date() < preview.expiresAt,
                  preview.epoch == PersistenceTransactionFence.epoch(layout.domains),
                  preview.rootIdentities == (try Self.rootIdentities(layout))
            else { throw SyncAtomicImportError.stalePreview }
            let before = try Self.inventory(layout)
            guard Self.inventoryHash(before) == preview.inventoryHash else { throw SyncAtomicImportError.stalePreview }
            if let plan = preview.shortcutPlan {
                guard let target = manager.shortcutRecoveryTarget,
                      plan.suiteName == target.suiteName,
                      target.defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
                        == plan.beforeData else { throw SyncAtomicImportError.stalePreview }
            }
            beforeView = PersistenceTransactionFence.BeforeView(files: before.filter { path, _ in
                let url = URL(fileURLWithPath: path)
                return layout.scope(for: url) != nil || ["chat-attachment-ownership.json", "chat-execution-state.json", "chat-composer-command-state.json", "chat-pasted-text.json", ".bl6-settings-transaction-unknown"].contains(url.lastPathComponent)
            }.mapValues(\.image),
                                                                settings: manager.settingsStore.settings,
                                                                skills: manager.skillStore.snapshot())
            admission.captureBefore(beforeView!)
            if cancelled() { throw PersistenceTransactionError.cancelled }
            let selectedBefore = before.filter { path, _ in layout.scope(for: URL(fileURLWithPath: path)).map(preview.selected.contains) ?? false }
            var value = Journal(version: preview.shortcutPlan == nil ? 1 : 2,
                                id: transactionID, layout: layout, phase: .prepared,
                                snapshotHash: preview.snapshotHash, selected: preview.selected.sorted { $0.rawValue < $1.rawValue },
                                entries: selectedBefore.keys.sorted().map { Entry(path: $0, before: selectedBefore[$0]?.image, after: selectedBefore[$0]?.image) },
                                neighbors: before.filter { selectedBefore[$0.key] == nil }.mapValues(\.fingerprint),
                                createdDirectories: [], completedFiles: 0,
                                shortcut: preview.shortcutPlan.map(ShortcutJournal.init))
            // Refuse an oversized PREPARED envelope before even creating the
            // backup workspace; no durable unreadable journal can be left behind.
            _ = try Self.encodeJournalEnvelope(try JSONEncoder.sorted.encode(value), maximumBytes: journalByteLimit)
            try Self.createPrivateDirectory(root)
            for scope in value.selected { try fault?(.backup, scope.rawValue) }
            try Self.writeDurable(try JSONEncoder.sorted.encode(value.entries), to: backupURL, mode: 0o600)
            try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit)
            journal = value
            let stage = root.appendingPathComponent("stage", isDirectory: true)
            try Self.createPrivateDirectory(stage)
            let stageLayout = try Layout(sessionDirectory: stage.appendingPathComponent("chat", isDirectory: true),
                                         memoryDirectory: stage.appendingPathComponent("memory", isDirectory: true),
                                         settingsDirectory: stage.appendingPathComponent("core", isDirectory: true),
                                         skillsRoot: stage.appendingPathComponent("core/skills", isDirectory: true),
                                         providerConfigurationDirectory: layout.providerConfigurationDirectory.map {
                                             $0 == layout.settingsDirectory
                                                 ? stage.appendingPathComponent("core", isDirectory: true)
                                                 : stage.appendingPathComponent("core/providers", isDirectory: true)
                                         }, shortcutSuiteName: layout.shortcutSuiteName)
            for (path, record) in selectedBefore.sorted(by: { $0.key < $1.key }) {
                let source = URL(fileURLWithPath: path)
                let staged = try Self.relocated(source, from: layout, to: stageLayout)
                try Self.createPrivateDirectory(staged.deletingLastPathComponent())
                try Self.writeDurable(record.image.data, to: staged, mode: record.image.mode)
            }
            let stagedManager = SyncManager(sessionStore: SessionStore(directory: stageLayout.sessionDirectory),
                                           memoryStore: MemoryStore(directory: stageLayout.memoryDirectory),
                                           skillStore: SkillStore(skillsRoot: stageLayout.skillsRoot),
                                           settingsStore: SettingsStore(directory: stageLayout.settingsDirectory), deviceName: manager.deviceName)
            var stagedEnvelope = envelope
            stagedEnvelope.settingsRecovery = nil
            let stagedSnapshot = try JSONEncoder.sorted.encode(stagedEnvelope)
            for scope in value.selected {
                try fault?(.stage, scope.rawValue)
                let stagedResult = try stagedManager.importSnapshot(stagedSnapshot, restoring: [scope], memoryScope: preview.memoryScope)
                guard stagedResult.allSucceeded else { throw SyncAtomicImportError.invalidSnapshot }
            }
            if value.selected.contains(.settings), let attachment = envelope.settingsRecovery,
               let liveProvider = layout.providerConfigurationDirectory,
               let stagedProvider = stageLayout.providerConfigurationDirectory {
                let original = liveProvider.appendingPathComponent(EnvVarStore.fileName)
                let image = try Self.stagedProviderImage(
                    attachment: attachment, previous: selectedBefore[original.path]?.image
                )
                let stagedURL = stagedProvider.appendingPathComponent(EnvVarStore.fileName)
                try Self.createPrivateDirectory(stagedProvider)
                try Self.writeDurable(image.data, to: stagedURL, mode: image.mode)
                guard let verified = try Self.readRecord(stagedURL)?.image,
                      verified.data == image.data else { throw SyncAtomicImportError.invalidSnapshot }
            }
            let stagedInventory = try Self.inventory(stageLayout)
            var after: [String: PersistenceTransactionFence.FileImage] = [:]
            for (path, record) in stagedInventory {
                let url = URL(fileURLWithPath: path)
                guard let scope = stageLayout.scope(for: url), preview.selected.contains(scope) else { continue }
                let canonical = try Self.relocated(url, from: stageLayout, to: layout)
                guard layout.scope(for: canonical) == scope else { throw SyncAtomicImportError.unsafePath }
                after[canonical.path] = record.image
            }
            // Canonical readers re-open and validate every selected staged domain.
            if preview.selected.contains(.sessions) {
                let strict = SessionStore(directory: stageLayout.sessionDirectory)
                for session in stagedManager.sessionStore.listSessions() {
                    guard strict.loadSession(id: session.id) == session else { throw SyncAtomicImportError.invalidSnapshot }
                }
            }
            if preview.selected.contains(.memories) { _ = try stagedManager.memoryStore.loadFacts(); _ = try stagedManager.memoryProposalConsumer.restoreReceipts() }
            if preview.selected.contains(.settings), stagedManager.settingsStore.lastPersistenceError != nil { throw SyncAtomicImportError.invalidSnapshot }
            value.entries = Set(selectedBefore.keys).union(after.keys).sorted().map {
                Entry(path: $0, before: selectedBefore[$0]?.image, after: after[$0])
            }.filter { $0.before?.data != $0.after?.data || $0.before?.mode != $0.after?.mode }
            let changedPaths = Set(value.entries.map(\.path))
            value.neighbors = before.filter { !changedPaths.contains($0.key) }.mapValues(\.fingerprint)
            value.createdDirectories = try Self.missingParents(for: value.entries, layout: layout)
            try Self.validateJournal(value, layout: layout)
            try fault?(.prepareJournal, nil)
            try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit); journal = value
            if cancelled() || Date() >= preview.expiresAt { throw PersistenceTransactionError.cancelled }
            value.phase = .committing
            try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit); journal = value
            for directory in value.createdDirectories.sorted(by: { $0.count < $1.count }) { try Self.createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true)) }
            for (index, entry) in value.entries.enumerated() {
                if cancelled() { throw PersistenceTransactionError.cancelled }
                try fault?(.beforeFile, entry.path)
                try Self.requireImage(entry.before, at: URL(fileURLWithPath: entry.path))
                try Self.install(entry.after, at: URL(fileURLWithPath: entry.path), fault: fault)
                try fault?(.afterFile, entry.path)
                value.completedFiles = index + 1
                try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit); journal = value
            }
            if let shortcut = value.shortcut {
                try Self.requireShortcut(shortcut.before, suiteName: shortcut.suiteName)
                try Self.installShortcut(shortcut.after, suiteName: shortcut.suiteName)
            }
            try Self.verify(value, committed: true)
            try fault?(.beforeCommitMarker, nil)
            value.phase = .committed
            try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit)
            journal = value
            admission.finish(committed: true, recoveryRequired: false, before: beforeView)
            // No fallible cleanup or cancellation can recast a durable commit as rollback.
            try? fault?(.afterCommitMarker, nil)
            let cancelledAfter = cancelled()
            for scope in preview.selected { manager.clearDirty(scope) }
            return SyncAtomicImportReceipt(transactionID: transactionID, snapshotHash: preview.snapshotHash,
                                           selected: value.selected, backupURL: backupURL, journalURL: journalURL,
                                           fileCount: value.entries.count, committed: true, reopenRequired: true,
                                           cancellationObservedAfterCommit: cancelledAfter)
        } catch {
            // Every fallible operation precedes the durable commit marker.
            if var value = journal {
                do {
                    try Self.rollback(value, fault: fault)
                    value.phase = .rolledBack
                    value.recoveryAcknowledged = true
                    try fault?(.rollbackJournal, nil)
                    try fault?(.journalFsync, value.phase.rawValue)
            try Self.writeJournal(value, at: journalURL, maximumBytes: journalByteLimit)
                    admission.finish(committed: false, recoveryRequired: false, before: nil)
                } catch {
                    admission.finish(committed: false, recoveryRequired: true, before: beforeView)
                    throw SyncAtomicImportError.rollbackIncomplete
                }
            } else {
                // Before PREPARED, no live target has been changed. Remove only
                // this private transaction workspace; cleanup failure stays visible.
                if FileManager.default.fileExists(atPath: root.path) {
                    do { try FileManager.default.removeItem(at: root) }
                    catch {
                        admission.finish(committed: false, recoveryRequired: true, before: beforeView)
                        throw SyncAtomicImportError.recoveryRequired
                    }
                }
                admission.finish(committed: false, recoveryRequired: false, before: nil)
            }
            throw error
        }
    }

    /// The App calls this before constructing even SettingsStore/SkillStore.
    public static func recoverBeforeStores(layout: Layout) throws {
        guard PersistenceTransactionFence.registerProfile(layout.domains) else { throw SyncAtomicImportError.invalidLayout }
        guard FileManager.default.fileExists(atPath: layout.journalRoot.path) else { return }
        try PersistenceTransactionFence.bootstrapBeforeStores(layout.domains) {
            try validatePath(layout.journalRoot, directory: true)
            let roots = try FileManager.default.contentsOfDirectory(at: layout.journalRoot, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            for root in roots {
                guard UUID(uuidString: root.lastPathComponent) != nil else { throw SyncAtomicImportError.invalidJournal }
                try validatePath(root, directory: true)
                let url = root.appendingPathComponent("journal.json")
                guard let record = try readRecord(url), record.image.data.count <= maximumJournalBytes,
                      let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: record.image.data),
                      envelope.hash == Layout.digest(envelope.payload),
                      var journal = try? JSONDecoder().decode(Journal.self, from: envelope.payload) else { throw SyncAtomicImportError.invalidJournal }
                try validateJournal(journal, layout: layout)
                if journal.recoveryAcknowledged {
                    guard journal.phase == .committed || journal.phase == .rolledBack else { throw SyncAtomicImportError.invalidJournal }
                    continue
                }
                switch journal.phase {
                case .prepared, .committing:
                    try rollback(journal, fault: nil)
                    journal.phase = .rolledBack; try writeJournal(journal, at: url)
                case .committed:
                    // The commit marker is durable, while UserDefaults has no
                    // filesystem fsync guarantee. Finish the recorded after
                    // images before constructing any Store on this profile.
                    if journal.version == 2 {
                        for entry in journal.entries {
                            let path = URL(fileURLWithPath: entry.path)
                            if (try? requireImage(entry.after, at: path)) == nil {
                                try install(entry.after, at: path)
                            }
                        }
                        if let shortcut = journal.shortcut {
                            try installShortcut(shortcut.after, suiteName: shortcut.suiteName)
                        }
                    }
                    try verify(journal, committed: true, verifyNeighbors: false)
                case .rolledBack: try verify(journal, committed: false)
                }
                // This durable acknowledgement permits subsequent ordinary store
                // mutations without treating an old receipt as the current epoch.
                journal.recoveryAcknowledged = true
                try writeJournal(journal, at: url)
            }
        }
    }

    private func validate(_ data: Data, selected: Set<SyncScope>?, memoryScope: MemoryScope?) throws -> SyncSnapshotEnvelope {
        guard data.count <= 64 * 1024 * 1024,
              let envelope = try? JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data) else { throw SyncAtomicImportError.invalidSnapshot }
        try envelope.manifest.validate()
        let declared = Set(envelope.manifest.scopes.compactMap(SyncScope.init(rawValue:)))
        guard declared.count == envelope.manifest.scopes.count,
              envelope.manifest.dirtyScopes?.allSatisfy({ declared.contains(SyncScope(rawValue: $0) ?? .sessions) && SyncScope(rawValue: $0) != nil }) ?? true else { throw SyncAtomicImportError.invalidSnapshot }
        guard envelope.settingsRecovery == nil || declared.contains(.settings) else {
            throw SyncAtomicImportError.invalidSnapshot
        }
        if let attachment = envelope.settingsRecovery {
            guard (try? attachment.validate()) != nil else {
                throw SyncAtomicImportError.invalidSnapshot
            }
        }
        let scopes = selected ?? declared
        guard !scopes.isEmpty && scopes.isSubset(of: declared) else { throw SyncAtomicImportError.invalidSnapshot }
        for scope in declared {
            switch scope {
            case .sessions: guard let sessions = envelope.sessions, Set(sessions.map(\.id)).count == sessions.count,
                                 sessions.allSatisfy({ session in
                                     let identities = [session.id, session.rootSessionID] + [session.parentSessionID, session.forkedFromSessionID].compactMap { $0 }
                                     return identities.allSatisfy(SkillStore.isSafeSkillID) && session.lineageVersion == ChatSession.currentLineageVersion
                                 }) else { throw SyncAtomicImportError.invalidSnapshot }
            case .memories: guard envelope.memories != nil else { throw SyncAtomicImportError.invalidSnapshot }
            case .skills: guard let skills = envelope.skills,
                               skills.allSatisfy({ SkillStore.isSafeSkillID($0.key) && $0.value.utf8.count <= SkillStore.maxSkillContentBytes && SkillStore.slugify(SkillStore.parse(skillMD: $0.value).name) == $0.key }) else { throw SyncAtomicImportError.invalidSnapshot }
            case .settings: guard let settings = envelope.settings, settings.settingsVersion <= AppSettings.currentVersion else { throw SyncAtomicImportError.invalidSnapshot }
            }
        }
        if scopes.contains(.memories) {
            guard let memoryScope, memoryScope.isValid else { throw SyncAtomicImportError.missingMemoryScope }
            guard envelope.memories?.allSatisfy({ $0.memoryScope == memoryScope && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? false else { throw SyncAtomicImportError.foreignMemoryScope }
        }
        return envelope
    }

    private struct Record {
        let image: PersistenceTransactionFence.FileImage
        var fingerprint: Fingerprint { Fingerprint(hash: Layout.digest(image.data), mode: image.mode, size: image.data.count) }
    }
    private static func stagedProviderImage(
        attachment: SettingsRecoveryAttachment,
        previous: PersistenceTransactionFence.FileImage?
    ) throws -> PersistenceTransactionFence.FileImage {
        let existing: [EnvVarEntry]
        if let previous {
            guard let decoded = try? JSONDecoder().decode([EnvVarEntry].self, from: previous.data),
                  Set(decoded.map(\.name)).count == decoded.count,
                  decoded.allSatisfy({ $0.name == EnvVarStore.canonicalName($0.name)
                      && EnvVarStore.isValidName($0.name) }) else {
                throw SyncAtomicImportError.invalidSnapshot
            }
            existing = decoded
        } else {
            existing = []
        }
        // Retain ordinary environment variables. Recovered providers are cold:
        // no source credential, target Keychain linkage, readiness or grant.
        let ordinary = existing.filter { !$0.isProviderRecord }
        guard Set(ordinary.map(\.name)).isDisjoint(with: Set(attachment.providers.map(\.name))),
              Set(ordinary.map { $0.id.lowercased() }).isDisjoint(
                  with: Set(attachment.providers.map { $0.id.lowercased() })
              ) else {
            throw SyncAtomicImportError.invalidSnapshot
        }
        let imported = attachment.providers.map { provider in
            EnvVarEntry(
                id: provider.id, name: provider.name, value: "",
                isSecret: true, valueInKeychain: false,
                createdAt: provider.createdAt, baseURL: provider.baseURL,
                modelNames: provider.modelNames, protocolType: provider.protocolType,
                modelContextWindows: provider.modelContextWindows
            )
        }
        let candidate = (ordinary + imported).sorted { $0.name < $1.name }
        let data = try JSONEncoder.sorted.encode(candidate)
        guard data.count <= 16 * 1024 * 1024 else { throw SyncAtomicImportError.inventoryLimit }
        return PersistenceTransactionFence.FileImage(
            data: data, mode: previous?.mode ?? 0o600, modifiedAt: Date()
        )
    }
    private struct Fingerprint: Codable, Equatable { let hash: String; let mode: UInt16; let size: Int }
    private struct Entry: Codable {
        let path: String; let before: PersistenceTransactionFence.FileImage?; let after: PersistenceTransactionFence.FileImage?
        let beforeHash: String?; let afterHash: String?
        init(path: String, before: PersistenceTransactionFence.FileImage?, after: PersistenceTransactionFence.FileImage?) {
            self.path = path; self.before = before; self.after = after
            beforeHash = before.map { Layout.digest($0.data) }; afterHash = after.map { Layout.digest($0.data) }
        }
    }
    private struct JournalEnvelope: Codable { let payload: Data; let hash: String }
    private struct ShortcutJournal: Codable {
        let suiteName: String?
        let before: Data?
        let after: Data
        let beforeHash: String?
        let afterHash: String
        init(_ plan: ShortcutRecoveryPlan) {
            suiteName = plan.suiteName; before = plan.beforeData; after = plan.afterData
            beforeHash = plan.beforeData.map(Layout.digest); afterHash = Layout.digest(plan.afterData)
        }
    }
    private struct Journal: Codable {
        enum Phase: String, Codable { case prepared = "PREPARED", committing = "COMMITTING", committed = "COMMITTED", rolledBack = "ROLLED_BACK" }
        let version: Int; let id: UUID; let layout: Layout; var phase: Phase
        let snapshotHash: String; let selected: [SyncScope]; var entries: [Entry]
        var neighbors: [String: Fingerprint]; var createdDirectories: [String]; var completedFiles: Int
        var shortcut: ShortcutJournal? = nil
        var recoveryAcknowledged: Bool = false
    }
    private static func inventoryHash(_ inventory: [String: Record]) -> String {
        Layout.digest(try! JSONEncoder.sorted.encode(inventory.mapValues(\.fingerprint)))
    }
    private static func rootIdentities(_ layout: Layout) throws -> [SyncAtomicImportRootIdentity?] {
        let roots = Set([
            layout.sessionDirectory, layout.memoryDirectory,
            layout.settingsDirectory, layout.skillsRoot
        ]).sorted { $0.path < $1.path }
        return try roots.map { root in
            try validatePath(root, directory: true)
            var info = stat()
            if lstat(root.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw SyncAtomicImportError.unsafePath
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw SyncAtomicImportError.unsafePath }
            return SyncAtomicImportRootIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
    }
    private static func inventory(_ layout: Layout) throws -> [String: Record] {
        var result: [String: Record] = [:]; var total = 0
        func walk(_ url: URL) throws {
            if url.path == layout.settingsDirectory.appendingPathComponent(".minis-sync-import-v1").path { return }
            var info = stat()
            if lstat(url.path, &info) != 0 { if errno == ENOENT { return }; throw SyncAtomicImportError.io("inventory") }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try validatePath(url, directory: true)
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) { try walk(child) }
            } else {
                guard let record = try readRecord(url) else { throw SyncAtomicImportError.stalePreview }
                total += record.image.data.count
                guard total <= 256 * 1024 * 1024 && result.count < 10_000 else { throw SyncAtomicImportError.inventoryLimit }
                result[url.path] = record
            }
        }
        for root in layout.inventoryRoots { try walk(root) }
        return result
    }
    private static func validatePath(_ url: URL, directory: Bool) throws {
        guard url.isFileURL && PersistenceTransactionFence.stablePath(url.standardizedFileURL) == url.path && PersistenceTransactionFence.stablePath(url.resolvingSymlinksInPath()) == PersistenceTransactionFence.stablePath(url) else { throw SyncAtomicImportError.unsafePath }
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                let isDirectory = current != url || directory
                guard (info.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFREG),
                      isDirectory || (info.st_nlink == 1 && info.st_uid == getuid()) else { throw SyncAtomicImportError.unsafePath }
            } else if errno != ENOENT { throw SyncAtomicImportError.unsafePath }
            current.deleteLastPathComponent()
        }
    }
    private static func readRecord(_ url: URL) throws -> Record? {
        try validatePath(url, directory: false)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw SyncAtomicImportError.io("read") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 && before.st_nlink == 1 && (before.st_mode & S_IFMT) == S_IFREG && before.st_size >= 0 && before.st_size <= Int64(maximumJournalBytes) else { throw SyncAtomicImportError.unsafePath }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw SyncAtomicImportError.io("read") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count)); guard data.count <= maximumJournalBytes else { throw SyncAtomicImportError.inventoryLimit }
        }
        var after = stat(); var path = stat()
        guard fstat(fd, &after) == 0 && lstat(url.path, &path) == 0 && before.st_dev == path.st_dev && before.st_ino == path.st_ino && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SyncAtomicImportError.stalePreview }
        return Record(image: .init(data: data, mode: UInt16(before.st_mode & 0o777), modifiedAt: Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9)))
    }
    private static func relocated(_ url: URL, from: Layout, to: Layout) throws -> URL {
        guard let scope = from.scope(for: url) else { throw SyncAtomicImportError.unsafePath }
        if let provider = from.providerConfigurationDirectory,
           url.path == provider.appendingPathComponent(EnvVarStore.fileName).path {
            guard let targetProvider = to.providerConfigurationDirectory else {
                throw SyncAtomicImportError.unsafePath
            }
            return targetProvider.appendingPathComponent(EnvVarStore.fileName)
        }
        if scope == .settings { return to.settingsDirectory.appendingPathComponent(url.lastPathComponent) }
        if url.path == from.settingsDirectory.appendingPathComponent("skills-enabled.json").path { return to.settingsDirectory.appendingPathComponent("skills-enabled.json") }
        guard let source = from.domains.first(where: { $0.scope == scope })?.root,
              let target = to.domains.first(where: { $0.scope == scope })?.root,
              url.path.hasPrefix(source.path + "/") else { throw SyncAtomicImportError.unsafePath }
        return target.appendingPathComponent(String(url.path.dropFirst(source.path.count + 1)))
    }
    private static func createPrivateDirectory(_ url: URL) throws {
        try validatePath(url, directory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let parent = url.deletingLastPathComponent()
        try createPrivateDirectory(parent)
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw SyncAtomicImportError.io("mkdir") }
        try syncDirectory(parent)
    }
    private static func syncDirectory(_ url: URL) throws {
        try validatePath(url, directory: true)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAtomicImportError.io("directory open") }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw SyncAtomicImportError.io("directory fsync") }
    }
    private static func writeDurable(_ data: Data, to url: URL, mode: UInt16, fault: FaultInjector? = nil) throws {
        try validatePath(url, directory: false)
        let parent = url.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw SyncAtomicImportError.io("parent open") }; defer { close(parentFD) }
        let name = ".sync-" + UUID().uuidString
        let fd = openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else { throw SyncAtomicImportError.io("temporary open") }
        var openFD = true
        defer { if openFD { close(fd) }; unlinkat(parentFD, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw SyncAtomicImportError.io("write") }; offset += count
            }
        }
        try fault?(.fileFsync, url.path)
        guard fchmod(fd, mode_t(mode)) == 0 && fsync(fd) == 0 else { throw SyncAtomicImportError.io("file fsync") }
        guard close(fd) == 0 else { throw SyncAtomicImportError.io("close") }; openFD = false
        try validatePath(url, directory: false)
        guard renameat(parentFD, name, parentFD, url.lastPathComponent) == 0 else { throw SyncAtomicImportError.io("rename") }
        try fault?(.directoryFsync, url.path)
        guard fsync(parentFD) == 0 else { throw SyncAtomicImportError.io("directory fsync") }
    }
    private static func install(_ image: PersistenceTransactionFence.FileImage?, at url: URL, fault: FaultInjector? = nil) throws {
        if let image { try writeDurable(image.data, to: url, mode: image.mode, fault: fault) }
        else if FileManager.default.fileExists(atPath: url.path) {
            try validatePath(url, directory: false)
            guard unlink(url.path) == 0 else { throw SyncAtomicImportError.io("unlink") }; try syncDirectory(url.deletingLastPathComponent())
        }
    }
    private static func requireImage(_ expected: PersistenceTransactionFence.FileImage?, at url: URL) throws {
        let actual = try readRecord(url)?.image
        guard actual?.data == expected?.data && actual?.mode == expected?.mode else { throw SyncAtomicImportError.stalePreview }
    }
    private static func missingParents(for entries: [Entry], layout: Layout) throws -> [String] {
        var missing = Set<String>()
        for entry in entries where entry.after != nil {
            var parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path) {
                guard layout.inventoryRoots.contains(where: { parent.path == $0.path || parent.path.hasPrefix($0.path + "/") }) else { throw SyncAtomicImportError.unsafePath }
                missing.insert(parent.path); parent.deleteLastPathComponent()
            }
        }
        return missing.sorted()
    }
    private static func validateJournal(_ journal: Journal, layout: Layout) throws {
        let sameOriginalRoots = journal.layout.sessionDirectory == layout.sessionDirectory
            && journal.layout.memoryDirectory == layout.memoryDirectory
            && journal.layout.settingsDirectory == layout.settingsDirectory
            && journal.layout.skillsRoot == layout.skillsRoot
        let compatibleLayout = journal.version == 1
            ? sameOriginalRoots
                && (journal.layout.providerConfigurationDirectory == nil
                    || journal.layout.providerConfigurationDirectory == layout.providerConfigurationDirectory)
                && (journal.layout.shortcutSuiteName == nil
                    || journal.layout.shortcutSuiteName == layout.shortcutSuiteName)
            : journal.layout == layout
        guard (journal.version == 1 || journal.version == 2), compatibleLayout,
              ((journal.version == 1 && journal.shortcut == nil)
                || (journal.version == 2 && journal.shortcut != nil)),
              journal.selected.count > 0, Set(journal.selected).count == journal.selected.count,
              journal.snapshotHash.count == 64, journal.completedFiles >= 0,
              journal.completedFiles <= journal.entries.count,
              journal.entries.map(\.path) == journal.entries.map(\.path).sorted(),
              Set(journal.entries.map(\.path)).count == journal.entries.count else {
            throw SyncAtomicImportError.invalidJournal
        }
        if let shortcut = journal.shortcut {
            guard journal.selected.contains(.settings),
                  shortcut.suiteName == layout.shortcutSuiteName,
                  shortcut.after.count <= 1024 * 1024,
                  (shortcut.before?.count ?? 0) <= 1024 * 1024,
                  shortcut.beforeHash == shortcut.before.map(Layout.digest),
                  shortcut.afterHash == Layout.digest(shortcut.after) else {
                throw SyncAtomicImportError.invalidJournal
            }
        }
        for entry in journal.entries {
            let url = URL(fileURLWithPath: entry.path)
            guard let scope = layout.scope(for: url), journal.selected.contains(scope), entry.before != nil || entry.after != nil,
                  entry.beforeHash == entry.before.map({ Layout.digest($0.data) }),
                  entry.afterHash == entry.after.map({ Layout.digest($0.data) }) else { throw SyncAtomicImportError.invalidJournal }
            try validatePath(url, directory: false)
        }
        for directory in journal.createdDirectories {
            guard journal.entries.contains(where: { $0.path.hasPrefix(directory + "/") }) && layout.inventoryRoots.contains(where: { directory == $0.path || directory.hasPrefix($0.path + "/") }) else { throw SyncAtomicImportError.invalidJournal }
        }
        for path in journal.neighbors.keys {
            guard layout.inventoryRoots.contains(where: { path.hasPrefix($0.path + "/") }) && !journal.entries.contains(where: { $0.path == path }) else { throw SyncAtomicImportError.invalidJournal }
        }
    }
    static func encodeJournalEnvelope(_ payload: Data, maximumBytes: Int = SyncAtomicImport.maximumJournalBytes) throws -> Data {
        guard maximumBytes > 0 && maximumBytes <= maximumJournalBytes else { throw SyncAtomicImportError.inventoryLimit }
        let envelope = JournalEnvelope(payload: payload, hash: Layout.digest(payload))
        let encoded = try JSONEncoder.sorted.encode(envelope)
        guard encoded.count <= maximumBytes else { throw SyncAtomicImportError.inventoryLimit }
        return encoded
    }
    private static func writeJournal(_ journal: Journal, at url: URL, maximumBytes: Int = SyncAtomicImport.maximumJournalBytes) throws {
        let encoded = try encodeJournalEnvelope(try JSONEncoder.sorted.encode(journal), maximumBytes: maximumBytes)
        try writeDurable(encoded, to: url, mode: 0o600)
    }
    private static func verify(_ journal: Journal, committed: Bool, verifyNeighbors: Bool = true) throws {
        for entry in journal.entries { try requireImage(committed ? entry.after : entry.before, at: URL(fileURLWithPath: entry.path)) }
        if let shortcut = journal.shortcut {
            try requireShortcut(committed ? shortcut.after : shortcut.before,
                                suiteName: shortcut.suiteName)
        }
        guard verifyNeighbors else { return }
        let actual = try inventory(journal.layout)
        for (path, expected) in journal.neighbors { guard actual[path]?.fingerprint == expected else { throw SyncAtomicImportError.stalePreview } }
        let known = Set(journal.entries.map(\.path)).union(journal.neighbors.keys)
        guard Set(actual.keys).isSubset(of: known) else { throw SyncAtomicImportError.stalePreview }
    }
    private static func rollback(_ journal: Journal, fault: FaultInjector?) throws {
        var failed = false
        if let shortcut = journal.shortcut {
            do { try installShortcut(shortcut.before, suiteName: shortcut.suiteName) }
            catch { failed = true }
        }
        for entry in journal.entries.reversed() {
            do { try fault?(.rollbackFile, entry.path); try install(entry.before, at: URL(fileURLWithPath: entry.path)) }
            catch { failed = true }
        }
        for directory in journal.createdDirectories.sorted(by: { $0.count > $1.count }) {
            if FileManager.default.fileExists(atPath: directory) {
                if rmdir(directory) != 0 { failed = true }
                else { do { try syncDirectory(URL(fileURLWithPath: directory).deletingLastPathComponent()) } catch { failed = true } }
            }
        }
        do { try verify(journal, committed: false) } catch { failed = true }
        guard !failed else { throw SyncAtomicImportError.rollbackIncomplete }
    }

    private static func shortcutDefaults(suiteName: String?) throws -> UserDefaults {
        if let suiteName {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw SyncAtomicImportError.invalidLayout
            }
            return defaults
        }
        return .standard
    }

    private static func requireShortcut(_ expected: Data?, suiteName: String?) throws {
        let defaults = try shortcutDefaults(suiteName: suiteName)
        guard defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey) == expected else {
            throw SyncAtomicImportError.stalePreview
        }
    }

    private static func installShortcut(_ image: Data?, suiteName: String?) throws {
        let defaults = try shortcutDefaults(suiteName: suiteName)
        if let image {
            defaults.set(image, forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
        } else {
            defaults.removeObject(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
        }
        guard defaults.synchronize() else { throw SyncAtomicImportError.io("shortcut synchronize") }
        guard defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey) == image else {
            throw SyncAtomicImportError.io("shortcut write")
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
