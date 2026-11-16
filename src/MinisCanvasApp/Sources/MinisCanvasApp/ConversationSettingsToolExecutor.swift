import Foundation
import MinisCore

enum ConversationSettingsToolError: Error, Equatable {
    case ownerUnavailable
    case approvalRequired
    case invalidInput
    case undoReceiptStale(String)
    case sessionChangeRejected(String)
    case unsupportedApprovalPolicy
}

extension ConversationSettingsToolError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .undoReceiptStale(let message), .sessionChangeRejected(let message): return message
        case .ownerUnavailable: return "设置所有者不可用。"
        case .approvalRequired: return "此设置改动需要先经用户批准。"
        case .invalidInput: return "设置请求参数无效。"
        case .unsupportedApprovalPolicy: return BL6SettingsApprovedInput.unsupportedApprovalPolicyMessage
        }
    }
}

private struct ConversationSettingsCatalogEntry: Encodable {
    let id: String
    let kind: BL6SettingValueKind
    let agentMutable: Bool
    let secret: Bool
}

private struct ConversationSettingsCatalogResponse: Encodable {
    let catalogRevision: String
    let sidebarRevision: String?
    let shortcutRevision: String?
    let mcpRevision: String?
    let sessionRevision: String
    let memoryRevision: String?
    let skillsRevision: String?
    let schedulerRevision: String?
    let preferencesRevision: String?
    let hooksRevision: String?
    let entries: [ConversationSettingsCatalogEntry]
    let values: [String: BL6SettingValue]
}

@MainActor
extension ChatStore {
    /// The installed live SettingsCenter remains the sole owner. A suspended
    /// attachment or a different profile cannot satisfy a conversation read.
    func conversationSettingsSnapshot(
        from center: SettingsCenter,
        sessionDirectory: URL
    ) -> BL6EffectiveSettingsSnapshot? {
        guard SettingsCenter.active === center,
              BridgeStore.canonicalSessionDirectoryIdentity(center.sessionStore.directory)
                == BridgeStore.canonicalSessionDirectoryIdentity(sessionDirectory),
              let admitted = effectiveSettingsSnapshotSource?(),
              let live = center.bl6EffectiveSettingsSnapshot,
              admitted == live else { return nil }
        return live
    }

    func dispatchApprovedConversationSettings(
        inputData: Data,
        approvedCall: BL6SettingsApprovedCallContext,
        authorizationFacts: ApprovalAuthorizationContext,
        center: SettingsCenter,
        shortcutStore: ShortcutStore?,
        skillsStore: SkillsStore?,
        schedulerStore: SchedulerTaskStore? = nil,
        sidebarWidthSetting: SessionSidebarWidthSetting,
        sessionDirectory: URL
    ) async -> Result<BL6SettingsReceipt, BL6SettingsDispatchError> {
        guard conversationSettingsSnapshot(from: center, sessionDirectory: sessionDirectory) != nil else {
            return .failure(.transactionUnknown)
        }
        return await center.dispatchApprovedBL6Settings(
            inputData: inputData,
            approvedCall: approvedCall,
            currentAuthorizationFacts: authorizationFacts,
            currentPolicyRevision: { [weak self] in self?.composerPolicyFacts.revision ?? "" },
            currentGrantEpoch: { [weak self] in self?.composerPolicyFacts.grantEpoch ?? "" },
            currentProfileDirectory: center.settingsStore.directory,
            shortcutStore: shortcutStore,
            skillsStore: skillsStore,
            sidebarWidthSetting: sidebarWidthSetting,
            sessionOwner: self,
            schedulerStore: schedulerStore
        )
    }
}

@MainActor
extension ChatStore {
    func activeThread(id: String) -> ChatThread? {
        sessions.first { $0.id.uuidString == id }
    }

