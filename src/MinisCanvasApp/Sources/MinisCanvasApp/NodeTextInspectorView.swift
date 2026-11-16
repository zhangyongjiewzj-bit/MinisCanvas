import SwiftUI
import AppKit
import CanvasCore

/// Binds one optimization result to the node, text and request that launched it.
struct NodeTextOptimizationOwner: Equatable {
    let nodeID: UUID
    let requestID: UUID
    let submittedText: String

    func canApply(visibleNodeID: UUID?, activeRequestID: UUID?, currentDraft: String) -> Bool {
        visibleNodeID == nodeID
            && activeRequestID == requestID
            && currentDraft == submittedText
    }
}

// MARK: - A2 右侧文本编辑面板（画布里太小，选中文本节点 → 桌面右侧大编辑区）

/// 画布右侧文本大编辑区：选中文本节点即显示（store.textInspectorNodeID 驱动），
/// TextEditor 实时写回节点内容（updateNodeContent 同源 params[content]）。
/// 与卡片内联编辑/双击编辑面板共用同一数据源，互不覆盖。
struct NodeTextInspectorView: View {
    let store: CanvasStore

    @Environment(BridgeStore.self) private var bridge
    @Environment(\.themeTokens) private var theme
    @State private var draft = ""
    @State private var activeOptimization: NodeTextOptimizationOwner?
    @State private var optimizeError: String?
    @FocusState private var focused: Bool
    private var isOptimizing: Bool { activeOptimization != nil }

    private var nodeID: UUID? { store.textInspectorNodeID }
    private var node: CanvasNode? {
        nodeID.flatMap { store.graph.node(id: $0) }
    }

    var body: some View {
        if let node {
            VStack(alignment: .leading, spacing: 0) {
                header(node)
                Divider()
                TextEditor(text: Binding(
                    get: { draft },
                    set: { newValue in
                        draft = newValue
                        // TextEditor events from a stale view must not mutate
                        // the node currently shown by a newer selection.
                        guard store.textInspectorNodeID == node.id else { return }
                        bridge.dispatchCanvasMutation(
                            .updateNodeContent(content: newValue, id: node.id)
                        )
                    }
                ))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($focused)
                    .onChange(of: store.textInspectorNodeID) { _, newValue in
                        activeOptimization = nil
                        if newValue == node.id {
                            draft = store.content(of: node.id)
                            Task { @MainActor in focused = true }
                        }
                    }
                    .onAppear {
                        draft = store.content(of: node.id)
                        Task { @MainActor in focused = true }
                    }
                    .onDisappear { activeOptimization = nil }
                Divider()
                footer(node)
            }
            .frame(width: inspectorWidth, height: inspectorHeight)
            .alert("优化失败", isPresented: Binding(
                get: { optimizeError != nil },
                set: { if !$0 { optimizeError = nil } }
            )) {
                Button("好") { optimizeError = nil }
            } message: {
                Text(optimizeError ?? "")
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor)).opacity(0.97))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme?.aj38.accent.swiftUIColor ?? Color.accentColor, lineWidth: 1)
            )
            // A3：右下角拖拽手柄（调整面板尺寸，持久化）
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(5)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                store.textInspectorWidth = max(280, min(620, inspectorWidth + value.translation.width))
                                store.textInspectorHeight = max(220, min(720, inspectorHeight + value.translation.height))
                            }
                    )
                    .help("拖拽调整编辑面板大小")
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var inspectorWidth: Double {
        min(max(store.textInspectorWidth, 280), 620)
    }

    private var inspectorHeight: Double {
        min(max(store.textInspectorHeight, 220), 720)
    }

    // MARK: 头部（标题 + 节点类型 + 关闭）

    private func header(_ node: CanvasNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 12))
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(ManjuNodeType(rawValue: node.type)?.displayName ?? node.type)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                store.closeTextInspector()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("关闭右侧编辑面板")
            .accessibilityLabel("关闭右侧编辑面板")
            .accessibilityIdentifier("canvas.text-inspector.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 底部（字数 + 缩放手柄 + 收起）

    private func footer(_ node: CanvasNode) -> some View {
        HStack(spacing: 8) {
            Text("\(draft.count) 字")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            if !draft.isEmpty {
                Button {
                    let submittedText = draft
                    Task { await optimize(nodeID: node.id, text: submittedText) }
                } label: {
                    if isOptimizing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Label("优化提示词", systemImage: "wand.and.stars")
                            .font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isOptimizing)
                .help("调用 LLM 润色当前文本（B3）")
            }
            Button {
                store.beginInlineContentEdit(nodeID: node.id)
            } label: {
                Label("画布内编辑", systemImage: "square.grid.2x2")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在画布卡片上内联编辑（画布视图）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: B3 优化提示词

    @MainActor
    private func optimize(nodeID: UUID, text: String) async {
        guard store.textInspectorNodeID == nodeID,
              store.graph.node(id: nodeID) != nil,
              draft == text, !text.isEmpty else { return }
        let owner = NodeTextOptimizationOwner(
            nodeID: nodeID, requestID: UUID(), submittedText: text
        )
        activeOptimization = owner
        defer {
            if activeOptimization?.requestID == owner.requestID {
                activeOptimization = nil
            }
        }
        do {
            let service = OptimizePromptService(providerFactory: { try bridge.chat.activeProvider() })
            let result = try await service.optimize(text)
            guard !Task.isCancelled,
                  owner.canApply(
                    visibleNodeID: store.textInspectorNodeID,
                    activeRequestID: activeOptimization?.requestID,
                    currentDraft: draft
                  ) else { return }
            // Explicitly target the initiating node. Updating draft no longer
            // routes an asynchronous result through a later view's onChange.
            bridge.dispatchCanvasMutation(
                .updateNodeContent(content: result, id: owner.nodeID)
            )
            draft = result
        } catch {
            if owner.canApply(
                visibleNodeID: store.textInspectorNodeID,
                activeRequestID: activeOptimization?.requestID,
                currentDraft: draft
            ) {
                optimizeError = error.localizedDescription
            }
        }
    }
}
