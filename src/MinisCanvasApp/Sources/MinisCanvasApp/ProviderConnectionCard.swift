import SwiftUI

enum ProviderConnectionRoute {
    static let id = "provider-connection"
    /// 对话里“检查 API Key”/“去修复”指定要打开的供应商标识；设置页打开编辑表单时取用一次后清空。
    nonisolated(unsafe) static var preferredProviderID: String?
    /// 模型选择里点了还没有供应商记录的内置服务商（如 DeepSeek）：打开“新增供应商”并预选这个预设（空串＝不预选）；取用一次后清空。
    nonisolated(unsafe) static var preferredPresetID: String?
}

struct ProviderConnectionCard: View {
    /// 已有供应商但没有可用模型时给出名称，按钮改为“去修复〈名称〉”并直接打开它的编辑表单。
    var repairProviderName: String? = nil
    /// 用户设为默认的供应商已配置、但还没检查过连接时给出名称：卡片改为“检查连接”，就地检查，不跳设置。
    var uncheckedDefaultName: String? = nil
    var isChecking = false
    var onCheck: () -> Void = {}
    let onConnect: () -> Void
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        if let uncheckedDefaultName {
            uncheckedDefaultBody(uncheckedDefaultName)
        } else {
            connectBody
        }
    }

    private func uncheckedDefaultBody(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("默认模型还没检查连接").font(typography?.headline ?? .headline)
            Text("「\(name)」已经配置好，检查能连上后会自动切换过去；在那之前对话停在演示模式。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(isChecking ? "正在检查…" : "检查连接「\(name)」") { onCheck() }
                    .buttonStyle(.bordered)
                    .disabled(isChecking)
                    .accessibilityIdentifier("chat.model-connection.check-default")
                Button("去设置") { onConnect() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("chat.model-connection.open-default")
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("chat.model-connection")
    }

    private var connectBody: some View {
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
