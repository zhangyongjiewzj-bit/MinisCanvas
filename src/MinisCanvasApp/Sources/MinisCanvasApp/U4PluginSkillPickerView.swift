import SwiftUI
import AppKit
import MinisCore

// MARK: - U4 聊天输入区插件 / Skill 选择器
//
// 输入框左侧「插件」按钮（puzzlepiece 图标）→ popover 列出可选的技能
// 选中项以 chip（胶囊标签）挂在输入框上方，点 × 移除。
// 选中即把可见引用「@技能名」插入输入框草稿末尾（× 移除 chips = 同步删除引用）；
// 发送时从草稿提取 @引用 → 查技能目录（SkillCatalogLoader，条目带 SKILL.md 内容）
// → 把该技能 SKILL.md 内容注入本次消息系统提示（ChatStore.pickerContentInjectionFragment），
// 发送后草稿与选中项一并清空（本次消息语义）。

/// U4：选择器 popover 内容 —— 标题 + 搜索框 + 「技能 / 插件」分组列表。
struct PluginSkillPickerPopover: View {
    @Bindable var chat: ChatStore

    @State private var searchText = ""
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            list
        }
        .frame(width: 300)
        .onAppear { refreshIfNeeded() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            MinisIconView(.plugin, size: 16, accessibilityLabel: "插件")
                .foregroundPalette(Color.accentColor)
            Text("插件与技能")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("已选 \(chat.selectedPickerItems.count)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button {
                // R9 卡顿专项：刷新走后台重扫（U4 弹层交互路径不做主线程全盘扫描）
                chat.refreshPickerCatalogInBackground()
            } label: {
                MinisIconView(.refresh, size: 14, accessibilityLabel: "刷新")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刷新目录（重新扫描技能库与 MCP 配置）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 5) {
            MinisIconView(.search, size: 14, accessibilityLabel: "搜索")
            TextField("搜索插件 / 技能…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor)).opacity(0.4))
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: 列表

    private var filteredItems: [PickerCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return chat.pickerCatalog }
        return chat.pickerCatalog.filter { item in
            item.name.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var list: some View {
        let skills = filteredItems.filter { $0.kind == .skill }
        let plugins = filteredItems.filter { $0.kind == .plugin }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if chat.isPickerCatalogLoading {
                    emptyHint("正在加载插件与技能…")
                } else if chat.pickerCatalog.isEmpty {
                    emptyHint("未发现插件 / 技能\n（尚无已审核启用的技能或 MCP 服务器）")
                } else if filteredItems.isEmpty {
                    emptyHint("没有匹配「\(searchText)」的插件 / 技能")
                } else {
                    if !skills.isEmpty {
                        sectionHeader("技能", count: skills.count)
                        ForEach(skills) { item in
                            itemRow(item)
                        }
                    }
                    if !plugins.isEmpty {
                        sectionHeader("插件（MCP）", count: plugins.count)
                        ForEach(plugins) { item in
                            itemRow(item)
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 320)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: 条目行（点击切换选中）

    private func itemRow(_ item: PickerCatalogItem) -> some View {
        let selected = chat.selectedPickerItems.contains { $0.id == item.id }
        return Button {
            chat.togglePickerItem(item)
        } label: {
            HStack(spacing: 7) {
                u4ItemIcon(item, selected: selected)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    MinisIconView(.check, state: .active, size: 14, accessibilityLabel: "已选中")
                } else {
                    MinisIconView(.status, state: .disabled, size: 14, accessibilityLabel: "未选中")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .help(item.detail.isEmpty ? item.name : "\(item.name) — \(item.detail)")
    }

    /// 首次打开且目录为空时后台加载（避免弹层交互路径同步扫描技能库）
    private func refreshIfNeeded() {
        if chat.pickerCatalog.isEmpty {
            chat.loadPickerCatalogInBackground()
        }
    }

}

// MARK: - U4 选中 chip 行（输入框上方，× 移除）

@MainActor
@ViewBuilder
private func u4ItemIcon(_ item: PickerCatalogItem, selected: Bool) -> some View {
    if item.kind == .skill {
        // K2 fallback: `wand.and.stars` has no existing MinisIcon case.
        Image(systemName: "wand.and.stars")
            .font(.system(size: 10))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    } else {
        MinisIconView(
            .plugin,
            state: selected ? .active : .normal,
            size: 14,
            accessibilityLabel: "插件"
        )
    }
}

/// 已选插件 / 技能的胶囊标签行：横向滚动，点 × 移除单个。
struct PickerSelectionChips: View {
    @Bindable var chat: ChatStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(chat.selectedPickerItems) { item in
                    chip(item)
                }
            }
        }
    }

    private func chip(_ item: PickerCatalogItem) -> some View {
        HStack(spacing: 4) {
            u4ItemIcon(item, selected: true)
                .frame(width: 12, height: 12)
            Text(item.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Button {
                chat.deselectPickerItem(id: item.id)
            } label: {
                MinisIconView(.remove, size: 12, accessibilityLabel: "移除")
            }
            .buttonStyle(.plain)
            .help("移除 \(item.name)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(Color.accentColor)
        .help("本次消息引用：\(item.name)（已插入 @\(item.name) 到草稿）")
    }
}
