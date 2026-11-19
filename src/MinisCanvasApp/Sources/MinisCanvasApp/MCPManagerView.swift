import AppKit
import SwiftUI
import MinisCore

// MARK: - MCP 管理面板（E6）
//
// 服务器列表（名称/类型/启用开关/测试连接/删除）+ 新增表单（sheet）。
// 数据全部走 SettingsCenter.mcpManager（MCPServerManager：CRUD + mcps.json 持久化）。
// 风格对齐 Codex `codex mcp` 管理体验。

struct MCPManagerView: View {
    @Bindable var center: SettingsCenter
    var widthClass: AdaptiveWidthClass? = nil
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    @State private var showingAddSheet = false
    @State private var showingImportSheet = false
    @State private var editingServer: MCPServer?
    /// 正在测试连接的服务器 id（按钮转圈）
    @State private var reconnectingIDs: Set<String> = []
    @State private var testingID: String?
    /// 正在执行 tools/list 的服务器 id（按钮转圈）
    @State private var discoveringToolsID: String?
    /// 最近一次测试结果（按服务器 id）
    @State private var testResults: [String: MCPTestResult] = [:]
    /// 最近一次 tools/list 失败（按服务器 id）
    @State private var discoveryErrors: [String: String] = [:]
    /// 让 manager 的跨 turn discovery cache 在刷新完成后重绘。
    @State private var discoveryRevision = 0
    @State private var lastActionMessage: String?
    @State private var pendingDeleteServer: MCPServer?
    /// 11/16：工具授权区默认展开，这里记录被用户手动收起的服务器。
    @State private var collapsedToolAuthorizationServerIDs: Set<String> = []
    @State private var oauthStates: [String: MCPOAuthState] = [:]
    @State private var oauthClientIDs: [String: String] = [:]
    @State private var oauthLoginIDs: Set<String> = []
    @State private var oauthBrowser: MCPWebAuthentication?
    @State private var oauthLoginTask: Task<Void, Never>?
    /// 项目 .mcp.json 的待批准状态（按已知项目）。批准之前不会启动、不会授权。
    @State private var projectMCPSnapshots: [MCPProjectConfigSnapshot] = []

    private var projectMCPStore: MCPProjectConfigStore {
        MCPProjectConfigStore.resident(directory: center.mcpManager.fileURL.deletingLastPathComponent())
    }

    private func refreshProjectMCP() {
        let store = projectMCPStore
        let existing = Set(center.mcpServers.map(\.id))
        let roots = MinisCore.HookRuntime.installed?.knownProjectRoots() ?? []
        projectMCPSnapshots = roots.compactMap { root in
            let snapshot = store.snapshot(projectRoot: root, existingIDs: existing, existingServers: center.mcpServers)
            if case .noFile = snapshot.trust { return nil }
            return snapshot
        }
    }

    /// 批准项目 .mcp.json。默认不覆盖用户改过的同 id 服务器；`overwriteModified` 为真（用户点“仍然覆盖”）才覆盖。
    /// 覆盖已有服务器时一律保留用户的启用开关与超时，已存凭据不动。
    private func approveProjectMCP(_ snapshot: MCPProjectConfigSnapshot, overwriteModified: Bool = false) {
        guard let hash = snapshot.contentHash else { return }
        let root = URL(fileURLWithPath: snapshot.projectRoot, isDirectory: true)
        let toImport = (overwriteModified ? snapshot.allServers : snapshot.servers).map { server -> MCPServer in
            guard let local = center.mcpServers.first(where: { $0.id == server.id }) else { return server }
            var merged = server
            merged.enabled = local.enabled
            merged.timeoutSeconds = local.timeoutSeconds
            merged.callTimeoutSeconds = local.callTimeoutSeconds
            return merged
        }
        do {
            // 先导入，全部成功后才记“已批准”；导入失败时批准按钮保留，可以重试。
            guard importServers(toImport) else {
                refreshProjectMCP()
                return
            }
            try projectMCPStore.trust(projectRoot: root, expectedHash: hash,
                                      serverIDs: toImport.map(\.id), servers: snapshot.allServers)
            let skipped = overwriteModified ? [] : snapshot.locallyModifiedServers
            if !skipped.isEmpty {
                lastActionMessage = (lastActionMessage.map { $0 + " " } ?? "")
                    + "你改过的 \(skipped.count) 个服务器没有自动更新：\(skipped.map(\.name).joined(separator: "、"))。需要时点“仍然覆盖”。"
            }
        } catch {
            lastActionMessage = (error as? LocalizedError)?.errorDescription ?? "批准失败，请重试。"
        }
        refreshProjectMCP()
    }

