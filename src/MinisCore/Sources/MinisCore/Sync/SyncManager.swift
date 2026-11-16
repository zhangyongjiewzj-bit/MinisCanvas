import Foundation

// MARK: - Snapshot envelope

/// 单个数据域恢复过程中的聚合错误（F14 P1-2，内部类型）。
///
/// 由 restoreSessions/restoreMemories/restoreSkills 在存在条目级写失败时
/// 抛出，携带逐条失败明细；`scopeResult(for:body:)` 捕获后转换为
/// `SyncScopeResult`。不直接暴露给 importSnapshot 的调用方
/// （对外统一为 `SyncImportError`）。
struct SyncScopeRestoreError: Error {
    let scope: SyncScope
    let failures: [SyncScopeFailure]
}

/// 快照载荷：清单 + 各域数据。所有字段可选 —— 只序列化本次导出的域，
/// 导入端按 manifest.scopes 逐个取用并校验完整性。
struct SyncSnapshotEnvelope: Codable {
    var manifest: SyncManifest
    var sessions: [ChatSession]?
    var memories: [MemoryFact]?
    var skills: [String: String]?      // skill id -> SKILL.md 原文
    var settings: AppSettings?
    /// Optional v1 settings-domain attachment. Old v1 envelopes omit it.
    var settingsRecovery: SettingsRecoveryAttachment? = nil
}

/// Export cannot rewrite a digest/approval-bound fact while retaining its
/// original provenance. No payload, credential, or fact identifier is exposed.
public enum SyncSnapshotExportError: Error, Equatable, Sendable {
    case credentialBoundMemory
}

// MARK: - SyncManager

/// 数据同步管理器（macOS 简化版，继承 OpenMinis 手机端 Sync 能力）。
/// 本工程使用本地快照与恢复，与 OpenMinis 的 iCloud 架构不同。
///
/// 能力：
/// - `exportSnapshot` / `importSnapshot`：把各 Store 数据打包成 JSON 快照 /
///   从快照恢复（sessions+memories+skills+settings）。
/// - `exportSnapshotFile` / `importSnapshotFile`：手动导出/导入文件，
///   macOS 版替代 iCloud 同步。
/// - 自动同步策略：外部在 Store 数据变更时调用 `markDirty(_:)` 标记
///   dirty；导出时 dirty 域写入 manifest.dirtyScopes 随快照带走，导出
///   成功后自动清除对应 dirty 标记。
///
/// TODO(iCloud): 手机端用 CloudKit/NSUbiquitousContainer 做自动云同步。
/// macOS 版当前只做手动文件导出/导入，
/// UI 层后续可接 NSUbiquitousContainer 实现跨设备自动同步。
public final class SyncManager: @unchecked Sendable {

    /// 手动导出文件的建议扩展名。
    public static let snapshotFileExtension = "minissync"

    // MARK: - 依赖的 Store

    public let sessionStore: SessionStore
    /// Shared production caller for snapshot session recovery. It owns the
    /// admission token lifecycle so late callbacks cannot upsert blindly.
    public let sessionRecoveryCoordinator: SessionRecoveryCoordinator
    public let memoryStore: MemoryStore
    public let memoryProposalConsumer: MemoryProposalConsumer
    public let skillStore: SkillStore
    public let settingsStore: SettingsStore
    let providerConfigurationDirectory: URL?
    let shortcutRecoveryTarget: ShortcutRecoveryTarget?

    /// 导出快照时写入清单的设备名。默认取本机名。
    public let deviceName: String

    private let lock = NSLock()
    // Each mark has its own identity. An export may consume only the marks
    // it captured, never a replacement mark arriving while stores are read.
    private var dirty: [SyncScope: UUID] = [:]
    let atomicProfileRegistered: Bool

