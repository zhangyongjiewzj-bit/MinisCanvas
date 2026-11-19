import SwiftUI

/// Small, disclosure-based surface used by the chat inspector.
/// It owns presentation state only; all facts arrive as value projections.
struct InspectorSection<Content: View>: View {
    let identifier: String
    let title: String
    let icon: String
    let catalogIcon: MinisIcon?
    let summary: String?
    private let content: () -> Content
    private let defaultExpanded: Bool
    /// 用户手动展开/收起的记忆：0 = 未操作（跟随“是否有内容”），1 = 展开，2 = 收起。
    /// 只读写自己这一个键，不依赖任何会话或消息数据。
    @AppStorage private var storedChoice: Int
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    init(
        identifier: String,
        title: String,
        icon: String,
        catalogIcon: MinisIcon? = nil,
        summary: String? = nil,
        initiallyExpanded: Bool = true,
        hasContent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.identifier = identifier
        self.title = title
        self.icon = icon
        self.catalogIcon = catalogIcon
        self.summary = summary
        self.content = content
        // 没有内容的区块默认收起；用户没手动操作过时，内容从无到有会自动展开。
        defaultExpanded = initiallyExpanded && hasContent
        _storedChoice = AppStorage(wrappedValue: 0, "inspector.section.expanded.\(identifier)")
    }

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                switch storedChoice {
                case 1: return true
                case 2: return false
                default: return defaultExpanded
                }
            },
            set: { storedChoice = $0 ? 1 : 2 }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpandedBinding) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                if let catalogIcon {
                    MinisIconView(catalogIcon, size: 12)
                        .foregroundPalette(HierarchicalShapeStyle.tertiary)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        // Decorative: the title follows; never announce the symbol name.
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font((typography?.caption ?? .system(size: 10)).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(typography?.caption ?? .system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().accessibilityHidden(true) }
        .accessibilityIdentifier(identifier)
    }
}

/// A stable key/value row shared by inspector sections.
struct InspectorValueRow: View {
    let label: String
    let value: String
    var tint: Color?
    @Environment(\.typographyTokens) private var typography

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(typography?.contextBody ?? .system(size: 10))
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct InspectorEmptyState: View {
    let text: String
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        Text(text)
            .font(typography?.caption ?? .system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
