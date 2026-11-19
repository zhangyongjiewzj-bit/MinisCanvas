import SwiftUI
import MinisCore

/// 设置「技能」页里的“外部技能”分区：列出 ~/.claude/skills、项目 .claude/skills、~/.agents/skills
/// 里的技能（只读、按磁盘内容实时读取）。首次出现和内容变化后须在这里查看并确认，
/// 才会提供给模型；它们不进入 App 自己的已验证技能集合。
struct ExternalSkillsSection: View {
    @Environment(\.themeTokens) private var theme
    let chat: ChatStore
    @Environment(\.typographyTokens) private var typography
    @State private var skills: [ExternalSkill] = []
    @State private var reviewing: ExternalSkill?
    @State private var message: String?
    @State private var showsBatchReview = false
    /// 技能数超过每个根 500 个的上限、后面的没有读到的根。
    @State private var truncatedRoots: [ExternalSkill.Root] = []

    var body: some View {
        DisclosureGroup("外部技能（\(skills.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("读取其他工具放在磁盘上的技能：改了 SKILL.md 立即按新内容生效，不用重新导入；首次出现和内容变化后须确认一次才会提供给模型。它们只读，不属于 App 已验证的技能。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Button("重新扫描") { refresh() }
                    .accessibilityIdentifier("settings.skills.external.refresh")
                let pending = skills.filter { $0.status != .confirmed }
                if pending.count > 1 {
                    Button("批量确认待确认的 \(pending.count) 项…") { showsBatchReview = true }
                        .accessibilityIdentifier("settings.skills.external.batch-review")
                }
                if skills.isEmpty {
                    Text("没有发现外部技能。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(skills) { skill in
                    row(skill)
                }
                if !truncatedRoots.isEmpty {
                    Text("\(truncatedRoots.map(\.displayName).joined(separator: "、")) 里的技能超过 \(ExternalSkillCatalog.maximumSkillsPerRoot) 个，多出的没有列出。请把不用的技能移走后重新扫描。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                }
                if skills.filter({ $0.status == .confirmed }).count > ExternalSkillCatalog.maximumInjectedSkills {
                    Text("已确认的技能超过 \(ExternalSkillCatalog.maximumInjectedSkills) 个，每次对话只会向模型列出前 \(ExternalSkillCatalog.maximumInjectedSkills) 个。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                }
                if let message {
                    Text(message)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .onAppear { refresh() }
        .sheet(item: $reviewing) { skill in
            reviewSheet(skill)
        }
        .sheet(isPresented: $showsBatchReview) {
            batchReviewSheet(skills.filter { $0.status != .confirmed })
        }
    }

    /// 批量确认：逐项列出名称和路径，一次确认；每一项仍按当前磁盘内容的哈希确认。
    @ViewBuilder
    private func batchReviewSheet(_ pending: [ExternalSkill]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("批量确认 \(pending.count) 个外部技能").font(.title3)
            Text("确认后，这些技能的内容会作为参考提供给模型，不授予任何额外权限；磁盘上再改动就需要重新确认。确认前请逐项看过名称和来源，需要看正文的请取消后单独查看。")
                .font(.caption)
            List(pending) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name + (skill.status == .changedSinceConfirmation ? "（内容已变化）" : ""))
                        .fontWeight(.medium)
                    Text("\(skill.root.displayName) · \(skill.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(minHeight: 200, maxHeight: 320)
            HStack {
                Button("取消") { showsBatchReview = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认这 \(pending.count) 项") { confirmAll(pending) }
                    .accessibilityIdentifier("settings.skills.external.batch-confirm")
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func confirmAll(_ pending: [ExternalSkill]) {
        defer { showsBatchReview = false; refresh() }
        var confirmed = 0
        var failed: [String] = []
        for skill in pending {
            do {
                try chat.externalSkillCatalog?.confirm(skill, projectRoot: chat.activeTrustedProjectRoot)
                confirmed += 1
            } catch {
                failed.append(skill.name)
            }
        }
        message = failed.isEmpty
            ? "已确认 \(confirmed) 项。"
            : "已确认 \(confirmed) 项；\(failed.count) 项没有确认（内容在查看后变了或没能保存）：\(failed.joined(separator: "、"))。请重新查看后再确认。"
    }

    /// 扫描放到后台线程，不卡界面；结果回到主线程后再更新列表。
    private func refresh() {
        guard let catalog = chat.externalSkillCatalog else {
            skills = []
            truncatedRoots = []
            return
        }
        let root = chat.activeTrustedProjectRoot
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                catalog.scanReport(projectRoot: root)
            }.value
            skills = result.skills
            truncatedRoots = result.truncatedRoots
        }
    }

    @ViewBuilder
    private func row(_ skill: ExternalSkill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(skill.name).fontWeight(.medium)
                Text(skill.status.label)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(skill.status == .confirmed ? Color.secondary : (theme?.statusWarningText ?? AppStatusColor.warning))
                Spacer()
                switch skill.status {
                case .confirmed:
                    Button("撤销确认") { revoke(skill) }
                        .accessibilityIdentifier("settings.skills.external.revoke.\(skill.id)")
                case .needsConfirmation, .changedSinceConfirmation:
                    Button(skill.status == .needsConfirmation ? "查看并确认…" : "查看变化并重新确认…") {
                        reviewing = skill
                    }
                    .accessibilityIdentifier("settings.skills.external.review.\(skill.id)")
                }
            }
            Text("\(skill.root.displayName) · \(skill.path)")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func reviewSheet(_ skill: ExternalSkill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("确认外部技能：\(skill.name)").font(.title3)
            Text("来源：\(skill.path)\n内容指纹：\(String(skill.contentHash.prefix(16)))…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("确认后，这份内容会作为参考提供给模型，不授予任何额外权限；磁盘上再改动就需要重新确认。")
                .font(.caption)
            ScrollView {
                Text(skill.body.count > 8000 ? String(skill.body.prefix(8000)) + "\n…（只显示前 8000 字）" : skill.body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 320)
            HStack {
                Button("取消") { reviewing = nil }
                Spacer()
                Button("我看过了，确认") { confirm(skill) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.skills.external.confirm")
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func confirm(_ skill: ExternalSkill) {
        defer { reviewing = nil; refresh() }
        do {
            try chat.externalSkillCatalog?.confirm(skill, projectRoot: chat.activeTrustedProjectRoot)
            message = "已确认：\(skill.name)"
        } catch ExternalSkillCatalog.ConfirmationError.contentChanged {
            message = "确认失败：技能内容在你查看之后又变了，请重新查看。"
        } catch {
            message = "确认没有保存，请检查磁盘空间后重试。"
        }
    }

    private func revoke(_ skill: ExternalSkill) {
        do {
            try chat.externalSkillCatalog?.revoke(id: skill.id)
            message = "已撤销：\(skill.name)"
        } catch {
            message = "撤销没有保存，请检查磁盘空间后重试。"
        }
        refresh()
    }
}

/// 设置「技能」页里的“项目子智能体”分区：当前项目 .claude/agents 里的子智能体。
/// 首次出现和文件内容变化后须在这里查看并确认，才能被派发使用（用户级 ~/.claude/agents 不需要确认）。
struct ProjectSubagentsSection: View {
    @Environment(\.themeTokens) private var theme
    let chat: ChatStore
    @Environment(\.typographyTokens) private var typography
    @State private var agents: [CustomSubagentDefinition] = []
    @State private var reviewing: CustomSubagentDefinition?
    @State private var message: String?

    var body: some View {
        DisclosureGroup("项目子智能体（\(agents.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("当前项目 .claude/agents 里的自定义子智能体。文件是项目里的内容，首次出现和内容变化后须确认一次才能使用；未确认时派发会被拒绝。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Button("重新扫描") { refresh() }
                if chat.activeTrustedProjectRoot == nil {
                    Text("当前会话没有已信任的项目目录。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                } else if agents.isEmpty {
                    Text("没有发现项目子智能体。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(agents, id: \.filePath) { agent in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(agent.name).fontWeight(.medium)
                            Text(statusLabel(agent.confirmation))
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(agent.confirmation == .confirmed ? Color.secondary : (theme?.statusWarningText ?? AppStatusColor.warning))
                            Spacer()
                            if agent.confirmation == .confirmed {
                                Button("撤销确认") { revoke(agent) }
                            } else {
                                Button(agent.confirmation == .needsConfirmation ? "查看并确认…" : "查看变化并重新确认…") {
                                    reviewing = agent
                                }
                            }
                        }
                        Text(agent.filePath)
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let message {
                    Text(message)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .onAppear { refresh() }
        .sheet(item: $reviewing) { agent in
            reviewSheet(agent)
        }
    }

    private func statusLabel(_ status: CustomSubagentDefinition.Confirmation) -> String {
        switch status {
        case .confirmed: "已确认"
        case .needsConfirmation: "待确认"
        case .changedSinceConfirmation: "内容已变化，需重新确认"
        }
    }

    /// 扫描放到后台线程；结果回到主线程后再更新列表。
    private func refresh() {
        guard let store = chat.customSubagentConfirmations, let root = chat.activeTrustedProjectRoot else {
            agents = []
            return
        }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                CustomSubagentLoader.load(projectRoot: root, confirmations: store).filter { $0.source == .project }
            }.value
            agents = loaded
        }
    }

    @ViewBuilder
    private func reviewSheet(_ agent: CustomSubagentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("确认项目子智能体：\(agent.name)").font(.title3)
            Text("来源：\(agent.filePath)\n内容指纹：\(String(agent.contentHash.prefix(16)))…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("确认后，这份角色设定会在你让模型派发这个子智能体时使用；它只能收窄工具范围，审批和授权仍沿用父会话。文件再改动就需要重新确认。")
                .font(.caption)
            if let tools = agent.toolNames {
                Text("工具范围：" + (tools.isEmpty ? "无" : tools.joined(separator: "、")))
                    .font(.caption)
            }
            ScrollView {
                Text(agent.prompt.count > 8000 ? String(agent.prompt.prefix(8000)) + "\n…（只显示前 8000 字）" : agent.prompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 320)
            HStack {
                Button("取消") { reviewing = nil }
                Spacer()
                Button("我看过了，确认") { confirm(agent) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func confirm(_ agent: CustomSubagentDefinition) {
        defer { reviewing = nil; refresh() }
        guard let store = chat.customSubagentConfirmations, let root = chat.activeTrustedProjectRoot else { return }
        // 确认的瞬间文件已经和用户看到的不一样就拒绝，要用户重新看。
        let current = CustomSubagentLoader.load(projectRoot: root, confirmations: store)
            .first { $0.confirmationKey == agent.confirmationKey }
        guard let current, current.contentHash == agent.contentHash else {
            message = "确认失败：文件内容在你查看之后又变了，请重新查看。"
            return
        }
        do {
            try store.confirm(agent)
            message = "已确认：\(agent.name)"
        } catch {
            message = "确认没有保存，请检查磁盘空间后重试。"
        }
    }

    private func revoke(_ agent: CustomSubagentDefinition) {
        do {
            try chat.customSubagentConfirmations?.revoke(agent)
            message = "已撤销：\(agent.name)"
        } catch {
            message = "撤销没有保存，请检查磁盘空间后重试。"
        }
        refresh()
    }
}
