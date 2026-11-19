import SwiftUI
import MinisCore

/// 规则管理面板（对齐 Claude Code 的 /permissions）用到的当前会话信息。
/// 由根视图从当前会话取，面板自己不持有任何权限状态；规则都存在 `PersistentApprovalRuleStore`。
struct PermissionRulesPanelContext {
    var facts: ComposerPolicyFactSource?
    var workingDirectory: String?
    var sessionID: String?

    init(facts: ComposerPolicyFactSource? = nil, workingDirectory: String? = nil, sessionID: String? = nil) {
        self.facts = facts
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
    }

    /// 本项目规则对应的项目目录；没有项目会话时为 nil。
    var projectRoot: String? {
        facts?.trustedProjectRoot ?? workingDirectory ?? facts?.allowedWriteRoots.first
    }

    var core: PermissionRuleContext {
        let roots = facts?.allowedWriteRoots ?? []
        return PermissionRuleContext(
            trustedProjectRoot: projectRoot,
            allowedRoots: roots.isEmpty ? [workingDirectory].compactMap { $0 } : roots)
    }
}

@MainActor
@Observable
final class PermissionRulesPanelModel {
    enum ScopeChoice: String, CaseIterable, Identifiable {
        case session, project, global
        var id: String { rawValue }
        var label: String {
            switch self {
            case .session: "本会话"
            case .project: "本项目"
            case .global: "全局"
            }
        }
    }

    let store: PersistentApprovalRuleStore
    var contextProvider: @MainActor () -> PermissionRulesPanelContext

    private(set) var entries: [PersistentApprovalRuleEntry] = []
    private(set) var diagnostics: [String] = []
    var feedback: String?

    // 新增 / 编辑表单
    var isEditorPresented = false
    private(set) var editingID: String?
    var draftBehavior: PersistentApprovalRuleBehavior = .allow
    var draftType: PermissionRuleType = .shellPrefix
    var draftPattern = ""
    var draftScope: ScopeChoice = .project

    // 导入
    var isImportPresented = false
    private(set) var importPreview: ImportedPermissionPreview?
    var importSelection: Set<String> = []
    var importFeedback: String?

    init(store: PersistentApprovalRuleStore, contextProvider: @escaping @MainActor () -> PermissionRulesPanelContext) {
        self.store = store
        self.contextProvider = contextProvider
        reload()
    }

    func reload() {
        entries = store.entries(sessionID: contextProvider().sessionID)
            .sorted { $0.rule.createdAt > $1.rule.createdAt }
        diagnostics = store.diagnostics()
    }

    // MARK: 增删改

    func beginAdd(behavior: PersistentApprovalRuleBehavior = .allow) {
        editingID = nil
        draftBehavior = behavior
        draftType = .shellPrefix
        draftPattern = ""
        draftScope = .project
        feedback = nil
        isEditorPresented = true
    }

    func beginEdit(_ entry: PersistentApprovalRuleEntry) {
        guard let parsed = Self.draftFields(of: entry.rule) else { return }
        editingID = entry.rule.id
        draftBehavior = entry.rule.behavior
        draftType = parsed.type
        draftPattern = parsed.pattern
        switch entry.scope {
        case .session: draftScope = .session
        case .project: draftScope = .project
        case .global: draftScope = .global
        }
        feedback = nil
        isEditorPresented = true
    }

    /// 保存表单；校验不通过时留在表单里并给出原因（`feedback`），原规则不变。
    @discardableResult
    func saveDraft() -> Bool {
        let context = contextProvider()
        let scope: PersistentApprovalRuleScope
        switch draftScope {
        case .global: scope = .global
        case .project: scope = .project
        case .session:
            guard let sessionID = context.sessionID else {
                feedback = "当前没有打开的会话，不能保存为“本会话”规则。"
                return false
            }
            scope = .session(sessionID)
        }
        if draftBehavior == .allow, draftType == .mcpTool {
            feedback = "MCP 允许规则在审批卡上创建：该 MCP 工具弹卡时选“以后都允许”。这里只能添加拒绝或每次询问规则。"
            return false
        }
        let draft = PermissionRuleDraft(behavior: draftBehavior, type: draftType, pattern: draftPattern, scope: scope)
        let result: Result<PersistentApprovalRule, PermissionRuleRejection>
        if let editingID {
            result = store.editRule(id: editingID, draft: draft, context: context.core)
        } else {
            result = store.addManualRule(draft: draft, context: context.core)
        }
        switch result {
        case .success:
            feedback = nil
            isEditorPresented = false
            reload()
            return true
        case .failure(let rejection):
            feedback = rejection.reason
            return false
        }
    }

