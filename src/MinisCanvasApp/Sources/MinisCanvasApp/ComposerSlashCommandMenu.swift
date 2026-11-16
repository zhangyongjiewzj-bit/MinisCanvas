import Foundation
import MinisCore

// MARK: - W4-SLASHMENU-036 Composer slash command menu view model
//
// Pure, SwiftPM-testable presentation model for the Composer slash menu
// (D-COMPOSER-16 / D-COMPOSER-17, defect F09 family). It never executes a
// command and never registers anything into the shared CommandRegistry: it
// projects the registry's slash vocabulary plus the live registry so the menu
// can render, for every row, a bilingual description and the session-state
// tri-state (可用 / 阻断 / 需审批). Rows whose ID is not yet routable by the
// canonical Composer pipeline are displayed as 阻断 with an explicit reason,
// so keyboard accept can only complete text and can never dispatch them.
// When MinisCore later registers those IDs (pending write-set escalation),
// these rows flip to their real state automatically because routing
// presence is resolved against the registry on every render.
//
// MARK: - D-COMMAND-02 single command source
//
// The slash menu's enumerable vocabulary — command identity, bilingual title
// and summary, alias set, risk level, approval flag and parameter summary — is
// generated from `CommandRegistry`'s own Composer declaration
// (`CommandRegistry.composerCommandMetadata`, the very list
// `registerComposerCommands()` installs and `CommandParser` resolves against)
// and ordered by the registry's declared completion order. This file keeps no
// parallel command list: a command added to the registry (D-COMMAND-01) shows
// up in the slash menu with no edit here. What stays in this file is only what
// the registry structurally cannot know — ChatStore-derived session gates
// (`sessionGates`) and the App-local risk label type. Gates never add, drop or
// reorder a row.

/// Risk shown beside a slash command row. Presentation metadata only; the
/// Policy/Approval boundary remains the authority before any execution.
enum ComposerSlashCommandRisk: String, CaseIterable {
    case low
    case medium
    case high

    var zhLabel: String {
        switch self {
        case .low: "低风险"
        case .medium: "中风险"
        case .high: "高风险"
        }
    }

    var displayLabel: String {
        switch self {
        case .low: "低风险 / Low risk"
        case .medium: "中风险 / Medium risk"
        case .high: "高风险 / High risk"
        }
    }