    func sessionListRows(currentSessionID: String) -> [SessionReadTool.SessionListRow] {
        func rows(_ list: [ChatThread], _ state: SessionReadTool.SessionListRow.State)
            -> [SessionReadTool.SessionListRow] {
            list.map { thread in
                SessionReadTool.SessionListRow(
                    sessionID: thread.id.uuidString, title: thread.title, updatedAt: thread.updatedAt,
                    state: state, current: thread.id.uuidString == currentSessionID,
                    pinned: thread.pinned, unread: thread.unread, projectName: thread.projectName,
                    group: groups.first { $0.id == thread.groupID }?.name)
            }
        }
        let trashed = sessionTrashEntries.map { entry in
            SessionReadTool.SessionListRow(
                sessionID: entry.receipt.targetID, title: entry.title, updatedAt: entry.deletedAt,
                state: .trashed, current: false, pinned: false, unread: false,
                projectName: nil, group: nil)
        }
        return rows(sessions, .active) + rows(archivedSessions, .archived) + trashed
    }
}

struct ConversationSessionCatalogRow: Sendable {
    let id: String
    let kind: BL6SettingValueKind
    let value: BL6SettingValue
    let mutable: Bool
}

@MainActor
extension ChatStore {
    func refreshSessionTitleDirectory() {
        sessionTitleDirectory.replace(with: Dictionary(
            (sessions + archivedSessions).map { ($0.id.uuidString, $0.title) },
            uniquingKeysWith: { first, _ in first }
        ))
    }

    private func groupName(of thread: ChatThread) -> String {
        groups.first { $0.id == thread.groupID }?.name ?? ""
    }

    private func projectValue(of thread: ChatThread) -> BL6SettingValue {
        .object([
            "name": .text(thread.projectName ?? ""),
            "working_directory": .text(thread.workingDirectory ?? "")
        ])
    }