    func remove(_ id: String) {
        let removed = store.remove(id: id)
        reload()
        feedback = removed ? nil : "撤销失败：规则没有写入磁盘，这条规则仍然有效。请稍后重试。"
    }

    func clearAll() {
        let removed = store.removeAll()
        reload()
        feedback = removed ? nil : "清除失败：规则没有写入磁盘，规则仍然有效。请稍后重试。"
    }

    // MARK: 导入 .claude/settings.json

    func prepareImport() {
        let context = contextProvider()
        importFeedback = nil
        guard let root = context.projectRoot else {
            importPreview = ImportedPermissionPreview()
            importFeedback = "当前没有项目目录，无法定位 .claude/settings.json。请先打开一个项目会话。"
            importSelection = []
            isImportPresented = true
            return
        }
        let preview = ClaudeSettingsPermissionsImporter.preview(projectRoot: root, context: context.core)
        importPreview = preview
        // 拒绝、询问规则默认勾选；允许规则来自项目文件（可能不是你写的），默认不勾选，需要你逐条确认。
        importSelection = Set(preview.candidates.filter { $0.draft.behavior != .allow }.map(\.id))
        isImportPresented = true
    }

    func confirmImport() {
        guard let preview = importPreview else { return }
        let chosen = preview.candidates.filter { importSelection.contains($0.id) }
        guard !chosen.isEmpty else {
            importFeedback = "没有勾选任何规则。"
            return
        }
        let result = store.importRules(chosen, context: contextProvider().core)
        reload()
        if result.failed.isEmpty {
            importFeedback = nil
            isImportPresented = false
            feedback = "已导入 \(result.saved.count) 条规则。"
        } else {
            importFeedback = "已导入 \(result.saved.count) 条，\(result.failed.count) 条未通过检查：\n"
                + result.failed.map { "\($0.original)：\($0.reason)" }.joined(separator: "\n")
        }
    }

    // MARK: 显示

    static func isEditable(_ rule: PersistentApprovalRule) -> Bool { draftFields(of: rule) != nil }

    /// 规则 → 表单字段。技能规则、会话目标规则、带服务器指纹的 MCP 允许规则只能删除。
    static func draftFields(of rule: PersistentApprovalRule) -> (type: PermissionRuleType, pattern: String)? {
        switch rule.kind {
        case .shellCommandPrefix: return (.shellPrefix, rule.pattern)
        case .webHost: return (.webHost, rule.pattern)
        case .mcpTool: return rule.behavior == .allow ? nil : (.mcpTool, rule.pattern)
        case .sessionTarget: return nil
        case .projectDirectory:
            if rule.capability == "web_search" { return (.webSearch, "") }
            if rule.capability == "file_read" { return (.readDirectory, rule.pattern) }
            if rule.capability == "file_write" { return (.writePath, rule.pattern) }
            // "仅编辑"规则表单里没有对应类型，编辑后会升格成"允许写入"（权限放大），所以只允许删除。
            return nil
        }
    }

    static func behaviorLabel(_ behavior: PersistentApprovalRuleBehavior) -> String {
        switch behavior {
        case .allow: "允许"
        case .deny: "拒绝"
        case .ask: "每次询问"
        }
    }

    static func typeLabel(_ type: PermissionRuleType) -> String {
        switch type {
        case .shellPrefix: "命令前缀"
        case .readDirectory: "读取目录"
        case .writePath: "写入路径"
        case .webHost: "网站域名"
        case .mcpTool: "MCP 工具"
        case .webSearch: "联网搜索"
        }
    }

    static func scopeLabel(_ scope: PersistentApprovalRuleScope) -> String {
        switch scope {
        case .session: "本会话"
        case .project: "本项目"
        case .global: "全局"
        }
    }

    static func originLabel(_ origin: PersistentApprovalRuleOrigin) -> String {
        switch origin {
        case .approvalCard: "审批卡"
        case .manual: "手动添加"
        case .imported: "导入"
        }
    }

    static func patternHint(_ type: PermissionRuleType, behavior: PersistentApprovalRuleBehavior) -> String {
        switch type {
        case .shellPrefix: "命令前缀，如 npm test、git push（拒绝和询问规则对复合命令的每一段都检查）"
        case .readDirectory: behavior == .allow ? "目录的绝对路径，如 ~/Documents/资料" : "路径或通配，如 ~/.ssh、/项目/**/.env"
        case .writePath: behavior == .allow ? "项目内的目录或文件路径" : "路径或通配，如 /项目/src/**"
        case .webHost: "域名，如 example.com（拒绝和询问规则同时覆盖子域名）"
        case .mcpTool: "mcp__服务器__工具；写 mcp__服务器 表示该服务器全部工具（仅拒绝、询问）"
        case .webSearch: "不需要填写，对联网搜索整体生效"
        }
    }

