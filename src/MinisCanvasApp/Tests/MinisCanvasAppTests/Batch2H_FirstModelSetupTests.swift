import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// Batch2H / U-04：首次配置模型。
// 新符号（修复作者按此签名实现；均为纯值/纯函数，无 UI 依赖）：
//   ProviderPreset                         —— MinisCore（见 Core 测试）
//   ProviderAddFormState                   —— App，新增供应商表单的状态层
//   ModelPickerProviderRow / ModelPickerState.providerMenuRows(options:readyProviderIDs:)
// 测试里只用占位假值作 API Key，只断言引用名，不涉及真实钥匙串。

@Suite("Batch2H 新增供应商表单预设")
struct Batch2HProviderAddFormTests {

    @Test("选 DeepSeek 预设后：凭据名、Base URL、协议、模型列表自动填好，只剩 API Key 待填")
    func selectingDeepSeekPresetPrefillsEverythingButKey() throws {
        var form = ProviderAddFormState.initial(fromConnectionRoute: false)
        #expect(form.missingRequiredFields.contains(.apiKey))
        form.selectPreset(id: "deepseek")
        let preset = try #require(ProviderPreset.all.first { $0.id == "deepseek" })
        #expect(form.name == "DEEPSEEK_API_KEY")
        #expect(form.name == preset.credentialName)
        #expect(form.baseURL == preset.baseURL)
        #expect(form.protocolType == preset.protocolType)
        #expect(form.modelNames == preset.modelNames)
        #expect(form.apiKey.isEmpty)
        #expect(form.missingRequiredFields == [.apiKey])
        form.apiKey = "placeholder-not-a-real-key"
        #expect(form.missingRequiredFields.isEmpty)
        // 保存只引用凭据名，Key 本身不进入表单快照里的任何引用/展示字段。
        #expect(form.name != form.apiKey)
    }

    @Test("百炼、NewAPI 预设同样一键填好")
    func selectingOtherPresetsPrefills() throws {
        for id in ["dashscope", "newapi"] {
            var form = ProviderAddFormState.initial(fromConnectionRoute: false)
            form.selectPreset(id: id)
            let preset = try #require(ProviderPreset.all.first { $0.id == id })
            #expect(form.name == preset.credentialName, "\(id)")
            #expect(form.baseURL == preset.baseURL, "\(id)")
            #expect(form.modelNames == preset.modelNames, "\(id)")
            #expect(form.missingRequiredFields == [.apiKey], "\(id)")
        }
    }

    @Test("切换预设会整体替换，不残留上一个预设的 Base URL 和模型")
    func switchingPresetReplacesPreviousFields() throws {
        var form = ProviderAddFormState.initial(fromConnectionRoute: false)
        form.selectPreset(id: "deepseek")
        form.selectPreset(id: "newapi")
        let newAPI = try #require(ProviderPreset.all.first { $0.id == "newapi" })
        #expect(form.name == newAPI.credentialName)
        #expect(form.baseURL == newAPI.baseURL)
        #expect(form.modelNames == newAPI.modelNames)
    }

    @Test("不选预设（自定义）时仍需自填名称、Base URL、模型和 Key")
    func customPathStillRequiresManualFields() {
        let form = ProviderAddFormState.initial(fromConnectionRoute: false)
        #expect(Set(form.missingRequiredFields) == [.name, .baseURL, .modelNames, .apiKey])
    }
}

@Suite("Batch2H 连接模型入口")
struct Batch2HConnectionEntryTests {

    @Test("从“连接一个模型”卡进入：直接展示预设列表，且列表非空、含 DeepSeek")
    func connectionRouteShowsPresetListByDefault() {
        let form = ProviderAddFormState.initial(fromConnectionRoute: true)
        #expect(form.showsPresetPicker)
        #expect(form.presets == ProviderPreset.all)
        #expect(form.presets.contains { $0.id == "deepseek" })
        #expect(form.name.isEmpty && form.baseURL.isEmpty)
    }

    @Test("路由 id 仍是 provider-connection（卡片、菜单、设置页共用）")
    func routeIDUnchanged() {
        #expect(ProviderConnectionRoute.id == "provider-connection")
    }
}

@Suite("Batch2H 模型菜单排序")
@MainActor
struct Batch2HModelMenuOrderTests {

    private func record(_ name: String) -> EnvVarEntry {
        EnvVarEntry(name: name, value: "", displayName: name, isSecret: true,
                    valueInKeychain: true, modelNames: ["m1"])
    }

    @Test("已就绪的真实供应商排在 Mock 演示之前，Mock 仍在列表中可选")
    func readyProviderPrecedesMock() throws {
        let ready = record("DEEPSEEK_API_KEY")
        let options = ChatStore.chatProviderOptions(builtInTypes: [], customRecords: [ready])
        let rows = ModelPickerState.providerMenuRows(
            options: options, readyProviderIDs: [options[0].providerRuntimeID]
        )
        let mockIndex = try #require(rows.firstIndex(of: .mock))
        let readyIndex = try #require(rows.firstIndex(of: .provider(options[0])))
        #expect(readyIndex < mockIndex)
        #expect(rows.first == .provider(options[0]))
    }

    @Test("多个就绪供应商（内置+自定义）全部在 Mock 之前，未就绪的不抢在前面")
    func allReadyBeforeMockAndUnreadyAfterReady() throws {
        let custom = record("DASHSCOPE_API_KEY")
        let unready = record("OTHER_API_KEY")
        let options = ChatStore.chatProviderOptions(
            builtInTypes: [.deepSeek], customRecords: [unready, custom]
        )
        let readyIDs: Set<String> = [
            ChatStore.ChatProvider.builtIn(.deepSeek).providerRuntimeID,
            ChatStore.ChatProvider.custom(custom).providerRuntimeID,
        ]
        let rows = ModelPickerState.providerMenuRows(options: options, readyProviderIDs: readyIDs)
        let mockIndex = try #require(rows.firstIndex(of: .mock))
        let readyRows: [ModelPickerProviderRow] = [.provider(.builtIn(.deepSeek)), .provider(.custom(custom))]
        for row in readyRows {
            #expect(try #require(rows.firstIndex(of: row)) < mockIndex)
        }
        #expect(try #require(rows.firstIndex(of: .provider(.custom(unready)))) > rows.firstIndex(of: readyRows[1])!)
    }

    @Test("没有就绪供应商时 Mock 仍在，所有候选都不丢")
    func noReadyProviderKeepsEverythingSelectable() {
        let options = ChatStore.chatProviderOptions(builtInTypes: [.deepSeek], customRecords: [record("X_API_KEY")])
        let rows = ModelPickerState.providerMenuRows(options: options, readyProviderIDs: [])
        #expect(rows.contains(.mock))
        for option in options { #expect(rows.contains(.provider(option))) }
        #expect(rows.count == options.count + 1)
    }
}
