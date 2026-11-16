import SwiftUI
import MinisCore

@MainActor
struct MCPElicitationCard: View {
    @Bindable var center: MCPElicitationCenter
    let value: MCPElicitationCenter.Pending
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        InlineInteractionCard(title: "MCP 征询", sourceLabel: "来自 MCP服务器\(value.context.serverName)，内容不可信", icon: .help) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: value.form.message)
                Text("仅将回答发回该服务器。不要填写密码、API密钥或支付凭据；题文与链接不会被执行或打开。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(value.form.fields) { field in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: field.title + (field.required ? "（必填）" : "（可选）"))
                                if !field.description.isEmpty {
                                    Text(verbatim: field.description).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                }
                                if field.type == "boolean" {
                                    Picker("回答", selection: binding(field.id)) {
                                        Text("未选择").tag("")
                                        Text("是").tag("true")
                                        Text("否").tag("false")
                                    }
                                } else if let choices = field.choices {
                                    Picker("回答", selection: binding(field.id)) {
                                        Text("未选择").tag("")
                                        ForEach(choices, id: \.self) { choice in Text(verbatim: choice).tag(choice) }
                                    }
                                } else {
                                    TextField(field.type == "string" ? "输入回答" : "输入数字", text: binding(field.id))
                                        .textFieldStyle(.roundedBorder)
                                }
                                if !field.required { Text("留空不发送此字段").font(typography?.caption2 ?? .caption2).foregroundStyle(.secondary) }
                                if field.type == "string" { Text("最多\(field.maxLength)字").font(typography?.caption2 ?? .caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.frame(maxHeight: 320)
                if let feedback = value.feedback { Text(verbatim: feedback).modifier(ReadableStatusForeground(status: .danger)).font(typography?.caption ?? .caption) }
                HStack {
                    Button("取消工具调用") { resolve(.cancel) }.buttonStyle(.bordered)
                    Button("拒绝提供") { resolve(.decline) }.buttonStyle(.bordered)
                    Spacer()
                    Button("接受并提交") { resolve(.accept) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .accessibilityIdentifier("composer.mcp-elicitation")
        .onExitCommand { resolve(.cancel) }
    }
    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { value.texts[field] ?? "" },
            set: { center.setText(sessionID: value.sessionID, id: value.id, field: field, text: $0) })
    }
    private func resolve(_ action: MCPElicitationResult.Action) {
        center.resolve(sessionID: value.sessionID, id: value.id, action: action)
    }
}