    private func revokeProjectMCP(_ snapshot: MCPProjectConfigSnapshot) {
        do {
            try projectMCPStore.revokeTrust(projectRoot: URL(fileURLWithPath: snapshot.projectRoot, isDirectory: true))
        } catch {
            lastActionMessage = (error as? LocalizedError)?.errorDescription ?? "撤销批准失败，批准状态没有变化，请重试。"
            refreshProjectMCP()
            return
        }
        // 撤销批准要真的停下来：从这份文件导入的服务器（按 ID 对应）一并停用。
        let importedIDs = Set(snapshot.servers.map(\.id))
        var disabled: [String] = []
        for server in center.mcpServers where server.enabled && importedIDs.contains(server.id) {
            if center.toggleMCPServer(id: server.id, enabled: false) { disabled.append(server.name) }
        }
        lastActionMessage = disabled.isEmpty
            ? "已撤销批准。之前导入的服务器没有变化。"
            : "已撤销批准，并停用了从该文件导入的 \(disabled.count) 个服务器：\(disabled.joined(separator: "、"))。"
        refreshProjectMCP()
    }

    @ViewBuilder
    private func projectMCPSection(_ snapshot: MCPProjectConfigSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.projectRoot).font(.callout).lineLimit(1).truncationMode(.middle)
            switch snapshot.trust {
            case .invalid(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .noFile:
                EmptyView()
            case .untrusted(let changed):
                Text(changed ? "内容在上次批准之后变了，需要重新批准。批准前不会启动，也不会授权。"
                             : "项目自带的服务器配置，批准前不会启动，也不会授权。")
                    .font(.caption).foregroundStyle(.secondary)
            case .trusted:
                Text("已批准；服务器已导入上方列表，工具仍需在列表里逐个授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.entries) { entry in
                Text("· \(entry.sourceName)：\(entry.server != nil ? entry.summary : (entry.note ?? "无法导入"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if entry.server != nil, let note = entry.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if snapshot.needsTrustDecision, !snapshot.allServers.isEmpty {
                    Button(snapshot.trust == .untrusted(changedSinceTrust: true) ? "批准更新" : "批准并导入") { approveProjectMCP(snapshot) }
                        .accessibilityIdentifier("mcp.project.approve")
                }
                if snapshot.needsTrustDecision, !snapshot.locallyModifiedServers.isEmpty {
                    Button("仍然覆盖你改过的") { approveProjectMCP(snapshot, overwriteModified: true) }
                        .accessibilityIdentifier("mcp.project.overwriteModified")
                }
                if case .trusted = snapshot.trust {
                    Button("撤销批准") { revokeProjectMCP(snapshot) }
                        .accessibilityIdentifier("mcp.project.revoke")
                }
            }
        }
        .padding(.vertical, 2)
    }



    /// Focused field instrumentation seam for NSHosting/AppKit measurement.
    @MainActor
    internal func typographyInstrumentationView() -> AnyView {
        AnyView(self)
    }

    // Shared by both caption consumers below; status glyphs retain their own tokens.
    static func feedbackTextToken(succeeded: Bool, theme: ThemeTokenProvider) -> ThemeColor {
        theme.readableStatusText(succeeded ? theme.tokens.statusSuccess : theme.tokens.statusDanger)
    }

    private func restoreServer(_ server: MCPServer) {
        do {
            guard center.mcpManager.trashedServers().contains(server),
                  try center.mcpManager.restoreServer(id: server.id) != nil else {
                lastActionMessage = "恢复失败，回收区配置已变化。"
                center.reloadMCP()
                return
            }
            center.reloadMCP()
            lastActionMessage = "已恢复服务器「\(server.name)」的配置，请重新授权。"
        } catch {
            center.reloadMCP()
            lastActionMessage = "恢复失败，请刷新后重试。"
        }
    }