    private var persistenceDomains: [PersistenceTransactionFence.Domain] {
        [.sessions(sessionStore.directory), .memories(memoryStore.directory),
         .skills(skillStore.skillsRoot), .settings(settingsStore.directory)]
    }
    private func atomicImporter() throws -> SyncAtomicImport { try SyncAtomicImport(manager: self) }
    public func previewAtomicImport(_ data: Data, selecting scopes: Set<SyncScope>? = nil,
                                    memoryScope: MemoryScope? = nil,
                                    shortcutPlan: ShortcutRecoveryPlan? = nil) throws -> SyncAtomicImportPreview {
        try atomicImporter().preview(data, selecting: scopes, memoryScope: memoryScope,
                                     shortcutPlan: shortcutPlan)
    }
    public func confirmAtomicImport(_ preview: SyncAtomicImportPreview, snapshot: Data,
                                    confirmation: SyncAtomicImportConfirmation,
                                    cancelled: () -> Bool = { false }) throws -> SyncAtomicImportReceipt {
        try atomicImporter().confirm(preview, snapshot: snapshot, confirmation: confirmation, cancelled: cancelled)
    }


    /// 快照编解码：默认日期策略（deferredToDate，Double 全精度），
    /// 保证导出/导入往返后 Date 精确一致（iso8601 会截断亚秒导致
    /// ChatSession 等值比较失败）。与 MemoryStore facts.json 同格式。
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    public init(
        sessionStore: SessionStore,
        memoryStore: MemoryStore,
        skillStore: SkillStore,
        settingsStore: SettingsStore,
        deviceName: String? = nil,
        memoryProposalConsumer: MemoryProposalConsumer? = nil,
        providerConfigurationDirectory: URL? = nil,
        shortcutRecoveryTarget: ShortcutRecoveryTarget? = nil
    ) {
        self.sessionStore = sessionStore
        self.sessionRecoveryCoordinator = SessionRecoveryCoordinator(store: sessionStore)
        self.memoryStore = memoryStore
        self.memoryProposalConsumer = memoryProposalConsumer
            ?? MemoryProposalConsumer(store: memoryStore)
        self.skillStore = skillStore
        self.settingsStore = settingsStore
        self.providerConfigurationDirectory = providerConfigurationDirectory
        self.shortcutRecoveryTarget = shortcutRecoveryTarget
        self.deviceName = deviceName ?? Self.currentDeviceName()
        self.atomicProfileRegistered = PersistenceTransactionFence.registerProfile([
            .sessions(sessionStore.directory), .memories(memoryStore.directory),
            .skills(skillStore.skillsRoot), .settings(settingsStore.directory)
        ])
    }

    /// 本机名称（fallback "Mac"）。
    public static func currentDeviceName() -> String {
        ProcessInfo.processInfo.hostName.isEmpty ? "Mac" : ProcessInfo.processInfo.hostName
    }

    // MARK: - Dirty 标记（自动同步策略）

    /// 当前处于 dirty 状态的数据域（onChange 标记后待下次导出带走）。
    public var dirtyScopes: Set<SyncScope> {
        lock.lock(); defer { lock.unlock() }
        return Set(dirty.keys)
    }

    /// 数据变更时调用：把该域标记为 dirty。
    public func markDirty(_ scope: SyncScope) {
        lock.lock(); defer { lock.unlock() }
        dirty[scope] = UUID()
    }

    /// 清除指定域的 dirty 标记（导出成功后自动调用；也供手动清除）。
    public func clearDirty(_ scope: SyncScope) {
        lock.lock(); defer { lock.unlock() }
        dirty.removeValue(forKey: scope)
    }

    /// 清除全部 dirty 标记。
    public func clearAllDirty() {
        lock.lock(); defer { lock.unlock() }
        dirty.removeAll()
    }

    // MARK: - 快照导出

