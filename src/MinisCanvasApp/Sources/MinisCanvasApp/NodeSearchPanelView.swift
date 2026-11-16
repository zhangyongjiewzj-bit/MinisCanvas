import SwiftUI
import CanvasCore

// MARK: - 节点搜索面板（C5：双击画布空白弹出，学 ComfyUI showSearchBox）
//
// 输入即过滤（type/title/summary 模糊匹配 15 类节点）→ ↑↓ 选择 → 回车在双击位置创建；
// ESC / 点击面板外关闭。面板状态（是否展示/弹出位置）由 CanvasStore 持有，本视图只做渲染与键盘流。

struct NodeSearchPanelView: View {
    let store: CanvasStore

    @Environment(\.themeTokens) private var theme
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var textFocused: Bool

    /// 实时过滤结果（空关键词 = 全部 15 类）
    private var results: [NodeTypeSpec] { store.nodeSearchResults(matching: query) }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            Divider()
            resultsList
        }
        .frame(width: 300, height: 300)
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onAppear { textFocused = true }
    }

    // MARK: 输入行（回车创建选中项；↑↓ 移动选择；ESC 关闭）

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索节点类型…（回车创建）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($textFocused)
                .onSubmit { submit() }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.escape) { store.dismissNodeSearch(); return .handled }
            Text("\(results.count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    // MARK: 结果列表（选中行高亮 + 自动滚动跟随）

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if results.isEmpty {
                        Text("无匹配节点类型")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, spec in
                            row(spec, index: index)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard newIndex < results.count else { return }
                proxy.scrollTo(results[newIndex].id, anchor: .center)
            }
        }
    }

    private func row(_ spec: NodeTypeSpec, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return Button {
            store.createNodeFromSearch(type: spec.type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: spec.iconName)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(spec.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(spec.type)
                    .font(.system(size: 9, weight: .medium))
                    .monospaced()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(spec.id)
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    private func submit() {
        guard !results.isEmpty else { return }
        let index = min(max(selectedIndex, 0), results.count - 1)
        store.createNodeFromSearch(type: results[index].type)
    }
}
