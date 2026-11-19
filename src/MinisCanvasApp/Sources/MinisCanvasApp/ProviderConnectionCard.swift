import SwiftUI

enum ProviderConnectionRoute {
    static let id = "provider-connection"
    /// 对话里“检查 API Key”/“去修复”指定要打开的供应商标识；设置页打开编辑表单时取用一次后清空。
    nonisolated(unsafe) static var preferredProviderID: String?
}

struct ProviderConnectionCard: View {
    /// 已有供应商但没有可用模型时给出名称，按钮改为“去修复〈名称〉”并直接打开它的编辑表单。
    var repairProviderName: String? = nil
    let onConnect: () -> Void
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(repairProviderName == nil ? "连接一个模型" : "模型连接需要修复").font(typography?.headline ?? .headline)
            Text(repairProviderName == nil
                 ? "选一个模型服务商 → 填入服务商给你的密钥（API Key） → 保存并检查能否连上"
                 : "已添加的供应商还没有通过连接检查：核对密钥（API Key）、服务地址和模型名后重新检查")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            Button(repairProviderName.map { "去修复「\($0)」" } ?? "开始连接") { onConnect() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat.model-connection.start")
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("chat.model-connection")
    }
}