    /// 配置文件写入被拦下时的说明（读取与列表仍可用，改动不会保存）。
    static func persistenceConflictMessage(_ conflict: MCPPersistenceConflict) -> String {
        switch conflict {
        case .staleSnapshot, .needsReopen:
            return "MCP 配置文件已被其他窗口或进程改动，当前改动不会保存。请重新打开此页面后再改。"
        case .writerBusy:
            return "MCP 配置文件正被其他进程写入，暂时无法保存改动，请稍后重试。"
        case .incompleteSnapshot:
            return "MCP 配置文件读取不完整，为避免覆盖原文件，改动暂不保存。请检查配置文件后重新打开此页面。"
        case .scopeUnavailable, .documentUnavailable, .documentTooLarge:
            return "MCP 配置文件无法读写，改动不会保存。请检查文件是否存在、权限与大小是否正常。"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedWidthClass = widthClass ?? AdaptiveLayoutPolicy.widthClass(for: geometry.size.width)
            VStack(spacing: 0) {
                header

                Divider()

                if let conflict = center.mcpManager.persistenceWriteConflict() {
                    Text(Self.persistenceConflictMessage(conflict))
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mcp.persistence-conflict")
                }

                let trashedServers = center.mcpManager.trashedServers()
                if center.mcpServers.isEmpty && trashedServers.isEmpty && projectMCPSnapshots.isEmpty {
                    ContentUnavailableView(
                        label: {
                            Label {
                                Text("暂无 MCP 服务器")
                            } icon: {
                                MinisIconView(.server, size: 20, accessibilityLabel: "MCP 服务器")
                            }
                        },
                        description: {
                            Text("添加本地 stdio 或 HTTP 服务器，让智能体可以调用这些工具。")
                        }
                    )
                } else {
                    List {
                        ForEach(center.mcpServers) { server in
                            serverRow(server, widthClass: resolvedWidthClass)
                        }
                        if !projectMCPSnapshots.isEmpty {
                            Section("项目 .mcp.json（待批准）") {
                                ForEach(projectMCPSnapshots, id: \.projectRoot) { snapshot in
                                    projectMCPSection(snapshot)
                                }
                            }
                        }
                        if !trashedServers.isEmpty {
                            Section("已删除的 MCP 服务器") {
                                ForEach(trashedServers) { server in
                                    HStack {
                                        Text(server.name)
                                        Spacer()
                                        Button("恢复「\(server.name)」") { restoreServer(server) }
                                            .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).restore")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPServerEditSheet { draft in saveServerDraft(draft) }
        }
        .sheet(isPresented: $showingImportSheet) {
            MCPJSONImportSheet(existingIDs: Set(center.mcpServers.map(\.id))) { servers in importServers(servers) }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditSheet(existing: server) { draft in saveServerDraft(draft) }
        }
        .confirmationDialog(
            "删除 MCP 服务器？",
            isPresented: Binding(
                get: { pendingDeleteServer != nil },
                set: { if !$0 { pendingDeleteServer = nil } }
            ),
            presenting: pendingDeleteServer
        ) { server in
            Button("删除「\(server.name)」", role: .destructive) {
                if center.removeMCPServer(id: server.id) {
                    testResults[server.id] = nil
                    lastActionMessage = "已删除服务器「\(server.name)」。"
                } else {
                    lastActionMessage = MCPFailureMessage.change(center.lastMCPWriteFailure)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { server in
            Text("将「\(server.name)」移入回收区。恢复配置后需要重新授权。")
        }
        .task { center.reloadMCP(); refreshProjectMCP() }
        .task(id: discoveryRevision) { await refreshOAuthStates() }
        .onReceive(NotificationCenter.default.publisher(for: MCPOAuthCoordinator.stateChanged)
            .receive(on: RunLoop.main)) { _ in discoveryRevision &+= 1 }

        .onReceive(NotificationCenter.default.publisher(for: MCPServerManager.runtimeChanged)
            .receive(on: RunLoop.main)) { notification in
            guard let manager = notification.object as? MCPServerManager, manager === center.mcpManager else { return }
            center.reloadMCP()
            discoveryRevision &+= 1
        }
        .font(typography?.body ?? .body)

    }

    @MainActor
    @discardableResult
    private func importServers(_ servers: [MCPServer]) -> Bool {
        var added = 0
        var failed: [String] = []
        for server in servers {
            if center.addMCPServer(server) { added += 1 } else { failed.append(server.name) }
        }
        lastActionMessage = failed.isEmpty
            ? "已导入 \(added) 个服务器，默认未授权；请在列表中逐个检查并授权。"
            : "已导入 \(added) 个；\(failed.count) 个导入失败：\(failed.joined(separator: "、"))。请检查配置后重试。"
        return failed.isEmpty
    }

    @MainActor
    private func saveServerDraft(_ draft: MCPServerEditDraft) -> Bool {
        let saved = draft.save(to: center)
        if saved {
            // A successful edit changes the server descriptor.  Any result from
            // the previous descriptor must not remain visible as if it applied
            // to the newly saved configuration.
            testResults[draft.id] = nil
            discoveryErrors[draft.id] = nil
        }
        lastActionMessage = saved ? "已保存服务器「\(draft.name)」。"
            : MCPFailureMessage.save(center.lastMCPWriteFailure)
        return saved
    }

    @MainActor
    private func refreshOAuthStates() async {
        for server in center.mcpServers where MCPOAuthCoordinator.isEligible(server) {
            if await center.mcpManager.oauth.isKnownRequired(for: server) {
                oauthStates[server.id] = await center.mcpManager.oauth.state(for: server)
            } else { oauthStates[server.id] = nil }
        }
    }

    private func oauthControls(_ server: MCPServer, authorized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("登录状态：" + (oauthStates[server.id] ?? .needsLogin).rawValue)
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).oauth-state")
            TextField("client_id（服务器不支持动态注册时填写）", text: Binding(
                get: { oauthClientIDs[server.id, default: ""] },
                set: { oauthClientIDs[server.id] = $0 }
            ))
            HStack {
                Button(oauthLoginIDs.contains(server.id) ? "正在登录…" : "登录") {
                    oauthLoginTask = Task { await loginOAuth(server) }
                }
                .disabled(!authorized || !server.enabled || !center.isSafetyFeatureEnabled(.mcp)
                    || !oauthLoginIDs.isEmpty)
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).oauth-login")
                Button("退出登录") {
                    oauthLoginTask?.cancel()
                    Task {
                        do {
                            try await center.mcpManager.logoutOAuth(serverID: server.id)
                            await refreshOAuthStates()
                        } catch { lastActionMessage = MCPOAuthError.credentialUnavailable.localizedDescription }
                    }
                }
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).oauth-logout")
            }
        }
    }

    @MainActor
    private func loginOAuth(_ server: MCPServer) async {
        guard center.isSafetyFeatureEnabled(.mcp), server.enabled,
              center.mcpManager.isServerAuthorized(server),
              center.mcpManager.server(id: server.id) == server,
              oauthLoginIDs.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        oauthLoginIDs.insert(server.id)
        let browser = MCPWebAuthentication(window: window)
        oauthBrowser = browser
        defer { oauthLoginIDs.remove(server.id); oauthBrowser = nil }
        do {
            // The normal managed initialize request obtains a real 401 challenge before browser authorization.
            if !(await center.mcpManager.oauth.hasChallenge(server: server)) {
                do { try await center.mcpManager.reconnect(serverID: server.id) }
                catch let error as MCPOAuthError {
                    guard error == .loginRequired || error == .expired else { throw error }
                }
            }
            try await center.mcpManager.oauth.login(server: server, manualClientID: oauthClientIDs[server.id]) { url, scheme in
                try await browser.authenticate(url: url, scheme: scheme)
            }
            guard center.isSafetyFeatureEnabled(.mcp), center.mcpManager.server(id: server.id) == server,
                  center.mcpManager.isServerAuthorized(server) else {
                try await center.mcpManager.oauth.logout(server: server)
                throw MCPOAuthError.stale
            }
            try await center.mcpManager.reconnect(serverID: server.id)
            lastActionMessage = "MCP 已登录。"
        } catch {
            // Only local fixed messages, never AS response/callback/URLError descriptions.
            lastActionMessage = (error as? MCPOAuthError ?? .requestFailed).localizedDescription
        }
        await refreshOAuthStates()
    }

    // MARK: 头部（新增按钮 + 状态提示）

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showingAddSheet = true
            } label: {
                Label {
                    Text("新增服务器")
                } icon: {
                    MinisIconView(.add, size: 16, accessibilityLabel: "新增服务器")
                }
            }

            Button {
                showingImportSheet = true
            } label: {
                Text("从 JSON 导入")
            }
            .accessibilityIdentifier("mcp.import-json")

            if let lastActionMessage {
                Text(lastActionMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(center.mcpServers.count) 个服务器 · \(center.mcpServers.filter(\.enabled).count) 启用")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("typography.mcp.server-count")
        }
        .padding(12)
    }

    // MARK: 服务器行

    private func serverRow(
        _ server: MCPServer,
        widthClass: AdaptiveWidthClass
    ) -> some View {
        let serverAuthorized = center.isMCPServerAuthorized(id: server.id)
        let _ = discoveryRevision
        let session = center.mcpManager.replacementSessionState(serverID: server.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                MinisIconView(
                    typeIcon(server.type),
                    state: server.enabled ? .active : .disabled,
                    size: 16,
                    accessibilityLabel: server.type == .stdio ? "stdio" : "HTTP"
                )
                    .foregroundPalette(server.enabled ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        Text(server.id)
                            .font(typography?.caption2 ?? .caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                    Text(server.transportSummary)
                        .font(typography?.caption2 ?? .system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("配置状态：\(replacementPhaseLabel(session.phase)) · 连接：\(runtimeLabel(center.mcpManager.runtimeState(serverID: server.id)))")
                        .help("替换会话 r\(session.revision)")
                        .font(typography?.caption2 ?? .caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "mcp.server.\(accessibilityComponent(server.id)).lifecycle"
                        )
                        .accessibilityValue(session.id)
                }

                Text(server.type == .stdio ? "stdio" : "http")
                    .font(typography?.caption2 ?? .caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(mcpTypeTagColor(server.type).opacity(0.15)))
                    .foregroundStyle(mcpTypeTagColor(server.type))
            }

            if let message = center.mcpManager.runtimeMessage(serverID: server.id) {
                Text(verbatim: message).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).runtime-message")
            }
            if server.type == .http {
                Text("HTTP 当前仅支持请求/响应；不支持服务器征询与工具变化通知。可手动刷新工具列表。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }

            if MCPOAuthCoordinator.isEligible(server), oauthStates[server.id] != nil {
                oauthControls(server, authorized: serverAuthorized)
            }

            serverActionRow(
                server: server,
                authorized: serverAuthorized,
                widthClass: widthClass
            )
                .frame(maxWidth: .infinity, alignment: .leading)

            if server.enabled, serverAuthorized {
                toolAuthorizationSection(for: server)
            }

            if let result = testResults[server.id] {
                Label {
                    Text(result.message)
                } icon: {
                    MinisIconView(
                        result.ok ? .success : .warning,
                        state: result.ok ? .success : .danger,
                        size: 16
                    )
                }
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme.map { Self.feedbackTextToken(succeeded: result.ok, theme: $0).swiftUIColor }
                        ?? (result.ok ? .green : .red))
                    .padding(.leading, 24)
                    .accessibilityLabel("测试连接结果")
                    .accessibilityValue(result.accessibilityValue)
                    .accessibilityIdentifier(
                        "mcp.server.\(accessibilityComponent(server.id)).connection-test.result"
                    )
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func serverActionRow(
        server: MCPServer,
        authorized: Bool,
        widthClass: AdaptiveWidthClass
    ) -> some View {
        Group {
            if widthClass == .compact || widthClass == .medium {
                VStack(alignment: .leading, spacing: 8) {
                    serverActionControls(server: server, authorized: authorized)
                }
            } else {
                HStack(spacing: 10) {
                    serverActionControls(server: server, authorized: authorized)
                }
            }
        }
        .padding(.leading, 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).actions")
    }

    @ViewBuilder
    private func serverActionControls(
        server: MCPServer,
        authorized: Bool
    ) -> some View {

                Button("编辑") { editingServer = server }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("编辑 \(server.name)")
                    .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).edit")

                Toggle("启用 \(server.name)", isOn: Binding(
                    get: { server.enabled },
                    set: { newValue in
                        if center.toggleMCPServer(id: server.id, enabled: newValue) {
                            lastActionMessage = newValue ? "已启用「\(server.name)」。"
                                                         : "已禁用「\(server.name)」。"
                        } else {
                            lastActionMessage = MCPFailureMessage.change(center.lastMCPWriteFailure)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityValue(server.enabled ? "已启用" : "已停用")
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).enabled")
                .help("启用后该服务器的工具进入 Agent 工具循环")

                Toggle("授权", isOn: Binding(
                    get: { authorized },
                    set: { newValue in
                        if center.setMCPServerAuthorized(id: server.id, authorized: newValue) {
                            lastActionMessage = newValue ? "已授权「\(server.name)」；工具仍需逐项授权。"
                                                         : "已撤销「\( server.name)」的授权。"
                            if newValue {
                                discoverTools(for: server)
                            }
                        } else {
                            lastActionMessage = MCPFailureMessage.change(center.lastMCPWriteFailure)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("授权 \(server.name)")
                .disabled(!server.enabled)
                .accessibilityValue(
                    authorized ? "已授权" : "未授权"
                )
                .accessibilityIdentifier(
                    "mcp.server.\(accessibilityComponent(server.id)).authorization"
                )
                .help("服务器授权与启用状态分离；工具仍需逐项授权")

                Button {
                    reconnect(server)
                } label: {
                    Label {
                        Text(reconnectingIDs.contains(server.id) ? "正在重连…" : "重连")
                    } icon: { MinisIconView(.refresh, size: 16) }
                }
                .buttonStyle(.borderless)
                .disabled(reconnectingIDs.contains(server.id) || !server.enabled || !authorized)
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).reconnect")
                .help("断开原服务器连接，重新握手并刷新工具列表；不授予工具权限")

                Button {
                    runTest(server)
                } label: {
                    if testingID == server.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label {
                            Text("测试连接")
                        } icon: {
                            MinisIconView(.connection, size: 16, accessibilityLabel: "测试连接")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(testingID != nil || !server.enabled || !authorized)
                .accessibilityLabel("测试连接")
                .accessibilityHint("测试 \(server.name) 的握手与 tools/list，不授予工具权限")
                .accessibilityValue(
                    testingID == server.id
                        ? "进行中"
                        : (!server.enabled ? "已禁用" : (!authorized ? "需服务器授权" : "就绪"))
                )
                .accessibilityIdentifier(
                    "mcp.server.\(accessibilityComponent(server.id)).connection-test"
                )
                .help(
                    server.enabled && authorized
                        ? "握手 + tools/list；不授予工具权限"
                        : (!server.enabled ? "请先启用服务器" : "请先授权服务器")
                )

                Button(role: .destructive) {
                    pendingDeleteServer = server
                } label: {
                    MinisIconView(.delete, state: .danger, size: 16, accessibilityLabel: "删除服务器")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除服务器 \(server.name)")
                .accessibilityIdentifier(
                    "mcp.server.\(accessibilityComponent(server.id)).delete"
                )
                .help("删除服务器")
    }

    private func typeIcon(_ type: MCPTransportType) -> MinisIcon {
        switch type {
        case .stdio: return .terminal
        case .http: return .globe
        }
    }

    /// 传输类型标签色：本地进程用信息色，网络用主题强调色（全 App 只保留一种强调色）。
    private func mcpTypeTagColor(_ type: MCPTransportType) -> Color {
        switch type {
        case .stdio: return theme?.statusInfo ?? AppStatusColor.info
        case .http: return theme?.aj38.accent.swiftUIColor ?? Color.accentColor
        }
    }

    private func runTest(_ server: MCPServer) {
        testingID = server.id
        testResults[server.id] = nil
        Task { @MainActor in
            let result = await center.testMCPServerResult(server)
            guard let result else {
                testingID = nil
                return
            }
            testResults[server.id] = result
            testingID = nil
        }
    }

    private func toolAuthorizationSection(for server: MCPServer) -> some View {
        let expanded = !collapsedToolAuthorizationServerIDs.contains(server.id)
        // Both entry points share the existing snapshot-based, idempotent
        // expansion mutation. Neither discovery nor authorization is invoked.
        let changeExpansion: () -> Void = {
            if expanded {
                collapsedToolAuthorizationServerIDs.insert(server.id)
            } else {
                collapsedToolAuthorizationServerIDs.remove(server.id)
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: changeExpansion) {
                HStack(spacing: 6) {
                    MinisIconView(expanded ? .caretDown : .caretRight, size: 12,
                                  accessibilityLabel: "")
                    Text("工具授权")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, changeExpansion)
            .accessibilityLabel("\(expanded ? "收起" : "展开") \(server.name) 的工具授权")
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier(
                "mcp.server.\(accessibilityComponent(server.id)).tools.disclosure"
            )
            .accessibilityHint("只显示或隐藏工具列表，不改变授权")

            if expanded {
                toolAuthorizationContents(for: server)
            }
        }
        .padding(.leading, 24)
        .accessibilityElement(children: .contain)
    }

    private func toolAuthorizationContents(for server: MCPServer) -> some View {
        // The original discovery function synchronously consumes its existing
        // discoveringToolsID guard before creating its one owned Task.
        let refreshToolsAction: () -> Void = { discoverTools(for: server) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("逐项授权决定哪些已发现工具可以由智能体调用。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: refreshToolsAction) {
                    if discoveringToolsID == server.id {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在刷新工具列表")
                                .accessibilityValue("进行中")
                            Text("刷新工具列表")
                        }
                    } else {
                        Label {
                            Text("刷新工具列表")
                        } icon: {
                            MinisIconView(.refresh, size: 16)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(discoveringToolsID != nil)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, refreshToolsAction)
                .accessibilityLabel("刷新工具列表")
                .accessibilityValue(
                    discoveringToolsID == server.id ? "进行中" : "就绪"
                )
                .accessibilityIdentifier(
                    "mcp.server.\(accessibilityComponent(server.id)).tools.refresh"
                )
                .help("刷新 tools/list：重新读取该 MCP 服务器的工具列表")
            }

            if let error = discoveryErrors[server.id] {
                Label {
                    Text("工具发现失败")
                } icon: {
                    MinisIconView(.close, state: .danger, size: 16)
                }
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme.map { Self.feedbackTextToken(succeeded: false, theme: $0).swiftUIColor } ?? .red)
                    .accessibilityLabel("工具发现失败")
                    .accessibilityValue(error)
                    .accessibilityIdentifier(
                        "mcp.server.\(accessibilityComponent(server.id)).tools.error"
                    )
            }

            let tools = center.mcpManager.cachedTools(serverID: server.id)
            Text("授权和配置改动从你发送下一条消息起生效；改动时正在进行的回复里，还没返回的 MCP 调用会被取消。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).tools.effect-note")
            let narrowed = center.mcpNarrowedToolCount(serverID: server.id)
            if narrowed > 0 {
                Text("\(narrowed) 个工具因定义变化需要重新授权。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme.map { Self.feedbackTextToken(succeeded: false, theme: $0).swiftUIColor } ?? .red)
                    .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).tools.narrowed")
            }
            if !tools.isEmpty {
                HStack(spacing: 12) {
                    Button("全部授权") { setAllTools(server: server, tools: tools, authorized: true) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).tools.authorize-all")
                    Button("全部取消") { setAllTools(server: server, tools: tools, authorized: false) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mcp.server.\(accessibilityComponent(server.id)).tools.revoke-all")
                }
            }
            if tools.isEmpty {
                Text("尚未发现工具")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "mcp.server.\(accessibilityComponent(server.id)).tools.empty"
                    )
            } else {
                ForEach(tools, id: \.name) { tool in
                    let toolName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let accessibleToolName = toolName.isEmpty ? "未命名工具" : toolName
                    Toggle(accessibleToolName, isOn: Binding(
                        get: {
                            center.isMCPToolAuthorized(
                                serverID: server.id,
                                toolName: toolName
                            )
                        },
                        set: { authorized in
                            guard center.setMCPToolAuthorized(
                                serverID: server.id,
                                toolName: toolName,
                                authorized: authorized
                            ) else {
                                lastActionMessage = "工具授权保存失败。"
                                return
                            }
                            lastActionMessage = authorized
                                ? "已授权工具「\(accessibleToolName)」。"
                                : "已撤销工具「\(accessibleToolName)」的授权。"
                        }
                    ))
                    .accessibilityLabel("授权工具 \(accessibleToolName)")
                    .accessibilityValue(
                        center.isMCPToolAuthorized(
                            serverID: server.id,
                            toolName: toolName
                        ) ? "已授权" : "未授权"
                    )
                    .accessibilityIdentifier(
                        "mcp.server.\(accessibilityComponent(server.id)).tool.\(accessibilityComponent(accessibleToolName)).authorization"
                    )
                    .help(tool.description ?? "切换该工具的持久化授权")
                }
            }
        }
    }

    private func setAllTools(server: MCPServer, tools: [MCPTool], authorized: Bool) {
        let names = tools.map(\.name)
        if center.setMCPToolsAuthorized(serverID: server.id, toolNames: names, authorized: authorized) {
            lastActionMessage = authorized ? "已授权「\(server.name)」的全部 \(names.count) 个工具。"
                                           : "已撤销「\(server.name)」的全部工具授权。"
            discoveryRevision &+= 1
        } else {
            lastActionMessage = "工具授权保存失败。"
        }
    }

    private func discoverTools(for server: MCPServer) {
        guard discoveringToolsID == nil else { return }
        discoveringToolsID = server.id
        discoveryErrors[server.id] = nil
        Task { @MainActor in
            let succeeded = await center.discoverMCPTools(for: server, clientFactory: nil) { message in
                discoveryErrors[server.id] = message
                lastActionMessage = message
            }
            if succeeded { discoveryRevision &+= 1 }
            discoveringToolsID = nil
        }
    }

    private func reconnect(_ server: MCPServer) {
        guard reconnectingIDs.insert(server.id).inserted else { return }
        Task { @MainActor in
            do {
                try await center.mcpManager.reconnect(serverID: server.id)
                lastActionMessage = "已重连「\(server.name)」，工具列表已刷新。"
            } catch {
                lastActionMessage = center.isSafetyFeatureEnabled(.mcp)
                    ? "重连「\(server.name)」失败：" + MCPFailureMessage.reconnect(error)
                    : "重连「\(server.name)」失败：MCP 功能已被 Safe Mode/Kill Switch 关闭。"
            }
            reconnectingIDs.remove(server.id)
            center.reloadMCP()
            discoveryRevision &+= 1
        }
    }
    private func runtimeLabel(_ state: MCPClientState) -> String {
        switch state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed: return "连接失败"
        }
    }

    private func accessibilityComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        return trimmed.utf8
            .map { String($0, radix: 16) }
            .joined(separator: "-")
    }

    private func replacementPhaseLabel(_ phase: MCPReplacementSessionState.Phase) -> String {
        switch phase {
        case .active: return "已启用"
        case .disabled: return "已停用"
        case .missing: return "已移除"
        }
    }
}

/// 一次测试连接的结果（UI 展示用）。
enum MCPTestResultStatus: String, Equatable {
    case success = "成功"
    case rejected = "已拒绝"
    case error = "错误"
}

struct MCPTestResult: Equatable {
    let status: MCPTestResultStatus
    let message: String

    var ok: Bool { status == .success }

    var accessibilityValue: String {
        "\(status.rawValue)：\(message)"
    }
}

// MARK: - 新增/编辑表单

/// MCP 服务器新增表单（stdio / http 双模式）。
private struct MCPServerEditSheet: View {
    let onSave: (MCPServerEditDraft) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerEditDraft
    @State private var saveFailed = false
    @Environment(\.typographyTokens) private var typography
    private enum Field: Hashable {
        case id, name, command, args, env, url
        case headerName(MCPHeaderEditRow.ID)
        case headerValue(MCPHeaderEditRow.ID)
    }
    @FocusState private var focusedField: Field?

    init(existing: MCPServer? = nil, onSave: @escaping (MCPServerEditDraft) -> Bool) {
        self.onSave = onSave
        _draft = State(initialValue: MCPServerEditDraft(existing: existing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isEditing ? "编辑 MCP 服务器" : "新增 MCP 服务器")
                .font(typography?.headline ?? .headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("标识（唯一，如 github）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField("github", text: $draft.id)
                    .disabled(draft.isEditing)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .id)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("显示名称").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField("GitHub", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }

            Picker("传输类型", selection: $draft.type) {
                Text("stdio（本地进程）").tag(MCPTransportType.stdio)
                Text("http（远程端点）").tag(MCPTransportType.http)
            }
            .pickerStyle(.segmented)

            if draft.type == .stdio {
                VStack(alignment: .leading, spacing: 4) {
                    Text("命令").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    TextField("npx", text: $draft.command)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .command)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("参数（可用引号保留空格，可留空）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    TextField("-y @modelcontextprotocol/server-github", text: $draft.argsText)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .args)
                }

                if let launch = draft.stdioLaunchFields,
                   !launch.command.isEmpty {
                    Text("可执行文件：\(launch.command)")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    Text("参数：\(launch.args.map { String(reflecting: $0) }.joined(separator: " "))")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
                if draft.stdioLaunchFields == nil && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("请检查引号和转义。若绝对路径含空格，请用引号包住可执行文件路径。")
                        .modifier(ReadableStatusForeground(status: .danger))
                }
                Text("可粘贴完整命令。绝对路径含空格且后接参数时，请用引号包住路径。找不到命令时，请填写绝对路径或设置 PATH。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.isEditing ? "新增或替换环境变量（每行一个，留空保留原配置）" : "环境变量（每行一个 KEY=VALUE，可留空）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.envText)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                        .focused($focusedField, equals: .env)
                        .accessibilityIdentifier("mcp.server.edit.env")
                    Text("除安全基础运行变量外，仅这里列出的变量会传给该服务器；不会继承 App 中的 Provider 密钥。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    TextField("https://mcp.example.com/mcp", text: $draft.url)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .url)
                }
            }

            if draft.type == .http {
                VStack(alignment: .leading, spacing: 6) {
                    Text("请求头（值保存在钥匙串；留空保留已有值）")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    ForEach($draft.headerRows) { $row in
                        HStack {
                            TextField("如 Authorization", text: $row.name).textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .headerName(row.id))
                            SecureField("如 Bearer token", text: $row.value).textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .headerValue(row.id))
                            Button("移除") { draft.headerRows.removeAll { $0.id == row.id } }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("添加请求头") { draft.headerRows.append(MCPHeaderEditRow(name: "")) }
                        .buttonStyle(.borderless)
                    Text("优先使用 HTTP；初始化协议不兼容时尝试 SSE。")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("工具调用超时（秒，留空为 600）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField("600", text: $draft.callTimeoutText)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("mcp.server.edit.call-timeout")
            }

            Toggle("启用（供智能体调用）", isOn: $draft.enabled)

            if let problem = draft.problem {
                Text(problem)
                    .modifier(ReadableStatusForeground(status: .danger))
                    .accessibilityIdentifier("mcp.server.edit.problem")
            }

            if saveFailed {
                Text("保存失败，草稿已保留；配置可能已变化，请核对后重试。")
                    .modifier(ReadableStatusForeground(status: .danger))
                    .accessibilityIdentifier("mcp.server.edit.save-error")
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if onSave(draft) { dismiss() } else { saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedField = draft.isEditing ? .name : .id
            }
        }
    }

}

// MARK: - 从 JSON 导入

private struct MCPJSONImportSheet: View {
    let existingIDs: Set<String>
    let onImport: ([MCPServer]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var text = ""

    var body: some View {
        let preview = MCPServerJSONImport.preview(text, existingIDs: existingIDs)
        let importable = preview.importableServers
        VStack(alignment: .leading, spacing: 12) {
            Text("从 JSON 导入 MCP 服务器").font(typography?.headline ?? .headline)
            Text("粘贴 Claude Code 或 Claude Desktop 的配置，例如 {\"mcpServers\": {…}}，也可以只粘贴单个服务器对象。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                .accessibilityIdentifier("mcp.import.text")
            if let error = preview.parseError {
                Text(error).modifier(ReadableStatusForeground(status: .danger))
            }
            if !preview.entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.sourceName).fontWeight(.medium)
                                if !entry.summary.isEmpty {
                                    Text(entry.summary)
                                        .font(typography?.caption2 ?? .caption2).foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                if let note = entry.note {
                                    if entry.server == nil {
                                        Text(note).font(typography?.caption ?? .caption)
                                            .modifier(ReadableStatusForeground(status: .danger))
                                    } else {
                                        Text(note).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            Text("导入后的服务器默认未授权，需在列表中逐个授权后才会被智能体调用；环境变量和请求头里的密钥保存在钥匙串。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入 \(importable.count) 个") {
                    onImport(importable)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importable.isEmpty)
                .accessibilityIdentifier("mcp.import.confirm")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Preview

#Preview {
    MCPManagerView(center: SettingsCenter(
        settingsStore: SettingsStore(directory: FileManager.default.temporaryDirectory),
        envStore: EnvVarStore(directory: FileManager.default.temporaryDirectory),
        memoryStore: MemoryStore(directory: FileManager.default.temporaryDirectory),
        sessionStore: SessionStore(directory: FileManager.default.temporaryDirectory),
        logManager: LogManager(directory: FileManager.default.temporaryDirectory, ringCapacity: 50),
        mcpManager: MCPServerManager(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("mcps-preview.json"))
    ))
}
