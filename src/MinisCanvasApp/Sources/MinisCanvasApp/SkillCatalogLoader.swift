import Foundation
import MinisCore

// MARK: - U4 聊天输入区插件 / Skill 选择器：目录条目与加载器

/// 选择器目录条目种类。
enum PickerItemKind: String, Sendable {
    case skill    // SKILL.md 技能（App 技能库）
    case plugin   // MCP 服务器（mcps.json）
}

/// 输入区「插件 / 技能」选择器的一个可选条目。
/// id 带命名空间前缀（skill:<id> / plugin:<id>），跨来源去重用。
struct PickerCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: PickerItemKind
    let name: String
    let detail: String
    /// SKILL.md body（去除 frontmatter；plugin 条目为 nil），仅作目录展示
    /// 缓存。发送时不得把它当作授权或 prompt 内容，必须走 canonical
    /// SkillInjector 的 turn snapshot。
    let content: String?
    let version: String
    let source: SkillSource?
    let path: URL?
    let isEnabled: Bool

    init(
        id: String,
        kind: PickerItemKind,
        name: String,
        detail: String,
        content: String? = nil,
        version: String = "1.0.0",
        source: SkillSource? = nil,
        path: URL? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.content = content
        self.version = version
        self.source = source
        self.path = path
        self.isEnabled = isEnabled
    }
}

/// The picker reads the canonical App SkillStore and MCP server catalog.
enum SkillCatalogLoader {

    // MARK: 技能（SKILL.md）

