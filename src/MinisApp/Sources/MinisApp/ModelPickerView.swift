import SwiftUI
import MinisCore

// MARK: - 模型选择器（Provider 下拉 + 模型子菜单）

struct ModelPickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            // Mock 占位（UI 管线演示）
            Button {
                appState.selectedProviderType = nil
                appState.selectedModel = nil
            } label: {
                if appState.selectedProviderType == nil {
                    Label("Mock（UI 演示）", systemImage: "checkmark")
                } else {
                    Text("Mock（UI 演示）")
                }
            }

            Divider()

            // 已注册 Provider（来自 ProviderFactory）
            ForEach(appState.availableProviders, id: \.self) { type in
                providerMenu(for: type)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(appState.providerLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择 Provider 与模型")
    }

    @ViewBuilder
    private func providerMenu(for type: ProviderType) -> some View {
        if type.builtInModels.isEmpty {
            // 无内置模型目录（local 等）：显示端点占位
            Button {
                appState.selectedProviderType = type
                appState.selectedModel = nil
            } label: {
                if appState.selectedProviderType == type && appState.selectedModel == nil {
                    Label(type.displayName, systemImage: "checkmark")
                } else {
                    Text(type.displayName)
                }
            }
            Menu("\(type.displayName) · 模型") {
                Button("默认模型（端点自动发现）") {
                    appState.selectedProviderType = type
                    appState.selectedModel = nil
                }
                Button("Ollama @ http://127.0.0.1:11434") {
                    appState.selectedProviderType = type
                    appState.selectedModel = nil
                }
                Button("自定义端点（设置中配置）") {
                    appState.settingsPresented = true
                }
            }
        } else {
            Menu(type.displayName) {
                Button("默认模型") {
                    appState.selectedProviderType = type
                    appState.selectedModel = nil
                }
                Divider()
                ForEach(type.builtInModels, id: \.id) { model in
                    Button {
                        appState.selectedProviderType = type
                        appState.selectedModel = model
                    } label: {
                        if appState.selectedProviderType == type && appState.selectedModel?.id == model.id {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
        }
    }
}
