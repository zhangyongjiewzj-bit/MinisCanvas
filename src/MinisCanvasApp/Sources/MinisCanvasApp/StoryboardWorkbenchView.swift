import SwiftUI
import CanvasCore

// MARK: - P2 分镜表工作台（画布右侧悬浮面板：左列表 + 右详情）
//
// 设计文档：issues/p2_storyboard_design_20260805.md §5.2（macOS 常规布局：左列表 + 右详情）
// 数据源：CanvasCore 纯逻辑层 StoryboardAggregator（第二批线2 交付，无 mock）。
// 联动（画布分析报告缺口 :130 核心要求）：
//   - 选中分镜行 → selectNode + revealRequest 视口居中（复用 CanvasView 粘贴 reveal 机制）
//   - 画布选中节点 → 反向高亮对应行（selectedNodeIDs ∩ row.nodeIDs）
// 三态色与全局一致：通过青 #78BFC8 / 打回红 #E06060 / 待审黄 #E0B94D

/// 分镜表工作台面板主体（工具栏 + 左列表 + 右详情）。
struct StoryboardWorkbenchView: View {
    let store: CanvasStore
    let mutationCoordinator: CanvasMutationCoordinator?
    var onClose: () -> Void = {}

    /// 选中行锚点：store.storyboardSelectedNodeID（图内稳定节点 id）。
    /// ⚠️ 行选中判定/滚动定位只依赖锚点（nodeIDs.contains），绝不依赖行 id——
    /// 聚合每次重建行、id 随机生成（审计 R5-P0-1：随机 id 跨聚合失配 → 高亮/详情/滚动全失效）。
    /// 未展开分镜（多镜文本切段）每行 nodeIDs 均为同一锚点 → first 命中第一镜。
    private var selectedAnchorID: UUID? { store.storyboardSelectedNodeID }

    /// 每次渲染从图实时聚合（确定性排序；行数少，直算可接受）
    private var table: StoryboardTable {
        store.storyboardTable
    }

    private var selectedRow: StoryboardRow? {
        StoryboardAggregator.row(containing: selectedAnchorID, in: table)
    }

    private func isRowSelected(_ row: StoryboardRow) -> Bool {
        guard let anchorID = selectedAnchorID else { return false }
        return row.nodeIDs.contains(anchorID)
    }

