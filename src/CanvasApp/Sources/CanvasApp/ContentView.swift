import SwiftUI

// MARK: - App 入口

@main
struct CanvasAppApp: App {
    var body: some Scene {
        WindowGroup("MinisCanvas 画布") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}

// MARK: - 主界面

/// 主界面：工具栏 + 左侧节点面板 + 无限画布
struct ContentView: View {
    @State private var store = CanvasStore()
    /// 一键生成前的替换确认（画布非空时弹）
    @State private var confirmPipelineReplace = false
    /// 模板库覆盖确认（pendingTemplate != nil 时弹"覆盖当前画布？"）
    @State private var pendingTemplate: PipelineTemplate?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                NodePaletteView(store: store)
                CanvasView(store: store)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let toast = store.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toastMessage)
        .task(id: store.toastMessage) {
            // toast 自动消失（3.5 秒；id 变化会取消上一个计时）
            guard store.toastMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            store.toastMessage = nil
        }
        .sheet(isPresented: modelPanelBinding) {
            ModelConfigPanelView(nodeID: store.modelPanelNodeID ?? UUID(), store: store)
        }
        .alert("替换当前画布？", isPresented: $confirmPipelineReplace) {
            Button("生成流水线", role: .destructive) { store.installManjuPipeline() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前画布已有 \(store.graph.nodes.count) 个节点，一键生成将替换为漫剧流水线骨架。")
        }
        .alert("覆盖当前画布？", isPresented: pendingTemplateBinding) {
            Button("生成模板", role: .destructive) {
                if let template = pendingTemplate {
                    store.installTemplate(template)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前画布已有 \(store.graph.nodes.count) 个节点，生成模板将替换现有内容。")
        }
        .onDeleteCommand {
            if !store.selectedNodeIDs.isEmpty {
                store.removeNodes(ids: Array(store.selectedNodeIDs))
            }
        }
    }

    /// 模型面板展示绑定（由 store.modelPanelNodeID 驱动，关闭时回写 nil）
    private var modelPanelBinding: Binding<Bool> {
        Binding(
            get: { store.modelPanelNodeID != nil },
            set: { if !$0 { store.closeModelPanel() } }
        )
    }

    /// 模板库覆盖确认绑定（pendingTemplate != nil 时弹窗，关闭回写 nil）
    private var pendingTemplateBinding: Binding<Bool> {
        Binding(
            get: { pendingTemplate != nil },
            set: { if !$0 { pendingTemplate = nil } }
        )
    }

    /// 模板库入口：空画布直接生成，非空弹覆盖确认
    private func requestTemplate(_ template: PipelineTemplate) {
        if store.graph.nodes.isEmpty {
            store.installTemplate(template)
        } else {
            pendingTemplate = template
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            // 执行按钮
            Button {
                store.runGraph()
            } label: {
                Label(store.isRunning ? "执行中…" : "执行", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(store.isRunning || store.graph.nodes.isEmpty)

            // 一键流水线（M1d：ManjuPipeline.standardPipeline 全流程，追加模式不覆盖）
            Button {
                store.createPipeline()
            } label: {
                Label("一键流水线", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .keyboardShortcut("p", modifiers: [.command, .shift])

            // 模板库（M1h：漫剧全流程 / 仅提示词 / 仅生图 3 个预置模板，覆盖模式）
            Menu {
                ForEach(PipelineTemplate.allCases) { template in
                    Button {
                        requestTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.icon)
                    }
                    .help(template.subtitle)
                }
            } label: {
                Label("模板库", systemImage: "square.grid.2x2.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .tint(.orange)
            .help("模板库：漫剧全流程 / 仅提示词 / 仅生图")

            // 一键漫剧流水线（M1b：模板工厂 + 资产锁定注入；Cmd+Shift+M）
            Button {
                if store.graph.nodes.isEmpty {
                    store.installManjuPipeline()
                } else {
                    confirmPipelineReplace = true
                }
            } label: {
                Label("漫剧流水线", systemImage: "square.stack.3d.up.fill")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .keyboardShortcut("m", modifiers: [.command, .shift])

            // 执行到此处：跑选中节点及其全部上游（A2-v04）
            Button {
                if let selected = store.selectedNodeID {
                    store.runToNode(selected)
                }
            } label: {
                Label("执行到此处", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
            .disabled(store.isRunning || store.selectedNodeID == nil)

            // 自动布局（整图分层重排 + 缩放全图，Cmd+Shift+L）
            Button {
                store.autoLayout()
            } label: {
                Label("自动布局", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(store.graph.nodes.isEmpty)

            // 重置状态
            Button {
                store.resetStatuses()
            } label: {
                Label("重置状态", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.graph.nodes.isEmpty)

            Spacer()

            // 节点统计
            Text("节点 \(store.graph.nodes.count) · 连线 \(store.graph.edges.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // 状态提示
            if let message = store.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }
}
