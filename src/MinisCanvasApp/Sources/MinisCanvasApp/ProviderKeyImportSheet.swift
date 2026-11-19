import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore

/// 导入供应商 Key：识别常见环境变量，或让用户用文件选择框指定 Claude Code 的 settings.json、
/// Codex 的 auth.json。由 App 自己读取（不走智能体工具），只提取 API Key 和 Base URL，
/// 不导入 OAuth 令牌；Key 只以掩码显示，确认后写入钥匙串。
struct ProviderKeyImportSheet: View {
    @Environment(\.themeTokens) private var theme
    let center: SettingsCenter
    let onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var candidates: [ImportedProviderCredential]
    @State private var selection: Set<String>
    @State private var message: String?
    /// 所选项里有 http 公网地址时，第一次点“导入所选”只提示风险，第二次才真正导入。
    @State private var plainHTTPAcknowledged = false

    private var plainHTTPCandidates: [ImportedProviderCredential] {
        candidates.filter {
            selection.contains($0.id)
                && $0.baseURL.map(ProviderEndpointPolicy.isPlainHTTPToPublicHost) == true
        }
    }

    init(center: SettingsCenter, onFinished: @escaping (String) -> Void) {
        self.center = center
        self.onFinished = onFinished
        let found = ProviderKeyImport.fromEnvironment(ProcessInfo.processInfo.environment)
        _candidates = State(initialValue: found)
        _selection = State(initialValue: Set(found.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入 Key").font(typography?.headline ?? .headline)
            Text("只提取 API Key 和 Base URL，不导入登录令牌；Key 只显示掩码，确认后保存到钥匙串。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("选择 Claude Code 配置…") { pickFile(kind: .claudeCode) }
                    .accessibilityIdentifier("settings.provider.import.claude-code")
                Button("选择 Codex 配置…") { pickFile(kind: .codex) }
                    .accessibilityIdentifier("settings.provider.import.codex")
            }
            Text("Claude Code：~/.claude/settings.json；Codex：~/.codex/auth.json。从 Finder 启动的 App 读不到终端里的环境变量，可改用上面的文件。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text("没有发现可导入的 Key。")
                    .font(typography?.caption ?? .caption)
                    .accessibilityIdentifier("settings.provider.import.empty")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { candidate in
                            Toggle(isOn: Binding(
                                get: { selection.contains(candidate.id) },
                                set: { isOn in
                                    if isOn { selection.insert(candidate.id) } else { selection.remove(candidate.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(candidate.displayName)（\(candidate.credentialName)）")
                                    Text("\(candidate.sourceLabel) · \(candidate.maskedKey)"
                                         + (candidate.baseURL.map { " · \($0)" } ?? ""))
                                        .font(typography?.caption ?? .caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("settings.provider.import.item.\(candidate.id)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if !plainHTTPCandidates.isEmpty {
                Text("有 \(plainHTTPCandidates.count) 项的地址使用 http，Key 会在网络上明文传输，有被截获的风险；仅在你信任该网络和服务时导入。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.provider.import.plainHTTP")
            }

            if let message {
                Text(message)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.provider.import.message")
            }

            HStack {
                Spacer()
                Button("取消") {
                    candidates = []
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(plainHTTPCandidates.isEmpty || plainHTTPAcknowledged ? "导入所选" : "确认风险并导入") {
                    if !plainHTTPCandidates.isEmpty, !plainHTTPAcknowledged {
                        plainHTTPAcknowledged = true
                        message = "已提示明文传输风险，再点一次“导入所选”才会导入。"
                        return
                    }
                    importSelected()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || candidates.isEmpty)
                    .accessibilityIdentifier("settings.provider.import.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460)
        .task { await mergeLoginShellEnvironment() }
    }

    /// 从 Finder 启动的 App 读不到 .zshrc 里 export 的 Key：后台取登录 shell 快照（只取已知变量名），
    /// 与 App 进程环境合并，同名以登录 shell 为准。取不到（超时、失败）就保持原样，仍可用上面的文件选择。
    private func mergeLoginShellEnvironment() async {
        let login = await ModelShellEnvironment.loginShellValues(named: ProviderKeyImport.environmentVariableNames)
        guard !login.isEmpty else { return }
        let merged = ProviderKeyImport.mergedEnvironment(
            process: ProcessInfo.processInfo.environment, loginShell: login)
        for item in ProviderKeyImport.fromEnvironment(merged) {
            if let existing = candidates.first(where: { $0.id == item.id }), existing.apiKey == item.apiKey { continue }
            candidates.removeAll { $0.id == item.id }
            candidates.append(item)
            selection.insert(item.id)
        }
    }

    private enum FileKind { case claudeCode, codex }

    private func pickFile(kind: FileKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = kind == .codex
            ? [.json, UTType(filenameExtension: "toml") ?? .plainText] : [.json]
        let home = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = home.appendingPathComponent(kind == .claudeCode ? ".claude" : ".codex", isDirectory: true)
        panel.message = kind == .claudeCode
            ? "选择 Claude Code 的 settings.json"
            : "选择 Codex 的 auth.json；用第三方网关时再选一次 config.toml，以读取它的服务地址"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: url) else {
            message = "无法读取所选文件，或文件过大。"
            return
        }
        if kind == .codex, url.pathExtension.lowercased() == "toml" {
            // config.toml 只读当前 model_provider 的 base_url，用来改写已读取的 Codex Key 的发送地址；
            // 地址会显示在列表里，http 明文仍走风险确认，确认前不发任何请求。
            guard let existing = candidates.first(where: { $0.id == "codex:OPENAI_API_KEY" }) else {
                message = "请先选择 Codex 的 auth.json，再选 config.toml。"
                return
            }
            guard let gateway = ProviderKeyImport.codexBaseURL(fromConfigTOML: data) else {
                message = "config.toml 里没有自定义服务地址，将使用 OpenAI 官方地址。"
                return
            }
            guard ProviderKeyImport.codexOpenAIKeyMayBind(toBaseURL: gateway) else {
                message = "config.toml 的服务地址 \(gateway) 不是 OpenAI 官方地址，它使用自己的 Key，"
                    + "auth.json 里的 OpenAI Key 不会发往该地址。请到供应商设置里添加这个地址并填写它的 Key。"
                return
            }
            candidates.removeAll { $0.id == existing.id }
            candidates.append(ImportedProviderCredential(
                id: existing.id, sourceLabel: existing.sourceLabel + " + config.toml 地址",
                credentialName: existing.credentialName, displayName: existing.displayName,
                baseURL: gateway, protocolType: existing.protocolType,
                modelNames: existing.modelNames, apiKey: existing.apiKey))
            plainHTTPAcknowledged = false
            message = "已读取服务地址 \(gateway)，请核对后再导入。"
            return
        }
        let found = kind == .claudeCode
            ? ProviderKeyImport.fromClaudeCodeSettings(data: data)
            : ProviderKeyImport.fromCodexAuth(data: data)
        guard !found.isEmpty else {
            message = "所选文件里没有可导入的 API Key（登录令牌不会导入）。"
            return
        }
        for item in found {
            candidates.removeAll { $0.id == item.id }
            candidates.append(item)
            selection.insert(item.id)
        }
        message = "已读取 \(found.count) 项。"
    }

    private func importSelected() {
        var imported = 0
        var skipped: [String] = []
        for candidate in candidates where selection.contains(candidate.id) {
            guard !center.providerExists(named: candidate.credentialName) else {
                skipped.append("\(candidate.displayName)（已存在同名供应商）")
                continue
            }
            if center.saveProvider(
                name: candidate.credentialName,
                credential: .replace(candidate.apiKey),
                baseURL: candidate.baseURL,
                modelNames: candidate.modelNames,
                protocolType: candidate.protocolType,
                displayName: candidate.displayName
            ) {
                imported += 1
                _ = center.startProviderReadinessAfterSave(forProviderName: candidate.credentialName)
            } else {
                skipped.append("\(candidate.displayName)（保存失败）")
            }
        }
        // 导入完成后不再在内存里保留明文 Key。
        candidates = []
        selection = []
        var summary = "已导入 \(imported) 个供应商，正在检查连接。"
        if !skipped.isEmpty { summary += " 未导入：" + skipped.joined(separator: "、") + "。" }
        if imported > 0 { summary += " 模型名为空的供应商请在编辑表单里用“获取模型列表”选择。" }
        onFinished(summary)
        dismiss()
    }
}
