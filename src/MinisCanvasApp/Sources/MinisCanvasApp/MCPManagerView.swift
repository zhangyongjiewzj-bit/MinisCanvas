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
    @State private var expandedToolAuthorizationServerIDs: Set<String> = []
    @State private var oauthStates: [String: MCPOAuthState] = [:]
    @State private var oauthClientIDs: [String: String] = [:]
    @State private var oauthLoginIDs: Set<String> = []
    @State private var oauthBrowser: MCPWebAuthentication?
    @State private var oauthLoginTask: Task<Void, Never>?



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

    var body: some View {
        GeometryReader { geometry in
            let resolvedWidthClass = widthClass ?? AdaptiveLayoutPolicy.widthClass(for: geometry.size.width)
            VStack(spacing: 0) {
                header

                Divider()

                let trashedServers = center.mcpManager.trashedServers()
                if center.mcpServers.isEmpty && trashedServers.isEmpty {
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
                }
            }
            Button("取消", role: .cancel) {}
        } message: { server in
            Text("将「\(server.name)」移入回收区。恢复配置后需要重新授权。")
        }
        .task { center.reloadMCP() }
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
            : "保存失败：配置已变化或写入失败，请核对后重试。"
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
                    .background(Capsule().fill(server.type == .stdio ? .blue.opacity(0.15) : .purple.opacity(0.15)))
                    .foregroundStyle(server.type == .stdio ? .blue : .purple)
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
        let expanded = expandedToolAuthorizationServerIDs.contains(server.id)
        // Both entry points share the existing snapshot-based, idempotent
        // expansion mutation. Neither discovery nor authorization is invoked.
        let changeExpansion: () -> Void = {
            if expanded {
                expandedToolAuthorizationServerIDs.remove(server.id)
            } else {
                expandedToolAuthorizationServerIDs.insert(server.id)
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
            } catch { lastActionMessage = "重连「\(server.name)」失败，请检查配置后重试。" }
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
                    Text(draft.isEditing ? "新增或替换环境变量（留空保留原配置）" : "环境变量（KEY=VALUE，逗号分隔，可留空）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    TextField("API_KEY=xxx, DEBUG=1", text: $draft.envText)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .env)
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

            Toggle("启用（供智能体调用）", isOn: $draft.enabled)

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
