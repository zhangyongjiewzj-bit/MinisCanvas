import Foundation
import SwiftUI
import AppKit
import MinisCore

// MARK: - Composition pass-through seam (077-A 差额面②/③)

private struct ExternalSessionAuthorizationCompositionKey: EnvironmentKey {
    /// `nil` is the fail-closed default: surfaces that never receive the
    /// composition root (field journeys, previews) render no ledger card and
    /// expose no mint entry, exactly like the shipping app before this file.
    static let defaultValue: ExternalSessionAuthorizationComposition? = nil
}

extension EnvironmentValues {
    var externalSessionAuthorizationComposition: ExternalSessionAuthorizationComposition? {
        get { self[ExternalSessionAuthorizationCompositionKey.self] }
        set { self[ExternalSessionAuthorizationCompositionKey.self] = newValue }
    }
}

/// Task Center entry for user-selected external session roots, authorization,
/// revocation and grant-gated read operations. Control grants are distinct and
/// only offered for an adapter that declares actual control capabilities.
/// Enforcement and epochs remain in the existing ledger and App adapter.
///
/// Everything shown comes from `authorizationSnapshot()` — pure enumeration.
/// The status text derived below is display-only; live enforcement keeps
/// re-checking `isAuthorizationActive` at admission and after every await.
struct ExternalSessionAuthorizationLedgerView: View {
    @Environment(\.externalSessionAuthorizationComposition) private var composition
    @Environment(\.typographyTokens) private var typography

    @State private var snapshot: ExternalSessionAuthorizationSnapshotV1 = .empty
    @State private var hasLoadedSnapshot = false
    @State private var selectedSourceID: ExternalSessionSourceID?
    @State private var targetKind: GrantTargetKind = .session
    @State private var projectIDText = ""
    @State private var sessionIDText = ""
    @State private var scopes: Set<ExternalSessionReadScopeV1> = [.metadata]
    @State private var lifetime: GrantLifetime = .hour
    @State private var isConfirmationPresented = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var selectedExternalKind: ExternalSessionSourceKindV1 = .codex
    @State private var selectedRootDescription: String?
    @State private var pairPendingRevocation: ExternalSessionAuthorizationSnapshotV1.AuthorizedPairEntry?
    @State private var selectedControlSourceID: ExternalSessionSourceID?
    @State private var controlThreadIDText = ""
    @State private var controlOperations: Set<ExternalSessionControlOperationV1> = []
    @State private var isControlConfirmationPresented = false
    @State private var discoveredThreads: [ExternalSessionThreadV1] = []
    @State private var nextThreadCursor: ExternalSessionCursorV1?
    @State private var selectedThread: ExternalSessionThreadV1?
    @State private var directReadThreadIDText = ""
    @State private var displayedReadThreadID: ExternalSessionThreadID?
    @State private var readPages: [ExternalSessionReadPageV1] = []
    @State private var readRequestOwner = ExternalSessionReadRequestOwner()
    @State private var actionOperation: ExternalSessionControlOperationV1 = .resume
    @State private var actionTurnIDText = ""
    @State private var actionInputText = ""
    @State private var isActionConfirmationPresented = false
    @State private var lastControlReceipt: ExternalSessionControlReceiptV1?
    @State private var ownedCodexExecutableURL: URL?
    @State private var ownedMemoryWorkspaceURL: URL?
    @State private var ownedMemoryTaskPrompt = ""
    @State private var isOwnedMemoryTaskConfirmationPresented = false
    @StateObject private var externalEventProjection = ExternalSessionEventDisplayProjection()

    /// D-EXTB 措辞「按 source/project/session 授权读取」到合同
    /// `ExternalSessionReadTargetV1` 三 case 的一一映射（session=thread）。
    enum GrantTargetKind: String, CaseIterable, Identifiable {
        case source
        case project
        case session

        var id: String { rawValue }

        var title: String {
            switch self {
            case .source: return "整个来源（source）"
            case .project: return "项目（project）"
            case .session: return "单个会话（session）"
            }
        }
    }

    /// 最小实现：固定时长三档（不开放自由输入），满足台账
    /// `lifetime > 0 && isFinite` guard，到期即失效由执法面既有检查保证。
    enum GrantLifetime: String, CaseIterable, Identifiable {
        case minutes30
        case hour
        case day

        var id: String { rawValue }

        var title: String {
            switch self {
            case .minutes30: return "30 分钟"
            case .hour: return "1 小时"
            case .day: return "24 小时"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .minutes30: return 30 * 60
            case .hour: return 60 * 60
            case .day: return 24 * 60 * 60
            }
        }
    }

    /// Display-only grant status. Revoked means the stamped epoch no longer
    /// equals the pair's current epoch (or the pair left the ledger's issued
    /// set); expired means the wall clock reached `expiresAt`. Both mirror the
    /// existing enforcement rules value-for-value and add none of their own.
    enum GrantDisplayStatus: String, Equatable {
        case active
        case revoked
        case expired

        var title: String {
            switch self {
            case .active: return "有效"
            case .revoked: return "已撤销"
            case .expired: return "已过期"
            }
        }
    }

    static func readGrantStatus(
        _ grant: ExternalSessionReadGrantV1,
        in snapshot: ExternalSessionAuthorizationSnapshotV1,
        now: Date
    ) -> GrantDisplayStatus {
        guard let currentEpoch = snapshot.currentEpoch(
            sourceID: grant.sourceID,
            profileID: grant.profileID
        ), grant.revocationEpoch == currentEpoch else {
            return .revoked
        }
        return now < grant.expiresAt ? .active : .expired
    }

    static func controlGrantStatus(
        _ grant: ExternalSessionControlGrantV1,
        in snapshot: ExternalSessionAuthorizationSnapshotV1,
        now: Date
    ) -> GrantDisplayStatus {
        guard let currentEpoch = snapshot.currentEpoch(
            sourceID: grant.sourceID,
            profileID: grant.profileID
        ), grant.revocationEpoch == currentEpoch else {
            return .revoked
        }
        return now < grant.expiresAt ? .active : .expired
    }

    static func targetText(_ target: ExternalSessionReadTargetV1) -> String {
        switch target {
        case let .source(sourceID): return "source \(sourceID.rawValue)"
        case let .project(projectID): return "project \(projectID.rawValue)"
        case let .thread(threadID): return "session \(threadID.rawValue)"
        }
    }