    /// Projects the risk level the canonical registry declares for a Composer
    /// command. The switch is exhaustive on purpose: a new registry risk level
    /// fails compilation here instead of silently down-grating a row.
    init(_ registryRisk: ComposerCommandRisk) {
        switch registryRisk {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

/// The session facts the menu renders against. Every field maps to an
/// already-public ChatStore signal; nothing here is invented.
struct ComposerSlashSessionState: Equatable, Sendable {
    /// `ChatStore.isActiveSessionStreaming`
    var isStreaming: Bool = false
    /// `ChatStore.pendingComposerCommand != nil`
    var hasPendingComposerCommand: Bool = false
    /// `ChatStore.activeSessionID != nil`
    var hasActiveSession: Bool = true
    /// Only concrete, current production blockers supplied by the Composer
    /// consumer. Keys are canonical command IDs; absence makes no additional
    /// readiness claim. In particular a registered command is not proof that
    /// the App has an executor, configuration or permission.
    var unavailableReasonsByCommandID: [String: String] = [:]

    static let neutral = ComposerSlashSessionState()
}

/// Tri-state visibility of one slash command under the current session state.
enum ComposerSlashCommandState: Equatable, Sendable {
    case available
    case requiresApproval
    case blocked(reason: String)

    /// Short label; 可用 / 需审批 / 阻断.
    var label: String {
        switch self {
        case .available: "可用"
        case .requiresApproval: "需审批"
        case .blocked: "阻断"
        }
    }

    var reason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }

    /// Accessibility value for one row, including the keyboard selection
    /// state (D-COMPOSER-16) and the blocking reason (D-COMPOSER-17).
    func accessibilityValue(isSelected: Bool) -> String {
        var parts: [String] = []
        if isSelected { parts.append("已选中") }
        parts.append(label)
        if let reason { parts.append(reason) }
        return parts.joined(separator: "，")
    }
}

/// One Phase 3 slash vocabulary row definition (bilingual metadata only;
/// canonical execution stays behind the registry/policy pipeline).
struct ComposerSlashCommandDescriptor: Sendable {
    let id: String
    let zhTitle: String
    let enTitle: String
    let zhSummary: String
    let enSummary: String
    let aliases: [String]
    let category: CommandCategory
    let risk: ComposerSlashCommandRisk?
    let requiresPolicyApproval: Bool
    let argumentSummary: String
    /// Session-state gate returning a blocking reason, or nil.
    let sessionGating: @Sendable (ComposerSlashSessionState) -> String?

    init(
        id: String,
        zhTitle: String,
        enTitle: String,
        zhSummary: String,
        enSummary: String,
        aliases: [String] = [],
        category: CommandCategory,
        risk: ComposerSlashCommandRisk?,
        requiresPolicyApproval: Bool = false,
        argumentSummary: String = "无 / none",
        sessionGating: @escaping @Sendable (ComposerSlashSessionState) -> String? = { _ in nil }
    ) {
        self.id = CommandDefinition.canonicalID(id)
        self.zhTitle = zhTitle
        self.enTitle = enTitle
        self.zhSummary = zhSummary
        self.enSummary = enSummary
        self.aliases = aliases
        self.category = category
        self.risk = risk
        self.requiresPolicyApproval = requiresPolicyApproval
        self.argumentSummary = argumentSummary
        self.sessionGating = sessionGating
    }

    /// Registry-derived row: every display field comes from the canonical
    /// Composer declaration in `CommandRegistry`, and the alias set is taken
    /// from the live registration when the injected registry carries one, so
    /// slash matching accepts exactly what the parser resolves.
    init(
        metadata: ComposerCommandMetadata,
        liveCommand: CommandDefinition?,
        sessionGating: @escaping @Sendable (ComposerSlashSessionState) -> String? = { _ in nil }
    ) {
        let liveAliases = liveCommand?.aliases ?? []
        self.init(
            id: metadata.id,
            zhTitle: liveCommand?.title ?? metadata.zhTitle,
            enTitle: metadata.enTitle,
            zhSummary: metadata.zhSummary,
            enSummary: metadata.enSummary,
            aliases: liveAliases.isEmpty ? metadata.aliases : liveAliases,
            category: metadata.category,
            risk: ComposerSlashCommandRisk(metadata.risk),
            requiresPolicyApproval: metadata.requiresPolicyApproval,
            argumentSummary: metadata.parameterSummary,
            sessionGating: sessionGating
        )
    }

    /// Preset and App commands already have a canonical registry definition.
    /// They have no Composer risk grade; keep that field absent instead of
    /// inventing one while projecting the same command into the slash menu.
    init(command: CommandDefinition) {
        self.init(
            id: command.id,
            zhTitle: command.title,
            enTitle: command.id,
            zhSummary: command.title,
            enSummary: command.id,
            aliases: command.aliases,
            category: command.category,
            risk: nil,
            argumentSummary: command.argumentSpecs.isEmpty
                ? "无 / none" : command.argumentSpecs.map(\.label).joined(separator: "、")
        )
    }

    /// Non-routed rows still need a `CommandDefinition` identity for the
    /// shared keyboard-completion state machine. This projection is local to
    /// the menu; it is never registered into any registry.
    var menuCommand: CommandDefinition {
        CommandDefinition(
            id: id,
            title: zhTitle,
            aliases: aliases,
            category: category,
            requiresConfirmation: requiresPolicyApproval
        ) { _ in
            .failure("Composer 命令必须先创建 pending request")
        }
    }
}

/// One rendered menu row.
struct ComposerSlashMenuEntry: Identifiable {
    let descriptor: ComposerSlashCommandDescriptor
    /// The live registry definition when the canonical Composer pipeline can
    /// consume this ID; nil means the row is display-only (阻断：未接入路由).
    let routedCommand: CommandDefinition?
    let state: ComposerSlashCommandState

    var id: String { descriptor.id }

    /// Command identity handed to the completion state machine.
    var completionCommand: CommandDefinition { routedCommand ?? descriptor.menuCommand }

    var isRouted: Bool { routedCommand != nil }

    /// Enter/Return and click may dispatch only when the pipeline can consume
    /// the command and the session state does not block it. Blocked rows can
    /// still be completed into the draft with Tab for editing.
    var shouldSendOnAccept: Bool {
        (state == .available || state == .requiresApproval)
            && routedCommand?.argumentSpecs.contains(where: \.required) != true
    }

    var stateReason: String? { state.reason }

    /// Execution scope and retention are visible even when the row is blocked.
    var executionSummary: String? {
        guard id == "compact" else { return nil }
        return "范围：当前会话 · 保留最近 \(ChatStore.defaultCompactionKeepRecent) 条"
    }

    func accessibilityValue(isSelected: Bool) -> String {
        let value = state.accessibilityValue(isSelected: isSelected)
        guard let executionSummary else { return value }
        return "\(value)，\(executionSummary)"
    }
}

enum ComposerSlashCommandMenu {
    /// The slash vocabulary, generated from the canonical command registry in
    /// the registry's own declared completion order (keyboard and VoiceOver
    /// order).
    ///
    /// D-COMMAND-02: this is the only source of menu rows. Adding a Composer
    /// command to the registry (D-COMMAND-01) makes it enumerable in the slash
    /// menu without a second edit here; a vocabulary row whose ID the injected
    /// registry cannot yet consume is still projected as 阻断 by
    /// `entry(for:registry:sessionState:)`, so widening the registry widens the
    /// menu and never silently drops a row. Only the first declaration of an ID
    /// is projected, so the menu can never hand the view two rows sharing one
    /// `Identifiable` id.
    static func descriptors(
        registry: CommandRegistry
    ) -> [ComposerSlashCommandDescriptor] {
        var seen: Set<String> = []
        let composer = CommandRegistry.composerCommandMetadata.compactMap { metadata -> ComposerSlashCommandDescriptor? in
            guard seen.insert(metadata.id).inserted else { return nil }
            return ComposerSlashCommandDescriptor(
                metadata: metadata,
                liveCommand: registry.command(id: metadata.id),
                sessionGating: sessionGate(for: metadata.id)
            )
        }
        let registered = registry.allCommands().compactMap { command -> ComposerSlashCommandDescriptor? in
            guard seen.insert(command.id).inserted else { return nil }
            return ComposerSlashCommandDescriptor(command: command)
        }
        return composer + registered
    }

    /// Composer-local session gate for one canonical command ID. The gates read
    /// ChatStore facts the registry cannot see (`isStreaming`,
    /// `hasPendingComposerCommand`); they only shape the tri-state of a row the
    /// registry already declares and never add, drop or reorder vocabulary.
    static func sessionGate(
        for id: String
    ) -> @Sendable (ComposerSlashSessionState) -> String? {
        if let gate = sessionGates[id] { return gate }
        return { (_: ComposerSlashSessionState) -> String? in nil }
    }

    private static let sessionGates: [String: @Sendable (ComposerSlashSessionState) -> String?] = [
        "stop": { (session: ComposerSlashSessionState) -> String? in
            session.isStreaming ? nil : "当前没有进行中的生成"
        },
        "approve": { (session: ComposerSlashSessionState) -> String? in
            session.hasPendingComposerCommand ? nil : "当前没有待审批请求"
        },
        "reject": { (session: ComposerSlashSessionState) -> String? in
            session.hasPendingComposerCommand ? nil : "当前没有待审批请求"
        },
    ]

    /// Filtered, ordered menu rows for one draft. Matching mirrors the
    /// canonical completion semantics: the text after `/` prefix-matches the
    /// command ID, the Chinese/English title, or any localized alias the
    /// registry declares for that command.
    static func entries(
        matching input: String,
        registry: CommandRegistry,
        sessionState: ComposerSlashSessionState = .neutral
    ) -> [ComposerSlashMenuEntry] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return [] }
        let fullPrefix = String(text.dropFirst())
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let descriptors = descriptors(registry: registry)
        // Once an exact command is followed by arguments, keep its row visible
        // so Return can submit the unchanged typed arguments.
        let firstWord = String(fullPrefix.split(whereSeparator: \.isWhitespace).first ?? "")
        let prefix = descriptors.contains(where: { $0.matches(prefix: fullPrefix) })
            ? fullPrefix : firstWord
        return descriptors.compactMap { descriptor in
            if !prefix.isEmpty && !descriptor.matches(prefix: prefix) { return nil }
            return entry(for: descriptor, registry: registry, sessionState: sessionState)
        }
    }