    /// 导出指定域（默认全部四个域）为 JSON 快照 Data。
    ///
    /// 导出的 dirty 域会写入 manifest.dirtyScopes；导出成功后自动清除
    /// 这些域的 dirty 标记。
    public func exportSnapshot(scopes: Set<SyncScope>? = nil,
                               settingsRecovery: SettingsRecoveryAttachment? = nil) throws -> Data {
        let exported = try exportSnapshotData(scopes: scopes, settingsRecovery: settingsRecovery)
        clearExportedDirty(exported.dirty)
        return exported.data
    }

    /// Consume only captured generations under the same lock as markDirty.
    private func clearExportedDirty(_ exported: [SyncScope: UUID]) {
        lock.lock(); defer { lock.unlock() }
        for (scope, generation) in exported where dirty[scope] == generation {
            dirty.removeValue(forKey: scope)
        }
    }

    private func exportSnapshotData(
        scopes: Set<SyncScope>?,
        settingsRecovery: SettingsRecoveryAttachment?
    ) throws -> (data: Data, dirty: [SyncScope: UUID]) {
        let admission = PersistenceTransactionFence.read(persistenceDomains)
        defer { admission.release() }
        let selected = scopes ?? Set(SyncScope.allCases)
        guard settingsRecovery == nil || selected.contains(.settings) else {
            throw SyncManifestError.invalidSnapshot("settings attachment without settings scope")
        }
        try settingsRecovery?.validate()
        let dirtyNow = lock.withLock { dirty }
        // 只带本次导出实际携带的 dirty 域：导入端据此清除的 dirty 标记
        // 一定对应已恢复的数据，不会误清未恢复域。
        let carriedDirty = dirtyNow.filter { selected.contains($0.key) }

        var envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(
                exportedAt: Date(),
                deviceName: deviceName,
                scopes: selected.map(\.rawValue).sorted(),
                dirtyScopes: carriedDirty.isEmpty ? nil : carriedDirty.keys.map(\.rawValue).sorted()
            )
        )

        if selected.contains(.sessions) {
            envelope.sessions = sessionStore.listSessions()
        }
        if selected.contains(.memories) {
            envelope.memories = try readMemoryFacts().map(Self.memoryExportProjection)
        }
        if selected.contains(.skills) {
            envelope.skills = readSkillsContent()
        }
        if selected.contains(.settings) {
            envelope.settings = settingsStore.settings
            envelope.settingsRecovery = settingsRecovery
        }

