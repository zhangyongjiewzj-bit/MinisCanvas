import SwiftUI

/// Shared visual shell only. The owning feature validates input and resolves
/// its own continuation; rendering this card never grants tool authority.
struct InlineInteractionCard<Content: View>: View {
    let title: String
    let sourceLabel: String?
    let icon: MinisIcon
    private let content: Content
    @Environment(\.typographyTokens) private var typography

    init(title: String, sourceLabel: String? = nil, icon: MinisIcon = .help,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        if title.isEmpty {
            // O14 owns its existing visual treatment; the shared shell must not
            // add padding/background/fonts or change VStack's default spacing.
            VStack(alignment: .leading) { content }
        } else {
            decoratedCard
        }
    }

    private var decoratedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MinisIconView(icon, size: 18)
                Text(verbatim: title).font(typography?.headline ?? .headline)
                Spacer(minLength: 4)
                if let sourceLabel {
                    Text(verbatim: sourceLabel)
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
            }
            content
                .font(typography?.body ?? .body)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}