    /// Covers session metadata only (title, pin, unread, group, project, archive and
    /// trash state), never messages or updatedAt, so an ordinary turn does not change it.
    func conversationSessionRevision(currentSessionID: String) -> String {
        var lines = ["current|\(currentSessionID)"]
        for (state, list) in [("active", sessions), ("archived", archivedSessions)] {
            for thread in list {
                lines.append([
                    state, thread.id.uuidString, thread.title, "\(thread.pinned)", "\(thread.unread)",
                    thread.groupID?.uuidString ?? "", thread.projectID ?? "",
                    thread.projectName ?? "", thread.workingDirectory ?? ""
                ].joined(separator: "|"))
            }
        }
        lines += groups.map { "group|\($0.id.uuidString)|\($0.name)" }
        lines += sessionTrashEntries.map { "trash|\($0.receipt.targetID)|\($0.id.uuidString)" }
        return DeletionGate.fingerprint(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    func conversationSessionCatalogRows(currentSessionID: String) -> [ConversationSessionCatalogRow] {
        let currentID = UUID(uuidString: currentSessionID)
        var rows: [ConversationSessionCatalogRow] = []
        func row(_ id: String, _ kind: BL6SettingValueKind, _ value: BL6SettingValue, mutable: Bool = true) {
            rows.append(ConversationSessionCatalogRow(id: id, kind: kind, value: value, mutable: mutable))
        }
        if let current = sessions.first(where: { $0.id == currentID }) {
            row("session.current.id", .text, .text(current.id.uuidString), mutable: false)
            row("session.current.title", .text, .text(current.title))
            row("session.current.pinned", .toggle, .toggle(current.pinned))
            row("session.current.unread", .toggle, .toggle(current.unread))
            row("session.current.archived", .toggle, .toggle(false))
            row("session.current.group", .text, .text(groupName(of: current)))
            row("session.current.project", .object, projectValue(of: current))
        }
        for thread in sessions where thread.id != currentID {
            row("session.\(thread.id.uuidString).archived", .toggle, .toggle(false))
            row("session.\(thread.id.uuidString).trashed", .toggle, .toggle(false))
        }
        for thread in archivedSessions {
            row("session.\(thread.id.uuidString).archived", .toggle, .toggle(true))
            row("session.\(thread.id.uuidString).trashed", .toggle, .toggle(false))
        }
        for entry in sessionTrashEntries {
            row("session.\(entry.receipt.targetID).trashed", .toggle, .toggle(true))
        }
        return rows
    }

    /// `session.*` writes of conversation_settings, one key per call. Uses the same ChatStore
    /// functions as the sidebar; returns the rollback value of the changed key.
    func applyConversationSessionChange(
        key: String, value: BL6SettingValue, currentSessionID: String
    ) -> Result<BL6SettingValue, BL6SettingsDispatchError> {
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "session" else {
            return .failure(.invalidIntent("unknown session setting"))
        }
        let currentID = UUID(uuidString: currentSessionID)
        let isCurrent = parts[1] == "current"
        guard let id = isCurrent ? currentID : UUID(uuidString: parts[1]) else {
            return .failure(.invalidIntent("unknown session id"))
        }
        let field = parts[2]
        if id == currentID && (field == "archived" || field == "trashed") {
            return .failure(.invalidIntent(
                field == "archived"
                    ? "不能在当前会话内归档自身，请在侧栏操作"
                    : "不能把当前会话移入回收站，请在侧栏操作"))
        }
        if isCurrent, !["title", "pinned", "unread", "group", "project"].contains(field) {
            return .failure(.invalidIntent("unknown session setting"))
        }
        if !isCurrent, !["archived", "trashed"].contains(field) {
            return .failure(.invalidIntent("unknown session setting"))
        }
        let thread = sessions.first { $0.id == id }
        switch (field, value) {
        case ("title", .text(let title)):
            guard let thread, applyRenameSession(id: id, title: title) else {
                return .failure(.invalidIntent("标题不能为空"))
            }
            return .success(.text(thread.title))
        case ("pinned", .toggle(let on)):
            guard let thread else { return .failure(.invalidIntent("session not found")) }
            setPinned(on, sessionID: id)
            return .success(.toggle(thread.pinned))
        case ("unread", .toggle(let on)):
            guard let thread else { return .failure(.invalidIntent("session not found")) }
            setUnread(on, sessionID: id)
            return .success(.toggle(thread.unread))
        case ("group", .text(let raw)):
            guard let thread else { return .failure(.invalidIntent("session not found")) }
            let previous = BL6SettingValue.text(groupName(of: thread))
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                moveSession(id, toGroup: nil)
            } else if let existing = groups.first(where: { $0.name == name }) {
                moveSession(id, toGroup: existing.id)
            } else if let created = createGroup(named: name) {
                moveSession(id, toGroup: created.id)
            } else {
                return .failure(.invalidIntent("无法新建分组"))
            }
            return .success(previous)
        case ("project", .object(let fields)):
            guard let thread else { return .failure(.invalidIntent("session not found")) }
            guard case .text(let rawName)? = fields["name"],
                  case .text(let rawDirectory)? = fields["working_directory"] else {
                return .failure(.invalidIntent("project needs name and working_directory"))
            }
            let previous = projectValue(of: thread)
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                setProject(nil, forSession: id)
            } else if let directory = SessionSidebarPresentation.projectDirectory(rawDirectory) {
                setProject(
                    SessionProject(id: Self.projectID(for: name), name: name,
                                   workingDirectory: directory.path),
                    forSession: id)
            } else {
                return .failure(.invalidIntent("工作目录不可用：请提供已存在的文件夹路径"))
            }
            return .success(previous)
        case ("archived", .toggle(let archive)):
            if archive {
                guard sessions.contains(where: { $0.id == id }) else {
                    return .failure(.invalidIntent("session not found"))
                }
                archiveSession(id: id)
                guard archivedSessions.contains(where: { $0.id == id }) else {
                    return .failure(.invalidIntent("归档失败，会话保持原状"))
                }
            } else {
                guard archivedSessions.contains(where: { $0.id == id }) else {
                    return .failure(.invalidIntent("session is not archived"))
                }
                restoreSession(id: id, activating: false)
                guard sessions.contains(where: { $0.id == id }) else {
                    return .failure(.invalidIntent("恢复失败，会话保持在归档"))
                }
            }
            return .success(.toggle(!archive))
        case ("trashed", .toggle(let trash)):
            if trash {
                do {
                    let preview = try previewCurrentDeletion(id: id)
                    guard preview.intent.reversible else {
                        return .failure(.invalidIntent("该删除不可恢复，对话中不执行"))
                    }
                    let confirmed = preview.intent
                        .withFirstConfirmation(preview.intent.targetName)
                        .withSecondConfirmation("移入回收站")
                    if preview.archived {
                        _ = try deleteArchivedSession(id: id, intent: confirmed)
                    } else {
                        _ = try deleteSession(id: id, intent: confirmed)
                    }
                } catch {
                    return .failure(.invalidIntent("移入回收站失败：\(error.localizedDescription)"))
                }
            } else {
                guard let entry = sessionTrashEntries.first(where: { $0.receipt.targetID == id.uuidString }),
                      restoreTrashedSession(entry.receipt, activating: false) else {
                    return .failure(.invalidIntent("回收站里没有该会话，或已过期、无法恢复"))
                }
            }
            return .success(.toggle(!trash))
        default:
            return .failure(.invalidIntent("session setting value has the wrong type"))
        }
    }
}