    /// 解析单个 SKILL.md 内容为目录条目（纯函数，可单测）。
    /// frontmatter 无 name 时回退目录名；空内容返回 nil。
    static func skillItem(
        skillMD content: String,
        directoryName: String,
        path: URL? = nil
    ) -> PickerCatalogItem? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let parsed = SkillCatalogDocumentPolicy.admit(content) else { return nil }
        return skillItem(parsed: parsed, directoryName: directoryName, path: path)
    }

    private static func skillItem(
        parsed: SkillCatalogParsedDocument,
        directoryName: String,
        path: URL?
    ) -> PickerCatalogItem? {
        guard parsed.documentByteCount > 0,
              SkillFilesystemBoundary.isSafePathComponent(directoryName) else { return nil }
        guard SkillFilesystemBoundary.isSafeDisplayName(parsed.name) else { return nil }
        let name = parsed.name == SkillStore.defaultSkillName ? directoryName : parsed.name
        let id = SkillStore.slugify(directoryName)
        guard SkillManifestIdentity.isValidSkillID(id),
              SkillManifestIdentity.isValidSkillVersion(parsed.version) else { return nil }
        return PickerCatalogItem(
            id: "skill:" + id,
            kind: .skill,
            name: name,
            detail: [parsed.description, parsed.argumentHint.map { "参数：\($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
            content: parsed.body,
            version: parsed.version,
            source: .app,
            path: path
        )
    }

    /// Read only the canonical App store.
    static func storeSkillItems(from store: SkillStore) -> [PickerCatalogItem] {
        var diagnostics = SkillCatalogDiagnosticReport()
        return storeSkillItems(from: store, diagnostics: &diagnostics)
    }

    /// App catalog projection with bounded, path-free rejection diagnostics.
    static func storeSkillItemsWithDiagnostics(
        from store: SkillStore
    ) -> (items: [PickerCatalogItem], diagnostics: SkillCatalogDiagnosticReport) {
        var diagnostics = SkillCatalogDiagnosticReport()
        let items = storeSkillItems(from: store, diagnostics: &diagnostics)
        return (items, diagnostics)
    }

    private static func storeSkillItems(
        from store: SkillStore,
        diagnostics: inout SkillCatalogDiagnosticReport
    ) -> [PickerCatalogItem] {
        let rootLocator = SkillCatalogDiagnostic.safeLocator(store.skillsRoot.lastPathComponent)
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(store.skillsRoot),
              SkillFilesystemBoundary.isApprovedRoot(store.skillsRoot, matching: rootIdentity) else {
            diagnostics.record(source: .app, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        let candidates = store.allSkills().filter { skill in
            guard SkillManifestIdentity.isValidSkillID(skill.id),
                  SkillFilesystemBoundary.isSafeDisplayName(skill.name),
                  SkillManifestIdentity.isValidSkillVersion(skill.version) else {
                diagnostics.record(source: .app, locator: SkillCatalogDiagnostic.safeLocator(skill.id), code: .invalidMetadata)
                return false
            }
            return true
        }
        guard let snapshots = store.catalogFileSnapshots(for: candidates.map(\.id), expectedRootIdentity: rootIdentity) else {
            diagnostics.batchIncomplete = true
            diagnostics.record(source: .app, locator: rootLocator, code: .snapshotRejected)
            return []
        }
        let items = candidates.compactMap { skill in
            let locator = SkillCatalogDiagnostic.safeLocator(skill.id)
            let directory = store.skillDirectoryURL(for: skill.id)
            let skillFile = directory.appendingPathComponent("SKILL.md")
            guard let snapshot = snapshots[skill.id] else {
                diagnostics.record(source: .app, locator: locator, code: .snapshotRejected)
                return nil
            }
            guard let parsed = SkillCatalogDocumentPolicy.admit(snapshot.content) else {
                diagnostics.record(source: .app, locator: locator, code: .documentRejected)
                return nil
            }
            let content = snapshot.content
            guard SkillFilesystemBoundary.isSafeDisplayName(parsed.name),
                  parsed.version == skill.version else {
                diagnostics.record(source: .app, locator: locator, code: .invalidMetadata)
                return nil
            }
            guard SkillManifestIdentity.resolve(
                skillID: skill.id,
                skillVersion: parsed.version,
                content: content,
                manifestData: snapshot.manifestData
            ) != nil else {
                diagnostics.record(source: .app, locator: locator, code: .identityRejected)
                return nil
            }
            return PickerCatalogItem(
                id: "skill:" + skill.id,
                kind: .skill,
                name: parsed.name == SkillStore.defaultSkillName ? skill.name : parsed.name,
                detail: [parsed.description, parsed.argumentHint.map { "参数：\($0)" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                content: parsed.body,
                version: parsed.version,
                source: .app,
                path: skillFile,
                isEnabled: skill.isEnabled
            )
        }
        .sorted(by: stableSort)
        guard SkillFilesystemBoundary.isApprovedRoot(store.skillsRoot, matching: rootIdentity) else {
            diagnostics.record(source: .app, locator: rootLocator, code: .untrustedEntry)
            return []
        }
        return items
    }

    // MARK: 插件（MCP 服务器）

    /// MCP 服务器 → 插件条目（停用服务器保留展示，detail 标注）。
    static func pluginItems(servers: [MCPServer]) -> [PickerCatalogItem] {
        var seenIDs = Set<String>()
        var duplicateIDs = Set<String>()
        var items: [PickerCatalogItem] = []
        for server in servers {
            guard SkillManifestIdentity.isValidSkillID(server.id),
                  SkillFilesystemBoundary.isSafeDisplayName(server.name) else { continue }
            if !seenIDs.insert(server.id).inserted { duplicateIDs.insert(server.id) }
            let transport = server.type == .http ? "HTTP" : "stdio"
            var detail = "\(transport) · \(server.transportSummary)"
            if !server.enabled { detail += "（已停用）" }
            items.append(PickerCatalogItem(
                id: "plugin:" + server.id,
                kind: .plugin,
                name: server.name,
                detail: detail,
                isEnabled: server.enabled
            ))
        }
        return items.filter { item in
            guard let id = SkillManifestIdentity.canonicalCatalogID(item.id) else { return false }
            return !duplicateIDs.contains(id)
        }
    }

    // MARK: 汇总

    /// Composer 可用目录：发现项只有
    /// canonical 生命周期允许注入才可选择。插件按独立命名空间加入。
    static func loadCatalog(
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool] = [:]
    ) -> [PickerCatalogItem] {
        loadCatalogWithDiagnostics(
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        ).items
    }

    /// Complete catalog projection plus bounded diagnostics from both skill
    /// sources. Plugin admission remains on its existing independent path.
    static func loadCatalogWithDiagnostics(
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool] = [:]
    ) -> (items: [PickerCatalogItem], diagnostics: SkillCatalogDiagnosticReport) {
        var diagnostics = SkillCatalogDiagnosticReport()
        let appItems = storeSkillItems(from: appStore, diagnostics: &diagnostics)
        // Catalog discovery does not grant execution authority.
        let runtimeStore = appStore.makeSnapshotStore()
        let registry = SkillRegistry(store: runtimeStore)
        let availableSkills: [String: (version: String, body: String)] = Dictionary(uniqueKeysWithValues: runtimeStore.allSkills().compactMap { skill in
            guard let receipt = runtimeStore.lifecycleReceipt(for: skill.id),
                  let content = runtimeStore.rawContent(skill.id),
                  registry.rejection(for: skill, content: content) == nil,
                  runtimeStore.isInjectable(skill, within: receipt.scope),
                  let parsed = SkillCatalogDocumentPolicy.admit(content) else { return nil }
            return (skill.id, (version: skill.version, body: parsed.body))
        })

        var seen = Set<String>()
        var result: [PickerCatalogItem] = []
        func add(_ newItems: [PickerCatalogItem]) {
            for item in newItems {
                if item.kind == .skill {
                    guard item.source == .app,
                          let skillID = SkillManifestIdentity.canonicalCatalogID(item.id),
                          let available = availableSkills[skillID],
                          available.version == item.version,
                          available.body == item.content,
                          isEnabled(item, states: enabledStates) else { continue }
                }
                guard seen.insert(item.id).inserted else { continue }
                result.append(item)
            }
        }
        add(appItems)
        add(pluginItems(servers: servers))
        return (result.sorted(by: stableSort), diagnostics)
    }

    private static func stableSort(_ lhs: PickerCatalogItem, _ rhs: PickerCatalogItem) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    /// Compatibility shell for callers that only have a picker catalog.
    ///
    /// A catalog carries display/cache data, not lifecycle authority. Keep the
    /// old entry point source-compatible but fail closed; ChatStore's turn
    /// snapshot must route Skill IDs through SkillInjector instead.
    static func buildInjection(
        for userMessage: String,
        from catalog: [PickerCatalogItem],
        maxInjectedSkills: Int = 5,
        maxInjectedCharacters: Int = 8_000,
        maxCharactersPerSkill: Int? = nil
    ) -> SkillInjectionResult {
        _ = maxInjectedSkills
        _ = maxCharactersPerSkill
        let selectedSkills = catalog.filter { $0.kind == .skill }
        let receipts = selectedSkills.map { item in
            let skillID = item.id.hasPrefix("skill:")
                ? String(item.id.dropFirst("skill:".count))
                : item.id
            return SkillInjectionReceipt(
                receiptID: SkillInjectionReceipt.stableID(
                    skillID: skillID,
                    version: item.version,
                    contentHash: "",
                    reason: "canonical_skill_injector_required"
                ),
                request: userMessage,
                skillID: skillID,
                version: item.version,
                contentHash: "",
                matchedTerms: [],
                injectedCharacters: 0,
                budget: max(0, maxInjectedCharacters),
                omittedReason: "canonical_skill_injector_required",
                sourceIdentity: "picker-cache:\(item.id)",
                state: .rejected
            )
        }
        return SkillInjectionResult(fragment: nil, receipts: receipts)
    }

    static func loadDefaultCatalog() -> [PickerCatalogItem] {
        let inputs = defaultInputs()
        return loadCatalog(
            appStore: inputs.appStore,

            servers: inputs.servers,
            enabledStates: inputs.enabledStates
        )
    }

    static func defaultInputs(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        processName: String = ProcessInfo.processInfo.processName
    ) -> (
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool]
    ) {
        // Settings and the Composer must read the same validated launch
        // profile. A packaged field run is not a formal test process; falling
        // back to production defaults here hides its approved canonical
        // skills and can consult the wrong catalog root.
        let profile: RuntimeIsolationProfile
        switch RuntimeIsolationProfile.launchProfileResolution(
            processEnvironment: processEnvironment,
            processArguments: processArguments,
            processName: processName
        ) {
        case .ready(let resolved):
            profile = resolved
        case .blocked:
            profile = RuntimeIsolationProfile.blockedProfile()
        }
        return (
            appStore: SkillStore(skillsRoot: profile.minisCoreDirectory
                .appendingPathComponent("skills", isDirectory: true)),

            servers: MCPServerManager(
                fileURL: profile.mcpConfigurationURL,
                keychain: profile.makeKeychainStore()
            ).listServers(),
            enabledStates: SkillsStateStore.load(from: profile.skillStateURL)
        )
    }

    private static func isEnabled(_ item: PickerCatalogItem, states: [String: Bool]) -> Bool {
        guard item.isEnabled else { return false }
        guard item.source == .app,
              let rawID = item.id.split(separator: ":", maxSplits: 1).last
        else { return true }
        let prefix = "app:"
        return states[prefix + rawID] ?? true
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        SkillFilesystemBoundary.isCanonicallyContained(candidate, in: root)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

// MARK: - 进程级目录缓存（R9 卡顿专项）

/// Cache the canonical App skill and MCP projections outside interactive UI work.
/// 启动时后台预热缓存；
/// 刷新按钮走后台重扫（refreshDefaultCatalog），不阻塞主线程。
enum SkillCatalogCache {

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedDefaultSnapshot: SkillCatalogCacheSnapshot?
    private nonisolated(unsafe) static var nextGeneration: UInt64 = 0
    private nonisolated(unsafe) static var requestGate = SkillCatalogCacheRequestGate()

    /// Drop the process projection after a settings lifecycle commit. The
    /// next request/picker load must observe the live SkillStore enablement
    /// state instead of reusing a catalog captured before the toggle.
    static func invalidateDefaultCatalog() {
        lock.lock()
        cachedDefaultSnapshot = nil
        requestGate.invalidate()
        nextGeneration &+= 1
        lock.unlock()
    }

    /// 带缓存的生产入口：缓存命中直接返回（零 I/O）；未命中（首次调用 /
    /// 缓存被失效）同步扫描并写缓存。此函数本身保持同步，生产调用方必须在
    /// detached/background task 中消费；主线程 UI 走 ChatStore 的异步入口。
    static func loadDefaultCatalogCached() -> [PickerCatalogItem] {
        loadDefaultCatalogCachedWithDiagnostics().catalog
    }

    /// Read-only status projection for the picker view. It never triggers a
    /// scan, and returns only the fixed-label/count summary of the last cache
    /// snapshot, if one exists.
    static var cachedDefaultDiagnosticSummary: String? {
        lock.lock()
        let summary = cachedDefaultSnapshot?.stableSummary
        lock.unlock()
        return summary
    }

    /// Read-only lifecycle state for the existing picker cache consumer.
    /// Invalidated/absent cache state is represented by nil rather than by a
    /// fabricated successful empty catalog.
    static var cachedDefaultStatus: SkillCatalogRefreshStatus? {
        lock.lock()
        let status = cachedDefaultSnapshot?.status
        lock.unlock()
        return status
    }

    /// Picker cache snapshot for the production default roots. The report and
    /// opaque input scope travel with the catalog so a consumer can reject a
    /// late result instead of displaying a prior root's diagnostics.
    static func loadDefaultCatalogCachedWithDiagnostics() -> SkillCatalogCacheSnapshot {
        let inputs = defaultInputs()
        return loadCatalogCachedWithDiagnostics(
            appStore: inputs.appStore,

            servers: inputs.servers,
            enabledStates: inputs.enabledStates
        )
    }

    /// 同步重扫默认目录并更新缓存（须在后台线程调用，见 ChatStore.refreshPickerCatalogInBackground）。
    @discardableResult
    static func refreshDefaultCatalog() -> [PickerCatalogItem] {
        refreshDefaultCatalogWithDiagnostics().catalog
    }

    /// Forced default-root refresh that always advances the projection
    /// generation, even when the input scope itself is unchanged.
    @discardableResult
    static func refreshDefaultCatalogWithDiagnostics() -> SkillCatalogCacheSnapshot {
        let inputs = defaultInputs()
        return refreshCatalogWithDiagnostics(
            appStore: inputs.appStore,

            servers: inputs.servers,
            enabledStates: inputs.enabledStates
        )
    }

    /// Cache entry point with explicit roots for hermetic callers/tests. The
    /// opaque scope key makes a different root a cache miss without storing a
    /// raw path in a diagnostic or status message.
    static func loadCatalogCachedWithDiagnostics(
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool] = [:]
    ) -> SkillCatalogCacheSnapshot {
        let scopeKey = scopeKey(
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        )
        // An earlier load may cache an empty projection for this root. Once a
        // later store snapshot contains an enabled, explicitly activated skill,
        // that empty projection is not a valid cache hit. The regular catalog
        // scan below still performs every
        // source, hash, scope and enablement check before publishing an item.
        let hasApprovedCandidate = appStore.allSkills().contains { skill in
            guard skill.isEnabled,
                  enabledStates["app:\(skill.id)"] ?? true,
                  skill.integrity.state == .verified,
                  let manifest = skill.integrity.manifest,
                  let receipt = appStore.lifecycleReceipt(for: skill.id) else { return false }
            return receipt.action == .activate
                && receipt.state == .active
                && receipt.contentHash == manifest.contentHash
                && receipt.sourceIdentity == "skill:\(skill.id)@\(manifest.contentHash)"
        }
        lock.lock()
        let candidateHit = cachedDefaultSnapshot?.scopeKey == scopeKey
            ? cachedDefaultSnapshot
            : nil
        let hit = candidateHit?.catalog.contains(where: { $0.kind == .skill }) == false
            && hasApprovedCandidate ? nil : candidateHit
        let request = hit == nil ? requestGate.begin(scopeKey: scopeKey) : nil
        if request != nil { cachedDefaultSnapshot = nil }
        lock.unlock()
        if let hit { return hit }
        return storeSnapshot(
            request: request!,
            scopeKey: scopeKey,
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        )
    }

    /// Forced explicit-root refresh, useful to make root replacement an
    /// observable generation transition in a settings/picker consumer.
    @discardableResult
    static func refreshCatalogWithDiagnostics(
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool] = [:]
    ) -> SkillCatalogCacheSnapshot {
        let scopeKey = scopeKey(
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        )
        let request = beginCacheRequest(scopeKey: scopeKey)
        return storeSnapshot(
            request: request,
            scopeKey: scopeKey,
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        )
    }

    private static func defaultInputs() -> (
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool]
    ) {
        SkillCatalogLoader.defaultInputs()
    }

    private static func scopeKey(
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool]
    ) -> String {
        SkillCatalogScopeKey.make(
            appSkillsRoot: appStore.skillsRoot,

            servers: servers.map(\.id),
            enabledStates: enabledStates
        )
    }

    private static func storeSnapshot(
        request: SkillCatalogCacheRequestToken,
        scopeKey: String,
        appStore: SkillStore,

        servers: [MCPServer],
        enabledStates: [String: Bool]
    ) -> SkillCatalogCacheSnapshot {
        let result = SkillCatalogLoader.loadCatalogWithDiagnostics(
            appStore: appStore,

            servers: servers,
            enabledStates: enabledStates
        )
        lock.lock()
        nextGeneration &+= 1
        let snapshot = SkillCatalogCacheSnapshot(
            catalog: result.items,
            diagnostics: result.diagnostics,
            status: result.diagnostics.rejectedCount == 0 ? .ready : .degraded,
            generation: nextGeneration,
            scopeKey: scopeKey
        )
        if requestGate.accepts(request), !result.diagnostics.batchIncomplete {
            cachedDefaultSnapshot = snapshot
        }
        lock.unlock()
        return snapshot
    }

    private static func beginCacheRequest(scopeKey: String) -> SkillCatalogCacheRequestToken {
        lock.lock()
        let request = requestGate.begin(scopeKey: scopeKey)
        cachedDefaultSnapshot = nil
        lock.unlock()
        return request
    }
}