        let data = try encoder.encode(envelope)
        // Return the exact marks captured for this snapshot; callers clear
        // them only after their existing data/file success boundary.
        return (data, carriedDirty)
    }

    /// 便捷方法：导出单个域。
    public func exportSnapshot(scope: SyncScope) throws -> Data {
        try exportSnapshot(scopes: [scope])
    }

    // MARK: - 快照导入

    /// 从快照 Data 恢复数据（默认恢复快照声明的全部域）。
    ///
    /// 恢复前校验清单（版本匹配 + scope 完整）；任一校验失败则抛错且
    /// 不写入任何数据。恢复语义：被恢复的域以快照内容为准
    /// （sessions 按 id upsert，memories 整文件替换，skills upsert，
    /// settings 整体替换）。
    ///
    /// F14 P1-2：逐域恢复并聚合 per-scope 结果 —— 某域写盘失败不中断
    /// 其余域；返回值携带每个域的成功/失败明细。存在失败域时抛
    /// `SyncImportError`（携带逐域结果），写失败不再静默返回成功。
    @discardableResult
    public func importSnapshot(
        _ data: Data,
        restoring scopes: Set<SyncScope>? = nil,
        memoryScope: MemoryScope? = nil
    ) throws -> SyncImportResult {
        let admission = PersistenceTransactionFence.read(persistenceDomains)
        defer { admission.release() }
        let envelope = try decodeEnvelope(data)
        let manifest = envelope.manifest
        try manifest.validate()
        // Direct per-scope import has no durable UserDefaults/provider journal.
        // An attached settings backup must use SyncAtomicImport instead.
        guard envelope.settingsRecovery == nil else {
            throw SyncManifestError.invalidSnapshot("settings attachment requires atomic import")
        }

        // scope 完整性：清单声明的每个域都必须可识别（v1 内未知 scope 名 =
        // 坏快照 —— 静默丢弃会导致零恢复却报成功，用户误以为数据已导入）。
        let unknown = manifest.scopes.filter { SyncScope(rawValue: $0) == nil }
        if !unknown.isEmpty {
            throw SyncManifestError.invalidSnapshot("unknown scopes: \(unknown.sorted())")
        }
        let declared = Set(manifest.scopes.compactMap(SyncScope.init(rawValue:)))
        let missing = declared.filter { payloadMissing(in: envelope, for: $0) }
        if !missing.isEmpty {
            throw SyncManifestError.incompletePayload(missing.map(\.rawValue).sorted())
        }

        let restore = scopes ?? declared
        guard !restore.isEmpty else {
            throw SyncManifestError.emptyScopes
        }
        let undeclared = restore.subtracting(declared)
        if !undeclared.isEmpty {
            throw SyncManifestError.missingScopes(undeclared.map(\.rawValue).sorted())
        }
        var scopeResults: [SyncScopeResult] = []
        if restore.contains(.sessions) {
            scopeResults.append(scopeResult(for: .sessions) { try self.restoreSessions(envelope.sessions ?? []) })
        }
        if restore.contains(.memories) {
            // Payload completeness is validated above. Keep the unwrap
            // explicit at the write boundary so a future caller cannot turn
            // a missing payload into an empty replace for the active scope.
            guard let memories = envelope.memories else {
                throw SyncManifestError.incompletePayload([SyncScope.memories.rawValue])
            }
            if let memoryScope {
                scopeResults.append(
                    scopeResult(for: .memories) {
                        try self.restoreMemories(
                            memories,
                            within: memoryScope
                        )
                    }
                )
            } else {
                scopeResults.append(
                    SyncScopeResult(
                        scope: .memories,
                        succeeded: false,
                        failures: [
                            SyncScopeFailure(
                                item: "memoryScope",
                                reason: "memory scope is required"
                            )
                        ]
                    )
                )
            }
        }
        if restore.contains(.skills) {
            scopeResults.append(scopeResult(for: .skills) { try self.restoreSkills(envelope.skills ?? [:]) })
        }
        if restore.contains(.settings), let settings = envelope.settings {
            scopeResults.append(scopeResult(for: .settings) { try restoreSettings(settings) })
        }

        let result = SyncImportResult(manifest: manifest, scopeResults: scopeResults)

        // 恢复完成后，快照里带过来的 dirty 域已落盘，清除本地对应标记。
        // 只清除恢复成功的域：失败域的 dirty 标记保留，等待下次导出/重试。
        if let snapshotDirty = manifest.dirtyScopes {
            let restoredOK = Set(result.succeededScopes)
            for raw in snapshotDirty {
                if let scope = SyncScope(rawValue: raw), restoredOK.contains(scope) {
                    clearDirty(scope)
                }
            }
        }

        // F14 P1-2：写盘失败不再静默返回成功 —— 存在失败域则抛
        // SyncImportError（携带逐域结果）；成功域的数据已生效。
        if !result.allSucceeded {
            throw SyncImportError(result: result)
        }
        return result
    }

    // MARK: - 手动文件导出 / 导入（macOS 版替代 iCloud）

    /// 手动导出快照到文件（建议扩展名 `.minissync`）。
    public func exportSnapshotFile(
        scopes: Set<SyncScope>? = nil,
        to url: URL,
        settingsRecovery: SettingsRecoveryAttachment? = nil
    ) throws {
        try exportSnapshotFile(scopes: scopes, to: url, protection: .legacy,
                               settingsRecovery: settingsRecovery)
    }

    /// Export either the legacy plaintext JSON snapshot or a password-
    /// protected envelope. The default method above remains the explicit
    /// legacy compatibility path for existing callers.
    public func exportSnapshotFile(
        scopes: Set<SyncScope>? = nil,
        to url: URL,
        protection: SyncSnapshotProtection,
        settingsRecovery: SettingsRecoveryAttachment? = nil
    ) throws {
        switch protection {
        case .legacy:
            let data = try exportSnapshot(scopes: scopes, settingsRecovery: settingsRecovery)
            try data.write(to: url, options: .atomic)
        case .password(let password):
            let selected = scopes ?? Set(SyncScope.allCases)
            let exported = try exportSnapshotData(scopes: selected,
                                                  settingsRecovery: settingsRecovery)
            let protected = try SyncProtectionCodec.seal(exported.data, password: password)
            try protected.write(to: url, options: .atomic)
            clearExportedDirty(exported.dirty)
        }
    }

    /// 从文件导入快照（内容即 `exportSnapshotFile` 产出的 Data）。
    /// F14 P1-2：返回逐域结果；存在写失败域时抛 `SyncImportError`。
    @discardableResult
    public func importSnapshotFile(
        from url: URL,
        restoring scopes: Set<SyncScope>? = nil,
        memoryScope: MemoryScope? = nil
    ) throws -> SyncImportResult {
        try importSnapshotFile(
            from: url,
            restoring: scopes,
            memoryScope: memoryScope,
            protection: .legacy
        )
    }

    /// Import a legacy plaintext or password-protected snapshot. Protected
    /// input never falls back to the plaintext decoder without a password.
    @discardableResult
    public func importSnapshotFile(
        from url: URL,
        restoring scopes: Set<SyncScope>? = nil,
        memoryScope: MemoryScope? = nil,
        protection: SyncSnapshotProtection
    ) throws -> SyncImportResult {
        let data = try readSnapshotFileData(from: url, protection: protection)
        return try importSnapshot(
            data,
            restoring: scopes,
            memoryScope: memoryScope
        )
    }

    /// Read and authenticate/decrypt a snapshot without touching any store.
    /// SettingsCenter uses this to build an atomic-import draft first.
    public func readSnapshotFileData(
        from url: URL,
        protection: SyncSnapshotProtection = .legacy
    ) throws -> Data {
        let data = try readSnapshotFileBytes(from: url)
        return try SyncProtectionCodec.open(
            data,
            password: {
                if case .password(let password) = protection { return password }
                return nil
            }()
        )
    }

    /// Inspect only the unprotected envelope marker; private payload bytes
    /// are not decoded.
    public func snapshotProtectionKind(from url: URL) throws -> SyncSnapshotProtectionKind {
        try SyncProtectionCodec.protectionKind(for: readSnapshotFileBytes(from: url))
    }

    private func readSnapshotFileBytes(from url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0,
              size <= SyncProtectionCodec.maximumProtectedFileBytes else {
            throw SyncProtectionError.resourceLimit
        }
        let data = try Data(contentsOf: url)
        guard data.count <= SyncProtectionCodec.maximumProtectedFileBytes else {
            throw SyncProtectionError.resourceLimit
        }
        return data
    }

    /// 建议的默认导出文件名：`MinisCanvas-<yyyyMMdd-HHmmss>.minissync`。
    public static func defaultSnapshotFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "MinisCanvas-\(formatter.string(from: now)).\(snapshotFileExtension)"
    }

    // MARK: - 各域打包 / 恢复

    private func readMemoryFacts() throws -> [MemoryFact] {
        try memoryStore.loadFacts()
    }

    /// Project legacy free-form text only at the outbound boundary. The
    /// persisted fact and every identity/scope/lifecycle field stay unchanged.
    /// Hash-bound facts fail closed rather than inventing a new approval.
    private static func memoryExportProjection(_ fact: MemoryFact) throws -> MemoryFact {
        let text = ContentSecretRedactor.redact(fact.text)
        guard text != fact.text else { return fact }
        guard fact.contentDigest == nil, fact.sourceProposalID == nil,
              fact.writeProvenance == nil else {
            throw SyncSnapshotExportError.credentialBoundMemory
        }
        return MemoryFact(
            id: fact.id, text: text, sourceSessionID: fact.sourceSessionID,
            createdAt: fact.createdAt, category: fact.category,
            memoryScope: fact.memoryScope, ownerUserID: fact.ownerUserID,
            visibility: fact.visibility, temporaryLifetimeID: fact.temporaryLifetimeID,
            sourceProposalID: fact.sourceProposalID, sourceRef: fact.sourceRef,
            contentDigest: fact.contentDigest, writeProvenance: fact.writeProvenance,
            revision: fact.revision, supersedesFactID: fact.supersedesFactID,
            lifecycleState: fact.lifecycleState, activatedAt: fact.activatedAt
        )
    }

    private func readSkillsContent() -> [String: String] {
        var result: [String: String] = [:]
        for skill in skillStore.skills {
            if let content = skillStore.rawContent(skill.id) {
                result[skill.id] = content
            }
        }
        return result
    }

    /// 逐域恢复的统一包装（F14 P1-2）：
    /// restore 闭包正常返回 → 该域成功；抛 `SyncScopeRestoreError` →
    /// 采用其条目级明细；抛其他错误 → 归并为该域单条失败。
    /// 单域失败不中断其余域，由 `importSnapshot` 汇总。
    private func scopeResult(for scope: SyncScope, body: () throws -> Void) -> SyncScopeResult {
        do {
            try body()
            return SyncScopeResult(scope: scope, succeeded: true, failures: [])
        } catch let error as SyncScopeRestoreError {
            return SyncScopeResult(scope: scope, succeeded: false, failures: error.failures)
        } catch {
            return SyncScopeResult(
                scope: scope,
                succeeded: false,
                failures: [SyncScopeFailure(item: scope.rawValue, reason: "\(error)")]
            )
        }
    }

    private func restoreSessions(_ sessions: [ChatSession]) throws {
        var failures: [SyncScopeFailure] = []
        var seenIDs: Set<String> = []
        let tokens = sessionRecoveryCoordinator.begin(sessions)
        for session in sessions {
            guard seenIDs.insert(session.id).inserted else {
                failures.append(
                    SyncScopeFailure(item: session.id, reason: "duplicate recovery session id")
                )
                continue
            }
            guard let token = tokens[session.id] else {
                failures.append(
                    SyncScopeFailure(item: session.id, reason: "recovery token missing")
                )
                continue
            }
            // A stale callback is a safe, observable restore failure: it never
            // falls back to updateSession and therefore cannot replace a newer
            // session created after recovery began.
            do {
                guard try sessionRecoveryCoordinator.apply(session, token: token) else {
                    failures.append(
                        SyncScopeFailure(item: session.id, reason: "stale recovery ignored")
                    )
                    continue
                }
            } catch {
                failures.append(SyncScopeFailure(item: session.id, reason: "\(error)"))
            }
        }
        if !failures.isEmpty {
            throw SyncScopeRestoreError(scope: .sessions, failures: failures)
        }
    }

    private func restoreMemories(
        _ facts: [MemoryFact],
        within memoryScope: MemoryScope
    ) throws {
        do {
            _ = try memoryProposalConsumer.restoreFacts(
                facts,
                within: memoryScope,
                mode: .replace,
                reason: "sync snapshot restore"
            )
        } catch {
            throw SyncScopeRestoreError(
                scope: .memories,
                failures: [SyncScopeFailure(item: "facts.json", reason: "\(error)")]
            )
        }
    }

    private func restoreSkills(_ skills: [String: String]) throws {
        var failures: [SyncScopeFailure] = []
        for (id, content) in skills.sorted(by: { $0.key < $1.key }) {
            // F14 P1-2：单个技能导入失败逐条记录并继续（尽力恢复），
            // 最后聚合抛出，不再 try? 静默吞掉。
            do {
                _ = try skillStore.importSkillThroughLifecycle(
                    content: content,
                    source: .file,
                    reason: "explicit sync snapshot restore"
                )
            } catch {
                failures.append(SyncScopeFailure(item: id, reason: "\(error)"))
            }
        }
        skillStore.reload()
        if !failures.isEmpty {
            throw SyncScopeRestoreError(scope: .skills, failures: failures)
        }
    }

    /// N1：权限与安全边界相关设置不随同步包跨机器迁移（对齐 Claude Code），
    /// 导入时一律保留本机现值；本机没有设置文件时即默认值。
    static func preservingLocalPermissionSettings(imported: AppSettings, local: AppSettings) -> AppSettings {
        var result = imported
        // agent：审批、绕过、自主权、子任务写入/删除审核、终端规则、浏览器写入、凭据剥离。
        result.agent.composerPolicy = local.agent.composerPolicy
        result.agent.approvalPolicy = local.agent.approvalPolicy
        result.agent.legacyAutomaticApprovalCompatibilityActive = local.agent.legacyAutomaticApprovalCompatibilityActive
        result.agent.legacyApprovalPolicyOriginal = local.agent.legacyApprovalPolicyOriginal
        result.agent.legacyApprovalPolicyNoticePending = local.agent.legacyApprovalPolicyNoticePending
        result.agent.legacyApprovalScopeNoticePending = local.agent.legacyApprovalScopeNoticePending
        result.agent.policyRuntimeDefaults = local.agent.policyRuntimeDefaults
        result.agent.terminalPolicy = local.agent.terminalPolicy
        result.agent.childMutationsEnabled = local.agent.childMutationsEnabled
        result.agent.childMutationsExplicitlySelected = local.agent.childMutationsExplicitlySelected
        result.agent.childModelOverridesEnabled = local.agent.childModelOverridesEnabled
        result.agent.childDeletionAutoReviewEnabled = local.agent.childDeletionAutoReviewEnabled
        result.agent.childDeletionAutoReviewWhitelist = local.agent.childDeletionAutoReviewWhitelist
        result.agent.browserWriteEnabled = local.agent.browserWriteEnabled
        result.agent.stripModelShellCredentials = local.agent.stripModelShellCredentials
        // privacy：文件访问边界（授权根、拒绝目录、挂载目录）、环境值脱敏、统计同意。
        result.privacy.allowedRootPath = local.privacy.allowedRootPath
        result.privacy.fileRootPolicyVersion = local.privacy.fileRootPolicyVersion
        result.privacy.deniedRootPaths = local.privacy.deniedRootPaths
        result.privacy.mountedFolderPaths = local.privacy.mountedFolderPaths
        result.privacy.redactEnvValues = local.privacy.redactEnvValues
        result.privacy.collectAnalytics = local.privacy.collectAnalytics
        return result
    }

    private func restoreSettings(_ settings: AppSettings) throws {
        let restored = Self.preservingLocalPermissionSettings(imported: settings, local: settingsStore.settings)
        switch settingsStore.replace(with: restored) {
        case .success:
            return
        case .failure(let error):
            throw SyncScopeRestoreError(
                scope: .settings,
                failures: [SyncScopeFailure(item: SettingsStore.fileName, reason: "\(error)")]
            )
        }
    }

    // MARK: - 内部

    private func decodeEnvelope(_ data: Data) throws -> SyncSnapshotEnvelope {
        do {
            return try decoder.decode(SyncSnapshotEnvelope.self, from: data)
        } catch {
            throw SyncManifestError.invalidSnapshot("\(error)")
        }
    }

    private func payloadMissing(in envelope: SyncSnapshotEnvelope, for scope: SyncScope) -> Bool {
        switch scope {
        case .sessions: return envelope.sessions == nil
        case .memories: return envelope.memories == nil
        case .skills: return envelope.skills == nil
        case .settings: return envelope.settings == nil
        }
    }
}
