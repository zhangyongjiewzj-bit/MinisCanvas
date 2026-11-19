import SwiftUI
import MinisCore

/// SecureField state is local to this sheet and is cleared on every exit.
struct ChatCredentialCardView: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var chat: ChatStore
    @State private var providerID = ""
    @State private var baseURL = ""
    @State private var models = ""
    @State private var protocolType = ProviderWireProtocol.openaiCompatible
    @State private var secureValue = ""
    @State private var riskConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安全保存供应商凭据").font(.headline)
            Text("凭据只在本机处理，不会发送给模型。确认后将写入钥匙串，并向下方供应商地址发送连通性探测。请核实地址与供应商身份。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("现有供应商", selection: $providerID) {
                Text("请选择或填写新供应商").tag("")
                ForEach(chat.credentialBroker.providerIDs, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: providerID) { _, value in
                if let projection = chat.credentialBroker.providerProjection(value) {
                    baseURL = projection.baseURL
                    models = projection.modelIDs.joined(separator: ", ")
                    protocolType = projection.protocolType
                }
            }
            TextField("供应商标识", text: $providerID)
            TextField("Base URL", text: $baseURL)
            TextField("模型名称（逗号分隔）", text: $models)
            SecureField("API Key（留空使用刚才本地捕获的值）", text: $secureValue)
                .accessibilityIdentifier("credential.local.secure-input")
            if ProviderEndpointPolicy.isPlainHTTPToPublicHost(baseURL) {
                Text("该地址使用 http，Key 会在网络上明文传输，有被截获的风险；仅在你信任该网络和服务时继续。")
                    .font(.caption)
                    .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("credential.local.plainHTTP")
            }
            Toggle(ProviderEndpointPolicy.isPlainHTTPToPublicHost(baseURL)
                   ? "我已了解明文传输的风险，仍同意保存并探测"
                   : "我已核实供应商地址，同意保存并探测", isOn: $riskConfirmed)
            .onChange(of: baseURL) { _, _ in riskConfirmed = false }
            HStack {
                Button("取消") {
                    secureValue = ""
                    chat.credentialBroker.cancel()
                }
                Spacer()
                Button("确认保存并探测") {
                    guard let sessionID = chat.activeSessionID,
                          chat.credentialBroker.pending?.sessionID == sessionID else { return }
                    if !secureValue.isEmpty {
                        _ = chat.credentialBroker.captureSecureField(secureValue, sessionID: sessionID)
                        secureValue = ""
                    }
                    guard let request = chat.credentialBroker.pending else { return }
                    Task {
                        let outcome = await chat.credentialBroker.confirm(
                            requestID: request.id, sessionID: sessionID, providerID: providerID,
                            baseURL: baseURL, modelIDs: models.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                            protocolType: protocolType, riskConfirmed: riskConfirmed)
                        let text: String
                        switch outcome {
                        case .saved: text = "供应商凭据已安全保存，连通性探测通过。"
                        case .savedProbeBlocked: text = "供应商凭据已安全保存；当前隔离环境未允许此地址的网络探测。"
                        case .savedProbeFailed: text = "供应商凭据已安全保存；连通性探测未通过，请在供应商设置中检查。"
                        case .rejected: text = "凭据操作未获确认或未完成，请重新核实后重试。"
                        case .cancelled: text = "凭据操作已取消。"
                        }
                        _ = chat.appendAssistant(text, toSession: sessionID)
                    }
                }
                .disabled(!riskConfirmed || providerID.isEmpty || chat.credentialBroker.isConfirming)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { secureValue = "" }
    }
}