/// Bind Composer projection reads to the App composition root. Creating a
/// second MCPServerManager for a picker read may retire the live manager's
/// persisted discovery snapshot during its initializer.
@MainActor
enum ProductionPickerCatalogWiring {
    @discardableResult
    static func bind(chat: ChatStore, center: SettingsCenter,
                     profile: RuntimeIsolationProfile) -> Bool {
        // A mismatched owner must not fall back to the default constructors.
        chat.pickerCatalogLoader = { [] }
        chat.pickerCatalogRefreshLoader = { [] }
        // URL equality retains a directory trailing slash even when both
        // values identify the same canonical path.
        let canonical: (URL) -> String = {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard canonical(center.skillStore.skillsRoot) == canonical(profile.minisCoreDirectory
            .appendingPathComponent("skills", isDirectory: true)),
              canonical(center.mcpManager.fileURL) == canonical(profile.mcpConfigurationURL)
        else { return false }
        let skillStore = center.skillStore
        let manager = center.mcpManager
        let stateURL = profile.skillStateURL
        chat.pickerCatalogLoader = {
            SkillCatalogCache.loadCatalogCachedWithDiagnostics(
                appStore: skillStore,
                servers: manager.listServers(),
                enabledStates: SkillsStateStore.load(from: stateURL)
            ).catalog
        }
        chat.pickerCatalogRefreshLoader = {
            SkillCatalogCache.refreshCatalogWithDiagnostics(
                appStore: skillStore,
                servers: manager.listServers(),
                enabledStates: SkillsStateStore.load(from: stateURL)
            ).catalog
        }
        return true
    }
}