/// This router is installed only with the canonical SettingsCenter and below
/// the existing Safety -> Policy -> Recording -> Composer approval wrappers.
/// It owns neither settings storage nor an independent authorization policy.
final class ConversationSettingsToolExecutor:
    ToolCatalogValidatingExecutor,
    PolicyCapabilityResolving,
    SessionReadCapabilityAwareToolExecutor,
    BuiltinOwnerBoundToolExecutor,
    @unchecked Sendable
{
    private let base: any ToolExecutor
    private weak var center: SettingsCenter?
    private weak var chat: ChatStore?
    private weak var shortcutStore: ShortcutStore?
    private let skillsStore: SkillsStore?
    private let schedulerStore: SchedulerTaskStore?
    private let preferencesDefaults: UserDefaults
    private let sidebarWidthSetting: SessionSidebarWidthSetting
    private let sessionDirectory: URL

    init(
        base: any ToolExecutor,
        center: SettingsCenter,
        chat: ChatStore,
        shortcutStore: ShortcutStore?,
        skillsStore: SkillsStore?,
        schedulerStore: SchedulerTaskStore?,
        preferencesDefaults: UserDefaults,
        sidebarWidthSetting: SessionSidebarWidthSetting,
        sessionDirectory: URL
    ) {
        self.base = base
        self.center = center
        self.chat = chat
        self.shortcutStore = shortcutStore
        self.skillsStore = skillsStore
        self.schedulerStore = schedulerStore
        self.preferencesDefaults = preferencesDefaults
        self.sidebarWidthSetting = sidebarWidthSetting
        self.sessionDirectory = sessionDirectory
    }

    private static let toolNames: Set<String> = [
        BL6SettingsToolApproval.catalogToolName,
        BL6SettingsToolApproval.toolName
    ]

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        let names = Set(tools.map(\.name))
        let exposedSettings = names.intersection(Self.toolNames)
        guard (exposedSettings.isEmpty || exposedSettings == Self.toolNames),
              names.count == tools.count else {
            throw ConversationSettingsToolError.ownerUnavailable
        }
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(
            tools.filter { !Self.toolNames.contains($0.name) }
        )
    }

    /// Session titles plus scheduled-task names, so approval cards can name what they change.
    @MainActor
    private func refreshTitleDirectory(_ chat: ChatStore) {
        chat.refreshSessionTitleDirectory()
        if let schedulerStore {
            chat.sessionTitleDirectory.merge(Dictionary(
                schedulerStore.allTasks().map { ($0.id.uuidString, $0.name) },
                uniquingKeysWith: { first, _ in first }))
        }
    }

    func resolvesCapability(_ name: String) async throws -> Bool {
        if Self.toolNames.contains(name) {
            return await MainActor.run {
                guard let center, let chat else { return false }
                refreshTitleDirectory(chat)
                return chat.conversationSettingsSnapshot(
                    from: center, sessionDirectory: sessionDirectory
                ) != nil
            }
        }
        guard let resolver = base as? any PolicyCapabilityResolving else { return false }
        return try await resolver.resolvesCapability(name)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard Self.toolNames.contains(name) else {
            return try await base.execute(name: name, input: input)
        }
        guard let center, let chat else { throw ConversationSettingsToolError.ownerUnavailable }
        if name == BL6SettingsToolApproval.catalogToolName {
            guard input.isEmpty else { throw ConversationSettingsToolError.invalidInput }
            // The Core Composer wrapper supplies a one-use, delegated read
            // context bound to the exact live tool attempt. A raw executor
            // call cannot return the catalog.
            guard let readApproval = BL6SettingsToolApproval.currentCatalogRead else {
                throw ConversationSettingsToolError.approvalRequired
            }
            let readReceipt = try await readApproval.consumeCurrent()
            let (snapshot, sidebarRevision, sidebarValue, shortcutRevision, mcpRevision, memoryRevision, skillsRevision, shortcutValues, memoryValues, mcpValues, skillsValues, mutableSkillIDs, schedulerValues, providerValues, safety) = try await MainActor.run {
                guard let snapshot = chat.conversationSettingsSnapshot(
                    from: center, sessionDirectory: sessionDirectory
                ) else { throw ConversationSettingsToolError.ownerUnavailable }
                let shortcutRevision: String?
                let shortcuts: [String: BL6SettingValue]
                if let shortcutStore {
                    switch shortcutStore.bl6Snapshot(
                        profileID: center.settingsStore.directory.standardizedFileURL.path
                    ) {
                    case .success(let projection):
                        shortcutRevision = projection.revision
                        shortcuts = projection.values
                    case .failure:
                        throw ConversationSettingsToolError.ownerUnavailable
                    }
                } else {
                    shortcutRevision = nil
                    shortcuts = [:]
                }
                let sidebar: (revision: String, value: BL6SettingValue)
                switch sidebarWidthSetting.bl6Snapshot(profileID: center.settingsStore.directory.standardizedFileURL.path) {
                case .success(let live): sidebar = live
                case .failure: throw ConversationSettingsToolError.ownerUnavailable
                }
                let activeMemoryScope = chat.activeMemoryScope
                guard center.memoryScopeProvider?() == activeMemoryScope else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                let memory: [String: BL6SettingValue]
                let memoryRevision: String?
                if let scope = activeMemoryScope {
                    guard scope.isValid, scope.sessionID == readReceipt.sessionID else {
                        throw ConversationSettingsToolError.ownerUnavailable
                    }
                    memory = try MemoryStoreTypedCatalogAdapter.snapshot(from: center)
                    memoryRevision = try center.memoryStore.bl6MemoryRevision(within: scope)
                } else {
                    memory = [:]
                    memoryRevision = nil
                }
                guard let mcp = MCPServerStoreTypedCatalogAdapter.snapshot(
                    from: center, sessionDirectory: sessionDirectory
                ), let mcpRevision = center.mcpManager.bl6NameRevision() else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                // The App root injects its exact SkillsStore. A scan that has
                // not completed has no admitted entries to project yet.
                let skills: [String: BL6SettingValue]
                let skillsRevision: String?
                let mutableSkillIDs: Set<String>
                if let skillsStore, skillsStore.catalogRefreshStatus == .ready {
                    skills = try SkillsStoreTypedCatalogAdapter.snapshot(
                        from: skillsStore, boundTo: skillsStore
                    )
                    if let scope = activeMemoryScope,
                       skillsStore.hasCanonicalBL6EnablementOwner(center.skillStore) {
                        let admitted = try SkillsStoreTypedCatalogAdapter.approvedSnapshot(
                            from: skillsStore, boundTo: center.skillStore, visibleTo: scope)
                        guard admitted.values.allSatisfy({ skills[$0.key] == .toggle($0.value) }) else {
                            throw ConversationSettingsToolError.ownerUnavailable
                        }
                        skillsRevision = admitted.revision
                        mutableSkillIDs = Set(admitted.values.keys)
                    } else {
                        skillsRevision = nil
                        mutableSkillIDs = []
                    }
                } else {
                    skills = [:]
                    skillsRevision = nil
                    mutableSkillIDs = []
                }
                let scheduler: [String: BL6SettingValue]
                if let schedulerStore, let scope = activeMemoryScope {
                    switch SchedulerStoreTypedCatalogAdapter.snapshotVisible(
                        to: scope,
                        approvedSessionID: readReceipt.sessionID,
                        preferencesDefaults: preferencesDefaults,
                        from: schedulerStore
                    ) {
                    case .success(let values): scheduler = values
                    case .failure: throw ConversationSettingsToolError.ownerUnavailable
                    }
                } else {
                    scheduler = [:]
                }
                return (snapshot, sidebar.revision, sidebar.value, shortcutRevision, mcpRevision, memoryRevision, skillsRevision, shortcuts, memory, mcp, skills, mutableSkillIDs, scheduler,
                        try center.conversationProviderRecordDirectory(), center.safetyRuntimeSnapshot)
            }
            let (sessionRevision, sessionRows) = await MainActor.run {
                refreshTitleDirectory(chat)
                return (
                    chat.conversationSessionRevision(currentSessionID: readReceipt.sessionID),
                    chat.conversationSessionCatalogRows(currentSessionID: readReceipt.sessionID)
                )
            }
            var entries = BL6SettingsCatalog.production.entries.map { entry in
                ConversationSettingsCatalogEntry(
                    id: entry.id,
                    kind: entry.kind,
                    agentMutable: entry.mutable
                        && (entry.id == BL6SettingsApprovedInput.approvalPolicyKey
                            || !BL6SettingsCatalog.deniedApprovedMutationKeys.contains(entry.id)),
                    secret: entry.secret
                )
            }
            var values = snapshot.values
            let sidebarID = SessionSidebarWidthContract.typedCatalogID
            guard values[sidebarID] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
            values[sidebarID] = sidebarValue
            entries.append(ConversationSettingsCatalogEntry(
                id: sidebarID, kind: .decimal, agentMutable: true, secret: false
            ))
            // Safe Mode and Kill Switch are editable only through the local
            // SettingsCenter safety controls. Their effective live state is
            // still part of the typed directory, never an agent write grant.
            for (id, enabled) in [
                ("safety.safe-mode-enabled", safety.safeModeEnabled),
                ("safety.kill-switch-enabled", safety.killSwitchEnabled)
            ] {
                guard values[id] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
                values[id] = .toggle(enabled)
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .toggle, agentMutable: false, secret: false
                ))
            }
            for id in shortcutValues.keys.sorted() {
                guard let value = shortcutValues[id], values[id] == nil,
                      case .object = value else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .object, agentMutable: shortcutRevision != nil, secret: false
                ))
            }
            for id in memoryValues.keys.sorted() {
                guard let value = memoryValues[id], values[id] == nil,
                      case .object = value else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .object, agentMutable: memoryRevision != nil, secret: false
                ))
            }
            for id in mcpValues.keys.sorted() {
                guard let value = mcpValues[id], values[id] == nil else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                let kind: BL6SettingValueKind
                switch value {
                case .text: kind = .text
                case .toggle: kind = .toggle
                default: throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: kind,
                    agentMutable: id.hasPrefix("mcp.")
                        && (id.hasSuffix(".name") || id.hasSuffix(".enabled")),
                    secret: false
                ))
            }
            for id in ["mcp.servers.add", "mcp.servers.remove"] {
                guard values[id] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .object, agentMutable: true, secret: false
                ))
            }
            for row in sessionRows {
                guard values[row.id] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
                values[row.id] = row.value
                entries.append(ConversationSettingsCatalogEntry(
                    id: row.id, kind: row.kind, agentMutable: row.mutable, secret: false
                ))
            }
            for id in skillsValues.keys.sorted() {
                guard let value = skillsValues[id], values[id] == nil,
                      case .toggle = value else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .toggle, agentMutable: skillsRevision != nil && mutableSkillIDs.contains(id), secret: false
                ))
            }
            for id in schedulerValues.keys.sorted() {
                guard let value = schedulerValues[id], values[id] == nil else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                let kind: BL6SettingValueKind
                switch value {
                case .text: kind = .text
                case .toggle: kind = .toggle
                default: throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: kind, agentMutable: id.hasSuffix(".enabled"), secret: false
                ))
            }
            if schedulerStore != nil {
                for id in ["scheduler.tasks.add", "scheduler.tasks.remove"] {
                    entries.append(ConversationSettingsCatalogEntry(
                        id: id, kind: .object, agentMutable: true, secret: false
                    ))
                }
            }
            let (schedulerRevision, preferencesRevision, hooksRevision, extraRows) = await MainActor.run {
                var rows: [(id: String, kind: BL6SettingValueKind, value: BL6SettingValue, mutable: Bool)] = []
                let usageRecords = UsageFilteredSettingsView.sessionRecords(
                    from: center.usageStore, sessionID: readReceipt.sessionID)
                rows.append(("usage.session.call-count", .integer, .integer(usageRecords.count), false))
                if !usageRecords.isEmpty {
                    let tokens = usageRecords.reduce(0) { $0.addingReportingOverflow($1.totalTokensIncludingCache).partialValue }
                    rows.append(("usage.session.total-tokens", .integer, .integer(tokens), false))
                    rows.append(("usage.session.estimated-cost", .text,
                                 .text(UsageModelPricing.display(records: usageRecords, prices: center.usageStore.modelPricing)),
                                 false))
                }
                if let occupancy = chat.contextOccupancy {
                    rows.append(("context.reported", .toggle, .toggle(true), false))
                    rows.append(("context.used-tokens", .integer, .integer(occupancy.inputTokens), false))
                    rows.append(("context.window-tokens", .integer, .integer(occupancy.windowTokens), false))
                    rows.append(("context.percent", .text, .text(occupancy.percentage), false))
                } else {
                    rows.append(("context.reported", .toggle, .toggle(false), false))
                }
                for row in center.conversationPreferenceRows() {
                    rows.append((row.id, .toggle, row.value, true))
                }
                let schedulerRevision = schedulerStore.map {
                    SchedulerStoreTypedCatalogAdapter.revision(visibleTo: chat.activeMemoryScope, in: $0)
                }
                return (schedulerRevision, center.conversationPreferencesRevision(),
                        center.conversationHookStore?.conversationUserHooksRevision(), rows)
            }
            if hooksRevision != nil {
                for id in ["hooks.entries.add", "hooks.entries.remove"] {
                    entries.append(ConversationSettingsCatalogEntry(
                        id: id, kind: .object, agentMutable: true, secret: false))
                }
            }
            for row in extraRows {
                guard values[row.id] == nil else { throw ConversationSettingsToolError.ownerUnavailable }
                values[row.id] = row.value
                entries.append(ConversationSettingsCatalogEntry(
                    id: row.id, kind: row.kind, agentMutable: row.mutable, secret: false
                ))
            }
            for id in providerValues.keys.sorted() {
                guard let value = providerValues[id], values[id] == nil,
                      case .object = value else {
                    throw ConversationSettingsToolError.ownerUnavailable
                }
                values[id] = value
                entries.append(ConversationSettingsCatalogEntry(
                    id: id, kind: .object, agentMutable: false, secret: false
                ))
            }
            let response = ConversationSettingsCatalogResponse(
                catalogRevision: snapshot.catalogRevision,
                sidebarRevision: sidebarRevision,
                shortcutRevision: shortcutRevision,
                mcpRevision: mcpRevision,
                sessionRevision: sessionRevision,
                memoryRevision: memoryRevision,
                skillsRevision: skillsRevision,
                schedulerRevision: schedulerRevision,
                preferencesRevision: preferencesRevision,
                hooksRevision: hooksRevision,
                entries: entries,
                values: values
            )
            return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        }

        guard let approvedCall = BL6SettingsToolApproval.current,
              let authorizationFacts = BL6SettingsToolApproval.currentAuthorizationFacts else {
            throw ConversationSettingsToolError.approvalRequired
        }
        guard JSONSerialization.isValidJSONObject(input) else {
            throw ConversationSettingsToolError.invalidInput
        }
        let inputData = try JSONSerialization.data(
            withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let result = await chat.dispatchApprovedConversationSettings(
            inputData: inputData,
            approvedCall: approvedCall,
            authorizationFacts: authorizationFacts,
            center: center,
            shortcutStore: shortcutStore,
            skillsStore: skillsStore,
            schedulerStore: schedulerStore,
            sidebarWidthSetting: sidebarWidthSetting,
            sessionDirectory: sessionDirectory
        )
        switch result {
        case .success(let receipt):
            return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        case .failure(.staleRevision(let expected, let actual)):
            guard input["operation"] as? String == "rollback",
                  let receiptID = input["undoReceiptID"] as? String,
                  case .success(let original?) = center.settingsStore.bl6ReplayRecord(receiptID: receiptID)
            else { throw BL6SettingsDispatchError.staleRevision(expected: expected, actual: actual) }
            let originals = original.rollbackValues.keys.sorted().map { key -> String in
                switch original.rollbackValues[key] {
                case .text(let v)?: return "\(key) = \(v)"
                case .toggle(let v)?: return "\(key) = \(v ? "开" : "关")"
                case .integer(let v)?: return "\(key) = \(v)"
                case .decimal(let v)?: return "\(key) = \(v)"
                case .list(let v)?: return "\(key) = [\(v.joined(separator: ", "))]"
                default: return "\(key)（原值不展示）"
                }
            }.joined(separator: "；")
            throw ConversationSettingsToolError.undoReceiptStale(
                "这次改动之后设置又变过，无法撤销，设置未被改动。该回执记录的原值：\(originals)。如需恢复，请用新的 expectedRevision 重新提交这些值。"
            )
        case .failure(.invalidIntent(let message))
            where message == BL6SettingsApprovedInput.unsupportedApprovalPolicyMessage:
            throw ConversationSettingsToolError.unsupportedApprovalPolicy
        case .failure(.invalidIntent(let message))
            where (input["changes"] as? [String: Any])?.keys.contains(where: { $0.hasPrefix("session.") }) == true:
            throw ConversationSettingsToolError.sessionChangeRejected(message)
        case .failure(let error):
            throw error
        }
    }

    var currentBuiltinOwner: BuiltinToolExecutor? {
        (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard !Self.toolNames.contains(name), currentBuiltinOwner === owner else {
            throw ToolExecutorError.resourceScopeInvalid
        }
        return try await executeThroughBoundBuiltinOwner(base, owner: owner, name: name, input: input)
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
            throw CrossSessionReadAuthorizationError.capabilityRequired
        }
        if let scope = try SessionReadTool.authorizeSessionLevel(
            input: input, authorization: authorization, context: context, now: now
        ) {
            guard let center, let chat else { throw ConversationSettingsToolError.ownerUnavailable }
            let query = input["query"] as? String
            return try await MainActor.run {
                let redactor = ChatTranscriptRedactor(store: center.envStore)
                if scope == .export {
                    guard let thread = chat.activeThread(id: context.currentConversationID) else {
                        throw ToolExecutorError.fileNotFound(context.currentConversationID)
                    }
                    return SessionMarkdownExport.markdown(
                        title: thread.title, messages: thread.messages, redactor: redactor)
                }
                return try SessionReadTool.listEnvelope(
                    rows: chat.sessionListRows(currentSessionID: context.currentConversationID),
                    query: query,
                    knownSecrets: redactor.secretValues)
            }
        }
        return try await aware.executeSessionRead(
            input: input, authorization: authorization, context: context, now: now
        )
    }
}