    /// Resolves the keyboard selection to a row index by command identity so
    /// that narrowing the list cannot silently move the highlight onto a
    /// different command at the same index (F09 family).
    static func selectedIndex(
        for selectedCommandID: String?,
        in entries: [ComposerSlashMenuEntry]
    ) -> Int? {
        guard let selectedCommandID,
              let index = entries.firstIndex(where: { $0.id == selectedCommandID })
        else { return nil }
        return index
    }

    static func entry(
        for descriptor: ComposerSlashCommandDescriptor,
        registry: CommandRegistry,
        sessionState: ComposerSlashSessionState = .neutral
    ) -> ComposerSlashMenuEntry {
        let routed = registry.command(id: descriptor.id)
        let state = resolveState(descriptor: descriptor, routed: routed, sessionState: sessionState)
        return ComposerSlashMenuEntry(descriptor: descriptor, routedCommand: routed, state: state)
    }

    private static func resolveState(
        descriptor: ComposerSlashCommandDescriptor,
        routed command: CommandDefinition?,
        sessionState: ComposerSlashSessionState
    ) -> ComposerSlashCommandState {
        // Display-only rows must never dispatch: the canonical Composer
        // pipeline cannot consume them yet (MinisCore registration is a
        // separate, escalated write set).
        guard let command else {
            return .blocked(reason: "尚未接入 Composer 路由")
        }
        if case .disabled(let reason) = command.currentAvailability {
            return .blocked(reason: reason)
        }
        if let reason = sessionState.unavailableReasonsByCommandID[descriptor.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return .blocked(reason: reason)
        }
        if let reason = descriptor.sessionGating(sessionState) {
            return .blocked(reason: reason)
        }
        if !CommandRegistry.composerCommandIDs.contains(descriptor.id),
           command.requiresConfirmation {
            return .blocked(reason: AppCommandCatalog.missingConfirmationReason(for: command)
                ?? "此命令当前没有确认执行入口")
        }
        if descriptor.requiresPolicyApproval || command.requiresConfirmation {
            return .requiresApproval
        }
        return .available
    }
}

private extension ComposerSlashCommandDescriptor {
    func matches(prefix: String) -> Bool {
        id.lowercased().hasPrefix(prefix)
            || zhTitle.lowercased().hasPrefix(prefix)
            || enTitle.lowercased().hasPrefix(prefix)
            || aliases.contains { $0.lowercased().hasPrefix(prefix) }
    }
}

// The native Escape handler and configured ShortcutStore outlet share this
// existing selection/context update. Dismissal never accepts or sends a row.
extension GlobalComposer {
    @discardableResult
    static func dismissSlashCompletion(
        entries: [ComposerSlashMenuEntry], contextKey: String,
        selectedCommandID: inout String?, dismissedContextKey: inout String?
    ) -> Bool {
        guard !entries.isEmpty else { return false }
        selectedCommandID = nil
        dismissedContextKey = contextKey
        return true
    }
}