    static func timeText(_ date: Date?) -> String {
        guard let date else { return "从未" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 视图

struct PermissionRuleEditorSheet: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var model: PermissionRulesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.editingID == nil ? "新增规则" : "编辑规则").font(.headline)
            Picker("类别", selection: $model.draftBehavior) {
                ForEach([PersistentApprovalRuleBehavior.allow, .deny, .ask], id: \.self) {
                    Text(PermissionRulesPanelModel.behaviorLabel($0)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("approval.rules.editor.behavior")
            Picker("类型", selection: $model.draftType) {
                ForEach(PermissionRuleType.allCases.filter { model.draftBehavior != .allow || $0 != .mcpTool }, id: \.self) {
                    Text(PermissionRulesPanelModel.typeLabel($0)).tag($0)
                }
            }
            .onChange(of: model.draftBehavior) { _, behavior in
                if behavior == .allow, model.draftType == .mcpTool { model.draftType = .shellPrefix }
            }
            .accessibilityIdentifier("approval.rules.editor.type")
            if model.draftType != .webSearch {
                TextField("内容", text: $model.draftPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("approval.rules.editor.pattern")
            }
            Text(PermissionRulesPanelModel.patternHint(model.draftType, behavior: model.draftBehavior))
                .font(.caption).foregroundStyle(.secondary)
            Picker("范围", selection: $model.draftScope) {
                ForEach(PermissionRulesPanelModel.ScopeChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("approval.rules.editor.scope")
            if model.draftBehavior == .allow {
                Text("允许规则沿用审批卡的安全底线：敏感文件、构建配置、.git/.claude、不可逆删除等不能被允许规则免问；不通过时会说明原因。会执行项目脚本的命令（npm run、make、python 等）只能设为本项目或本会话。MCP 允许规则在审批卡上创建。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.draftBehavior == .deny {
                Text("拒绝：命中后直接拒绝，不弹卡，所有权限模式（包括绕过权限）都生效。读写拒绝规则只拦文件工具直接访问该路径，不拦命令行（shell），也不拦以上级目录为搜索范围的搜索。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("每次询问：命中后一定弹卡（绕过权限除外），卡上不提供“以后都允许”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = model.feedback {
                Text(feedback).font(.caption).foregroundStyle(theme?.statusDangerText ?? AppStatusColor.danger)
                    .accessibilityIdentifier("approval.rules.editor.feedback")
            }
            HStack {
                Spacer()
                Button("取消") { model.isEditorPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("approval.rules.editor.save")
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}

struct PermissionRulesImportSheet: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var model: PermissionRulesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入 Claude Code 权限设置").font(.headline)
            Text("读取项目 .claude/settings.json 和 settings.local.json 里的 permissions.allow / deny / ask（不读用户级 ~/.claude/settings.json）。请逐条确认，点“导入所选”之前不会生效。")
                .font(.caption).foregroundStyle(.secondary)
            if model.importPreview?.candidates.contains(where: { $0.draft.behavior == .allow }) == true {
                Text("允许规则会让这些操作免问，只导入你信任的项目里的规则。允许规则默认没有勾选，请逐条确认。")
                    .font(.caption).foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
            }
            if let preview = model.importPreview {
                if let note = preview.note {
                    Text(note).font(.caption)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview.candidates) { candidate in
                            Toggle(isOn: Binding(
                                get: { model.importSelection.contains(candidate.id) },
                                set: { on in
                                    if on { model.importSelection.insert(candidate.id) }
                                    else { model.importSelection.remove(candidate.id) }
                                })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(PermissionRulesPanelModel.behaviorLabel(candidate.draft.behavior))：\(candidate.original)")
                                        .font(.system(.body, design: .monospaced))
                                    Text("→ \(PermissionRulesPanelModel.typeLabel(candidate.draft.type)) \(candidate.draft.pattern)（\(candidate.source)）")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("approval.rules.import.candidate")
                        }
                        if !preview.skipped.isEmpty {
                            Text("无法导入，已跳过").font(.subheadline).padding(.top, 6)
                            ForEach(preview.skipped) { skip in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skip.original).font(.system(.caption, design: .monospaced))
                                    Text("\(skip.reason)（\(skip.source)）").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 360)
            }
            if let feedback = model.importFeedback {
                Text(feedback).font(.caption).foregroundStyle(theme?.statusDangerText ?? AppStatusColor.danger)
                    .accessibilityIdentifier("approval.rules.import.feedback")
            }
            HStack {
                Spacer()
                Button("关闭") { model.isImportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("导入所选") { model.confirmImport() }
                    .disabled(model.importSelection.isEmpty)
                    .accessibilityIdentifier("approval.rules.import.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}
