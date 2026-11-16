import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CanvasCore

// MARK: - 节点内容编辑器（E15：双击节点弹出，TextEditor + 粘贴 + 文件导入）
//
// AJ-14 精致化：参照 neo-tv 面板风格重构视觉/布局（分组卡片、层级留白、统一控件），
// 不改任何节点功能逻辑。整体结构：
//   · 顶部标题栏（状态点 + 图标 + 标题 + 类型徽标 + 字符数）
//   · 节点信息分组卡片（类型 / 执行状态 / 输入输出端口提示）
//   · 内容编辑分组卡片（TextEditor + 占位提示）
//   · 底部操作栏（导入 / 粘贴 / 清空 ｜ 取消 / 保存）

/// 节点内容编辑面板：
/// - 双击画布节点（或节点上 ✏️ 按钮）弹出
/// - TextEditor 编辑节点内容（小说文本/剧情/提示词等），支持 ⌘V 粘贴大段文本
/// - 「导入文件」按钮：NSOpenPanel 选 .txt/.md，读入后追加到编辑器（保留已输入内容）
/// - 显示：节点类型 / 标题 / 当前内容（可滚动）/ 字符数 / 保存 / 取消
/// - 保存 → `CanvasStore.setContent(nodeID:content:)` 写回；取消 → 丢弃草稿
struct NodeContentEditorView: View {
    let nodeID: UUID
    let store: CanvasStore

    @State private var draft: String = ""
    @State private var importError: String?

    @Environment(\.themeTokens) private var theme

    private var node: CanvasNode? { store.graph.node(id: nodeID) }

    /// 节点状态语义色（走 theme token；未注入回退 node.status.color，与 NodeView 一致）
    private var statusColor: Color {
        guard let node else { return .secondary }
        return theme?.nodeStatusColor(node.status) ?? node.status.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    infoSection
                    contentSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 460)
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        .onAppear { draft = store.content(of: nodeID) }
    }

    // MARK: 标题栏：节点类型 / 标题 / 字符数

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Image(systemName: spec?.iconName ?? "pencil.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(spec?.color ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(node?.title ?? "节点")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(nodeTypeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(draft.count) 字符")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var spec: NodeTypeSpec? {
        guard let node else { return nil }
        return NodeTypeRegistry.spec(for: node.type)
    }

    private var nodeTypeLabel: String {
        guard let node else { return "未知节点" }
        let specTitle = spec?.title
        return [specTitle, node.type].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 分组卡片容器（统一卡片样式：圆角 + 控制背景填充）

    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: 节点信息分组（类型 / 状态 / 端口提示）

    @ViewBuilder
    private var infoSection: some View {
        sectionCard(title: "节点信息", icon: "info.circle") {
            if let node {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("类型")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(node.type)
                            .font(.system(size: 12, weight: .medium))
                            .monospaced()
                        Spacer()
                        statusBadge
                    }
                    portsLine(inputs: node.inputs, direction: "输入")
                    portsLine(inputs: node.outputs, direction: "输出")
                }
            } else {
                Text("节点不存在")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(node?.status.label ?? "待执行")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)))
        )
    }

    /// 端口提示行：方向图标 + 端口名 + 数据类型徽标
    private func portsLine(inputs: [CanvasCore.Port], direction: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(direction)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            if inputs.isEmpty {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inputs) { port in
                        HStack(spacing: 6) {
                            Image(systemName: direction == "输入" ? "arrow.down" : "arrow.up")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(port.name)
                                .font(.system(size: 12))
                            Text(portTypeLabel(port.dataType))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.25))
                                )
                        }
                    }
                }
            }
        }
    }

    /// 数据类型 → 中文标签
    private func portTypeLabel(_ dataType: String) -> String {
        switch dataType {
        case "string": return "文本"
        case "image": return "图片"
        case "video": return "视频"
        default: return dataType
        }
    }

    // MARK: 内容编辑分组（TextEditor，可滚动，支持 ⌘V 粘贴）

    private var contentSection: some View {
        sectionCard(title: "节点内容", icon: "text.quote") {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay(alignment: .center) {
                    if draft.isEmpty {
                        Text("在此输入节点内容…（可直接 ⌘V 粘贴大段文本）")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("节点内容编辑器")
                .accessibilityIdentifier("canvas.node-content-editor.input")
        }
    }

    // MARK: 底部：导入 / 粘贴 / 清空 ｜ 取消 / 保存

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let importError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(importError)
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme?.statusDanger ?? .red)
            }
            HStack(spacing: 8) {
                Button {
                    importFromFile()
                } label: {
                    Label("导入文件…", systemImage: "doc.badge.plus")
                }
                .help("从 .txt / .md 文件导入内容（追加到编辑器）")

                Button {
                    pasteFromClipboard()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .help("把剪贴板文本追加到编辑器（也可直接 ⌘V）")

                Button {
                    draft = ""
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .help("清空编辑器草稿")

                Spacer()

                Button("取消") {
                    store.closeContentEditor()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    store.setContent(nodeID: nodeID, content: draft)
                    store.closeContentEditor()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 粘贴 / 导入

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        appendToDraft(text)
    }

    /// 文件导入：NSOpenPanel 选 .txt/.md，读入后追加（保留已输入内容）
    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "导入节点内容"
        panel.message = "选择 .txt / .md 文本文件（内容将追加到编辑器）"
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // R9 卡顿专项：String(contentsOf:) 同步读文件移后台线程 ——
            // NSOpenPanel.begin 完成回调在主线程，大文本（数 MB）会卡编辑器。
            Task.detached(priority: .userInitiated) {
                let text = try? String(contentsOf: url, encoding: .utf8)
                await MainActor.run {
                    if let text {
                        importError = nil
                        appendToDraft(text)
                    } else {
                        importError = "读取文件失败"
                    }
                }
            }
        }
    }

    private func appendToDraft(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if draft.isEmpty {
            draft = trimmed
        } else {
            draft += "\n\n" + trimmed
        }
    }
}