    static func targetText(_ target: ExternalSessionControlTargetV1) -> String {
        switch target {
        case let .source(sourceID): return "source \(sourceID.rawValue)"
        case let .project(projectID): return "project \(projectID.rawValue)"
        case let .thread(threadID): return "session \(threadID.rawValue)"
        }
    }

    static func scopeTitles(_ scopes: Set<ExternalSessionReadScopeV1>) -> String {
        scopes.map(\.rawValue).sorted().joined(separator: "、")
    }

    /// 合同枚举全集（`ExternalSessionReadScopeV1` 非 CaseIterable，且合同
    /// 文件不入本线写集；此处显式列举与合同 :319-323 逐一对应）。
    static let selectableScopes: [ExternalSessionReadScopeV1] = [
        .metadata, .messages, .status, .events
    ]

    private var isFormComplete: Bool {
        guard selectedSourceID != nil else { return false }
        switch targetKind {
        case .source:
            return true
        case .project:
            return !projectIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .session:
            return !sessionIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        if let composition {
            card(composition)
        }
        // else: no composition root in the environment — the card renders
        // nothing, keeping non-production surfaces free of an issuer.
    }

    @ViewBuilder
    private func card(_ composition: ExternalSessionAuthorizationComposition) -> some View {
        let supervisedSources = composition.supervisedSourceIDs
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("外部会话授权台账")
            } icon: {
                MinisIconView(.branch, size: 16, accessibilityLabel: "外部会话授权台账")
            }

            if !hasLoadedSnapshot {
                Text("台账状态加载中")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-authorization-loading")
            } else if snapshot.authorizedPairs.isEmpty {
                Text("还没有授权任何外部会话")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-authorization-empty")
            } else {
                pairRows
                grantRows(now: .now)
            }

            // Registration/handshake facts are distinct from the grant ledger.
            // No control button is created for an unregistered vendor source.
            ForEach(composition.externalSourceSupport) { support in
                VStack(alignment: .leading, spacing: 2) {
                    Text(support.title + "：" + support.detail)
                    if !support.declaredCapabilities.isEmpty {
                        Text("已注册适配器声明：" + support.declaredCapabilities.map(\.rawValue).sorted().joined(separator: ", "))
                    }
                }
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("external-session-source-support-" + support.id)
            }

            externalSourceSection(composition)

            mintSection(composition: composition, supervisedSources: supervisedSources)
            readSection(composition: composition)
            controlGrantSection(composition: composition)
            controlledMemoryTaskSection(composition: composition)

            if let statusMessage {
                Text(statusMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-authorization-status")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(typography?.caption ?? .caption)
                    .modifier(ReadableStatusForeground(status: .danger))
                    .accessibilityIdentifier("external-session-authorization-error")
            }

            HStack(spacing: 8) {
                Button("刷新台账") {
                    Task { await refresh(from: composition) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("external-session-authorization-refresh")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("external-session-authorization-ledger")
        .onAppear { readRequestOwner.open(sourceID: selectedSourceID) }
        .onDisappear { readRequestOwner.close() }
        .task(id: supervisedSources) {
            await refresh(from: composition)
            if selectedSourceID == nil {
                selectedSourceID = supervisedSources.first
                readRequestOwner.switchSource(selectedSourceID)
            }
        }
        .confirmationDialog(
            "确认签发外部会话读取授权？",
            isPresented: $isConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认签发读取授权") {
                Task { await mintConfirmedGrant(from: composition) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmationSummaryText(supervisedSources: supervisedSources))
        }
        .confirmationDialog(
            "撤销该来源当前所有读取和控制授权？",
            isPresented: Binding(
                get: { pairPendingRevocation != nil },
                set: { if !$0 { pairPendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销该来源全部授权", role: .destructive) {
                guard let pair = pairPendingRevocation else { return }
                pairPendingRevocation = nil
                externalEventProjection.reset(ifSource: pair.sourceID)
                Task {
                    _ = await composition.revoke(sourceID: pair.sourceID, profileID: pair.profileID)
                    if selectedSourceID == pair.sourceID {
                        readRequestOwner.switchSource(selectedSourceID)
                        discoveredThreads = []
                        nextThreadCursor = nil
                        selectedThread = nil
                        displayedReadThreadID = nil
                        readPages = []
                    }
                    statusMessage = "已撤销该来源当前授权"
                    await refresh(from: composition)
                }
            }
            Button("取消", role: .cancel) { pairPendingRevocation = nil }
        } message: {
            Text("撤销将推进该来源的授权版本；此前签发的读取和控制授权都会立即失效。")
        }
        .confirmationDialog(
            "确认签发外部会话控制授权？",
            isPresented: $isControlConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认签发控制授权") {
                Task { await mintConfirmedControlGrant(from: composition) }
            }
            .disabled(selectedControlSourceID == nil)
            Button("取消", role: .cancel) {}
        } message: {
            Text("来源：\(selectedControlSourceID.map { composition.sourceLabel(for: $0) } ?? "未选择")；会话：\(controlThreadIDText)；操作：\(controlOperations.map(\.rawValue).sorted().joined(separator: "、"))。读取授权不能执行这些操作。")
        }
        .confirmationDialog(
            "确认向隔离外部会话发送控制操作？",
            isPresented: $isActionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("发送 \(actionOperation.rawValue)") {
                Task { await executeSyntheticControl(composition: composition) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会话：\(controlThreadIDText)；操作：\(actionOperation.rawValue)。操作将发送到已连接的隔离 Codex app-server；回执 accepted 仅表示请求已被接收。")
        }
        .confirmationDialog(
            "新建受控外部任务并启用记忆提案？",
            isPresented: $isOwnedMemoryTaskConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认新建任务") {
                Task { await startOwnedMemoryTask(composition: composition) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在新建线程注册记忆候选工具。来源提交权限需在记忆设置另行开启，每条事实仍须逐条批准；撤权后待审作废。外部任务可在所选工作目录运行。")
        }
    }

    @ViewBuilder
    private func controlledMemoryTaskSection(
        composition: ExternalSessionAuthorizationComposition
    ) -> some View {
        let sourceID = selectedSourceID.flatMap {
            composition.controlledMemorySourceIDs.contains($0) ? $0 : nil
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("新建受控 Codex 记忆任务")
                .font(typography?.caption ?? .caption)
            Text("先选中已授权的 Codex 来源，再选择可执行文件和工作目录。连接与新建均由你分别操作；旧会话、resume 和 fork 不继承记忆工具。")
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
            Button("选择 Codex 可执行文件…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.prompt = "选择可执行文件"
                if panel.runModal() == .OK { ownedCodexExecutableURL = panel.url }
            }
            .accessibilityIdentifier("external-memory-owned-executable")
            if let ownedCodexExecutableURL {
                Text(ownedCodexExecutableURL.path)
                    .font(typography?.caption2 ?? .caption2)
                    .textSelection(.enabled)
            }
            Button("连接已选 Codex 来源…") {
                guard let sourceID, let executableURL = ownedCodexExecutableURL else { return }
                Task {
                    await connectOwnedMemorySource(
                        sourceID: sourceID, executableURL: executableURL,
                        composition: composition
                    )
                }
            }
            .disabled(sourceID == nil || ownedCodexExecutableURL == nil
                || sourceID.flatMap { activeStatusGrant(for: $0) } == nil
                || sourceID.map { composition.hasOwnedDynamicMemoryConnection(for: $0) } == true)
            .accessibilityIdentifier("external-memory-owned-connect")
            Button("选择任务工作目录…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "选择工作目录"
                if panel.runModal() == .OK { ownedMemoryWorkspaceURL = panel.url }
            }
            .accessibilityIdentifier("external-memory-owned-workspace")
            if let ownedMemoryWorkspaceURL {
                Text(ownedMemoryWorkspaceURL.path)
                    .font(typography?.caption2 ?? .caption2)
                    .textSelection(.enabled)
            }
            TextField("受控外部任务内容", text: $ownedMemoryTaskPrompt, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("external-memory-owned-prompt")
            Button("新建受控任务并启用记忆提案…") {
                isOwnedMemoryTaskConfirmationPresented = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(sourceID == nil || ownedMemoryWorkspaceURL == nil
                || ownedMemoryTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sourceID.map { !composition.hasOwnedDynamicMemoryConnection(for: $0) } != false
                || sourceID.flatMap { activeSourceEventGrant(for: $0) } == nil
                || sourceID.flatMap { source in
                    composition.externalMemoryCandidates.first { $0.sourceID == source }
                }.map { candidate in
                    composition.boundMemoryScope(for: candidate) == nil
                } != false)
            .accessibilityIdentifier("external-memory-owned-start")
        }
    }

    private func activeSourceEventGrant(
        for sourceID: ExternalSessionSourceID
    ) -> ExternalSessionReadGrantV1? {
        snapshot.readGrants.reversed().first { grant in
            grant.sourceID == sourceID && grant.scopes.contains(.events)
                && Self.readGrantStatus(grant, in: snapshot, now: .now) == .active
                && {
                    if case .source(let target) = grant.target { return target == sourceID }
                    return false
                }()
        }
    }

    private func connectOwnedMemorySource(
        sourceID: ExternalSessionSourceID,
        executableURL: URL,
        composition: ExternalSessionAuthorizationComposition
    ) async {
        guard let grant = activeStatusGrant(for: sourceID) else {
            errorMessage = "连接拒绝：需要来源级状态读取授权"
            return
        }
        do {
            try await composition.connectOwnedCodexMemorySource(
                sourceID: sourceID, executableURL: executableURL,
                statusReadGrant: grant
            )
            errorMessage = nil
            statusMessage = "受控连接已建立；请在记忆设置另行开启该来源的当前作用域提交权限"
        } catch {
            errorMessage = "受控连接失败；请检查所选来源与协议版本"
        }
        await refresh(from: composition)
    }

    private func startOwnedMemoryTask(
        composition: ExternalSessionAuthorizationComposition
    ) async {
        guard let sourceID = selectedSourceID,
              let workspaceURL = ownedMemoryWorkspaceURL,
              let eventGrant = activeSourceEventGrant(for: sourceID) else {
            errorMessage = "新建拒绝：来源、目录或事件读取授权已失效"
            return
        }
        do {
            _ = try await composition.startOwnedCodexMemoryTask(
                sourceID: sourceID, workspaceURL: workspaceURL,
                prompt: ownedMemoryTaskPrompt, eventsReadGrant: eventGrant
            )
            ownedMemoryTaskPrompt = ""
            errorMessage = nil
            statusMessage = "已新建受控外部任务；记忆候选仍须逐条批准"
        } catch {
            errorMessage = "外部任务状态未确认；请检查原会话，勿自动重试"
        }
    }

    @ViewBuilder
    private func externalSourceSection(_ composition: ExternalSessionAuthorizationComposition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("接入已有外部会话")
                .font(typography?.caption ?? .caption)
            Picker("来源类型", selection: $selectedExternalKind) {
                Text("Codex 桌面客户端").tag(ExternalSessionSourceKindV1.codex)
                Text("Claude Code").tag(ExternalSessionSourceKindV1.claudeCode)
            }
            .accessibilityLabel("来源类型")
            .accessibilityIdentifier("external-session-select-kind")
            Text(selectedExternalKind == .codex
                ? "选择 Codex 的 sessions 目录。选择只登记来源；签发读取授权后才会发现会话。"
                : "选择 Claude Code 的 projects 目录。选择只登记来源；签发读取授权后才会发现会话。")
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
            Button("选择会话目录…") {
                chooseExternalRoot(for: composition)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("external-session-choose-root")
            if let selectedRootDescription {
                Text(selectedRootDescription)
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-selected-root")
            }
        }
    }

    private func chooseExternalRoot(for composition: ExternalSessionAuthorizationComposition) {
        guard let suggestions = composition.directorySelectionSuggestions else {
            errorMessage = "目录建议尚未就绪，请重新打开任务中心。"
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = selectedExternalKind == .codex ? suggestions.codex : suggestions.claudeCode
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "登记来源"
        guard panel.runModal() == .OK, let rootURL = panel.url else { return }
        do {
            let sourceID = try composition.registerSelectedReadRoot(
                kind: selectedExternalKind,
                rootURL: rootURL
            )
            selectedSourceID = sourceID
            readRequestOwner.switchSource(sourceID)
            scopes = [.metadata]
            selectedRootDescription = "已登记 \(composition.sourceLabel(for: sourceID))；目录尚未检查，签发读取授权后才验证并启用"
            errorMessage = nil
        } catch {
            errorMessage = "来源登记失败：\(error)"
        }
    }

    private var pairRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(snapshot.authorizedPairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text("已授权对 \(pair.sourceID.rawValue) · \(pair.profileID.rawValue) · epoch \(pair.revocationEpoch)")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("撤销…") { pairPendingRevocation = pair }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityIdentifier("external-session-revoke-\(pair.sourceID.rawValue)")
                }
                .accessibilityIdentifier(
                    "external-session-authorization-pair-\(pair.sourceID.rawValue)-\(pair.profileID.rawValue)"
                )
            }
        }
    }

    @ViewBuilder
    private func grantRows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(snapshot.readGrants.enumerated()), id: \.offset) { _, grant in
                let status = Self.readGrantStatus(grant, in: snapshot, now: now)
                Text(
                    "读取授权 \(grant.authorizationID.rawValue) · "
                    + "\(Self.targetText(grant.target)) · scopes \(Self.scopeTitles(grant.scopes)) · "
                    + "到期 \(Self.expiryText(grant.expiresAt)) · \(status.title)"
                )
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(status == .active ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "external-session-authorization-read-grant-\(grant.authorizationID.rawValue)"
                    )
            }
            ForEach(Array(snapshot.controlGrants.enumerated()), id: \.offset) { _, grant in
                let status = Self.controlGrantStatus(grant, in: snapshot, now: now)
                Text(
                    "控制授权（只读展示）\(grant.authorizationID.rawValue) · "
                    + "\(Self.targetText(grant.target)) · 到期 \(Self.expiryText(grant.expiresAt)) · \(status.title)"
                )
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "external-session-authorization-control-grant-\(grant.authorizationID.rawValue)"
                    )
            }
        }
    }

    @ViewBuilder
    private func mintSection(
        composition: ExternalSessionAuthorizationComposition,
        supervisedSources: [ExternalSessionSourceID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("签发读取授权")
                .font(typography?.caption ?? .caption)
            if supervisedSources.isEmpty {
                Text("当前没有已登记的授权来源，签发入口保持不可用")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-authorization-mint-unavailable")
            } else {
                Picker("来源", selection: Binding(
                    get: { selectedSourceID ?? supervisedSources.first },
                    set: {
                        selectedSourceID = $0
                        readRequestOwner.switchSource($0)
                        scopes = [.metadata]
                        discoveredThreads = []
                        nextThreadCursor = nil
                        selectedThread = nil
                        displayedReadThreadID = nil
                        readPages = []
                        statusMessage = nil
                        errorMessage = nil
                    }
                )) {
                    ForEach(supervisedSources, id: \.rawValue) { source in
                        Text(composition.sourceLabel(for: source)).tag(Optional(source))
                    }
                }
                .accessibilityLabel("来源")
                .accessibilityIdentifier("external-session-authorization-mint-source")

                Picker("授权粒度", selection: $targetKind) {
                    ForEach(GrantTargetKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("external-session-authorization-mint-target-kind")

                switch targetKind {
                case .source:
                    Text("将授权该来源的全部本机会话读取（受既有 scope/target 执法约束）")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                case .project:
                    TextField("项目 ID", text: $projectIDText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("external-session-authorization-mint-project")
                    Text("项目授权只可读取已知 ID 的项目会话；来源会在正文读取前核验归属，不枚举其他项目。")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                case .session:
                    TextField("会话 ID", text: $sessionIDText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("external-session-authorization-mint-session")
                }

                Text("读取范围（至少一项）")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
                ForEach(Self.selectableScopes, id: \.rawValue) { scope in
                    Toggle(
                        scope.rawValue,
                        isOn: Binding(
                            get: { scopes.contains(scope) },
                            set: { included in
                                if included {
                                    scopes.insert(scope)
                                } else {
                                    scopes.remove(scope)
                                }
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(typography?.caption2 ?? .caption2)
                    .accessibilityIdentifier("external-session-authorization-mint-scope-\(scope.rawValue)")
                    .disabled(!composition.configurableReadScopes(for: selectedSourceID ?? supervisedSources[0]).contains(scope))
                }

                Picker("有效期", selection: $lifetime) {
                    ForEach(GrantLifetime.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityLabel("有效期")
                .accessibilityIdentifier("external-session-authorization-mint-lifetime")

                Button("签发…") {
                    errorMessage = nil
                    isConfirmationPresented = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!(selectedSourceID != nil && isFormComplete && !scopes.isEmpty
                    && scopes.isSubset(of: composition.configurableReadScopes(for: selectedSourceID ?? supervisedSources[0]))))
                .accessibilityIdentifier("external-session-authorization-mint-submit")
            }
        }
    }

    @ViewBuilder
    private func readSection(composition: ExternalSessionAuthorizationComposition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("读取已授权会话")
                .font(typography?.caption ?? .caption)
            Button("发现会话") {
                guard let sourceID = selectedSourceID,
                      let request = readRequestOwner.beginDiscovery(
                          sourceID: sourceID, cursor: .beginning
                      ) else { return }
                Task { await discoverThreads(from: composition, request: request) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedSourceID == nil || activeMetadataGrant() == nil)
            .accessibilityIdentifier("external-session-discover")
            Text("发现会话需来源级元数据授权。项目或单会话授权可输入已知会话 ID；项目归属会在读取前核验。")
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
            HStack {
                TextField("已知会话 ID", text: $directReadThreadIDText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("external-session-direct-thread-id")
                Button("读取指定会话") {
                    guard let sourceID = selectedSourceID else { return }
                    let value = directReadThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    let threadID = ExternalSessionThreadID(rawValue: value)
                    selectedThread = nil
                    displayedReadThreadID = nil
                    readPages = []
                    readRequestOwner.selectThread(threadID)
                    guard let request = readRequestOwner.beginRead(
                        sourceID: sourceID, threadID: threadID, cursor: .beginning
                    ) else { return }
                    Task { await readKnownThread(from: composition, request: request) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedSourceID == nil || directReadThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("external-session-direct-read")
            }
            if !discoveredThreads.isEmpty {
                ForEach(discoveredThreads, id: \.threadID.rawValue) { thread in
                    HStack {
                        Text("\(thread.title) · \(thread.status.rawValue) · 项目 \(thread.projectID?.rawValue ?? "未知")")
                            .font(typography?.caption2 ?? .caption2)
                            .textSelection(.enabled)
                        Button("读取") {
                            guard selectedSourceID == thread.sourceID else { return }
                            selectedThread = thread
                            readRequestOwner.selectThread(thread.threadID)
                            guard let request = readRequestOwner.beginRead(
                                sourceID: thread.sourceID, threadID: thread.threadID,
                                cursor: .beginning
                            ) else { return }
                            Task { await readThread(thread, from: composition, request: request) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!thread.readable || activeMessagesGrant(for: thread) == nil)
                        .accessibilityIdentifier("external-session-read-\(thread.threadID.rawValue)")
                    }
                }
            }
            if let nextThreadCursor {
                Button("更多会话") {
                    guard let sourceID = selectedSourceID,
                          let request = readRequestOwner.beginDiscovery(
                              sourceID: sourceID, cursor: nextThreadCursor
                          ) else { return }
                    Task { await discoverThreads(from: composition, request: request) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("external-session-more-threads")
            }
            if !readPages.isEmpty, displayedReadThreadID == readPages.first?.threadID {
                Text("\(selectedThread?.title ?? displayedReadThreadID?.rawValue ?? "会话")的读取结果")
                    .font(typography?.caption ?? .caption)
                ForEach(Array(readPages.enumerated()), id: \.offset) { _, page in
                    if page.messageChunks.isEmpty {
                        ForEach(Array(page.events.enumerated()), id: \.offset) { _, event in
                            Text(event.payload.summary)
                                .font(typography?.caption2 ?? .caption2)
                                .textSelection(.enabled)
                        }
                    } else {
                        ForEach(Array(page.messageChunks.enumerated()), id: \.offset) { _, chunk in
                            Text("\(chunk.role)：\(chunk.text)")
                                .font(typography?.caption2 ?? .caption2)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let nextCursor = readPages.last?.nextCursor,
                   let displayedReadThreadID {
                    Button("更多内容") {
                        guard let sourceID = selectedSourceID,
                              let request = readRequestOwner.beginRead(
                                  sourceID: sourceID, threadID: displayedReadThreadID,
                                  cursor: nextCursor
                              ) else { return }
                        Task { await readThreadID(from: composition, request: request) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("external-session-more-content")
                }
            }
        }
    }

    private func activeMetadataGrant() -> ExternalSessionReadGrantV1? {
        guard let sourceID = selectedSourceID else { return nil }
        return snapshot.readGrants.reversed().first { grant in
            guard grant.sourceID == sourceID,
                  grant.scopes.contains(.metadata),
                  Self.readGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
            switch grant.target {
            case .source(let targetSource): return targetSource == sourceID
            case .project: return false
            case .thread: return false
            }
        }
    }

    private func activeMessagesGrant(for thread: ExternalSessionThreadV1) -> ExternalSessionReadGrantV1? {
        snapshot.readGrants.reversed().first { grant in
            guard grant.sourceID == thread.sourceID,
                  grant.scopes.contains(.messages),
                  Self.readGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
            switch grant.target {
            case .source(let sourceID): return sourceID == thread.sourceID
            case .project(let projectID): return projectID == thread.projectID
            case .thread(let threadID): return threadID == thread.threadID
            }
        }
    }

    private func discoverThreads(
        from composition: ExternalSessionAuthorizationComposition,
        request: ExternalSessionReadRequestOwner.Envelope
    ) async {
        let sourceID = request.sourceID
        let cursor = request.cursor
        guard readRequestOwner.mayPublish(
            request, selectedSourceID: selectedSourceID,
            displayedThreadID: displayedReadThreadID,
            expectedCursor: nextThreadCursor
        ) else { return }
        guard let adapter = composition.adapter(for: sourceID),
              let grant = activeMetadataGrant() else {
            errorMessage = "发现失败：需要有效的列表读取授权"
            return
        }
        do {
            let page = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(
                    sourceID: sourceID,
                    cursor: cursor,
                    limit: 50
                ),
                readGrant: grant
            )
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: nextThreadCursor
            ) else { return }
            if cursor == .beginning {
                discoveredThreads = page.threads
                selectedThread = nil
                displayedReadThreadID = nil
                readPages = []
            } else {
                discoveredThreads.append(contentsOf: page.threads)
            }
            nextThreadCursor = page.nextCursor
            errorMessage = nil
            statusMessage = "已读取 \(discoveredThreads.count) 个会话"
        } catch {
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: nextThreadCursor
            ) else { return }
            if cursor == .beginning {
                discoveredThreads = []
                nextThreadCursor = nil
                selectedThread = nil
                displayedReadThreadID = nil
                readPages = []
            }
            errorMessage = "发现失败：\(error)"
        }
    }

    private func readThread(
        _ thread: ExternalSessionThreadV1,
        from composition: ExternalSessionAuthorizationComposition,
        request: ExternalSessionReadRequestOwner.Envelope
    ) async {
        let cursor = request.cursor
        guard request.sourceID == thread.sourceID,
              request.threadID == thread.threadID,
              readRequestOwner.mayPublish(
                  request, selectedSourceID: selectedSourceID,
                  displayedThreadID: displayedReadThreadID,
                  expectedCursor: readPages.last?.nextCursor
              ) else { return }
        displayedReadThreadID = thread.threadID
        guard let adapter = composition.adapter(for: thread.sourceID),
              let grant = activeMessagesGrant(for: thread) else {
            errorMessage = "读取失败：需要此会话有效的消息读取授权"
            return
        }
        do {
            let page = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: thread.sourceID,
                    threadID: thread.threadID,
                    cursor: cursor,
                    limit: 50
                ),
                readGrant: grant
            )
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: readPages.last?.nextCursor
            ) else { return }
            if cursor == .beginning { readPages = [page] }
            else { readPages.append(page) }
            errorMessage = nil
            statusMessage = "已读取会话结果"
        } catch {
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: readPages.last?.nextCursor
            ) else { return }
            if cursor == .beginning { readPages = [] }
            errorMessage = "读取失败：\(error)"
        }
    }

    private func readKnownThread(
        from composition: ExternalSessionAuthorizationComposition,
        request: ExternalSessionReadRequestOwner.Envelope
    ) async {
        await readThreadID(from: composition, request: request)
    }

    private func readThreadID(
        from composition: ExternalSessionAuthorizationComposition,
        request: ExternalSessionReadRequestOwner.Envelope
    ) async {
        guard let threadID = request.threadID,
              readRequestOwner.mayPublish(
                  request, selectedSourceID: selectedSourceID,
                  displayedThreadID: displayedReadThreadID,
                  expectedCursor: readPages.last?.nextCursor
              ) else { return }
        let sourceID = request.sourceID
        let cursor = request.cursor
        guard let adapter = composition.adapter(for: sourceID),
              let grant = snapshot.readGrants.reversed().first(where: { grant in
                  guard grant.sourceID == sourceID, grant.scopes.contains(.messages),
                        Self.readGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
                  switch grant.target {
                  case .source(let target): return target == sourceID
                  case .project: return true // App gate verifies exact membership before body I/O.
                  case .thread(let target): return target == threadID
                  }
              }) else {
            errorMessage = "读取失败：需要此会话有效的消息读取授权"
            return
        }
        do {
            let page = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: sourceID, threadID: threadID, cursor: cursor, limit: 50
                ), readGrant: grant
            )
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: readPages.last?.nextCursor
            ) else { return }
            displayedReadThreadID = threadID
            if cursor == .beginning { readPages = [page] }
            else { readPages.append(page) }
            errorMessage = nil
            statusMessage = "已读取会话结果"
        } catch {
            guard readRequestOwner.mayPublish(
                request, selectedSourceID: selectedSourceID,
                displayedThreadID: displayedReadThreadID,
                expectedCursor: readPages.last?.nextCursor
            ) else { return }
            if cursor == .beginning { readPages = [] }
            errorMessage = "读取失败：\(error)"
        }
    }

    @ViewBuilder
    private func controlGrantSection(composition: ExternalSessionAuthorizationComposition) -> some View {
        let controlSources = composition.supervisedSourceIDs.filter {
            !composition.configurableControlOperations(for: $0).isEmpty
        }
        let selectedControlSource = selectedControlSourceID.flatMap { controlSources.contains($0) ? $0 : nil }
        let availableControlOperations = selectedControlSource.map {
            composition.configurableControlOperations(for: $0)
        } ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("单独签发控制授权")
                .font(typography?.caption ?? .caption)
            if controlSources.isEmpty {
                Text("当前没有已配置控制连接的来源；Codex/Claude 只读目录不会自动取得控制能力")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-session-control-unavailable")
            } else {
                Picker("控制来源", selection: Binding(
                    get: { selectedControlSource },
                    set: {
                        selectedControlSourceID = $0
                        controlOperations = []
                        externalEventProjection.reset()
                    }
                )) {
                    Text("请选择来源").tag(nil as ExternalSessionSourceID?)
                    ForEach(controlSources, id: \.rawValue) { source in
                        Text(composition.sourceLabel(for: source)).tag(Optional(source))
                    }
                }
                .accessibilityIdentifier("external-session-control-source")
                .accessibilityLabel("来源")
                .onChange(of: controlSources) { _, sources in
                    if let selectedControlSourceID, !sources.contains(selectedControlSourceID) {
                        self.selectedControlSourceID = nil
                        controlOperations = []
                        externalEventProjection.reset()
                    }
                }
                TextField("要控制的会话 ID", text: $controlThreadIDText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("external-session-control-thread")
                    .onChange(of: controlThreadIDText) { _, _ in externalEventProjection.reset() }
                if let sourceID = selectedControlSource,
                   composition.hasConfiguredSyntheticCodexControl(for: sourceID),
                   composition.supportedControlOperations(for: sourceID).isEmpty {
                    Text("这是隔离合成控制连接。先单独签发控制授权和状态读取授权，再手动启动连接；当前尚未声明控制能力。")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Self.selectableControlOperations, id: \.rawValue) { operation in
                    Toggle(operation.rawValue, isOn: Binding(
                        get: { controlOperations.contains(operation) },
                        set: { included in
                            if included { controlOperations.insert(operation) }
                            else { controlOperations.remove(operation) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!availableControlOperations.contains(operation))
                    .accessibilityIdentifier("external-session-control-operation-\(operation.rawValue)")
                }
                Button("签发控制授权…") {
                    errorMessage = nil
                    isControlConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedControlSource == nil
                    || controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || controlOperations.isEmpty
                    || !controlOperations.isSubset(of: availableControlOperations))
                .accessibilityIdentifier("external-session-control-grant-submit")
                if let sourceID = selectedControlSource,
                   composition.hasConfiguredSyntheticCodexControl(for: sourceID),
                   composition.supportedControlOperations(for: sourceID).isEmpty {
                    Button("启动隔离控制连接…") {
                        Task { await activateSyntheticControl(sourceID: sourceID, composition: composition) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeControlGrant(for: sourceID) == nil || activeStatusGrant(for: sourceID) == nil)
                    .accessibilityIdentifier("external-session-synthetic-control-activate")
                }
                if let sourceID = selectedControlSource,
                   !composition.supportedControlOperations(for: sourceID).isEmpty {
                    Button(composition.hasActiveCodexEventListener(for: sourceID) ? "隔离事件订阅中" : "订阅隔离会话事件") {
                        Task { await subscribeSyntheticEvents(sourceID: sourceID, composition: composition) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(composition.hasActiveCodexEventListener(for: sourceID)
                        || controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || activeEventGrant(for: sourceID, threadID: controlThreadIDText) == nil)
                    .accessibilityIdentifier("external-session-synthetic-event-subscribe")
                    Text("订阅需另行签发此会话的 events 读取授权；断线后按状态和原会话对账，事件流不保证重放。")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                    if externalEventProjection.sourceID == sourceID,
                       externalEventProjection.threadID?.rawValue
                           == controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines),
                       !externalEventProjection.chunks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已脱敏消息片段（仅当前订阅，最多 32 条）")
                                .font(typography?.caption2 ?? .caption2)
                            ForEach(externalEventProjection.chunks) { chunk in
                                Text(chunk.text)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("external-session-safe-message-chunk")
                            }
                        }
                    }
                    Picker("执行操作", selection: $actionOperation) {
                        ForEach(Self.selectableControlOperations.filter {
                            composition.supportedControlOperations(for: sourceID).contains($0)
                        }, id: \.rawValue) { operation in
                            Text(operation.rawValue).tag(operation)
                        }
                    }
                    .accessibilityIdentifier("external-session-control-action")
                    if actionOperation == .steer || actionOperation == .interrupt {
                        TextField("当前 turn ID", text: $actionTurnIDText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("external-session-control-turn")
                    }
                    if actionOperation == .steer {
                        TextField("补充指令", text: $actionInputText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("external-session-control-input")
                    }
                    Button("执行控制…") {
                        isActionConfirmationPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!composition.hasActiveCodexEventListener(for: sourceID)
                        || activeControlGrant(
                        for: sourceID,
                        threadID: controlThreadIDText,
                        operation: actionOperation
                    ) == nil
                        || ((actionOperation == .approve || actionOperation == .reject)
                            ? composition.adapter(for: sourceID)?.runtimeSnapshot.pendingApproval == nil
                            : activeStatusGrant(for: sourceID) == nil)
                        || ((actionOperation == .steer || actionOperation == .interrupt)
                            && actionTurnIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || (actionOperation == .steer
                            && actionInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("external-session-control-execute")
                    if let runtime = composition.adapter(for: sourceID)?.runtimeSnapshot,
                       runtime.unconfirmedControl != nil || !(runtime.humanResolutionHistory ?? []).isEmpty {
                        ExternalSessionHumanResolutionCard(composition: composition, sourceID: sourceID,
                            readGrant: activeStatusGrant(for: sourceID),
                            controlGrant: activeControlGrant(for: sourceID))
                    }
                    if let lastControlReceipt {
                        Text("最近回执：\(lastControlReceipt.operation.rawValue) · \(lastControlReceipt.outcome.rawValue) · \(lastControlReceipt.detail ?? "无详情")")
                            .font(typography?.caption2 ?? .caption2)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("external-session-control-receipt")
                        if let childThreadID = lastControlReceipt.childThreadID {
                            Text("新会话 ID：\(childThreadID.rawValue)")
                                .font(typography?.caption2 ?? .caption2)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("external-session-fork-child-thread")
                        }
                    }
                }
            }
        }
    }

    static let selectableControlOperations: [ExternalSessionControlOperationV1] = [
        .resume, .fork, .steer, .interrupt, .approve, .reject
    ]

    private func mintConfirmedControlGrant(from composition: ExternalSessionAuthorizationComposition) async {
        guard let sourceID = selectedControlSourceID,
              let profileID = composition.supervisedProfileID(for: sourceID),
              !controlOperations.isEmpty,
              controlOperations.isSubset(of: composition.configurableControlOperations(for: sourceID)) else {
            errorMessage = "控制授权失败：来源尚无可用控制能力"
            return
        }
        let threadID = controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            errorMessage = "控制授权失败：会话 ID 不能为空"
            return
        }
        do {
            _ = try await composition.issueControlGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: UUID().uuidString),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(ExternalSessionThreadID(rawValue: threadID)),
                operations: controlOperations,
                lifetime: lifetime.seconds
            )
            errorMessage = nil
            statusMessage = "已单独签发控制授权；执行操作仍需选择会话并确认"
        } catch {
            statusMessage = nil
            errorMessage = "控制授权失败：\(error)"
        }
        await refresh(from: composition)
    }

    private func activeControlGrant(for sourceID: ExternalSessionSourceID) -> ExternalSessionControlGrantV1? {
        snapshot.controlGrants.reversed().first { grant in
            guard grant.sourceID == sourceID,
                  Self.controlGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
            if case .thread = grant.target { return true }
            return false
        }
    }

    private func activeControlGrant(
        for sourceID: ExternalSessionSourceID,
        threadID: String,
        operation: ExternalSessionControlOperationV1
    ) -> ExternalSessionControlGrantV1? {
        let wanted = ExternalSessionThreadID(rawValue: threadID.trimmingCharacters(in: .whitespacesAndNewlines))
        return snapshot.controlGrants.reversed().first { grant in
            guard grant.sourceID == sourceID,
                  grant.operations.contains(operation),
                  Self.controlGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
            if case .thread(let target) = grant.target { return target == wanted }
            return false
        }
    }

    private func activeStatusGrant(for sourceID: ExternalSessionSourceID) -> ExternalSessionReadGrantV1? {
        snapshot.readGrants.reversed().first { grant in
            grant.sourceID == sourceID && grant.scopes.contains(.status)
                && Self.readGrantStatus(grant, in: snapshot, now: .now) == .active
                && {
                    if case .source(let target) = grant.target { return target == sourceID }
                    return false
                }()
        }
    }

    private func activeEventGrant(
        for sourceID: ExternalSessionSourceID,
        threadID: String
    ) -> ExternalSessionReadGrantV1? {
        let targetThread = ExternalSessionThreadID(rawValue: threadID.trimmingCharacters(in: .whitespacesAndNewlines))
        return snapshot.readGrants.reversed().first { grant in
            guard grant.sourceID == sourceID, grant.scopes.contains(.events),
                  Self.readGrantStatus(grant, in: snapshot, now: .now) == .active else { return false }
            switch grant.target {
            case .source(let target): return target == sourceID
            case .project: return true // Membership is checked before each delivered event.
            case .thread(let target): return target == targetThread
            }
        }
    }

    private func subscribeSyntheticEvents(
        sourceID: ExternalSessionSourceID,
        composition: ExternalSessionAuthorizationComposition
    ) async {
        let value = controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let grant = activeEventGrant(for: sourceID, threadID: value),
              let generation = composition.adapter(for: sourceID)?.runtimeSnapshot.generation else {
            errorMessage = "订阅拒绝：需要当前会话单独的事件读取授权"
            return
        }
        let threadID = ExternalSessionThreadID(rawValue: value)
        let subscriptionID = externalEventProjection.begin(
            sourceID: sourceID, threadID: threadID, generation: generation, grant: grant
        )
        do {
            try await composition.subscribeSyntheticCodexEvents(
                sourceID: sourceID,
                threadID: threadID,
                readGrant: grant,
                onEvent: externalEventProjection.consumer(
                    composition: composition, subscriptionID: subscriptionID
                )
            )
            errorMessage = nil
            statusMessage = "隔离会话事件订阅已就绪；断线或未知结果需状态对账"
        } catch {
            externalEventProjection.reset(ifSubscription: subscriptionID)
            errorMessage = "事件订阅失败：\(error)"
        }
    }

    private func activateSyntheticControl(
        sourceID: ExternalSessionSourceID,
        composition: ExternalSessionAuthorizationComposition
    ) async {
        guard let controlGrant = activeControlGrant(for: sourceID),
              let readGrant = activeStatusGrant(for: sourceID) else {
            errorMessage = "连接失败：需有效的独立控制授权和来源状态读取授权"
            return
        }
        do {
            try await composition.activateSyntheticCodexControl(
                sourceID: sourceID,
                readGrant: readGrant,
                controlGrant: controlGrant
            )
            errorMessage = nil
            statusMessage = "隔离 Codex 控制连接已建立；实际操作仍须逐项确认"
        } catch {
            errorMessage = "隔离控制连接失败：\(error)"
        }
    }

    private func executeSyntheticControl(composition: ExternalSessionAuthorizationComposition) async {
        guard let sourceID = selectedControlSourceID,
              let adapter = composition.adapter(for: sourceID),
              let grant = activeControlGrant(
                  for: sourceID,
                  threadID: controlThreadIDText,
                  operation: actionOperation
              ) else {
            errorMessage = "控制拒绝：缺少当前会话的控制授权"
            return
        }
        if actionOperation == .approve || actionOperation == .reject {
            do {
                try await composition.respondToSyntheticCodexApproval(
                    sourceID: sourceID, decision: actionOperation, controlGrant: grant
                )
                lastControlReceipt = nil
                errorMessage = nil
                statusMessage = "审批回应已发送；等待原会话确认，断线后需对账"
            } catch {
                errorMessage = "审批结果未确认：\(error)；请检查原会话，勿自动重试"
            }
            return
        }
        guard let statusGrant = activeStatusGrant(for: sourceID) else {
            errorMessage = "控制拒绝：缺少来源状态读取授权"
            return
        }
        let threadID = ExternalSessionThreadID(rawValue: controlThreadIDText.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let status = try await adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: sourceID, threadID: threadID),
                readGrant: statusGrant
            )
            let turnText = actionTurnIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            let turnID = turnText.isEmpty ? nil : ExternalSessionTurnID(rawValue: turnText)
            let request = ExternalSessionControlRequestV1(
                sourceID: sourceID,
                threadID: threadID,
                turnID: turnID,
                operation: actionOperation,
                expectedCursor: status.observedCursor,
                idempotencyKey: UUID().uuidString,
                boundedInput: actionOperation == .steer
                    ? actionInputText.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            )
            let receipt: ExternalSessionControlReceiptV1
            if actionOperation == .interrupt {
                receipt = try await adapter.cancel(
                    sourceID: sourceID,
                    threadID: threadID,
                    turnID: turnID,
                    expectedCursor: status.observedCursor,
                    idempotencyKey: request.idempotencyKey,
                    controlGrant: grant
                )
            } else {
                receipt = try await adapter.control(request: request, controlGrant: grant)
            }
            lastControlReceipt = receipt
            errorMessage = nil
            statusMessage = "控制回执：\(receipt.outcome.rawValue)；请核对后续事件和会话状态"
        } catch {
            lastControlReceipt = nil
            errorMessage = "控制结果未确认：\(error)；请检查原会话状态，勿自动重试"
        }
    }

    private func confirmationSummaryText(supervisedSources: [ExternalSessionSourceID]) -> String {
        let sourceText = selectedSourceID?.rawValue
            ?? supervisedSources.first?.rawValue
            ?? "未选择"
        let targetText: String
        switch targetKind {
        case .source:
            targetText = "整个来源"
        case .project:
            targetText = "项目 \(projectIDText.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .session:
            targetText = "会话 \(sessionIDText.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "来源：\(sourceText)；粒度：\(targetText)；范围：\(Self.scopeTitles(scopes))；有效期：\(lifetime.title)。"
            + "本授权仅允许读取；控制操作须另行签发。"
    }

    private func refresh(from composition: ExternalSessionAuthorizationComposition) async {
        snapshot = await composition.authorizationSnapshot()
        externalEventProjection.reconcileAuthorization(snapshot)
        hasLoadedSnapshot = true
    }

    private func mintConfirmedGrant(from composition: ExternalSessionAuthorizationComposition) async {
        guard let sourceID = selectedSourceID else {
            errorMessage = "签发失败：未选择来源"
            return
        }
        guard let profileID = composition.supervisedProfileID(for: sourceID) else {
            errorMessage = "签发失败：该来源没有已登记的 profile"
            return
        }
        let target: ExternalSessionReadTargetV1?
        switch targetKind {
        case .source:
            target = .source(sourceID)
        case .project:
            let value = projectIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            target = value.isEmpty ? nil : .project(ExternalSessionProjectID(rawValue: value))
        case .session:
            let value = sessionIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            target = value.isEmpty ? nil : .thread(ExternalSessionThreadID(rawValue: value))
        }
        guard let mintedTarget = target else {
            errorMessage = "签发失败：授权目标不能为空"
            return
        }
        guard !scopes.isEmpty else {
            errorMessage = "签发失败：至少选择一个读取范围"
            return
        }
        do {
            let grant = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: UUID().uuidString),
                sourceID: sourceID,
                profileID: profileID,
                target: mintedTarget,
                scopes: scopes,
                lifetime: lifetime.seconds
            )
            if composition.isReadRootPending(for: sourceID) {
                _ = try await composition.activateSelectedReadRoot(
                    sourceID: sourceID,
                    readGrant: grant
                )
            }
            errorMessage = nil
            statusMessage = "已签发读取授权并启用已验证来源"
        } catch {
            statusMessage = nil
            errorMessage = "签发或来源验证失败：\(error)；请刷新台账查看授权状态"
        }
        await refresh(from: composition)
    }

    private static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
