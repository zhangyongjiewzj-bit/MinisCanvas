import SwiftUI

// MARK: - 左侧节点类型面板

/// 从 CanvasNode.type 字符串注册表（NodeTypeRegistry）渲染可添加的节点类型。
/// 按分组展示：漫剧流程 → 漫剧工具 → 基础节点；点击条目 → 添加到画布；
/// 支持拖拽到画布（落点作为节点位置）；提示词类节点标题旁显示模板槽位徽标（如 "8槽"）。
/// Phase B 瘦身：只列 `creatableSpecs`（7 类生成类节点），文本创作类不再出现在面板。
struct NodePaletteView: View {
    let store: CanvasStore

    /// 面板分组顺序：漫剧流程 / 漫剧工具 / 基础节点
    private static let groupOrder: [NodePaletteGroup] = [.manjuFlow, .manjuTools, .basic]

    private var groupedSpecs: [NodePaletteGroup: [NodeTypeSpec]] {
        Dictionary(grouping: NodeTypeRegistry.creatableSpecs, by: { $0.group })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("节点")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.groupOrder) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }

    /// 分组区块：组标题 + 组内节点条目
    @ViewBuilder
    private func section(_ group: NodePaletteGroup) -> some View {
        let specs = groupedSpecs[group] ?? []
        if !specs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(group.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(specs) { spec in
                        paletteItem(spec)
                    }
                }
            }
        }
    }

    private func paletteItem(_ spec: NodeTypeSpec) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(spec.color.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: spec.iconName)
                        .font(.system(size: 15))
                        .foregroundStyle(spec.color)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(spec.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let slots = spec.slotCount, slots > 0 {
                        Text("\(slots)槽")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(spec.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(spec.color.opacity(0.15))
                            )
                    }
                }
                Text(spec.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.addNode(ofType: spec.type)
        }
        .onDrag {
            NSItemProvider(object: spec.type as NSString)
        }
    }
}
