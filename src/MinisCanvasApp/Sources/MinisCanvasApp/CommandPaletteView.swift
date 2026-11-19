import SwiftUI
import CanvasCore
import MinisCore

// MARK: - 全局命令面板（⌘K / Ctrl+Space）
//
// C3-1：对齐 ComfyUI searchbox v2 四段式——输入 + 分类侧栏 + 结果列表（图标/名称/快捷键徽标）+ 收藏。
// 命令本体 100% 来自 CommandRegistry（注册制唯一命令源，见 AppCommandCatalog）；本视图只做渲染与执行。

struct CommandPaletteView: View {
    @Bindable var bridge: BridgeStore
    @State private var model: CommandPaletteModel
    @FocusState private var searchFocused: Bool
    @Environment(\.themeTokens) private var theme

    init(bridge: BridgeStore) {
        self.bridge = bridge
        _model = State(initialValue: CommandPaletteModel(
            registry: bridge.commandRegistry,
            display: bridge.paletteDisplay,
            favorites: bridge.favoriteCommands
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchInput
            Divider()
            HStack(spacing: 0) {
                categorySidebar
                Divider()
                resultsList
            }
        }
        .escapeShortcut(closeSheet: bridge.commandPaletteEscapeAction())
        .frame(width: 560, height: 440)
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let draft = bridge.takeCommandPaletteDraft() {
                model.updateQuery(draft)
                searchFocused = true
            }
        }
    }

    // MARK: 输入行（输入即过滤，250ms 防抖）

    var searchPlaceholder: String {
        let shortcut = bridge.shortcutStore.binding(for: .commandPalette)
        return shortcut.isEmpty
            ? "搜索命令…"
            : "搜索命令…（\(shortcut.displayString)）"
    }

    private var searchInput: some View {
        HStack(spacing: 8) {
            MinisIconView(.search, size: MinisIconTokens.defaultSize)
            TextField(searchPlaceholder, text: Binding(
                get: { model.query },
                set: { model.updateQuery($0) }
            ))
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .font(.system(size: 14))
            .onSubmit {
                runSubmittedQuery()
            }
            if !model.query.isEmpty {
                Button {
                    model.updateQuery("")
                } label: {
                    MinisIconView(.close, size: MinisIconTokens.smallSize)
                }
                .buttonStyle(.plain)
                .help("清空输入")
                .accessibilityLabel("清空输入")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: 分类侧栏（ComfyUI NodeSearchCategorySidebar）

    private var categorySidebar: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                sidebarItem(title: "全部", count: model.totalCount, isSelected: model.selectedCategory == nil) {
                    model.selectedCategory = nil
                }
                ForEach(model.categoryCounts, id: \.category) { entry in
                    sidebarItem(
                        title: entry.category.displayName,
                        count: entry.count,
                        isSelected: model.selectedCategory == entry.category
                    ) {
                        model.selectedCategory = entry.category
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 132)
        .background((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.4))
    }

    private func sidebarItem(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 结果列表（分组：收藏置顶 + 分类 / 检索结果）

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, section.id == model.sections.first?.id ? 2 : 8)
                        ForEach(section.commands) { command in
                            commandRow(command)
                        }
                    }
                }
                if model.sections.allSatisfy({ $0.commands.isEmpty }) {
                    Text("无匹配命令")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 24)
                }
            }
            .padding(8)
        }
    }

    private var firstResult: PaletteCommand? {
        model.sections.first { !$0.commands.isEmpty }?.commands.first
    }

    // MARK: 回车执行（F22④ 带参命令参数透传）

    /// 面板回车提交的解析结果：要执行的命令 id + 解析出的参数。
    struct PaletteSubmission: Equatable {
        let id: String
        let args: [String: String]
    }

    /// F22④（Q8-r4 P1-3）：回车执行时先把输入整体当命令解析——结构化形态
    ///（`/env.set FOO=bar`、`env.set FOO=bar`、`env set FOO=bar`）与自然语言形态
    /// 都由 `MinisCore.CommandParser` 提取参数，命中则「命令 + 参数」一起下发；
    /// 解析未命中（纯过滤词）才回落到当前 top-1 结果（无参数）。
    /// 抽成纯静态函数便于无 SwiftUI 宿主的单测（F22CommandArgTests）。
    /// `category` 给出时（侧栏选了分类），解析出的命令必须属于这个分类才采用；否则（例如在“日志”
    /// 分类里输入“设置日志”被解析成“设置环境变量 + 参数”）回车执行列表里看得到的第一项。
    static func resolveSubmission(
        query: String,
        registry: CommandRegistry,
        fallbackID: String?,
        category: CommandCategory? = nil
    ) -> PaletteSubmission? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 显式限定 MinisCore.CommandParser —— App 模块内另有同名画布指令解析器
            let parsed = MinisCore.CommandParser().parse(trimmed, registry: registry)
            if let command = parsed.command, category.map({ $0 == command.category }) ?? true {
                return PaletteSubmission(id: command.id, args: parsed.args)
            }
        }
        return fallbackID.map { PaletteSubmission(id: $0, args: [:]) }
    }

    /// A row click in an already filled query must carry those arguments,
    /// rather than replacing them with a fresh empty draft.
    static func filledSubmissionForRow(
        query: String,
        registry: CommandRegistry,
        selectedID: String
    ) -> PaletteSubmission? {
        guard let submission = resolveSubmission(query: query, registry: registry, fallbackID: nil),
              submission.id == selectedID, !submission.args.isEmpty else { return nil }
        return submission
    }

    private func runSubmittedQuery() {
        // 回车前先同步重算：防抖还没到时，别用上一次的结果当 top-1。
        model.refresh()
        guard let submission = Self.resolveSubmission(
            query: model.query,
            registry: model.registry,
            fallbackID: firstResult?.id,
            category: model.selectedCategory
        ) else { return }
        bridge.runCommand(id: submission.id, args: submission.args)
    }

    private func commandRow(_ command: PaletteCommand) -> some View {
        HStack(spacing: 10) {
            // 主体：点击执行
            Button {
                if let submission = Self.filledSubmissionForRow(
                    query: model.query,
                    registry: model.registry,
                    selectedID: command.id
                ) {
                    bridge.runCommand(id: submission.id, args: submission.args)
                    return
                }
                bridge.activateCommandRow(id: command.id)
                if let draft = bridge.takeCommandPaletteDraft() {
                    model.updateQuery(draft)
                    searchFocused = true
                }
            } label: {
                HStack(spacing: 10) {
                    // Command catalog icons are dynamic SF names; no stable MinisIcon case can cover them.
                    Image(systemName: command.icon)
                        .font(.system(size: 13))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(command.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let shortcut = command.shortcut {
                        Text(shortcut)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!command.isEnabled)
            .help(command.disabledReason ?? command.title)

            // 收藏 ⭐（独立按钮，与执行不冲突）
            Button {
                model.toggleFavorite(command.id)
            } label: {
                // Favorite state uses the star/star.fill pair, which has no stable MinisIcon case.
                Image(systemName: command.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(command.isFavorite ? (theme?.aj38.accent.swiftUIColor ?? Color.yellow) : Color.secondary.opacity(0.5))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(!command.isEnabled)
            .help(command.isFavorite ? "取消收藏" : "收藏到顶部")
            .accessibilityLabel(command.isFavorite ? "已收藏，取消收藏" : "未收藏，收藏到顶部")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.5))
        )
    }
}