    private func offset(ofRowContaining anchorID: UUID?) -> Int? {
        StoryboardAggregator.index(ofRowContaining: anchorID, in: table)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider()
            if table.rows.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    rowList
                        .frame(width: 184)
                    Divider()
                    detail
                }
            }
        }
        // AJ-70：宽度自适应防裁剪——min/max 钳制在可用空间内收缩：窗口/画布变窄时
        // 面板随 overlay 提议尺寸收窄（不再被 CanvasView .clipped() 裁掉左侧），
        // 空间充足时保持原 460×540 默认；左右列表/详情各自内部可滚动。
        .frame(
            minWidth: 400, idealWidth: 460, maxWidth: 460,
            minHeight: 420, idealHeight: 540, maxHeight: 540
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        // 波次3：工作台右键挂点（浮动菜单：新建分镜/导出分镜表/关闭）。
        // 菜单渲染复用主窗口全局 FloatingMenuOverlay（ContentView 根 overlay），此处只挂捕获层。
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(storyboardContextMenuItems(), at: windowPoint)
        })
    }

    /// 波次3：工作台右键菜单项（分镜相关）。
    private func storyboardContextMenuItems() -> [FloatingMenuItem] {
        [
            FloatingMenuItem(kind: .button(title: "新建分镜", icon: "plus", role: nil, help: "新建分镜节点并打开工作台") {
                createStoryboardFromEmptyState()
            }),
            FloatingMenuItem(kind: .divider),
            FloatingMenuItem(kind: .button(title: "导出分镜表 JSON", icon: "square.and.arrow.up", role: nil, help: "导出分镜表为 JSON 到 ~/Downloads") {
                store.exportStoryboardJSON()
            }),
            FloatingMenuItem(kind: .button(title: "导出分镜表 Markdown", icon: "doc.plaintext", role: nil, help: "导出分镜脚本表为 Markdown 到 ~/Downloads") {
                store.exportStoryboardMarkdown()
            }),
            FloatingMenuItem(kind: .divider),
            FloatingMenuItem(kind: .button(title: "关闭分镜表", icon: "xmark.circle", role: nil, help: "关闭分镜表工作台") {
                onClose()
            }),
        ]
    }

    // MARK: 工具栏（标题 + 行计数 + 关闭）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("分镜表")
                .font(.system(size: 13, weight: .semibold))
            if !table.rows.isEmpty {
                Text("\(table.rows.count) 镜")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭分镜表")
            .accessibilityIdentifier("canvas.storyboard.close")
            .help("关闭分镜表")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 工具栏批量操作（P2 §5.2：导出 JSON / 导出 Markdown / 逐镜生成提示词 / 全部展开）
    //
    // 按钮只做「调用 store 方法 → statusMessage 提示」，可测逻辑全部在
    // StoryboardExporter（纯函数）与 CanvasStore 扩展（写盘/剪贴板/批量展开），
    // 验证走逻辑测试（临时目录），不触发 GUI 弹窗。

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                store.exportStoryboardJSON()
            } label: {
                Label("导出JSON", systemImage: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("导出分镜表为 JSON 到 ~/Downloads")

            Button {
                store.exportStoryboardMarkdown()
            } label: {
                Label("导出Markdown", systemImage: "doc.plaintext")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("导出分镜脚本表为 Markdown 到 ~/Downloads")

            Button {
                store.copyPromptSummaryToPasteboard()
            } label: {
                Label("逐镜生成提示词", systemImage: "text.quote")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("汇总全部镜头提示词并复制到剪贴板")

            Button {
                store.expandAllStoryboards()
            } label: {
                Label("全部展开", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("把未展开分镜内容切分为逐个分镜节点（幂等，已展开不受影响）")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: 空态（无分镜节点 → 引导建流水线）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("画布上还没有分镜节点")
                .font(.system(size: 13, weight: .medium))
            Text("先建「一键流水线」或添加分镜节点，\n分镜表会自动按镜头汇总整部剧。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // AJ-70：空态创建入口——复用现有 API（addNode + openStoryboardWorkbench），
            // 新建分镜节点并定位到工作台（列表出现新行 + 右侧详情选中），不新增存储逻辑。
            Button {
                createStoryboardFromEmptyState()
            } label: {
                Label("新建分镜", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .help("新建一个分镜节点并打开分镜表")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: AJ-70 空态创建入口（用现有 API，不新增存储逻辑）

    /// 新建分镜节点并定位到工作台：`addNode(ofType:)` 走 NodeTypeRegistry 创建
    /// storyboard 节点（分镜 spec 存在，虽不在「添加节点」菜单保留清单，仍可创建）；
    /// `openStoryboardWorkbench(for:)` 打开工作台 + 记录选中锚点 + reveal 视口定位，
    /// 空态随即消失（rows 非空），新分镜行高亮且右侧详情展示。
    private func createStoryboardFromEmptyState() {
        guard let mutationCoordinator else { return }
        let existingNodeIDs = Set(store.graph.nodes.map(\.id))
        Task { @MainActor in
            do {
                _ = try await mutationCoordinator.execute(
                    .addNode(type: CanvasStore.storyboardNodeType, position: nil)
                )
                guard let node = store.graph.nodes.first(where: { !existingNodeIDs.contains($0.id) }) else {
                    return
                }
                store.openStoryboardWorkbench(for: node.id)
            } catch {
                store.statusMessage = "画布操作已拒绝：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 左列表（镜号 / 标题 / 状态色点 / 缩略图）

    private var rowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // identity 用确定性行序下标（行 id 每次聚合随机，不能作 identity/滚动目标）
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { offset, row in
                        rowCell(row)
                            .id(offset)
                    }
                }
                .padding(6)
            }
            // ③ 选中行滚动到可见（issues/p2_storyboard_interaction_20260805.md §5.2 列表体验）：
            // 行数超过面板高度时，行单击 / 双击分镜节点打开（程序化选中）都自动滚动定位；
            // onAppear 兜底面板刚打开时行已被外部选中的场景（onChange 不触发初始值）。
            .onAppear {
                if let offset = offset(ofRowContaining: selectedAnchorID) {
                    proxy.scrollTo(offset, anchor: .center)
                }
            }
            .onChange(of: selectedAnchorID) { _, newAnchor in
                guard let offset = offset(ofRowContaining: newAnchor) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(offset, anchor: .center)
                }
            }
        }
    }

    private func rowCell(_ row: StoryboardRow) -> some View {
        let isSelected = isRowSelected(row)
        // 反向高亮：画布当前选中节点属于本镜节点组
        let isLinked = !store.selectedNodeIDs.isDisjoint(with: row.nodeIDs)
        return HStack(spacing: 8) {
            Text(String(format: "%02d", row.sceneIndex))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20, alignment: .trailing)
            thumbnail(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(row.prompt)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(row.reviewStatus.statusColor)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor(isSelected: isSelected, isLinked: isLinked))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectRow(row) }
    }

    private func highlightColor(isSelected: Bool, isLinked: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isLinked { return Color.accentColor.opacity(0.07) }
        return .clear
    }

    @ViewBuilder
    private func thumbnail(_ row: StoryboardRow) -> some View {
        let path = row.imageRefs.first ?? row.videoRefs.first
        if let path, let img = store.cachedImage(path: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: 联动（行单击 = 选中 + 视口居中）

    private func selectRow(_ row: StoryboardRow) {
        // 存锚点节点 id（nodeIDs 首个 = 分镜锚点，图内稳定）；行 id 跨渲染会变，不能存
        store.storyboardSelectedNodeID = row.nodeIDs.first
        // nodeIDs 按数据流顺序（分镜 → 提示词 → 生成 → 审核 → 质检），取首节点做画布选中锚点
        guard let first = row.nodeIDs.first else { return }
        store.selectNode(id: first)
        // ② 定位中心 = 整组包围盒 min/max 中点（issues/p2_storyboard_interaction_20260805.md）：
        // 多节点组跨度大时整组居中入视野；单节点行（未展开分镜）退化为节点自身 position。
        // 复用 CanvasView 已有 reveal 机制（粘贴揭示同款）：视口平移居中 + 扩散脉冲。
        if let center = CanvasStore.boundingBoxCenter(of: row.nodeIDs, in: store.graph) {
            store.revealRequest = RevealRequest(center: center, token: UUID())
        }
    }

    // MARK: 右详情（选中行）

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            StoryboardDetailView(row: row, store: store)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("选中左侧镜头查看详情")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 三态色（与全局审核语义一致：通过青 #78BFC8 / 打回红 #E06060 / 待审黄 #E0B94D）

extension StoryboardReviewStatus {
    var statusColor: Color {
        switch self {
        case .pass:
            return Color(red: 0x78 / 255, green: 0xBF / 255, blue: 0xC8 / 255)
        case .reject:
            return Color(red: 0xE0 / 255, green: 0x60 / 255, blue: 0x60 / 255)
        case .pending:
            return Color(red: 0xE0 / 255, green: 0xB9 / 255, blue: 0x4D / 255)
        }
    }
}
