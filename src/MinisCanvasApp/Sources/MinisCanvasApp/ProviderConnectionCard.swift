import SwiftUI

enum ProviderConnectionRoute {
    static let id = "provider-connection"
}

struct ProviderConnectionCard: View {
    let onConnect: () -> Void
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接一个模型").font(typography?.headline ?? .headline)
            Text("选择预设服务商 → 填写 Key → 保存并检查连接")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            Button("开始连接") { onConnect() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat.model-connection.start")
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("chat.model-connection")
    }
}
